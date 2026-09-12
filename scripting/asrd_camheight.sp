/**
 * ============================================================================
 *  [AS:RD] 视角高度 (Camera Height / 拉近拉远视野)
 *  版本 1.0.1  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ─────────────────────────────────────
 *  AS:RD 是俯视角射击游戏, 玩家看到的范围由"海军陆战队相机"决定。
 *  相机的核心 ConVar(引擎相机系统, 见 asw_in_camera.cpp):
 *    asw_cam_marine_dist   相机离 marine 的距离(默认 412, 同时决定高度+远近)
 *    asw_cam_marine_pitch  相机俯仰角(默认 60; 0=贴地, 90=正俯视)
 *  这两个 ConVar 在 RD 7.x 里带 "cheat","cl","rep","sv" 标志 —— 即服务端
 *  可复制(server+replicated)。本插件用 SendConVarValue 把自定义值
 *  **强制**下发到每个客户端(无视客户端 sv_cheats), 从而抬高视角,
 *  让玩家看到更多地图信息。
 *
 *  ── 玩家命令 (控制台输入, 或聊天栏加 ! 前缀) ───────────
 *   sm_camheight <距离>   设置自己的视角高度(相机距离), 例: sm_camheight 600
 *                        距离越大越高越远, 看到的地图越多(范围见下方 ConVar)
 *   sm_camheight reset    恢复为服务器默认高度
 *
 *  ── 管理员命令 (需 ADMFLAG_GENERIC) ────────────────────
 *   sm_cam_set <玩家> <距离>   给指定玩家设置视角高度
 *   sm_cam_status              列出所有玩家当前视角高度
 *
 *  ── 常用 ConVar (自动生成 cfg/sourcemod/asrd_camheight.cfg) ─
 *   sm_asrd_cam_enabled   总开关 (0=关 1=开, 默认 1)
 *   sm_asrd_cam_dist      服务器默认相机距离/高度(默认 412, 与游戏原生默认值一致; 越大越高越远)
 *   sm_asrd_cam_pitch     服务器默认俯仰角(默认 60, 30~89; 越小越接近正俯视)
 *   sm_asrd_cam_min       玩家可设置的最小距离(默认 200)
 *   sm_asrd_cam_max       玩家可设置的最大距离(默认 1500)
 *   sm_asrd_cam_public    允许普通玩家用 sm_camheight 自定义(0=仅管理员 1=公开)
 *   sm_asrd_cam_debug     调试输出(默认 0)
 *
 *  ── 实现原理 / 坑 ─────────────────────────────────────
 *   - asw_cam_marine_dist / _pitch 是 cheat 标记 ConVar, 玩家自己在控制台
 *     改不了(需要 sv_cheats); 但本插件用 SendConVarValue 由服务端"强制复制"
 *     给指定客户端, 走的是复制通道而非本地 set, 因此客户端无需开 sv_cheats。
 *   - 不用 ConVar.SetValue 改服务端全局值: 那是"同一值广播给所有人", 会覆盖
 *     逐人自定义。本插件对"每个客户端单独发值", 既能服务器统一默认, 又能逐人覆盖。
 *   - 换图 / 引擎 newmapsettings.cfg 可能把相机 ConVar 重置回 412, 所以
 *     用 3 秒周期重新下发(OnMapStart + OnClientPutInServer + 周期定时器三重保险)。
 *
 *  依赖: SourceMod 1.11+ (仅核心 API, 无需扩展)
 * ============================================================================
 */

#include <sourcemod>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] Camera Height"
#define PLUGIN_VERSION "1.0.1"

// 引擎相机 ConVar 名(RD 7.x 实测存在, 带 cheat+cl+rep+sv 标志)
#define CVAR_CAM_DIST  "asw_cam_marine_dist"
#define CVAR_CAM_PITCH "asw_cam_marine_pitch"

// 重新下发周期(秒): 应对换图 / newmapsettings.cfg 把相机 ConVar 重置
#define REASSERT_INTERVAL 3.0

