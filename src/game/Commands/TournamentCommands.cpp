/* Tournament control plane.
 *
 * Console-callable battleground control, so an external runner can pair two
 * named teams deterministically instead of hoping the queue does it.
 *
 * `.bg status` / `.bg start` / `.bg stop` are registered AllowConsole = false
 * (Chat.cpp) and dereference m_session->GetPlayer() (Commands.cpp), so nothing
 * outside the game client can drive a battleground. Every command here is
 * AllowConsole = true and touches no session state.
 *
 * Deliberately in core rather than the PlayerBots module: everything here uses
 * core APIs only, so it needs no PlayerbotStubs.cpp entry and keeps working with
 * BUILD_PLAYERBOTS=OFF.
 *
 * OUTPUT CONTRACT. Every record is exactly one line, starting "TOURNAMENT " and
 * continuing as space-separated key=value pairs, printed to the caller and
 * mirrored into bg.log. Scripts parse those lines and nothing else -- do not
 * reformat them, and do not emit a "TOURNAMENT " line by any route other than
 * TournamentEmit.
 *
 * Because readers split a record on whitespace, every value is a single
 * space-free token. A value containing a space does not read as one field with a
 * long value: it reads as a truncated value followed by stray tokens with no "="
 * in them. Anything a human needs that will not fit that shape -- a syntax
 * string, a sentence -- goes out on its own line WITHOUT the "TOURNAMENT "
 * prefix, which readers skip.
 */

#include "Chat.h"
#include "Log.h"
#include "ObjectAccessor.h"
#include "ObjectMgr.h"
#include "Player.h"
#include "BattleGround.h"
#include "BattleGroundMgr.h"
// For the GetTeamScore downcast in `result`: the accessor is declared on
// BattleGroundWS, not on the base class.
#include "BattleGroundWS.h"

#include <sstream>

// One place that both prints to the caller and durably records the same line.
// A console session can be detached mid-command; bg.log cannot.
void ChatHandler::TournamentEmit(std::string const& line)
{
    PSendSysMessage("TOURNAMENT %s", line.c_str());
    sLog.out(LOG_BG, "TOURNAMENT %s", line.c_str());
}

static char const* TournamentStatusName(BattleGroundStatus status)
{
    switch (status)
    {
        case STATUS_WAIT_JOIN:   return "WaitJoin";
        case STATUS_IN_PROGRESS: return "InProgress";
        case STATUS_WAIT_LEAVE:  return "WaitLeave";
        default:                 return "None";
    }
}

// The one place an instance id turns into an instance. BattleGroundMgr::GetBattleGround
// wants a type as well as an id, so this sweeps the types; every handler below that
// takes an <instanceId> goes through here, so there is exactly one lookup to reason
// about and exactly one place that decides what "no such instance" means.
//
// Instance id 0 is rejected rather than looked up: the manager registers the
// template under 0 (see HandleTournamentCreateCommand), and a template has no map,
// so handing it to SendToBattleGround or StopBattleGround is not something a caller
// could ever have meant. `tournament status` skips it for the same reason.
static BattleGround* TournamentFindInstance(uint32 instanceId)
{
    if (!instanceId)
        return nullptr;

    for (uint32 typeId = BATTLEGROUND_AV; typeId < MAX_BATTLEGROUND_TYPE_ID; ++typeId)
        if (BattleGround* bg = sBattleGroundMgr.GetBattleGround(instanceId, BattleGroundTypeId(typeId)))
            return bg;

    return nullptr;
}

