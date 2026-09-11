/**
 * ============================================================================
 *  [AS:RD] 积分机制 (Points)
 *  版本 1.15.0  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ──────────────────────────────────────
 *  引入一套全队共享的积分经济:
 *    1. 击杀计分: 玩家击杀虫族获得积分, 按被杀虫族的实际最大血量计算
 *       (血量越高积分越多, 倍率见 sm_asrd_points_hp_scale, 最少 1 分)
 *    2. 积分购买: 玩家使用 sm_nukepub / sm_betraypub / sm_power_up|down 时,
 *       先扣除积分再放行给原插件执行功能; 聊天框用 /buy 4 <编号> 购买强化
 *       哨戒塔 (0机枪 1炮塔, 喷火/冰冻暂不支持), /buy 5 一键满配全场哨戒塔
 *    3. 积分显示: 屏幕左上方常驻显示总积分, 每 0.5 秒刷新, 击杀/消费即时更新
 *    4. 进服通知: 玩家连上服务器后, 延迟几秒在聊天框私聊发送 /buy 购买说明
 *       (避开加载画面; 开关见 sm_asrd_points_join_help)
 *
 *  ── 积分池规则 ─────────────────────────────────────────
 *    - 全队共享一个积分池: 任何玩家击杀都加分, 任何玩家都能消费
 *    - 换图后积分清零 (一局一结算)
 *    - 管理员与普通玩家一致, 使用玩家命令同样扣分
 *
 *  ── 购买接入方式 (零修改现有插件) ─────────────────────
 *  本插件用 AddCommandListener 拦截玩家的功能命令, 扣分后返回
 *  Plugin_Continue 放行给原插件执行:
 *      sm_nukepub    → 扣 sm_asrd_points_nuke_cost   (需原插件 sm_asrd_nuke_public 1)
 *      sm_betraypub  → 扣 sm_asrd_points_betray_cost (需原插件 sm_asrd_betray_public 1)
 *      sm_power_up   → 扣 sm_asrd_points_power_cost  (需原插件 sm_asrd_power_public 1)
 *      sm_power_down → 扣 sm_asrd_points_power_cost  (同上)
 *      sm_power_reset→ 免费 (只恢复默认, 不收积分)
 *      sm_sentrydrop → 扣 sm_asrd_points_sentry_cost (需哨戒塔插件 sm_asrd_sentry_drop_public 1)
 *      sm_sentry_refill → 扣 sm_asrd_points_refill_cost (需 sm_asrd_sentry_refill_public 1)
 *    价格设为 0 = 该功能不设积分门槛, 维持原插件自己的开关行为。
 *    管理员命令 (sm_nuke / sm_betray / sm_power_set / sm_sentry_*) 不拦截, 不受积分影响。
 *
 *    注意事项:
 *    - 玩家命令能否真正生效仍由原插件的 public 开关决定, 购买前会先检查
 *      对应开关, 未开放/已禁用/插件未加载时不会扣分。
 *    - 极端情况 (如核弹已在倒计时、场上无陆战队员) 可能扣分但功能未触发,
 *      积分不退还 (积分插件无法读取原插件的内部状态)。
 *    - sm_betraypub 的虫种参数会在扣分前预校验, 打错虫种名不会白扣积分。
 *
 *  ── 击杀归属判定 ───────────────────────────────────────
 *    - 伤害回调挂在虫族 victim 侧 (SDKHook_OnTakeDamage, 与扫描机插件同模式)
 *    - 致命一击的归属按攻击者解析: 玩家客户端 / 陆战队员实体(查 m_Commander)
 *      / 被玩家附身的虫族(查 m_Commander) / 哨戒塔塔顶炮台(反查塔底座
 *      m_hSentryBase -> 部署者 m_hDeployer -> 操控者), 其它来源 (核弹/
 *      扫描机/虫族互杀) 不计分
 *    - 哨戒塔: 炮弹/喷火/冰冻塔引擎本就填部署者 marine (原本就计分); 机枪塔
 *      走 hitscan 子弹, 引擎只填塔顶实体自身, 由本插件补一路反查使其一并计分。
 *      地图预置的塔没有部署者, 一律不计分
 *    - 友军虫 (targetname=asrd_betray_swarm, 含玩家附身虫) 不计分, 防刷分
 *
 *  ── 命令 ────────────────────────────────────────────────
 *   /buy [1] [2]      玩家: 聊天框购买 (唯一扣积分入口, 无控制台命令)
 *                        /buy = 显示格式; /buy 1=属性强化+1; /buy 2=核弹;
 *                        /buy 3 [1-6]=叛变虫群 (/buy 3 无选项=drone×10)
 *                        (强化已满级时 /buy 1 转为加血: 血量<800 花
 *                        power_cost 恢复 200 血, 封顶最大血量)
 *                        /buy 4 <编号>=强化哨戒塔箱 (0机枪 1炮塔,
 *                        喷火/冰冻暂不支持); /buy 5=一键满配全场哨戒塔
 *                        (地图上没有哨戒塔时不允许购买, 不扣分)
 *   /1 /2 /3          玩家: 聊天框快捷购买 强化等级 / 核弹 / 叛变虫群(默认drone)
 *   /nukepub /betraypub /power_up /power_down
 *                     玩家: 聊天框直接调用原功能命令同样扣积分
 *   注: 无任何 sm_points* 控制台命令; 控制台调用原功能命令不扣积分
 *
 *  ── 常用 ConVar (自动生成 cfg/sourcemod/asrd_points.cfg) ──
 *   sm_asrd_points_enabled    总开关 (0=关 1=开, 默认 1)
 *   sm_asrd_points_start      每局初始积分 (默认 1000; 开局/换图时重置)
 *   sm_asrd_points_hp_scale   击杀积分 = 虫族最大血量 x 倍率 (默认 0.05, 最少 1 分)
 *   sm_asrd_points_nuke_cost  核弹价格 (默认 300, 0=不设门槛)
 *   sm_asrd_points_betray_cost 叛变虫群价格 (默认 100, 0=不设门槛)
 *   sm_asrd_points_power_cost 强化等级价格 (默认 400, 0=不设门槛)
 *   sm_asrd_points_sentry_cost 强化哨戒塔价格 (默认 300, 0=不设门槛)
 *   sm_asrd_points_refill_cost 全场哨戒塔满配价格 (默认 500, 0=不设门槛)
 *   sm_asrd_points_hud        积分显示开关 (0=关 1=开, 默认 1)
 *   sm_asrd_points_hud_channel HUD 通道 (默认 6, 避开 4=哨戒塔/X-33, 5=核弹)
 *   sm_asrd_points_hud_x      横向位置 (默认 0.01 左上角; -1=居中)
 *   sm_asrd_points_hud_y      纵向位置 (默认 0.02)
 *   sm_asrd_points_hud_alpha  文字透明度 (默认 170 半透明; 0=全透明 255=不透明)
 *   sm_asrd_points_debug      调试输出 (默认 0)
 *   sm_asrd_points_advert     聊天公告使用说明开关 (默认 1)
 *   sm_asrd_points_advert_interval 公告间隔秒数 (默认 30)
 *   sm_asrd_points_join_help  玩家进服后私聊通知购买说明 (默认 1; 0=不通知)
 *
 *  依赖: SourceMod 1.11+ (核心 + sdktools + sdkhooks)
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <events>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] Points"
#define PLUGIN_VERSION "1.15.0"

// ─── /buy 4 强化哨戒塔可选编号 (哨戒塔插件 sm_sentrydrop 的塔类型; 2喷火/3冰冻暂不支持) ─
#define BUY_SENTRY_VARIANTS_MAX 1   // 当前支持的最高塔编号 (0=机枪 1=炮塔)

// ─── HUD 显示 (左上角, 与 4=哨戒塔/X-33、5=核弹 错开) ─────
#define HUD_CHANNEL     6
#define HUD_X           0.01
#define HUD_Y           0.02
#define HUD_HOLD        1.2
#define HUD_REFRESH     0.5

// ─── 进服通知: 玩家连上后延迟这么久再发购买说明 (等加载/入队完成) ─
#define JOIN_HELP_DELAY 3.0

// ─── /buy 3 叛变虫群可选虫种 (别名 + 数量, 对应 asrd_alien_civilwar 的 sm_betraypub) ─
#define BUY_BETRAY_VARIANTS  6
char g_sBetrayAlias[BUY_BETRAY_VARIANTS + 1][16] = { "", "drone", "buzzer", "ranger", "shield", "mortar", "shaman" };
int  g_iBetrayCount[BUY_BETRAY_VARIANTS + 1] = { 0, 10, 20, 10, 5, 10, 5 };

// ─── 满级加血 (强化满级后再购买 /buy 1): 血量低于阈值时可花积分治疗 ─
#define MAX_LEVEL_HEAL_THRESHOLD 800   // 当前血量低于此值才可购买满级加血 (>=800 不操作)
#define MAX_LEVEL_HEAL_AMOUNT   200    // 每次恢复量 (当前血量+200, 封顶最大血量)
#define MAX_POWER_LEVEL_MAXHP   1000   // 强化插件满级(L5)最大血量 (代码固定) — 满级判断以此为准

// 友军虫统一 targetname (镜像 asrd_alien_civilwar 的 INFECTED_NAME)
#define BETRAY_NAME     "asrd_betray_swarm"

// ─── 虫族实体类名清单 (与核弹/扫描机插件一致) ──────────
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
    "asw_shaman",            // 治疗虫 (RD 真实类名)
    "asw_xenomite",          // 自爆孢子虫 (收割者产出)
    "asw_antlion_guard",     // 蚁狮守卫 (旧名, 保留兼容)
    // RD 蚁狮守卫/工蜂真实类名 (npc_ 前缀)
    "npc_antlionguard",
    "npc_antlionguard_cavern",
    "npc_antlionguard_normal",
    "npc_antlion_worker"
};

// ─── 叛变虫可生成类型 (镜像 asrd_alien_civilwar, 用于 sm_betraypub 扣分前预校验) ──
char g_sBetrayTypes[][3][] =
{
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
    { "asw_grub",             "幼虫",       "grub"     },
    { "asw_drone_antlion",     "蚁狮工蜂",   "antonlion" },
    { "npc_antlion_worker",    "蚁狮工蜂(npc)", "anlionwork" },
    { "npc_antlionguard",      "蚁狮守卫",   "antlionguard" },
    { "npc_antlionguard_cavern","蚁狮守卫(洞窟)","antlioncave" },
    { "npc_antlionguard_normal","蚁狮守卫(标准)","antlionnorm" },
    { "asw_shaman",            "治疗虫",     "shaman"   }
};

// ─── ConVar 句柄 ─────────────────────────────────────────
ConVar g_cvEnabled;
ConVar g_cvStart;
ConVar g_cvHpScale;
ConVar g_cvNukeCost;
ConVar g_cvBetrayCost;
ConVar g_cvPowerCost;
ConVar g_cvSentryCost;
ConVar g_cvRefillCost;
ConVar g_cvHud;
ConVar g_cvHudChannel;
ConVar g_cvHudX;
ConVar g_cvHudY;
ConVar g_cvHudAlpha;
ConVar g_cvDebug;
ConVar g_cvAdvert;
ConVar g_cvAdvertInterval;
ConVar g_cvJoinHelp;

// ─── 积分池与 HUD 状态 ──────────────────────────────────
int    g_iPoints;
float  g_fLastHudCheck;         // HUD 帧回调节流时间 (秒)
float  g_fLastAdvert;           // 使用说明公告帧回调节流时间 (秒)
int    g_iPlayerLevel[MAXPLAYERS + 1];   // 强化等级镜像, 与 asrd_marine_power 同步, 用于满/低级别拦截扣分
float  g_fJoinHelpAt[MAXPLAYERS + 1];    // 进服购买说明的待发时刻 (GetEngineTime; 0=无待发)

// ============================================================================
//  插件信息
// ============================================================================
public Plugin myinfo = {
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "AS:RD 全队共享积分: 击杀虫族得分, 积分购买核弹/叛变虫群/强化等级",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
//  插件启动: 创建 ConVar、注册命令与命令监听
// ============================================================================
public void OnPluginStart()
{
    CreateConVar("sm_asrd_points_version", PLUGIN_VERSION,
        "积分机制插件版本", FCVAR_NOTIFY|FCVAR_DONTRECORD);

    g_cvEnabled = CreateConVar(
        "sm_asrd_points_enabled", "1",
        "积分机制总开关 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvStart = CreateConVar(
        "sm_asrd_points_start", "1000",
        "每局 (开局/换图) 的初始积分",
        FCVAR_NOTIFY, true, 0.0
    );
    g_cvHpScale = CreateConVar(
        "sm_asrd_points_hp_scale", "0.05",
        "击杀积分 = 虫族最大血量 x 此倍率 (四舍五入, 最少 1 分)",
        FCVAR_NOTIFY, true, 0.001, true, 100.0
    );
    g_cvNukeCost = CreateConVar(
        "sm_asrd_points_nuke_cost", "300",
        "核弹(sm_nukepub)积分价格 (0=不设积分门槛)",
        FCVAR_NOTIFY, true, 0.0
    );
    g_cvBetrayCost = CreateConVar(
        "sm_asrd_points_betray_cost", "100",
        "叛变虫群(sm_betraypub)积分价格 (0=不设积分门槛)",
        FCVAR_NOTIFY, true, 0.0
    );
    g_cvPowerCost = CreateConVar(
        "sm_asrd_points_power_cost", "400",
        "强化等级(sm_power_up/sm_power_down)积分价格 (0=不设积分门槛; sm_power_reset 免费)",
        FCVAR_NOTIFY, true, 0.0
    );
    g_cvSentryCost = CreateConVar(
        "sm_asrd_points_sentry_cost", "300",
        "强化哨戒塔(/buy 4)积分价格 (0=不设积分门槛)",
        FCVAR_NOTIFY, true, 0.0
    );
    g_cvRefillCost = CreateConVar(
        "sm_asrd_points_refill_cost", "500",
        "全场哨戒塔满配(/buy 5)积分价格 (0=不设积分门槛)",
        FCVAR_NOTIFY, true, 0.0
    );
    g_cvHud = CreateConVar(
        "sm_asrd_points_hud", "1",
        "屏幕积分显示开关 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvHudChannel = CreateConVar(
        "sm_asrd_points_hud_channel", "6",
        "积分 HUD 通道 (4=哨戒塔/X-33, 5=核弹)",
        FCVAR_NOTIFY, true, 1.0, true, 8.0
    );
    g_cvHudX = CreateConVar(
        "sm_asrd_points_hud_x", "0.01",
        "积分 HUD 横向位置 (0=最左 1=最右, -1=居中; 该游戏 HudText 只渲染左侧 4:3 区域, 勿设到 0.7 以上)",
        FCVAR_NOTIFY, true, -1.0, true, 0.7
    );
    g_cvHudY = CreateConVar(
        "sm_asrd_points_hud_y", "0.02",
        "积分 HUD 纵向位置 (0=最上 1=最下)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvHudAlpha = CreateConVar(
        "sm_asrd_points_hud_alpha", "170",
        "积分 HUD 文字透明度 (0=完全透明 255=不透明, 170≈半透明)",
        FCVAR_NOTIFY, true, 0.0, true, 255.0
    );
    g_cvDebug = CreateConVar(
        "sm_asrd_points_debug", "0",
        "调试输出到服务器控制台 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvAdvert = CreateConVar(
        "sm_asrd_points_advert", "1",
        "每隔一段时间在聊天中公告基本使用说明 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvAdvertInterval = CreateConVar(
        "sm_asrd_points_advert_interval", "30",
        "使用说明公告间隔秒数",
        FCVAR_NOTIFY, true, 5.0
    );
    g_cvJoinHelp = CreateConVar(
        "sm_asrd_points_join_help", "1",
        "玩家连接后私聊通知购买用法 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    // 自动保存/读取配置到 cfg/sourcemod/asrd_points.cfg
    AutoExecConfig(true, "asrd_points");

    // 无注册命令: /buy、/1、/2、/3 等聊天框购买统一走 OnClientSayCommand;
    // 控制台没有积分相关命令 (原功能命令控制台调用不扣积分)。

    // sm_power_reset 免费, 但需同步强化等级镜像 (镜像置 0), 不扣分
    AddCommandListener(Listener_PowerReset, "sm_power_reset");

    // 屏幕积分显示由帧回调 + 0.5 秒节流刷新 (见下方 OnGameFrame)。
    // v1.6.2: 原 CreateTimer 在本环境下定时器不触发, 与核弹 v1.7.7 同源修复。

    // 同图重开 (mp_restartgame / restart) 不触发 OnMapStart, 需在此也重置积分
    AddCommandListener(Listener_Restart, "mp_restartgame");
    AddCommandListener(Listener_Restart, "restart");

    // AS:RD 任务即时重启 (重新开始游戏, 不换图): 与 asrd_marine_power 用同一事件,
    // 重置积分并把强化等级镜像清 0, 避免满级判断漂移
    HookEventEx("asw_mission_restart", Event_MissionRestart, EventHookMode_Post);

    // 热加载 (插件中途载入 / map 已在进行) 时补挂虫族伤害钩子
    char sMap[PLATFORM_MAX_PATH];
    if (GetCurrentMap(sMap, sizeof(sMap)) > 0)
        HookExistingAliens();
}

// ============================================================================
//  玩家加入: 预约一条购买说明, 稍后 (JOIN_HELP_DELAY 秒) 私聊发送
//  立即发的话玩家可能还在加载画面里, 会看不到; 实际发送见 OnGameFrame
//  (本环境 CreateTimer 不触发, 与 HUD/公告一致改用帧回调 + 时间戳)
// ============================================================================
public void OnClientPutInServer(int client)
{
    if (client <= 0 || IsFakeClient(client))
        return;

    g_fJoinHelpAt[client] = GetEngineTime() + JOIN_HELP_DELAY;
}

// 玩家断开: 清掉未发送的预约, 免得索引被下一位玩家复用后误发
public void OnClientDisconnect(int client)
{
    if (client > 0 && client <= MaxClients)
        g_fJoinHelpAt[client] = 0.0;
}

// 地图加载/开局: 每局重置为初始积分 (一局一结算)
public void OnMapStart()
{
    g_iPoints = g_cvStart.IntValue;
    if (g_iPoints < 0)
        g_iPoints = 0;

    // 换图后强化等级同步归 0 (强化插件同样在换图时重置), 镜像保持一致
    for (int i = 1; i <= MaxClients; i++)
        g_iPlayerLevel[i] = 0;
}

// ============================================================================
//  实体创建钩子: 给虫族挂伤害钩子 (计分必须挂在 victim 侧, 同扫描机模式)
// ============================================================================
public void OnEntityCreated(int entity, const char[] classname)
{
    if (IsAlienClass(classname))
        SDKHookEx(entity, SDKHook_OnTakeDamage, OnAlienDamaged);
}

// ============================================================================
//  伤害回调 (victim=虫族): 判定致命一击的归属并计分
// ============================================================================
public Action OnAlienDamaged(int victim, int &attacker, int &inflictor,
    float &damage, int &damagetype, int &weapon,
    float damageForce[3], float damagePosition[3], int damagecustom)
{
    if (!g_cvEnabled.BoolValue)
        return Plugin_Continue;
    if (attacker <= 0 || attacker == victim)
        return Plugin_Continue;
    if (!HasEntProp(victim, Prop_Data, "m_iHealth"))
        return Plugin_Continue;

    int iHealth = GetEntProp(victim, Prop_Data, "m_iHealth");
    if (iHealth <= 0 || damage < float(iHealth))
        return Plugin_Continue;   // 已死亡或本次伤害非致命

    // 友军虫/玩家附身虫 (targetname=asrd_betray_swarm) 不打分, 防刷分
    if (IsBetrayAlien(victim))
        return Plugin_Continue;

    int killer = ResolveKillerClient(attacker);
    if (killer <= 0)
        return Plugin_Continue;

    AwardPoints(victim, killer);
    return Plugin_Continue;
}

// ============================================================================
//  计分: 积分 = max(1, round(虫族最大血量 x hp_scale))
// ============================================================================
void AwardPoints(int victim, int killer)
{
    int iMax = 0;
    if (HasEntProp(victim, Prop_Data, "m_iMaxHealth"))
        iMax = GetEntProp(victim, Prop_Data, "m_iMaxHealth");
    if (iMax <= 0)
        iMax = GetEntProp(victim, Prop_Data, "m_iHealth");

    int iPoints = RoundToNearest(float(iMax) * g_cvHpScale.FloatValue);
    if (iPoints < 1)
        iPoints = 1;

    g_iPoints += iPoints;
    RefreshHud();

    if (g_cvDebug.BoolValue)
    {
        char cls[64];
        GetEntityClassname(victim, cls, sizeof(cls));
        PrintToServer("[积分][debug] %N 击杀 %s (maxhp=%d) 获得 %d 积分, 总 %d",
            killer, cls, iMax, iPoints, g_iPoints);
    }
}

// ============================================================================
//  把攻击者实体解析为击杀玩家 (0=无人):
//   玩家客户端 / 陆战队员实体(查 m_Commander) / 被玩家附身的虫族(查 m_Commander)
//   / 哨戒塔塔顶炮台(反查 m_hSentryBase -> m_hDeployer -> 操控者)
// ============================================================================
int ResolveKillerClient(int attacker)
{
    if (attacker <= 0)
        return 0;

    if (attacker <= MaxClients)
    {
        if (IsClientInGame(attacker) && !IsFakeClient(attacker))
            return attacker;
        return 0;
    }

    if (!IsValidEntity(attacker))
        return 0;

    char cls[64];
    GetEntityClassname(attacker, cls, sizeof(cls));

    // 哨戒塔塔顶炮台 (asw_sentry_top_*): 机枪塔走 hitscan 子弹, 引擎在
    // FireBulletsInfo_t 里只填了塔顶实体自身 (asw_sentry_top_machinegun.cpp
    // "info.m_pAttacker = this"), 插件必须自己反查这座塔是谁部署的。
    // (炮弹/喷火/冰冻塔引擎直接填部署者 marine, 不走这里, 但一并兜住无害。)
    if (IsSentryTopClass(cls))
        return GetSentryTopDeployerClient(attacker);

    if (!StrEqual(cls, "asw_marine", false) && !IsAlienClass(cls))
        return 0;

    return GetCommanderClient(attacker);
}

// ============================================================================
//  是否是哨戒塔塔顶炮台类 (asw_sentry_top_machinegun / _cannon / _flamer
//  / _icer / _railgun)
// ============================================================================
bool IsSentryTopClass(const char[] classname)
{
    return StrContains(classname, "asw_sentry_top_", false) == 0;
}

// ============================================================================
//  塔顶实体 -> 塔底座 (m_hSentryBase) -> 部署者陆战队员 (m_hDeployer)
//  -> 操控该 marine 的玩家 (0=无归属)
//  地图预置的塔 (非玩家部署) m_hDeployer 为空, 返回 0 不计分
// ============================================================================
int GetSentryTopDeployerClient(int iTop)
{
    int iBase = GetNetHandleEnt(iTop, "m_hSentryBase");
    if (iBase <= 0)
        return 0;

    int iMarine = GetNetHandleEnt(iBase, "m_hDeployer");
    if (iMarine <= 0)
        return 0;

    return GetCommanderClient(iMarine);
}

// ============================================================================
//  读取 CNetworkHandle 字段指向的实体 (Prop_Send 优先, Prop_Data 兜底;
//  与插件其它位置读取坐标/操控者的做法一致, 避免单一路径拿不到值)
// ============================================================================
int GetNetHandleEnt(int iEnt, const char[] sProp)
{
    if (HasEntProp(iEnt, Prop_Send, sProp))
    {
        int iTarget = GetEntPropEnt(iEnt, Prop_Send, sProp);
        if (iTarget > 0 && IsValidEntity(iTarget))
            return iTarget;
    }

    if (HasEntProp(iEnt, Prop_Data, sProp))
    {
        int iTarget = GetEntPropEnt(iEnt, Prop_Data, sProp);
        if (iTarget > 0 && IsValidEntity(iTarget))
            return iTarget;
    }

    return 0;
}

// ============================================================================
//  查实体上的 m_Commander (CASW_Inhabitable_NPC 字段, marine/虫族都有):
//  先数据属性后网络属性, 返回操控该实体的玩家 (0=无人操控)
// ============================================================================
int GetCommanderClient(int ent)
{
    if (FindDataMapInfo(ent, "m_Commander") > 0)
    {
        int client = GetEntPropEnt(ent, Prop_Data, "m_Commander");
        if (IsUsableClient(client))
            return client;
    }

    char sNetClass[64];
    if (GetEntityNetClass(ent, sNetClass, sizeof(sNetClass))
        && FindSendPropInfo(sNetClass, "m_Commander") > 0)
    {
        int client = GetEntPropEnt(ent, Prop_Send, "m_Commander");
        if (IsUsableClient(client))
            return client;
    }

    return 0;
}

bool IsUsableClient(int client)
{
    return client > 0 && client <= MaxClients
        && IsClientInGame(client) && !IsFakeClient(client);
}

// ============================================================================
//  判断玩家是否真正在游戏中: 是否控制着任意陆战队员 (查 m_Commander)
//  (不依赖队伍编号; 观战/等待/未入队玩家没有受控 marine, 判定为不在游戏中)
// ============================================================================
bool IsActivePlayer(int client)
{
    if (!IsUsableClient(client))
        return false;

    int iEnt = -1;
    while ((iEnt = FindEntityByClassname(iEnt, "asw_marine")) != -1)
    {
        if (GetCommanderClient(iEnt) == client)
            return true;
    }
    return false;
}

// 返回玩家当前控制的陆战队员实体 (0=未控制)
int GetClientMarine(int client)
{
    if (!IsUsableClient(client))
        return 0;

    int iEnt = -1;
    while ((iEnt = FindEntityByClassname(iEnt, "asw_marine")) != -1)
    {
        if (GetCommanderClient(iEnt) == client)
            return iEnt;
    }
    return 0;
}

// ============================================================================
//  判定是否为友军虫 (targetname=asrd_betray_swarm, 含玩家附身虫)
// ============================================================================
bool IsBetrayAlien(int ent)
{
    char sName[64];
    GetEntPropString(ent, Prop_Data, "m_iName", sName, sizeof(sName));
    return StrEqual(sName, BETRAY_NAME);
}

// ============================================================================
//  命令监听: 同图重开 (mp_restartgame / restart) 不触发 OnMapStart,
//  在这里把积分重置为初始值 (一局一结算在此同样成立)
// ============================================================================
public Action Listener_Restart(int client, const char[] command, int argc)
{
    g_iPoints = g_cvStart.IntValue;
    if (g_iPoints < 0)
        g_iPoints = 0;
    ResetPlayerLevels();

    if (g_cvDebug.BoolValue)
        PrintToServer("[积分][debug] 检测到 %s, 积分重置为 %d", command, g_iPoints);
    return Plugin_Continue;
}

// ============================================================================
//  AS:RD 任务即时重启 (重新开始游戏, 不换图): 重置积分 + 清强化等级镜像
// ============================================================================
public void Event_MissionRestart(Event event, const char[] name, bool dontBroadcast)
{
    g_iPoints = g_cvStart.IntValue;
    if (g_iPoints < 0)
        g_iPoints = 0;
    ResetPlayerLevels();

    if (g_cvDebug.BoolValue)
        PrintToServer("[积分][debug] 任务重启(asw_mission_restart), 积分重置为 %d", g_iPoints);
}

void ResetPlayerLevels()
{
    for (int i = 1; i <= MaxClients; i++)
        g_iPlayerLevel[i] = 0;
}

// ============================================================================
//  聊天框统一购买入口 (唯一扣积分路径)
//  玩家在聊天框输入 /buy、/1、/2、/3、/nukepub、/betraypub、/power_up 等,
//  全部在此解析: 校验 → 扣分 → 转发给原插件命令执行。
//  客户端控制台/服务器控制台调用原命令不经过这里 → 不扣积分。
// ============================================================================
public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
        return Plugin_Continue;
    if (sArgs[0] != '/' && sArgs[0] != '!')
        return Plugin_Continue;

    char sText[192];
    strcopy(sText, sizeof(sText), sArgs);
    TrimString(sText);
    if (sText[0] != '/' && sText[0] != '!')
        return Plugin_Continue;

    char sCmd[64];
    GetArgFromString(sText, 0, sCmd, sizeof(sCmd));   // 参数 0 = 命令本身 (去前缀)

    if (StrEqual(sCmd, "buy", false))
    {
        char sA1[16], sA2[16];
        if (!GetArgFromString(sText, 1, sA1, sizeof(sA1)))
        {
            ShowBuyHelp(client);
            return Plugin_Handled;
        }
        int iItem = StringToInt(sA1);
        switch (iItem)
        {
            case 1:
                BuyPowerFromChat(client, true);
            case 2:
                PurchaseFromChat(client, "sm_nukepub", "", g_cvNukeCost,
                    "核弹", "sm_asrd_nuke_enabled", "sm_asrd_nuke_public");
            case 3:
            {
                int iVar = 1;
                if (GetArgFromString(sText, 2, sA2, sizeof(sA2)))
                    iVar = StringToInt(sA2);
                if (iVar < 1 || iVar > BUY_BETRAY_VARIANTS)
                {
                    PrintToChat(client, "\x04[积分]\x01 /buy 3 选项: 1=工蜂 2=蜂群 3=游侠 4=盾甲虫 5=迫击炮虫 6=治疗虫");
                    return Plugin_Handled;
                }
                char sBetray[64];
                Format(sBetray, sizeof(sBetray), "%s %d", g_sBetrayAlias[iVar], g_iBetrayCount[iVar]);
                PurchaseFromChat(client, "sm_betraypub", sBetray, g_cvBetrayCost,
                    "叛变虫群", "sm_asrd_betray_enabled", "sm_asrd_betray_public");
            }
            case 4:
            {
                // /buy 4 <编号>: 购买强化哨戒塔箱 (0=机枪 1=炮塔; 喷火/冰冻暂不支持)
                char sType[16];
                int iType = -1;
                if (GetArgFromString(sText, 2, sType, sizeof(sType)))
                    iType = StringToInt(sType);

                if (iType < 0 || iType > BUY_SENTRY_VARIANTS_MAX)
                {
                    PrintToChat(client, "\x04[积分]\x01 /buy 4 编号无效: 0=机枪 1=炮塔 (喷火/冰冻暂不支持)");
                }
                else
                {
                    char sTypeArg[8];
                    IntToString(iType, sTypeArg, sizeof(sTypeArg));

                    char sFeature[32];
                    Format(sFeature, sizeof(sFeature), "强化哨戒塔(%s)", iType == 0 ? "机枪" : "炮塔");

                    PurchaseFromChat(client, "sm_sentrydrop", sTypeArg, g_cvSentryCost,
                        sFeature, "sm_asrd_sentry_enabled", "sm_asrd_sentry_drop_public");
                }
            }
            case 5:
            {
                // /buy 5: 一键满配全场哨戒塔 (补满生命与弹药)
                // 先查地图上有没有塔: 一座都没有就别让玩家白扣 500 分
                int iSentries = CountMapSentries();
                if (iSentries <= 0)
                {
                    PrintToChat(client, "\x04[积分]\x01 地图上目前没有任何哨戒塔, 不能购买【%s】", "全场哨戒塔满配");
                    return Plugin_Handled;
                }

                PurchaseFromChat(client, "sm_sentry_refill", "", g_cvRefillCost,
                    "全场哨戒塔满配", "sm_asrd_sentry_enabled", "sm_asrd_sentry_refill_public");
            }
            default:
            {
                PrintToChat(client, "\x04[积分]\x01 /buy 编号无效, 输入 \x05/buy\x01 查看格式");
            }
        }
        return Plugin_Handled;
    }

    if (StrEqual(sCmd, "1", false))
    {
        BuyPowerFromChat(client, true);
        return Plugin_Handled;
    }
    if (StrEqual(sCmd, "2", false))
    {
        PurchaseFromChat(client, "sm_nukepub", "", g_cvNukeCost,
            "核弹", "sm_asrd_nuke_enabled", "sm_asrd_nuke_public");
        return Plugin_Handled;
    }
    if (StrEqual(sCmd, "3", false))
    {
        char sBetray[64];
        Format(sBetray, sizeof(sBetray), "%s %d", g_sBetrayAlias[1], g_iBetrayCount[1]);
        PurchaseFromChat(client, "sm_betraypub", sBetray, g_cvBetrayCost,
            "叛变虫群", "sm_asrd_betray_enabled", "sm_asrd_betray_public");
        return Plugin_Handled;
    }

    if (StrEqual(sCmd, "nukepub", false))
    {
        char sRest[64];
        JoinArgsFrom(sText, 1, sRest, sizeof(sRest));
        PurchaseFromChat(client, "sm_nukepub", sRest, g_cvNukeCost,
            "核弹", "sm_asrd_nuke_enabled", "sm_asrd_nuke_public");
        return Plugin_Handled;
    }
    if (StrEqual(sCmd, "betraypub", false))
    {
        char sRest[64];
        JoinArgsFrom(sText, 1, sRest, sizeof(sRest));
        PurchaseFromChat(client, "sm_betraypub", sRest, g_cvBetrayCost,
            "叛变虫群", "sm_asrd_betray_enabled", "sm_asrd_betray_public");
        return Plugin_Handled;
    }
    if (StrEqual(sCmd, "power_up", false))
    {
        BuyPowerFromChat(client, true);
        return Plugin_Handled;
    }
    if (StrEqual(sCmd, "power_down", false))
    {
        BuyPowerFromChat(client, false);
        return Plugin_Handled;
    }

    return Plugin_Continue;
}

void BuyPowerFromChat(int client, bool bUp)
{
    if (bUp)
    {
        // 满级判断以实际最大血量为准 (IsMarineMaxLevel), 不再依赖镜像 g_iPlayerLevel:
        // 镜像只随聊天框购买更新, 与 sm_power_set 指定 / 绑定键直调 sm_power_up 可能不同步,
        // 旧逻辑会让满级玩家误走扣分放行(原插件不强化) → 扣分但血量不变
        if (IsMarineMaxLevel(client))
        {
            BuyMaxLevelHeal(client);
            return;
        }
        if (PurchaseFromChat(client, "sm_power_up", "", g_cvPowerCost,
            "强化等级", "sm_asrd_power_enabled", "sm_asrd_power_public"))
            g_iPlayerLevel[client]++;
    }
    else
    {
        // 已达最小体型: 不再扣分
        if (g_iPlayerLevel[client] <= -GetPowerShrinkMax())
        {
            FakeClientCommand(client, "sm_power_down");
            return;
        }
        if (PurchaseFromChat(client, "sm_power_down", "", g_cvPowerCost,
            "强化等级", "sm_asrd_power_enabled", "sm_asrd_power_public"))
            g_iPlayerLevel[client]--;
    }
}

// 满级判断: 玩家控制的陆战队员最大血量达到强化插件等级表上限(L5=1000)即视为满级
// (强化插件 m_iMaxHealth 同样用 Prop_Data 读写, 与血量加血一致)
bool IsMarineMaxLevel(int client)
{
    int marine = GetClientMarine(client);
    if (marine <= 0)
        return false;
    return GetEntProp(marine, Prop_Data, "m_iMaxHealth") >= MAX_POWER_LEVEL_MAXHP;
}

// ============================================================================
//  满级加血: 强化满级后再购买 /buy 1 的后续逻辑
//    当前血量 >= 800            → 不做任何操作, 仅提示
//    当前血量 < 800 且积分够    → 扣 power_cost, 当前血量 +200 (封顶最大血量)
//    当前血量 < 800 但积分不足  → 不做任何操作, 仅提示
// ============================================================================
void BuyMaxLevelHeal(int client)
{
    // 积分机制关闭或价格=0: 不提供免费加血, 放行原插件自行处理 (会提示已达最高等级)
    if (!g_cvEnabled.BoolValue || g_cvPowerCost.IntValue <= 0)
    {
        FakeClientCommand(client, "sm_power_up");
        return;
    }

    if (!IsActivePlayer(client))
    {
        PrintToChat(client, "\x04[积分]\x01 不在游戏中的玩家不能购买, 请先加入游戏");
        return;
    }

    int marine = GetClientMarine(client);
    if (marine <= 0)
        return;

    int iHealth = GetEntProp(marine, Prop_Data, "m_iHealth");
    if (iHealth <= 0)
    {
        PrintToChat(client, "\x04[积分]\x01 你已阵亡, 无法购买满级加血");
        return;
    }

    // 血量 >= 800: 不做任何操作, 仅提示
    if (iHealth >= MAX_LEVEL_HEAL_THRESHOLD)
    {
        PrintToChat(client, "\x04[积分]\x01 强化已满级且血量充足, 无需购买");
        return;
    }

    // 积分不足: 不做任何操作, 仅提示
    if (g_iPoints < g_cvPowerCost.IntValue)
    {
        PrintToChat(client, "\x04[积分]\x01 积分不足: 强化加血需要 \x05%d\x01 积分, 当前 \x05%d\x01 积分",
            g_cvPowerCost.IntValue, g_iPoints);
        return;
    }

    g_iPoints -= g_cvPowerCost.IntValue;
    RefreshHud();
    PrintToChatAll("\x04[积分]\x01 %N 花费 \x05%d\x01 积分购买【满级加血】, 剩余 \x05%d\x01 积分",
        client, g_cvPowerCost.IntValue, g_iPoints);

    // 治疗: 当前血量 +200, 封顶最大血量
    int iMaxHealth = GetEntProp(marine, Prop_Data, "m_iMaxHealth");
    int iNew = iHealth + MAX_LEVEL_HEAL_AMOUNT;
    if (iMaxHealth > 0 && iNew > iMaxHealth)
        iNew = iMaxHealth;
    SetEntProp(marine, Prop_Data, "m_iHealth", iNew);
    PrintToChat(client, "\x04[积分]\x01 血量已恢复至 \x05%d/%d\x01", iNew, iMaxHealth);
}

// ============================================================================
//  聊天命令解析辅助: 从 "!buy 3 5" 这类文本取第 n 个参数
//  n=0 返回命令本体 (已去 / ! 前缀); 找不到返回 false
// ============================================================================
bool GetArgFromString(const char[] sInput, int n, char[] buf, int maxlen)
{
    int i = 1;   // 跳过 / 或 ! 前缀
    int cur = 0;
    for (;;)
    {
        while (sInput[i] == ' ')
            i++;
        if (sInput[i] == '\0')
            return false;
        int j = 0;
        while (sInput[i] != '\0' && sInput[i] != ' ' && j < maxlen - 1)
            buf[j++] = sInput[i++];
        buf[j] = '\0';
        if (cur == n)
            return true;
        cur++;
    }
}

// 把第 n 个参数起的所有参数拼成 "a b c" (n 从 1 开始)
void JoinArgsFrom(const char[] sInput, int n, char[] buf, int maxlen)
{
    buf[0] = '\0';
    char sTmp[64];
    int i = 1;
    int cur = 1;
    for (;;)
    {
        while (sInput[i] == ' ')
            i++;
        if (sInput[i] == '\0')
            break;
        int j = 0;
        while (sInput[i] != '\0' && sInput[i] != ' ' && j < sizeof(sTmp) - 1)
            sTmp[j++] = sInput[i++];
        sTmp[j] = '\0';
        if (cur >= n)
        {
            if (buf[0] != '\0')
                StrCat(buf, maxlen, " ");
            StrCat(buf, maxlen, sTmp);
        }
        cur++;
    }
}

// 购买用法说明 (玩家输入 /buy 查询 & 进服通知 共用同一份)
void ShowBuyHelp(int client)
{
    PrintToChat(client, "\x04[积分]\x01 欢迎 \x05%N\x01! ── 快捷购买 ──  当前总积分: \x05%d\x01   用法: \x05/buy <编号> [选项]", client, g_iPoints);
    PrintToChat(client, "  \x05/buy 1\x01  属性强化 +1 (%d 分; 满级后转为加血)", g_cvPowerCost.IntValue);
    PrintToChat(client, "  \x05/buy 2\x01  战术核弹 (%d 分)", g_cvNukeCost.IntValue);
    PrintToChat(client, "  \x05/buy 3 [1-6]\x01  友军虫群 (%d 分): 1=工蜂 2=蜂群 3=游侠 4=盾甲虫 5=迫击炮虫 6=治疗虫", g_cvBetrayCost.IntValue);
    PrintToChat(client, "  \x05/buy 4 <0/1>\x01  强化哨戒塔箱 (%d 分): 0=机枪 1=炮塔", g_cvSentryCost.IntValue);
    PrintToChat(client, "  \x05/buy 5\x01  一键满配全场哨戒塔 (%d 分; 场上无塔时不会扣分)", g_cvRefillCost.IntValue);
    PrintToChat(client, "  快捷指令: \x05/1\x01 强化   \x05/2\x01 核弹   \x05/3\x01 虫群");
}

// ============================================================================
//  命令监听: sm_power_reset (免费): 只把等级镜像归 0, 放行给原插件恢复默认
// ============================================================================
public Action Listener_PowerReset(int client, const char[] command, int argc)
{
    if (client > 0 && client <= MaxClients)
        g_iPlayerLevel[client] = 0;
    return Plugin_Continue;
}

// 读取 asrd_marine_power 的体型下限 (找不到时用其代码默认值)
int GetPowerShrinkMax()
{
    ConVar c = FindConVar("sm_asrd_power_shrink_max");
    return c != null ? c.IntValue : 3;
}

// ============================================================================
//  购买核心 (仅聊天框入口): 校验 → 扣分 → 转发给原插件执行
//  返回 true = 已放行 (扣分成功或该功能无门槛), false = 阻止 (已提示原因)
// ============================================================================
// ============================================================================
//  统计地图上现有的哨戒塔数量 (底座实体 asw_sentry_base)
//  仅用于 /buy 5 的前置检查: 一座塔都没有时不允许购买满配, 免得白扣积分
// ============================================================================
int CountMapSentries()
{
    int count = 0;
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "asw_sentry_base")) != -1)
        count++;

    return count;
}

bool PurchaseFromChat(int client, const char[] sFullCommand, const char[] sArgs,
    ConVar costCv, const char[] sFeature,
    const char[] sEnabledCv, const char[] sPublicCv)
{
    // 不在游戏中 (未控制任何陆战队员: 观战/等待/未入队) 的玩家不能消耗积分
    if (!IsActivePlayer(client))
    {
        if (g_cvDebug.BoolValue)
            PrintToServer("[积分][debug] %N 队伍=%d, 拒绝购买 (未控制陆战队员)", client, GetClientTeam(client));
        PrintToChat(client, "\x04[积分]\x01 不在游戏中的玩家不能购买, 请先加入游戏");
        return false;
    }

    // 插件总开关或价格=0: 不设积分门槛, 直接放行原命令
    if (!g_cvEnabled.BoolValue || costCv.IntValue <= 0)
    {
        FakeClientCommand(client, "%s %s", sFullCommand, sArgs);
        return true;
    }
    int iCost = costCv.IntValue;

    // 原插件总开关: 关着就拒绝, 不扣分
    ConVar cvEnabled = FindConVar(sEnabledCv);
    if (cvEnabled != null && !cvEnabled.BoolValue)
    {
        PrintToChat(client, "\x04[积分]\x01 %s 功能已禁用", sFeature);
        return false;
    }

    // 原插件 public 开关: 未开就拒绝, 不扣分
    ConVar cvPublic = FindConVar(sPublicCv);
    if (cvPublic == null)
    {
        PrintToChat(client, "\x04[积分]\x01 %s 对应插件未加载, 无法购买", sFeature);
        return false;
    }
    if (!cvPublic.BoolValue)
    {
        PrintToChat(client, "\x04[积分]\x01 %s 未对玩家开放 (管理员需设置 \x05%s\x01 1)",
            sFeature, sPublicCv);
        return false;
    }

    // sm_betraypub: 扣分前预校验虫种, 防止打错字白扣积分
    if (StrEqual(sFullCommand, "sm_betraypub", false))
    {
        char sArg[64] = "";
        int i = 0;
        int j = 0;
        while (sArgs[i] == ' ')
            i++;
        while (sArgs[i] != '\0' && sArgs[i] != ' ' && j < sizeof(sArg) - 1)
            sArg[j++] = sArgs[i++];
        sArg[j] = '\0';
        if (sArg[0] != '\0' && !IsValidBetrayType(sArg))
        {
            PrintToChat(client, "\x04[积分]\x01 未知虫种 \"%s\", 用 sm_betray_list 查看可选虫种", sArg);
            return false;
        }
    }

    if (g_iPoints < iCost)
    {
        PrintToChat(client, "\x04[积分]\x01 积分不足: %s 需要 \x05%d\x01 积分, 当前 \x05%d\x01 积分",
            sFeature, iCost, g_iPoints);
        return false;
    }

    // 扣分并转发给原插件执行
    g_iPoints -= iCost;
    RefreshHud();
    PrintToChatAll("\x04[积分]\x01 %N 花费 \x05%d\x01 积分购买【%s】, 剩余 \x05%d\x01 积分",
        client, iCost, sFeature, g_iPoints);

    if (g_cvDebug.BoolValue)
        PrintToServer("[积分][debug] %N 购买 %s 花费 %d, 剩余 %d",
            client, sFeature, iCost, g_iPoints);

    FakeClientCommand(client, "%s %s", sFullCommand, sArgs);
    return true;
}

// ============================================================================
//  虫种名校验 (镜像 asrd_alien_civilwar 的 ResolveType)
// ============================================================================
bool IsValidBetrayType(const char[] sInput)
{
    for (int i = 0; i < sizeof(g_sBetrayTypes); i++)
    {
        if (StrEqual(sInput, g_sBetrayTypes[i][0], false)
            || StrEqual(sInput, g_sBetrayTypes[i][2], false)
            || StrEqual(sInput, g_sBetrayTypes[i][1], false))
            return true;
    }
    return false;
}

// ============================================================================
//  帧回调: HUD 刷新 (0.5 秒节流) + 使用说明公告 (默认 30 秒节流)
//  (不依赖 SourceMod 定时器; 本环境定时器不触发, 否则 HUD 只闪一下)
// ============================================================================
public void OnGameFrame()
{
    float fNow = GetEngineTime();

    // 进服购买说明: 到点的玩家逐个私聊发送 (预约见 OnClientPutInServer)
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_fJoinHelpAt[i] <= 0.0 || fNow < g_fJoinHelpAt[i])
            continue;

        g_fJoinHelpAt[i] = 0.0;
        if (g_cvJoinHelp.BoolValue && IsClientInGame(i) && !IsFakeClient(i))
            ShowBuyHelp(i);
    }

    if (fNow - g_fLastHudCheck >= HUD_REFRESH)
    {
        g_fLastHudCheck = fNow;
        RefreshHud();
    }

    if (g_cvAdvert.BoolValue && fNow - g_fLastAdvert >= g_cvAdvertInterval.FloatValue)
    {
        g_fLastAdvert = fNow;
        AdvertiseUsage();
    }
}

// ============================================================================
//  聊天公告: 基本使用说明 (每隔一段时间循环)
// ============================================================================
void AdvertiseUsage()
{
    PrintToChatAll("\x04[积分]\x01 快捷购买: \x05/buy 1\x01强化(%d) \x05/buy 2\x01核弹(%d) \x05/buy 3\x01虫群(%d) \x05/buy 4\x01哨戒塔(%d) \x05/buy 5\x01补充全部哨戒弹药(%d)",
        g_cvPowerCost.IntValue, g_cvNukeCost.IntValue, g_cvBetrayCost.IntValue,
        g_cvSentryCost.IntValue, g_cvRefillCost.IntValue);
}

void RefreshHud()
{
    if (!g_cvEnabled.BoolValue || !g_cvHud.BoolValue)
        return;

    int   iChannel = g_cvHudChannel.IntValue;
    float fX = g_cvHudX.FloatValue;
    float fY = g_cvHudY.FloatValue;
    int   iAlpha = g_cvHudAlpha.IntValue;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;

        SetHudTextParams(fX, fY, HUD_HOLD, 255, 210, 0, iAlpha, 0, 0.0, 0.1, 0.1);
        ShowHudText(i, iChannel, "总积分: %d", g_iPoints);
    }
}

// ============================================================================
//  工具: 虫族类名判定 / 补挂已有虫族
// ============================================================================
bool IsAlienClass(const char[] classname)
{
    for (int c = 0; c < sizeof(g_sAlienClasses); c++)
    {
        if (StrEqual(classname, g_sAlienClasses[c], false))
            return true;
    }
    return false;
}

void HookExistingAliens()
{
    for (int c = 0; c < sizeof(g_sAlienClasses); c++)
    {
        int ent = -1;
        while ((ent = FindEntityByClassname(ent, g_sAlienClasses[c])) != -1)
            SDKHookEx(ent, SDKHook_OnTakeDamage, OnAlienDamaged);
    }
}
