/**
 * ============================================================================
 *  [AS:RD] 核弹轰炸 (Nuke Strike)
 *  版本 1.7.7  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ──────────────────────────────────────
 *  玩家按下绑定按键 (或输入命令) 后, 触发一次"战术核弹":
 *    1. 在所有玩家屏幕中央以红色大字倒计时 "呼叫战术核弹 / ETA n 秒"
 *    2. n 秒后轰炸全图: 清除地图上所有虫族 (含异形卵)
 *    3. 倒计时期间禁止再次触发 (同一时刻只有一发核弹在路上)
 *
 *  ── 核爆特效 ────────────────────────────────────────────
 *    - 白色炫光闪屏 (Fade 用户消息)
 *    - 镜头震动 (env_shake 全局震屏)
 *    - 游戏自带爆炸音效 (复用油桶爆炸音 ASWBarrel.Explode)
 *
 *  ── 按键绑定 ───────────────────────────────────────────
 *  在控制台输入:  bind <按键> "sm_nuke"
 *  例如:          bind f "sm_nuke"
 *  写入客户端的 config.cfg 即可跨局持久生效。
 *
 *  ── 命令 ────────────────────────────────────────────────
 *   sm_nuke        管理员: 呼叫战术核弹轰炸全图虫族
 *   sm_nukepub     玩家:   呼叫战术核弹 (需管理员开启公众模式)
 *
 *  ── 常用 ConVar (自动生成 cfg/sourcemod/asrd_nuke.cfg) ──
 *   sm_asrd_nuke_enabled    总开关 (0=关 1=开, 默认 1)
 *   sm_asrd_nuke_damage     对虫族造成的伤害 (默认 999999.0)
 *   sm_asrd_nuke_delay      预计抵达秒数 ETA (默认 3.0, 0=立即引爆)
 *   sm_asrd_nuke_public     允许所有玩家使用 sm_nukepub (默认 1)
 *   sm_asrd_nuke_debug      调试输出 (默认 0)
 *
 *  依赖: SourceMod 1.11+ (核心 + sdktools + sdkhooks)
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] Nuke Strike"
#define PLUGIN_VERSION "1.7.7"

// 倒计时红字的位置与颜色 (内置 HUD 坐标: -1=居中; game_text: 0=居中)
#define ETA_HUD_X       -1.0
#define ETA_HUD_Y       0.10
#define ETA_CHANNEL     5        // 通道号, 避免与其它 HUD 冲突

// ─── 怪物实体类名清单 (取自 RD 官方实体列表 / 源码) ──────
char g_sAlienClasses[][] =
{
    "asw_drone",             // 普通工蜂
    "asw_drone_jumper",      // 跳跃工蜂
    "asw_drone_uber",        // 强化工蜂(血厚)
    "asw_drone_antlion",     // 蚁狮工蜂
    "asw_parasite",          // 抱脸寄生虫
    "asw_parasite_defanged", // 无牙寄生虫
    "asw_egg",               // 异形卵(会孵化)
    "asw_boomer",            // 爆裂虫
    "asw_boomer_blob",       // 爆裂虫酸液残留
    "asw_buzzer",            // 蜂群
    "asw_harvester",         // 收割者
    "asw_mortarbug",         // 迫击炮虫
    "asw_ranger",            // 游侠
    "asw_shieldbug",         // 盾甲虫
    "asw_grub",              // 幼虫
    "asw_grub_sac",          // 幼虫囊
    "asw_queen",             // 蜂后
    "asw_mender",            // 医疗虫 (旧名, 保留兼容)
    "asw_shaman",            // 治疗虫 (RD 真实类名, 会治疗其它异形)
    "asw_xenomite",          // 自爆孢子虫 (收割者产出)
    "asw_antlion_guard",     // 蚁狮守卫 (旧名, 保留兼容)
    // RD 蚁狮守卫/工蜂真实类名 (npc_ 前缀, 不是 asw_!)
    "npc_antlionguard",
    "npc_antlionguard_cavern",
    "npc_antlionguard_normal",
    "npc_antlion_worker"
};

// ─── ConVar 句柄 ─────────────────────────────────────────
ConVar g_cvEnabled;
ConVar g_cvDamage;
ConVar g_cvDelay;
ConVar g_cvPublic;
ConVar g_cvDebug;

// ─── 倒计时全局状态 (单发锁定, 帧回调驱动; 每帧推进, 不依赖 SourceMod 定时器) ──
bool   g_bPending;                // 是否有核弹正在倒计时
int    g_iEtaSeconds;             // 剩余秒数
float  g_fCountEnd;               // 预计引爆时刻 (GetEngineTime 秒, 帧回调据此推进)
float  g_fLastCountCheck;         // 上次执行倒计时计算的时间 (1 秒节流, 其余帧直接跳过)

// ─── 红字显示状态 (每玩家独立, 与哨戒塔 HUD 同一套双保险思路) ───
int g_iHudMode[MAXPLAYERS + 1];        // 0=未试 1=内置HUD 2=game_text
int g_iEtaTextEnt[MAXPLAYERS + 1];     // game_text 实体引用

// ============================================================================
//  插件信息
// ============================================================================
public Plugin myinfo = {
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "AS:RD 呼叫战术核弹, 倒计时后轰炸全图虫族",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
//  插件启动: 创建 ConVar、注册命令
// ============================================================================
public void OnPluginStart()
{
    g_cvEnabled = CreateConVar(
        "sm_asrd_nuke_enabled", "1",
        "启用/禁用核弹轰炸 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvDamage = CreateConVar(
        "sm_asrd_nuke_damage", "999999.0",
        "对怪物造成的伤害 (走正常死亡流程, 可触发碎块)",
        FCVAR_NOTIFY, true, 1.0, true, 10000000.0
    );
    g_cvDelay = CreateConVar(
        "sm_asrd_nuke_delay", "3.0",
        "支援抵达秒数 ETA (倒计时时长, 0=立即引爆)",
        FCVAR_NOTIFY, true, 0.0, true, 60.0
    );
    g_cvPublic = CreateConVar(
        "sm_asrd_nuke_public", "1",
        "允许所有玩家使用 sm_nukepub (0=仅管理员 1=所有人)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvDebug = CreateConVar(
        "sm_asrd_nuke_debug", "0",
        "调试模式 (向服务器控制台输出引爆日志)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    // 自动保存/读取配置到 cfg/sourcemod/asrd_nuke.cfg
    AutoExecConfig(true, "asrd_nuke");

    // 管理员命令 (可 bind 到按键)
    RegAdminCmd("sm_nuke", Command_Nuke, ADMFLAG_GENERIC,
        "呼叫战术核弹轰炸全图虫族");
    // 玩家命令 (需管理员开启 public)
    RegConsoleCmd("sm_nukepub", Command_NukePublic, "呼叫战术核弹 (需管理员开启)");
}

// ============================================================================
//  地图加载: 预缓存特效资源, 清空上一局留下的状态
// ============================================================================
public void OnMapStart()
{
    // 换图时若有核弹正倒计时, 直接清空倒计时状态。
    // (v1.7.5 起倒计时代由帧回调推进, 不再有带 NO_MAPCHANGE 的残留定时器)
    g_bPending = false;
    g_fCountEnd = 0.0;
    g_iEtaSeconds = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        g_iHudMode[i] = 0;
        g_iEtaTextEnt[i] = 0;
    }
}

// ============================================================================
//  地图结束: 同样杀掉残留倒计时定时器 (双保险)
// ============================================================================
public void OnMapEnd()
{
    g_bPending = false;
    g_fCountEnd = 0.0;
    g_iEtaSeconds = 0;
}

// ============================================================================
//  玩家离开: 清掉他名下的 game_text 显示实体
// ============================================================================
public void OnClientDisconnected(int client)
{
    g_iHudMode[client] = 0;

    // 警告: EntRefToEntIndex(0) 返回 0 = worldspawn(世界实体) 且 IsValidEntity(0)
    // 为 true, 引用为 0 时对它 Kill 会直接崩服, 必须用 ent > 0 挡住!
    int ent = EntRefToEntIndex(g_iEtaTextEnt[client]);
    if (ent != INVALID_ENT_REFERENCE && ent > 0 && IsValidEntity(ent))
        AcceptEntityInput(ent, "Kill");
    g_iEtaTextEnt[client] = 0;
}

// ============================================================================
//  命令 (管理员): sm_nuke
// ============================================================================
public Action Command_Nuke(int client, int args)
{
    if (!g_cvEnabled.BoolValue)
    {
        ReplyToCommand(client, "[核弹] 功能已禁用");
        return Plugin_Handled;
    }

    StartNuke(client);
    return Plugin_Handled;
}

// ============================================================================
//  命令 (玩家): sm_nukepub
// ============================================================================
public Action Command_NukePublic(int client, int args)
{
    if (!g_cvEnabled.BoolValue)
    {
        ReplyToCommand(client, "[核弹] 功能已禁用");
        return Plugin_Handled;
    }

    if (!g_cvPublic.BoolValue)
    {
        ReplyToCommand(client, "[核弹] 该功能未对玩家开放");
        return Plugin_Handled;
    }

    StartNuke(client);
    return Plugin_Handled;
}

// ============================================================================
//  呼叫核弹: 加锁 → 记录引爆时刻 → OnGameFrame 每帧推进倒计时/引爆
//  v1.7.6: 不再依赖 SourceMod 定时器 (本环境定时器不触发), 改用已实测可靠的帧回调
// ============================================================================
void StartNuke(int client)
{
    // 已有一发在路上, 拒绝重复触发 (倒计时结束前禁止下次命令)
    if (g_bPending)
    {
        ReplyToCommand(client, "[核弹] 战术核弹已在路上 (预计 %d 秒抵达), 请稍候", g_iEtaSeconds);
        return;
    }

    float delay = g_cvDelay.FloatValue;
    if (delay <= 0.0)
    {
        Detonate();   // 无延迟: 直接轰炸
        return;
    }

    g_bPending = true;
    g_iEtaSeconds = RoundToNearest(delay);
    g_fCountEnd = GetEngineTime() + delay;
    g_fLastCountCheck = GetEngineTime();   // 立即开始, 无需等待首个 1 秒窗口

    ShowEta(g_iEtaSeconds);
    if (g_cvDebug.BoolValue)
        PrintToServer("[核弹][debug] 已启动帧驱动倒计时: end=%.2f", g_fCountEnd);
}

// ============================================================================
//  每帧推进: 刷新 ETA 倒计时, 到时刻引爆并解锁 (帧类回调驱动, 替代旧定时器)
// ============================================================================
public void OnGameFrame()
{
    if (!g_bPending)
        return;

    float fNow = GetEngineTime();
    // 1 秒节流: 未满 1 秒的帧直接跳过, 只在到点那帧计算/重绘/引爆 (降低每帧开销)
    if (fNow - g_fLastCountCheck < 1.0)
        return;
    g_fLastCountCheck = fNow;

    int iNew = RoundToCeil(g_fCountEnd - fNow);

    // 剩余秒数发生变化时刷新字幕 (从高到低, 归零时才停)
    if (iNew != g_iEtaSeconds && iNew >= 0)
    {
        g_iEtaSeconds = iNew;
        ShowEta(iNew);
        if (g_cvDebug.BoolValue)
            PrintToServer("[核弹][debug] 倒计时: %d 秒", iNew);
    }

    // 到时刻 → 引爆并解锁
    if (fNow >= g_fCountEnd)
    {
        g_bPending = false;
        g_iEtaSeconds = 0;
        ClearEta();
        Detonate();
    }
}

// ============================================================================
//  引爆核弹: 全图清除虫族 → 白闪 + 震屏 + 音效
// ============================================================================
void Detonate()
{
    float fDamage = g_cvDamage.FloatValue;
    int iKilled = 0;

    // 逐类遍历全图虫族, 不再限定圆心/半径
    for (int c = 0; c < sizeof(g_sAlienClasses); c++)
    {
        int entity = -1;
        while ((entity = FindEntityByClassname(entity, g_sAlienClasses[c])) != -1)
        {
            // 先以巨额爆破伤害走正常死亡流程 (触发碎块、击杀归属)
            SDKHooks_TakeDamage(entity, 0, 0, fDamage, DMG_BLAST);
            // 兜底: 若仍未移除 (免疫/特殊状态) 则强制 Kill
            if (IsValidEntity(entity))
                AcceptEntityInput(entity, "Kill");

            iKilled++;
        }
    }

    // 核爆特效 (全图: 闪屏 + 震屏 + 音效, 不再有单一爆心火光)
    ScreenFlashAll();
    ScreenShake();
    PlayNukeSound();

    // 埋点: 调试日志
    if (g_cvDebug.BoolValue)
    {
        PrintToServer("[核弹] 全图清除虫族=%d", iKilled);

        // 打印引爆后仍存活的 asw_ 单位, 便于定位清单外的漏网异形
        char cls[64];
        for (int e = MaxClients + 1; e < GetEntityCount(); e++)
        {
            if (!IsValidEntity(e) || !HasEntProp(e, Prop_Data, "m_iHealth"))
                continue;
            GetEntityClassname(e, cls, sizeof(cls));
            if (strncmp(cls, "asw_", 4, false) != 0)
                continue;
            if (GetEntProp(e, Prop_Data, "m_iHealth") > 0)
                PrintToServer("[核弹][debug] 仍存活: %s (hp=%d)", cls, GetEntProp(e, Prop_Data, "m_iHealth"));
        }
    }

    PrintToChatAll("\x04[核弹]\x01 战术核弹已抵达, 已烧烤 %d 只虫子", iKilled);
}

// ============================================================================
//  倒计时红字: 给所有玩家屏幕中央显示 ETA
// ============================================================================
void ShowEta(int seconds)
{
    char text[64];
    // 分两行, 避免单行过长被屏幕边缘截断
    Format(text, sizeof(text), "呼叫战术核弹\nETA %d 秒", seconds);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;
        ShowCenterText(i, text);
    }
}

// ============================================================================
//  清除倒计时红字 (倒计时结束引爆时调用)
// ============================================================================
void ClearEta()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;

        if (g_iHudMode[i] == 1)
        {
            SetHudTextParams(ETA_HUD_X, ETA_HUD_Y, 0.1, 255, 255, 255, 0, 0, 0.0, 0.1, 0.1);
            ShowHudText(i, ETA_CHANNEL, " ");
        }
        else if (g_iHudMode[i] == 2)
        {
            int ent = EntRefToEntIndex(g_iEtaTextEnt[i]);
            // ent > 0: 引用为 0 时解析成 worldspawn, 误 Kill 会崩服
            if (ent != INVALID_ENT_REFERENCE && ent > 0 && IsValidEntity(ent))
                AcceptEntityInput(ent, "Kill");
            g_iEtaTextEnt[i] = 0;
        }
    }
}

// ============================================================================
//  给单个玩家显示屏幕中央红字 (先试内置 HUD, 不支持则 game_text 兜底)
// ============================================================================
void ShowCenterText(int client, const char[] text)
{
    if (g_iHudMode[client] == 2)
    {
        ShowViaGameText(client, text);
        if (g_cvDebug.BoolValue)
            PrintToServer("[核弹][debug] HUD刷新(game_text兜底): client=%d", client);
        return;
    }

    // 红色大字, 居中偏上, 停留略超 1 秒保证刷新不闪烁
    SetHudTextParams(ETA_HUD_X, ETA_HUD_Y, 1.1, 255, 0, 0, 255, 0, 0.0, 0.05, 0.15);
    int ret = ShowHudText(client, ETA_CHANNEL, text);

    if (ret == -1)
    {
        g_iHudMode[client] = 2;
        if (g_cvDebug.BoolValue)
            PrintToServer("[核弹][debug] 内置HudText不可用(返回-1), 改用 game_text 兜底: client=%d", client);
        ShowViaGameText(client, text);
    }
    else
    {
        if (g_iHudMode[client] != 1)
        {
            g_iHudMode[client] = 1;
            if (g_cvDebug.BoolValue)
                PrintToServer("[核弹][debug] 内置HudText可用(返回通道=%d): client=%d", ret, client);
        }
        if (g_cvDebug.BoolValue)
            PrintToServer("[核弹][debug] HUD刷新(内置HudText): client=%d", client);
    }
}

// ============================================================================
//  备用显示方式: 为某玩家取得 (没有则创建) 一个 game_text 实体并显示
// ============================================================================
int GetEtaGameText(int client)
{
    int ent = EntRefToEntIndex(g_iEtaTextEnt[client]);
    // ent > 0: 引用为 0 时解析成 worldspawn(世界实体), 不能当 game_text 用,
    // 否则兜底永远拿到世界实体而不创建, 倒计时根本不显示
    if (ent != INVALID_ENT_REFERENCE && ent > 0 && IsValidEntity(ent))
        return ent;

    ent = CreateEntityByName("game_text");
    if (ent == -1)
        return -1;

    char sName[48];
    Format(sName, sizeof(sName), "asrd_nuke_eta_%d", GetClientUserId(client));

    DispatchKeyValue(ent, "targetname", sName);
    DispatchKeyValue(ent, "spawnflags", "0");
    DispatchKeyValue(ent, "channel",   "5");
    DispatchKeyValue(ent, "x",         "0.0");
    DispatchKeyValue(ent, "y",         "0.10");
    DispatchKeyValue(ent, "effect",    "0");
    DispatchKeyValue(ent, "color",     "255 0 0");
    DispatchKeyValue(ent, "fadein",    "0.05");
    DispatchKeyValue(ent, "fadeout",   "0.1");
    DispatchKeyValue(ent, "holdtime",  "1.0");
    DispatchSpawn(ent);

    g_iEtaTextEnt[client] = EntIndexToEntRef(ent);
    return ent;
}

void ShowViaGameText(int client, const char[] msg)
{
    int ent = GetEtaGameText(client);
    if (ent == -1)
        return;

    DispatchKeyValue(ent, "message", msg);
    AcceptEntityInput(ent, "Display", client);
}

// ============================================================================
//  视觉: 白色炫光闪屏 (Fade 用户消息, FFADE_IN 全白 → 淡出)
// ============================================================================
void ScreenFlashAll()
{
    Handle msg = StartMessageAll("Fade", USERMSG_RELIABLE);
    if (msg == INVALID_HANDLE)
        return;

    BfWriteShort(msg, 512);              // 淡出时长
    BfWriteShort(msg, 256);              // 全白保持时长
    BfWriteShort(msg, 0x0001 | 0x0010);  // FFADE_IN | FFADE_PURGE
    BfWriteByte(msg, 255);   // R
    BfWriteByte(msg, 244);   // G
    BfWriteByte(msg, 180);   // B (白中带黄)
    BfWriteByte(msg, 255);   // A
    EndMessage();
}

// ============================================================================
//  视觉: 镜头震动 (env_shake, 全局震屏)
// ============================================================================
void ScreenShake()
{
    int shake = CreateEntityByName("env_shake");
    if (shake == -1)
        return;

    DispatchKeyValue(shake, "amplitude", "14");
    DispatchKeyValue(shake, "frequency", "40");
    DispatchKeyValue(shake, "duration", "2.5");
    DispatchKeyValue(shake, "spawnflags", "1");
    DispatchSpawn(shake);
    ActivateEntity(shake);
    AcceptEntityInput(shake, "StartShake");

    CreateTimer(2.7, Timer_KillEntity, EntIndexToEntRef(shake), TIMER_FLAG_NO_MAPCHANGE);
}

// ============================================================================
//  音效: 全图播放游戏自带爆炸音 (油桶爆炸同款, 无空间衰减)
// ============================================================================
void PlayNukeSound()
{
    // RD 源码中油桶爆炸即 EmitSound("ASWBarrel.Explode"), 该 scripted sound 已随游戏注册
    EmitSoundToAll("ASWBarrel.Explode");
}

// ============================================================================
//  定时器: 延迟删除实体 (env_shake 震动结束后清理)
// ============================================================================
public Action Timer_KillEntity(Handle timer, int ref)
{
    int ent = EntRefToEntIndex(ref);
    if (ent != INVALID_ENT_REFERENCE && IsValidEntity(ent))
        AcceptEntityInput(ent, "Kill");
    return Plugin_Handled;
}