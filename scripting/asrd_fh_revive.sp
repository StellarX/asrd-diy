// asrd_fh_revive.sp
// 玩家战死后, 在聊天框输入 /fh 或 /FH 可复活并重新加入战斗, 每局每人仅一次.
// 依赖: SourceMod 1.10+
// 编译: spcomp scripting/asrd_fh_revive.sp  ->  plugins/asrd_fh_revive.smx
// 安装: 放到 addons/sourcemod/plugins/, 配置写入 cfg/sourcemod/fh_revive.cfg
// 配置 ConVar 前缀: fh_
//
// 注意: 下面标 [需核实] 的三处请对照你服务器的实际行为确认, 见文件末尾说明.

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <admin>

public Plugin myinfo =
{
    name        = "FH 一次性复活",
    author      = "asrd-plugins",
    description = "玩家战死后输入 /fh 复活一次重新加入战斗 (每局每人仅一次)",
    version     = "1.1.0",
    url         = ""
};

ConVar g_cvEnabled;        // 总开关
ConVar g_cvResetMode;      // 0=每局/每图只能一次(符合需求); 1=每次重生刷新(测试用)
ConVar g_cvRespawnCmd;     // [需核实1] 服务器自己的“复活”控制台命令
ConVar g_cvRespawnServer;  // [需核实1] 是否用 ServerCommand 以 root 执行(部分命令不接受客户端触发)
ConVar g_cvAnnounce;       // 死亡时是否提示玩家可以 /fh
ConVar g_cvConfirm;        // 复活确认窗口(秒), 超时仍没活则归还本次机会

bool g_bUsed[MAXPLAYERS + 1];   // 本局是否已用掉复活
bool g_bDead[MAXPLAYERS + 1];   // 是否为死亡状态 (用 player_death 事件判定, 不依赖 IsPlayerAlive)

public void OnPluginStart()
{
    LoadTranslations("common.phrases");

    g_cvEnabled       = CreateConVar("fh_enabled", "1", "启用 /fh 一次性复活", FCVAR_NOTIFY);
    g_cvResetMode     = CreateConVar("fh_reset_mode", "0", "0=每局每人仅一次; 1=每次重生后重置(仅供测试)", _, true, 0.0, true, 1.0);
    g_cvRespawnCmd    = CreateConVar("fh_respawn_cmd", "respawn", "执行复活的命令, 由玩家身份或 ServerCommand 触发");
    g_cvRespawnServer = CreateConVar("fh_respawn_as_server", "0", "1=用 ServerCommand 执行(对命令名追加玩家id); 0=以玩家身份 FakeClientCommand", _, true, 0.0, true, 1.0);
    g_cvAnnounce      = CreateConVar("fh_announce", "1", "死亡时提示可输入 /fh 复活一次", _, true, 0.0, true, 1.0);
    g_cvConfirm       = CreateConVar("fh_confirm_time", "1.0", "执行复活后等待确认是否为存活状态(秒), 超时未复活则归还次数", _, true, 0.0, true, 10.0);

    RegConsoleCmd("sm_fh", Cmd_FH, "玩家聊天框输入 /fh 或 /FH 复活一次");
    RegAdminCmd("sm_fh_test", Cmd_FH_Test, ADMFLAG_GENERIC, "管理员测试: 直接对某个玩家执行复活命令");

    // 聊天指令映射: SourceMod 会把 /fh、/FH、!fh 都解析到 sm_fh (大小写不敏感).

    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
    HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
    HookEvent("round_start",  Event_RoundStart,  EventHookMode_PostNoCopy);  // [需核实2] RD 若无此事件请删掉这行
    HookEvent("round_end",    Event_RoundEnd,    EventHookMode_PostNoCopy);

    AutoExecConfig(true, "fh_revive");
}

public void OnMapStart()
{
    // 新地图: 重置所有人机会 (per-round 语义)
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bUsed[i] = false;
        g_bDead[i] = false;
    }
}

public void OnClientDisconnect(int client)
{
    g_bUsed[client] = false;
    g_bDead[client] = false;
}

