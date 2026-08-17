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
#include "BattleGround.h"
#include "BattleGroundMgr.h"

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
