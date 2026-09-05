/**
 * ============================================================================
 *  [AS:RD] 范围击退 (Repulse)
 *  版本 1.2.0  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ──────────────────────────────────────
 *  1. 手动击退: 按绑定键以自己为中心, 把周围虫族沿径向往外推开。
 *     每游戏帧推进(OnGameFrame)并附带速度, 客户端帧间插值 → 短击退也平滑,
 *     推进速度可用时长控制, 不会"瞬移"也不会"一顿一顿"。
 *  2. 持续护盾: (可选) 开启后就像能量斥力场, 自动把靠近你的虫族
 *     缓慢持续往外推, 保持在护盾半径之外。同时也会弹开敌方投射物(炮弹)。
 *
 *  ── 投射物(炮弹) ───────────────────────────────────────
 *   已内置 mortarbug(迫击炮虫)的炮弹 asw_mortarbug_shell。
 *   用"速度弹开"而非 teleport, 防止被投射物原速度拉回。
 *   其余(如 ranger 的酸液)可在 debug 抓到类名后,
 *   追加到 sm_asrd_repulse_projectile_classes 即可。
 *
 *  ── 为什么有些虫打不到? ────────────────────────────────
 *   内置清单包含绝大多数 asw_* 虫族 + 蚁狮 npc_* 变体。
 *   若某个敌人没有效果, 先开 debug 看它到底是哪个实体类名,
 *   再用 sm_asrd_repulse_classes 追加即可, 无需改代码重编译。
 *
 *  ── 按键绑定 ───────────────────────────────────────────
 *  控制台输入:  bind <按键> "sm_repulse"
 *  例如:        bind f "sm_repulse"
 *
 *  ── 命令 ────────────────────────────────────────────────
 *   sm_repulse      手动范围击退 (可绑定按键连按)
 *
 *  ── 常用 ConVar (自动生成 cfg/sourcemod/asrd_repulse.cfg) ──
 *   sm_asrd_repulse_enabled        总开关 (默认 1)
 *   sm_asrd_repulse_public         允许普通玩家使用 (默认 1; 0=仅管理员)
 *   sm_asrd_repulse_radius         手动击退作用半径 (默认 400)
 *   sm_asrd_repulse_force          向外推开的距离/游戏单位 (默认 160)
 *   sm_asrd_repulse_lift           向上挑飞高度/游戏单位 (默认 80)
 *   sm_asrd_repulse_pull_time      单次击退推进时长/秒 (默认 0.35, 越大越慢越平滑)
 *   sm_asrd_repulse_cooldown       两次触发最小间隔秒 (默认 0=无冷却可连按)
 *
 *   sm_asrd_repulse_aura           持续护盾开关 (默认 0)
 *   sm_asrd_repulse_aura_radius    护盾半径/游戏单位 (默认 260)
 *   sm_asrd_repulse_aura_mode      护盾模式 (默认 1: 1=直接阻挡钉在圈外; 0=斥力击退平滑弹开)
 *
 *   sm_asrd_repulse_classes        追加要击退的实体类名 (空格分隔, 空=不追加)
 *   sm_asrd_repulse_debug          调试输出 (默认 0; 1 会列出半径内所有 asw_ 与 npc_ 实体的真实类名)
 *
 *  依赖: SourceMod 1.11+ (核心 + sdktools)
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] 范围击退"
#define PLUGIN_VERSION "1.5.3"

// ─── 平滑推进动画池 (手动击退用) ──
#define MAX_PUSH 512
#define MAX_CUSTOM_CLASSES 32
#define MAX_PROJ_CLASSES 32
int    g_iPushEnt[MAX_PUSH];
float  g_fPushSrc[MAX_PUSH][3];
float  g_fPushDst[MAX_PUSH][3];
float  g_fPushElapsed[MAX_PUSH];
float  g_fPushDur[MAX_PUSH];
float  g_fPushPrev[MAX_PUSH][3];   // 上一帧已应用的位置, 用于计算该帧速度(客户端插值更平滑)
bool   g_bPushActive[MAX_PUSH];
bool   g_bAnyPushActive;           // 是否有任意推进动画在跑, 用于跳过空闲帧
float  g_fLastAuraLog;            // 护盾汇总日志节流
float  g_fLastAuraDump;           // 护盾类名点名节流
float  g_fLastProjLog;            // 投射物 owner 日志节流

// ─── 敌方投射物清单 (用速度弹开, 不用 teleport) ──
// asw_mortarbug_shell = mortarbug(迫击炮虫)的炮弹
// asw_missile_round   = ranger 酸球 + 玩家的导弹/火箭, 共用同一实体!
//   对 asw_missile_round 我们只弹"玩家之外"发射的(owner 是 alien), 避免误伤玩家武器。
// 其余可在 debug 抓到类名后追加
char g_sBuiltinProjClasses[][] =
{
    "asw_mortarbug_shell",
    "asw_missile_round"
};
char g_sProjClasses[MAX_PROJ_CLASSES][64];
int  g_iProjClassCount;

// ─── 内置怪物实体类名清单 ──
// asw_drone_antlion 等 asw_* 虫族 + npc_antlionguard 系列 (RD 的蚁狮用 npc_ 前缀!)
char g_sAlienClasses[][] =
{
    "asw_drone",
    "asw_drone_jumper",
    "asw_drone_uber",
    "asw_drone_antlion",
    "asw_parasite",
    "asw_parasite_defanged",
    "asw_egg",
    "asw_boomer",
    "asw_boomer_blob",
    "asw_buzzer",
    "asw_harvester",
    "asw_mortarbug",
    "asw_ranger",
    "asw_shieldbug",
    "asw_grub",
    "asw_grub_sac",
    "asw_queen",
    "asw_mender",
    "asw_shaman",
    "asw_xenomite",
    "asw_antlion_guard",
    // RD 蚁狮守卫/工蜂真实类名 (npc_ 前缀, 不是 asw_!)
    "npc_antlionguard",
    "npc_antlionguard_cavern",
    "npc_antlionguard_normal",
    "npc_antlion_worker"
};

// 管理员可追加的额外类名
char g_sCustomClasses[MAX_CUSTOM_CLASSES][64];
int  g_iCustomClassCount;

// ─── ConVar 句柄 ─────────────────────────────────────────
ConVar g_cvEnabled;
ConVar g_cvPublic;
ConVar g_cvRadius;
ConVar g_cvForce;
ConVar g_cvLift;
ConVar g_cvPullTime;
ConVar g_cvCooldown;
ConVar g_cvAura;
ConVar g_cvAuraRadius;
ConVar g_cvAuraMode;
ConVar g_cvClasses;
ConVar g_cvProjectiles;
ConVar g_cvProjSpeed;
ConVar g_cvProjClasses;
ConVar g_cvDebug;

// ─── 按玩家激活的护盾 (由管理员命令 sm_repulseaura 指定, 默认全场无护盾) ──
bool g_bAuraOn[MAXPLAYERS + 1];

float g_fLastUse[MAXPLAYERS + 1];   // 手动击退冷却用

// ============================================================================
//  插件信息
// ============================================================================
public Plugin myinfo = {
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "范围击退(平滑推进) + 可选持续斥力护盾",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
//  插件启动
// ============================================================================
public void OnPluginStart()
{
    g_cvEnabled = CreateConVar("sm_asrd_repulse_enabled", "1",
        "启用/禁用范围击退 (0=关 1=开)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvPublic = CreateConVar("sm_asrd_repulse_public", "1",
        "允许普通玩家使用 sm_repulse (1=所有人 0=仅管理员)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvRadius = CreateConVar("sm_asrd_repulse_radius", "400",
        "手动击退作用半径 (游戏单位)", FCVAR_NOTIFY, true, 50.0, true, 3000.0);
    g_cvForce = CreateConVar("sm_asrd_repulse_force", "160",
        "单次击退向外的总位移 (游戏单位)", FCVAR_NOTIFY, true, 0.0, true, 2000.0);
    g_cvLift = CreateConVar("sm_asrd_repulse_lift", "80",
        "单次击退向上挑飞高度 (游戏单位)", FCVAR_NOTIFY, true, 0.0, true, 500.0);
    g_cvPullTime = CreateConVar("sm_asrd_repulse_pull_time", "0.35",
        "单次击退推进时长/秒 (越大越慢越平滑)", FCVAR_NOTIFY, true, 0.05, true, 3.0);
    g_cvCooldown = CreateConVar("sm_asrd_repulse_cooldown", "0",
        "手动触发最小间隔秒 (0=无冷却可连按)", FCVAR_NOTIFY, true, 0.0, true, 60.0);
    g_cvAura = CreateConVar("sm_asrd_repulse_aura", "0",
        "持续斥力护盾 (1=开 0=关)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvAuraRadius = CreateConVar("sm_asrd_repulse_aura_radius", "260",
        "护盾半径 (游戏单位)", FCVAR_NOTIFY, true, 50.0, true, 3000.0);
    g_cvAuraMode = CreateConVar("sm_asrd_repulse_aura_mode", "1",
        "护盾模式 (1=直接阻挡 钉在圈外; 0=斥力击退 平滑弹开)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvClasses = CreateConVar("sm_asrd_repulse_classes", "",
        "追加要击退的实体类名 (空格分隔, 空=不追加)", FCVAR_NOTIFY);
    g_cvProjectiles = CreateConVar("sm_asrd_repulse_projectiles", "1",
        "是否弹开敌方投射物(炮弹), 如 mortarbug 的炮弹 (0=关 1=开)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvProjSpeed = CreateConVar("sm_asrd_repulse_projectile_speed", "400",
        "弹开投射物的速度 (游戏单位/秒)", FCVAR_NOTIFY, true, 50.0, true, 3000.0);
    g_cvProjClasses = CreateConVar("sm_asrd_repulse_projectile_classes", "",
        "追加要弹开的敌方投射物类名 (空格分隔, 空=不追加)", FCVAR_NOTIFY);
    g_cvDebug = CreateConVar("sm_asrd_repulse_debug", "0",
        "调试输出 (0=关 1=开; 1还列出半径内所有实体的真实类名, 便于抓投射物/漏网虫种)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    HookConVarChange(g_cvClasses, OnClassesChanged);
    HookConVarChange(g_cvProjClasses, OnProjClassesChanged);

    AutoExecConfig(true, "asrd_repulse");

    RegConsoleCmd("sm_repulse", Command_Repulse, "范围击退 (可绑定按键连按)");
    RegAdminCmd("sm_repulseaura", Command_Aura, ADMFLAG_GENERIC,
        "[管理员] 给指定玩家开关护盾: sm_repulseaura [玩家] [on|off|1|0] (无玩家=自己, 无状态=切换)");

    ParseCustomClasses();
    ParseProjClasses();
}

// ============================================================================
//  [管理员] 按玩家开关护盾: sm_repulseaura [玩家] [on|off|1|0]
//  默认只有管理员可用; 护盾仍受总开关 sm_asrd_repulse_aura 控制 (需=1 才真正生效)
// ============================================================================
public Action Command_Aura(int client, int args)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
    {
        ReplyToCommand(client, "[击退] 请在游戏内使用");
        return Plugin_Handled;
    }

    // 目标 (默认自己)
    int target = client;
    if (args >= 1)
    {
        char sArg[64];
        GetCmdArg(1, sArg, sizeof(sArg));
        target = FindTargetPlayer(client, sArg);
        if (target == -1)
            return Plugin_Handled;   // 已提示
    }

    // 状态 (缺省切换)
    if (args >= 2)
    {
        char sState[16];
        GetCmdArg(2, sState, sizeof(sState));
        if (StrEqual(sState, "on", false) || StrEqual(sState, "1", false))
            g_bAuraOn[target] = true;
        else if (StrEqual(sState, "off", false) || StrEqual(sState, "0", false))
            g_bAuraOn[target] = false;
        else
        {
            ReplyToCommand(client, "[击退] 状态参数仅支持 on/off/1/0");
            return Plugin_Handled;
        }
    }
    else
    {
        g_bAuraOn[target] = !g_bAuraOn[target];
    }

    char sName[64];
    GetClientName(target, sName, sizeof(sName));
    ReplyToCommand(client, "[击退] 已%s %s 的护盾 (需 sm_asrd_repulse_aura 1 才生效)",
        g_bAuraOn[target] ? "开启" : "关闭", sName);
    return Plugin_Handled;
}

// ============================================================================
//  名字 / #userid 找在线玩家; 返回 client 或 -1 (找不到/有歧义时已提示)
//  完整名精确匹配优先, 否则部分匹配去歧义
// ============================================================================
int FindTargetPlayer(int client, const char[] sArg)
{
    if (sArg[0] == '#')
    {
        int t = GetClientOfUserId(StringToInt(sArg[1]));
        if (t > 0 && IsClientInGame(t))
            return t;
        ReplyToCommand(client, "[击退] 找不到该 userid 的在线玩家");
        return -1;
    }

    int iMatch = 0;
    int iFound = -1;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;

        char sName[64];
        GetClientName(i, sName, sizeof(sName));
        if (StrEqual(sName, sArg, false))
            return i;   // 全名精确命中, 直接取

        if (StrContains(sName, sArg, false) != -1)
        {
            iMatch++;
            iFound = i;
        }
    }

    if (iMatch == 1)
        return iFound;
    if (iMatch == 0)
        ReplyToCommand(client, "[击退] 未找到玩家 \"%s\"", sArg);
    else
        ReplyToCommand(client, "[击退] 名字 \"%s\" 有歧义, 请用完整名或 #userid", sArg);
    return -1;
}

// ============================================================================
//  地图加载: 清空动画池, 重解析附加类名
// ============================================================================
public void OnMapStart()
{
    for (int i = 0; i < MAX_PUSH; i++)
        g_bPushActive[i] = false;
    g_bAnyPushActive = false;

    ParseCustomClasses();
    ParseProjClasses();
}

// ============================================================================
//  附加类名 ConVar 变化时重新解析
// ============================================================================
public void OnClassesChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    ParseCustomClasses();
}

void ParseCustomClasses()
{
    g_iCustomClassCount = 0;

    char sBuf[1024];
    g_cvClasses.GetString(sBuf, sizeof(sBuf));
    if (sBuf[0] == '\0')
        return;

    char sParts[MAX_CUSTOM_CLASSES][64];
    int iCount = ExplodeString(sBuf, " ", sParts, MAX_CUSTOM_CLASSES, 64);
    for (int i = 0; i < iCount; i++)
    {
        TrimString(sParts[i]);
        if (sParts[i][0] != '\0' && g_iCustomClassCount < MAX_CUSTOM_CLASSES)
            strcopy(g_sCustomClasses[g_iCustomClassCount++], 64, sParts[i]);
    }
}

// ============================================================================
//  投射物附加类名 ConVar 变化时重新解析
// ============================================================================
public void OnProjClassesChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    ParseProjClasses();
}

void ParseProjClasses()
{
    // 内置 + 自定义
    g_iProjClassCount = 0;

    for (int i = 0; i < sizeof(g_sBuiltinProjClasses); i++)
    {
        if (g_iProjClassCount < MAX_PROJ_CLASSES)
            strcopy(g_sProjClasses[g_iProjClassCount++], 64, g_sBuiltinProjClasses[i]);
    }

    char sBuf[1024];
    g_cvProjClasses.GetString(sBuf, sizeof(sBuf));
    if (sBuf[0] == '\0')
        return;

    char sParts[MAX_PROJ_CLASSES][64];
    int iCount = ExplodeString(sBuf, " ", sParts, MAX_PROJ_CLASSES, 64);
    for (int i = 0; i < iCount; i++)
    {
        TrimString(sParts[i]);
        if (sParts[i][0] != '\0' && g_iProjClassCount < MAX_PROJ_CLASSES)
            strcopy(g_sProjClasses[g_iProjClassCount++], 64, sParts[i]);
    }
}

// ============================================================================
//  命令: sm_repulse
// ============================================================================
public Action Command_Repulse(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
        return Plugin_Handled;

    if (!g_cvEnabled.BoolValue)
    {
        ReplyToCommand(client, "[击退] 功能已禁用");
        return Plugin_Handled;
    }

    if (!g_cvPublic.BoolValue && !CheckCommandAccess(client, "sm_repulse_admin", ADMFLAG_GENERIC))
    {
        ReplyToCommand(client, "[击退] 该功能未对普通玩家开放");
        return Plugin_Handled;
    }

    float cd = g_cvCooldown.FloatValue;
    if (cd > 0.0)
    {
        float now = GetEngineTime();
        if (g_fLastUse[client] > 0.0 && (now - g_fLastUse[client]) < cd)
            return Plugin_Handled;
        g_fLastUse[client] = now;
    }

    Repulse(client);
    return Plugin_Handled;
}

// ============================================================================
//  手动击退: 遍历内置 + 附加类名, 对范围内每只虫登记平滑推进动画
// ============================================================================
void Repulse(int client)
{
    float fCenter[3];
    if (!GetMarineOrigin(client, fCenter))
    {
        ReplyToCommand(client, "[击退] 无法确定你的位置");
        return;
    }

    float fRadius  = g_cvRadius.FloatValue;
    float fRadius2 = fRadius * fRadius;
    int   iPushed  = 0;

    if (g_cvDebug.BoolValue)
    {
        PrintToServer("[击退][debug] 触发: %N 中心=%.0f %.0f %.0f 半径=%.0f 附加类=%d",
            client, fCenter[0], fCenter[1], fCenter[2], fRadius, g_iCustomClassCount);
        DebugListNearby(fCenter, fRadius2);
    }

    for (int c = 0; c < sizeof(g_sAlienClasses); c++)
        iPushed += PushClassAliens(g_sAlienClasses[c], fCenter, fRadius2, true);

    for (int c = 0; c < g_iCustomClassCount; c++)
        iPushed += PushClassAliens(g_sCustomClasses[c], fCenter, fRadius2, true);

    if (g_cvProjectiles.BoolValue)
        iPushed += PushProjectiles(fCenter, fRadius2, false);

    if (g_cvDebug.BoolValue)
        PrintToServer("[击退][debug] %N 登记 %d 只虫/炮弹", client, iPushed);

    if (iPushed > 0)
        PrintToChat(client, "\x04[击退]\x01 震开 \x05%d\x01 只异形/炮弹", iPushed);
}

// ============================================================================
//  弹开范围内的敌方投射物: 给一个从中心向外的速度, 而非 teleport
//  (投射物常带物理/高速, 逐帧 teleport 会被它的飞行速度拉回, 用速度推开才有效)
//  返回处理的投射物数量
// ============================================================================
int PushProjectiles(const float fCenter[3], float fRadius2, bool bKill)
{
    int iCount = 0;
    for (int c = 0; c < g_iProjClassCount; c++)
    {
        int entity = -1;
        while ((entity = FindEntityByClassname(entity, g_sProjClasses[c])) != -1)
        {
            if (!IsValidEntity(entity))
                continue;

            float fPos[3];
            if (!GetEntOrigin(entity, fPos))
                continue;

            float dx = fPos[0] - fCenter[0];
            float dy = fPos[1] - fCenter[1];
            float dz = fPos[2] - fCenter[2];
            float fDistSq = dx*dx + dy*dy + dz*dz;

            // 只对击杀做范围判断, asw_missile_round 与玩家导弹共用: 一律按敌方投射物处理(不做敌我区分)
            // debug: 枚举到 asw_missile_round 打印距离, 便于确认 ranger 酸球是否被截获
            if (g_cvDebug.BoolValue
                && StrEqual(g_sProjClasses[c], "asw_missile_round", false)
                && GetGameTime() - g_fLastProjLog >= 1.0)
            {
                PrintToServer("[击退][debug] 命中 asw_missile_round 距离=%.0f",
                    SquareRoot(fDistSq));
                g_fLastProjLog = GetGameTime();
            }

            if (fDistSq > fRadius2)
                continue;

            // 在半径内: 护盾模式直接让它消失, 手动模式用速度弹开
            // 例外: asw_mortarbug_shell(炮虫炮弹) 任何模式都只用速度弹开, 不删除
            if (bKill && !StrEqual(g_sProjClasses[c], "asw_mortarbug_shell", false))
            {
                RemoveEntity(entity);
                iCount++;
                continue;
            }

            float fLen = SquareRoot(fDistSq) + 1.0;
            float fSpeed = g_cvProjSpeed.FloatValue;
            float fVel[3];
            fVel[0] = (dx / fLen) * fSpeed;
            fVel[1] = (dy / fLen) * fSpeed;
            fVel[2] = (dz / fLen) * fSpeed + 40.0;   // 小幅上挑, 让它飞开而不是贴地

            TeleportEntity(entity, NULL_VECTOR, NULL_VECTOR, fVel);
            iCount++;
        }
    }
    return iCount;
}

// ============================================================================
//  debug: 列出玩家半径范围内所有实体的真实类名, 便于发现漏网虫种与投射物
// ============================================================================
void DebugListNearby(const float fCenter[3], float fRadius2)
{
    for (int e = MaxClients + 1; e < GetEntityCount(); e++)
    {
        if (!IsValidEntity(e))
            continue;

        char sCls[64];
        GetEntityClassname(e, sCls, sizeof(sCls));

        float fPos[3];
        if (!GetEntOrigin(e, fPos))
            continue;

        float dx = fPos[0] - fCenter[0];
        float dy = fPos[1] - fCenter[1];
        float dz = fPos[2] - fCenter[2];
        if ((dx*dx + dy*dy + dz*dz) > fRadius2)
            continue;

        PrintToServer("[击退][debug] 半径内实体类名: %s", sCls);
    }
}

// ============================================================================
//  处理某类虫: bManual=true 平滑推进(带挑飞), false 护盾小步外推
//  返回处理的虫数量
// ============================================================================
int PushClassAliens(const char[] sClass, const float fCenter[3], float fRadius2, bool bManual)
{
    int iCount = 0;
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, sClass)) != -1)
    {
        if (!IsValidEntity(entity))
            continue;

        float fPos[3];
        if (!GetEntOrigin(entity, fPos))
            continue;

        float dx = fPos[0] - fCenter[0];
        float dy = fPos[1] - fCenter[1];

        if (bManual)
        {
            float dz = fPos[2] - fCenter[2];
            if ((dx*dx + dy*dy + dz*dz) > fRadius2)
                continue;

            float fLen = SquareRoot(dx*dx + dy*dy) + 1.0;
            float fDst[3];
            fDst[0] = fPos[0] + (dx / fLen) * g_cvForce.FloatValue;
            fDst[1] = fPos[1] + (dy / fLen) * g_cvForce.FloatValue;
            fDst[2] = fPos[2] + g_cvLift.FloatValue;
            AddPush(entity, fPos, fDst);
            iCount++;
        }
        else
        {
            // 护盾分两模式, 由 sm_asrd_repulse_aura_mode 决定:
            //   1 (默认) = 直接阻挡: 每帧把范围内怪物钉回半径边界, 形成"墙"
            //   0        = 斥力推: 每帧沿径向小步向外推
            if ((dx*dx + dy*dy) > fRadius2)
                continue;   // 护盾只看水平距离, 在界外无视

            float fLen = SquareRoot(dx*dx + dy*dy);
            if (fLen < 1.0)
                continue;

            float fNew[3];
            fNew[2] = fPos[2];   // 管水平, 高度保持不动

            if (g_cvAuraMode.BoolValue)
            {
                // ── 直接阻挡: 钉回半径边界 + 清零速度(压住飞行/高速虫) ──
                float fRadius = SquareRoot(fRadius2);
                fNew[0] = fCenter[0] + (dx / fLen) * fRadius;
                fNew[1] = fCenter[1] + (dy / fLen) * fRadius;

                float fZero[3];
                fZero[0] = fZero[1] = fZero[2] = 0.0;
                TeleportEntity(entity, fNew, NULL_VECTOR, fZero);
            }
            else
            {
                // ── 斥力 = 持续击退弹开: 对进入范围的怪施放一次平滑推进动画(力度/挑飞同手动)
                // 同一只怪在动画未结束时不再重复施放(AddPush 内已防重), 既有击退弹开感又不抖动
                float fDst[3];
                fDst[0] = fPos[0] + (dx / fLen) * g_cvForce.FloatValue;
                fDst[1] = fPos[1] + (dy / fLen) * g_cvForce.FloatValue;
                fDst[2] = fPos[2] + g_cvLift.FloatValue;
                AddPush(entity, fPos, fDst);
                iCount++;
            }
        }
    }
    return iCount;
}

// ============================================================================
//  每游戏帧回调: 平滑推进动画 + 持续护盾
//  放在 OnGameFrame(最高频率) 而非低频定时器, 每帧都更新位置并附带速度,
//  客户端据此做帧间插值 → 即便很短(0.05s)的击退也平滑, 不会一顿一顿。
// ============================================================================
public void OnGameFrame()
{
    // 无动画且未开护盾时直接跳过, 避免空转
    bool bHasAura = g_cvEnabled.BoolValue && g_cvAura.BoolValue;
    if (!bHasAura && !g_bAnyPushActive)
        return;

    float dt = GetTickInterval();

    if (bHasAura)
        ThinkAura();

    g_bAnyPushActive = ProcessPushAnim(dt);
}

// 逐帧推进动画, 返回是否仍有条目在跑(用于跳过空闲帧)
bool ProcessPushAnim(float dt)
{
    bool bAny = false;
    for (int i = 0; i < MAX_PUSH; i++)
    {
        if (!g_bPushActive[i])
            continue;

        bAny = true;

        int ent = g_iPushEnt[i];
        if (!IsValidEntity(ent))
        {
            g_bPushActive[i] = false;
            continue;
        }

        g_fPushElapsed[i] += dt;
        float k = g_fPushElapsed[i] / g_fPushDur[i];
        if (k >= 1.0)
            k = 1.0;

        float s = k * k * (3.0 - 2.0 * k);   // smoothstep 缓入缓出

        float fPos[3];
        float fVel[3];
        for (int a = 0; a < 3; a++)
        {
            fPos[a] = g_fPushSrc[i][a] + (g_fPushDst[i][a] - g_fPushSrc[i][a]) * s;
            // 该帧速度 = (当前位置 - 上一帧位置) / 帧时长, 供客户端帧间插值
            fVel[a] = (fPos[a] - g_fPushPrev[i][a]) / dt;
            g_fPushPrev[i][a] = fPos[a];
        }

        TeleportEntity(ent, fPos, NULL_VECTOR, fVel);

        if (k >= 1.0)
            g_bPushActive[i] = false;
    }
    return bAny;
}

void ThinkAura()
{
    float fRadius  = g_cvAuraRadius.FloatValue;
    float fRadius2 = fRadius * fRadius;
    int   iPushed  = 0;

    // 护盾模式下若开了 debug, 每隔 3 秒点名一次半径内所有实体类名,
    // 方便直接确认某只虫(如治疗虫)的真实类名, 不用改代码
    bool bDumpPending = g_cvDebug.BoolValue
        && (GetGameTime() - g_fLastAuraDump >= 3.0);
    bool bDumped = false;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
            continue;
        if (!g_bAuraOn[client])
            continue;   // 只有被管理员 sm_repulseaura 指定的玩家才有效盾

        float fCenter[3];
        if (!GetMarineOrigin(client, fCenter))
            continue;

        if (bDumpPending && !bDumped)
        {
            bDumped = true;
            g_fLastAuraDump = GetGameTime();
            DebugListNearby(fCenter, fRadius2);
        }

        for (int c = 0; c < sizeof(g_sAlienClasses); c++)
            iPushed += PushClassAliens(g_sAlienClasses[c], fCenter, fRadius2, false);

        for (int c = 0; c < g_iCustomClassCount; c++)
            iPushed += PushClassAliens(g_sCustomClasses[c], fCenter, fRadius2, false);

        if (g_cvProjectiles.BoolValue)
            iPushed += PushProjectiles(fCenter, fRadius2, true);
    }

    if (g_cvDebug.BoolValue && iPushed > 0
        && GetGameTime() - g_fLastAuraLog >= 1.0)
    {
        PrintToServer("[击退][aura] 本秒推开 %d 只", iPushed);
        g_fLastAuraLog = GetGameTime();
    }
}

// ============================================================================
//  把一只虫登记进推进动画池 (池满时退化为即时位移)
// ============================================================================
void AddPush(int ent, const float fSrc[3], const float fDst[3])
{
    // 该怪已在推进动画中 → 跳过, 避免重复施放造成叠加抖动
    for (int i = 0; i < MAX_PUSH; i++)
        if (g_bPushActive[i] && g_iPushEnt[i] == ent)
            return;

    for (int i = 0; i < MAX_PUSH; i++)
    {
        if (g_bPushActive[i])
            continue;

        g_iPushEnt[i] = ent;
        for (int a = 0; a < 3; a++)
        {
            g_fPushSrc[i][a] = fSrc[a];
            g_fPushDst[i][a] = fDst[a];
            g_fPushPrev[i][a] = fSrc[a];   // 上一帧位置初始为起点
        }
        g_fPushElapsed[i] = 0.0;
        float dur = g_cvPullTime.FloatValue;
        g_fPushDur[i] = (dur > 0.05) ? dur : 0.05;
        g_bPushActive[i] = true;
        g_bAnyPushActive = true;
        return;
    }

    TeleportEntity(ent, fDst, NULL_VECTOR, NULL_VECTOR);
}

// ============================================================================
//  读取实体世界坐标: 优先网络权威属性 Prop_Send, 退回 Prop_Data
// ============================================================================
bool GetEntOrigin(int entity, float fOut[3])
{
    if (HasEntProp(entity, Prop_Send, "m_vecOrigin"))
    {
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", fOut);
        return true;
    }
    if (HasEntProp(entity, Prop_Data, "m_vecOrigin"))
    {
        GetEntPropVector(entity, Prop_Data, "m_vecOrigin", fOut);
        return true;
    }
    return false;
}

// ============================================================================
//  取玩家当前控制的陆战队员坐标
// ============================================================================
bool GetMarineOrigin(int client, float fOut[3])
{
    if (client <= 0 || !IsClientInGame(client))
        return false;

    int iMarine = GetPlayerMarine(client);
    if (iMarine != 0)
    {
        if (HasEntProp(iMarine, Prop_Send, "m_vecOrigin"))
        {
            GetEntPropVector(iMarine, Prop_Send, "m_vecOrigin", fOut);
            return true;
        }
        if (HasEntProp(iMarine, Prop_Data, "m_vecOrigin"))
        {
            GetEntPropVector(iMarine, Prop_Data, "m_vecOrigin", fOut);
            return true;
        }
    }

    GetClientAbsOrigin(client, fOut);
    return true;
}

// ============================================================================
//  查找玩家当前控制的 marine 实体 (失败返回 0)
// ============================================================================
int GetPlayerMarine(int client)
{
    if (client <= 0 || !IsClientInGame(client))
        return 0;

    char sNetClass[64];
    if (GetEntityNetClass(client, sNetClass, sizeof(sNetClass))
        && FindSendPropInfo(sNetClass, "m_hInhabiting") > 0)
    {
        int iMarine = GetEntPropEnt(client, Prop_Send, "m_hInhabiting");
        if (iMarine > 0 && IsValidEntity(iMarine))
            return iMarine;
    }

    if (FindDataMapInfo(client, "m_hInhabiting") > 0)
    {
        int iMarine = GetEntPropEnt(client, Prop_Data, "m_hInhabiting");
        if (iMarine > 0 && IsValidEntity(iMarine))
            return iMarine;
    }

    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "asw_marine")) != -1)
    {
        if (FindDataMapInfo(ent, "m_hCommander") > 0
            && GetEntPropEnt(ent, Prop_Data, "m_hCommander") == client)
            return ent;
    }

    return 0;
}