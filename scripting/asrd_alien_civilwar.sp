/**
 * ============================================================================
 *  Plugin: [AS:RD] 叛变虫群 (Alien Civil War)
 *
 *  描述: 生成一批"叛变虫群", 它们的攻击对象是**虫族**而不是玩家。
 *        通过着色(RenderColor)与普通虫族在外观上区分, 免冷却, 可自选虫种。
 *  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  命令:
 *    sm_betray     [type] [count]   管理员: 生成一批叛变虫群 (可指定虫种/数量)
 *    sm_betraypub  [type] [count]   玩家:   同上 (需管理员开启 public)
 *    sm_betray_list                 列出可生成的虫种
 *    sm_betray_clear                清除本插件生成的所有叛变虫
 *
 *  实现原理 (关键结论, 均经 reactivedrop_public_src 源码 + 运行时 datamap 实测):
 *    1. CreateEntityByName(<虫族类名>) + DispatchSpawn 生成虫族实体。
 *       AS:RD 的虫族 netclass 是 CASW_Drone_Advanced 之类 (不是 CASW_Drone)。
 *    2. 改阵营: 把 m_nFaction 从 FACTION_ALIENS(实测=2) 改成 marine 阵营值。
 *       - AS:RD 的 faction 字段叫 m_nFaction (datamap 偏移 1800), 不是标准
 *         Source SDK 的 m_iFaction。
 *       - CASW_Alien/CASW_Marine 都不重写 IRelationType, 走基类基于 faction
 *         的判定; 同 faction → D_LI (友好, 不攻击), 异 faction → D_HT。
 *       - m_bIgnoreMarines / m_AlienOrders 均不在 datadesc, SourceMod 无法
 *         设置, 所以"改 faction"是唯一可行路径。
 *    3. spawn 后立即改 + 0.1s 单次延迟重设 (Timer_ReassertFaction), 防
 *       AS:RD 在 NPCInit/Think 里把 faction 重置回 FACTION_ALIENS。
 *    4. SetEntProp(m_clrRender) 着色, 与正常虫族外观区分。
 *
 *  踩过的坑 (详见项目记忆):
 *    - ai_relationship 的 ApplyRelationship 遇实际虫族实体会段错误崩溃 server,
 *      该方案在 AS:RD 不可用。
 *    - 不要在 RepeatingTimer 里持续改 faction, Source AI 不期望 think 中途
 *      改 faction, 会段错误崩溃。只做单次/有限次重设。
 *    - GetEntProp(Prop_Send,"m_nFaction") 会抛 native error (类型不匹配),
 *      必须用 FindDataMapInfo + GetEntData/SetEntData 走 datamap。
 *    - 换图/换挑战前必须彻底清除: 叛变虫是"虫族实体+marine faction"的
 *      矛盾状态, 残留到下一挑战会被某些挑战(如 ASBI Weapon Balancing)
 *      段错误崩溃。做法: 游戏结束事件里先恢复 alien 阵营再 Kill 销毁
 *      全部叛变虫 (只恢复阵营不 Kill 仍会残留崩溃, v3.3.0 起改为
 *      恢复 + Kill + 清空列表)。
 *    - AS:RD 换挑战是软重启(不 changelevel), OnMapEnd 不触发, 必须靠
 *      HookEvent 监听 round_end/asw_mission_restart/mission_failed/
 *      mission_success/map_transition 事件清理。
 *
 *  依赖: SourceMod 1.11+ (核心 + sdktools; 不依赖 SDKHooks)
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] 叛变虫群"
#define PLUGIN_VERSION "3.7.0"

// 叛变虫的统一 targetname, 供清除命令匹配
#define INFECTED_NAME  "asrd_betray_swarm"
// 单次生成数量上限
#define MAX_BATCH      80

// ─── 可生成的虫种: {类名, 中文名, 别名} ──────────────────
char g_sTypes[][3][] = {
    { "asw_drone",            "普通工蜂",   "drone"    },
    { "asw_drone_jumper",     "跳跃工蜂",   "jumper"   },
    { "asw_buzzer",           "蜂群",       "buzzer"   },
    { "asw_parasite",         "抱脸寄生虫", "parasite" },
    { "asw_parasite_defanged", "拔牙寄生虫","defanged" },
    { "asw_boomer",           "爆裂虫",     "boomer"   },
    { "asw_ranger",           "游侠",       "ranger"   },
    { "asw_shieldbug",        "盾甲虫",     "shield"   },
    { "asw_mortarbug",        "迫击炮虫",   "mortar"   },
    { "asw_harvester",        "收割者",     "harvester"},
    { "asw_grub",             "幼虫",       "grub"     }
};

// ─── ConVar 句柄 ─────────────────────────────────────────
ConVar g_cvEnabled;
ConVar g_cvType;
ConVar g_cvCount;
ConVar g_cvSpread;
ConVar g_cvColor;
ConVar g_cvPublic;
ConVar g_cvDebug;

// 缓存本批生成时从 marine 读到的真实 faction 值 (避免每只虫都扫一次 marine)
int g_iCachedMarineFaction = -1;

// 跟踪本插件生成的所有叛变虫实体引用, 换图/换挑战前恢复阵营用
ArrayList g_hBetrayAliens;

// 叛变虫的原始(alien)阵营值, 首次读到真值时缓存 (实测 = 2), 恢复阵营用
int g_iAlienFaction = -1;

// 缓存本批生成时从 marine 读到的真实 team 值 (m_iTeamNum), 改 team 用
int g_iCachedMarineTeam = -1;
// 叛变虫的原始(alien)team 值, 首次读到真值时缓存, 恢复 team 用
int g_iAlienTeam = -1;

// ============================================================================
//  插件信息
// ============================================================================
public Plugin myinfo = {
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "生成攻击虫族的叛变虫群, 可着色区分、免冷却、自选虫种",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
//  插件加载
// ============================================================================
public void OnPluginStart()
{
    PrintToServer("[叛变虫群] v%s 已加载 (改 m_nFaction 方案)", PLUGIN_VERSION);

    CreateConVar("sm_asrd_betray_version", PLUGIN_VERSION,
        "插件版本", FCVAR_NOTIFY | FCVAR_DONTRECORD);

    g_cvEnabled = CreateConVar(
        "sm_asrd_betray_enabled", "1",
        "启用/禁用叛变虫群 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvType = CreateConVar(
        "sm_asrd_betray_type", "asw_drone",
        "默认生成的虫种类名 (见 sm_betray_list)",
        FCVAR_NOTIFY);

    g_cvCount = CreateConVar(
        "sm_asrd_betray_count", "10",
        "默认每批生成数量",
        FCVAR_NOTIFY, true, 1.0, true, float(MAX_BATCH));

    g_cvSpread = CreateConVar(
        "sm_asrd_betray_spread", "120.0",
        "生成时相对召唤者位置的散布半径(游戏单位)",
        FCVAR_NOTIFY, true, 0.0, true, 500.0);

    g_cvColor = CreateConVar(
        "sm_asrd_betray_color", "255 40 40",
        "叛变虫着色 RGB (如 180 0 255 紫色), 用空格分隔",
        FCVAR_NOTIFY);

    g_cvPublic = CreateConVar(
        "sm_asrd_betray_public", "0",
        "允许普通玩家使用 sm_betraypub (0=仅管理员 1=所有人)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvDebug = CreateConVar(
        "sm_asrd_betray_debug", "0",
        "调试输出 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    AutoExecConfig(true, "asrd_alien_civilwar");

    g_hBetrayAliens = new ArrayList();

    RegAdminCmd("sm_betray", Command_Betray, ADMFLAG_GENERIC,
        "生成一批叛变虫群. 用法: sm_betray [type] [count]");
    RegConsoleCmd("sm_betraypub", Command_BetrayPublic, "生成叛变虫群 (需管理员开启)");
    RegAdminCmd("sm_betray_list", Command_List, ADMFLAG_GENERIC, "列出可生成的虫种");
    RegAdminCmd("sm_betray_clear", Command_Clear, ADMFLAG_GENERIC, "清除本插件生成的叛变虫");

    // 任务/回合结束事件 (Pre): 任务结束时尽早清理。
    HookEvent("round_end",           Event_RestoreAliens, EventHookMode_Pre);
    HookEvent("asw_mission_restart", Event_RestoreAliens, EventHookMode_Pre);
    HookEvent("mission_failed",      Event_RestoreAliens, EventHookMode_Pre);
    HookEvent("mission_success",     Event_RestoreAliens, EventHookMode_Pre);
    HookEvent("map_transition",      Event_RestoreAliens, EventHookMode_Pre);

    // 回合/游戏/任务开始事件 (Post): 换挑战/重新开始任务是软重启, 触发的是
    // "开始"类事件而不是"结束"事件。round_start_pre_entity 在实体重新生成
    // 之前触发, 此时旧叛变虫还在场上、新虫族还没生成 → 清理的最佳时机。
    // 用 Post 确保事件已发生、旧叛变虫仍在场上时才清理。
    HookEvent("round_start_pre_entity", Event_RestoreAliens, EventHookMode_Post);
    HookEvent("round_start",         Event_RestoreAliens, EventHookMode_Post);
    HookEvent("game_start",          Event_RestoreAliens, EventHookMode_Post);
    HookEvent("asw_mission_start",   Event_RestoreAliens, EventHookMode_Post);

    // 周期检测软重启兜底: 若上述事件因某些原因没触发, 用"场上无 marine"
    // (软重启时 marine 被重建, 短暂消失) 作为备用信号, 立即清理。
    CreateTimer(0.1, Timer_CheckSoftRestart, _, TIMER_REPEAT);
}

// ============================================================================
//  周期检测软重启: 场上没有 marine 且还有叛变虫残留 → 立即清理
// ============================================================================
Action Timer_CheckSoftRestart(Handle hTimer)
{
    if (g_hBetrayAliens == null || g_hBetrayAliens.Length == 0)
        return Plugin_Continue;

    // 场上没有 marine = 软重启/lobby/主菜单 (mission 进行中通常有 marine)。
    // 此时若叛变虫残留(marine faction), 软重启处理虫族会崩, 立即清理。
    if (FindEntityByClassname(-1, "asw_marine") == -1)
    {
        if (g_cvDebug.BoolValue)
            PrintToServer("[叛变虫群] 检测到软重启(场上无 marine), 立即清理 %d 只叛变虫",
                g_hBetrayAliens.Length);
        RestoreAllBetrayAliens();
    }

    return Plugin_Continue;
}

// ============================================================================
//  地图加载: 重置 marine faction 缓存, 清空上一局的叛变虫引用
// ============================================================================
public void OnMapStart()
{
    g_iCachedMarineFaction = -1;
    g_iAlienFaction = -1;          // 换图后重新读 alien 真值
    g_iCachedMarineTeam = -1;
    g_iAlienTeam = -1;
    if (g_hBetrayAliens != null)
        g_hBetrayAliens.Clear();    // 旧实体的引用全部失效
}

// ============================================================================
//  地图结束(换图/换挑战): 把所有叛变虫恢复成正常虫族阵营。
//  叛变虫是"虫族实体 + marine faction"的矛盾状态, 若带着这个状态被销毁或
//  残留到下一个挑战, 遇到会处理场上虫族的挑战(如 ASBI Weapon Balancing)
//  会段错误崩溃。所以在换图前把它们改回 alien 阵营, 消除矛盾状态。
// ============================================================================
public void OnMapEnd()
{
    RestoreAllBetrayAliens();
}

public void OnPluginEnd()
{
    RestoreAllBetrayAliens();
}

// ============================================================================
//  命令 (管理员): sm_betray [type] [count]
// ============================================================================
public Action Command_Betray(int client, int args)
{
    return DoBetray(client, args);
}

// ============================================================================
//  命令 (玩家): sm_betraypub [type] [count]
// ============================================================================
public Action Command_BetrayPublic(int client, int args)
{
    if (!g_cvPublic.BoolValue)
    {
        ReplyToCommand(client, "[叛变虫群] 该功能未对玩家开放");
        return Plugin_Handled;
    }
    return DoBetray(client, args);
}

// ============================================================================
//  核心: 解析参数并生成
// ============================================================================
Action DoBetray(int client, int args)
{
    if (!g_cvEnabled.BoolValue)
    {
        ReplyToCommand(client, "[叛变虫群] 功能已禁用");
        return Plugin_Handled;
    }

    // ── 解析虫种 ──
    char sType[64];
    g_cvType.GetString(sType, sizeof(sType));

    if (args >= 1)
    {
        char sArg[64];
        GetCmdArg(1, sArg, sizeof(sArg));
        if (!ResolveType(sArg, sType, sizeof(sType)))
        {
            ReplyToCommand(client, "[叛变虫群] 未知虫种 \"%s\", 用 sm_betray_list 查看可选虫种", sArg);
            return Plugin_Handled;
        }
    }

    // ── 解析数量 ──
    int iCount = g_cvCount.IntValue;
    if (args >= 2)
    {
        char sArg[16];
        GetCmdArg(2, sArg, sizeof(sArg));
        int n = StringToInt(sArg);
        if (n > 0)
            iCount = n;
    }
    if (iCount < 1) iCount = 1;
    if (iCount > MAX_BATCH) iCount = MAX_BATCH;

    // ── 生成中心: 召唤者控制的陆战队员 ──
    float fCenter[3];
    if (!GetMarineOrigin(client, fCenter))
    {
        ReplyToCommand(client, "[叛变虫群] 无法确定生成位置");
        return Plugin_Handled;
    }

    // 每批生成开始时清空 marine faction 缓存, 重新从场上 marine 读真值
    g_iCachedMarineFaction = -1;

    float fSpread = g_cvSpread.FloatValue;
    int iOk = 0;

    for (int i = 0; i < iCount; i++)
    {
        float fPos[3];
        fPos[0] = fCenter[0] + GetRandomFloat(-fSpread, fSpread);
        fPos[1] = fCenter[1] + GetRandomFloat(-fSpread, fSpread);
        fPos[2] = fCenter[2];

        if (SpawnAlien(sType, fPos) != -1)
            iOk++;
    }

    if (g_cvDebug.BoolValue)
        PrintToServer("[叛变虫群] type=%s count=%d 成功=%d", sType, iCount, iOk);

    char sName[MAX_NAME_LENGTH];
    GetClientName(client, sName, sizeof(sName));
    PrintToChatAll("\x04[叛变虫群]\x01 %s 召唤了 %d 只\x05叛变%s\x01!",
        sName, iOk, sType);

    return Plugin_Handled;
}

// ============================================================================
//  生成单个叛变虫
// ============================================================================
int SpawnAlien(const char[] sClass, const float fPos[3])
{
    int ent = CreateEntityByName(sClass);
    if (ent == -1)
    {
        if (g_cvDebug.BoolValue)
            PrintToServer("[叛变虫群] 创建实体 %s 失败", sClass);
        return -1;
    }

    // 打统一标记, 供清除命令匹配
    DispatchKeyValue(ent, "targetname", INFECTED_NAME);
    // 强制睡眠时也渲染 (AS:RD 睡眠虫默认不渲染)
    DispatchKeyValue(ent, "visiblewhenasleep", "1");

    float fAng[3];
    fAng[1] = GetRandomFloat(0.0, 360.0);
    // 先设位置再生成, 对齐 asw_spawner 的 SetAbsOrigin → DispatchSpawn 顺序
    TeleportEntity(ent, fPos, fAng, NULL_VECTOR);

    DispatchSpawn(ent);
    ActivateEntity(ent);

    // 生成后再确认一次位置 (兜底, 防 NPC 出生重置回原点)
    TeleportEntity(ent, fPos, fAng, NULL_VECTOR);

    // 着色区分
    ApplyTint(ent);

    // 改阵营: spawn 后立即改 m_nFaction 为 marine 阵营
    SetToMarineFaction(ent);

    // 0.1s 后单次重设, 防 AS:RD 在 NPCInit/Think 里重置 faction。
    // 只做单次 (持续守护在 think 中途改 faction 会段错误崩溃)。
    CreateTimer(0.1, Timer_ReassertFaction, EntIndexToEntRef(ent));

    // 记录实体引用, 供换图/换挑战前恢复阵营
    g_hBetrayAliens.Push(EntIndexToEntRef(ent));

    return ent;
}

// ============================================================================
//  faction 读写: AS:RD 的 faction 字段是 m_nFaction (datamap 偏移 1800, 实测),
//  不是标准 Source SDK 的 m_iFaction。用 datamap 读写 (FindDataMapInfo +
//  GetEntData/SetEntData), 绕开 SendProp 的 GetEntProp 类型不匹配问题。
// ============================================================================
int GetFaction(int ent)
{
    int off = FindDataMapInfo(ent, "m_nFaction");
    if (off >= 0)
        return GetEntData(ent, off, 4);
    off = FindDataMapInfo(ent, "m_iFaction");
    if (off >= 0)
        return GetEntData(ent, off, 4);
    return -1;
}

bool WriteFaction(int ent, int val)
{
    int off = FindDataMapInfo(ent, "m_nFaction");
    if (off >= 0)
    {
        SetEntData(ent, off, val, 4, true);
        return true;
    }
    off = FindDataMapInfo(ent, "m_iFaction");
    if (off >= 0)
    {
        SetEntData(ent, off, val, 4, true);
        return true;
    }
    return false;
}

// ============================================================================
//  team 读写: m_iTeamNum (datamap 偏移 444, 实测)。改 team 是为了让叛变虫
//  "队伍"和"阵营"一致 (都变成 marine), 消除"team=虫族 + faction=marine"的
//  矛盾。ASBI Weapon Balancing 等挑战按 m_iTeamNum 识别虫族, 若 team 还是
//  虫族、faction 是 marine, 换挑战处理虫族时撞上矛盾 → 段错误。
// ============================================================================
int GetTeam(int ent)
{
    int off = FindDataMapInfo(ent, "m_iTeamNum");
    if (off >= 0)
        return GetEntData(ent, off, 4);
    return -1;
}

bool WriteTeam(int ent, int val)
{
    int off = FindDataMapInfo(ent, "m_iTeamNum");
    if (off >= 0)
    {
        SetEntData(ent, off, val, 4, true);
        return true;
    }
    return false;
}

// ============================================================================
//  改阵营 + 改队伍: 把叛变虫的 m_nFaction 和 m_iTeamNum 都改成 marine 值,
//  让它成为"完整的 marine 阵营虫族" (team/faction 一致), 而非"虫族 team +
//  marine faction"的矛盾状态。不假设枚举顺序, 从场上 asw_marine 读真值。
// ============================================================================
void SetToMarineFaction(int ent)
{
    int iAlienFaction = GetFaction(ent);
    if (iAlienFaction < 0)
    {
        PrintToServer("[叛变虫群] #%d 未找到 faction 字段, 改阵营失败", ent);
        return;
    }

    // 首次读到 alien 真值时缓存 (此时虫刚 spawn 还没被改, 值就是 alien 阵营),
    // 供换图前恢复用。Timer_ReassertFaction 二次调用时读到的是已改后的值,
    // 但因 g_iAlienFaction 已缓存, 不会被覆盖。
    if (g_iAlienFaction < 0)
        g_iAlienFaction = iAlienFaction;

    int iAlienTeam = GetTeam(ent);
    if (g_iAlienTeam < 0)
        g_iAlienTeam = iAlienTeam;

    int iMarineFaction = ResolveMarineFaction(iAlienFaction);
    int iMarineTeam = ResolveMarineTeam(iAlienTeam);

    if (!WriteFaction(ent, iMarineFaction))
    {
        PrintToServer("[叛变虫群] #%d 写 faction 失败", ent);
        return;
    }
    WriteTeam(ent, iMarineTeam);

    int iAfterFaction = GetFaction(ent);
    int iAfterTeam = GetTeam(ent);
    PrintToServer("[叛变虫群] #%d 改阵营 faction alien=%d->marine=%d 写后=%d%s | team alien=%d->marine=%d 写后=%d%s",
        ent, iAlienFaction, iMarineFaction, iAfterFaction,
        (iAfterFaction == iMarineFaction) ? "(OK)" : "(失败)",
        iAlienTeam, iMarineTeam, iAfterTeam,
        (iAfterTeam == iMarineTeam) ? "(OK)" : "(失败)");
}

// ----------------------------------------------------------------------------
//  取 marine 阵营值: 缓存优先, 否则扫场上 asw_marine 读真值, 兜底 alien-1。
// ----------------------------------------------------------------------------
int ResolveMarineFaction(int iAlienFaction)
{
    if (g_iCachedMarineFaction >= 0)
        return g_iCachedMarineFaction;

    int iMarine = FindEntityByClassname(-1, "asw_marine");
    if (iMarine > 0 && IsValidEntity(iMarine))
    {
        int iMFaction = GetFaction(iMarine);
        if (iMFaction >= 0 && iMFaction != iAlienFaction)
        {
            g_iCachedMarineFaction = iMFaction;
            PrintToServer("[叛变虫群] marine #%d faction=%d", iMarine, iMFaction);
            return iMFaction;
        }
    }

    g_iCachedMarineFaction = iAlienFaction - 1;
    PrintToServer("[叛变虫群] 场上无 marine, 兜底 marine faction=%d", g_iCachedMarineFaction);
    return g_iCachedMarineFaction;
}

// ----------------------------------------------------------------------------
//  取 marine team 值: 缓存优先, 否则扫场上 asw_marine 读真值, 兜底 alien-1。
// ----------------------------------------------------------------------------
int ResolveMarineTeam(int iAlienTeam)
{
    if (g_iCachedMarineTeam >= 0)
        return g_iCachedMarineTeam;

    int iMarine = FindEntityByClassname(-1, "asw_marine");
    if (iMarine > 0 && IsValidEntity(iMarine))
    {
        int iMTeam = GetTeam(iMarine);
        if (iMTeam >= 0 && iMTeam != iAlienTeam)
        {
            g_iCachedMarineTeam = iMTeam;
            PrintToServer("[叛变虫群] marine #%d team=%d", iMarine, iMTeam);
            return iMTeam;
        }
    }

    g_iCachedMarineTeam = iAlienTeam - 1;
    PrintToServer("[叛变虫群] 场上无 marine, 兜底 marine team=%d", g_iCachedMarineTeam);
    return g_iCachedMarineTeam;
}

// ============================================================================
//  0.1s 后单次重设 faction
// ============================================================================
Action Timer_ReassertFaction(Handle hTimer, int iEntRef)
{
    int ent = EntRefToEntIndex(iEntRef);
    if (ent > 0 && IsValidEntity(ent))
        SetToMarineFaction(ent);
    return Plugin_Stop;
}

// ============================================================================
//  换图/换挑战前: 彻底清除本插件的所有影响 (含死亡的叛变虫尸体)。
//
//  关键教训: 之前的清理只处理 g_hBetrayAliens 列表里"活着"的叛变虫。但
//  叛变虫死亡后, 原实体的 EntRef 失效(从列表跳过), 而它生成的"marine
//  阵营尸体"是个新实体、不在列表里, 残留到换挑战 → ASBI WB 处理虫族时
//  撞上 marine 阵营的虫族尸体 → 段错误。这就是为什么"只有虫子死亡才崩"。
//
//  做法: 1) 清理列表里活着的叛变虫; 2) 按 targetname 遍历场上所有虫族类
//  实体, 清理匹配 asrd_betray_swarm 的(含尸体), 全部恢复 faction+team 成
//  alien 再 RemoveEntity, 不留任何残留。
// ============================================================================
void RestoreAllBetrayAliens()
{
    if (g_hBetrayAliens == null)
        return;

    int iAlien = (g_iAlienFaction >= 0) ? g_iAlienFaction : 2;  // 兜底 2 (实测 alien 阵营值)
    int iAlienTeam = (g_iAlienTeam >= 0) ? g_iAlienTeam : 2;    // 兜底 2 (实测 alien team 值)

    int iCleaned = 0;

    // 1) 清理 g_hBetrayAliens 列表里活着的叛变虫
    int n = g_hBetrayAliens.Length;
    for (int i = 0; i < n; i++)
    {
        int ref = g_hBetrayAliens.Get(i);
        int ent = EntRefToEntIndex(ref);
        if (ent == INVALID_ENT_REFERENCE || !IsValidEntity(ent))
            continue;
        RestoreAlienAndRemove(ent, iAlien, iAlienTeam);
        iCleaned++;
    }
    g_hBetrayAliens.Clear();

    // 2) 清理死亡的叛变虫尸体/残留: 死亡的叛变虫不在列表里, 但其尸体实体
    //    可能保留 targetname=asrd_betray_swarm。按 targetname 遍历场上所有
    //    虫族类实体, 清理匹配的 (含尸体/半死亡实体)。
    for (int t = 0; t < sizeof(g_sTypes); t++)
    {
        int ent = -1;
        while ((ent = FindEntityByClassname(ent, g_sTypes[t][0])) != -1)
        {
            char sName[64];
            GetEntPropString(ent, Prop_Data, "m_iName", sName, sizeof(sName));
            if (!StrEqual(sName, INFECTED_NAME))
                continue;
            RestoreAlienAndRemove(ent, iAlien, iAlienTeam);
            iCleaned++;
        }
    }

    if (g_cvDebug.BoolValue)
        PrintToServer("[叛变虫群] 游戏结束清理: 恢复并销毁 %d 只叛变虫(含尸体)", iCleaned);
}

// ----------------------------------------------------------------------------
//  恢复单个实体的 faction+team 成 alien, 然后 RemoveEntity 立即移除。
//  RemoveEntity 而非 Kill: Kill 走死亡流程(死亡动画+尸体+延迟移除)会残留,
//  RemoveEntity 直接移除不留残留。
// ----------------------------------------------------------------------------
void RestoreAlienAndRemove(int ent, int iAlien, int iAlienTeam)
{
    int off = FindDataMapInfo(ent, "m_nFaction");
    if (off < 0)
        off = FindDataMapInfo(ent, "m_iFaction");
    if (off >= 0)
        SetEntData(ent, off, iAlien, 4, true);

    int toff = FindDataMapInfo(ent, "m_iTeamNum");
    if (toff >= 0)
        SetEntData(ent, toff, iAlienTeam, 4, true);

    RemoveEntity(ent);
}

// ============================================================================
//  任务/回合结束事件回调: 换挑战/退出任务前恢复叛变虫阵营。
//  AS:RD 换挑战是软重启(不 changelevel), 不触发 OnMapEnd, 只能靠游戏事件
//  在这些时点主动清理, 消除"虫族实体 + marine faction"的矛盾状态。
// ============================================================================
public Action Event_RestoreAliens(Event event, const char[] name, bool dontBroadcast)
{
    if (g_cvDebug.BoolValue)
        PrintToServer("[叛变虫群] 收到事件 %s, 恢复叛变虫阵营", name);

    RestoreAllBetrayAliens();
    return Plugin_Continue;
}

// ============================================================================
//  着色: 用 m_clrRender 给叛变虫染色
// ============================================================================
void ApplyTint(int ent)
{
    int iColor;
    if (!ParseColor(iColor))
        return;

    if (HasEntProp(ent, Prop_Send, "m_nRenderMode"))
        SetEntProp(ent, Prop_Send, "m_nRenderMode", 1, 1);

    if (HasEntProp(ent, Prop_Send, "m_clrRender"))
        SetEntProp(ent, Prop_Send, "m_clrRender", iColor, 4);
}

// ============================================================================
//  解析着色 CVar "R G B" → 0xAABBGGRR
// ============================================================================
bool ParseColor(int &out)
{
    char sColor[32];
    g_cvColor.GetString(sColor, sizeof(sColor));

    int v[3];
    int n = 0;
    char sPart[8];
    int l = 0;
    int len = strlen(sColor);

    for (int i = 0; i <= len; i++)
    {
        if (sColor[i] == ' ' || sColor[i] == '\0')
        {
            if (l > 0 && n < 3)
            {
                sPart[l] = '\0';
                v[n] = StringToInt(sPart);
                n++;
            }
            l = 0;
        }
        else if (IsCharNumeric(sColor[i]) && l < sizeof(sPart) - 1)
        {
            sPart[l++] = sColor[i];
        }
        else
        {
            return false;
        }
    }

    if (n < 3)
        return false;

    int r = ClampI(v[0]);
    int g = ClampI(v[1]);
    int b = ClampI(v[2]);

    out = (255 << 24) | (b << 16) | (g << 8) | r;
    return true;
}

int ClampI(int v)
{
    if (v < 0) return 0;
    if (v > 255) return 255;
    return v;
}

// ============================================================================
//  命令: 列出可生成虫种
// ============================================================================
public Action Command_List(int client, int args)
{
    ReplyToCommand(client, "[叛变虫群] 可生成虫种 (类名 = 中文名):");
    for (int i = 0; i < sizeof(g_sTypes); i++)
        ReplyToCommand(client, "  %s = %s", g_sTypes[i][0], g_sTypes[i][1]);
    return Plugin_Handled;
}

// ============================================================================
//  命令: 清除本插件生成的叛变虫
// ============================================================================
public Action Command_Clear(int client, int args)
{
    int iCount = 0;
    for (int t = 0; t < sizeof(g_sTypes); t++)
    {
        int ent = -1;
        while ((ent = FindEntityByClassname(ent, g_sTypes[t][0])) != -1)
        {
            char sName[64];
            GetEntPropString(ent, Prop_Data, "m_iName", sName, sizeof(sName));
            if (StrEqual(sName, INFECTED_NAME))
            {
                AcceptEntityInput(ent, "Kill");
                iCount++;
            }
        }
    }

    ReplyToCommand(client, "[叛变虫群] 已清除 %d 只叛变虫", iCount);
    return Plugin_Handled;
}

// ============================================================================
//  虫种解析: 支持类名 / 别名 / 中文名 (大小写不敏感)
// ============================================================================
bool ResolveType(const char[] sInput, char[] sOut, int outLen)
{
    for (int i = 0; i < sizeof(g_sTypes); i++)
    {
        if (StrEqual(sInput, g_sTypes[i][0], false)
            || StrEqual(sInput, g_sTypes[i][2], false)
            || StrEqual(sInput, g_sTypes[i][1], false))
        {
            strcopy(sOut, outLen, g_sTypes[i][0]);
            return true;
        }
    }
    return false;
}

// ============================================================================
//  取召唤者控制的陆战队员坐标
// ============================================================================
bool GetMarineOrigin(int client, float fOut[3])
{
    if (client <= 0 || !IsClientInGame(client))
        return false;

    int iMarine = GetPlayerMarine(client);
    if (IsValidEntity(iMarine))
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

    // 办法1: 玩家身上的 m_hInhabiting 网络属性
    char sNetClass[64];
    if (GetEntityNetClass(client, sNetClass, sizeof(sNetClass))
        && FindSendPropInfo(sNetClass, "m_hInhabiting") > 0)
    {
        int iMarine = GetEntPropEnt(client, Prop_Send, "m_hInhabiting");
        if (iMarine > 0 && IsValidEntity(iMarine))
            return iMarine;
    }

    // 办法2: 数据属性
    if (FindDataMapInfo(client, "m_hInhabiting") > 0)
    {
        int iMarine = GetEntPropEnt(client, Prop_Data, "m_hInhabiting");
        if (iMarine > 0 && IsValidEntity(iMarine))
            return iMarine;
    }

    // 办法3: 遍历 marine, 找操控者是该玩家的那个
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "asw_marine")) != -1)
    {
        if (FindDataMapInfo(ent, "m_hCommander") > 0
            && GetEntPropEnt(ent, Prop_Data, "m_hCommander") == client)
            return ent;
    }

    return 0;
}
