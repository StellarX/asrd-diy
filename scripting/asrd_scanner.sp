// ============================================================================
//  asrd_scanner.sp — 战斗扫描机召唤 (Alien Swarm: Reactive Drop)
//
//  功能: 管理员/玩家在目标玩家身边召唤战斗扫描机 (npc_cscanner, HL2 联合军
//  城市扫描机), 扫描机加入 marine 阵营, 主动俯冲攻击虫族而不攻击玩家。
//
//  ── v1.3.0 (对照 asrd_drone.sp 实测可用版, 生成路径完全克隆) ──────────
//  用户实测: 同服同图, asrd_drone.sp 能生成, 本插件 v1.2.0 不能。
//  本版原则: 默认生成路径与 drone 逐行对齐, 消除所有未验证变量;
//  并给生成流程装"黑匣子" —— 每一步的结果直接发聊天, 不再只写控制台。
//
//  与 drone 对齐的要点 (npc_scanner.cpp / npc_basescanner.cpp 源码证实):
//  1. physdamagescale=0: scanner 是 MOVETYPE_VPHYSICS 飞行体, 撞击走
//     CNPC_BaseScanner::TakeDamageFromPhysicsImpact (flDamageScale = 5.0 *
//     m_impactEnergyScale, npc_basescanner.cpp:466), 默认必被秒。
//  2. 血量 20000 (drone 实测值)。
//  3. 位置 = 陆战队员原点 + 100 高度 + 横向错开 (drone 原版算法),
//     不再随机散布 (随机点可能落进天花板/实体堆, 且点内容检测查不到 hull)。
//  4. 顺序: Create → KeyValue → DispatchSpawn → ActivateEntity →
//     血量/属性 → 最后 Teleport (drone 原版顺序)。
//  5. m_CollisionGroup = DEBRIS(1), m_bOnlyInspectPlayers = 1。
//  6. 默认挂粒子特效 + 动态聚光灯 (drone 原版配置):
//     就算扫描机模型因 late-precache 在客户端不渲染, 也能看到发光飞行体。
//     —— 注意: drone 的"能生成"很可能就是特效可见, 模型本体是否渲染
//     从未被单独验证过。
//  7. 生成后立刻 + 2 秒 + 8 秒三次状态回报 (实体编号/位置/血量/模型索引/
//     EF_NODRAW/碰撞组), 始终发聊天 + 控制台。
//
//  ── v1.3.2 ("生成后慢慢往上飘走") ────────────────────────────
//  全部结论取自引擎源码, 不是猜的:
//  1) 为什么会飘 —— npc_scanner.cpp:2418 (CNPC_CScanner::OverrideMove):
//     没有导航目标、且不在 SPOT/PHOTO/FOLLOW/ATTACK 模式时, 唯一分支是
//         else if (!GetNavigator()->IsGoalActive()) { Decelerate(9.5); }
//     即**没有任何维持高度的力量**, 只剩每帧
//         VelocityToAvoidObstacles() (ai_basenpc_physicsflyer.cpp:158:
//         离地小于 MinGroundDist()=72 时上推 Vector(0,0,50/tr.fraction))
//         + AddNoiseToVelocity(3.0) 的随机游走 → "慢慢往上飘"。
//  2) 为什么 drone 不飘 —— drone 不动阵营, 扫描机保持引擎给的
//     FACTION_COMBINE (npc_scanner.cpp:311), 场上有敌人 → 走
//     MoveToAttack() → IdealGoalForMovement() → **主动控高飞行**。
//     我把阵营改成 marine 后它没敌人了 → 掉回 PATROL + Decelerate → 飘。
//  3) 原生解法 (让引擎自己带它飞, 不用外力硬拽):
//         m_nFlyMode  = SCANNER_FLY_FOLLOW (7)
//             (npc_basescanner.cpp:30 DEFINE_FIELD; 枚举 npc_basescanner.h:23-32)
//         m_vInspectPos = 队员上方的目标点
//             (npc_scanner.cpp:126 DEFINE_FIELD, FIELD_VECTOR)
//     链路: HaveInspectTarget() 只要 m_vInspectPos != 0 即成立
//     (npc_scanner.cpp:853) → FOLLOW 模式调 MoveToSpotlight()
//     (npc_scanner.cpp:2515) → IdealGoalForMovement() → MoveToTarget(),
//     由 AI 主动控高飞向目标; 且 npc_scanner.cpp:1135 明确 FOLLOW 模式
//     **豁免** inspect 目标超时清理, 不会中途丢目标。
//     插件每秒刷新一次 m_vInspectPos → 稳定跟在队员头顶。
//  新增: sm_asrd_scanner_followmode(1) / _height(100)。
//  另修: 坐标读取改为 drone 原版的 Prop_Send (Prop_Data 对 VPHYSICS 实体
//  读出来是 NaN, 日志里表现为 "x=N")。
//
//  ── v1.3.1 (黑匣子定位到的真因) ────────────────────────────────
//  用户实测回报: "生成即时: #431 存活 血量100 模型索引64 可见 ... 位置 0 -1"
//  → 扫描机一直活着、可见 (模型索引 64 = 模型本来就在地图预载表内, 客户端
//    能渲染, 可见性从来不是问题), 但坐标 ≈ (0,0,0) —— 被扔到世界原点了。
//  根因: v1.3.0 用 Prop_Data 读 marine 的 m_vecOrigin 得到 0;
//        asrd_drone.sp 用的是 Prop_Send (drone 的信标摆位正确, 已实测)。
//  修复: 坐标读取改为 drone 原版的 Prop_Send, 并加 Data 侧与玩家本体两级
//        兜底 + 零值校验; 另加 0.1 秒/1 秒两次补定位 (VPHYSICS 飞行体的
//        初始化会在头几帧把位置冲掉, 叛变虫群插件同款坑)。
//
//  保留的自有功能: 阵营改造 (m_nFaction 是合法 datamap 字段,
//  basecombatcharacter.cpp:88 DEFINE_FIELD, 读写安全) / 中立模式 /
//  主动索敌 / 挂哨戒炮塔 / 攻击力倍率 / 多机互伤拦截 / sm_scanner_tp。
// ============================================================================

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION  "1.3.3"
#define SCANNER_CLASS   "npc_cscanner"
#define SCANNER_NAME    "asrd_scanner"   // targetname 统一标记, 供识别/清除
#define MAX_SUMMON      10              // 单次召唤数量上限

// ─── 引擎阵营真值兜底 (源码证实) ──────────────────────────
// src/game/shared/shareddefs.h:      FACTION_NONE = 0; LAST_SHARED_FACTION = FACTION_NONE
// src/game/shared/swarm/asw_gamerules.h: FACTION_MARINES = LAST_SHARED_FACTION + 1
#define FACTION_MARINES_DEFAULT 1
#define TEAM_DEFAULT            2

// ─── 扫描机飞行模式枚举 (npc_basescanner.h:23-32) ─────────────
#define SCANNER_FLY_PHOTO   0   // 飞近目标拍照
#define SCANNER_FLY_PATROL  1   // 环境巡逻 (生成默认, 无目标 → 只 Decelerate → 会飘)
#define SCANNER_FLY_FAST    2
#define SCANNER_FLY_CHASE   3
#define SCANNER_FLY_SPOT    4
#define SCANNER_FLY_ATTACK  5
#define SCANNER_FLY_DIVE    6
#define SCANNER_FLY_FOLLOW  7   // 跟随目标 ← 本插件用它 (AI 主动控高, 不会飘)

