/**
 * ============================================================================
 *  Plugin: [AS:RD] 叛变虫群 (Alien Civil War)
 *
 *  描述: 生成一批"叛变虫群", 它们的攻击对象是**虫族**而不是玩家。
 *        通过着色(RenderColor)与普通虫族在外观上区分, 免冷却, 可自选虫种。
 *  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  命令:
 *    sm_betray     [type] [count] [target]  管理员: 生成一批叛变虫群 (可指定虫种/数量/生成到某玩家身旁)
 *    sm_betraypub  [type] [count]           玩家:   同上 (需管理员开启 public, 只能生成在自己身旁)
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
 *    3. spawn 后 (ActivateEntity 之前) 立即改一次 faction —— 此后永不改写
 *       (中途改写会导致 Source AI 段错误, 详见下方"踩过的坑")。
 *    4. SetEntProp(m_clrRender) 着色, 与正常虫族外观区分。
 *
 *  踩过的坑 (详见项目记忆):
 *    - ai_relationship 的 ApplyRelationship 遇实际虫族实体会段错误崩溃 server,
 *      该方案在 AS:RD 不可用。
 *    - 不要在 RepeatingTimer 里持续改 faction, Source AI 不期望 think 中途
 *      改 faction, 会段错误崩溃。只做单次/有限次重设。
 *    - GetEntProp(Prop_Send,"m_nFaction") 会抛 native error (类型不匹配),
 *      必须用 FindDataMapInfo + GetEntData/SetEntData 走 datamap。
 *    - RemoveEntity native 在 AS:RD 未注册, 会导致插件加载失败, 一律用
 *      AcceptEntityInput(ent, "Kill")。
 *    - v4.0.0 核心结论 (经 reactivedrop_public_src 源码核实): 之前九轮
 *      "换图/换挑战前恢复阵营+Kill 清理"全部失败且本身有害:
 *      1) 游戏的 RestartMission(即时重启) 自己会按 classname 遍历
 *         UTIL_Remove 所有虫族实体 + CleanupDeleteList, 实体销毁流程
 *         (UpdateOnRemove→析构→AutoList 移除) 根本不读 faction, "恢复
 *         阵营再删除"毫无必要;
 *      2) 事件回调(asw_mission_restart 等)在游戏帧处理中段触发, 在其中
 *         改写 AI 活跃实体的 faction 正是已知的段错误模式;
 *      3) FindAndModifyAlienHealth (历史怀疑的崩溃点) 只做血量数学运算,
 *         与 faction 无关, 历史诊断不成立;
 *      4) 0.1s 重设定时器同理: 在 NPC 首次 think 后改 faction, 且日志
 *         证实首写从未被游戏重置, 重设是多余的 no-op 写入。
 *      故 v4.0.0 起: faction 只在 spawn 后立即写一次(实体首次 think 之前),
 *      之后永不改写; 实体删除只用原生 Kill(游戏自己也在用); 不再挂钩
 *      任何"结束/开始"事件做清理, 让游戏自己的重启流程删实体。
 *    - 叛变虫残留崩溃的历史真相: 各版本崩溃时唯一恒定的因素是"对
 *      AI 活跃中的实体中途改写 faction"(spawn 后 0.1s 重设 + 事件回调
 *      清理), 而非实体残留本身。v4.0.0 移除全部中途改写后观察验证。
 *    - 真正根因 (v4.1.0, 经源码核实): CBaseCombatCharacter 维护进程级全局
 *      m_aFactions[阵营]->实体列表。虫子 Spawn() 时 ChangeFaction(FACTION_ALIENS)
 *      把它加入 alien 列表; 插件 SetEntData 直接写 m_nFaction=marine (绕过
 *      ChangeFaction), 造成 m_nFaction 与所在列表不一致。虫子被删时析构按
 *      m_nFaction 从 marine 列表移除(no-op), 在 m_aFactions[FACTION_ALIENS]
 *      留下悬空 EHANDLE; 该全局仅引擎关闭时 Purge, 悬空指针永不清理;
 *      切换挑战/新任务遍历该列表时段错误崩溃。修复: OnEntityDestroyed 里
 *      在析构前把 m_nFaction 改回 alien, 使析构从正确列表移除。
 *
 *  依赖: SourceMod 1.11+ (核心 + sdktools + sdkhooks)
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] 叛变虫群"
#define PLUGIN_VERSION "4.6.0"

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
ConVar g_cvDroneScale;
ConVar g_cvDamageMult;
ConVar g_cvHealthMult;
ConVar g_cvSpeedMult;
ConVar g_cvAnimMult;

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
        "sm_asrd_betray_color", "37 217 73",
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

    g_cvDroneScale = CreateConVar(
        "sm_asrd_betray_drone_scale", "1.0",
        "叛变 drone 体型缩放倍率 (仅 asw_drone, 1.0=默认大小)",
        FCVAR_NOTIFY, true, 0.1, true, 10.0);

    g_cvDamageMult = CreateConVar(
        "sm_asrd_betray_damage_mult", "4.0",
        "叛变虫攻击力倍率 (仅叛变虫造成的伤害, 1.0=不增强)",
        FCVAR_NOTIFY, true, 1.0, true, 100.0);

    g_cvHealthMult = CreateConVar(
        "sm_asrd_betray_health_mult", "10.0",
        "叛变虫血量倍率 (仅叛变虫, 1.0=默认血量)",
        FCVAR_NOTIFY, true, 1.0, true, 100.0);

    g_cvSpeedMult = CreateConVar(
        "sm_asrd_betray_speed_mult", "2.0",
        "叛变虫移动速度倍率 (仅叛变虫, 1.0=默认速度)",
        FCVAR_NOTIFY, true, 1.0, true, 10.0);

    g_cvAnimMult = CreateConVar(
        "sm_asrd_betray_anim_mult", "2.0",
        "叛变虫动画速度倍率 (仅叛变虫, 1.0=默认动画速度)",
        FCVAR_NOTIFY, true, 1.0, true, 10.0);

    g_hBetrayAliens = new ArrayList();

    RegAdminCmd("sm_betray", Command_Betray, ADMFLAG_GENERIC,
        "生成一批叛变虫群. 用法: sm_betray [type] [count] [target]");
    RegConsoleCmd("sm_betraypub", Command_BetrayPublic, "生成叛变虫群 (需管理员开启)");
    RegAdminCmd("sm_betray_list", Command_List, ADMFLAG_GENERIC, "列出可生成的虫种");
    RegAdminCmd("sm_betray_clear", Command_Clear, ADMFLAG_GENERIC, "清除本插件生成的叛变虫");

    // v4.0.1 诊断探针: asw_mission_restart 是实测存在的事件 (v3.9.0 日志证明)。
    // 挂它而非 asw_mission_start (后者在 AS:RD 不存在, v4.0.0 挂了从未触发)。
    // 用途: 事件在 RestartMission 删实体**之前**触发, 延迟 1s 后统计实体数,
    // 实证"游戏重启是否真的删掉了叛变虫"(源码 CASW_Map_Reset_Filter 分析
    // 的结论), 并为崩溃日志提供时间锚点。
    HookEventEx("asw_mission_restart", Event_DiagRestart, EventHookMode_Post);
}

// 重启事件: 调度 1s 后的实体清点 (此时实体删除早已完成)
public void Event_DiagRestart(Event event, const char[] name, bool dontBroadcast)
{
    CreateTimer(1.0, Timer_DiagAfterRestart);
}

// 1s 后清点: 存活叛变虫(按列表) + 场上全部虫族类实体(按 classname)
Action Timer_DiagAfterRestart(Handle hTimer)
{
    int iBetrayAlive = 0;
    if (g_hBetrayAliens != null)
    {
        int n = g_hBetrayAliens.Length;
        for (int i = 0; i < n; i++)
        {
            int ent = EntRefToEntIndex(g_hBetrayAliens.Get(i));
            if (ent > 0 && IsValidEntity(ent) && GetEntProp(ent, Prop_Data, "m_iHealth") > 0)
                iBetrayAlive++;
        }
    }

    int iTotal = 0;
    for (int t = 0; t < sizeof(g_sTypes); t++)
    {
        int ent = -1;
        while ((ent = FindEntityByClassname(ent, g_sTypes[t][0])) != -1)
            iTotal++;
    }

    PrintToServer("[叛变虫群] 重启后 1s: 存活叛变虫 %d / 列表 %d, 场上虫族类实体 %d",
        iBetrayAlive, g_hBetrayAliens != null ? g_hBetrayAliens.Length : 0, iTotal);
    return Plugin_Stop;
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
//  地图结束(换图): 只清空引用列表。
// 实体随地图卸载由引擎销毁, 销毁流程不读 faction, 无需任何恢复/删除操作。
// ============================================================================
public void OnMapEnd()
{
    if (g_hBetrayAliens != null)
        g_hBetrayAliens.Clear();
}

// ============================================================================
//  实体销毁前回调: 恢复 faction 一致性 (v4.1.0 崩溃根因修复)。
//
//  崩溃机制 (经 reactivedrop_public_src 源码核实):
//    CBaseCombatCharacter 维护进程级全局 m_aFactions[阵营] -> 实体列表。
//    1) 虫子 DispatchSpawn -> CASW_Alien::Spawn() -> ChangeFaction(FACTION_ALIENS)
//       -> 虫子加入 m_aFactions[FACTION_ALIENS];
//    2) 插件 SetEntData 直接写 m_nFaction=marine (绕过 ChangeFaction),
//       m_nFaction 内存值=marine, 但虫子仍在 m_aFactions[FACTION_ALIENS] 里;
//    3) 虫子被删(死亡尸体消失/重启/清理) -> ~CBaseCombatCharacter 按
//       m_nFaction 从 m_aFactions[marine] 移除(虫子不在那, no-op)
//       -> m_aFactions[FACTION_ALIENS] 留下悬空 EHANDLE;
//    4) m_aFactions 是进程级全局(仅引擎关闭时 Purge), 悬空指针永不清理;
//    5) 切换挑战/新任务刷虫时游戏遍历 m_aFactions[FACTION_ALIENS]
//       -> 访问悬空指针 -> 段错误崩溃。
//  修复: 在实体析构前把 m_nFaction 改回 alien, 使析构从正确列表移除,
//        不产生悬空指针。OnEntityDestroyed 在实体真正析构前触发, 安全。
// ============================================================================
public void OnEntityDestroyed(int entity)
{
    // 只处理本插件生成的叛变虫 (targetname 判定, 快路径)
    char sName[64];
    GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));
    if (!StrEqual(sName, INFECTED_NAME))
        return;

    // 改回 alien 阵营, 让 ~CBaseCombatCharacter 从 m_aFactions[FACTION_ALIENS]
    // 正确移除自己 (m_nFaction 与所在列表一致), 消除悬空指针。
    int off = FindDataMapInfo(entity, "m_nFaction");
    if (off < 0)
        off = FindDataMapInfo(entity, "m_iFaction");
    if (off >= 0)
        SetEntData(entity, off, (g_iAlienFaction >= 0) ? g_iAlienFaction : 2, 4, true);
}

// ============================================================================
//  插件卸载: 用原生 Kill 销毁所有叛变虫 (绝不能留着 faction=marine 的虫
//  在场上跑), 并清空列表。注意不改写 faction —— 对 AI 活跃实体中途改写
//  faction 正是已知的段错误模式; 实体即将销毁, 恢复阵营毫无意义。
// ============================================================================
public void OnPluginEnd()
{
    KillAllBetrayAliens();
}

// ============================================================================
//  命令 (管理员): sm_betray [type] [count]
// ============================================================================
public Action Command_Betray(int client, int args)
{
    return DoBetray(client, args, true);   // 管理员: 允许指定生成到某玩家身旁
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
    return DoBetray(client, args, false);   // 普通玩家: 只能生成在自己身旁
}

// ============================================================================
//  核心: 解析参数并生成。
//  bAllowTarget=true 时, 可选参数3 指定生成到某玩家身旁; 缺省=召唤者自己。
// ============================================================================
Action DoBetray(int client, int args, bool bAllowTarget)
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

    // ── 生成中心: 默认召唤者自己; 管理员可在参数3 指定目标玩家 ──
    int iTargetClient = 0;   // 0 = 召唤者自己
    if (bAllowTarget && args >= 3)
    {
        char sArg[64];
        GetCmdArg(3, sArg, sizeof(sArg));
        iTargetClient = FindTargetPlayer(client, sArg);
        if (iTargetClient == 0)
            return Plugin_Handled;
    }

    float fCenter[3];
    if (!GetMarineOrigin((iTargetClient != 0) ? iTargetClient : client, fCenter))
    {
        ReplyToCommand(client, "[叛变虫群] 无法确定生成位置");
        return Plugin_Handled;
    }

    // 每批生成开始时清空 marine faction/team 缓存, 重新从场上 marine 读真值
    g_iCachedMarineFaction = -1;
    g_iCachedMarineTeam = -1;

    // 先解析 marine 阵营/队伍值, 失败则整批中止。绝不能兜底成 alien-1
    // (会写出 team=-1/faction=1 的危险矛盾状态, 换挑战时被游戏处理虫族崩溃)。
    int iAlienF = (g_iAlienFaction >= 0) ? g_iAlienFaction : 2;
    int iMarineFaction = ResolveMarineFaction(iAlienF);
    int iMarineTeam = ResolveMarineTeam();
    if (iMarineFaction < 0 || iMarineTeam < 0)
    {
        ReplyToCommand(client, "[叛变虫群] 场上没有可用的陆战队员, 无法确定 marine 阵营, 已中止生成");
        return Plugin_Handled;
    }

    float fSpread = g_cvSpread.FloatValue;
    int iOk = 0;

    for (int i = 0; i < iCount; i++)
    {
        float fPos[3];
        fPos[0] = fCenter[0] + GetRandomFloat(-fSpread, fSpread);
        fPos[1] = fCenter[1] + GetRandomFloat(-fSpread, fSpread);
        fPos[2] = fCenter[2];

        if (SpawnAlien(sType, fPos, iMarineFaction, iMarineTeam) != -1)
            iOk++;
    }

    if (g_cvDebug.BoolValue)
        PrintToServer("[叛变虫群] type=%s count=%d 成功=%d", sType, iCount, iOk);

    char sCaster[MAX_NAME_LENGTH], sTarget[MAX_NAME_LENGTH];
    GetClientName(client, sCaster, sizeof(sCaster));
    if (iTargetClient != 0)
    {
        GetClientName(iTargetClient, sTarget, sizeof(sTarget));
        PrintToChatAll("\x04[叛变虫群]\x01 %s 在 \x05%s\x01 身旁召唤了 %d 只\x05叛变%s\x01!",
            sCaster, sTarget, iOk, sType);
    }
    else
    {
        PrintToChatAll("\x04[叛变虫群]\x01 %s 召唤了 %d 只\x05叛变%s\x01!",
            sCaster, iOk, sType);
    }

    // 生成成功后扫描一次, 给场上已有虫族挂伤害回调 (新刷虫族由 OnEntityCreated 自动挂)
    if (iOk > 0)
        HookAllAliens();

    return Plugin_Handled;
}

// ============================================================================
//  生成单个叛变虫
// ============================================================================
int SpawnAlien(const char[] sClass, const float fPos[3], int iMarineFaction, int iMarineTeam)
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
    // drone 体型缩放: sizescale 是 CASW_Inhabitable_NPC 的 keyvalue,
    // 在 Spawn() 里 SetModelScale(m_fSizeScale) 应用 (仅 asw_drone, 其他虫种不变)
    if (StrEqual(sClass, "asw_drone"))
    {
        char sScale[16];
        FloatToString(g_cvDroneScale.FloatValue, sScale, sizeof(sScale));
        DispatchKeyValue(ent, "sizescale", sScale);
    }

    float fAng[3];
    fAng[1] = GetRandomFloat(0.0, 360.0);
    // 先设位置再生成, 对齐 asw_spawner 的 SetAbsOrigin → DispatchSpawn 顺序
    TeleportEntity(ent, fPos, fAng, NULL_VECTOR);

    DispatchSpawn(ent);

    // v4.0.0: faction 改写放在 ActivateEntity 之前 (实体首次 think 之前)。
    // 此后插件永不改写该实体的 faction —— AI think 中途改 faction 是已证实的
    // 段错误模式 (历史崩溃时 0.1s 重设定时器一直在做这件事)。实测游戏不会
    // 在 spawn 后重置 faction, 单次写入即可长期生效。
    if (!SetToMarineFaction(ent, iMarineFaction, iMarineTeam))
    {
        AcceptEntityInput(ent, "Kill");
        return -1;
    }

    // 死亡方式改为瞬间碎块(kDIE_INSTAGIB=2): 客户端视觉上死亡即碎块。
    // (服务端 drone 的 ShouldGib 恒为 false, 死亡本来就走客户端 ragdoll,
    // 此写入只影响客户端表现, 与崩溃无关, 保留做视觉区分。)
    if (HasEntProp(ent, Prop_Send, "m_nDeathStyle"))
        SetEntProp(ent, Prop_Send, "m_nDeathStyle", 2);

    ActivateEntity(ent);

    // 血量增强: 生成后读取基础血量, 按倍率放大。
    // m_iHealth/m_iMaxHealth 是标准 CBaseEntity 字段, 可直接读写;
    // 放在 ActivateEntity 之后确保 Spawn 流程(含难度血量修正)已完成。
    float fHealthMult = g_cvHealthMult.FloatValue;
    if (fHealthMult > 1.0 && HasEntProp(ent, Prop_Data, "m_iMaxHealth"))
    {
        int iMax = GetEntProp(ent, Prop_Data, "m_iMaxHealth");
        int iNew = RoundToCeil(float(iMax) * fHealthMult);
        SetEntProp(ent, Prop_Data, "m_iMaxHealth", iNew);
        SetEntProp(ent, Prop_Data, "m_iHealth", iNew);
    }

    // 移速增强: 读取基础移动速度, 按倍率放大 (m_flMaxSpeed 优先, 防 AI 覆盖)
    float fSpeedMult = g_cvSpeedMult.FloatValue;
    if (fSpeedMult > 1.0)
    {
        float fBase = 0.0;
        if (HasEntProp(ent, Prop_Data, "m_flMaxSpeed"))
            fBase = GetEntPropFloat(ent, Prop_Data, "m_flMaxSpeed");
        if (fBase <= 0.0 && HasEntProp(ent, Prop_Data, "m_flSpeed"))
            fBase = GetEntPropFloat(ent, Prop_Data, "m_flSpeed");
        if (fBase > 0.0)
        {
            SetEntPropFloat(ent, Prop_Data, "m_flMaxSpeed", fBase * fSpeedMult);
            SetEntPropFloat(ent, Prop_Data, "m_flSpeed", fBase * fSpeedMult);
        }
    }

    // 动画速度增强: 播放速率倍率 (默认 1.0, 直接设为倍率)
    float fAnimMult = g_cvAnimMult.FloatValue;
    if (fAnimMult > 1.0)
    {
        if (HasEntProp(ent, Prop_Send, "m_flPlaybackRate"))
            SetEntPropFloat(ent, Prop_Send, "m_flPlaybackRate", fAnimMult);
        else if (HasEntProp(ent, Prop_Data, "m_flPlaybackRate"))
            SetEntPropFloat(ent, Prop_Data, "m_flPlaybackRate", fAnimMult);
    }

    // 生成后再确认一次位置 (兜底, 防 NPC 出生重置回原点)
    TeleportEntity(ent, fPos, fAng, NULL_VECTOR);

    // 着色区分
    ApplyTint(ent);

    // 记录实体引用, 供清除命令/插件卸载时销毁
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
bool SetToMarineFaction(int ent, int iMarineFaction, int iMarineTeam)
{
    int iAlienFaction = GetFaction(ent);
    if (iAlienFaction < 0)
    {
        PrintToServer("[叛变虫群] #%d 未找到 faction 字段, 改阵营失败", ent);
        return false;
    }

    // 首次读到 alien 真值时缓存 (此时虫刚 spawn 还没被改, 值就是 alien 阵营),
    // 供 DoBetray 的 ResolveMarineFaction 做"marine 值 ≠ alien 值"有效性校验。
    if (g_iAlienFaction < 0)
        g_iAlienFaction = iAlienFaction;

    int iAlienTeam = GetTeam(ent);
    if (g_iAlienTeam < 0)
        g_iAlienTeam = iAlienTeam;

    if (!WriteFaction(ent, iMarineFaction))
    {
        PrintToServer("[叛变虫群] #%d 写 faction 失败", ent);
        return false;
    }
    WriteTeam(ent, iMarineTeam);

    int iAfterFaction = GetFaction(ent);
    int iAfterTeam = GetTeam(ent);
    PrintToServer("[叛变虫群] #%d 改阵营 faction alien=%d->marine=%d 写后=%d%s | team alien=%d->marine=%d 写后=%d%s",
        ent, iAlienFaction, iMarineFaction, iAfterFaction,
        (iAfterFaction == iMarineFaction) ? "(OK)" : "(失败)",
        iAlienTeam, iMarineTeam, iAfterTeam,
        (iAfterTeam == iMarineTeam) ? "(OK)" : "(失败)");

    return true;
}

// ----------------------------------------------------------------------------
//  取 marine 阵营值: 缓存优先, 否则扫场上 asw_marine 读真值。
//  找不到有效值返回 -1, 由调用方中止生成 (绝不兜底成 alien-1, 那会写出
//  faction=1 的危险矛盾状态, 换挑战时被游戏处理虫族崩溃)。
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

    return -1;
}

// ----------------------------------------------------------------------------
//  取 marine team 值: 缓存优先, 否则扫场上 asw_marine 读真值。
//  注意: AS:RD 里 alien team 与 marine team 实测相同(都=0), 所以不需要
//  与 alien team 比较, 只要读到有效值即可。找不到返回 -1 由调用方中止。
// ----------------------------------------------------------------------------
int ResolveMarineTeam()
{
    if (g_iCachedMarineTeam >= 0)
        return g_iCachedMarineTeam;

    int iMarine = FindEntityByClassname(-1, "asw_marine");
    if (iMarine > 0 && IsValidEntity(iMarine))
    {
        int iMTeam = GetTeam(iMarine);
        if (iMTeam >= 0)
        {
            g_iCachedMarineTeam = iMTeam;
            PrintToServer("[叛变虫群] marine #%d team=%d", iMarine, iMTeam);
            return iMTeam;
        }
    }

    return -1;
}

// ============================================================================
//  销毁本插件生成的所有叛变虫 (列表 + targetname 双通道, 纯 Kill)。
//  v4.0.0: 不再改写 faction —— 实体销毁流程(UTIL_Remove/析构)不读 faction,
//  "恢复阵营再删"毫无必要, 且中途改写 AI 活跃实体的 faction 是已证实的
//  段错误模式。只用游戏原生的 Kill (游戏 RestartMission 自己也在用)。
// ============================================================================
void KillAllBetrayAliens()
{
    if (g_hBetrayAliens == null)
        return;

    int iCleaned = 0;

    // 1) 列表里活着的叛变虫
    int n = g_hBetrayAliens.Length;
    for (int i = 0; i < n; i++)
    {
        int ent = EntRefToEntIndex(g_hBetrayAliens.Get(i));
        if (ent == INVALID_ENT_REFERENCE || !IsValidEntity(ent))
            continue;
        AcceptEntityInput(ent, "Kill");
        iCleaned++;
    }
    g_hBetrayAliens.Clear();

    // 2) 按 targetname 扫描残留 (含死亡未消失的尸体实体)
    for (int t = 0; t < sizeof(g_sTypes); t++)
    {
        int ent = -1;
        while ((ent = FindEntityByClassname(ent, g_sTypes[t][0])) != -1)
        {
            char sName[64];
            GetEntPropString(ent, Prop_Data, "m_iName", sName, sizeof(sName));
            if (!StrEqual(sName, INFECTED_NAME))
                continue;
            AcceptEntityInput(ent, "Kill");
            iCleaned++;
        }
    }

    if (iCleaned > 0)
        PrintToServer("[叛变虫群] 销毁 %d 只叛变虫(含尸体/残留)", iCleaned);
}

// ============================================================================
//  攻击力增强: 用 SDKHooks OnTakeDamage 精准放大叛变虫造成的伤害。
//  AS:RD 虫子伤害全部来自全局 ConVar (sk_asw_xxx_damage), 无逐实体伤害字段,
//  改全局 ConVar 会污染正常虫族。方案: 对虫族实体挂 OnTakeDamage 回调,
//  当伤害来源(attacker)是叛变虫时放大伤害, 正常虫族打玩家完全不受影响。
//  覆盖策略: 生成叛变虫时扫描一次 (HookAllAliens) + OnEntityCreated 自动
//  给新刷出的虫族挂回调, 无需任何定时器。
// ============================================================================
// 新实体创建即挂回调 (只关心虫族类, 开销极小)
public void OnEntityCreated(int entity, const char[] classname)
{
    if (!IsAlienClass(classname))
        return;
    SDKHookEx(entity, SDKHook_OnTakeDamage, OnAlienDamaged);
}

bool IsAlienClass(const char[] classname)
{
    for (int t = 0; t < sizeof(g_sTypes); t++)
    {
        if (StrEqual(classname, g_sTypes[t][0]))
            return true;
    }
    return false;
}

// 生成叛变虫后调用: 给场上已存在的虫族补挂回调 (OnEntityCreated 只覆盖之后创建的)
void HookAllAliens()
{
    for (int t = 0; t < sizeof(g_sTypes); t++)
    {
        int ent = -1;
        while ((ent = FindEntityByClassname(ent, g_sTypes[t][0])) != -1)
        {
            if (!IsValidEntity(ent))
                continue;
            // SDKHookEx 对已挂过的实体返回 false, 天然去重
            SDKHookEx(ent, SDKHook_OnTakeDamage, OnAlienDamaged);
        }
    }
}

// 虫族受伤回调: 攻击者是叛变虫则放大伤害
Action OnAlienDamaged(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (attacker <= 0 || !IsValidEntity(attacker))
        return Plugin_Continue;
    if (!IsBetrayAlien(attacker))
        return Plugin_Continue;
    float mult = g_cvDamageMult.FloatValue;
    if (mult <= 1.0)
        return Plugin_Continue;
    float fOld = damage;
    damage *= mult;
    // 调试: 打印原始/放大后伤害, 便于验证倍率生效
    if (g_cvDebug.BoolValue)
        PrintToServer("[叛变虫群] 伤害增强 %d -> %d (x%.1f) victim=%d",
            RoundToNearest(fOld), RoundToNearest(damage), mult, victim);
    return Plugin_Changed;
}

// 按 targetname 识别叛变虫 (生成时统一打标)
bool IsBetrayAlien(int ent)
{
    char sName[64];
    GetEntPropString(ent, Prop_Data, "m_iName", sName, sizeof(sName));
    return StrEqual(sName, INFECTED_NAME);
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
    KillAllBetrayAliens();
    ReplyToCommand(client, "[叛变虫群] 已清除场上所有叛变虫");
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
//  按 名字 / 部分名字 / #userid 找一个在线玩家 (找不到或歧义时返回 0)
// ============================================================================
int FindTargetPlayer(int client, const char[] szArg)
{
    // #userid 形式
    if (szArg[0] == '#')
    {
        int who = GetClientOfUserId(StringToInt(szArg[1]));
        if (who > 0 && IsClientInGame(who) && !IsFakeClient(who))
            return who;
        PrintToConsole(client, "找不到该 userid 对应的在线玩家");
        return 0;
    }

    int found = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;

        char sName[MAX_NAME_LENGTH];
        GetClientName(i, sName, sizeof(sName));

        if (StrEqual(sName, szArg, false))   // 精确匹配: 直接命中
            return i;

        if (StrContains(sName, szArg, false) != -1)   // 部分匹配
        {
            if (found != 0)
            {
                PrintToConsole(client, "匹配到多名玩家, 请用更完整的名字或 #userid 精确定位");
                return 0;
            }
            found = i;
        }
    }

    if (found == 0)
        PrintToConsole(client, "找不到在线玩家 \"%s\"", szArg);
    return found;
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