bool ChatHandler::HandleTournamentStatusCommand(char* /*args*/)
{
    uint32 count = 0;

    for (uint32 typeId = BATTLEGROUND_AV; typeId < MAX_BATTLEGROUND_TYPE_ID; ++typeId)
    {
        BattleGroundTypeId bgTypeId = BattleGroundTypeId(typeId);

        for (BattleGroundSet::const_iterator it = sBattleGroundMgr.GetBattleGroundsBegin(bgTypeId);
             it != sBattleGroundMgr.GetBattleGroundsEnd(bgTypeId); ++it)
        {
            // Instance id 0 is the template every live instance is copied from,
            // not a battleground anyone can be in. CreateBattleGround registers
            // it under 0 precisely because a template has no map.
            if (!it->first)
                continue;

            BattleGround* bg = it->second;
            if (!bg)
                continue;

            uint32 alliance = 0;
            uint32 horde = 0;
            for (const auto& player : bg->GetPlayers())
            {
                if (player.second.PlayerTeam == HORDE)
                    ++horde;
                else
                    ++alliance;
            }

            std::ostringstream ss;
            ss << "instance=" << it->first
               << " type=" << typeId
               << " map=" << bg->GetMapId()
               << " status=" << TournamentStatusName(bg->GetStatus())
               << " alliance=" << alliance
               << " horde=" << horde
               << " elapsed=" << (bg->GetStartTime() / 1000);
            TournamentEmit(ss.str());
            ++count;
        }
    }

    std::ostringstream ss;
    ss << "status count=" << count;
    TournamentEmit(ss.str());
    return true;
}

bool ChatHandler::HandleTournamentCreateCommand(char* args)
{
    uint32 typeId = 0;
    uint32 level = 0;
    if (!ExtractUInt32(&args, typeId) || !ExtractUInt32(&args, level))
    {
        // The reason is a single space-free token because the record is parsed by
        // splitting on whitespace -- a syntax string inside the value would be read
        // as stray tokens with no "=" in them. The syntax goes out as human
        // commentary on its own unprefixed line, which the parser ignores.
        TournamentEmit("create error=usage");
        SendSysMessage("Syntax: .tournament create <bgTypeId> <level>");
        return true;
    }

    // 0 is BATTLEGROUND_TYPE_NONE, and MAX_BATTLEGROUND_TYPE_ID is a bound, not
    // a type -- both would index past the end of the manager's arrays.
    if (typeId == 0 || typeId >= MAX_BATTLEGROUND_TYPE_ID)
    {
        TournamentEmit("create error=bad_type_id");
        return true;
    }

    BattleGroundTypeId bgTypeId = BattleGroundTypeId(typeId);

    // Templates are read once at boot (World.cpp). A missing one is not
    // something a command can repair at runtime, so report it and stop rather
    // than trying to reload anything.
    if (!sBattleGroundMgr.GetBattleGroundTemplate(bgTypeId))
    {
        TournamentEmit("create error=no_template");
        return true;
    }

    BattleGroundBracketId bracketId = sBattleGroundMgr.GetBattleGroundBracketIdFromLevel(bgTypeId, level);

    BattleGround* bg = sBattleGroundMgr.CreateNewBattleGround(bgTypeId, bracketId);
    if (!bg)
    {
        TournamentEmit("create error=create_failed");
        return true;
    }

    // CreateNewBattleGround builds the instance and its map but does NOT put it
    // in the manager's set -- on the queue path StartBattleGround does that
    // (BattleGround.cpp). Without this the instance id emitted below would
    // resolve to nothing: `tournament status` iterates that set, and so does
    // BattleGroundMgr::GetBattleGround. The destructor calls RemoveBattleGround,
    // so registering here needs no matching teardown.
    //
    // NOTE for whoever adds `tournament add`: a registered instance with no
    // players and no invited count is deleted by BattleGround::Update on the
    // very next map tick, so an instance created here does not survive long
    // enough to be filled by a second console round-trip. Holding an empty
    // instance open is a lifecycle change this scaffolding deliberately does
    // not make.
    sBattleGroundMgr.AddBattleGround(bg->GetInstanceID(), bgTypeId, bg);

    std::ostringstream ss;
    ss << "create instance=" << bg->GetInstanceID()
       << " type=" << typeId
       << " map=" << bg->GetMapId()
       << " bracket=" << uint32(bracketId);
    TournamentEmit(ss.str());
    return true;
}