// ─── 特效/灯光 (asrd_drone.sp 原版配置) ───────────────────
#define PARTICLE_FX     "powerup_explosive_bullets"

// ─── 扫描机依赖的 HL2 资源 (npc_scanner.cpp Precache/Activate 实测表) ──
char g_sScannerAssets[][] =
{
    "models/combine_scanner.mdl",
    "models/gibs/scanner_gib01.mdl",
    "models/gibs/scanner_gib02.mdl",
    "models/gibs/scanner_gib04.mdl",
    "models/gibs/scanner_gib05.mdl",
    "sprites/light_glow03.vmt",
    "sprites/glow_test02.vmt",
    "sprites/blueflare1.vmt"
};

// ─── ConVar ────────────────────────────────────────────────
ConVar g_cvEnabled;
ConVar g_cvCount;
ConVar g_cvHealth;
ConVar g_cvDamageMult;
ConVar g_cvLimit;
ConVar g_cvSpread;
ConVar g_cvPublic;
ConVar g_cvDebug;
ConVar g_cvPhysDamage;   // physdamagescale: 物理撞击伤害倍率 (0=免疫, 引擎默认 1.0 ×5)
ConVar g_cvNeutral;      // 中立模式 (引擎 DAMAGE_NO, 彻底无敌但不主动攻击)
ConVar g_cvFollow;       // 只跟随玩家 (m_bOnlyInspectPlayers)
ConVar g_cvSeek;         // 生成后主动锁定最近虫族
ConVar g_cvTurret;       // 挂载哨戒炮塔 (复刻 asrd_drone.sp 的火力思路)
ConVar g_cvFX;           // 挂粒子特效+聚光灯 (drone 原版, 保证肉眼可见)
ConVar g_cvFaction;      // 写入 marine 阵营 (0=完全走 drone 原版, 不改阵营)
ConVar g_cvFollowMode;   // 引擎原生跟随 (m_nFlyMode=FOLLOW + m_vInspectPos 刷新)
ConVar g_cvHeight;       // 悬停高度 (相对队员原点)

// 扫描机归属: 实体索引 → 召唤者 client / 横向槽位 (用于多台错开)
int g_iScannerOwner[2048];
int g_iScannerSlot[2048];

// marine 阵营真值缓存 (跨图失效, OnMapEnd 清零后重新解析)
int g_iMarineFaction = -1;
int g_iMarineTeam    = -1;

// 资源/地图环境自检结果
int  g_iModelIndex   = -1;
char g_sMissing[512];
bool g_bMissing      = false;
int  g_iAirNodes     = -1;

// ─── 伤害倍率需要 hook 的虫族类名 (victim 侧钩子) ──────────
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
    "npc_antlionguard",
    "npc_antlionguard_cavern",
    "npc_antlionguard_normal",
    "npc_antlion_worker"
};

// ============================================================================
public Plugin myinfo =
{
    name        = "战斗扫描机召唤 (ASRD Scanner)",
    author      = "asrd-plugins",
    description = "召唤战斗扫描机到玩家身边, 加入 marine 阵营攻击虫族, 多台互不攻击",
    version     = PLUGIN_VERSION,
    url        = ""
};

// ============================================================================
public void OnPluginStart()
{
    CreateConVar("sm_asrd_scanner_version", PLUGIN_VERSION,
        "战斗扫描机召唤插件版本", FCVAR_NOTIFY|FCVAR_DONTRECORD);

    g_cvEnabled    = CreateConVar("sm_asrd_scanner_enabled", "1",
        "总开关 (0=关 1=开)", 0, true, 0.0, true, 1.0);
    g_cvCount      = CreateConVar("sm_asrd_scanner_count", "1",
        "每次召唤数量 (1~10)", 0, true, 1.0, true, 10.0);
    g_cvHealth     = CreateConVar("sm_asrd_scanner_health", "20000",
        "扫描机血量 (0=保持引擎默认 30。asrd_drone.sp 实测用 20000)", 0, true, 0.0);
    g_cvDamageMult = CreateConVar("sm_asrd_scanner_damage_mult", "1.0",
        "扫描机攻击力倍率 (俯冲/撞击伤害, 1.0=原生, 原生俯冲伤害 25)", 0, true, 0.1);
    g_cvLimit      = CreateConVar("sm_asrd_scanner_limit", "10",
        "场上同时允许存在的扫描机数量 (0=不限)", 0, true, 0.0);
    g_cvSpread     = CreateConVar("sm_asrd_scanner_spread", "40",
        "多机横向错开间距 (游戏单位, drone 原版=40)", 0, true, 0.0);
    g_cvPublic     = CreateConVar("sm_asrd_scanner_public", "0",
        "允许普通玩家使用 sm_scannerpub (0=仅管理员 1=所有人)", 0, true, 0.0, true, 1.0);
    g_cvDebug      = CreateConVar("sm_asrd_scanner_debug", "0",
        "调试输出 (0=关 1=开)", 0, true, 0.0, true, 1.0);
    g_cvPhysDamage = CreateConVar("sm_asrd_scanner_physdamage", "0.0",
        "物理撞击伤害倍率 (0=免疫。扫描机是vphysics飞行体, 默认1.0会被5倍撞击伤害秒杀)",
        0, true, 0.0);
    g_cvNeutral    = CreateConVar("sm_asrd_scanner_neutral", "0",
        "中立模式 (1=引擎设 DAMAGE_NO 无敌, 但不主动攻击虫族)", 0, true, 0.0, true, 1.0);
    g_cvFollow     = CreateConVar("sm_asrd_scanner_follow", "1",
        "只跟随玩家不自己乱窜 (m_bOnlyInspectPlayers)", 0, true, 0.0, true, 1.0);
    g_cvSeek       = CreateConVar("sm_asrd_scanner_seek", "0",
        "生成后锁定最近虫族 (1=开启, 可能导致高速俯冲自撞)", 0, true, 0.0, true, 1.0);
    g_cvTurret     = CreateConVar("sm_asrd_scanner_turret", "1",
        "挂载哨戒机枪/加农炮塔 (1=开启, 复刻 asrd_drone.sp 的火力。扫描机本体只会俯冲自爆, 真正打虫族的是炮塔)",
        0, true, 0.0, true, 1.0);
    g_cvFX         = CreateConVar("sm_asrd_scanner_fx", "1",
        "挂粒子特效+动态聚光灯 (1=开启, drone 原版配置, 保证肉眼可见)", 0, true, 0.0, true, 1.0);
    g_cvFaction    = CreateConVar("sm_asrd_scanner_marinefaction", "1",
        "写入 marine 阵营 (1=扫描机会打虫族; 0=完全走 drone 原版不改阵营)", 0, true, 0.0, true, 1.0);
    g_cvFollowMode = CreateConVar("sm_asrd_scanner_followmode", "1",
        "引擎原生跟随 (1=开: m_nFlyMode=FOLLOW + 每秒刷新 m_vInspectPos, 不会上飘)",
        0, true, 0.0, true, 1.0);
    g_cvHeight     = CreateConVar("sm_asrd_scanner_height", "100",
        "跟随时的悬停高度 (相对队员原点的游戏单位)", 0, true, 0.0);

    RegAdminCmd("sm_scanner", Command_Scanner, ADMFLAG_GENERIC,
        "召唤战斗扫描机 [数量] [目标玩家]");
    RegConsoleCmd("sm_scannerpub", Command_ScannerPublic,
        "为自己召唤战斗扫描机 [数量] (需 sm_asrd_scanner_public=1)");
    RegAdminCmd("sm_scanner_clear", Command_Clear, ADMFLAG_GENERIC,
        "清除本插件召唤的所有扫描机");
    RegAdminCmd("sm_scanner_diag", Command_Diag, ADMFLAG_GENERIC,
        "扫描机召唤自检: 实体/资源/阵营/空中节点");
    RegAdminCmd("sm_scanner_tp", Command_Teleport, ADMFLAG_GENERIC,
        "把本插件所有扫描机传送到自己头顶 (验证它们是否还在场上)");

    LoadTranslations("common.phrases");

    // 每秒刷新跟随目标点 (引擎原生跟随, v1.3.2)
    CreateTimer(1.0, Timer_UpdateFollow, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);

    // 热加载 (插件中途载入 / map 已在进行) 时补做预载与环境自检
    char sMap[PLATFORM_MAX_PATH];
    if (GetCurrentMap(sMap, sizeof(sMap)) > 0)
    {
        PrecacheScannerAssets();
        g_iAirNodes = CountAirNodes();
        HookExistingAliens();
    }
}