// ---------- 聊天指令 ----------
public Action Cmd_FH(int client, int args)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
        return Plugin_Handled;

    if (!g_cvEnabled.BoolValue)
    {
        ReplyToCommand(client, " /fh 复活功能已关闭.");
        return Plugin_Handled;
    }

    if (g_bUsed[client])
    {
        PrintToChat(client, " [FH] 你本局已经复活过一次, 不能再次使用 /fh.");
        return Plugin_Handled;
    }

    // 以 player_death 事件标记为准判定死亡.
    // AS:RD 里阵亡后玩家实体可能仍被 IsPlayerAlive 判为存活, 所以不能只用它.
    if (!g_bDead[client] && IsPlayerAlive(client))
    {
        PrintToChat(client, " [FH] 你还活着, 不需要复活.");
        return Plugin_Handled;
    }

    DoRevive(client);
    return Plugin_Handled;
}

// 管理员/测试入口: sm_fh_test <名字|#userid>
public Action Cmd_FH_Test(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "用法: sm_fh_test <玩家>");
        return Plugin_Handled;
    }
    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));
    int target = FindTarget(client, arg, true, false);
    if (target == -1)
        return Plugin_Handled;

    DoRevive(target);
    return Plugin_Handled;
}

// ---------- 核心: 执行复活 ----------
void DoRevive(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
        return;

    g_bUsed[client] = true;   // 立即占用本次机会; 若确认未生效会归还

    char cmd[128];
    g_cvRespawnCmd.GetString(cmd, sizeof(cmd));
    if (cmd[0] == '\0')
    {
        PrintToChat(client, " [FH] 复活命令未配置, 请联系管理员 (fh_respawn_cmd).");
        g_bUsed[client] = false;
        return;
    }

    if (g_cvRespawnServer.BoolValue)
    {
        // 以服务器 root 执行, 部分命令需要带玩家 id
        char arg[32];
        Format(arg, sizeof(arg), "%d", GetClientUserId(client));
        ServerCommand("%s %s", cmd, arg);
        ServerExecute();
    }
    else
    {
        // 以该玩家身份执行 (Source 常见 client 命令如 respawn)
        FakeClientCommand(client, "%s", cmd);
    }

    // 广播
    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
            PrintToChat(i, " [FH] %s 已使用 /fh 复活, 本局将无法再次使用.", name);
    }

    // 延迟确认: 若命令没生效(玩家仍死), 把机会还给他并提示管理员
    DataPack pack = new DataPack();
    pack.WriteCell(client);
    CreateTimer(g_cvConfirm.FloatValue, Timer_ConfirmRevive, pack, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ConfirmRevive(Handle timer, DataPack pack)
{
    ResetPack(pack);
    int client = pack.ReadCell();
    delete pack;

    if (client < 1 || client > MaxClients || !IsClientInGame(client))
        return Plugin_Stop;

    if (!IsPlayerAlive(client) && g_bUsed[client])
    {
        // 命令没生效 -> 归还机会, 提示管理员检查 fh_respawn_cmd
        g_bUsed[client] = false;
        char cmd[64];
        g_cvRespawnCmd.GetString(cmd, sizeof(cmd));
        LogError("[FH] 复活命令 '%s' 未让玩家 %L 复活, 请核实 fh_respawn_cmd / fh_respawn_as_server.",
                 cmd, client);
        PrintToChat(client, " [FH] 复活未生效, 你的 /fh 机会已保留. 请联系管理员检查复活命令配置.");
    }
    return Plugin_Stop;
}

// ---------- 事件 ----------
public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (victim < 1 || victim > MaxClients || !IsClientInGame(victim))
        return;

    g_bDead[victim] = true;   // 记录死亡状态(复活判定依据)
    if (!g_cvEnabled.BoolValue || g_bUsed[victim])
        return;
    if (!g_cvAnnounce.BoolValue)
        return;
    PrintToChat(victim, " [FH] 你阵亡了! 输入 /fh 可复活并重新加入战斗 (每局仅一次).");
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || client > MaxClients)
        return;

    g_bDead[client] = false;   // 已回到战场, 清除死亡状态

    // 复活成功(玩家已回到战场): 若确认成功, 次数保持已用, 保证“每局仅一次”.
    // fh_reset_mode=1 仅供测试时刷新.
    if (g_cvResetMode.IntValue == 1)
        g_bUsed[client] = false;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bUsed[i] = false;
        g_bDead[i] = false;
    }
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    // 预留给需要“当局结束立即重置”的模式; 默认每局开始/新地图重置已够.
}