// ─── ConVar 句柄 ──────────────────────────────────────
ConVar g_cvEnabled;
ConVar g_cvDist;
ConVar g_cvPitch;
ConVar g_cvMin;
ConVar g_cvMax;
ConVar g_cvPublic;
ConVar g_cvDebug;

// 引擎相机 ConVar 句柄(找不到则功能不可用)
ConVar g_hCamDist  = null;
ConVar g_hCamPitch = null;

// 每玩家自定义距离(0=用服务器默认)
float g_fCustomDist[MAXPLAYERS + 1];

Handle g_hReassert = null;

// ============================================================================
//  插件信息
// ============================================================================
public Plugin myinfo =
{
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "抬高(可调)玩家视角高度, 看到更多地图; 逐人自定义",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
//  插件启动
// ============================================================================
public void OnPluginStart()
{
    for (int i = 1; i <= MaxClients; i++)
        g_fCustomDist[i] = 0.0;

    g_cvEnabled = CreateConVar("sm_asrd_cam_enabled", "1",
        "[AS:RD] 视角高度 总开关 (0=关 1=开)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvDist = CreateConVar("sm_asrd_cam_dist", "412",
        "[AS:RD] Server default camera distance/height (world units). Native game default is 412; larger = higher & sees more map", FCVAR_NOTIFY, true, 100.0, true, 3000.0);
    g_cvPitch = CreateConVar("sm_asrd_cam_pitch", "60",
        "[AS:RD] 服务器默认相机俯仰角(30~89, 越小越接近正俯视)", FCVAR_NOTIFY, true, 30.0, true, 89.0);
    g_cvMin = CreateConVar("sm_asrd_cam_min", "200",
        "[AS:RD] 玩家可设置的最小相机距离", FCVAR_NOTIFY, true, 100.0, true, 3000.0);
    g_cvMax = CreateConVar("sm_asrd_cam_max", "1500",
        "[AS:RD] 玩家可设置的最大相机距离", FCVAR_NOTIFY, true, 100.0, true, 5000.0);
    g_cvPublic = CreateConVar("sm_asrd_cam_public", "1",
        "[AS:RD] 允许普通玩家用 sm_camheight 自定义高度 (0=仅管理员 1=公开)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvDebug = CreateConVar("sm_asrd_cam_debug", "0",
        "[AS:RD] 调试输出到服务器控制台 (0=关 1=开)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    CreateConVar("sm_asrd_cam_version", PLUGIN_VERSION,
        "[AS:RD] 视角高度 插件版本号", FCVAR_NOTIFY);

    RegConsoleCmd("sm_camheight",  Cmd_CamHeight,  "设置自己的视角高度: sm_camheight <距离> | sm_camheight reset");
    RegAdminCmd("sm_cam_set",     Cmd_CamSet,     ADMFLAG_GENERIC, "给指定玩家设置视角高度: sm_cam_set <玩家> <距离>");
    RegAdminCmd("sm_cam_status",  Cmd_CamStatus,  ADMFLAG_GENERIC, "列出所有玩家当前视角高度");

    AutoExecConfig(true, "asrd_camheight");

    // 缓存引擎相机 ConVar 句柄(必须在 OnPluginStart 早期拿到, 后续靠它下发)
    g_hCamDist  = FindConVar(CVAR_CAM_DIST);
    g_hCamPitch = FindConVar(CVAR_CAM_PITCH);
    if (g_hCamDist == null || g_hCamPitch == null)
    {
        LogError("[视角] 未找到引擎相机 ConVar (%s / %s), 本插件将无法工作! 确认运行在 AS:RD 上。",
            CVAR_CAM_DIST, CVAR_CAM_PITCH);
    }
}

// 配置加载完后再开周期定时器(避免重复创建)
public void OnConfigsExecuted()
{
    if (g_hReassert != null)
    {
        KillTimer(g_hReassert);
        g_hReassert = null;
    }
    g_hReassert = CreateTimer(REASSERT_INTERVAL, Timer_ReassertAll, _, TIMER_REPEAT);
    CreateTimer(0.5, Timer_ReassertAll);   // 立即先发一轮
}

public void OnMapStart()
{
    // 换图后游戏/newmapsettings.cfg 可能把相机 ConVar 重置, 延迟补发
    CreateTimer(0.5, Timer_ReassertAll);
}

public void OnClientPutInServer(int client)
{
    // 玩家进入服务器即下发其(默认或自定义)视角高度
    if (IsClientInGame(client) && !IsFakeClient(client))
        ApplyClient(client);
}

public void OnPluginEnd()
{
    if (g_hReassert != null)
    {
        KillTimer(g_hReassert);
        g_hReassert = null;
    }
}

// ============================================================================
//  周期把所有在线玩家(重新)下发视角高度
// ============================================================================
public Action Timer_ReassertAll(Handle timer)
{
    if (!g_cvEnabled.BoolValue || g_hCamDist == null)
        return Plugin_Continue;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
            ApplyClient(i);
    }
    return Plugin_Continue;
}