public void OnMapStart()
{
    // 阵营/队伍枚举值每张图重新解析 (跨图缓存的实体已全部销毁)
    g_iMarineFaction = -1;
    g_iMarineTeam    = -1;

    // 提前预载扫描机模型/精灵, 避免 DispatchSpawn 时的 "late precache"
    // 导致客户端拿不到模型索引 → 实体存在但看不见。
    PrecacheScannerAssets();
    g_iAirNodes = CountAirNodes();

    PrintToServer("[扫描机] 地图开始: 模型索引=%d 空中节点=%d%s%s",
        g_iModelIndex, g_iAirNodes,
        g_bMissing ? " 缺少资源:" : "", g_bMissing ? g_sMissing : "");

    if (g_iAirNodes <= 0)
        PrintToServer("[扫描机] 警告: 本图没有 info_node_air, 飞行单位可能无法寻路/索敌");
}

public void OnMapEnd()
{
    g_iMarineFaction = -1;
    g_iMarineTeam    = -1;

    // 实体索引会被回收复用, 归属表必须清空
    for (int i = 0; i < 2048; i++)
    {
        g_iScannerOwner[i] = 0;
        g_iScannerSlot[i]  = 0;
    }
}

// ============================================================================
//  资源预载 + 存在性检查
// ============================================================================
void PrecacheScannerAssets()
{
    g_sMissing[0] = '\0';
    g_bMissing    = false;
    g_iModelIndex = -1;

    for (int i = 0; i < sizeof(g_sScannerAssets); i++)
    {
        // FileExists 用 Valve 文件系统, 才能真正检查 VPK/游戏目录里的资源
        if (FileExists(g_sScannerAssets[i], true, "GAME"))
        {
            int idx = PrecacheModel(g_sScannerAssets[i]);
            if (i == 0)
                g_iModelIndex = idx;
        }
        else
        {
            g_bMissing = true;
            if (strlen(g_sMissing) < sizeof(g_sMissing) - 64)
            {
                StrCat(g_sMissing, sizeof(g_sMissing), " ");
                StrCat(g_sMissing, sizeof(g_sMissing), g_sScannerAssets[i]);
            }
            PrintToServer("[扫描机] 资源缺失: %s", g_sScannerAssets[i]);
        }
    }
}

int CountAirNodes()
{
    int n = 0;
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "info_node_air")) != -1)
        n++;
    return n;
}

// ============================================================================
//  统一回显: 同时写服务端控制台 + 给操作者发聊天消息
// ============================================================================
void NotifyFmt(int client, const char[] fmt, any ...)
{
    char buf[256];
    VFormat(buf, sizeof(buf), fmt, 3);

    PrintToServer("[扫描机] %s", buf);
    if (client > 0 && IsClientInGame(client))
        PrintToChat(client, "\x04[扫描机]\x01 %s", buf);
}

// ============================================================================
//  命令: sm_scanner [数量] [目标]
//  参数兼容: sm_scanner / sm_scanner 3 / sm_scanner jack / sm_scanner 3 jack
// ============================================================================
public Action Command_Scanner(int client, int args)
{
    int iCount = g_cvCount.IntValue;
    char sTarget[64];
    sTarget[0] = '\0';

    if (args >= 1)
    {
        char sArg[64];
        GetCmdArg(1, sArg, sizeof(sArg));
        if (IsPositiveInteger(sArg))
            iCount = StringToInt(sArg);
        else
            strcopy(sTarget, sizeof(sTarget), sArg);
    }
    if (args >= 2)
        GetCmdArg(2, sTarget, sizeof(sTarget));

    int iTarget = client;
    if (sTarget[0] != '\0')
    {
        iTarget = FindTarget(client, sTarget);
        if (iTarget == -1)
            return Plugin_Handled;   // FindTarget 已自动回复错误原因
    }

    if (iTarget <= 0)
    {
        NotifyFmt(client, "服务器控制台使用需指定目标玩家, 例: sm_scanner 1 jack");
        return Plugin_Handled;
    }

    DoSummon(client, iTarget, iCount);
    return Plugin_Handled;
}

// ============================================================================
//  命令: sm_scannerpub [数量] (玩家版, 只能召唤到自己身边)
// ============================================================================
public Action Command_ScannerPublic(int client, int args)
{
    if (client == 0)
        return Plugin_Handled;

    if (!g_cvEnabled.BoolValue)
    {
        NotifyFmt(client, "插件已关闭");
        return Plugin_Handled;
    }
    if (!g_cvPublic.BoolValue)
    {
        NotifyFmt(client, "管理员未开放玩家召唤");
        return Plugin_Handled;
    }

    int iCount = g_cvCount.IntValue;
    if (args >= 1)
    {
        char sArg[64];
        GetCmdArg(1, sArg, sizeof(sArg));
        if (IsPositiveInteger(sArg))
            iCount = StringToInt(sArg);
    }

    DoSummon(client, client, iCount);
    return Plugin_Handled;
}

// ============================================================================
//  命令: sm_scanner_clear 清除全部召唤的扫描机
// ============================================================================
public Action Command_Clear(int client, int args)
{
    int iKilled = 0;
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, SCANNER_CLASS)) != -1)
    {
        if (!IsOurScanner(ent))
            continue;
        AcceptEntityInput(ent, "Kill");
        iKilled++;
    }

    NotifyFmt(client, "已清除 %d 台扫描机", iKilled);
    if (iKilled > 0 && client > 0)
        PrintToChatAll("\x04[扫描机]\x01 场上扫描机已被管理员清除 (%d 台)", iKilled);
    return Plugin_Handled;
}

