# UnVAC (RevEmu edition)

Lets VAC-banned players join a Source dedicated server, while the server stays VAC
secure for everybody else. Full source code included.

It replaces UnVAC 0.0.6 by asherkin (2011), a closed-source Metamod:Source plugin that
no longer loads on current Metamod:Source / SourceMod.
Original thread: https://forums.alliedmods.net/showthread.php?t=132853

## IMPORTANT - read before installing
This plugin only does something on a server whose steamclient is RevEmu (a Steam
emulator). On such a server, a VAC-banned account is refused by the ticket check
(ISteamGameServer::BeginAuthSession returns 1, "invalid ticket", and the engine prints
"S3: Client connected with invalid ticket") BEFORE any answer from the Steam servers.
The plugin turns that 1 into 0 (OK) for the accounts you choose.

On a normal server (Valve's steamclient) a VAC ban is reported later, by the
ValidateAuthTicketResponse_t callback, BeginAuthSession returns OK, and this plugin never
sees anything to change. It is NOT a general replacement for the 2011 plugin.

## About RevEmu, and a disclaimer
RevEmu's installation and configuration are not explained here and not linked: if you do not
already run it, look up the setup procedure yourself. RevEmu is a third-party Steam emulator
distributed outside any official channel, and installing it can be risky (unverified
binaries, the security of your server, the terms of your host and of Steam). You do that
entirely at your own risk. The author is in no way responsible for what you install, for how
you use this plugin, or for any damage, ban or loss that results. This plugin is provided as
is, without any warranty.

## Differences from the 2011 UnVAC
- It is a SourceMod plugin, not a Metamod:Source plugin. Commands: sm_unvac_add,
  sm_unvac_remove, sm_unvac_list (sm_ prefix, root admins or RCON).
- Not ported: unvac_clear, the blacklist mode (unvac_mode 1) and unvac_fix_insecure.
  There are two other modes instead (sm_unvac_mode, below).
- It acts on something else. The original replaced the GSClientDeny callback of the Steam
  backend with a GSClientApprove one; this one changes the result of BeginAuthSession
  (see "How it works").
- The original supported the Source 2009 games it listed (TF2, HL2:DM, DoD:S); this one
  was only tested on Counter-Strike: Source.

## Requirements
- Linux, 32-bit srcds. Counter-Strike: Source (game folder "cstrike") is the only game it
  was tested on. The gamedata finds the engine function by its Linux symbol name, so
  engine_srv.so must still contain its symbols (it does in the current CS:S build).
  Windows is not supported (no symbols there, it would need byte signatures).
- Metamod:Source and SourceMod 1.12 (tested: SourceMod 1.12.0-git7255). It uses
  DynamicDetour / DynamicHook.HookRaw, so 1.11 should work too but was not tested.
  DHooks is built into SourceMod, nothing else to install.
- RevEmu as the server's steamclient (bin/steamclient.so, rev.ini).
- Automatic mode only: "Logging=True" in the [steamclient] section of the server's
  rev.ini, so that rev-client.log (in the server folder, next to srcds_run) records
  "UserConnect SteamID = STEAM_0:Y:Z (...)  VAC status: banned" lines.

## Installation
1. Copy the "addons" and "cfg" folders of this repository into your "cstrike" folder
  (they merge with the existing ones).
2. Restart the server (or "sm plugins load unvac"). "sm plugins list" must show
  "UnVAC" (1.2.0), and addons/sourcemod/logs/errors_*.log must have no unvac line.
3. Choose the mode in cfg/sourcemod/unvac.cfg (sm_unvac_mode, see below).

The hook on BeginAuthSession is installed when the first client connects after the
plugin is loaded, always before the engine calls BeginAuthSession for that client.

To compile it yourself: addons/sourcemod/scripting/unvac.sp, with the includes of your
SourceMod (it only needs <sourcemod> and <dhooks>).

## Modes (sm_unvac_mode)
- `0` = manual: only the SteamIDs added with `sm_unvac_add` may join despite a VAC ban.
- `1` = automatic: every VAC-banned account may join, nothing to add. An account counts as
  VAC-banned when RevEmu says so for that same SteamID in `rev-client.log`.
In both modes the SteamIDs of the list may join, and an admin SteamID (as known to
SourceMod's admin cache) is NEVER let in as a VAC-banned account in automatic mode.
Default: 1. Change it live with "sm_unvac_mode 0" / "sm_unvac_mode 1" and keep it in
cfg/sourcemod/unvac.cfg (a live change is lost at the next restart).

## Commands (root admins or RCON)
| Command | Effect |
|---|---|
| `sm_unvac_add "STEAM_0:Y:Z"` | add a SteamID to the list (`[U:1:N]` is accepted too) |
| `sm_unvac_remove "STEAM_0:Y:Z"` | remove it |
| `sm_unvac_list` | current mode and list |

The list is stored in addons/sourcemod/data/unvac_whitelist.txt (one SteamID per line).
Every admission is logged in addons/sourcemod/logs/L*.log, for example:
```
[unvac.smx] STEAM_0:1:1234567 refused by the Steam check (VAC ban reported by RevEmu): let in (automatic mode)
```

## How it works
1. For each connecting client the engine calls CSteam3Server::NotifyClientConnect, which
  calls ISteamGameServer::BeginAuthSession(ticket, length, steamID) and accepts the client
  only if the result is 0 (k_EBeginAuthSessionResultOK).
2. The plugin detours NotifyClientConnect only to read the ISteamGameServer pointer the
  engine keeps at this + 4, then puts a DHooks post hook (DynamicHook.HookRaw) on slot 26
  of that interface, which is BeginAuthSession.
3. In the post hook: if the result is 1 (invalid ticket) and the account is in the list, or
  automatic mode is on and RevEmu flagged it as VAC-banned (and it is not an admin), the
  return value is changed to 0. The engine then goes on as for any other player.
The gamedata (addons/sourcemod/gamedata/unvac.games.txt) holds the engine symbol, the
function prototype and the vtable offset.

## Security notes
- The plugin admits a SteamID, not a ticket: anybody who announces a listed (or
  RevEmu-flagged) SteamID is admitted, even with a ticket that does not validate. Keep
  the list to accounts you know.
- Result 1 is the same for a VAC ban and for any other bad ticket, so it is never turned
  into OK for everybody: that would make every SteamID easy to spoof, admins included.
- If your admins are recognised by SteamID and you let no-Steam or VAC-banned clients in,
  protect them with an admin password (admins_simple.ini third field + PassInfoVar in
  core.cfg): https://wiki.alliedmods.net/Adding_Admins_(SourceMod)
- Keep an anti-cheat running (SMAC or similar): a VAC ban is a cheat ban.

## Troubleshooting
- "sm plugins list" shows UnVAC as Failed / Error: read addons/sourcemod/logs/errors_*.log.
     "Missing gamedata unvac.games.txt" or "Offset BeginAuthSession missing":
        addons/sourcemod/gamedata/unvac.games.txt was not copied (or is an older one).
     "CSteam3Server::NotifyClientConnect not found in the engine":
        not a Linux srcds, or the engine no longer carries its symbols, or another game.
     "Could not hook CSteam3Server::NotifyClientConnect": the function exists but DHooks
        refused it; send me the errors_*.log lines.
- A VAC-banned player is still refused and nothing is logged:
     - "sm_unvac_list" shows the mode and the list. In manual mode the SteamID must be in it.
     - The server console must show "S3: Client connected with invalid ticket". With another
       message (duplicate connection, wrong game, old version) the result is not 1 and the
       plugin leaves it alone on purpose.
     - Automatic mode: check that rev-client.log exists in the server folder (next to
       srcds_run), that rev.ini has Logging=True in [steamclient], and that it contains a
       "UserConnect SteamID = STEAM_0:Y:Z (...)  VAC status: banned" line for this account.
       An admin SteamID is never let in by the automatic mode (add it to the list if you
       really want it).
- The player joins but without his admin rights: normal if you use admin passwords and he
  did not give his setinfo; see "Security notes".

## Changelog
- **1.2.0**: `sm_unvac_mode` (0 manual / 1 automatic) replaces `sm_unvac_all`; `sm_unvac_list` shows the mode.
- **1.1.0**: automatic mode: accounts RevEmu reports as VAC-banned; admins excluded.
- **1.0.0**: first version: list of SteamIDs, hook on BeginAuthSession.

## Credits
- UnVAC 0.0.6 by asherkin (Asher Baker), the idea and the commands. No code of it is used
  (it was never released); this one was written from scratch.
- SourceMod / DHooks: https://github.com/alliedmodders/sourcemod/blob/master/plugins/include/dhooks.inc
- Steamworks documentation (BeginAuthSession): https://partner.steamgames.com/doc/api/ISteamGameServer

## License

[GNU GPL v3](LICENSE), like SourceMod.