// ============================================================================
//  把某玩家的视角高度下发到其客户端(核心: 逐人 SendConVarValue)
// ============================================================================
void ApplyClient(int client)
{
    if (g_hCamDist == null || g_hCamPitch == null)
        return;
    if (!IsClientInGame(client) || IsFakeClient(client))
        return;

    float fDist  = (g_fCustomDist[client] > 1.0) ? g_fCustomDist[client] : g_cvDist.FloatValue;
    float fPitch = g_cvPitch.FloatValue;

    char sDist[16], sPitch[16];
    FormatEx(sDist,  sizeof(sDist),  "%.0f", fDist);
    FormatEx(sPitch, sizeof(sPitch), "%.0f", fPitch);

    // SendConVarValue: 服务端强制该客户端采用下发的值(走复制通道, 无视客户端 sv_cheats)
    SendConVarValue(client, g_hCamDist,  sDist);
    SendConVarValue(client, g_hCamPitch, sPitch);

    if (g_cvDebug.BoolValue)
        PrintToServer("[视角] 下发 %N: dist=%.0f pitch=%.0f (自定义=%.0f)",
            client, fDist, fPitch, g_fCustomDist[client]);
}

// ============================================================================
//  玩家命令: sm_camheight <距离> | sm_camheight reset
// ============================================================================
public Action Cmd_CamHeight(int client, int args)
{
    if (!g_cvEnabled.BoolValue)
    {
        ReplyToCommand(client, "[视角] 功能已关闭");
        return Plugin_Handled;
    }
    if (client <= 0 || !IsClientInGame(client))
        return Plugin_Handled;
    if (!g_cvPublic.BoolValue && !CheckCommandAccess(client, "sm_camheight", ADMFLAG_GENERIC))
    {
        ReplyToCommand(client, "[视角] 自定义高度仅对管理员开放");
        return Plugin_Handled;
    }

    if (args < 1)
    {
        ReplyToCommand(client, "[视角] 用法: sm_camheight <距离> (例 600) | sm_camheight reset");
        return Plugin_Handled;
    }

    char sArg[32];
    GetCmdArg(1, sArg, sizeof(sArg));

    if (StrEqual(sArg, "reset", false))
    {
        g_fCustomDist[client] = 0.0;
        ApplyClient(client);
        PrintToChat(client, "\x04[视角]\x01 已恢复为服务器默认高度 \x05%.0f\x01", g_cvDist.FloatValue);
        return Plugin_Handled;
    }

    float fVal = StringToFloat(sArg);
    if (fVal <= 0.0)
    {
        ReplyToCommand(client, "[视角] 距离必须是正数");
        return Plugin_Handled;
    }

    float fMin = g_cvMin.FloatValue;
    float fMax = g_cvMax.FloatValue;
    if (fVal < fMin) fVal = fMin;
    if (fVal > fMax) fVal = fMax;

    g_fCustomDist[client] = fVal;
    ApplyClient(client);
    PrintToChat(client, "\x04[视角]\x01 你的视角高度已设为 \x05%.0f\x01 (范围 %.0f~%.0f, 越大越高越远)",
        fVal, fMin, fMax);
    return Plugin_Handled;
}