// ============================================================================
//  命令: sm_scanner_tp —— 把本插件所有扫描机传送到自己头顶。
//  用途: 区分"实体根本没生成"与"生成了但飞到别处/看不见"。
//  若传送后能看到 → 实体一直活着, 问题在可见性或 AI 跑飞;
//  若提示 0 台 → 实体生成后确实消失了。
// ============================================================================
public Action Command_Teleport(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        NotifyFmt(client, "该命令需在游戏中使用");
        return Plugin_Handled;
    }

    int marine = GetMarineOfClient(client);
    if (marine <= 0)
    {
        NotifyFmt(client, "无法获取你控制的陆战队员实体");
        return Plugin_Handled;
    }

    float fOrigin[3];
    GetEntPropVector(marine, Prop_Data, "m_vecOrigin", fOrigin);

    int iMoved = 0;
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, SCANNER_CLASS)) != -1)
    {
        if (!IsOurScanner(ent))
            continue;
        float fPos[3];
        fPos[0] = fOrigin[0] + iMoved * 40.0;
        fPos[1] = fOrigin[1];
        fPos[2] = fOrigin[2] + 100.0;
        TeleportEntity(ent, fPos, NULL_VECTOR, NULL_VECTOR);
        iMoved++;
    }

    NotifyFmt(client, "已把 %d 台扫描机传送到你头顶 100 单位处 (0 台 = 实体已不存在)", iMoved);
    return Plugin_Handled;
}

// ============================================================================
//  命令: sm_scanner_diag —— 召唤失败自检
// ============================================================================
public Action Command_Diag(int client, int args)
{
    // 1) 实体能否创建
    int ent = CreateEntityByName(SCANNER_CLASS);
    bool bCanCreate = (ent != -1);
    if (bCanCreate)
        AcceptEntityInput(ent, "Kill");

    // 2) 阵营真值
    int iFaction = ResolveMarineFaction();
    int iTeam    = ResolveMarineTeam();
    int iMarine  = FindEntityByClassname(-1, "asw_marine");

    // 3) 场上数量 / 空中节点
    int iAlive = CountOurScanners();

    // 3.5) 陆战队员坐标来源校验 (v1.3.1: 坐标读错会把扫描机扔到世界原点)
    float fMarineOrigin[3];
    bool bOriginOK = GetMarineOrigin(client, iMarine, fMarineOrigin);

    PrintToServer("========== [扫描机] 自检开始 ==========");
    PrintToServer("[扫描机] 插件版本 %s  开关=%d", PLUGIN_VERSION, g_cvEnabled.BoolValue);
    PrintToServer("[扫描机] 1. 创建实体 %s : %s", SCANNER_CLASS, bCanCreate ? "成功" : "失败(-1)");
    PrintToServer("[扫描机] 2. 模型索引=%d 资源缺失=%d%s%s",
        g_iModelIndex, g_bMissing, g_bMissing ? " 列表:" : "", g_bMissing ? g_sMissing : "");
    PrintToServer("[扫描机] 3. 场上 asw_marine=%d  faction=%d team=%d",
        iMarine, iFaction, iTeam);
    PrintToServer("[扫描机] 4. 空中节点 info_node_air=%d (0 则飞行单位无法寻路)", g_iAirNodes);
    PrintToServer("[扫描机] 5. 陆战队员坐标=%s (%.1f, %.1f, %.1f)",
        bOriginOK ? "有效" : "无效(全部来源都是0)",
        fMarineOrigin[0], fMarineOrigin[1], fMarineOrigin[2]);
    PrintToServer("[扫描机] 6. 场上本插件扫描机=%d 上限=%d", iAlive, g_cvLimit.IntValue);
    PrintToServer("========== [扫描机] 自检结束 ==========");

    if (client > 0 && IsClientInGame(client))
    {
        PrintToChat(client, "\x04[扫描机]\x01 自检结果已输出到服务器控制台, 摘要:");
        PrintToChat(client, "\x04[扫描机]\x01 实体创建=%s 模型索引=%d 阵营=%d/%d",
            bCanCreate ? "成功" : "失败", g_iModelIndex, iFaction, iTeam);
        PrintToChat(client, "\x04[扫描机]\x01 空中节点=%d 资源缺失=%d 场上=%d",
            g_iAirNodes, g_bMissing ? 1 : 0, iAlive);
        if (g_bMissing)
            PrintToChat(client, "\x04[扫描机]\x01 缺失资源:%s", g_sMissing);
        PrintToChat(client, "\x04[扫描机]\x01 队员坐标=%s (%.1f, %.1f, %.1f)",
            bOriginOK ? "有效" : "无效", fMarineOrigin[0], fMarineOrigin[1], fMarineOrigin[2]);
        if (!bOriginOK)
            PrintToChat(client, "\x04[扫描机]\x01 结论: 读不到队员坐标, 扫描机会被扔到世界原点");
        else if (!bCanCreate)
            PrintToChat(client, "\x04[扫描机]\x01 结论: 本服不支持 %s, 请换实体类", SCANNER_CLASS);
        else if (g_iModelIndex <= 0)
            PrintToChat(client, "\x04[扫描机]\x01 结论: 模型没预载成功, 客户端看不到实体");
        else if (g_bMissing)
            PrintToChat(client, "\x04[扫描机]\x01 结论: 有资源缺失 (见上行), 显示可能异常");
        else if (g_iAirNodes <= 0)
            PrintToChat(client, "\x04[扫描机]\x01 结论: 本图无空中节点, 扫描机可能原地不动");
        else
            PrintToChat(client, "\x04[扫描机]\x01 结论: 环境正常, 可再试 sm_scanner");
    }
    return Plugin_Handled;
}

// ============================================================================
//  召唤主流程
// ============================================================================
void DoSummon(int client, int target, int count)
{
    if (!g_cvEnabled.BoolValue)
    {
        NotifyFmt(client, "插件已通过 sm_asrd_scanner_enabled 关闭");
        return;
    }
    if (count < 1)  count = 1;
    if (count > MAX_SUMMON) count = MAX_SUMMON;

    if (target <= 0 || !IsClientInGame(target))
    {
        NotifyFmt(client, "目标玩家不在游戏中");
        return;
    }

    int marine = GetMarineOfClient(target);
    if (marine <= 0 || !IsValidEntity(marine))
    {
        NotifyFmt(client, "无法获取 %N 所控制的陆战队员实体", target);
        return;
    }

    int iLimit = g_cvLimit.IntValue;
    if (iLimit > 0)
    {
        int iAlive = CountOurScanners();
        if (iAlive + count > iLimit)
        {
            NotifyFmt(client, "场上扫描机已达上限 (%d/%d), 先用 sm_scanner_clear 清理再召唤",
                iAlive, iLimit);
            return;
        }
    }

    float fOrigin[3], fAng[3];
    // 关键: 必须按 drone 原版用 Prop_Send 读 marine 坐标。
    // v1.3.0 用 Prop_Data 读 m_vecOrigin 得到的是 0 → 扫描机被扔到世界原点
    // (实测: 存活/可见/坐标 0,0,-1), 用户自然"看不到"。
    if (!GetMarineOrigin(target, marine, fOrigin))
    {
        NotifyFmt(client, "读不到陆战队员坐标 (三个来源都无效), 已放弃召唤");
        return;
    }
    GetEntPropVector(marine, Prop_Send, "m_angRotation", fAng);

    int iSpawned = 0;
    for (int i = 0; i < count; i++)
    {
        if (SpawnScanner(fOrigin, fAng, client, marine, i))
            iSpawned++;
    }

    if (iSpawned == 0)
    {
        NotifyFmt(client, "召唤失败。请执行 sm_scanner_diag 查看自检");
        return;
    }

    PrintToChatAll("\x04[扫描机]\x01 （%N）已召唤 %d 台战斗扫描机支援", target, iSpawned);

    if (g_iAirNodes <= 0)
        NotifyFmt(client, "注意: 本图无 info_node_air, 扫描机可能不会移动/索敌");
}

