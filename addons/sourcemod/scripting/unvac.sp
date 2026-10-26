/**
 * UnVAC — Panda Zriot eXtrem
 * Lets chosen VAC-banned players in while the server stays VAC secure for everyone else.
 * Replaces UnVAC 0.0.6 by asherkin (2011): a closed-source Metamod plugin, it no longer loads, and
 * the SteamTools / SteamWorks extensions never exposed a way to turn a Steam refusal into an approval.
 *
 * How it works: for each connecting client the engine (CSteam3Server::NotifyClientConnect) asks
 * ISteamGameServer::BeginAuthSession about the ticket and refuses the client unless the result is OK.
 * Here a VAC-banned account comes back from that call as 1 (invalid ticket), before any answer from
 * the Steam servers: the engine prints "S3: Client connected with invalid ticket" and drops the client.
 * This plugin hooks that call and turns the 1 into a 0 (OK) for the SteamIDs of the list only,
 * the engine then goes on exactly as for any other player. Nobody else is affected.
 *
 * Who is let through (the result 1 is the same for a VAC ban and for any other bad ticket, so it is
 * never turned into OK for everybody, that would make every SteamID, admins included, easy to spoof):
 *  - the SteamIDs of the list (sm_unvac_add), whatever the reason of the refusal;
 *  - in automatic mode (sm_unvac_mode 1), any account that RevEmu itself reports as "VAC status: banned"
 *    in its rev-client.log (rev.ini: Logging=True), admins excepted (an admin SteamID is never let in this way).
 * Manual mode (sm_unvac_mode 0) lets in the list only.
 * Both let in the SteamID, not the ticket: someone who claims such a SteamID with a ticket that fails is
 * admitted too. Keep the list to the few accounts you know.
 *
 * Commands (root admins or RCON): sm_unvac_add "<SteamID>", sm_unvac_remove "<SteamID>", sm_unvac_list.
 * The list is kept in addons/sourcemod/data/unvac_whitelist.txt (not touched by a restart).
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <dhooks>

#define WHITELIST_FILE "data/unvac_whitelist.txt"

// RevEmu log, in the server folder (the paths of the file functions start in cstrike/); only its end is read
#define REV_LOG_FILE "../rev-client.log"
#define REV_LOG_TAIL 16384

// sm_unvac_mode
#define MODE_MANUAL     0
#define MODE_AUTOMATIC  1

// EBeginAuthSessionResult
#define AUTH_RESULT_OK              0
#define AUTH_RESULT_INVALID_TICKET  1

public Plugin myinfo =
{
    name = "UnVAC",
    author = "Panda Zriot eXtrem",
    description = "Lets chosen VAC-banned SteamIDs in, VAC stays active for everyone else",
    version = "1.2.0",
    url = ""
};

ConVar g_cvMode;
ArrayList g_Allowed;            // account IDs (32 bits) of the SteamIDs that may join
DynamicHook g_AuthHook;         // ISteamGameServer::BeginAuthSession
DynamicDetour g_Detour;         // CSteam3Server::NotifyClientConnect, only to find the ISteamGameServer
Address g_SteamServer;          // the ISteamGameServer currently hooked
int g_AuthHookId = INVALID_HOOK_ID;

public void OnPluginStart()
{
    GameData gd = new GameData("unvac.games");
    if (gd == null)
        SetFailState("Missing gamedata unvac.games.txt");

    g_Detour = DynamicDetour.FromConf(gd, "CSteam3Server::NotifyClientConnect");
    int offset = gd.GetOffset("BeginAuthSession");
    delete gd;
    if (g_Detour == null)
        SetFailState("CSteam3Server::NotifyClientConnect not found in the engine");
    if (offset < 1)
        SetFailState("Offset BeginAuthSession missing in unvac.games.txt");
    if (!g_Detour.Enable(Hook_Pre, Detour_NotifyClientConnect))
        SetFailState("Could not hook CSteam3Server::NotifyClientConnect");

    // BeginAuthSession(const void *ticket, int ticketLength, CSteamID id): the 64-bit id is two ints on the stack
    g_AuthHook = new DynamicHook(offset, HookType_Raw, ReturnType_Int, ThisPointer_Ignore);
    g_AuthHook.AddParam(HookParamType_Int);
    g_AuthHook.AddParam(HookParamType_Int);
    g_AuthHook.AddParam(HookParamType_Int);
    g_AuthHook.AddParam(HookParamType_Int);

    g_cvMode = CreateConVar("sm_unvac_mode", "1", "0 = manual: only the SteamIDs added with sm_unvac_add may join despite a VAC ban, 1 = automatic: every VAC-banned account may join (admins excepted)", _, true, 0.0, true, 1.0);
    AutoExecConfig(true, "unvac");

    g_Allowed = new ArrayList();
    LoadList();

    RegAdminCmd("sm_unvac_add", Cmd_Add, ADMFLAG_ROOT, "sm_unvac_add \"<SteamID>\" - lets a VAC-banned SteamID in");
    RegAdminCmd("sm_unvac_remove", Cmd_Remove, ADMFLAG_ROOT, "sm_unvac_remove \"<SteamID>\" - back to the normal VAC check");
    RegAdminCmd("sm_unvac_list", Cmd_List, ADMFLAG_ROOT, "sm_unvac_list - SteamIDs let in despite a VAC ban");
}

public void OnPluginEnd()
{
    if (g_AuthHookId != INVALID_HOOK_ID)
        DynamicHook.RemoveHook(g_AuthHookId);
    g_Detour.Disable(Hook_Pre, Detour_NotifyClientConnect);
}

// ── Engine hooks ─────────────────────────────────────────────────────

// The ISteamGameServer pointer is at this + 4; hooked as soon as the first client connects (and again if
// Steam is restarted and the object changes), always before the engine calls BeginAuthSession
public MRESReturn Detour_NotifyClientConnect(Address pThis, DHookReturn hReturn, DHookParam hParams)
{
    Address steamServer = view_as<Address>(LoadFromAddress(pThis + view_as<Address>(4), NumberType_Int32));
    if (steamServer == Address_Null || steamServer == g_SteamServer)
        return MRES_Ignored;

    if (g_AuthHookId != INVALID_HOOK_ID)
        DynamicHook.RemoveHook(g_AuthHookId);
    g_AuthHookId = g_AuthHook.HookRaw(Hook_Post, steamServer, Hook_BeginAuthSession);
    g_SteamServer = steamServer;
    return MRES_Ignored;
}

public MRESReturn Hook_BeginAuthSession(DHookReturn hReturn, DHookParam hParams)
{
    if (hReturn.Value != AUTH_RESULT_INVALID_TICKET)
        return MRES_Ignored;

    // Low 32 bits of the 64-bit SteamID = account ID
    int accountId = hParams.Get(3);
    char steamId[32];
    AccountToSteamId(accountId, steamId, sizeof(steamId));

    if (g_Allowed.FindValue(accountId) != -1)
        LogMessage("%s refused by the Steam check (invalid ticket): let in, he is in the UnVAC list", steamId);
    else if (g_cvMode.IntValue == MODE_AUTOMATIC && !IsAdminAccount(accountId) && IsVacBannedInRevLog(steamId))
        LogMessage("%s refused by the Steam check (VAC ban reported by RevEmu): let in (automatic mode)", steamId);
    else
        return MRES_Ignored;

    hReturn.Value = AUTH_RESULT_OK;
    return MRES_Override;
}

// An admin SteamID must never be let in on the strength of a log line: SteamIDs are public
bool IsAdminAccount(int accountId)
{
    char identity[32];
    FormatEx(identity, sizeof(identity), "STEAM_0:%d:%d", accountId & 1, accountId >>> 1);
    if (FindAdminByIdentity(AUTHMETHOD_STEAM, identity) != INVALID_ADMIN_ID)
        return true;
    identity[6] = '1';      // STEAM_1:Y:Z, the other spelling of the same account
    if (FindAdminByIdentity(AUTHMETHOD_STEAM, identity) != INVALID_ADMIN_ID)
        return true;
    FormatEx(identity, sizeof(identity), "[U:1:%u]", accountId);
    return FindAdminByIdentity(AUTHMETHOD_STEAM, identity) != INVALID_ADMIN_ID;
}

// RevEmu writes "UserConnect SteamID = STEAM_0:1:1234567 (234)  VAC status: banned" for such an account
bool IsVacBannedInRevLog(const char[] steamId)
{
    File file = OpenFile(REV_LOG_FILE, "r");
    if (file == null)
        return false;

    file.Seek(0, SEEK_END);
    int size = file.Position;
    file.Seek(size > REV_LOG_TAIL ? size - REV_LOG_TAIL : 0, SEEK_SET);

    char needle[48];
    FormatEx(needle, sizeof(needle), "SteamID = %s (", steamId);
    char line[256];
    bool banned = false;
    while (!banned && file.ReadLine(line, sizeof(line)))
        banned = StrContains(line, needle) != -1 && StrContains(line, "VAC status: banned") != -1;
    delete file;
    return banned;
}

// ── Commands ─────────────────────────────────────────────────────────

public Action Cmd_Add(int client, int args)
{
    int accountId;
    if (!ReadSteamIdArg(client, args, "sm_unvac_add", accountId))
        return Plugin_Handled;

    char steamId[32];
    AccountToSteamId(accountId, steamId, sizeof(steamId));
    if (g_Allowed.FindValue(accountId) != -1)
    {
        ReplyToCommand(client, "[UnVAC] %s is already in the list", steamId);
        return Plugin_Handled;
    }
    g_Allowed.Push(accountId);
    SaveList();
    ReplyToCommand(client, "[UnVAC] %s added: he can join even with a VAC ban", steamId);
    return Plugin_Handled;
}

public Action Cmd_Remove(int client, int args)
{
    int accountId;
    if (!ReadSteamIdArg(client, args, "sm_unvac_remove", accountId))
        return Plugin_Handled;

    char steamId[32];
    AccountToSteamId(accountId, steamId, sizeof(steamId));
    int index = g_Allowed.FindValue(accountId);
    if (index == -1)
    {
        ReplyToCommand(client, "[UnVAC] %s is not in the list", steamId);
        return Plugin_Handled;
    }
    g_Allowed.Erase(index);
    SaveList();
    ReplyToCommand(client, "[UnVAC] %s removed: normal VAC check again", steamId);
    return Plugin_Handled;
}

public Action Cmd_List(int client, int args)
{
    ReplyToCommand(client, "[UnVAC] Mode: %s (sm_unvac_mode)", g_cvMode.IntValue == MODE_AUTOMATIC
        ? "automatic, every VAC-banned account may join (admins excepted)" : "manual, only the list below may join");
    if (g_Allowed.Length == 0)
    {
        ReplyToCommand(client, "[UnVAC] No SteamID in the list");
        return Plugin_Handled;
    }
    ReplyToCommand(client, "[UnVAC] SteamIDs let in despite a VAC ban:");
    char steamId[32];
    for (int i = 0; i < g_Allowed.Length; i++)
    {
        AccountToSteamId(g_Allowed.Get(i), steamId, sizeof(steamId));
        ReplyToCommand(client, "  %d: %s", i + 1, steamId);
    }
    return Plugin_Handled;
}

bool ReadSteamIdArg(int client, int args, const char[] command, int &accountId)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[UnVAC] Usage: %s \"STEAM_0:1:1234567\" (or \"[U:1:2468135]\")", command);
        return false;
    }
    char arg[64];
    GetCmdArgString(arg, sizeof(arg));
    StripQuotes(arg);
    if (!ParseSteamId(arg, accountId))
    {
        ReplyToCommand(client, "[UnVAC] SteamID invalid: use STEAM_0:Y:Z or [U:1:N], with quotes");
        return false;
    }
    return true;
}

// ── SteamIDs and list file ───────────────────────────────────────────

// STEAM_X:Y:Z (X is 0 or 1 depending on the tool, ignored) or [U:1:N] -> 32-bit account ID
bool ParseSteamId(const char[] input, int &accountId)
{
    char text[64];
    strcopy(text, sizeof(text), input);
    TrimString(text);

    char parts[3][16];
    if (StrContains(text, "STEAM_", false) == 0)
    {
        if (ExplodeString(text, ":", parts, sizeof(parts), sizeof(parts[])) != 3)
            return false;
        int y = StringToInt(parts[1]);
        int z = StringToInt(parts[2]);
        if ((y != 0 && y != 1) || z < 0 || !IsDigits(parts[1]) || !IsDigits(parts[2]))
            return false;
        accountId = z * 2 + y;
        return accountId != 0;
    }

    int length = strlen(text);
    if (StrContains(text, "[U:1:") == 0 && length > 6 && text[length - 1] == ']')
    {
        text[length - 1] = '\0';
        if (!IsDigits(text[5]))
            return false;
        accountId = StringToInt(text[5]);
        return accountId > 0;
    }
    return false;
}

bool IsDigits(const char[] text)
{
    if (text[0] == '\0')
        return false;
    for (int i = 0; text[i] != '\0'; i++)
    {
        if (text[i] < '0' || text[i] > '9')
            return false;
    }
    return true;
}

void AccountToSteamId(int accountId, char[] buffer, int maxlen)
{
    FormatEx(buffer, maxlen, "STEAM_0:%d:%d", accountId & 1, accountId >>> 1);
}

void LoadList()
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), WHITELIST_FILE);
    File file = OpenFile(path, "r");
    if (file == null)
        return;

    char line[128];
    while (file.ReadLine(line, sizeof(line)))
    {
        int comment = StrContains(line, "//");
        if (comment != -1)
            line[comment] = '\0';
        TrimString(line);
        if (line[0] == '\0')
            continue;

        int accountId;
        if (!ParseSteamId(line, accountId))
        {
            LogError("%s: ignored line \"%s\" (not a SteamID)", WHITELIST_FILE, line);
            continue;
        }
        if (g_Allowed.FindValue(accountId) == -1)
            g_Allowed.Push(accountId);
    }
    delete file;
}

void SaveList()
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), WHITELIST_FILE);
    File file = OpenFile(path, "w");
    if (file == null)
    {
        LogError("Could not write %s", path);
        return;
    }

    file.WriteLine("// UnVAC: SteamIDs let in despite a VAC ban, one per line (sm_unvac_add / sm_unvac_remove)");
    char steamId[32];
    for (int i = 0; i < g_Allowed.Length; i++)
    {
        AccountToSteamId(g_Allowed.Get(i), steamId, sizeof(steamId));
        file.WriteLine("%s", steamId);
    }
    delete file;
}