// ============================================================================
//  管理员命令: sm_cam_set <玩家> <距离>
// ============================================================================
public Action Cmd_CamSet(int client, int args)
{
    if (!g_cvEnabled.BoolValue)
    {
        ReplyToCommand(client, "[视角] 功能已关闭");
        return Plugin_Handled;
    }
    if (args < 2)
    {
        ReplyToCommand(client, "用法: sm_cam_set <玩家> <距离>");
        return Plugin_Handled;
    }

    char sTarget[64], sVal[32];
    GetCmdArg(1, sTarget, sizeof(sTarget));
    GetCmdArg(2, sVal, sizeof(sVal));

    int target = FindTargetPlayer(client, sTarget);
    if (target == 0)
        return Plugin_Handled;

    float fVal = StringToFloat(sVal);
    if (fVal <= 0.0)
    {
        ReplyToCommand(client, "[视角] 距离必须是正数");
        return Plugin_Handled;
    }

    float fMin = g_cvMin.FloatValue;
    float fMax = g_cvMax.FloatValue;
    if (fVal < fMin) fVal = fMin;
    if (fVal > fMax) fVal = fMax;

    g_fCustomDist[target] = fVal;
    ApplyClient(target);

    char sName[MAX_NAME_LENGTH];
    GetClientName(target, sName, sizeof(sName));
    if (client > 0)
        PrintToChat(client, "\x04[视角]\x01 已将 \x05%s\x01 的视角高度设为 \x05%.0f\x01", sName, fVal);
    PrintToServer("[视角] 管理员(玩家 %N) 将 %s 视角高度设为 %.0f", client, sName, fVal);
    return Plugin_Handled;
}

// ============================================================================
//  管理员命令: sm_cam_status
// ============================================================================
public Action Cmd_CamStatus(int client, int args)
{
    if (client > 0)
        PrintToChat(client, "\x04[视角]\x01 服务器默认 dist=%.0f pitch=%.0f | 自定义范围 %.0f~%.0f",
            g_cvDist.FloatValue, g_cvPitch.FloatValue, g_cvMin.FloatValue, g_cvMax.FloatValue);

    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;
        count++;
        float fDist = (g_fCustomDist[i] > 1.0) ? g_fCustomDist[i] : g_cvDist.FloatValue;
        char sName[MAX_NAME_LENGTH];
        GetClientName(i, sName, sizeof(sName));
        PrintToConsole(client, "  %s : dist=%.0f %s", sName, fDist,
            (g_fCustomDist[i] > 1.0) ? "(自定义)" : "(默认)");
    }
    if (count == 0 && client > 0)
        PrintToChat(client, "\x04[视角]\x01 当前无真实玩家在线");
    return Plugin_Handled;
}

// ============================================================================
//  按 名字 / 部分名字 / #userid 找一个在线玩家 (找不到或歧义返回 0)
// ============================================================================
int FindTargetPlayer(int client, const char[] szArg)
{
    if (szArg[0] == '#')
    {
        int who = GetClientOfUserId(StringToInt(szArg[1]));
        if (who > 0 && IsClientInGame(who) && !IsFakeClient(who))
            return who;
        ReplyToCommand(client, "[视角] 找不到该 userid 对应的在线玩家");
        return 0;
    }

    int found = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;
        char sName[MAX_NAME_LENGTH];
        GetClientName(i, sName, sizeof(sName));
        if (StrEqual(sName, szArg, false))
            return i;
        if (StrContains(sName, szArg, false) != -1)
        {
            if (found != 0)
            {
                ReplyToCommand(client, "[视角] 匹配到多名玩家, 请用更完整的名字或 #userid");
                return 0;
            }
            found = i;
        }
    }
    if (found == 0)
        ReplyToCommand(client, "[视角] 找不到在线玩家 \"%s\"", szArg);
    return found;
}