// ============================================================================
//  生成一台扫描机。返回是否成功。
//  v1.3.0: 默认路径与 asrd_drone.sp 的 SpawnCombatDrone 逐行对齐 (实测可用),
//  自有增强 (阵营/索敌/炮塔) 全部放在 drone 原版流程完成之后, 且各有开关。
// ============================================================================
bool SpawnScanner(const float fOrigin[3], const float fAng[3], int ownerClient,
    int marine, int index)
{
    int ent = CreateEntityByName(SCANNER_CLASS);
    if (ent == -1)
    {
        NotifyFmt(ownerClient, "创建实体 %s 失败: 本服不支持该实体类", SCANNER_CLASS);
        return false;
    }

    // ── drone 原版 keyvalue 段 (顺序一致) ─────────────────────────
    DispatchKeyValue(ent, "targetname", SCANNER_NAME);   // 本插件追踪标记
    DispatchKeyValueFloat(ent, "physdamagescale", g_cvPhysDamage.FloatValue);
    DispatchKeyValue(ent, "Freezable", "0");
    DispatchKeyValue(ent, "Flammable", "0");
    DispatchKeyValue(ent, "Teslable", "0");
    // 中立模式: Spawn() 里会 ChangeFaction(FACTION_NEUTRAL) + DAMAGE_NO
    // (npc_scanner.cpp:299), 彻底无敌但不攻击。drone 写的是 "NeutralScanner"
    // 是无效名, 正确 keyfield 是 IsNeutralScanner (npc_scanner.cpp:173)。
    DispatchKeyValue(ent, "IsNeutralScanner", g_cvNeutral.BoolValue ? "1" : "0");

    // ── drone 原版: 先 Spawn 再 Activate, 最后才 Teleport ────────
    DispatchSpawn(ent);

    if (!IsValidEntity(ent))
    {
        NotifyFmt(ownerClient, "DispatchSpawn 后实体立即失效");
        return false;
    }

    ActivateEntity(ent);

    // ── drone 原版: 高血量 (Data + Send 双侧) ────────────────────
    int iHealth = g_cvHealth.IntValue;
    if (iHealth > 0)
    {
        if (HasEntProp(ent, Prop_Data, "m_iMaxHealth"))
            SetEntProp(ent, Prop_Data, "m_iMaxHealth", iHealth);
        if (HasEntProp(ent, Prop_Data, "m_iHealth"))
            SetEntProp(ent, Prop_Data, "m_iHealth", iHealth);
        if (HasEntProp(ent, Prop_Send, "m_iHealth"))
            SetEntProp(ent, Prop_Send, "m_iHealth", iHealth);
    }

    // ── drone 原版: 只观察玩家 + DEBRIS 碰撞组 ───────────────────
    if (g_cvFollow.BoolValue && HasEntProp(ent, Prop_Send, "m_bOnlyInspectPlayers"))
        SetEntProp(ent, Prop_Send, "m_bOnlyInspectPlayers", 1);
    if (HasEntProp(ent, Prop_Data, "m_CollisionGroup"))
        SetEntProp(ent, Prop_Data, "m_CollisionGroup", 1);

    // ── drone 原版位置算法: 队员头顶 +100, 多机横向错开 ──────────
    float right[3];
    GetAngleVectors(fAng, NULL_VECTOR, right, NULL_VECTOR);
    float fSpacing = g_cvSpread.FloatValue;
    // index 0 居中, 其后 ±fSpacing 交替排开
    float fSide = 0.0;
    if (index > 0)
        fSide = ((index % 2 == 1) ? 1.0 : -1.0) * fSpacing * ((index + 1) / 2);

    float fPos[3];
    fPos[0] = fOrigin[0] + right[0] * fSide;
    fPos[1] = fOrigin[1] + right[1] * fSide;
    fPos[2] = fOrigin[2] + 100.0 + index * 20.0;

    TeleportEntity(ent, fPos, fAng, NULL_VECTOR);

    // ── 保险: 0.1 秒 / 1 秒各补一次定位 ─────────────────────────
    // VPHYSICS 飞行体的初始化可能在一两帧内把位置冲掉 (叛变虫群插件同款兜底)。
    // 若发现实体跑离目标点超过 200 单位就再拉回来, 并打印前后坐标。
    for (int k = 0; k < 2; k++)
    {
        DataPack dpr = new DataPack();
        dpr.WriteCell(EntIndexToEntRef(ent));
        dpr.WriteCell(ownerClient);
        dpr.WriteFloat(fPos[0]);
        dpr.WriteFloat(fPos[1]);
        dpr.WriteFloat(fPos[2]);
        dpr.WriteFloat(fAng[0]);
        dpr.WriteFloat(fAng[1]);
        dpr.WriteFloat(fAng[2]);
        CreateTimer((k == 0) ? 0.1 : 1.0, Timer_ReTeleport, dpr, TIMER_FLAG_NO_MAPCHANGE);
    }

    // ── 自有增强 #1: 阵营改造 (在 drone 原版流程之后, 可用 cvar 关) ──
    // m_nFaction 是 CBaseCombatCharacter 的合法 datamap 字段
    // (basecombatcharacter.cpp:88 DEFINE_FIELD), 读写安全。
    // 注意: 这是绕过 ChangeFaction() 直接写字段, 不维护 m_aFactions 列表,
    // 与叛变虫群插件同款写法 (该插件实测可用)。
    int iFaction = -1, iTeam = -1;
    if (g_cvFaction.BoolValue && !g_cvNeutral.BoolValue)
    {
        iFaction = ResolveMarineFaction(marine);
        iTeam    = ResolveMarineTeam(marine);
        if (iFaction < 0)
            iFaction = FACTION_MARINES_DEFAULT;
        if (iTeam < 0)
            iTeam = TEAM_DEFAULT;

        if (!WriteFaction(ent, iFaction) || !WriteTeam(ent, iTeam))
            PrintToServer("[扫描机] 写入 faction/team 失败 (继续保留实体)");
    }

    // 伤害拦截钩子 (victim=scanner 侧): 多机互伤拦截
    SDKHookEx(ent, SDKHook_OnTakeDamage, OnScannerTakeDamage);

    // ── v1.3.2 核心: 引擎原生跟随 ───────────────────────────────
    // 记录在归属表里 (每秒刷新目标点用)
    if (ent >= 0 && ent < 2048)
    {
        g_iScannerOwner[ent] = ownerClient;
        g_iScannerSlot[ent]  = index;
    }
    if (g_cvFollowMode.BoolValue)
        SetFollowTarget(ent, ownerClient, true);

    // ── 自有增强 #2: 索敌 (默认关) ──────────────────────────────
    if (g_cvSeek.BoolValue && HasEntProp(ent, Prop_Data, "m_hEnemy"))
    {
        int iEnemy = FindNearestAlien(fPos, 1500.0);
        if (iEnemy > 0)
            SetEntPropEnt(ent, Prop_Data, "m_hEnemy", iEnemy);
    }

    // ── 自有增强 #3: 挂炮塔 (默认关, drone 的火力思路) ───────────
    if (g_cvTurret.BoolValue)
    {
        float fwd[3];
        GetAngleVectors(fAng, fwd, NULL_VECTOR, NULL_VECTOR);
        SpawnTurret("asw_sentry_top_machinegun", ent, fPos, fwd, -15.0);
        SpawnTurret("asw_sentry_top_cannon", ent, fPos, fwd, -10.0);
    }

    // ── drone 原版: 粒子特效 + 动态聚光灯 (默认开, 保证肉眼可见) ──
    // 就算扫描机模型因 late-precache 在客户端不渲染, 也能看到发光飞行体。
    if (g_cvFX.BoolValue)
        AttachFX(ent, fPos, fAng);

    // ── 黑匣子: 立刻回报一次真实状态 (聊天+控制台, 不看 debug 开关) ──
    DumpScannerState(ent, ownerClient, "生成即时");

    // ── 黑匣子: 2 秒 / 8 秒各复查一次 ───────────────────────────
    DataPack dp = new DataPack();
    dp.WriteCell(EntIndexToEntRef(ent));
    dp.WriteCell(ownerClient);
    dp.WriteCell(2);
    CreateTimer(2.0, Timer_VerifySpawn, dp, TIMER_FLAG_NO_MAPCHANGE);

    DataPack dp2 = new DataPack();
    dp2.WriteCell(EntIndexToEntRef(ent));
    dp2.WriteCell(ownerClient);
    dp2.WriteCell(8);
    CreateTimer(8.0, Timer_VerifySpawn, dp2, TIMER_FLAG_NO_MAPCHANGE);

    return true;
}