bool ChatHandler::HandleTournamentAddCommand(char* args)
{
    uint32 instanceId = 0;
    if (!ExtractUInt32(&args, instanceId))
    {
        TournamentEmit("add error=usage");
        SendSysMessage("Syntax: .tournament add <instanceId> <playerName>");
        return true;
    }

    char* nameStr = ExtractQuotedOrLiteralArg(&args);
    if (!nameStr)
    {
        TournamentEmit("add error=no_player_name");
        return true;
    }

    std::string name = nameStr;

    // FindPlayerByName only sees players in the world. A bot with a WorldSession
    // but no character in world reads the same as an offline one here, which is
    // the correct answer either way: there is nothing to teleport.
    Player* player = ObjectAccessor::FindPlayerByName(name.c_str());
    if (!player)
    {
        TournamentEmit("add error=player_not_online(" + name + ")");
        return true;
    }

    BattleGround* bg = TournamentFindInstance(instanceId);
    if (!bg)
    {
        TournamentEmit("add error=no_such_instance");
        return true;
    }

    // Sending a second player into a battleground they are already in would
    // overwrite the bgData of the first one, and the queue path guards the same
    // way (BattleGroundHandler.cpp).
    if (player->InBattleGround())
    {
        TournamentEmit("add error=already_in_a_battleground(" + name + ")");
        return true;
    }

    // Always the player's own team. Cross-faction only, by design: SetBGTeam
    // decides scoring and spawn side but NOT hostility -- Unit::IsHostileTo
    // resolves through faction templates (Unit.cpp:5189) and never consults
    // GetBGTeam(), so a player placed on the opposing side would spawn at the
    // right graveyard, score for the right team, and then refuse to fight
    // anyone. There is deliberately no argument that overrides this.
    Team team = player->GetTeam();

    // Mirrors HandleBattlefieldPortOpcode (BattleGroundHandler.cpp:524-531) minus
    // the queue bookkeeping, because there is no queue entry to retire. Note what
    // is NOT here and cannot be: bg->AddPlayer is deferred to
    // HandleMoveWorldPortAck, so this reports what was sent, not who arrived.
    // `tournament members` is the only way to learn whether it landed.
    player->SetBattleGroundId(bg->GetInstanceID(), bg->GetTypeID(), 0);
    player->SetBGTeam(team);
    sBattleGroundMgr.SendToBattleGround(player, bg->GetInstanceID(), bg->GetTypeID());

    std::ostringstream ss;
    ss << "add instance=" << bg->GetInstanceID()
       << " player=" << name
       << " team=" << (team == HORDE ? "HORDE" : "ALLIANCE")
       << " sent=1";
    TournamentEmit(ss.str());
    return true;
}

bool ChatHandler::HandleTournamentMembersCommand(char* args)
{
    uint32 instanceId = 0;
    if (!ExtractUInt32(&args, instanceId))
    {
        TournamentEmit("members error=usage");
        SendSysMessage("Syntax: .tournament members <instanceId>");
        return true;
    }

    BattleGround* bg = TournamentFindInstance(instanceId);
    if (!bg)
    {
        TournamentEmit("members error=no_such_instance");
        return true;
    }

    uint32 count = 0;
    for (const auto& entry : bg->GetPlayers())
    {
        std::string name;
        if (!sObjectMgr.GetPlayerNameByGUID(entry.first, name))
            name = "?";

        // A guid in GetPlayers() is not a promise the Player still exists -- a
        // player can be gone from the world before the battleground has removed
        // them. map=-1 says "recorded here, not resolvable now", which is not the
        // same statement as map=0 (Eastern Kingdoms, a real map a bot could be on).
        Player* player = ObjectAccessor::FindPlayer(entry.first);

        std::ostringstream ss;
        ss << "member instance=" << instanceId
           << " player=" << name
           // The raw Team value (ALLIANCE=469, HORDE=67) as the battleground
           // stores it, because this command reports what the battleground holds.
           << " team=" << uint32(entry.second.PlayerTeam)
           << " map=" << (player ? int32(player->GetMapId()) : -1);
        TournamentEmit(ss.str());
        ++count;
    }

    std::ostringstream ss;
    ss << "members instance=" << instanceId << " count=" << count;
    TournamentEmit(ss.str());
    return true;
}

