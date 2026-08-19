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
#include <vector>
#include <cstdlib>

// How long a created-but-unpopulated instance is held open, and how long an
// invited player is given to actually land in it. One number for both because
// from the runner's point of view it is one window: create, add, port. The value
// is the core's own answer to "how long may an invite sit unredeemed"
// (INVITE_ACCEPT_WAIT_TIME, BattleGround.h).
static uint32 const TOURNAMENT_HOLD_TIME_MS = INVITE_ACCEPT_WAIT_TIME;

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

// Exact undo of the invite `tournament add` takes out: give the instance's
// lifetime hold back and stop the player pointing at it.
//
// MUST NOT be called for a player the battleground actually holds.
// BattleGround::RemovePlayerAtLeave already calls DecreaseInvitedCount for
// anyone who made it into m_Players (BattleGround.cpp), and m_InvitedAlliance /
// m_InvitedHorde are uint32 -- releasing twice wraps one of them to ~4.29e9,
// after which the empty-instance check in BattleGround::Update never fires again
// and the instance and its map are stuck for the life of the process.
static void TournamentReleaseInvite(Player* player, uint32 instanceId, BattleGroundTypeId bgTypeId, Team team)
{
    // A battleground instance id IS its map's instance id (GetInstanceID() reads
    // GetBgMap()->GetInstanceId(), BattleGround.h), so this is "the player is
    // standing in this battleground's own map" -- not just map 489, which every
    // Warsong instance shares. False while the port is still in flight, because
    // m_InstanceId is only rewritten by SetMap at the world-port ack.
    bool const inThatBgMap = player->IsInWorld() && player->GetInstanceId() == instanceId;

    // Re-resolved rather than passed in: this runs from a delayed event too, by
    // which point the instance may already be gone.
    if (BattleGround* bg = sBattleGroundMgr.GetBattleGround(instanceId, bgTypeId))
    {
        bg->DecreaseInvitedCount(team);

        // Nothing holds the instance now. Re-arm the same grace window a fresh
        // `create` gets instead of letting the next map tick delete it: the caller
        // is being told the add failed and is likely to retry against this id, and
        // an id that dies as a side effect of a failed add is worse to script
        // against than one that survives for the window.
        if (!bg->GetPlayersSize() && !bg->GetInvitedCount(HORDE) && !bg->GetInvitedCount(ALLIANCE))
            bg->SetEmptyHoldTime(TOURNAMENT_HOLD_TIME_MS);
    }

    // Clears bgQueueTypeId and invitedToInstance together (Player.h), so this
    // both retires the slot `add` claimed and drops the invite marker.
    player->RemoveBattleGroundQueueId(BattleGroundMgr::BGQueueTypeId(bgTypeId));
    player->SetBattleGroundId(0, BATTLEGROUND_TYPE_NONE, PLAYER_MAX_BATTLEGROUND_QUEUES);
    player->SetBGTeam(TEAM_NONE);

    // Reached the battleground map but never joined the battleground -- the ack
    // failure paths in HandleMoveWorldPortAckOpcode can land a player and skip
    // AddPlayer. With the invite gone nothing else would ever move them again, so
    // put them back where `add` found them (SetBattleGroundEntryPoint recorded it;
    // TeleportToBGEntryPoint falls back to homebind if it was never set,
    // Player.cpp). Ordered after SetBattleGroundId(0) so nothing reads them as
    // still belonging to the instance on the way out.
    if (inThatBgMap)
        player->TeleportToBGEntryPoint();
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

    // A registered instance with no players and nobody invited is `delete this`'d
    // by BattleGround::Update on the very next map tick, and there is no queue
    // behind this one to invite anyone -- `tournament add` is a separate console
    // round-trip. Without this hold the instance id printed below is already
    // dangling by the time the caller can use it, so `add` could only ever answer
    // no_such_instance. The hold is a countdown (BattleGround.h), so an instance
    // created and then forgotten still reaps itself; `add` clears it once the
    // invited count takes over as the instance's lifetime.
    bg->SetEmptyHoldTime(TOURNAMENT_HOLD_TIME_MS);

    // CreateNewBattleGround builds the instance and its map but does NOT put it
    // in the manager's set -- on the queue path StartBattleGround does that
    // (BattleGround.cpp). Without this the instance id emitted below would
    // resolve to nothing: `tournament status` iterates that set, and so does
    // BattleGroundMgr::GetBattleGround. The destructor calls RemoveBattleGround,
    // so registering here needs no matching teardown.
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

    // Refused rather than handled, because the invite below has to live in one of
    // the player's three battleground queue slots, and AddBattleGroundQueueId
    // reuses the slot already holding the same queue type and zeroes its
    // invitedToInstance (Player.h). Taking a queued player would therefore
    // silently overwrite a real queue invite with ours and leave a dangling entry
    // in BattleGroundQueue::m_QueuedPlayers. Dequeue the player first; a tournament
    // is meant to be assembled out of idle bots.
    if (player->InBattleGroundQueue())
    {
        TournamentEmit("add error=player_in_bg_queue(" + name + ")");
        return true;
    }

    // A player already mid-teleport cannot be sent anywhere, and the "did the
    // port actually start?" check further down could not tell their teleport from
    // ours.
    if (player->IsBeingTeleported())
    {
        TournamentEmit("add error=player_teleporting(" + name + ")");
        return true;
    }

    // Always the player's own team. Cross-faction only, by design: SetBGTeam
    // decides scoring and spawn side but NOT hostility -- Unit::IsHostileTo
    // resolves through faction templates (Unit.cpp:5189) and never consults
    // GetBGTeam(), so a player placed on the opposing side would spawn at the
    // right graveyard, score for the right team, and then refuse to fight
    // anyone. There is deliberately no argument that overrides this.
    Team team = player->GetTeam();

    uint32 const instanceIdResolved = bg->GetInstanceID();
    BattleGroundTypeId const bgTypeId = bg->GetTypeID();
    BattleGroundQueueTypeId const bgQueueTypeId = BattleGroundMgr::BGQueueTypeId(bgTypeId);

    // The invite has to hang off a queue slot, because a slot is the only place
    // Player keeps one: SetInviteForBattleGroundQueueType writes
    // invitedToInstance into the slot whose bgQueueTypeId matches and does nothing
    // whatsoever if there is no such slot (Player.h). So claim a slot first even
    // though there is no queue entry behind it.
    //
    // The guard above means all three slots are free, so the failure return cannot
    // happen today -- checked anyway because the sentinel it returns is
    // PLAYER_MAX_BATTLEGROUND_QUEUES itself, which would go on to be stored as a
    // real queue slot index and read back out of bounds.
    uint32 const queueSlot = player->AddBattleGroundQueueId(bgQueueTypeId);
    if (queueSlot >= PLAYER_MAX_BATTLEGROUND_QUEUES)
    {
        TournamentEmit("add error=no_free_queue_slot(" + name + ")");
        return true;
    }

    // Mirrors HandleBattlefieldPortOpcode (BattleGroundHandler.cpp:519-531) minus
    // the queue bookkeeping there is no queue entry to retire. Note what is NOT
    // here and cannot be: bg->AddPlayer is deferred to HandleMoveWorldPortAck, so
    // this reports what was sent, not who arrived. `tournament members` is the
    // only way to learn whether it landed.
    //
    // The next two lines are not optional bookkeeping, they are what makes the
    // send mean anything:
    //
    //  - IncreaseInvitedCount is the instance's lifetime. While the player is in
    //    flight the instance has zero players, and BattleGround::Update deletes
    //    any instance that is empty AND has nobody invited, so without this the
    //    instance is destroyed on the next map tick and the player lands in a
    //    battleground map whose BattleGround object is gone (BattleGroundMap::Update
    //    then early-returns forever on !GetBG(), Map.cpp). It is also half of a
    //    pair: RemovePlayerAtLeave calls DecreaseInvitedCount unconditionally for
    //    anyone who was in m_Players, on a uint32, so an invite never taken out
    //    here would wrap the counter to ~4.29e9 the moment the player left.
    //
    //  - SetInviteForBattleGroundQueueType is what lets the port land.
    //    HandleMoveWorldPortAckOpcode only calls bg->AddPlayer if
    //    IsInvitedForBattleGroundInstance(GetBattleGroundId()) holds
    //    (MovementHandler.cpp) -- that guard exists to stop players who walked in
    //    with .goname from joining the match. Without the invite the player
    //    arrives in the map and never joins the battleground, so `members` can
    //    never report them.
    bg->IncreaseInvitedCount(team);
    player->SetInviteForBattleGroundQueueType(bgQueueTypeId, instanceIdResolved);

    // So the match ending returns the player where they were standing, instead of
    // TeleportToBGEntryPoint falling back to their homebind on an empty joinPos
    // (Player.cpp). HandleBattlefieldPortOpcode does the same.
    player->SetBattleGroundEntryPoint();

    player->SetBattleGroundId(instanceIdResolved, bgTypeId, queueSlot);
    player->SetBGTeam(team);

    // The invited count now carries the instance, so drop the create-time grace
    // window: `result` documents that a finished battleground is destroyed, and
    // leftover hold time would keep an emptied instance alive past its match.
    bg->SetEmptyHoldTime(0);

    sBattleGroundMgr.SendToBattleGround(player, instanceIdResolved, bgTypeId);

    // SendToBattleGround discards TeleportTo's return value, so the only way to
    // know the port started is to look at the player afterwards: a battleground
    // map is always a different map, so this is always a far teleport, and a
    // player who is not now mid-teleport was refused (bad coords, Map::CanEnter).
    // Roll the invite back rather than claim sent=1 for a player going nowhere --
    // an unreleased invite holds the instance open forever, and the leftover
    // bgInstanceID would make InBattleGround() reject every later `add` for that
    // player.
    if (!player->IsBeingTeleported())
    {
        TournamentReleaseInvite(player, instanceIdResolved, bgTypeId, team);
        TournamentEmit("add error=teleport_failed(" + name + ")");
        return true;
    }

    // Backstop for ports that start and never land: HandleMoveWorldPortAckOpcode
    // bails to HandleReturnOnTeleportFail when the battleground map has gone or
    // Map::Add refuses the player (MovementHandler.cpp), and in that case nothing
    // else ever hands the invite back -- RemovePlayerAtLeave only decrements for
    // players who reached m_Players.
    //
    // Ids are captured, not the BattleGround*: the instance may be deleted before
    // this runs (BGQueueRemoveEvent re-resolves for the same reason,
    // BattleGroundMgr.cpp). Capturing the Player* raw is safe -- the event lives
    // in that player's own processor, and events are aborted rather than executed
    // when the processor is destroyed (EventProcessor.h), which is the same
    // assumption BGQueueInviteEvent's siblings make.
    //
    // KNOWN LIMIT: the event carries no serial number, so if the same player is
    // added, lands, leaves and is added to the same still-live instance again
    // inside this window, the first event can release the second add's invite. The
    // counters stay balanced either way (that release is matched by the second
    // add's increase) and the release ports the player back out, so the cost is a
    // second `add` that reported sent=1 and then quietly undid itself -- visible as
    // a missing `members` entry, and fixed by adding again. Doing better needs
    // per-invite state that Player has no field for; a file-static side table would
    // be read from map-update threads.
    player->m_Events.AddLambdaEventAtOffset([player, instanceIdResolved, bgTypeId, team]
    {
        BattleGround* held = sBattleGroundMgr.GetBattleGround(instanceIdResolved, bgTypeId);
        if (!held)
            return;

        // Landed: AddPlayer ran, so RemovePlayerAtLeave owns the matching
        // DecreaseInvitedCount from here on and releasing would double-count.
        if (held->GetPlayers().find(player->GetObjectGuid()) != held->GetPlayers().end())
            return;

        // Already released -- left the battleground, or was sent to a different
        // instance. Same double-count hazard, so leave it alone.
        if (player->GetBattleGroundId() != instanceIdResolved)
            return;

        TournamentReleaseInvite(player, instanceIdResolved, bgTypeId, team);
        // Not a "TOURNAMENT " record: this fires long after the console session
        // that issued the add, and the output contract at the top of this file
        // reserves that prefix for TournamentEmit.
        sLog.out(LOG_BG, "[tournament] invite to instance %u expired for %s, hold released",
                 instanceIdResolved, player->GetName());
    }, TOURNAMENT_HOLD_TIME_MS);

    std::ostringstream ss;
    ss << "add instance=" << instanceIdResolved
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

// Splits "<id>[,<id>...]" into ids.
//
// Empty tokens -- a trailing comma, a doubled comma, a leading comma -- are
// skipped silently rather than reported. The gear tier files this is driven from
// join one field per equipment slot with commas, and a slot with no chosen item
// leaves that field empty; that means "nothing for this slot", not "item 0", so
// emitting a failure line for it would make every partial tier look broken.
//
// A token that is not a number at all is NOT skipped: strtoul yields 0, which has
// no prototype, so it comes back out as ok=0 reason=no_such_item. A malformed list
// is a caller bug worth seeing; an omitted slot is not.
//
// The terminator is tested AFTER the flush, which is what makes a trailing comma
// and a final id without one behave identically, and what stops the walk running
// off the end of the string.
static void TournamentParseItemIds(char const* str, std::vector<uint32>& ids)
{
    if (!str)
        return;

    std::string token;
    for (char const* p = str; ; ++p)
    {
        if (*p && *p != ',')
        {
            token.push_back(*p);
            continue;
        }

        if (!token.empty())
        {
            ids.push_back(uint32(strtoul(token.c_str(), nullptr, 10)));
            token.clear();
        }

        if (!*p)
            break;
    }
}

bool ChatHandler::HandleTournamentEquipCommand(char* args)
{
    char* nameStr = ExtractQuotedOrLiteralArg(&args);
    char* listStr = nameStr ? ExtractLiteralArg(&args) : nullptr;
    if (!nameStr || !listStr)
    {
        TournamentEmit("equip error=usage");
        SendSysMessage("Syntax: .tournament equip <playerName> <itemId>[,<itemId>...]");
        return true;
    }

    std::string name = nameStr;

    std::vector<uint32> ids;
    TournamentParseItemIds(listStr, ids);
    if (ids.empty())
    {
        // A list that is nothing but separators. Distinct from `usage` because the
        // caller did pass an argument -- it built an empty one, which is almost
        // always a tier file that resolved to no items at all.
        TournamentEmit("equip error=no_item_ids");
        return true;
    }

    // Same reading as `add`: only players in the world can be dressed, and a bot
    // with a session but no character in world is correctly "not online" here.
    Player* player = ObjectAccessor::FindPlayerByName(name.c_str());
    if (!player)
    {
        TournamentEmit("equip error=player_not_online(" + name + ")");
        return true;
    }

    uint32 equipped = 0;
    uint32 failed = 0;

    for (uint32 itemId : ids)
    {
        int32 slot = -1;
        uint32 ok = 0;
        std::string reason;

        // Asked separately from CanEquipNewItem even though that returns
        // EQUIP_ERR_ITEM_NOT_FOUND for the same case: "this id is not an item" is a
        // typo in a tier file, while every other InventoryResult is a real item the
        // bot may not wear. The caller has to tell those apart, so they get
        // different reasons rather than one numeric code covering both.
        if (!sObjectMgr.GetItemPrototype(itemId))
        {
            reason = "no_such_item";
        }
        else
        {
            uint16 dest = 0;

            // swap = true, and it is load-bearing. The slot is EXPECTED to hold the
            // previous tier's item: FindEquipSlot with swap = false refuses any
            // occupied slot (Player.cpp:10349-10377) and CanEquipItem then returns
            // EQUIP_ERR_NO_EQUIPMENT_SLOT_AVAILABLE, so re-gearing an already-dressed
            // bot -- the normal case -- would fail on every slot. With swap = true a
            // free slot is still preferred and an occupied one only taken as a
            // fallback, which is also what makes a second ring or trinket land in the
            // empty slot rather than on top of the first.
            InventoryResult res = player->CanEquipNewItem(NULL_SLOT, dest, itemId, true);
            if (res != EQUIP_ERR_OK)
            {
                // The numeric code, deliberately: a class mismatch
                // (EQUIP_ERR_YOU_CAN_NEVER_USE_THAT_ITEM) and a level requirement
                // (EQUIP_ERR_CANT_EQUIP_LEVEL_I) are both bad *item choices* in a tier
                // file rather than a broken command, and the caller needs to tell them
                // apart. The names are in Item.h (enum InventoryResult, Item.h:45)
                // -- NOT SharedDefines.h, where nothing of the sort is declared.
                // The two that matter most here: 20 = not equippable by anyone
                // (a consumable), 10 = never usable by this class.
                std::ostringstream why;
                why << "cannot_equip(" << uint32(res) << ")";
                reason = why.str();
            }
            else
            {
                slot = int32(dest & 255);

                // The occupant has to go before EquipNewItem, not after.
                // Player::EquipItem does NOT replace an item already in the destination
                // slot -- it treats the two as a stack, adds the new count onto the old
                // item, destroys the new one and returns the OLD item
                // (Player.cpp:12336-12409). So equipping over a filled slot without this
                // would report ok=1 and leave the previous tier's item in place. Same
                // destroy-then-equip the playerbot factory does
                // (PlayerbotFactory.cpp:3266-3268).
                if (Item* occupant = player->GetItemByPos(uint8(dest >> 8), uint8(dest & 255)))
                    player->DestroyItem(occupant->GetBagSlot(), occupant->GetSlot(), true);

                if (player->EquipNewItem(dest, itemId, true))
                {
                    ok = 1;
                    reason = "ok";
                    ++equipped;

                    // A two-hander in the mainhand leaves the offhand occupied but
                    // unusable. CanEquipItem already refused the equip unless that
                    // offhand item could be stored, so this cannot strand it, and it is a
                    // no-op for anything that is not a two-hander (Player.cpp:21723). The
                    // buy-item path does the same.
                    player->AutoUnequipOffhandIfNeed();
                }
                else
                {
                    // Item::CreateItem returned nothing -- the prototype exists but the
                    // item could not be built. Distinct from cannot_equip: nothing about
                    // the bot refused it.
                    reason = "equip_failed";
                }
            }
        }

        if (!ok)
            ++failed;

        std::ostringstream ss;
        ss << "equip player=" << name
           << " item=" << itemId
           // -1 rather than 0, because 0 is EQUIPMENT_SLOT_HEAD -- a real answer.
           // Same convention as the map=-1 in `members`.
           << " slot=" << slot
           << " ok=" << ok
           << " reason=" << reason;
        TournamentEmit(ss.str());
    }

    // Before the summary line, so a runner that reads the summary and immediately
    // logs the bot out cannot race the save. Gear applied less than
    // PlayerSave.Interval (60 s) ago is otherwise only in memory, and the runner
    // cycles bots between rounds far faster than that.
    player->SaveToDB();

    std::ostringstream ss;
    ss << "equip player=" << name
       << " equipped=" << equipped
       << " failed=" << failed;
    TournamentEmit(ss.str());
    return true;
}

bool ChatHandler::HandleTournamentStoreCommand(char* args)
{
    char* nameStr = ExtractQuotedOrLiteralArg(&args);
    uint32 itemId = 0;
    uint32 count = 0;
    if (!nameStr || !ExtractUInt32(&args, itemId) || !ExtractUInt32(&args, count))
    {
        TournamentEmit("store error=usage");
        SendSysMessage("Syntax: .tournament store <playerName> <itemId> <count>");
        return true;
    }

    std::string name = nameStr;

    // CanStoreNewItem for a zero count answers EQUIP_ERR_OK with an empty
    // destination, and StoreNewItem then returns nothing -- which would read as
    // store_failed for what is really a caller mistake.
    if (!count)
    {
        TournamentEmit("store error=bad_count");
        return true;
    }

    Player* player = ObjectAccessor::FindPlayerByName(name.c_str());
    if (!player)
    {
        TournamentEmit("store error=player_not_online(" + name + ")");
        return true;
    }

    uint32 ok = 0;
    std::string reason;

    if (!sObjectMgr.GetItemPrototype(itemId))
    {
        reason = "no_such_item";
    }
    else
    {
        // Bags, not equipment. `equip` is the wrong verb for a consumable and is
        // deliberately not taught to accept one: CanEquipNewItem refuses a potion,
        // correctly, and a stack of five would have nowhere to go if it did not.
        ItemPosCountVec dest;
        InventoryResult res = player->CanStoreNewItem(NULL_BAG, NULL_SLOT, dest, itemId, count);
        if (res != EQUIP_ERR_OK)
        {
            // Usually EQUIP_ERR_INVENTORY_FULL (50, Item.h): bots ship with small
            // default bags.
            // Numeric for the same reason as cannot_equip -- a full pack and a
            // per-character unique limit need different fixes.
            std::ostringstream why;
            why << "cannot_store(" << uint32(res) << ")";
            reason = why.str();
        }
        else if (!player->StoreNewItem(dest, itemId, true))
        {
            reason = "store_failed";
        }
        else
        {
            ok = 1;
            reason = "ok";
        }
    }

    // Unconditional, and for the same reason as in `equip`: the runner may log the
    // bot out well inside PlayerSave.Interval.
    player->SaveToDB();

    std::ostringstream ss;
    ss << "store player=" << name
       << " item=" << itemId
       << " count=" << count
       << " ok=" << ok
       << " reason=" << reason;
    TournamentEmit(ss.str());
    return true;
}

// Resolves the argument of `heal` / `kill` to a player who is genuinely in a
// live battleground. On refusal it hands back the reason token rather than
// emitting it, so both commands refuse identically while each still labels the
// record with its own verb (TournamentEmit is a protected member of
// ChatHandler and not callable from here).
//
// This guard IS the task, not a formality. The viewer effect queue is durable
// and replayed after a crash, so an effect routinely outlives the match that
// produced it. A `kill` that lands on a bot which has already left the
// battleground is not a harmless no-op -- it is the wrong bot dying, and to the
// viewer it looks like nothing happened.
//
// The membership test is bg->IsPlayerInBattleGround (BattleGround.h:550), not
// InBattleGround() and not a non-null GetBattleGround(). InBattleGround() is
// only "m_bgData.bgInstanceID != 0" (Player.h:3089), so it stays true for an id
// whose instance the manager has already reaped. GetBattleGround() resolves that
// id, which rejects the reaped instance -- but it is still non-null for a bot
// `tournament add` has invited and which is mid-far-teleport: add sets
// SetBattleGroundId before SendToBattleGround (above), and the player is only
// inserted into bg->m_Players later, when the world port acks and
// HandleMoveWorldPortAckOpcode calls bg->AddPlayer (MovementHandler.cpp).
// m_Players membership is the only one of the three that means "on the
// battleground map, in the match", so `kill` cannot land lethal damage on a bot
// still standing on its old map.
//
// FindPlayerByName finds in-world players only (FindPlayerByNameNotInWorld is
// the other overload), so a bot with a session but no character in the world is
// correctly "not online" here -- the same reading `add` and `equip` take.
static Player* TournamentFindPlayerInBattleGround(std::string const& name, std::string& error)
{
    Player* plr = ObjectAccessor::FindPlayerByName(name.c_str());
    if (!plr)
    {
        error = "player_not_online(" + name + ")";
        return nullptr;
    }

    BattleGround* bg = plr->GetBattleGround();
    if (!bg || !bg->IsPlayerInBattleGround(plr->GetObjectGuid()))
    {
        error = "not_in_battleground(" + name + ")";
        return nullptr;
    }

    return plr;
}

bool ChatHandler::HandleTournamentHealCommand(char* args)
{
    char* nameStr = ExtractQuotedOrLiteralArg(&args);
    if (!nameStr)
    {
        TournamentEmit("heal error=usage");
        SendSysMessage("Syntax: .tournament heal <playerName>");
        return true;
    }

    std::string name = nameStr;

    std::string error;
    Player* plr = TournamentFindPlayerInBattleGround(name, error);
    if (!plr)
    {
        TournamentEmit("heal error=" + error);
        return true;
    }

    uint32 resurrected = 0;
    if (!plr->IsAlive())
    {
        // The same pair `.revive` uses (Commands.cpp:3016). Resurrecting without
        // SpawnCorpseBones leaves the corpse standing and the client can still run
        // back to it -- a live player with a corpse still on the field.
        // ResurrectPlayer's restore_percent is a fraction, so 1.0f is already a
        // full heal; the SetHealth below is what covers the alive-but-hurt case.
        plr->ResurrectPlayer(1.0f);
        plr->SpawnCorpseBones();
        resurrected = 1;
    }

    plr->SetHealth(plr->GetMaxHealth());

    std::ostringstream ss;
    ss << "heal player=" << name
       << " hp=" << plr->GetHealth()
       << " resurrected=" << resurrected
       << " ok=1";
    TournamentEmit(ss.str());
    return true;
}

bool ChatHandler::HandleTournamentKillCommand(char* args)
{
    char* nameStr = ExtractQuotedOrLiteralArg(&args);
    if (!nameStr)
    {
        TournamentEmit("kill error=usage");
        SendSysMessage("Syntax: .tournament kill <playerName>");
        return true;
    }

    std::string name = nameStr;

    std::string error;
    Player* plr = TournamentFindPlayerInBattleGround(name, error);
    if (!plr)
    {
        TournamentEmit("kill error=" + error);
        return true;
    }

    // Already a corpse. Reported as a refusal rather than an error because the
    // caller asked for something that is already true, and a replayed queue entry
    // hits this constantly.
    if (!plr->IsAlive())
    {
        TournamentEmit("kill player=" + name + " ok=0 reason=already_dead");
        return true;
    }

    // Mirrors `.die`'s refusal (Commands.cpp:2805). Tournament bots are never
    // hardcore, so this should never fire -- but the name comes off an untrusted
    // effect queue on a server carrying ~1000 concurrent characters, and the
    // alternative to the guard is a console command that can permanently destroy
    // someone's character.
    if (plr->IsHardcore())
    {
        TournamentEmit("kill player=" + name + " ok=0 reason=hardcore_character");
        return true;
    }

    // Self-inflicted lethal damage rather than SetHealth(0) or a direct state
    // change, so the normal battleground death path runs: the death is scored,
    // the bot releases, and it respawns at its team's graveyard exactly like any
    // other kill. Setting state directly would leave the scoreboard and the
    // release timer untouched.
    //
    // The victim is the player itself, so there is no killer to credit -- the same
    // shape `.die` uses with CONFIG_BOOL_DIE_COMMAND_CREDIT off
    // (Commands.cpp:2821). durabilityLoss is false: a tournament bot's gear is
    // handed to it by `tournament equip`, and repairing it between rounds is not
    // something the runner does.
    plr->DealDamage(plr, plr->GetHealth(), nullptr, DIRECT_DAMAGE, SPELL_SCHOOL_MASK_NORMAL, nullptr, false);

    // "-" rather than an empty value: a reader splits the record on whitespace, and
    // "reason=" with nothing after it is an empty-valued field to some parsers and
    // a missing one to others.
    std::ostringstream ss;
    ss << "kill player=" << name << " ok=1 reason=-";
    TournamentEmit(ss.str());
    return true;
}

// Where the story is right now, reduced to one point. This is the ONE
// implementation of it: `poi` prints it and `camera` flies a spectator to it,
// and a second copy would drift from this one on the first edit -- after which
// the camera would sit somewhere `poi` never printed and nobody could tell which
// of the two was lying.
//
// Fills x/y/z plus the three things the records have to name: which branch
// answered (`reason`), the player that branch is framed on (`subject`, "-" when
// the answer is not about one player), and how many live players the answer was
// drawn from (`players`). The last two are out-parameters rather than something
// `poi` works out for itself precisely because working them out means redoing
// the reduction -- the cluster branch's player count is the size of the cluster,
// not the size of the battleground.
//
// Returns false only when there is nothing to look at at all: an instance with
// nobody alive in it. The outputs are still filled in that case (reason=empty,
// zeroed coordinates) so a caller that prints them regardless prints something
// deterministic rather than whatever was on the stack.
static bool TournamentComputePoi(BattleGround* bg, float& x, float& y, float& z,
                                 std::string& reason, std::string& subject, uint32& players)
{
    x = 0.0f;
    y = 0.0f;
    z = 0.0f;
    reason = "empty";
    subject = "-";
    players = 0;

    // Live players are collected ONCE. Every branch below is a different
    // reduction over this same set: re-walking GetPlayers() per branch would be
    // slower and, worse, racy -- a bot can die between two passes, and the
    // record would then describe two different moments of the match at once.
    //
    // ObjectAccessor::FindPlayer resolves in-world players only, and a guid in
    // GetPlayers() is not a promise the Player still exists (`members` above
    // documents the same hazard), so every lookup is null-checked. This walks
    // every member of a battleground on a server carrying ~1000 concurrent
    // playerbots; a missing null check here is a crash, not a wrong answer.
    std::vector<Player*> alive;
    for (const auto& entry : bg->GetPlayers())
        if (Player* player = ObjectAccessor::FindPlayer(entry.first))
            if (player->IsAlive())
                alive.push_back(player);

    if (alive.empty())
        return false;

    // 1. A flag carrier IS the story, so it outranks everything below.
    //
    // GetFlagCarrierGuid is a base virtual (BattleGround.h:299) returning an
    // empty guid by default, which is why this needs no subclass include, no
    // aura sniffing and no per-type special case: Warsong overrides it and reads
    // m_FlagKeepers, and a battleground with no flags answers empty and falls
    // straight through to the combat branch. BG_TEAMS_COUNT is 2 -- index 0 is
    // Alliance, 1 is Horde.
    for (uint32 teamIdx = 0; teamIdx < BG_TEAMS_COUNT; ++teamIdx)
    {
        ObjectGuid carrier = bg->GetFlagCarrierGuid(teamIdx);
        if (carrier.IsEmpty())
            continue;

        // A carrier who just died is still recorded as the carrier until the
        // flag actually drops, so liveness is checked rather than trusting the
        // guid: framing on a corpse is exactly the moment the fight has moved
        // somewhere else.
        Player* player = ObjectAccessor::FindPlayer(carrier);
        if (!player || !player->IsAlive())
            continue;

        x = player->GetPositionX();
        y = player->GetPositionY();
        z = player->GetPositionZ();
        reason = "flagcarrier";
        subject = player->GetName();
        players = uint32(alive.size());
        return true;
    }

    // 2. Otherwise the biggest knot of players in combat.
    //
    // Deliberately NOT a global centroid of everyone fighting: in a two-sided
    // battleground with a skirmish at each end, that averages out to the empty
    // middle of the map -- the one place with nothing to watch. The largest
    // cluster is a real fight.
    //
    // O(n^2) over at most 40 players, run only when a director asks. Do not
    // "optimise" it into something that caches Player pointers between calls:
    // they are only valid for the duration of this function.
    float const CLUSTER_RADIUS = 40.0f;

    Player* best = nullptr;
    size_t bestCount = 0;
    for (Player* a : alive)
    {
        if (!a->IsInCombat())
            continue;

        size_t count = 0;
        for (Player* b : alive)
            if (b->IsInCombat() && a->GetDistance(b) <= CLUSTER_RADIUS)
                ++count;

        if (count > bestCount)
        {
            bestCount = count;
            best = a;
        }
    }

    // A player in combat on their own is a bot being chewed on by a graveyard
    // guard, not a fight worth cutting to, so a cluster has to be at least two.
    if (best && bestCount >= 2)
    {
        float sx = 0.0f, sy = 0.0f, sz = 0.0f;
        uint32 n = 0;
        for (Player* b : alive)
        {
            if (!b->IsInCombat() || best->GetDistance(b) > CLUSTER_RADIUS)
                continue;

            sx += b->GetPositionX();
            sy += b->GetPositionY();
            sz += b->GetPositionZ();
            ++n;
        }

        x = sx / n;
        y = sy / n;
        z = sz / n;
        reason = "combat";
        subject = best->GetName();
        // The cluster, not the battleground: this number is how many players the
        // framing actually covers.
        players = n;
        return true;
    }

    // 3. Nothing is happening. The centroid of everyone alive at least keeps the
    //    camera on the map, and reason=centroid is the honest label for it -- a
    //    director reading that knows the framing is a guess and can hold a wide
    //    shot instead of cutting.
    float sx = 0.0f, sy = 0.0f, sz = 0.0f;
    for (Player* player : alive)
    {
        sx += player->GetPositionX();
        sy += player->GetPositionY();
        sz += player->GetPositionZ();
    }

    x = sx / alive.size();
    y = sy / alive.size();
    z = sz / alive.size();
    reason = "centroid";
    players = uint32(alive.size());
    return true;
}

bool ChatHandler::HandleTournamentPoiCommand(char* args)
{
    uint32 instanceId = 0;
    if (!ExtractUInt32(&args, instanceId))
    {
        TournamentEmit("poi error=usage");
        SendSysMessage("Syntax: .tournament poi <instanceId>");
        return true;
    }

    BattleGround* bg = TournamentFindInstance(instanceId);
    if (!bg)
    {
        TournamentEmit("poi error=no_such_instance");
        return true;
    }

    float x = 0.0f, y = 0.0f, z = 0.0f;
    std::string reason;
    std::string subject;
    uint32 players = 0;

    // Return value deliberately unused. "Nothing to look at" is a perfectly good
    // answer to this question, and the helper has already labelled it
    // reason=empty with zeroed coordinates, so this handler stays a printer and
    // nothing else. Only `camera` branches on the return, because only `camera`
    // has to decide whether to move a character.
    TournamentComputePoi(bg, x, y, z, reason, subject, players);

    std::ostringstream ss;
    ss << "poi instance=" << instanceId
       << " map=" << bg->GetMapId()
       << " x=" << x
       << " y=" << y
       << " z=" << z
       << " reason=" << reason
       << " subject=" << subject
       << " players=" << players;
    TournamentEmit(ss.str());
    return true;
}

// How far above the point of interest the spectator is put when no height is
// given: high enough to take in a whole skirmish, low enough to still read
// nameplates.
static uint32 const TOURNAMENT_CAMERA_DEFAULT_HEIGHT = 25;

bool ChatHandler::HandleTournamentCameraCommand(char* args)
{
    char* nameStr = ExtractQuotedOrLiteralArg(&args);
    uint32 instanceId = 0;
    uint32 height = 0;
    if (!nameStr || !ExtractUInt32(&args, instanceId) ||
        !ExtractOptUInt32(&args, height, TOURNAMENT_CAMERA_DEFAULT_HEIGHT))
    {
        TournamentEmit("camera error=usage");
        SendSysMessage("Syntax: .tournament camera <playerName> <instanceId> [height]");
        return true;
    }

    std::string name = nameStr;

    // FindPlayerByName sees in-world players only -- the same reading `add` and
    // `equip` take. A session with no character in the world has nothing to
    // teleport.
    Player* plr = ObjectAccessor::FindPlayerByName(name.c_str());
    if (!plr)
    {
        TournamentEmit("camera error=spectator_not_online(" + name + ")");
        return true;
    }

    BattleGround* bg = TournamentFindInstance(instanceId);
    if (!bg)
    {
        TournamentEmit("camera error=no_such_instance");
        return true;
    }

    // THE IMPORTANT HALF OF THIS COMMAND. The spectator must never be a member of
    // the match they are watching: yanking a participant across the map would
    // change the fight, and the whole point of a spectator is that the match is
    // still 10v10 with them there. A member is refused outright rather than
    // accommodated.
    //
    // IsPlayerInBattleGround is the m_Players lookup (BattleGround.h:550) -- the
    // only one of the three membership tests that means "in the match". As
    // `heal`/`kill` document above, InBattleGround() is just a non-zero instance
    // id and GetBattleGround() is still non-null for a bot mid-port.
    if (bg->IsPlayerInBattleGround(plr->GetObjectGuid()))
    {
        TournamentEmit("camera error=spectator_is_a_match_participant(" + name + ")");
        return true;
    }

    // The same participant, one step earlier. m_Players is only written by
    // BattleGround::AddPlayer, which HandleMoveWorldPortAckOpcode calls at the end
    // of the port -- so a player `tournament add` has already invited and sent is
    // absent from the lookup above for the whole flight and would pass it. Cutting
    // a camera to them would teleport them off their inbound trajectory, and the
    // ack would enrol them anyway on arrival: exactly the 11v10 the refusal above
    // exists to prevent. The invite is the state that exists the whole time,
    // because `add` takes it out before SendToBattleGround and only
    // TournamentReleaseInvite or RemovePlayerAtLeave gives it back.
    if (plr->IsInvitedForBattleGroundInstance(bg->GetInstanceID()))
    {
        TournamentEmit("camera error=spectator_is_invited_to_the_match(" + name + ")");
        return true;
    }

    // Refused for the reason `add` refuses one: a player already mid-teleport
    // cannot be sent anywhere, and TeleportTo would silently drop the second
    // destination rather than fail loudly, leaving us to report a move that never
    // happened. Also catches an inbound participant of some other instance whose
    // invite this command has no business inspecting.
    if (plr->IsBeingTeleported())
    {
        TournamentEmit("camera error=spectator_teleporting(" + name + ")");
        return true;
    }

    float x = 0.0f, y = 0.0f, z = 0.0f;
    std::string reason;
    std::string subject;
    uint32 players = 0;
    if (!TournamentComputePoi(bg, x, y, z, reason, subject, players))
    {
        // Nobody alive in there, so there is nowhere to cut to. Reported with the
        // helper's own reason token, so `poi` and `camera` speak one vocabulary.
        std::ostringstream ss;
        ss << "camera player=" << name
           << " instance=" << instanceId
           << " moved=0"
           << " reason=" << reason;
        TournamentEmit(ss.str());
        return true;
    }

    // A player who is genuinely in some OTHER battleground is refused rather than
    // moved: the teleport below has to overwrite their battleground id (see the
    // next comment), and doing that to a real participant of another match would
    // strand them -- their own instance would stop recognising them on the way
    // out. `add` refuses the mirror case for the same reason.
    if (BattleGround* other = plr->GetBattleGround())
        if (other != bg && other->IsPlayerInBattleGround(plr->GetObjectGuid()))
        {
            TournamentEmit("camera error=spectator_in_another_battleground(" + name + ")");
            return true;
        }

    // Everything below writes m_bgData, and every one of those writes also sets
    // m_needSave -- so a half-applied camera move does not just look wrong now, it
    // is flushed to characters.bgInstanceID/joinPos at the next save and outlives
    // logout: the GM relocates into the arena on next login, and `tournament add`
    // refuses them with already_in_a_battleground because InBattleGround() reads
    // the leftover id. Captured here so the failure path can put every field back
    // in one place, the way TournamentReleaseInvite undoes `add`'s writes in one
    // place. (m_needSave itself has no setter and stays true, which only costs a
    // save of values identical to the ones already on disk.)
    WorldLocation const savedEntryPoint = plr->GetBattleGroundEntryPoint();
    uint32 const savedBgInstanceId = plr->GetBattleGroundId();
    BattleGroundTypeId const savedBgTypeId = plr->GetBattleGroundTypeId();
    uint32 const savedBgQueueSlot = plr->GetCurrentBattlegroundQueueSlot();

    // Where they came from, so the end of the match sends them back somewhere
    // sensible instead of TeleportToBGEntryPoint falling back to their homebind
    // (Player.cpp). Skipped when they already carry a battleground id, because
    // then they are standing inside an arena and recording THAT as the way out
    // would be worse than the stale value it replaces.
    if (!plr->InBattleGround())
        plr->SetBattleGroundEntryPoint();

    // This is what makes the teleport land, and it is NOT enrolment.
    //
    // Player::TeleportTo refuses a battleground map outright unless the traveller
    // already carries a battleground id (Player.cpp:2617), and the world-port ack
    // resolves the destination as FindMap(mapId, GetBattleGroundId())
    // (MovementHandler.cpp:133) -- so without this the spectator either does not
    // move at all or lands in some other Warsong instance. `.appear` into a
    // battleground does exactly this (HandleGonameCommand, Commands.cpp).
    //
    // It does not make them a participant: HandleMoveWorldportAckOpcode only
    // calls bg->AddPlayer when IsInvitedForBattleGroundInstance holds, and
    // nothing here takes out an invite -- that is `tournament add`'s job, and the
    // guard above already refused anyone the battleground actually holds. They
    // arrive as a GM standing on the map, which is also why `.bg leave` does not
    // apply to them.
    uint32 teleFlags = TELE_TO_GM_MODE;
    if (plr->GetBattleGroundId() != bg->GetInstanceID())
    {
        plr->SetBattleGroundId(bg->GetInstanceID(), bg->GetTypeID(), PLAYER_MAX_BATTLEGROUND_QUEUES);
        // Forces the far-teleport path even when they are already on a map with
        // the same id, because the destination is a different copy of that map.
        teleFlags |= TELE_TO_FORCE_MAP_CHANGE;
    }

    float const cameraZ = z + float(height);

    // A cut, not a pan. There is no server-side API to rotate a client's view, so
    // this drops the spectator above the action and leaves the aiming to whoever
    // is at the keyboard: a director gets broadcast-style cuts between positions,
    // never smooth tracking.
    //
    // Whether the port started is checked rather than assumed: reporting moved=1
    // for a teleport that never happened would have a director cutting to a camera
    // still sitting in the last shot. The return value alone does not answer that.
    // It is false for the cheap up-front refusals -- IsValidMapCoord rejects a
    // position off the map, which an absurd height argument produces -- but
    // TeleportTo's return value is NOT "the port happened", and for this
    // destination it is barely even "the port started". A battleground map is a
    // different map copy from wherever the spectator was standing, so this always
    // takes the far branch, and that branch ends at MapManager::ScheduleFarTeleport
    // and returns true: mid-map-update it only queues the move, and the
    // CanPlayerEnter / Map::CanEnter refusals that actually decide the traveller's
    // fate are re-run later in Player::ExecuteTeleportFar (Player.cpp). So the
    // return value alone would have us report moved=1 for a spectator who never
    // left, with the m_bgData writes above -- and their m_needSave -- left behind.
    //
    // Checked the way `tournament add` checks SendToBattleGround: look at the
    // player afterwards. Every path that really started a move sets a teleport
    // semaphore -- near sets mSemaphoreTeleport_Near, an immediate far teleport
    // sets mSemaphoreTeleport_Far, a queued one sets mPendingFarTeleport -- and
    // IsBeingTeleported() is the OR of the three (Player.h). Not being teleported
    // after the call therefore means refused, whatever the return value said.
    bool const portStarted = plr->TeleportTo(bg->GetMapId(), x, y, cameraZ, plr->GetOrientation(), teleFlags)
                             && plr->IsBeingTeleported();

    if (!portStarted)
    {
        // One rollback closing both writes above: the entry point and the
        // battleground id go back to the values this handler found, so a moved=0
        // refusal leaves the player exactly as unentered as they were and a later
        // `tournament add` still sees a free player.
        plr->SetBattleGroundEntryPoint(savedEntryPoint.mapId, savedEntryPoint.x,
                                       savedEntryPoint.y, savedEntryPoint.z, savedEntryPoint.o);
        plr->SetBattleGroundId(savedBgInstanceId, savedBgTypeId, savedBgQueueSlot);

        std::ostringstream ss;
        ss << "camera player=" << name
           << " instance=" << instanceId
           << " x=" << x
           << " y=" << y
           << " z=" << cameraZ
           << " reason=" << reason
           << " moved=0";
        TournamentEmit(ss.str());
        return true;
    }

    // Backstop for a port that starts and never lands, which the check above
    // cannot see because it happens later and elsewhere: HandleMoveWorldPortAckOpcode
    // bails to Player::HandleReturnOnTeleportFail when the battleground map has
    // gone or Map::Add refuses the spectator, and that returns them to where they
    // were WITHOUT touching m_bgData. Nothing else would ever clear it, so the
    // stale bgInstanceID/joinPos gets flushed at the next save and is exactly the
    // persistent "in a match they never entered" state the rollback above exists
    // to prevent -- just reached by the slower road. Same shape as the invite
    // backstop `tournament add` arms after SendToBattleGround.
    //
    // Only armed when this call actually wrote m_bgData. A repeat cut to an
    // instance the spectator already carries the id of writes nothing (the
    // SetBattleGroundId above is guarded, and the entry-point write is skipped for
    // anyone already InBattleGround()), so arming there would queue an event whose
    // "restore" would re-apply the very id an earlier cut's backstop is due to
    // clear.
    //
    // Capturing the Player* raw is safe for the reason `add` documents: the event
    // lives in that player's own processor and is aborted, not run, if the
    // processor is destroyed (EventProcessor.h).
    if (savedBgInstanceId != bg->GetInstanceID())
    {
        uint32 const targetInstanceId = bg->GetInstanceID();
        plr->m_Events.AddLambdaEventAtOffset([plr, targetInstanceId, savedEntryPoint,
                                              savedBgInstanceId, savedBgTypeId, savedBgQueueSlot]
        {
            // Landed. A battleground instance id IS its map's instance id
            // (BattleGround.h), so this is "standing in that battleground's own
            // map" -- the spectator is where the cut sent them and needs the id to
            // stay, because the map lookup at every later ack reads it.
            if (plr->IsInWorld() && plr->GetInstanceId() == targetInstanceId)
                return;

            // Somebody else owns the field now -- a later cut to a different
            // instance, or a `tournament add`. Restoring a value from before their
            // write would strand them, so leave it.
            if (plr->GetBattleGroundId() != targetInstanceId)
                return;

            // A port is in flight right now -- a later cut to this same instance,
            // most likely, since a director re-cuts every fifteen seconds and this
            // fires eighty seconds after the one that armed it. Clearing the id
            // mid-flight would make the ack's FindMap(mapId, GetBattleGroundId())
            // miss and turn a working cut into a failed one, so this event stands
            // down rather than sabotage it.
            //
            // KNOWN LIMIT: standing down is permanent for this event, and a repeat
            // cut to an instance the spectator already carries the id of arms no
            // event of its own -- so if that in-flight cut ALSO fails at the ack,
            // the stale id survives until the next cut that lands. The next
            // successful cut to this instance clears it by arriving, and a cut to
            // any other instance overwrites it; what is left is a director that
            // stopped mid-failure, whose GM keeps a bgInstanceID until an operator
            // cuts once more or `tournament add`s them. Closing it properly needs
            // per-camera-cut state that Player has no field for.
            if (plr->IsBeingTeleported())
                return;

            plr->SetBattleGroundEntryPoint(savedEntryPoint.mapId, savedEntryPoint.x,
                                           savedEntryPoint.y, savedEntryPoint.z, savedEntryPoint.o);
            plr->SetBattleGroundId(savedBgInstanceId, savedBgTypeId, savedBgQueueSlot);

            // Not a "TOURNAMENT " record: this fires long after the console
            // session that issued the camera cut, and that prefix is reserved for
            // TournamentEmit.
            sLog.out(LOG_BG, "[tournament] camera port to instance %u never landed for %s, bgData rolled back",
                     targetInstanceId, plr->GetName());
        }, TOURNAMENT_HOLD_TIME_MS);
    }

    std::ostringstream ss;
    ss << "camera player=" << name
       << " instance=" << instanceId
       << " x=" << x
       << " y=" << y
       << " z=" << cameraZ
       << " reason=" << reason
       << " moved=1";
    TournamentEmit(ss.str());
    return true;
}