// ============================================================================
//  引擎原生跟随 (v1.3.2)
//  原理 (全部源码证实):
//    m_nFlyMode = SCANNER_FLY_FOLLOW (7)
//        → OverrideMove 走 MoveToSpotlight() (npc_scanner.cpp:2515)
//        → IdealGoalForMovement( InspectTargetPosition(), ... )
//        → MoveToTarget() —— AI 主动控高飞向目标, 因此不会像 PATROL 那样
//          只剩 Decelerate + 上推力而慢慢飘走。
//    m_vInspectPos = 队员上方的点
//        → HaveInspectTarget() 只判断它 != 0 (npc_scanner.cpp:853)
//        → InspectTargetPosition() 直接返回它 (npc_scanner.cpp:868)
//    且 FOLLOW 模式豁免 inspect 超时清理 (npc_scanner.cpp:1135)。
//  只在当前模式是 PATROL(1) 时才改模式, 避免打断攻击/拍照等正常行为。
// ============================================================================
void SetFollowTarget(int ent, int client, bool bAllowSetMode)
{
    if (ent <= 0 || !IsValidEntity(ent))
        return;

    int offFly = FindDataMapInfo(ent, "m_nFlyMode");
    int offPos = FindDataMapInfo(ent, "m_vInspectPos");
    int offEnd = FindDataMapInfo(ent, "m_fInspectEndTime");
    if (offPos < 0)
        return;

    if (bAllowSetMode && offFly >= 0)
    {
        int iMode = GetEntData(ent, offFly, 4);
        if (iMode == SCANNER_FLY_PATROL || iMode == SCANNER_FLY_FAST || iMode == SCANNER_FLY_CHASE)
            SetEntData(ent, offFly, SCANNER_FLY_FOLLOW, 4, true);
    }

    int marine = (client > 0) ? GetMarineOfClient(client) : -1;
    float fOrigin[3];
    if (!GetMarineOrigin(client, marine, fOrigin))
        return;

    float fHover[3];
    fHover[0] = fOrigin[0];
    fHover[1] = fOrigin[1];
    fHover[2] = fOrigin[2] + g_cvHeight.FloatValue;

    SetEntPropVector(ent, Prop_Data, "m_vInspectPos", fHover);

    // 保险: inspect 结束时间推远, 防止被 AI 判为"拍照结束"清掉目标
    if (offEnd >= 0)
        SetEntPropFloat(ent, Prop_Data, "m_fInspectEndTime", GetGameTime() + 99999.0);
}

// ============================================================================
//  每秒刷新跟随目标点
// ============================================================================
public Action Timer_UpdateFollow(Handle timer)
{
    if (!g_cvFollowMode.BoolValue)
        return Plugin_Continue;

    int ent = -1;
    while ((ent = FindEntityByClassname(ent, SCANNER_CLASS)) != -1)
    {
        if (!IsOurScanner(ent))
            continue;

        int iOwner = (ent >= 0 && ent < 2048) ? g_iScannerOwner[ent] : 0;
        if (iOwner <= 0 || !IsClientInGame(iOwner))
            continue;

        SetFollowTarget(ent, iOwner, true);
    }
    return Plugin_Continue;
}

// ============================================================================
//  挂特效 + 聚光灯 (asrd_drone.sp 原版配置)
// ============================================================================
void AttachFX(int drone, const float dronePos[3], const float fAng[3])
{
    // 爆炸弹粒子特效 (跟随无人机)
    int pfx = CreateEntityByName("info_particle_system");
    if (pfx > 0)
    {
        DispatchKeyValue(pfx, "effect_name", PARTICLE_FX);
        DispatchKeyValue(pfx, "start_active", "1");
        DispatchSpawn(pfx);
        ActivateEntity(pfx);
        float pfxPos[3];
        pfxPos[0] = dronePos[0];
        pfxPos[1] = dronePos[1];
        pfxPos[2] = dronePos[2] + 5.0;
        TeleportEntity(pfx, pfxPos, NULL_VECTOR, NULL_VECTOR);
        SetVariantString("!activator");
        AcceptEntityInput(pfx, "SetParent", drone, drone);
    }

    // 动态聚光灯 (drone 原版: 橙色 255 128 0, 向下 65 度)
    int light = CreateEntityByName("light_dynamic");
    if (light > 0)
    {
        DispatchKeyValue(light, "_light", "255 128 0 200");
        DispatchKeyValue(light, "brightness", "3");
        DispatchKeyValue(light, "_inner_cone", "60");
        DispatchKeyValue(light, "_cone", "100");
        DispatchKeyValue(light, "Pitch", "-65");
        DispatchKeyValue(light, "distance", "600");
        DispatchKeyValue(light, "spotlight_radius", "130");
        DispatchKeyValue(light, "Appearance", "12");
        DispatchSpawn(light);
        ActivateEntity(light);
        float lightPos[3];
        lightPos[0] = dronePos[0];
        lightPos[1] = dronePos[1];
        lightPos[2] = dronePos[2] - 10.0;
        TeleportEntity(light, lightPos, fAng, NULL_VECTOR);
        SetVariantString("!activator");
        AcceptEntityInput(light, "SetParent", drone, drone);
    }
}