bool ChatHandler::HandleTournamentStartCommand(char* args)
{
    uint32 instanceId = 0;
    if (!ExtractUInt32(&args, instanceId))
    {
        TournamentEmit("start error=usage");
        SendSysMessage("Syntax: .tournament start <instanceId>");
        return true;
    }

    BattleGround* bg = TournamentFindInstance(instanceId);
    if (!bg)
    {
        TournamentEmit("start error=no_such_instance");
        return true;
    }

    // Same mechanism as .bg start (Commands.cpp): collapse the countdown rather
    // than call a start method, because the countdown running out IS the start.
    bg->SetStartDelayTime(0);

    std::ostringstream ss;
    ss << "start instance=" << instanceId << " ok=1";
    TournamentEmit(ss.str());
    return true;
}

bool ChatHandler::HandleTournamentStopCommand(char* args)
{
    uint32 instanceId = 0;
    if (!ExtractUInt32(&args, instanceId))
    {
        TournamentEmit("stop error=usage");
        SendSysMessage("Syntax: .tournament stop <instanceId>");
        return true;
    }

    BattleGround* bg = TournamentFindInstance(instanceId);
    if (!bg)
    {
        TournamentEmit("stop error=no_such_instance");
        return true;
    }

    bg->StopBattleGround();

    std::ostringstream ss;
    ss << "stop instance=" << instanceId << " ok=1";
    TournamentEmit(ss.str());
    return true;
}

bool ChatHandler::HandleTournamentResultCommand(char* args)
{
    uint32 instanceId = 0;
    if (!ExtractUInt32(&args, instanceId))
    {
        TournamentEmit("result error=usage");
        SendSysMessage("Syntax: .tournament result <instanceId>");
        return true;
    }

    BattleGround* bg = TournamentFindInstance(instanceId);
    if (!bg)
    {
        // A finished battleground is destroyed, so this is the ordinary way to
        // learn a match is over -- not an error the caller should retry.
        TournamentEmit("result error=no_such_instance(finished_or_never_existed)");
        return true;
    }

    char const* winner = "NONE";
    switch (bg->GetWinner())
    {
        case WINNER_HORDE:    winner = "HORDE";    break;
        case WINNER_ALLIANCE: winner = "ALLIANCE"; break;
        default:              winner = "NONE";     break;
    }

    // GetTeamScore is declared on BattleGroundWS (BattleGroundWS.h:185), not on
    // the base class, so bg->GetTeamScore(ALLIANCE) through a BattleGround* does
    // not compile and the score is only readable once the type is known.
    // BattleGroundBR declares its own identical accessor (BattleGroundBR.h:61):
    // this is a per-subclass convention, not an oversight to be "fixed" by adding
    // a base virtual here. -1 means "this battleground type does not expose a
    // score through this command", which stays distinguishable from a real 0-0.
    int32 allianceScore = -1;
    int32 hordeScore = -1;
    if (bg->GetTypeID() == BATTLEGROUND_WS)
    {
        BattleGroundWS const* ws = static_cast<BattleGroundWS const*>(bg);
        allianceScore = int32(ws->GetTeamScore(ALLIANCE));
        hordeScore = int32(ws->GetTeamScore(HORDE));
    }

    std::ostringstream ss;
    ss << "result instance=" << instanceId
       << " winner=" << winner
       << " allianceScore=" << allianceScore
       << " hordeScore=" << hordeScore
       << " status=" << TournamentStatusName(bg->GetStatus())
       << " elapsed=" << (bg->GetStartTime() / 1000);
    TournamentEmit(ss.str());
    return true;
}
