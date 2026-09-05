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
 *     缓慢持续往外推, 保持在护盾半径之外。
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
 *   sm_asrd_repulse_aura_speed     护盾外推速度/单位每秒 (默认 180, 越小越柔和)
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
#define PLUGIN_VERSION "1.2.1"

// ─── 平滑推进动画池 (手动击退用) ──
#define MAX_PUSH 512
#define MAX_CUSTOM_CLASSES 32
int    g_iPushEnt[MAX_PUSH];
float  g_fPushSrc[MAX_PUSH][3];
float  g_fPushDst[MAX_PUSH][3];
float  g_fPushElapsed[MAX_PUSH];
float  g_fPushDur[MAX_PUSH];
float  g_fPushPrev[MAX_PUSH][3];   // 上一帧已应用的位置, 用于计算该帧速度(客户端插值更平滑)
bool   g_bPushActive[MAX_PUSH];
bool   g_bAnyPushActive;           // 是否有任意推进动画在跑, 用于跳过空闲帧

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
ConVar g_cvAuraSpeed;
ConVar g_cvClasses;
ConVar g_cvDebug;

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
        "护盾作用半径 (游戏单位)", FCVAR_NOTIFY, true, 50.0, true, 3000.0);
    g_cvAuraSpeed = CreateConVar("sm_asrd_repulse_aura_speed", "180",
        "护盾外推速度 (游戏单位/秒, 越小越柔和)", FCVAR_NOTIFY, true, 10.0, true, 1000.0);
    g_cvClasses = CreateConVar("sm_asrd_repulse_classes", "",
        "追加要击退的实体类名 (空格分隔, 空=不追加)", FCVAR_NOTIFY);
    g_cvDebug = CreateConVar("sm_asrd_repulse_debug", "0",
        "调试输出 (0=关 1=开; 1还会列出半径内所有 asw_*/npc_* 实体的真实类名)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    HookConVarChange(g_cvClasses, OnClassesChanged);

    AutoExecConfig(true, "asrd_repulse");

    RegConsoleCmd("sm_repulse", Command_Repulse, "范围击退 (可绑定按键连按)");

    ParseCustomClasses();
}

// ============================================================================
//  地图加载: 清空动画池, 重解析附加类名, 启动 Think 定时器
// ============================================================================
public void OnMapStart()
{
    for (int i = 0; i < MAX_PUSH; i++)
        g_bPushActive[i] = false;
    g_bAnyPushActive = false;

    ParseCustomClasses();
    // 推进/护盾改由 OnGameFrame 每帧驱动 (更平滑), 不再需要定时器
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
        iPushed += PushClassAliens(g_sAlienClasses[c], fCenter, fRadius2, true, 0.0);

    for (int c = 0; c < g_iCustomClassCount; c++)
        iPushed += PushClassAliens(g_sCustomClasses[c], fCenter, fRadius2, true, 0.0);

    if (g_cvDebug.BoolValue)
        PrintToServer("[击退][debug] %N 登记 %d 只虫", client, iPushed);

    if (iPushed > 0)
        PrintToChat(client, "\x04[击退]\x01 震开 \x05%d\x01 只异形", iPushed);
}

// ============================================================================
//  debug: 列出玩家半径范围内所有 asw_*/npc_* 实体的真实类名, 便于发现漏网虫种
// ============================================================================
void DebugListNearby(const float fCenter[3], float fRadius2)
{
    for (int e = MaxClients + 1; e < GetEntityCount(); e++)
    {
        if (!IsValidEntity(e))
            continue;

        char sCls[64];
        GetEntityClassname(e, sCls, sizeof(sCls));
        if (strncmp(sCls, "asw_", 4, false) != 0 && strncmp(sCls, "npc_", 4, false) != 0)
            continue;

        float fPos[3];
        if (!GetEntOrigin(e, fPos))
            continue;

        float dx = fPos[0] - fCenter[0];
        float dy = fPos[1] - fCenter[1];
        float dz = fPos[2] - fCenter[2];
        if ((dx*dx + dy*dy + dz*dz) > fRadius2)
            continue;

        PrintToServer("[击退][debug] 半径内实体类名: %s 位置=%.0f %.0f %.0f",
            sCls, fPos[0], fPos[1], fPos[2]);
    }
}

// ============================================================================
//  处理某类虫: bManual=true 平滑推进(带挑飞), false 护盾小步外推
//  返回处理的虫数量
// ============================================================================
int PushClassAliens(const char[] sClass, const float fCenter[3], float fRadius2, bool bManual, float dt)
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
            if ((dx*dx + dy*dy) > fRadius2)
                continue;   // 护盾只看水平距离

            float fLen = SquareRoot(dx*dx + dy*dy);
            if (fLen < 1.0)
                continue;

            float fStep = g_cvAuraSpeed.FloatValue * dt;
            float fNew[3];
            fNew[0] = fPos[0] + (dx / fLen) * fStep;
            fNew[1] = fPos[1] + (dy / fLen) * fStep;
            fNew[2] = fPos[2];
            TeleportEntity(entity, fNew, NULL_VECTOR, NULL_VECTOR);
            iCount++;
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
        ThinkAura(dt);

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

void ThinkAura(float dt)
{
    float fRadius  = g_cvAuraRadius.FloatValue;
    float fRadius2 = fRadius * fRadius;
    int   iPushed  = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
            continue;

        float fCenter[3];
        if (!GetMarineOrigin(client, fCenter))
            continue;

        for (int c = 0; c < sizeof(g_sAlienClasses); c++)
            iPushed += PushClassAliens(g_sAlienClasses[c], fCenter, fRadius2, false, dt);

        for (int c = 0; c < g_iCustomClassCount; c++)
            iPushed += PushClassAliens(g_sCustomClasses[c], fCenter, fRadius2, false, dt);
    }

    if (g_cvDebug.BoolValue && iPushed > 0)
        PrintToServer("[击退][aura] 本 tick 推开 %d 只", iPushed);
}

// ============================================================================
//  把一只虫登记进推进动画池 (池满时退化为即时位移)
// ============================================================================
void AddPush(int ent, const float fSrc[3], const float fDst[3])
{
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