// ============================================================================
//  挂载炮塔 (复刻 asrd_drone.sp): modelscale 0.01 缩到看不见, 前向朝下,
//  父级绑定到扫描机 → 扫描机只当飞行平台, 火力由哨戒炮塔提供。
// ============================================================================
void SpawnTurret(const char[] classname, int drone, const float dronePos[3],
    const float fwd[3], float heightOffset)
{
    int turret = CreateEntityByName(classname);
    if (turret <= 0)
        return;

    DispatchKeyValueFloat(turret, "modelscale", 0.01);
    DispatchSpawn(turret);
    ActivateEntity(turret);

    float tPos[3], tFwd[3], tAng[3];
    tPos[0] = dronePos[0] + fwd[0] * 5.0;
    tPos[1] = dronePos[1] + fwd[1] * 5.0;
    tPos[2] = dronePos[2] + heightOffset;
    tFwd = fwd;
    tFwd[2] -= 30.0;
    GetVectorAngles(tFwd, tAng);
    TeleportEntity(turret, tPos, tAng, NULL_VECTOR);

    SetVariantString("!activator");
    AcceptEntityInput(turret, "SetParent", drone, drone);
}

// ============================================================================
//  黑匣子: 把扫描机的真实状态发聊天 + 控制台
//  (模型索引/EF_NODRAW/碰撞组/movetype/血量/位置/faction —— 一眼看出
//  是"没了"还是"在但隐形"还是"在但飞走了")
// ============================================================================
void DumpScannerState(int ent, int client, const char[] tag)
{
    float fPos[3];
    // VPHYSICS 实体的 Prop_Data m_vecOrigin 读出来是 NaN (日志里表现为 x=N),
    // 一律用 drone 原版的 Prop_Send 读, 读不到再退回 Data 侧。
    GetEntPropVector(ent, Prop_Send, "m_vecOrigin", fPos);
    if (!IsValidWorldOrigin(fPos))
        GetEntPropVector(ent, Prop_Data, "m_vecOrigin", fPos);

    int iFlyMode = FindDataMapInfo(ent, "m_nFlyMode") > 0
        ? GetEntProp(ent, Prop_Data, "m_nFlyMode") : -1;

    int iHp       = HasEntProp(ent, Prop_Data, "m_iHealth")   ? GetEntProp(ent, Prop_Data, "m_iHealth")   : -1;
    int iModelIdx = HasEntProp(ent, Prop_Send, "m_nModelIndex") ? GetEntProp(ent, Prop_Send, "m_nModelIndex") : -1;
    int iEffects  = HasEntProp(ent, Prop_Send, "m_fEffects")  ? GetEntProp(ent, Prop_Send, "m_fEffects")  : -1;
    int iColGroup = HasEntProp(ent, Prop_Data, "m_CollisionGroup") ? GetEntProp(ent, Prop_Data, "m_CollisionGroup") : -1;
    int iMoveType = HasEntProp(ent, Prop_Data, "m_MoveType")  ? GetEntProp(ent, Prop_Data, "m_MoveType")  : -1;
    int iFac      = GetFaction(ent);

    // EF_NODRAW = 0x020
    NotifyFmt(client, "%s: #%d 血量%d 模型%d %s 飞行模式%d 碰%d 移%d fac%d 位置 x=%.1f y=%.1f z=%.1f",
        tag, ent, iHp, iModelIdx,
        (iEffects & 0x020) ? "隐形!" : "可见",
        iFlyMode, iColGroup, iMoveType, iFac,
        fPos[0], fPos[1], fPos[2]);
}

// ============================================================================
//  补定位保险 (0.1 秒 / 1 秒): 实体跑离目标点就再拉回来
// ============================================================================
public Action Timer_ReTeleport(Handle timer, DataPack dp)
{
    dp.Reset();
    int ref    = dp.ReadCell();
    int client = dp.ReadCell();
    float fPos[3], fAng[3];
    fPos[0] = dp.ReadFloat();
    fPos[1] = dp.ReadFloat();
    fPos[2] = dp.ReadFloat();
    fAng[0] = dp.ReadFloat();
    fAng[1] = dp.ReadFloat();
    fAng[2] = dp.ReadFloat();
    delete dp;

    int ent = EntRefToEntIndex(ref);
    if (ent == INVALID_ENT_REFERENCE || !IsValidEntity(ent))
        return Plugin_Stop;

    float fCur[3];
    GetEntPropVector(ent, Prop_Data, "m_vecOrigin", fCur);

    float fDist = GetVectorDistance(fCur, fPos);
    if (fDist > 200.0)
    {
        TeleportEntity(ent, fPos, fAng, NULL_VECTOR);
        NotifyFmt(client, "补定位: #%d 偏离 %.0f 单位 (%.0f,%.0f,%.0f), 已拉回目标点",
            ent, fDist, fCur[0], fCur[1], fCur[2]);
    }
    return Plugin_Stop;
}

// ============================================================================
//  生成后复查 (2 秒 / 8 秒)
// ============================================================================
public Action Timer_VerifySpawn(Handle timer, DataPack dp)
{
    dp.Reset();
    int ref     = dp.ReadCell();
    int client  = dp.ReadCell();
    int iSecond = dp.ReadCell();
    delete dp;

    char sTag[24];
    Format(sTag, sizeof(sTag), "%d秒复查", iSecond);

    int ent = EntRefToEntIndex(ref);
    if (ent == INVALID_ENT_REFERENCE || !IsValidEntity(ent))
    {
        NotifyFmt(client, "%s: 扫描机已消失 (被引擎移除/死亡/掉出世界)", sTag);
        return Plugin_Stop;
    }

    DumpScannerState(ent, client, sTag);
    return Plugin_Stop;
}

// ============================================================================
//  伤害回调: 扫描机被打 (victim=scanner)
//  物理互撞伤害的 attacker 是另一台 scanner
//  (CNPC_BaseScanner::TakeDamageFromPhysicsImpact), 拦截后引擎不会执行
//  伤害结算与仇恨记忆, 记仇循环从根上掐断。
// ============================================================================
public Action OnScannerTakeDamage(int victim, int &attacker, int &inflictor,
    float &damage, int &damagetype, int &weapon,
    float damageForce[3], float damagePosition[3], int damagecustom)
{
    if (attacker > 0 && attacker != victim && IsOurScanner(attacker))
    {
        if (g_cvDebug.BoolValue)
            PrintToServer("[扫描机][debug] 拦截友军互伤: #%d <- #%d (%.1f 伤害)",
                victim, attacker, damage);
        return Plugin_Handled;
    }
    return Plugin_Continue;
}

