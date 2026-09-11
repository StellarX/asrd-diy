/**
 * ============================================================================
 *  [AS:RD] 哨戒塔增强 + 头顶哨戒塔 + 信息 HUD
 *  版本 6.5.4  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ─────────────────────────────────────
 *  1. 增强地图里的哨戒塔: 生命/射速/射程/弹药/伤害 乘以倍率,
 *     可选无敌、可选关闭对队友的误伤
 *  2. 把哨戒塔放到角色头顶, 当"随行炮台" (sm_sentryhat, 每人最多 3 座)
 *  3. 在画面右上角显示哨戒塔信息 HUD (sm_sentryhud)
 *  4. 一键补满地图上所有哨戒塔的生命与弹药 (sm_sentry_refill, 供积分插件 /buy 5 调用)
 *  5. 强制关闭无限弹药: 持续把引擎的 asw_sentry_infinite_ammo 压成 0,
 *     覆盖挑战(甚至其它插件)设置的"哨戒塔无线弹药", 保证弹药正常消耗
 *  6. 保留拆卸后的剩余弹药: 玩家部署/拆除/再部署哨戒塔时, 弹药不会被自动补满
 *     (插件不再覆盖引擎带回箱子的剩余量, 并把 rd_sentry_refilled_by_dismantling 压成 0)
 *
 *  ── 玩家命令 (控制台输入, 或在聊天栏加 ! 前缀) ───────────
 *   sm_sentryhud      开关右上角信息 HUD (默认关)
 *   sm_hat            把最近的塔放到自己头顶 (需管理员开启该功能)
 *   sm_hat_off        取消自己的头顶塔
 *   sm_sentrydrop [0-3]  在身边掉落一座哨戒塔拾取箱 (0机枪 1炮 2喷火 3冰冻; 需管理员开启该功能)
 *   sm_sentry_refill  一键补满地图上所有哨戒塔的生命与弹药 (需管理员开启该功能)
 *
 *  ── 管理员命令 ─────────────────────────────────────────
 *   sm_sentry_refresh     重新增强所有哨戒塔并补满弹药
 *   sm_sentry_status      在控制台查看所有哨戒塔状态
 *   sm_sentryhat          把最近的塔放到自己头顶
 *   sm_sentryhat_off      取消所有玩家的头顶塔
 *   sm_sentry_boost       一键满配增强所有哨戒塔 (可 bind 到按键)
 *   sm_sentry_unboost     一键还原增强倍率到默认档
 *   sm_sentry_drop        在身边掉落一座哨戒枪拾取箱 (默认炮, 可 bind 到按键)
 *   sm_sentry_dump        转储哨戒塔内部属性 (调试)
 *   sm_sentry_dump_player 转储玩家实体属性 (调试)
 *
 *  ── 常用 ConVar (自动生成 cfg/sourcemod/asrd_sentry_enhancer.cfg) ─
 *   sm_asrd_sentry_enabled            总开关 (0=关 1=开)
 *   sm_asrd_sentry_health_mult        生命倍率 (默认 5.0)
 *   sm_asrd_sentry_firerate_mult      射速倍率 (默认 35)
 *   sm_asrd_sentry_range_mult         射程倍率 (默认 1.0)
 *   sm_asrd_sentry_ammo_mult          弹药倍率 (默认 25)
 *   sm_asrd_sentry_damage_mult        子弹伤害倍率 (默认 1.0, 基于机枪10/炮60/喷火4)
 *   sm_asrd_sentry_invulnerable       无敌 (默认 0)
 *   sm_asrd_sentry_no_player_damage   关闭误伤队友 (默认 1)
 *   sm_asrd_sentry_hat_public         允许所有玩家用头顶塔命令 (默认 1)
 *   sm_asrd_sentry_hat_turnspeed      头顶塔转向速度 度/秒 (默认 360)
 *   sm_asrd_sentry_hat_maxdist        头顶塔命令允许的最大距离 (默认 100, 0=不限制)
 *   sm_asrd_sentry_hat_layerspace     头顶多座塔的层间距 (默认 60, 20~200)
 *   sm_asrd_sentry_hud_default        新玩家默认开启 HUD (默认 0)
 *   sm_asrd_sentry_drop_limit         场上最多可同时存在的拾取箱数量 (默认 20, 0=不限制)
 *   sm_asrd_sentry_drop_public        允许所有玩家使用掉落命令 (默认 1)
 *   sm_asrd_sentry_refill_public      允许所有玩家使用一键满配命令 (默认 1)
 *   sm_asrd_sentry_no_infinite_ammo   强制 asw_sentry_infinite_ammo=0 (默认 1;
 *                                     独立于总开关, 0=不干预, 1=持续压制)
 *   sm_asrd_sentry_no_dismantle_refill 拆除哨戒塔不补满弹药 (默认 1;
 *                                     强制 rd_sentry_refilled_by_dismantling=0)
 *   sm_asrd_sentry_debug              调试输出 (默认 0)
 *
 *  依赖: SourceMod 1.11+ (不依赖任何扩展)
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] Sentry Enhancer + Sentry Hat"
#define PLUGIN_VERSION "6.5.4"

// 每个玩家头顶哨戒塔的数量上限 (写死, 不提供 ConVar 让挑战/玩家随意调整)
#define SENTRY_HAT_LIMIT 3

// 子弹伤害倍率的基础伤害值 (来自官方源码 asw_sentry_top*.cpp 的默认伤害):
//   机枪 GetSentryDamage=10*m_fDamageScale, 炮 fBaseGrenadeDamage=60, 喷火 GetSentryDamage=4*m_fDamageScale
// 冰冻塔伤害硬编码为 1 且无官方覆盖 ConVar, 不做增强。伤害倍率只作用于机枪/炮/喷火。
#define SENTRY_DMG_MACHINEGUN 10.0     // 机枪每发基础伤害
#define SENTRY_DMG_CANNON     60.0     // 炮每发基础伤害 (实际还会叠加 marine 技能增益)
#define SENTRY_DMG_FLAMER      4.0     // 喷火每发基础伤害

// HUD 文字相关参数
#define HUD_CHANNEL    4        // 文字通道号 (多个 HUD 同时显示时互不覆盖)
#define HUD_POS_X      0.60     // 横向位置 (0=最左 1=最右, 文字从该点向右展开)
#define HUD_POS_Y      0.08     // 纵向位置 (0=最上 1=最下)
#define HUD_HOLD_TIME  1.5      // 每条文字停留秒数 (比 1 秒刷新周期长, 保证不闪烁)

// ============================================================================
//  ConVar 句柄 (保存各个可调参数的引用, 供全局读写)
// ============================================================================
ConVar g_cvEnabled;
ConVar g_cvHealthMult;
ConVar g_cvFireRateMult;
ConVar g_cvRangeMult;
ConVar g_cvAmmoMult;
ConVar g_cvDamageMult;   // 子弹伤害倍率 (作用于机枪/炮/喷火, 冰冻塔无法增强)
ConVar g_cvInvulnerable;
ConVar g_cvNoPlayerDamage;
ConVar g_cvHatTurnSpeed;
ConVar g_cvHatPublic;
ConVar g_cvHatMaxDist;
ConVar g_cvHatLayerSpace;   // 头顶多座塔的层间距 (世界单位)
ConVar g_cvTurnRate;     // 哨戒塔顶转向速度 (度/秒, 0=瞬间转向)
ConVar g_cvDebug;
ConVar g_cvHudDefault;   // 新玩家进服时 HUD 的默认开关
ConVar g_cvDropLimit;    // 场上最多可同时存在的哨戒炮塔拾取箱数量 (0=不限制)
ConVar g_cvDropPublic;   // 允许所有玩家使用掉落命令 (0=仅管理员, 1=所有玩家)
ConVar g_cvRefillPublic; // 允许所有玩家使用一键满配命令 (0=仅管理员, 1=所有玩家)
ConVar g_cvNoInfiniteAmmo;      // 强制关闭无限弹药 (asw_sentry_infinite_ammo=0) 开关
ConVar g_cvEngineInfiniteAmmo;  // 引擎/挑战定义的 asw_sentry_infinite_ammo (找到后缓存)
bool   g_bFixingInfiniteAmmo;   // 正在压制无限弹药 (防止与变更钩子互相递归)
bool   g_bAmmoGuardWarned;      // 找不到引擎 ConVar 时只报错一次
ConVar g_cvNoDismantleRefill;      // 拆除哨戒塔不补满弹药 开关
ConVar g_cvEngineDismantleRefill;  // 引擎/挑战定义的 rd_sentry_refilled_by_dismantling (找到后缓存)
bool   g_bFixingDismantleRefill;   // 正在压制拆除补弹 (防止与变更钩子互相递归)
bool   g_bDismantleGuardWarned;    // 找不到引擎 ConVar 时只报错一次

// ============================================================================
//  属性偏移缓存
//  游戏实体内部的每个属性都固定存放在实体内存的某个位置 (叫"偏移")。
//  用 FindDataMapInfo / FindSendPropInfo 按名字查一次得到偏移, 存起来复用,
//  比每帧都按名字查要快得多。同类实体的偏移相同, 所以只需查一次。
//  base(底座) 和 top(炮口) 的缓存分开记, 因为玩家部署的塔一开始只有底座,
//  炮口要等组装完成才出现 (见 ApplyTopEnhancements)。
// ============================================================================
// 底座属性偏移
int g_offBaseMaxHealth    = -1;
int g_offBaseHealth       = -1;
int g_offBaseAmmo         = -1;
int g_offBaseMaxAmmo      = -1;  // 最大弹药 (仅网络属性, 用 FindSendPropInfo 查)
int g_offBaseGunType      = -1;
int g_offBaseSentryTop    = -1;
int g_offBaseTakedamage   = -1;
int g_offBaseCollisionGrp = -1;  // 网络属性, 用 FindSendPropInfo 查
// 炮口属性偏移 (这四项在哨戒塔的通用炮口基类里, 各类型塔通用)
int g_offTopShootRange    = -1;
int g_offTopNextFireTime  = -1;
int g_offTopFriendlyFire  = -1;
int g_offTopSentryBase    = -1;
// 塔顶转向速度字段 (炮口基类成员, 引擎默认 回正75/瞄准150 度每秒)
int g_offTopBaseTurnRate  = -1;
int g_offTopEnemyTurnRate = -1;
// 喷火/冰冻塔的"射速时钟" m_flLastFireTime 的偏移。
// 特殊点: 这个属性没在游戏的属性表里登记, 无法按名字访问,
// 于是借用它前面紧挨着的网络属性 m_bFiring 的位置 +4 字节来定位 (详见
// CacheLastFireTimeOffset)。取值含义: -1=还没定位 -2=定位失败 其它=偏移。
int g_offTopLastFireTime  = -1;

bool g_bBasePropsCached = false;   // 底座偏移是否已查好
bool g_bTopPropsCached  = false;   // 炮口偏移是否已查好

// ============================================================================
//  数据结构: 每座被增强的哨戒塔存一条记录
//  (用 ArrayList 保存, 只遍历有记录的塔, 不用扫描全部实体)
// ============================================================================
enum struct SentryData {
    int   baseRef;           // 底座的实体引用 (比实体索引安全, 防实体被销毁后复用)
    int   topRef;            // 炮口的实体引用 (0=炮口还没出现, 等组装完)
    int   origMaxHealth;     // 记录初始最大生命, 便于倍率变动时重新计算
    int   origAmmo;          // 记录初始弹药
    float origShootRange;    // 记录初始射程 (0=还没记录, 炮口出现后再记)
    int   origCollision;     // 记录初始碰撞设置 (取消头顶塔时恢复)
    MoveType origMoveType;    // 记录初始移动类型 (放头顶改 NONE 消除物理滞后, 取消时恢复)
    int   origTakedamage;    // 记录初始受击设置 (取消无敌时恢复)
    int   origFriendlyFire;  // 记录炮口初始的"友军伤害"开关 (-1=还没记录)
    int   gunType;           // 塔类型: 0=机枪 1=炮 2=喷火 3=冰冻 4=电磁
    float lastNextFireTime;  // 上一帧看到的"下次开火时间" (用于检测机枪开火瞬间)
    float lastLastFireTime;  // 上一帧看到的"上次开火时钟" (用于喷火/冰冻加速)
    float nextTopSearch;     // 下次允许寻找炮口的时间 (限制查找频率)
    // 头顶塔相关 (hatUserId == 0 表示不在任何玩家头顶)
    int   hatUserId;         // 头顶塔所属玩家 (按 userid 区分)
    int   hatMarineRef;      // 该玩家控制的角色实体引用
    float hatYawOffset;      // 头顶塔的朝向偏移
}

ArrayList g_hSentries;  // 所有哨戒塔记录的列表

// ============================================================================
//  HUD 显示状态 (每个玩家各一份)
//  Tab 记分板和任务简报是客户端面板, 服务端插件写不进去,
//  所以信息只能显示在游戏画面上, 由玩家自己决定开不开。
// ============================================================================
bool g_bHudEnabled[MAXPLAYERS + 1];   // 该玩家是否开着 HUD
int  g_iHudMode[MAXPLAYERS + 1];      // 用哪种方式显示: 0=还没试 1=内置HUD 2=备用方式
int  g_iHudTextEnt[MAXPLAYERS + 1];   // 备用显示方式用到的文字实体引用 (0=没创建)

// ============================================================================
//  插件信息
// ============================================================================
public Plugin myinfo = {
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "AS:RD 哨戒塔增强 + 头顶哨戒塔 + 信息HUD",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
//  插件启动: 创建所有 ConVar、注册命令、启动 HUD 定时器
// ============================================================================
public void OnPluginStart()
{
    // 每个 CreateConVar: 名字, 默认值, 说明, 是否允许变化 + 取值范围
    g_cvEnabled = CreateConVar(
        "sm_asrd_sentry_enabled", "1",
        "启用/禁用哨戒塔增强",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvHealthMult = CreateConVar(
        "sm_asrd_sentry_health_mult", "5.0",
        "哨戒塔生命值倍率 (1.0=默认, 5.0=五倍)",
        FCVAR_NOTIFY, true, 1.0
    );
    g_cvFireRateMult = CreateConVar(
        "sm_asrd_sentry_firerate_mult", "35",
        "哨戒塔射速倍率 (1.0=默认, 35=35倍射速)",
        FCVAR_NOTIFY, true, 1.0
    );
    g_cvRangeMult = CreateConVar(
        "sm_asrd_sentry_range_mult", "1.0",
        "哨戒塔射程倍率 (1.0=默认)",
        FCVAR_NOTIFY, true, 1.0
    );
    g_cvAmmoMult = CreateConVar(
        "sm_asrd_sentry_ammo_mult", "25",
        "哨戒塔弹药倍率 (1.0=默认, 25=25 倍弹药)",
        FCVAR_NOTIFY, true, 1.0
    );
    g_cvDamageMult = CreateConVar(
        "sm_asrd_sentry_damage_mult", "1.0",
        "哨戒塔子弹伤害倍率 (1.0=默认, 基于机枪10/炮60/喷火4, 冰冻塔不增强)",
        FCVAR_NOTIFY, true, 1.0
    );
    g_cvInvulnerable = CreateConVar(
        "sm_asrd_sentry_invulnerable", "0",
        "哨戒塔无敌 (0=正常可被摧毁, 1=不会死亡不会消失)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvNoPlayerDamage = CreateConVar(
        "sm_asrd_sentry_no_player_damage", "1",
        "禁用塔对玩家的伤害 (0=可伤害, 1=不伤害玩家/marine)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvHatTurnSpeed = CreateConVar(
        "sm_asrd_sentry_hat_turnspeed", "360.0",
        "头顶哨戒塔转向速度 (度/秒, 0=瞬间转向, 360=1秒转1圈)",
        FCVAR_NOTIFY, true, 0.0
    );
    g_cvHatMaxDist = CreateConVar(
        "sm_asrd_sentry_hat_maxdist", "100.0",
        "头顶哨戒塔命令允许的最大距离 (0=不限制)",
        FCVAR_NOTIFY, true, 0.0
    );
    g_cvHatLayerSpace = CreateConVar(
        "sm_asrd_sentry_hat_layerspace", "60.0",
        "头顶多座哨戒塔的层间距 (世界单位, 每多一座塔往上叠一层)",
        FCVAR_NOTIFY, true, 20.0, true, 200.0
    );
    g_cvTurnRate = CreateConVar(
        "sm_asrd_sentry_turn_rate", "0",
        "哨戒塔顶转向速度 (度/秒, 0=瞬间转向, 150=引擎默认速度)",
        FCVAR_NOTIFY, true, 0.0
    );
    g_cvHatPublic = CreateConVar(
        "sm_asrd_sentry_hat_public", "1",
        "允许所有玩家使用头顶哨戒塔命令 (0=仅管理员, 1=所有玩家)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvDebug = CreateConVar(
        "sm_asrd_sentry_debug", "0",
        "调试模式",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvHudDefault = CreateConVar(
        "sm_asrd_sentry_hud_default", "0",
        "新玩家默认显示哨戒塔信息HUD (0=默认不显示, 玩家可用 sm_sentryhud 自行切换)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvDropLimit = CreateConVar(
        "sm_asrd_sentry_drop_limit", "20",
        "场上最多可同时存在的哨戒炮塔拾取箱数量 (0=不限制)",
        FCVAR_NOTIFY, true, 0.0
    );
    g_cvDropPublic = CreateConVar(
        "sm_asrd_sentry_drop_public", "1",
        "允许所有玩家使用掉落哨戒炮塔命令 (0=仅管理员, 1=所有玩家)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvRefillPublic = CreateConVar(
        "sm_asrd_sentry_refill_public", "1",
        "允许所有玩家使用一键满配命令 (0=仅管理员, 1=所有玩家)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    g_cvNoInfiniteAmmo = CreateConVar(
        "sm_asrd_sentry_no_infinite_ammo", "1",
        "强制关闭哨戒塔无限弹药 (asw_sentry_infinite_ammo=0), 覆盖挑战设置 (0=不干预, 1=持续压制)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    g_cvNoDismantleRefill = CreateConVar(
        "sm_asrd_sentry_no_dismantle_refill", "1",
        "拆掉哨戒塔时不要补满弹药 (强制 rd_sentry_refilled_by_dismantling=0), 让重部署保留箱内剩余 (0=不干预, 1=持续压制)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    // 把以上 ConVar 的设置自动保存/读取到配置文件
    AutoExecConfig(true, "asrd_sentry_enhancer");

    // 注册命令 (管理员命令用 RegAdminCmd, 玩家命令用 RegConsoleCmd)
    RegAdminCmd("sm_sentry_refresh",   Command_RefreshSentries, ADMFLAG_GENERIC, "重新增强所有哨戒塔并补满弹药");
    RegAdminCmd("sm_sentry_status",    Command_SentryStatus,    ADMFLAG_GENERIC, "查看所有哨戒塔状态");
    RegAdminCmd("sm_sentry_dump",      Command_SentryDump,      ADMFLAG_GENERIC, "转储哨戒塔属性（调试）");
    RegAdminCmd("sm_sentry_dump_player", Command_DumpPlayer,    ADMFLAG_GENERIC, "转储玩家实体属性（调试）");
    RegAdminCmd("sm_sentryhat",        Command_SentryHat,       ADMFLAG_GENERIC, "把最近的哨戒塔放到自己头顶");
    RegAdminCmd("sm_sentryhat_off",    Command_SentryHatOff,    ADMFLAG_GENERIC, "取消所有玩家的头顶哨戒塔");
    RegAdminCmd("sm_sentry_boost",     Command_SentryBoost,     ADMFLAG_GENERIC, "一键满配增强所有哨戒塔");
    RegAdminCmd("sm_sentry_unboost",   Command_SentryUnboost,   ADMFLAG_GENERIC, "一键还原哨戒塔增强倍率(默认档)");
    RegAdminCmd("sm_sentry_drop",      Command_SentryDrop,      ADMFLAG_GENERIC, "在身边掉落一座哨戒塔(默认炮)");
    RegConsoleCmd("sm_sentrydrop",    Command_SentryDropPublic, "在身边掉落一座哨戒炮塔拾取箱 (需管理员开启)");
    RegConsoleCmd("sm_sentry_refill", Command_SentryRefillPublic, "一键补满所有哨戒塔的生命与弹药 (需管理员开启)");
    RegConsoleCmd("sm_hat",            Command_HatPublic,       "把最近的哨戒塔放到自己头顶 (需管理员开启)");
    RegConsoleCmd("sm_hat_off",        Command_HatOffPublic,    "取消自己的头顶哨戒塔 (需管理员开启)");
    RegConsoleCmd("sm_sentryhud",      Command_SentryHudToggle, "切换哨戒塔信息HUD显示 (默认不显示)");

    // ConVar 数值被改动时, 自动触发对应的刷新逻辑
    g_cvHealthMult.AddChangeHook(OnMultCvarChanged);
    g_cvFireRateMult.AddChangeHook(OnMultCvarChanged);
    g_cvRangeMult.AddChangeHook(OnMultCvarChanged);
    g_cvAmmoMult.AddChangeHook(OnMultCvarChanged);
    g_cvDamageMult.AddChangeHook(OnDamageMultCvarChanged);
    g_cvInvulnerable.AddChangeHook(OnInvulnCvarChanged);
    g_cvNoPlayerDamage.AddChangeHook(OnNoDamageCvarChanged);
    g_cvNoInfiniteAmmo.AddChangeHook(OnAmmoGuardCvarChanged);   // 开关被打开时立即压制一次
    g_cvNoDismantleRefill.AddChangeHook(OnDismantleGuardCvarChanged);

    g_hSentries = new ArrayList(sizeof(SentryData));

    // 无限弹药压制: 找到引擎的 asw_sentry_infinite_ammo 并挂上变更钩子
    SetupInfiniteAmmoGuard();

    // 拆除不补弹: 找到引擎的 rd_sentry_refilled_by_dismantling 并挂上变更钩子
    SetupDismantleRefillGuard();

    // 若插件是在游戏进行中才被加载, 把地图里已存在的哨戒塔也增强一遍
    // (正常启动时此时还没有塔, 这个循环什么都不会找到)
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "asw_sentry_base")) != -1)
        CreateTimer(0.3, Timer_EnhanceSentry, EntIndexToEntRef(entity), TIMER_FLAG_NO_MAPCHANGE);

    // HUD 刷新定时器: 每 1 秒重发一次文字 (只发给开着的玩家)
    CreateTimer(1.0, Timer_UpdateHud, _, TIMER_REPEAT);
}

// ============================================================================
//  配置文件加载完成后: 应用伤害覆盖 (此时 cfg 里的自定义值已生效)
// ============================================================================
public void OnConfigsExecuted()
{
    ApplyDamageOverrides();

    // 服务器/挑战的 cfg 都在此之前执行完, 这里再压一次无限弹药
    SetupInfiniteAmmoGuard();
    ForceNoInfiniteAmmo();

    // 同一时机把"拆除补弹"也压回关闭
    SetupDismantleRefillGuard();
    ForceNoDismantleRefill();
}

// ============================================================================
//  玩家进服: 按默认值初始化他的 HUD 开关
// ============================================================================
public void OnClientPutInServer(int client)
{
    g_bHudEnabled[client] = g_cvHudDefault.BoolValue;
    g_iHudMode[client]    = 0;   // 还没试过用哪种方式显示
    g_iHudTextEnt[client] = 0;
}

// ============================================================================
//  玩家离开: 关闭他的 HUD 并清理为他创建的文字实体
// ============================================================================
public void OnClientDisconnected(int client)
{
    g_bHudEnabled[client] = false;
    g_iHudMode[client]    = 0;

    int ent = EntRefToEntIndex(g_iHudTextEnt[client]);
    if (ent != INVALID_ENT_REFERENCE && IsValidEntity(ent))
        AcceptEntityInput(ent, "Kill");
    g_iHudTextEnt[client] = 0;
}

// ============================================================================
//  信息 HUD 部分
//  位置: 画面右上角。开关命令 sm_sentryhud。
//  显示方式自动选择: 先用游戏内置的 HUD 文字, 如果这个游戏分支不支持,
//  就改用一个叫 game_text 的通用文字实体来显示 (两种都按玩家单独显示)。
// ============================================================================

// 切换当前玩家的 HUD 开关
public Action Command_SentryHudToggle(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "该命令只能在游戏内使用");
        return Plugin_Handled;
    }

    g_bHudEnabled[client] = !g_bHudEnabled[client];   // 翻转开关状态
    ReplyToCommand(client, "哨戒塔信息HUD已%s (再次输入 sm_sentryhud 切换)",
        g_bHudEnabled[client] ? "开启" : "关闭");
    return Plugin_Handled;
}

// 每 1 秒执行一次: 给开着 HUD 的玩家发送最新信息
public Action Timer_UpdateHud(Handle timer)
{
    if (!g_cvEnabled.BoolValue)
        return Plugin_Continue;

    // 没人要看就什么都不做, 省得白组字符串
    bool bAny = false;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i) && g_bHudEnabled[i])
        {
            bAny = true;
            break;
        }
    }
    if (!bAny)
        return Plugin_Continue;

    char sBuf[256];
    BuildHudText(sBuf, sizeof(sBuf));

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i) || !g_bHudEnabled[i])
            continue;

        if (g_iHudMode[i] == 2)
        {
            // 已确认这个玩家要走备用方式
            ShowViaGameText(i, sBuf);
        }
        else
        {
            // 先设文字位置/颜色/停留时间, 再尝试用内置 HUD 显示
            SetHudTextParams(HUD_POS_X, HUD_POS_Y, HUD_HOLD_TIME,
                255, 220, 120, 255, 0, 0.0, 0.0, 0.0);
            int iShowRet = ShowHudText(i, HUD_CHANNEL, sBuf);
            if (iShowRet == -1)
            {
                // 返回值 -1 表示这个游戏分支不支持内置 HUD → 改备用方式
                g_iHudMode[i] = 2;
                if (g_cvDebug.BoolValue)
                    PrintToServer("[哨戒塔] 玩家#%d 内置HUD不可用, 改用 game_text", i);
                ShowViaGameText(i, sBuf);
            }
            else
            {
                g_iHudMode[i] = 1;
                if (g_cvDebug.BoolValue)
                    PrintToServer("[哨戒塔] 玩家#%d 内置HUD ok, ShowHudText=%d", i, iShowRet);
            }
        }
    }
    return Plugin_Continue;
}

// 把哨戒塔信息拼成一段多行文字
// 注意: 这类文字不会自动换行, 一行太长会被屏幕边缘截断, 所以分多行写短句
void BuildHudText(char[] sBuf, int maxlen)
{
    // 统计: 塔总数 / 头顶上的塔数 / 还没组装完的塔数
    int iTotal = 0, iHats = 0, iPending = 0;
    SentryData data;
    for (int i = 0; i < g_hSentries.Length; i++)
    {
        g_hSentries.GetArray(i, data);
        int iBase = EntRefToEntIndex(data.baseRef);
        if (iBase == INVALID_ENT_REFERENCE || !IsValidEntity(iBase))
            continue;   // 底座已不存在的记录跳过
        iTotal++;
        if (data.hatUserId != 0)
            iHats++;
        if (data.topRef == 0)
            iPending++;
    }

    if (iTotal == 0)
    {
        Format(sBuf, maxlen, "[哨戒塔增强 v%s]\n当前无哨戒塔", PLUGIN_VERSION);
        return;
    }

    Format(sBuf, maxlen,
        "[哨戒塔增强 v%s]\n塔:%d 头顶:%d 未组装:%d\n生命x%.1f 射速x%.1f\n射程x%.1f 弹药x%.1f\n无敌:%s 禁伤:%s",
        PLUGIN_VERSION, iTotal, iHats, iPending,
        g_cvHealthMult.FloatValue, g_cvFireRateMult.FloatValue,
        g_cvRangeMult.FloatValue, g_cvAmmoMult.FloatValue,
        g_cvInvulnerable.BoolValue ? "开" : "关",
        g_cvNoPlayerDamage.BoolValue ? "开" : "关");
}

// 为某个玩家取得 (没有就创建) 一个专用的 game_text 文字实体
// 关键: 不勾选"所有玩家", 这样文字只会显示给触发它的那一个玩家
int GetOrCreateGameText(int client)
{
    int ent = EntRefToEntIndex(g_iHudTextEnt[client]);
    if (ent != INVALID_ENT_REFERENCE && IsValidEntity(ent))
        return ent;   // 已创建且有效, 直接复用

    ent = CreateEntityByName("game_text");
    if (ent == -1)
        return -1;

    // 用一个不重复的名字, 便于识别是谁的
    char sName[48];
    Format(sName, sizeof(sName), "asrd_sentryhud_%d", GetClientUserId(client));

    // 用 DispatchKeyValue 逐项设置文字实体的外观参数
    DispatchKeyValue(ent, "targetname", sName);
    DispatchKeyValue(ent, "spawnflags", "0");          // 不勾"所有玩家" → 只给触发者看
    DispatchKeyValue(ent, "channel",   "4");
    DispatchKeyValue(ent, "x",         "0.60");        // 横向位置
    DispatchKeyValue(ent, "y",         "0.08");        // 纵向位置
    DispatchKeyValue(ent, "effect",    "0");           // 显示效果: 淡入淡出
    DispatchKeyValue(ent, "color",     "255 220 120"); // 文字颜色 RGB
    DispatchKeyValue(ent, "fadein",    "0.1");         // 淡入秒数
    DispatchKeyValue(ent, "fadeout",   "0.4");         // 淡出秒数
    DispatchKeyValue(ent, "holdtime",  "1.5");         // 停留秒数
    DispatchSpawn(ent);   // 设置完后正式创建它

    g_iHudTextEnt[client] = EntIndexToEntRef(ent);
    return ent;
}

// 用备用方式 (game_text 实体) 给某玩家显示一段文字
void ShowViaGameText(int client, const char[] sMsg)
{
    int ent = GetOrCreateGameText(client);
    if (ent == -1)
        return;

    // 先更新文字内容, 再以该玩家为"触发者"让它显示 (于是只他一人可见)
    DispatchKeyValue(ent, "message", sMsg);
    AcceptEntityInput(ent, "Display", client);
}

// ============================================================================
//  地图加载: 清空上一局留下的状态
// ============================================================================
public void OnMapStart()
{
    g_hSentries.Clear();
    g_bBasePropsCached = false;  // 换图后实体类可能重新注册, 偏移重新查
    g_bTopPropsCached  = false;
    g_offTopLastFireTime = -1;   // 那个特殊偏移也重新定位

    // 预缓存拾取箱模型: 运行时 spawn 的哨戒枪箱 (sm_sentry_drop) 客户端才能显示
    PrecacheModel("models/items/ItemBox/ItemBoxLarge.mdl", true);

    // 换图后挑战可能重新设过无限弹药, 这里压回 0
    SetupInfiniteAmmoGuard();
    ForceNoInfiniteAmmo();

    // 拆除补弹同样压回关闭
    SetupDismantleRefillGuard();
    ForceNoDismantleRefill();
}

// ============================================================================
//  插件卸载: 把被改过的塔属性还原成初始值
//  (这样管理员 sm plugins reload 重载插件时, 不会把已经放大的数值
//   当成"初始值"再放大一遍。弹药不还原——还原会白白扣掉玩家塔里的弹药)
// ============================================================================
public void OnPluginEnd()
{
    SentryData data;
    for (int i = 0; i < g_hSentries.Length; i++)
    {
        g_hSentries.GetArray(i, data);
        int iBase = EntRefToEntIndex(data.baseRef);
        if (iBase == INVALID_ENT_REFERENCE || !IsValidEntity(iBase))
            continue;

        if (data.origMaxHealth > 0)
        {
            SetEntProp(iBase, Prop_Data, "m_iMaxHealth", data.origMaxHealth);
            SetEntProp(iBase, Prop_Data, "m_iHealth", data.origMaxHealth);
        }

        if (g_offBaseTakedamage >= 0 && data.origTakedamage > 0)
            SetEntProp(iBase, Prop_Data, "m_takedamage", data.origTakedamage);

        int iTop = EntRefToEntIndex(data.topRef);
        if (iTop != INVALID_ENT_REFERENCE && IsValidEntity(iTop))
        {
            if (data.origShootRange > 0.0 && g_offTopShootRange >= 0)
                SetEntPropFloat(iTop, Prop_Data, "m_flShootRange", data.origShootRange);
            if (data.origFriendlyFire >= 0 && g_offTopFriendlyFire >= 0)
                SetEntProp(iTop, Prop_Data, "m_bFriendlyFire", data.origFriendlyFire);
        }
    }
}

// ============================================================================
//  有新实体生成时: 若是哨戒塔底座, 延迟 0.3 秒后增强它
//  延迟原因: 底座刚生成时有些属性还没初始化好。
//  注意: 玩家部署的塔一开始是"未组装"状态, 还没有炮口 (top),
//  炮口相关的增强要等组装完成后再补 (见 OnGameFrame / ApplyTopEnhancements)。
// ============================================================================
public void OnEntityCreated(int entity, const char[] classname)
{
    if (!g_cvEnabled.BoolValue)
        return;
    if (entity <= 0)
        return;

    if (StrEqual(classname, "asw_sentry_base"))
    {
        CreateTimer(0.3, Timer_EnhanceSentry, EntIndexToEntRef(entity), TIMER_FLAG_NO_MAPCHANGE);
    }
}

// ============================================================================
//  有实体被销毁时: 若是记录里的底座, 删掉对应记录
// ============================================================================
public void OnEntityDestroyed(int entity)
{
    if (entity <= 0)
        return;

    int idx = FindSentryByEntIndex(entity);
    if (idx >= 0)
        g_hSentries.Erase(idx);
}

// ============================================================================
//  底座属性偏移的缓存: 第一次增强塔时查一次, 之后直接复用
// ============================================================================
void CacheBasePropOffsets(int iBase)
{
    if (g_bBasePropsCached)
        return;

    g_offBaseMaxHealth    = FindDataMapInfo(iBase, "m_iMaxHealth");
    g_offBaseHealth       = FindDataMapInfo(iBase, "m_iHealth");
    g_offBaseAmmo         = FindDataMapInfo(iBase, "m_iAmmo");
    g_offBaseMaxAmmo      = FindSendPropInfo("asw_sentry_base", "m_iMaxAmmo");
    g_offBaseGunType      = FindDataMapInfo(iBase, "m_nGunType");
    g_offBaseSentryTop    = FindDataMapInfo(iBase, "m_hSentryTop");
    g_offBaseTakedamage   = FindDataMapInfo(iBase, "m_takedamage");
    g_offBaseCollisionGrp = FindSendPropInfo("asw_sentry_base", "m_CollisionGroup");

    g_bBasePropsCached = true;

    if (g_cvDebug.BoolValue)
    {
        PrintToServer("[哨戒塔] base 属性偏移缓存完成:");
        PrintToServer("  MaxHealth=%d Health=%d Ammo=%d MaxAmmo=%d GunType=%d SentryTop=%d Takedamage=%d Coll=%d",
            g_offBaseMaxHealth, g_offBaseHealth, g_offBaseAmmo, g_offBaseMaxAmmo, g_offBaseGunType,
            g_offBaseSentryTop, g_offBaseTakedamage, g_offBaseCollisionGrp);
    }
}

// ============================================================================
//  炮口属性偏移的缓存: 只在拿到一个有效炮口时才建立
//  (没组装完的塔没有炮口, 不能拿一个不存在的实体去查偏移)
// ============================================================================
void CacheTopPropOffsets(int iTop)
{
    if (g_bTopPropsCached || iTop <= 0)
        return;

    // 下面六个属性都在哨戒塔通用的炮口基类里, 各种塔 (机枪/炮/喷火/冰冻) 通用
    g_offTopShootRange   = FindDataMapInfo(iTop, "m_flShootRange");   // 射程
    g_offTopNextFireTime = FindDataMapInfo(iTop, "m_fNextFireTime");  // 下次开火时间
    g_offTopFriendlyFire = FindDataMapInfo(iTop, "m_bFriendlyFire");  // 是否误伤队友
    g_offTopSentryBase   = FindDataMapInfo(iTop, "m_hSentryBase");    // 指向底座
    g_offTopBaseTurnRate  = FindDataMapInfo(iTop, "m_iBaseTurnRate");  // 回正速度(度/秒)
    g_offTopEnemyTurnRate = FindDataMapInfo(iTop, "m_iEnemyTurnRate"); // 瞄准敌人速度(度/秒)

    g_bTopPropsCached = true;

    if (g_cvDebug.BoolValue)
    {
        PrintToServer("[哨戒塔] top 属性偏移缓存完成:");
        PrintToServer("  ShootRange=%d NextFire=%d FriendlyFire=%d SentryBase=%d BaseTurn=%d EnemyTurn=%d",
            g_offTopShootRange, g_offTopNextFireTime, g_offTopFriendlyFire, g_offTopSentryBase,
            g_offTopBaseTurnRate, g_offTopEnemyTurnRate);
    }
}

// ============================================================================
//  定位喷火/冰冻塔"射速时钟" m_flLastFireTime 在内存里的位置
//  这个属性没在游戏属性表里登记, 无法按名字读写。但它前面紧挨着一个
//  已知的网络属性 m_bFiring (一个 bool, 占 1 字节 + 3 字节对齐填充),
//  所以 m_flLastFireTime 的位置 = m_bFiring 的位置 + 4 字节。
// ============================================================================
void CacheLastFireTimeOffset(int iTop)
{
    if (g_offTopLastFireTime != -1)   // 已经定位过 (成功或失败), 不再重复
        return;

    // 先按当前实体的网络类查 m_bFiring 的位置
    int off = -1;
    char sNetClass[64];
    if (GetEntityNetClass(iTop, sNetClass, sizeof(sNetClass)))
        off = FindSendPropInfo(sNetClass, "m_bFiring");

    // 查不到就退一步, 直接按喷火塔的类名查 (更稳妥)
    if (off <= 0)
        off = FindSendPropInfo("CASW_Sentry_Top_Flamer", "m_bFiring");

    // 校验: 偏移必须有效, 且必须比炮口基类属性更靠后 (派生类成员排在基类之后)
    if (off > 0 && (g_offTopSentryBase < 0 || off > g_offTopSentryBase))
    {
        g_offTopLastFireTime = off + 4;
        if (g_cvDebug.BoolValue)
            PrintToServer("[哨戒塔] m_flLastFireTime 原始偏移=%d (m_bFiring@%d + 4)",
                g_offTopLastFireTime, off);
        return;
    }

    g_offTopLastFireTime = -2;  // 定位失败: 本图喷火/冰冻塔的射速加速不可用
    if (g_cvDebug.BoolValue)
        PrintToServer("[哨戒塔] m_flLastFireTime 偏移定位失败, 喷火/冰冻塔射速加速不可用");
}

// ============================================================================
//  0.3 秒延迟定时器: 到点后真正执行增强
// ============================================================================
public Action Timer_EnhanceSentry(Handle timer, int ref)
{
    int entity = EntRefToEntIndex(ref);
    if (entity == INVALID_ENT_REFERENCE || !IsValidEntity(entity))
        return Plugin_Stop;   // 塔已被销毁, 不再处理

    EnhanceSentry(entity, false);
    return Plugin_Stop;
}

// ============================================================================
//  炮口相关的增强: 拿到有效炮口时调用
//  1. 记录这个炮口, 并确保炮口偏移已缓存
//  2. 若还没记录过初始射程 (玩家刚组装完的塔), 现在记录并乘上射程倍率
//  3. 记录炮口初始的"友军伤害"开关; 若开了禁伤则把它关掉
//  本函数可重复调用, 结果一致
// ============================================================================
void ApplyTopEnhancements(SentryData data, int iTop)
{
    data.topRef = EntIndexToEntRef(iTop);
    CacheTopPropOffsets(iTop);

    // 首次遇到这个炮口时, 记录它本来的射程
    if (data.origShootRange <= 0.0 && g_offTopShootRange >= 0)
        data.origShootRange = GetEntPropFloat(iTop, Prop_Data, "m_flShootRange");

    // 按射程倍率改写射程 (倍率 1.0 时等于还原成原值)
    if (data.origShootRange > 0.0 && g_offTopShootRange >= 0)
    {
        SetEntPropFloat(iTop, Prop_Data, "m_flShootRange",
            data.origShootRange * g_cvRangeMult.FloatValue);
    }

    // 首次遇到时记录它本来的友军伤害开关 (默认是"会误伤")
    if (data.origFriendlyFire < 0 && g_offTopFriendlyFire >= 0)
        data.origFriendlyFire = GetEntProp(iTop, Prop_Data, "m_bFriendlyFire");

    // 哨戒塔是否误伤队友, 由炮口的 m_bFriendlyFire 决定; 置 0 即关闭误伤
    if (g_cvNoPlayerDamage.BoolValue && g_offTopFriendlyFire >= 0
        && GetEntProp(iTop, Prop_Data, "m_bFriendlyFire") != 0)
    {
        SetEntProp(iTop, Prop_Data, "m_bFriendlyFire", 0);
    }

    // 炮塔自身转向速度: ConVar>0 用指定值, =0 瞬间转向 (引擎默认 150 度/秒)
    if (g_offTopBaseTurnRate >= 0 && g_offTopEnemyTurnRate >= 0)
    {
        float fTurn = g_cvTurnRate.FloatValue;
        int iEnemyRate, iBaseRate;
        if (fTurn <= 0.0)
        {
            // 瞬间转向: 设极大值, 单帧即可转过最大 180° 视角差
            iEnemyRate = 100000;
            iBaseRate  = 100000;
        }
        else
        {
            iEnemyRate = RoundToNearest(fTurn);
            iBaseRate  = RoundToNearest(fTurn / 2.0);
        }
        SetEntProp(iTop, Prop_Data, "m_iEnemyTurnRate", iEnemyRate);   // 瞄准敌人速度
        SetEntProp(iTop, Prop_Data, "m_iBaseTurnRate", iBaseRate);     // 无敌人回正速度
    }
}

// ============================================================================
//  核心: 增强一座哨戒塔 (bForce=true 时即使已有记录也重新增强)
// ============================================================================
void EnhanceSentry(int iBase, bool bForce)
{
    // 已有记录且不强制, 直接返回
    int idx = FindSentryByEntIndex(iBase);
    if (!bForce && idx >= 0)
        return;

    // 找这座塔的炮口 (未组装的塔此时没有炮口, 返回 -1, 属正常)
    int iTop = FindSentryTop(iBase);
    CacheBasePropOffsets(iBase);

    float fHealthMult = g_cvHealthMult.FloatValue;
    float fAmmoMult   = g_cvAmmoMult.FloatValue;
    float fRangeMult  = g_cvRangeMult.FloatValue;

    // ── 情况一: 已有记录, 只重新套用一遍增强 ──
    if (idx >= 0)
    {
        SentryData data;
        g_hSentries.GetArray(idx, data);

        // 有炮口就刷新炮口增强 (补采射程/禁伤等)
        if (iTop > 0)
            ApplyTopEnhancements(data, iTop);
        // 没有炮口就保持记录不动, 等它组装完再补

        // 重新按初始值计算生命/弹药
        ReapplyEnhance(iBase, data);

        // 补满弹药
        if (data.origAmmo > 0)
        {
            int iFullAmmo = RoundToFloor(float(data.origAmmo) * fAmmoMult);
            SetEntProp(iBase, Prop_Data, "m_iAmmo", iFullAmmo);
            // 同步放大最大弹药, 让 HUD 弹药条按增强后的上限递减, 否则会一直显示满格
            if (g_offBaseMaxAmmo >= 0)
                SetEntData(iBase, g_offBaseMaxAmmo, iFullAmmo);
        }

        // 重新应用无敌
        if (g_cvInvulnerable.BoolValue && g_offBaseTakedamage >= 0)
            SetEntProp(iBase, Prop_Data, "m_takedamage", 0);

        g_hSentries.SetArray(idx, data);

        char sTypeName[32];
        GetSentryTypeName(data.gunType, sTypeName, sizeof(sTypeName));
        if (iTop > 0)
        {
            PrintToServer("[哨戒塔刷新] #%d [%s] (生命x%.1f 射速x%.1f 射程x%.1f 弹药x%.1f)",
                iBase, sTypeName, fHealthMult, g_cvFireRateMult.FloatValue,
                fRangeMult, fAmmoMult);
        }
        else
        {
            PrintToServer("[哨戒塔刷新] #%d [%s] (生命x%.1f 射速x%.1f 弹药x%.1f) [未组装: 组装完成后自动补全炮口增强]",
                iBase, sTypeName, fHealthMult, g_cvFireRateMult.FloatValue, fAmmoMult);
        }
        return;
    }

    // ── 情况二: 新塔, 建立一条记录 ──
    SentryData data;
    data.baseRef = EntIndexToEntRef(iBase);
    data.topRef  = 0;             // 炮口出现后由 ApplyTopEnhancements 填上
    data.hatUserId    = 0;
    data.hatMarineRef = 0;
    data.hatYawOffset = 0.0;
    data.lastNextFireTime = 0.0;
    data.lastLastFireTime = 0.0;
    data.nextTopSearch    = 0.0;

    // 记录初始值 (底座属性在生成时已就绪)
    data.gunType       = (g_offBaseGunType  >= 0) ? GetEntProp(iBase, Prop_Data, "m_nGunType")    : 0;
    data.origMaxHealth = (g_offBaseMaxHealth >= 0) ? GetEntProp(iBase, Prop_Data, "m_iMaxHealth") : 0;
    // 弹药基准用该类型的"自然满弹药量"(取值与引擎 GetBaseAmmoForGunType 一致:
    // 机枪450/炮40/喷火1200/冰冻800/电磁300), 而非当前 m_iAmmo ——
    // 重部署时当前 m_iAmmo 已经是增强过的值, 拿它再乘倍率会导致弹药越叠越高。
    // 该基准只用于: ①全新塔按倍率放大 ②判断当前弹药是否为"未增强的基础值"。
    data.origAmmo      = GetSentryMaxAmmo(data.gunType);
    data.origCollision = (g_offBaseCollisionGrp >= 0) ? GetEntProp(iBase, Prop_Send, "m_CollisionGroup") : 0;
    data.origMoveType  = GetEntityMoveType(iBase);
    data.origTakedamage= (g_offBaseTakedamage >= 0) ? GetEntProp(iBase, Prop_Data, "m_takedamage") : 1;
    data.origShootRange  = 0.0;   // 炮口出现后再记录
    data.origFriendlyFire = -1;   // 炮口出现后再记录

    // 应用生命倍率
    if (data.origMaxHealth > 0)
    {
        int iNewHealth = RoundToFloor(float(data.origMaxHealth) * fHealthMult);
        SetEntProp(iBase, Prop_Data, "m_iMaxHealth", iNewHealth);
        SetEntProp(iBase, Prop_Data, "m_iHealth", iNewHealth);
    }

    // 应用弹药倍率
    if (data.origAmmo > 0)
    {
        int iFullAmmo = RoundToFloor(float(data.origAmmo) * fAmmoMult);
        int iCurAmmo  = GetEntProp(iBase, Prop_Data, "m_iAmmo");

        // 引擎部署哨戒塔时, 会把"箱子里带的弹药"交给新塔
        //   (CASW_Weapon_Sentry::DeploySentry -> pBase->SetAmmo( m_nSentryAmmo ));
        // 而拆掉一座塔时, 引擎会先把它的剩余弹药存回箱子
        //   (CASW_Sentry_Base::ActivateUseIcon, 前提 rd_sentry_refilled_by_dismantling=0,
        //    该 cvar 已被插件持续压成 0)。
        // 所以: 只有"全新塔"(弹药恰好等于该类型的基础满弹药)才按倍率放大;
        //       若当前弹药已是增强后的量级, 说明是拆卸后重新部署, 必须原样保留
        //       箱内剩余弹药, 不能覆盖成满弹药。
        if (iCurAmmo == data.origAmmo || iCurAmmo > iFullAmmo)
        {
            SetEntProp(iBase, Prop_Data, "m_iAmmo", iFullAmmo);
        }
        else if (g_cvDebug.BoolValue)
        {
            PrintToServer("[哨戒塔] #%d 重新部署: 保留箱内剩余弹药 %d (不补满)", iBase, iCurAmmo);
        }

        // 最大弹药始终按倍率放大, 让 HUD 弹药条按增强后的上限递减, 否则会一直显示满格
        if (g_offBaseMaxAmmo >= 0)
            SetEntData(iBase, g_offBaseMaxAmmo, iFullAmmo);
    }

    // 应用无敌
    if (g_cvInvulnerable.BoolValue && g_offBaseTakedamage >= 0)
        SetEntProp(iBase, Prop_Data, "m_takedamage", 0);

    // 应用炮口增强 (地图预置、已组装好的塔这里就有炮口;
    // 玩家刚部署、还没组装完的塔没有炮口, 先跳过, 等组装完再补)
    if (iTop > 0)
        ApplyTopEnhancements(data, iTop);

    g_hSentries.PushArray(data);

    char sTypeName[32];
    GetSentryTypeName(data.gunType, sTypeName, sizeof(sTypeName));

    if (iTop > 0)
    {
        PrintToServer("[哨戒塔增强] #%d [%s] (生命x%.1f 射速x%.1f 射程x%.1f 弹药x%.1f 无敌%s 禁伤%s)",
            iBase, sTypeName, fHealthMult, g_cvFireRateMult.FloatValue,
            fRangeMult, fAmmoMult,
            g_cvInvulnerable.BoolValue ? "开" : "关",
            g_cvNoPlayerDamage.BoolValue ? "开" : "关");
    }
    else
    {
        PrintToServer("[哨戒塔增强] #%d [%s] (生命x%.1f 射速x%.1f 弹药x%.1f 无敌%s 禁伤%s) [未组装: 等待炮口创建]",
            iBase, sTypeName, fHealthMult, g_cvFireRateMult.FloatValue,
            fAmmoMult,
            g_cvInvulnerable.BoolValue ? "开" : "关",
            g_cvNoPlayerDamage.BoolValue ? "开" : "关");
    }
}

// ============================================================================
//  无限弹药压制 (强制 asw_sentry_infinite_ammo = 0)
//
//  背景: 某些挑战会把引擎的 asw_sentry_infinite_ammo 设成 1 (让哨戒塔无限子弹),
//        甚至周期性重设; 在"不允许无限弹药"的正规挑战里它应当是 0。
//        本插件把它持续压回 0, 保证弹药正常消耗。
//
//  依据: 引擎 `ConVar::SetValue / InternalSetValue` (source-sdk-2013 tier1/convar.cpp)
//        里**没有**任何 FCVAR_CHEAT / sv_cheats 判断——该限制只存在于控制台命令
//        分发层。所以 SourceMod 的 `ConVar.SetInt()` 在 sv_cheats=0 时照样能写入。
//        万一某个引擎版本仍拒绝写入, 下面复核后会临时清掉 FCVAR_CHEAT 再写一次兜底,
//        保证 0 一定落地 (清标志属兜底路径, 正常情况下不会执行)。
//
//  覆盖范围: 独立于插件总开关 sm_asrd_sentry_enabled, 只要插件加载即生效;
//            不想被干预时把 sm_asrd_sentry_no_infinite_ammo 设为 0。
// ============================================================================
void SetupInfiniteAmmoGuard()
{
    if (g_cvEngineInfiniteAmmo != null)
        return;   // 已经拿到引用并挂好钩子

    g_cvEngineInfiniteAmmo = FindConVar("asw_sentry_infinite_ammo");
    if (g_cvEngineInfiniteAmmo == null)
    {
        if (!g_bAmmoGuardWarned)
        {
            g_bAmmoGuardWarned = true;
            LogError("[AS:RD] 未找到引擎 ConVar asw_sentry_infinite_ammo, 无法强制关闭哨戒塔无限弹药");
        }
        return;
    }

    g_cvEngineInfiniteAmmo.AddChangeHook(OnInfiniteAmmoChanged);
    ForceNoInfiniteAmmo();
}

void ForceNoInfiniteAmmo()
{
    if (!g_cvNoInfiniteAmmo.BoolValue)
        return;                       // 开关关着, 不干预
    if (g_cvEngineInfiniteAmmo == null)
        return;                       // 还没拿到引擎 ConVar
    if (g_bFixingInfiniteAmmo)
        return;                       // 正在压制, 避免递归
    if (g_cvEngineInfiniteAmmo.IntValue == 0)
        return;                       // 已经是 0, 什么都不用做

    g_bFixingInfiniteAmmo = true;
    g_cvEngineInfiniteAmmo.SetInt(0);

    // 兜底: 若引擎因 FCVAR_CHEAT 拒绝写入 (值仍非 0), 去掉该标志后再写一次
    if (g_cvEngineInfiniteAmmo.IntValue != 0)
    {
        int iFlags = g_cvEngineInfiniteAmmo.Flags;
        if ((iFlags & FCVAR_CHEAT) != 0)
        {
            g_cvEngineInfiniteAmmo.Flags = iFlags & ~FCVAR_CHEAT;
            g_cvEngineInfiniteAmmo.SetInt(0);
        }
    }
    g_bFixingInfiniteAmmo = false;
}

// 有人 (挑战/其它插件/控制台) 把 asw_sentry_infinite_ammo 改成非 0 时立刻压回去
public void OnInfiniteAmmoChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (!g_cvNoInfiniteAmmo.BoolValue || convar.IntValue == 0)
        return;

    if (g_cvDebug.BoolValue)
        PrintToServer("[哨戒塔][debug] asw_sentry_infinite_ammo 被外部设为 %s, 已强制改回 0", newValue);

    ForceNoInfiniteAmmo();
}

// 本插件自己的开关被改动: 打开时立即压制一次
public void OnAmmoGuardCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (convar.BoolValue)
        ForceNoInfiniteAmmo();
}

// ============================================================================
//  拆除补弹压制 (强制 rd_sentry_refilled_by_dismantling = 0)
//
//  背景: 某些挑战会把 rd_sentry_refilled_by_dismantling 设成 1, 此时玩家拆掉
//        自己部署的哨戒塔, 引擎会**跳过**"把剩余弹药存回箱子"这一步
//        (CASW_Sentry_Base::ActivateUseIcon 里的 pWeapon->SetSentryAmmo),
//        箱子便按满弹药处理, 重新部署后弹药直接回满。
//        本插件把它持续压回 0, 让拆除保留剩余弹药、重新部署不补满。
//
//  依据: 与 asw_sentry_infinite_ammo 相同 —— FCVAR_CHEAT 不拦 SourceMod 的
//        ConVar.SetInt(), 详见上面 ForceNoInfiniteAmmo 的说明。
// ============================================================================
void SetupDismantleRefillGuard()
{
    if (g_cvEngineDismantleRefill != null)
        return;   // 已经拿到引用并挂好钩子

    g_cvEngineDismantleRefill = FindConVar("rd_sentry_refilled_by_dismantling");
    if (g_cvEngineDismantleRefill == null)
    {
        if (!g_bDismantleGuardWarned)
        {
            g_bDismantleGuardWarned = true;
            LogError("[AS:RD] 未找到引擎 ConVar rd_sentry_refilled_by_dismantling, 无法强制关闭拆除补弹");
        }
        return;
    }

    g_cvEngineDismantleRefill.AddChangeHook(OnDismantleRefillChanged);
    ForceNoDismantleRefill();
}

void ForceNoDismantleRefill()
{
    if (!g_cvNoDismantleRefill.BoolValue)
        return;                       // 开关关着, 不干预
    if (g_cvEngineDismantleRefill == null)
        return;                       // 还没拿到引擎 ConVar
    if (g_bFixingDismantleRefill)
        return;                       // 正在压制, 避免递归
    if (g_cvEngineDismantleRefill.IntValue == 0)
        return;                       // 已经是 0, 什么都不用做

    g_bFixingDismantleRefill = true;
    g_cvEngineDismantleRefill.SetInt(0);

    // 兜底: 若引擎因 FCVAR_CHEAT 拒绝写入 (值仍非 0), 去掉该标志后再写一次
    if (g_cvEngineDismantleRefill.IntValue != 0)
    {
        int iFlags = g_cvEngineDismantleRefill.Flags;
        if ((iFlags & FCVAR_CHEAT) != 0)
        {
            g_cvEngineDismantleRefill.Flags = iFlags & ~FCVAR_CHEAT;
            g_cvEngineDismantleRefill.SetInt(0);
        }
    }
    g_bFixingDismantleRefill = false;
}

// 有人 (挑战/其它插件/控制台) 把 rd_sentry_refilled_by_dismantling 改成非 0 时立刻压回去
public void OnDismantleRefillChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (!g_cvNoDismantleRefill.BoolValue || convar.IntValue == 0)
        return;

    if (g_cvDebug.BoolValue)
        PrintToServer("[哨戒塔][debug] rd_sentry_refilled_by_dismantling 被外部设为 %s, 已强制改回 0", newValue);

    ForceNoDismantleRefill();
}

// 本插件自己的开关被改动: 打开时立即压制一次
public void OnDismantleGuardCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (convar.BoolValue)
        ForceNoDismantleRefill();
}

// ============================================================================
//  每游戏帧执行: 补采炮口、射速加速、无敌维持、头顶塔跟随
//  只遍历有记录的塔 (通常不到 20 个), 不扫描全部实体
// ============================================================================
public void OnGameFrame()
{
    // 无限弹药压制必须每帧跑, 且不能受总开关/哨戒塔列表为空影响 (见 ForceNoInfiniteAmmo)
    ForceNoInfiniteAmmo();

    // "拆除不补满弹药" 同样每帧保证 (挑战可能周期性重设)
    ForceNoDismantleRefill();

    if (!g_cvEnabled.BoolValue)
        return;
    if (g_hSentries.Length == 0)
        return;

    float fGameTime     = GetGameTime();
    float fFireRateMult = g_cvFireRateMult.FloatValue;
    bool  bInvuln       = g_cvInvulnerable.BoolValue;
    float fTickInterval = GetTickInterval();
    float fTurnSpeed    = g_cvHatTurnSpeed.FloatValue;

    SentryData data;
    for (int i = 0; i < g_hSentries.Length; i++)
    {
        g_hSentries.GetArray(i, data);

        // 校验底座是否还在 (被销毁就从列表里移除)
        int iBase = EntRefToEntIndex(data.baseRef);
        if (iBase == INVALID_ENT_REFERENCE || !IsValidEntity(iBase))
        {
            g_hSentries.Erase(i);
            i--;
            continue;
        }

        // ── 找炮口 ──
        // 玩家部署的塔要等角色组装完成 (约 7 秒) 才生成炮口,
        // 所以这里每 0.25 秒找一次, 找到了就补做炮口增强。
        int iTop = -1;
        if (data.topRef != 0)
        {
            int iTopIdx = EntRefToEntIndex(data.topRef);
            if (iTopIdx != INVALID_ENT_REFERENCE && IsValidEntity(iTopIdx))
                iTop = iTopIdx;
        }

        if (iTop <= 0 && fGameTime >= data.nextTopSearch)
        {
            data.nextTopSearch = fGameTime + 0.25;   // 限制查找频率, 别每帧都扫
            int iFound = FindSentryTop(iBase);
            if (iFound > 0)
            {
                ApplyTopEnhancements(data, iFound);
                iTop = iFound;
            }
        }

        // ── 射速加速 ──
        if (fFireRateMult > 1.0 && iTop > 0)
        {
            // 通用做法: 压缩"下次开火时间", 让机枪/炮这类塔更早开火
            if (g_offTopNextFireTime >= 0)
            {
                float fNextFire = GetEntPropFloat(iTop, Prop_Data, "m_fNextFireTime");

                // 塔刚开火时, 游戏会把"下次开火时间"跳到"现在+射击间隔",
                // 表现为数值突然变大——抓住这一刻, 把等待时间按倍率缩短
                if (fNextFire > data.lastNextFireTime && fNextFire > fGameTime)
                {
                    float fRemaining = fNextFire - fGameTime;     // 本来还要等多久
                    float fNewNext   = fGameTime + (fRemaining / fFireRateMult);
                    SetEntPropFloat(iTop, Prop_Data, "m_fNextFireTime", fNewNext);
                    data.lastNextFireTime = fNewNext;
                }
                else
                {
                    data.lastNextFireTime = fNextFire;   // 正常推进时只记录
                }
            }

            // 喷火/冰冻塔走另一套"射速时钟"(每次喷射后向前拨 0.1 秒),
            // 也要同步压缩, 否则射速倍率对它们无效。做法: 每次发现时钟
            // 向前跳了 N*0.1 秒, 就只让它跳 N*0.1/倍率 秒。
            // (大幅跳变通常是"刚开火"重置, 用 0.3 秒上限过滤掉, 防止爆发)
            if (data.gunType == 2 || data.gunType == 3)
            {
                if (g_offTopLastFireTime == -1)
                    CacheLastFireTimeOffset(iTop);   // 第一次先定位这个时钟的偏移

                if (g_offTopLastFireTime > 0)
                {
                    float fLastFire = GetEntDataFloat(iTop, g_offTopLastFireTime);
                    float fAdvance  = fLastFire - data.lastLastFireTime;

                    if (data.lastLastFireTime > 0.0 && fAdvance > 0.0 && fAdvance <= 0.3)
                    {
                        float fNewLast = data.lastLastFireTime + (fAdvance / fFireRateMult);
                        SetEntDataFloat(iTop, g_offTopLastFireTime, fNewLast);
                        data.lastLastFireTime = fNewLast;
                    }
                    else
                    {
                        data.lastLastFireTime = fLastFire;
                    }
                }
            }
        }

        // ── 无敌维持 ──
        if (bInvuln && g_offBaseTakedamage >= 0)
        {
            // 保持"不能被打"状态, 并保持满血
            if (GetEntProp(iBase, Prop_Data, "m_takedamage") != 0)
                SetEntProp(iBase, Prop_Data, "m_takedamage", 0);

            if (g_offBaseHealth >= 0 && g_offBaseMaxHealth >= 0)
            {
                int iMaxHp = GetEntProp(iBase, Prop_Data, "m_iMaxHealth");
                if (iMaxHp > 0 && GetEntProp(iBase, Prop_Data, "m_iHealth") < iMaxHp)
                    SetEntProp(iBase, Prop_Data, "m_iHealth", iMaxHp);
            }
        }

        // 注: 关闭误伤(m_bFriendlyFire)在塔被增强/刷新/开关切换时写一次即可,
        // 游戏运行中不会改动这个值, 所以这里不用每帧处理。

        // 把本帧对 data 的改动写回列表
        g_hSentries.SetArray(i, data);

        // ── 头顶塔跟随 ──
        if (data.hatUserId != 0)
        {
            UpdateHatSentry(i, iBase, fTurnSpeed, fTickInterval);
        }
    }
}

// ============================================================================
//  头顶塔位置跟随: 每帧把塔贴到所属角色头顶
//  (内部自己读/写列表, 避免和 OnGameFrame 的临时副本打架)
// ============================================================================
// 计算某座塔在"同一玩家头顶"里的层序号 (0 起), 用于分层堆叠。
// 层序号按底座实体索引升序确定, 保证每座塔都有一个稳定且唯一的高度,
// 避免多座塔叠在同一高度、炮口互相遮挡视线导致射不出子弹。
int GetHatLayerIndex(int listIdx, int iUserId)
{
    SentryData myData;
    g_hSentries.GetArray(listIdx, myData);
    int iMyBase = EntRefToEntIndex(myData.baseRef);

    int iLayer = 0;
    for (int i = 0; i < g_hSentries.Length; i++)
    {
        SentryData d;
        g_hSentries.GetArray(i, d);
        if (d.hatUserId != iUserId)
            continue;
        int iBase = EntRefToEntIndex(d.baseRef);
        if (iBase == INVALID_ENT_REFERENCE || !IsValidEntity(iBase))
            continue;
        if (iBase < iMyBase)
            iLayer++;
    }
    return iLayer;
}

void UpdateHatSentry(int listIdx, int iBase, float fTurnSpeed, float fTickInterval)
{
    SentryData data;
    g_hSentries.GetArray(listIdx, data);

    int iClient = GetClientOfUserId(data.hatUserId);
    if (iClient <= 0 || !IsClientInGame(iClient))
    {
        ClearHatState(listIdx, data, iBase);   // 玩家不在了, 取消头顶塔
        return;
    }

    // 找到 (或重新找到) 这个玩家控制的角色实体
    int iMarine = EntRefToEntIndex(data.hatMarineRef);
    if (iMarine == INVALID_ENT_REFERENCE || !IsValidEntity(iMarine))
    {
        iMarine = GetPlayerMarine(iClient);
        if (iMarine > 0)
        {
            data.hatMarineRef = EntIndexToEntRef(iMarine);
            g_hSentries.SetArray(listIdx, data);
        }
    }

    if (iMarine <= 0 || !IsValidEntity(iMarine))
        return;   // 角色还没部署, 本帧不动

    // 角色死亡则取消头顶塔
    if (GetEntProp(iMarine, Prop_Data, "m_iHealth") <= 0)
    {
        ClearHatState(listIdx, data, iBase);
        return;
    }

    // 拿角色位置, 把塔放到头顶上方
    float fOrigin[3], fAngles[3];
    GetEntPropVector(iMarine, Prop_Send, "m_vecOrigin", fOrigin);   // 必须是 Send, Data 读出来是占位值
    // 同一玩家头顶多座塔时按层序号逐层往上叠 (第一座 +80, 之后每座 +层间距),
    // 避免叠在同一高度、炮口互相遮挡视线导致射不出子弹
    fOrigin[2] += 80.0 + GetHatLayerIndex(listIdx, data.hatUserId) * g_cvHatLayerSpace.FloatValue;

    // 塔朝向跟随玩家视角前方, 加自定义偏移
    float fEyeAngles[3];
    GetClientEyeAngles(iClient, fEyeAngles);
    GetEntPropVector(iMarine, Prop_Data, "m_angRotation", fAngles);

    float fTargetYaw = fEyeAngles[1] + data.hatYawOffset;

    if (fTurnSpeed <= 0.0)
    {
        // 转向速度为 0 = 瞬间对准
        fAngles[1] = fTargetYaw;
    }
    else
    {
        // 把角度差规范到 -180~180 之间
        float fDelta = fTargetYaw - fAngles[1];
        while (fDelta > 180.0)  fDelta -= 360.0;
        while (fDelta < -180.0) fDelta += 360.0;

        // 每帧最多转 fTurnSpeed * 帧时长, 实现平滑转向
        float fMaxTurn = fTurnSpeed * fTickInterval;
        if (fDelta > fMaxTurn)       fDelta = fMaxTurn;
        else if (fDelta < -fMaxTurn) fDelta = -fMaxTurn;
        fAngles[1] += fDelta;
    }
    fAngles[0] = 0.0;

    // 每帧确保脱离物理模拟, 避免物理引擎把位置回拉造成滞后
    if (GetEntityMoveType(iBase) != MOVETYPE_NONE)
        SetEntityMoveType(iBase, MOVETYPE_NONE);

    // 把塔传送(移动)到计算好的位置和朝向
    TeleportEntity(iBase, fOrigin, fAngles, NULL_VECTOR);
}

// ============================================================================
//  取消头顶塔: 恢复碰撞等设置, 清掉头顶归属标记
// ============================================================================
void ClearHatState(int listIdx, SentryData data, int iBase)
{
    // 恢复底座本来的碰撞设置和移动类型
    if (g_offBaseCollisionGrp >= 0 && IsValidEntity(iBase))
        SetEntProp(iBase, Prop_Send, "m_CollisionGroup", data.origCollision);
    if (data.origMoveType != MOVETYPE_NONE)
        SetEntityMoveType(iBase, data.origMoveType);

    // 恢复炮口的碰撞设置
    int iTop = EntRefToEntIndex(data.topRef);
    if (iTop > 0 && IsValidEntity(iTop))
        SetEntProp(iTop, Prop_Send, "m_CollisionGroup", 0);

    data.hatUserId    = 0;
    data.hatMarineRef = 0;
    data.hatYawOffset = 0.0;
    g_hSentries.SetArray(listIdx, data);
}

// ============================================================================
//  塔类型编号 → 中文名
// ============================================================================
void GetSentryTypeName(int iGunType, char[] sName, int iLen)
{
    switch (iGunType)
    {
        case 0: strcopy(sName, iLen, "哨戒枪");
        case 1: strcopy(sName, iLen, "哨戒炮");
        case 2: strcopy(sName, iLen, "喷火型");
        case 3: strcopy(sName, iLen, "冰冻型");
        case 4: strcopy(sName, iLen, "电磁型");
        default: Format(sName, iLen, "未知(%d)", iGunType);
    }
}

// ============================================================================
//  各类型哨戒塔的"自然满弹药量" (与玩家自带/地图默认塔一致, 取自官方 FGD)
//  用作弹药增强的固定基准, 避免拿"已被增强过的当前弹药"再乘倍率导致越叠越高。
// ============================================================================
int GetSentryMaxAmmo(int iGunType)
{
    switch (iGunType)
    {
        case 0: return 450;    // 哨戒枪 (机枪)
        case 1: return 40;     // 哨戒炮 (榴弹炮)
        case 2: return 1200;   // 喷火型
        case 3: return 800;    // 冰冻型
        case 4: return 300;    // 电磁型
    }
    return 0;
}

// ============================================================================
//  通过底座找它的炮口
//  底座上有个"指向炮口"的句柄属性: 有炮口就直接返回它;
//  句柄为空说明塔还没组装完, 直接返回 -1。
//  下面的按类名逐个找只是在句柄属性不可用时的兜底 (正常用不到)。
// ============================================================================
int FindSentryTop(int iBase)
{
    if (!IsValidEntity(iBase))
        return -1;

    // 主路径: 读底座上的炮口句柄 (快, 一次读到位)
    if (g_offBaseSentryTop < 0)
        g_offBaseSentryTop = FindDataMapInfo(iBase, "m_hSentryTop");

    if (g_offBaseSentryTop >= 0)
    {
        int iTop = GetEntDataEnt2(iBase, g_offBaseSentryTop);
        if (iTop > 0 && IsValidEntity(iTop))
            return iTop;
        return -1;   // 句柄为空 = 还没组装出炮口
    }

    // 兜底: 遍历所有炮口实体, 看谁的"底座句柄"指向当前底座
    char sTopClasses[][] = {
        "asw_sentry_top_machinegun",
        "asw_sentry_top_cannon",
        "asw_sentry_top_flamer",
        "asw_sentry_top_icer",
        "asw_sentry_top_railgun"
    };

    for (int t = 0; t < sizeof(sTopClasses); t++)
    {
        int entity = -1;
        while ((entity = FindEntityByClassname(entity, sTopClasses[t])) != -1)
        {
            int iMyBase = GetEntPropEnt(entity, Prop_Data, "m_hSentryBase");
            if (iMyBase == iBase)
                return entity;
        }
    }
    return -1;
}

// ============================================================================
//  按底座实体索引, 在记录列表里找它对应的位置 (找不到返回 -1)
// ============================================================================
int FindSentryByEntIndex(int iBase)
{
    if (iBase <= 0)
        return -1;

    int ref = EntIndexToEntRef(iBase);
    SentryData data;
    for (int i = 0; i < g_hSentries.Length; i++)
    {
        g_hSentries.GetArray(i, data);
        if (data.baseRef == ref)
            return i;
    }
    return -1;
}

// ============================================================================
//  找某个玩家当前控制的角色实体
//  依次尝试三种办法, 拿到有效角色就返回:
//   1. 玩家身上的"正在操控"句柄 (网络属性)
//   2. 同上 (数据属性)
//   3. 遍历所有角色, 看谁的"操控者"是这个玩家
// ============================================================================
int GetPlayerMarine(int iClient)
{
    if (iClient <= 0 || !IsClientInGame(iClient))
        return -1;

    // 办法1: m_hInhabiting 网络属性
    char sNetClass[64];
    if (GetEntityNetClass(iClient, sNetClass, sizeof(sNetClass)))
    {
        if (FindSendPropInfo(sNetClass, "m_hInhabiting") != -1)
        {
            int iMarine = GetEntPropEnt(iClient, Prop_Send, "m_hInhabiting");
            if (iMarine > 0 && IsValidEntity(iMarine))
                return iMarine;
        }
    }

    // 办法2: m_hInhabiting 数据属性
    if (FindDataMapInfo(iClient, "m_hInhabiting") != -1)
    {
        int iMarine = GetEntPropEnt(iClient, Prop_Data, "m_hInhabiting");
        if (iMarine > 0 && IsValidEntity(iMarine))
            return iMarine;
    }

    // 办法3: 遍历角色, 匹配操控者
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "asw_marine")) != -1)
    {
        int iCommander = -1;
        if (FindDataMapInfo(entity, "m_hCommander") != -1)
            iCommander = GetEntPropEnt(entity, Prop_Data, "m_hCommander");

        if (iCommander <= 0)
        {
            if (GetEntityNetClass(entity, sNetClass, sizeof(sNetClass))
                && FindSendPropInfo(sNetClass, "m_hCommander") != -1)
                iCommander = GetEntPropEnt(entity, Prop_Send, "m_hCommander");
        }

        if (iCommander == iClient)
            return entity;
    }

    return -1;
}

// ============================================================================
//  倍率类 ConVar 变化时: 把所有塔按新倍率重新增强一遍
// ============================================================================
void OnMultCvarChanged(ConVar cv, const char[] oldValue, const char[] newValue)
{
    if (!g_cvEnabled.BoolValue || g_hSentries.Length == 0)
        return;

    SentryData data;
    for (int i = 0; i < g_hSentries.Length; i++)
    {
        g_hSentries.GetArray(i, data);
        int iBase = EntRefToEntIndex(data.baseRef);
        if (iBase == INVALID_ENT_REFERENCE || !IsValidEntity(iBase))
            continue;

        ReapplyEnhance(iBase, data);   // 底座属性 (生命/弹药)

        int iTop = EntRefToEntIndex(data.topRef);
        if (iTop != INVALID_ENT_REFERENCE && IsValidEntity(iTop))
        {
            ApplyTopEnhancements(data, iTop);   // 炮口属性 (射程/禁伤)
            g_hSentries.SetArray(i, data);      // 写回可能新记录的初始值
        }
    }
}

// ============================================================================
//  子弹伤害倍率: 应用到官方伤害覆盖 ConVar (均带 FCVAR_CHEAT)
//  官方覆盖是"固定值"而非倍率, 所以这里用 基础伤害 x 倍率 算出目标值写入。
//  倍率<=1.0 时还原为 0 (0=官方不覆盖, 使用引擎默认伤害)。
//  这些 ConVar 是全局的, 设一次对所有同类塔生效, 无需每帧重复。
// ============================================================================
void ApplyDamageOverrides()
{
    float fMult = g_cvDamageMult.FloatValue;

    SetSentryDamageOverride("asw_sentry_top_machinegun_dmg_override", SENTRY_DMG_MACHINEGUN, fMult);
    SetSentryDamageOverride("asw_sentry_top_cannon_dmg_override",     SENTRY_DMG_CANNON,     fMult);
    SetSentryDamageOverride("asw_sentry_top_flamer_dmg_override",     SENTRY_DMG_FLAMER,     fMult);
}

// 写单个官方伤害覆盖 ConVar: 摘掉 FCVAR_CHEAT 后按 基础*倍率 赋值 (倍率<=1 归零还原)
void SetSentryDamageOverride(const char[] sCvar, float fBase, float fMult)
{
    ConVar cv = FindConVar(sCvar);
    if (cv == null)
        return;

    // 官方覆盖 ConVar 带 FCVAR_CHEAT, sv_cheats=0 时插件改不动, 先摘掉该标志
    int iFlags = cv.Flags;
    if (iFlags & FCVAR_CHEAT)
        cv.Flags = iFlags & ~FCVAR_CHEAT;

    float fDamage = (fMult > 1.0) ? (fBase * fMult) : 0.0;
    cv.FloatValue = fDamage;
}

// 伤害倍率 ConVar 变化时自动重新应用
void OnDamageMultCvarChanged(ConVar cv, const char[] oldValue, const char[] newValue)
{
    ApplyDamageOverrides();
}

// ============================================================================
//  无敌开关变化时: 切换所有塔的"是否可被打"
// ============================================================================
void OnInvulnCvarChanged(ConVar cv, const char[] oldValue, const char[] newValue)
{
    if (g_hSentries.Length == 0)
        return;

    bool bInvuln = g_cvInvulnerable.BoolValue;
    SentryData data;
    for (int i = 0; i < g_hSentries.Length; i++)
    {
        g_hSentries.GetArray(i, data);
        int iBase = EntRefToEntIndex(data.baseRef);
        if (iBase == INVALID_ENT_REFERENCE || !IsValidEntity(iBase))
            continue;

        if (g_offBaseTakedamage >= 0)
        {
            if (bInvuln)
                SetEntProp(iBase, Prop_Data, "m_takedamage", 0);
            else
                SetEntProp(iBase, Prop_Data, "m_takedamage", data.origTakedamage);
        }
    }
}

// ============================================================================
//  禁伤开关变化时: 切换所有塔炮口的"是否误伤队友"
// ============================================================================
void OnNoDamageCvarChanged(ConVar cv, const char[] oldValue, const char[] newValue)
{
    if (g_hSentries.Length == 0)
        return;

    bool bNoDmg = g_cvNoPlayerDamage.BoolValue;
    SentryData data;
    for (int i = 0; i < g_hSentries.Length; i++)
    {
        g_hSentries.GetArray(i, data);
        int iBase = EntRefToEntIndex(data.baseRef);
        if (iBase == INVALID_ENT_REFERENCE || !IsValidEntity(iBase))
            continue;

        int iTop = EntRefToEntIndex(data.topRef);
        if (iTop == INVALID_ENT_REFERENCE || !IsValidEntity(iTop))
            continue;   // 炮口还没出现, 等它出现时会自动应用

        if (g_offTopFriendlyFire < 0)
            CacheTopPropOffsets(iTop);
        if (g_offTopFriendlyFire < 0)
            continue;

        if (bNoDmg)
        {
            SetEntProp(iTop, Prop_Data, "m_bFriendlyFire", 0);
        }
        else
        {
            SetEntProp(iTop, Prop_Data, "m_bFriendlyFire", data.origFriendlyFire > 0 ? 1 : 0);
        }
    }
}

// ============================================================================
//  按初始值重新套用生命/弹药倍率 (倍率 1.0 时等于还原成原值)
// ============================================================================
void ReapplyEnhance(int iBase, SentryData data)
{
    float fHealthMult = g_cvHealthMult.FloatValue;
    float fAmmoMult   = g_cvAmmoMult.FloatValue;

    if (data.origMaxHealth > 0)
    {
        int iNewHealth = RoundToFloor(float(data.origMaxHealth) * fHealthMult);
        SetEntProp(iBase, Prop_Data, "m_iMaxHealth", iNewHealth);
        SetEntProp(iBase, Prop_Data, "m_iHealth", iNewHealth);
    }

    if (data.origAmmo > 0)
    {
        int iNewAmmo = RoundToFloor(float(data.origAmmo) * fAmmoMult);
        SetEntProp(iBase, Prop_Data, "m_iAmmo", iNewAmmo);
        // 同步放大最大弹药, 让 HUD 弹药条按增强后的上限递减, 否则会一直显示满格
        if (g_offBaseMaxAmmo >= 0)
            SetEntData(iBase, g_offBaseMaxAmmo, iNewAmmo);
    }
}

// ============================================================================
//  统计某玩家当前头顶上的哨戒塔数量 (按 userid 区分)
// ============================================================================
int CountPlayerHatSentries(int iUserId)
{
    if (iUserId <= 0)
        return 0;

    int count = 0;
    SentryData data;
    for (int i = 0; i < g_hSentries.Length; i++)
    {
        g_hSentries.GetArray(i, data);
        if (data.hatUserId != iUserId)
            continue;

        int iBase = EntRefToEntIndex(data.baseRef);
        if (iBase == INVALID_ENT_REFERENCE || !IsValidEntity(iBase))
            continue;
        count++;
    }
    return count;
}

// ============================================================================
//  命令: 把最近的哨戒塔放到自己头顶
// ============================================================================
public Action Command_SentryHat(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
    {
        ReplyToCommand(client, "你必须存活才能使用此命令");
        return Plugin_Handled;
    }

    // 头顶塔数量上限: 每个玩家最多 SENTRY_HAT_LIMIT 座 (写死, 不给 ConVar)
    if (CountPlayerHatSentries(GetClientUserId(client)) >= SENTRY_HAT_LIMIT)
    {
        ReplyToCommand(client, "头顶哨戒塔已达上限(%d 座), 请先用 sm_hat_off 取消", SENTRY_HAT_LIMIT);
        return Plugin_Handled;
    }

    // 可选参数: 塔的朝向偏移 (度数)
    float fYawOffset = 0.0;
    if (args >= 1)
    {
        char sArg[16];
        GetCmdArg(1, sArg, sizeof(sArg));
        fYawOffset = StringToFloat(sArg);
    }

    // 找离自己最近、且还没被放到别人头顶的塔
    int iBase = FindNearestSentryBase(client);
    if (iBase == -1)
    {
        ReplyToCommand(client, "附近没有可用的哨戒塔");
        return Plugin_Handled;
    }

    // 拿自己控制的角色
    int iMarine = GetPlayerMarine(client);
    if (iMarine <= 0)
    {
        ReplyToCommand(client, "未找到你控制的 marine，请先部署角色");
        return Plugin_Handled;
    }

    // 确保这座塔有增强记录 (没有就先建)
    int idx = FindSentryByEntIndex(iBase);
    if (idx < 0)
    {
        EnhanceSentry(iBase, false);
        idx = FindSentryByEntIndex(iBase);
    }
    if (idx < 0)
    {
        ReplyToCommand(client, "哨戒塔记录创建失败");
        return Plugin_Handled;
    }

    SentryData data;
    g_hSentries.GetArray(idx, data);

    // 关闭碰撞 + 脱离物理模拟, 消除头顶跟随时的滞后
    if (g_offBaseCollisionGrp >= 0)
        SetEntProp(iBase, Prop_Send, "m_CollisionGroup", 1);  // 1 = 不参与碰撞
    SetEntityMoveType(iBase, MOVETYPE_NONE);
    int iTop = EntRefToEntIndex(data.topRef);
    if (iTop > 0 && IsValidEntity(iTop))
    {
        SetEntProp(iTop, Prop_Send, "m_CollisionGroup", 1);
        SetEntityMoveType(iTop, MOVETYPE_NONE);
    }

    // 记录这座塔归这个玩家 (按 userid 区分, 多人互不干扰)
    data.hatUserId    = GetClientUserId(client);
    data.hatMarineRef = EntIndexToEntRef(iMarine);
    data.hatYawOffset = fYawOffset;
    g_hSentries.SetArray(idx, data);

    // 先把塔传送到头顶 (朝向前方, 之后每帧跟随)
    float fOrigin[3], fAngles[3], fEyeAngles[3];
    GetEntPropVector(iMarine, Prop_Send, "m_vecOrigin", fOrigin);   // 必须是 Send, Data 读出来是占位值
    // 与 UpdateHatSentry 一致的分层高度 (此时 data.hatUserId 已写入)
    fOrigin[2] += 80.0 + GetHatLayerIndex(idx, GetClientUserId(client)) * g_cvHatLayerSpace.FloatValue;
    GetClientEyeAngles(client, fEyeAngles);
    fAngles[0] = 0.0;
    fAngles[1] = fEyeAngles[1] + fYawOffset;   // 前方 + 自定义偏移
    fAngles[2] = 0.0;
    TeleportEntity(iBase, fOrigin, fAngles, NULL_VECTOR);

    char sTypeName[32];
    GetSentryTypeName(data.gunType, sTypeName, sizeof(sTypeName));
    ReplyToCommand(client, "已把[%s]放到你头顶", sTypeName);
    return Plugin_Handled;
}

// ============================================================================
//  命令 (管理员): 取消所有玩家的头顶塔
// ============================================================================
public Action Command_SentryHatOff(int client, int args)
{
    int iCount = 0;
    for (int i = 0; i < g_hSentries.Length; i++)
    {
        SentryData data;
        g_hSentries.GetArray(i, data);
        if (data.hatUserId == 0)
            continue;

        int iBase = EntRefToEntIndex(data.baseRef);
        if (iBase != INVALID_ENT_REFERENCE && IsValidEntity(iBase))
            ClearHatState(i, data, iBase);
        iCount++;
    }
    ReplyToCommand(client, "已取消 %d 个头顶哨戒塔", iCount);
    return Plugin_Handled;
}

// ============================================================================
//  命令 (玩家): 把最近的塔放自己头顶 (需管理员开启该功能)
// ============================================================================
public Action Command_HatPublic(int client, int args)
{
    if (!g_cvHatPublic.BoolValue)
    {
        ReplyToCommand(client, "头顶哨戒塔功能未对玩家开放");
        return Plugin_Handled;
    }
    return Command_SentryHat(client, args);
}

// 命令 (玩家): 取消自己的头顶塔 (只能取消自己的)
public Action Command_HatOffPublic(int client, int args)
{
    if (!g_cvHatPublic.BoolValue)
    {
        ReplyToCommand(client, "头顶哨戒塔功能未对玩家开放");
        return Plugin_Handled;
    }

    int iUserId = GetClientUserId(client);
    int iCount = 0;
    for (int i = 0; i < g_hSentries.Length; i++)
    {
        SentryData data;
        g_hSentries.GetArray(i, data);
        if (data.hatUserId != iUserId)
            continue;

        int iBase = EntRefToEntIndex(data.baseRef);
        if (iBase != INVALID_ENT_REFERENCE && IsValidEntity(iBase))
            ClearHatState(i, data, iBase);
        iCount++;
    }
    ReplyToCommand(client, "已取消你的 %d 个头顶哨戒塔", iCount);
    return Plugin_Handled;
}

// ============================================================================
//  命令 (管理员): 一键满配增强所有哨戒塔
//  改 ConVar 触发 changehook; 再强制扫描增强场上所有塔兜底(防未记录塔漏掉)
// ============================================================================
public Action Command_SentryBoost(int client, int args)
{
    if (client <= 0) return Plugin_Handled;   // 只接受游戏内/控制台管理员

    g_cvEnabled.SetInt(1);
    g_cvHealthMult.SetFloat(3.0);
    g_cvFireRateMult.SetFloat(20.0);
    g_cvRangeMult.SetFloat(1.0);
    g_cvAmmoMult.SetFloat(50.0);
    g_cvDamageMult.SetFloat(5.0);
    g_cvInvulnerable.SetInt(1);
    g_cvNoPlayerDamage.SetInt(1);
    g_cvDebug.SetInt(1);

    // 设完倍率必须主动扫描增强场上所有塔:
    // 倍率 changehook 只作用于已记录(g_hSentries)的塔, 若塔之前没被
    // 增强逻辑捕获(增强时机错过等), 光改 convar 不会触及它们。这里强制
    // 把当前所有 asw_sentry_base 逐一增强/补录, 最大化保证即刻生效。
    int count = 0;
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "asw_sentry_base")) != -1)
    {
        EnhanceSentry(entity, true);
        count++;
    }

    ReplyToCommand(client, "已一键开启哨戒塔满配增强并强化 %d 座塔 (生命x3 射速x20 射程x1 弹药x50 伤害x5 无敌 禁伤 调试开)", count);
    return Plugin_Handled;
}

// ============================================================================
//  命令 (管理员): 一键还原增强倍率到默认档 (1.0 即还原原始值)
// ============================================================================
public Action Command_SentryUnboost(int client, int args)
{
    if (client <= 0) return Plugin_Handled;

    g_cvHealthMult.SetFloat(1.0);
    g_cvFireRateMult.SetFloat(1.0);
    g_cvRangeMult.SetFloat(1.0);
    g_cvAmmoMult.SetFloat(1.0);
    g_cvDamageMult.SetFloat(1.0);
    g_cvInvulnerable.SetInt(0);
    g_cvNoPlayerDamage.SetInt(1);

    ReplyToCommand(client, "已还原哨戒塔增强倍率到默认档");
    return Plugin_Handled;
}

// ============================================================================
//  命令 (管理员): 在玩家身边掉落一座哨戒枪拾取箱 (默认炮, 可选参数指定类型)
//    0=机枪 1=炮 2=喷火 3=冰冻
//  拾取后玩家自行部署, 塔组装完成会被 OnEntityCreated 自动增强
// ============================================================================
public Action Command_SentryDrop(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
    {
        ReplyToCommand(client, "你必须存活才能使用此命令");
        return Plugin_Handled;
    }

    int iMarine = GetPlayerMarine(client);
    if (iMarine <= 0)
    {
        ReplyToCommand(client, "未找到你控制的 marine");
        return Plugin_Handled;
    }

    // 掉落数量上限: 场上未被拾取的哨戒枪拾取箱已满则拒绝 (0=不限制)
    int iLimit = g_cvDropLimit.IntValue;
    if (iLimit > 0)
    {
        int iDropped = CountSentryPickups();
        if (iDropped >= iLimit)
        {
            ReplyToCommand(client, "场上哨戒枪拾取箱已达上限(%d个), 请先拾取或部署后再掉落", iLimit);
            return Plugin_Handled;
        }
    }

    // 类型: 默认炮(1), 可选参数覆盖
    int iGunType = 1;
    if (args >= 1)
    {
        char sArg[8];
        GetCmdArg(1, sArg, sizeof(sArg));
        iGunType = StringToInt(sArg);
    }
    if (iGunType < 0 || iGunType > 3)
        iGunType = 1;

    // 类型 → 拾取箱类名 (炮为默认)
    char sClass[32];
    if      (iGunType == 0) strcopy(sClass, sizeof(sClass), "asw_pickup_sentry");
    else if (iGunType == 2) strcopy(sClass, sizeof(sClass), "asw_pickup_sentry_flamer");
    else if (iGunType == 3) strcopy(sClass, sizeof(sClass), "asw_pickup_sentry_freeze");
    else                    strcopy(sClass, sizeof(sClass), "asw_pickup_sentry_cannon");

    // 玩家位置 (Send 读真实世界坐标, Data 读出来是占位值)
    float fPos[3], fAng[3];
    GetEntPropVector(iMarine, Prop_Send, "m_vecOrigin", fPos);

    // 沿玩家朝向向前偏移 60 单位, 略抬高让它自然落地
    GetClientEyeAngles(client, fAng);
    float fYaw = DegToRad(fAng[1]);
    fPos[0] += Cosine(fYaw) * 60.0;
    fPos[1] += Sine(fYaw) * 60.0;
    fPos[2] += 20.0;

    // 创建拾取箱实体 (CItem 派生, spawn 后自动落地)
    int iPickup = CreateEntityByName(sClass);
    if (iPickup == -1)
    {
        ReplyToCommand(client, "创建哨戒枪拾取箱失败");
        return Plugin_Handled;
    }

    // 关键: 拾取箱默认近乎空弹 (BulletsInGun=1), 拾取后部署会提示"弹药耗尽"。
    // 这里按类型填入满弹药, 让掉落的塔和玩家自带的塔属性一致。
    char sAmmo[8];
    IntToString(GetSentryMaxAmmo(iGunType), sAmmo, sizeof(sAmmo));
    DispatchKeyValue(iPickup, "BulletsInGun", sAmmo);

    float fZeroAng[3];
    TeleportEntity(iPickup, fPos, fZeroAng, NULL_VECTOR);
    DispatchSpawn(iPickup);
    ActivateEntity(iPickup);

    char sTypeName[32];
    GetSentryTypeName(iGunType, sTypeName, sizeof(sTypeName));
    ReplyToCommand(client, "已在身边掉落一座[%s]哨戒枪箱, 拾取后自行部署组装", sTypeName);
    return Plugin_Handled;
}

// 命令 (玩家): 在身边掉落一座哨戒炮塔拾取箱 (需管理员开启该功能)
public Action Command_SentryDropPublic(int client, int args)
{
    if (!g_cvDropPublic.BoolValue)
    {
        ReplyToCommand(client, "哨戒炮塔掉落功能未对玩家开放");
        return Plugin_Handled;
    }
    return Command_SentryDrop(client, args);
}

// ============================================================================
//  一键满配: 补满地图上所有哨戒塔的生命值与弹药 (不改倍率)
//  生命: 直接补到当前最大生命 (m_iHealth = m_iMaxHealth)
//  弹药: 有记录用 记录基准 x 弹药倍率, 无记录用该型自然满弹药 x 弹药倍率;
//        同时同步最大弹药, 保证 HUD 弹药条显示正确
// ============================================================================
int RefillAllSentries()
{
    float fAmmoMult = g_cvAmmoMult.FloatValue;

    int count = 0;
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "asw_sentry_base")) != -1)
    {
        CacheBasePropOffsets(entity);   // 确保 GunType / MaxAmmo 偏移可用

        // 有增强记录就取记录基准, 保证补的量和增强后上限一致
        SentryData data;
        int idx = FindSentryByEntIndex(entity);
        if (idx >= 0)
            g_hSentries.GetArray(idx, data);

        // 生命补满
        int iMaxHp = GetEntProp(entity, Prop_Data, "m_iMaxHealth");
        if (iMaxHp > 0)
            SetEntProp(entity, Prop_Data, "m_iHealth", iMaxHp);

        // 弹药补满
        int iFullAmmo = 0;
        if (idx >= 0 && data.origAmmo > 0)
        {
            iFullAmmo = RoundToFloor(float(data.origAmmo) * fAmmoMult);
        }
        else if (g_offBaseGunType >= 0)
        {
            int iGunType = GetEntProp(entity, Prop_Data, "m_nGunType");
            iFullAmmo = RoundToFloor(float(GetSentryMaxAmmo(iGunType)) * fAmmoMult);
        }

        if (iFullAmmo > 0)
        {
            SetEntProp(entity, Prop_Data, "m_iAmmo", iFullAmmo);
            if (g_offBaseMaxAmmo >= 0)
                SetEntData(entity, g_offBaseMaxAmmo, iFullAmmo);
        }

        count++;
    }
    return count;
}

// ============================================================================
//  命令 (玩家): 一键补满所有哨戒塔的生命与弹药 (需管理员开启该功能)
//  供积分插件 /buy 5 (500 分) 转发调用
// ============================================================================
public Action Command_SentryRefillPublic(int client, int args)
{
    // 玩家命令需管理员开启; 管理员本人(游戏内或控制台)不受该开关限制
    bool bAdmin = (client <= 0) || ((GetUserFlagBits(client) & ADMFLAG_GENERIC) != 0);
    if (!bAdmin && !g_cvRefillPublic.BoolValue)
    {
        ReplyToCommand(client, "一键满配功能未对玩家开放");
        return Plugin_Handled;
    }
    if (!g_cvEnabled.BoolValue)
    {
        ReplyToCommand(client, "哨戒塔增强功能已禁用");
        return Plugin_Handled;
    }

    int count = RefillAllSentries();
    if (count <= 0)
    {
        // 地图上没有任何哨戒塔: 说明无法满配 (积分插件侧也会先查再扣分)
        ReplyToCommand(client, "地图上目前没有任何哨戒塔, 无法进行一键满配");
        return Plugin_Handled;
    }

    ReplyToCommand(client, "已一键补满 %d 座哨戒塔的生命与弹药", count);
    return Plugin_Handled;
}

// ============================================================================
//  统计场上未被拾取的哨戒枪拾取箱数量 (用于限制最多掉落数量)
//  只在掉落命令触发时执行一次, 不做每帧扫描。
// ============================================================================
int CountSentryPickups()
{
    static const char sPickupClasses[][] = {
        "asw_pickup_sentry",         // 哨戒枪
        "asw_pickup_sentry_cannon",  // 哨戒炮
        "asw_pickup_sentry_flamer",  // 喷火型
        "asw_pickup_sentry_freeze"   // 冰冻型
    };

    int count = 0;
    for (int c = 0; c < sizeof(sPickupClasses); c++)
    {
        int entity = -1;
        while ((entity = FindEntityByClassname(entity, sPickupClasses[c])) != -1)
            count++;
    }
    return count;
}

// ============================================================================
//  命令 (管理员): 重新增强地图里所有哨戒塔并补满弹药
// ============================================================================
public Action Command_RefreshSentries(int client, int args)
{
    if (!g_cvEnabled.BoolValue)
    {
        ReplyToCommand(client, "哨戒塔增强功能已禁用");
        return Plugin_Handled;
    }

    int count = 0;
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "asw_sentry_base")) != -1)
    {
        EnhanceSentry(entity, true);
        count++;
    }
    ReplyToCommand(client, "已重新增强 %d 个哨戒塔", count);
    return Plugin_Handled;
}

// ============================================================================
//  命令 (管理员): 在控制台列出所有哨戒塔状态
// ============================================================================
public Action Command_SentryStatus(int client, int args)
{
    PrintToConsole(client, "========== 哨戒塔状态 (v%s) ==========", PLUGIN_VERSION);
    PrintToConsole(client, "倍率: 生命x%.1f | 射速x%.1f | 射程x%.1f | 弹药x%.1f",
        g_cvHealthMult.FloatValue, g_cvFireRateMult.FloatValue,
        g_cvRangeMult.FloatValue, g_cvAmmoMult.FloatValue);
    PrintToConsole(client, "无敌: %s | 禁伤玩家: %s | 记录数: %d",
        g_cvInvulnerable.BoolValue ? "开" : "关",
        g_cvNoPlayerDamage.BoolValue ? "开" : "关",
        g_hSentries.Length);
    PrintToConsole(client, "------------------------------");

    int count = 0;
    SentryData data;
    for (int i = 0; i < g_hSentries.Length; i++)
    {
        g_hSentries.GetArray(i, data);
        int iBase = EntRefToEntIndex(data.baseRef);
        if (iBase == INVALID_ENT_REFERENCE || !IsValidEntity(iBase))
            continue;

        count++;
        char sTypeName[32];
        GetSentryTypeName(data.gunType, sTypeName, sizeof(sTypeName));

        int iHealth = GetEntProp(iBase, Prop_Data, "m_iHealth");
        int iMaxHp  = GetEntProp(iBase, Prop_Data, "m_iMaxHealth");
        int iAmmo   = GetEntProp(iBase, Prop_Data, "m_iAmmo");

        PrintToConsole(client, "[#%d %s] 生命: %d/%d | 弹药: %d | 头顶: %s",
            iBase, sTypeName, iHealth, iMaxHp, iAmmo,
            data.hatUserId != 0 ? "是" : "否");

        int iTop = EntRefToEntIndex(data.topRef);
        if (iTop > 0 && IsValidEntity(iTop))
        {
            float fRange = GetEntPropFloat(iTop, Prop_Data, "m_flShootRange");
            int iFF = (g_offTopFriendlyFire >= 0) ? GetEntProp(iTop, Prop_Data, "m_bFriendlyFire") : -1;
            PrintToConsole(client, "  [top #%d] 射程: %.0f (原始 %.0f) | 友军伤害: %s",
                iTop, fRange, data.origShootRange,
                iFF < 0 ? "未知" : (iFF != 0 ? "开" : "关"));
        }
        else
        {
            PrintToConsole(client, "  [top 未创建] 塔未组装, 组装完成后自动补全增强");
        }
    }

    if (count == 0)
        PrintToConsole(client, "当前没有哨戒塔");

    PrintToConsole(client, "==============================");
    return Plugin_Handled;
}

// ============================================================================
//  命令 (调试): 转储内部属性偏移和记录详情到控制台
// ============================================================================
public Action Command_SentryDump(int client, int args)
{
    PrintToConsole(client, "====== 属性偏移缓存 ======");
    PrintToConsole(client, "base (cached=%d): MaxHealth=%d Health=%d Ammo=%d GunType=%d SentryTop=%d Takedamage=%d Coll=%d",
        g_bBasePropsCached, g_offBaseMaxHealth, g_offBaseHealth, g_offBaseAmmo, g_offBaseGunType,
        g_offBaseSentryTop, g_offBaseTakedamage, g_offBaseCollisionGrp);
    PrintToConsole(client, "top  (cached=%d): ShootRange=%d NextFire=%d FriendlyFire=%d SentryBase=%d",
        g_bTopPropsCached, g_offTopShootRange, g_offTopNextFireTime, g_offTopFriendlyFire, g_offTopSentryBase);
    PrintToConsole(client, "m_flLastFireTime 原始偏移: %d (-2=定位失败, -1=未尝试)", g_offTopLastFireTime);
    PrintToConsole(client, "列表长度: %d", g_hSentries.Length);
    PrintToConsole(client, "------------------------------");

    SentryData data;
    for (int i = 0; i < g_hSentries.Length; i++)
    {
        g_hSentries.GetArray(i, data);
        int iBase = EntRefToEntIndex(data.baseRef);
        int iTop  = EntRefToEntIndex(data.topRef);

        char sTypeName[32];
        GetSentryTypeName(data.gunType, sTypeName, sizeof(sTypeName));

        PrintToConsole(client, "[%d] base=%d top=%d [%s] origHp=%d origAmmo=%d origRange=%.0f origFF=%d hatUid=%d",
            i, iBase, iTop, sTypeName, data.origMaxHealth, data.origAmmo,
            data.origShootRange, data.origFriendlyFire, data.hatUserId);
    }

    ReplyToCommand(client, "属性已转储到控制台");
    return Plugin_Handled;
}

// ============================================================================
//  命令 (调试): 转储当前玩家的实体属性到控制台
// ============================================================================
public Action Command_DumpPlayer(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "只能在游戏内使用");
        return Plugin_Handled;
    }

    PrintToConsole(client, "====== 玩家 #%d 属性 ======", client);
    PrintToConsole(client, "--- GetPlayerMarine 测试 ---");

    char sNetClass[64];
    if (GetEntityNetClass(client, sNetClass, sizeof(sNetClass)))
    {
        PrintToConsole(client, "玩家网络类: %s", sNetClass);
        PrintToConsole(client, "  m_hInhabiting Send=%d", FindSendPropInfo(sNetClass, "m_hInhabiting"));
    }
    PrintToConsole(client, "  m_hInhabiting Data=%d", FindDataMapInfo(client, "m_hInhabiting"));

    int iMarine = GetPlayerMarine(client);
    PrintToConsole(client, "  GetPlayerMarine(%d) = %d", client, iMarine);

    if (iMarine > 0)
    {
        char sMarineClass[64];
        GetEntityClassname(iMarine, sMarineClass, sizeof(sMarineClass));
        PrintToConsole(client, "  marine 类: %s", sMarineClass);

        float fOrigin[3];
        GetEntPropVector(iMarine, Prop_Send, "m_vecOrigin", fOrigin);
        PrintToConsole(client, "  marine 位置: %.1f %.1f %.1f", fOrigin[0], fOrigin[1], fOrigin[2]);
    }

    ReplyToCommand(client, "属性已转储到控制台");
    return Plugin_Handled;
}

// ============================================================================
//  找离玩家最近(且不超过距离上限)、还没被放到任何人头顶的哨戒塔底座
// ============================================================================
int FindNearestSentryBase(int iClient)
{
    float fClientPos[3];
    GetClientAbsOrigin(iClient, fClientPos);

    // AS:RD 的 marine 实体用 Prop_Data 读 m_vecOrigin 会得到占位值(0,0,-1),
    // 必须用 Prop_Send 读网络属性才是真实世界坐标; 读到占位值时再退回眼睛位置。
    int iMarine = GetPlayerMarine(iClient);
    if (iMarine > 0)
    {
        GetEntPropVector(iMarine, Prop_Send, "m_vecOrigin", fClientPos);
        if (fClientPos[0] == 0.0 && fClientPos[1] == 0.0)
            GetClientEyePosition(iClient, fClientPos);
    }

    int iBest = -1;
    float fBestDist = 999999.0;
    float fMaxDist = g_cvHatMaxDist.FloatValue;   // 0 = 不限制距离

    int iTotal = 0, iOccupied = 0, iTooFar = 0;
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "asw_sentry_base")) != -1)
    {
        iTotal++;

        // 跳过已经在别人头顶上的塔
        int idx = FindSentryByEntIndex(entity);
        if (idx >= 0)
        {
            SentryData data;
            g_hSentries.GetArray(idx, data);
            if (data.hatUserId != 0)
            {
                iOccupied++;
                continue;
            }
        }

        float fSentryPos[3];
        GetEntPropVector(entity, Prop_Data, "m_vecOrigin", fSentryPos);

        float fDist = GetVectorDistance(fClientPos, fSentryPos);

        // 太远的塔不算候选
        if (fMaxDist > 0.0 && fDist > fMaxDist)
        {
            iTooFar++;
            continue;
        }

        if (fDist < fBestDist)
        {
            fBestDist = fDist;
            iBest = entity;
        }
    }

    // 调试: 打印本次查找的详细结果, 便于定位"为何匹配不到"
    if (g_cvDebug.BoolValue)
    {
        int iMarineDbg = GetPlayerMarine(iClient);
        float vClientD[3], vClientS[3], vMarineD[3], vMarineS[3], vEye[3];
        GetEntPropVector(iClient, Prop_Data,  "m_vecOrigin", vClientD);
        GetEntPropVector(iClient, Prop_Send,  "m_vecOrigin", vClientS);
        GetEntPropVector(iMarineDbg, Prop_Data, "m_vecOrigin", vMarineD);
        GetEntPropVector(iMarineDbg, Prop_Send, "m_vecOrigin", vMarineS);
        GetClientEyePosition(iClient, vEye);

        PrintToServer("[哨戒塔] 玩家#%d client=(%.0f,%.0f,%.0f) send=(%.0f,%.0f,%.0f)",
            iClient, vClientD[0], vClientD[1], vClientD[2], vClientS[0], vClientS[1], vClientS[2]);
        PrintToServer("[哨戒塔] marine#%d data=(%.0f,%.0f,%.0f) send=(%.0f,%.0f,%.0f) eye=(%.0f,%.0f,%.0f)",
            iMarineDbg, vMarineD[0], vMarineD[1], vMarineD[2],
            vMarineS[0], vMarineS[1], vMarineS[2], vEye[0], vEye[1], vEye[2]);

        // 打印第一座塔的位置作对照
        int eTmp = -1; float vT[3]; int nT = 0;
        while ((eTmp = FindEntityByClassname(eTmp, "asw_sentry_base")) != -1 && nT < 1)
        {
            GetEntPropVector(eTmp, Prop_Data, "m_vecOrigin", vT);
            PrintToServer("[哨戒塔] 对比塔#%d base位置=(%.0f,%.0f,%.0f)", eTmp, vT[0], vT[1], vT[2]);
            nT++;
        }

        PrintToServer("[哨戒塔] 命令距离上限=%.0f 候选=%d 占用=%d 超距离=%d 最近=%.0f 命中#%d",
            fMaxDist, iTotal, iOccupied, iTooFar, fBestDist, iBest);
    }

    return iBest;
}