// ============================================================================
//  伤害回调: 虫族被打 (victim=虫族) — 扫描机攻击力倍率
// ============================================================================
public Action OnAlienTakeDamage(int victim, int &attacker, int &inflictor,
    float &damage, int &damagetype, int &weapon,
    float damageForce[3], float damagePosition[3], int damagecustom)
{
    if (attacker <= 0 || attacker == victim)
        return Plugin_Continue;
    if (!IsOurScanner(attacker))
        return Plugin_Continue;

    float fMult = g_cvDamageMult.FloatValue;
    if (fMult <= 0.0 || fMult == 1.0)
        return Plugin_Continue;

    damage *= fMult;
    if (g_cvDebug.BoolValue)
        PrintToServer("[扫描机][debug] 扫描机 #%d 伤害 %.1f x%.1f = %.1f (victim #%d)",
            attacker, damage / fMult, fMult, damage, victim);
    return Plugin_Changed;
}

// ============================================================================
//  实体创建钩子: 给虫族挂伤害倍率钩子 (伤害倍率必须挂在 victim 侧)
// ============================================================================
public void OnEntityCreated(int entity, const char[] classname)
{
    if (!IsAlienClass(classname))
        return;
    SDKHookEx(entity, SDKHook_OnTakeDamage, OnAlienTakeDamage);
}

void HookExistingAliens()
{
    for (int c = 0; c < sizeof(g_sAlienClasses); c++)
    {
        int ent = -1;
        while ((ent = FindEntityByClassname(ent, g_sAlienClasses[c])) != -1)
            SDKHookEx(ent, SDKHook_OnTakeDamage, OnAlienTakeDamage);
    }
}

bool IsAlienClass(const char[] classname)
{
    for (int c = 0; c < sizeof(g_sAlienClasses); c++)
    {
        if (StrEqual(classname, g_sAlienClasses[c]))
            return true;
    }
    return false;
}

// ============================================================================
//  工具函数
// ============================================================================

// 是否本插件召唤的扫描机 (统一 targetname 标记)
bool IsOurScanner(int ent)
{
    if (ent <= 0 || !IsValidEntity(ent) || !IsValidEdict(ent))
        return false;
    char sName[32];
    GetEntPropString(ent, Prop_Data, "m_iName", sName, sizeof(sName));
    return StrEqual(sName, SCANNER_NAME);
}

int CountOurScanners()
{
    int iCount = 0;
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, SCANNER_CLASS)) != -1)
    {
        if (IsOurScanner(ent))
            iCount++;
    }
    return iCount;
}

// 最近的活虫族 (给扫描机塞初始敌人用)
int FindNearestAlien(const float fPos[3], float fMaxDist)
{
    int iBest = -1;
    float fBest = fMaxDist * fMaxDist;

    for (int c = 0; c < sizeof(g_sAlienClasses); c++)
    {
        int ent = -1;
        while ((ent = FindEntityByClassname(ent, g_sAlienClasses[c])) != -1)
        {
            if (GetEntProp(ent, Prop_Data, "m_iHealth") <= 0)
                continue;
            float fOther[3];
            GetEntPropVector(ent, Prop_Data, "m_vecOrigin", fOther);
            float fDist = (fOther[0]-fPos[0])*(fOther[0]-fPos[0])
                        + (fOther[1]-fPos[1])*(fOther[1]-fPos[1])
                        + (fOther[2]-fPos[2])*(fOther[2]-fPos[2]);
            if (fDist < fBest)
            {
                fBest = fDist;
                iBest = ent;
            }
        }
    }
    return iBest;
}

// 玩家 → 其控制的陆战队员 (AS:RD 居住系统)
int GetMarineOfClient(int client)
{
    char sNetClass[64];
    GetEntityNetClass(client, sNetClass, sizeof(sNetClass));
    if (FindSendPropInfo(sNetClass, "m_hInhabiting") > 0)
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
    return -1;
}

// ============================================================================
//  读取陆战队员坐标。三级来源, 全部对齐 asrd_drone.sp 的 Prop_Send 用法:
//    1) marine 的 Prop_Send m_vecOrigin   ← drone 原版, 实测可用
//    2) marine 的 Prop_Data  m_vecOrigin  ← v1.3.0 用它得到 0, 已降为备选
//    3) 玩家本体的 GetClientAbsOrigin
//  坐标整体接近原点 (长度 < 1) 视为无效 —— 这种值会把扫描机扔到世界原点。
// ============================================================================
bool GetMarineOrigin(int client, int marine, float fOut[3])
{
    if (marine > 0 && IsValidEntity(marine))
    {
        GetEntPropVector(marine, Prop_Send, "m_vecOrigin", fOut);
        if (IsValidWorldOrigin(fOut))
            return true;

        // 备选 1: Data 侧 (v1.3.0 用它拿到过 0, 故必须校验)
        if (FindDataMapInfo(marine, "m_vecOrigin") > 0)
        {
            GetEntPropVector(marine, Prop_Data, "m_vecOrigin", fOut);
            if (IsValidWorldOrigin(fOut))
                return true;
        }
    }

    // 备选 2: 玩家实体自身
    if (client > 0 && IsClientInGame(client))
    {
        GetClientAbsOrigin(client, fOut);
        if (IsValidWorldOrigin(fOut))
            return true;
    }

    return false;
}

bool IsValidWorldOrigin(const float v[3])
{
    // 有效坐标: 至少有一维不是 0, 且不是 nan
    if (FloatAbs(v[0]) > 1.0 || FloatAbs(v[1]) > 1.0 || FloatAbs(v[2]) > 1.0)
        return (v[0] == v[0] && v[1] == v[1] && v[2] == v[2]);   // NaN 自比较为假
    return false;
}

bool IsPositiveInteger(const char[] s)
{
    if (s[0] == '\0')
        return false;
    for (int i = 0; s[i] != '\0'; i++)
    {
        if (s[i] < '0' || s[i] > '9')
            return false;
    }
    return true;
}

// ─── 阵营读写 (照搬叛变虫群的 datamap 模式) ─────────────────
// AS:RD 的阵营字段是 m_nFaction (CBaseCombatCharacter,
// basecombatcharacter.cpp:88 DEFINE_FIELD), 用 datamap 读写避开
// SendProp 类型不匹配问题。

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

// marine 阵营真值: 缓存优先, 否则扫场上 asw_marine 读真值。
int ResolveMarineFaction(int preferMarine = 0)
{
    if (g_iMarineFaction >= 0)
        return g_iMarineFaction;

    int iMarine = preferMarine;
    if (iMarine <= 0 || !IsValidEntity(iMarine))
        iMarine = FindEntityByClassname(-1, "asw_marine");
    if (iMarine > 0 && IsValidEntity(iMarine))
    {
        int iMFaction = GetFaction(iMarine);
        if (iMFaction >= 0)
        {
            g_iMarineFaction = iMFaction;
            return iMFaction;
        }
    }
    return -1;
}

int ResolveMarineTeam(int preferMarine = 0)
{
    if (g_iMarineTeam >= 0)
        return g_iMarineTeam;

    int iMarine = preferMarine;
    if (iMarine <= 0 || !IsValidEntity(iMarine))
        iMarine = FindEntityByClassname(-1, "asw_marine");
    if (iMarine > 0 && IsValidEntity(iMarine))
    {
        int iMTeam = GetTeam(iMarine);
        if (iMTeam >= 0)
        {
            g_iMarineTeam = iMTeam;
            return iMTeam;
        }
    }
    return -1;
}
