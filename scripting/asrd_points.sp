/**
 * ============================================================================
 *  [AS:RD] 积分机制 (Points)
 *  版本 1.22.0  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ──────────────────────────────────────
 *  引入一套全队共享的积分经济:
 *    1. 击杀计分: 玩家击杀虫族获得积分, 按被杀虫族的实际最大血量计算
 *       (血量越高积分越多, 倍率见 sm_asrd_points_hp_scale, 最少 1 分)
 *    2. 积分购买: 玩家使用 sm_nukepub / sm_betraypub / sm_power_up|down 时,
 *       先扣除积分再放行给原插件执行功能; 聊天框用 /buy 4 <编号> 购买强化
 *       哨戒塔 (0机枪 1炮塔, 喷火/冰冻暂不支持), /buy 5 补充全部哨戒塔弹药
 *    3. 积分显示: 屏幕左上方常驻显示总积分, 每 0.5 秒刷新, 击杀/消费即时更新
 *       (积分机制关闭时 HUD 隐藏并清掉残留文字)
 *    4. 进服通知: 玩家连上服务器后, 延迟几秒在聊天框私聊发送欢迎,
 *       并提示输入 /buy 查看详细用法 (详细用法在玩家输入 /buy 后才显示;
 *       不再周期性公告。开关见 sm_asrd_points_join_help;
 *       积分机制关闭时既无 HUD 也不发此通知)
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
 *                        /buy = 显示格式; /buy 1=属性强化+1; /buy 2=核弹
 *                        (核弹购买后 nuke_cooldown 秒内不能再买, 默认 3);
 *                        /buy 3 [1-6]=叛变虫群 (/buy 3 无选项=drone×10)
 *                        (强化已满级时 /buy 1 转为加血: 血量<800 花
 *                        power_cost 恢复 200 血, 封顶最大血量)
 *                        /buy 4 [编号]=强化哨戒塔箱 (0机枪 1炮塔,
 *                        无选项默认 0=机枪; 喷火/冰冻暂不支持);
 *                        /buy 5=补充全部哨戒塔弹药
 *                        (地图上没有哨戒塔时不允许购买, 不扣分)
 *                        /buy 6 [1|2]=武器箱 (第 6 类):
 *                          6 1=增强电锯 (伤害由 asrd_chainsaw_turbo 的 sm_asrd_chainsaw_dmg_mult 决定)
 *                          6 2=守望者脉冲步枪 (由 asrd_watcher_pulse_rifle 掉落, 击杀计积分)
 *                        /buy 7=头顶弹药箱 (由 asrd_ammohead 在玩家自己头顶放置标准弹药箱,
 *                        游戏默认弹药量/有限/同一陆战队员头顶同时仅1个; 管理员 sm_ammohead 可自定义含量)
 *                        /buy 8=弹药箱 (本插件直接实现在玩家身前地面掉落一个原版 asw_ammo_drop,
 *                        弹药量=游戏原版默认(DEFAULT_AMMO_DROP_UNITS=100)/有限, 走过去补弹)
 *   /1 ../8           玩家: 聊天框快捷购买, 与 /buy <编号> **完全等价**且同样能带选项:
 *                        /1 强化等级  /2 核弹  /3 [1-6] 叛变虫群(默认 drone×10)
 *                        /4 [0/1] 哨戒塔箱  /5 补充全部哨戒塔弹药  /6 [1|2] 武器箱(1=电锯 2=脉冲步枪)
 *                        /7 头顶弹药箱(标准弹药, 放到自己头顶)  /8 弹药箱(身前地面掉落)
 *                        例: /3 2 = /buy 3 2 (游侠); /4 1 = /buy 4 1 (炮塔)
 *   /nukepub /betraypub /power_up /power_down
 *                     玩家: 聊天框直接调用原功能命令同样扣积分
 *   注: 玩家侧无任何 sm_points* 聊天/控制台命令 (控制台调用原功能命令不扣积分);
 *       以下为管理员控制台命令:
 *   sm_asrd_points_toggle       管理员: 一键切换积分机制开关 (不带参数=反转当前状态; 0=关 1=开)。
 *                                   关闭后玩家无法使用任何购买命令 (也不免费放行), 击杀不再计分, HUD 隐藏
 *   sm_asrd_points_mult <倍率>  管理员: 设置积分购买倍率 (例如 10=所有物品价格x10, 0.5=半价);
 *                                   仅缩放购买花费, 不影响击杀计分
 *
 *  ── 常用 ConVar (自动生成 cfg/sourcemod/asrd_points.cfg) ──
 *   sm_asrd_points_enabled    总开关 (0=关 1=开, 默认 1)
 *   sm_asrd_points_cost_mult  积分购买倍率 (默认 1.0; 所有物品购买价格按此倍率缩放, 例如设 10 = 价格x10; 0.5 = 半价)
 *   sm_asrd_points_start      每局初始积分 (默认 1000; 开局/换图时重置)
 *   sm_asrd_points_hp_scale   击杀积分 = 虫族最大血量 x 倍率 (默认 0.05, 最少 1 分)
 *   sm_asrd_points_nuke_cost  核弹价格 (默认 200, 0=不设门槛)
 *   sm_asrd_points_nuke_cooldown 核弹购买冷却秒数 (默认 3; 同一玩家购买后
 *                                此时间内不能再购买核弹; 0=不限制)
 *   sm_asrd_points_betray_cost 叛变虫群价格 (默认 100, 0=不设门槛)
 *   sm_asrd_points_power_cost 强化等级价格 (默认 400, 0=不设门槛)
 *   sm_asrd_points_sentry_cost 强化哨戒塔价格 (默认 300, 0=不设门槛)
 *   sm_asrd_points_refill_cost 补充全部哨戒塔弹药价格 (默认 500, 0=不设门槛)
 *   sm_asrd_points_chainsaw_cost 增强电锯价格 (默认 300, 0=不设门槛)
 *   sm_asrd_points_rifle_cost  守望者脉冲步枪价格 (默认 300, 0=不设门槛)
 *   sm_asrd_points_ammohead_cost 头顶弹药箱价格 (默认 300, 0=不设门槛; 由 asrd_ammohead 放置标准弹药箱)
 *   sm_asrd_points_ammodrop_cost 弹药箱价格 (默认 300, 0=不设门槛; 本插件在玩家身前地面掉落原版弹药箱)
 *   sm_asrd_points_hud        积分显示开关 (0=关 1=开, 默认 1)
 *   sm_asrd_points_hud_channel HUD 通道 (默认 6, 避开 4=哨戒塔/X-33, 5=核弹)
 *   sm_asrd_points_hud_x      横向位置 (默认 0.01 左上角; -1=居中)
 *   sm_asrd_points_hud_y      纵向位置 (默认 0.02)
 *   sm_asrd_points_hud_alpha  文字透明度 (默认 170 半透明; 0=全透明 255=不透明)
 *   sm_asrd_points_debug      调试输出 (默认 0)
 *   sm_asrd_points_join_help  玩家进服后私聊发送欢迎与 /buy 用法提示 (默认 1; 0=不通知)
 *
 *  依赖: SourceMod 1.11+ (核心 + sdktools + sdkhooks)
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>
#include <sdktools_trace>
#include <sdkhooks>
#include <events>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] Points"
#define PLUGIN_VERSION "1.22.0"

// 与 asrd_ammohead 联动: 玩家 /buy 7 经此 native 在"自己"头顶放置标准(游戏默认)弹药箱。
// native 由 asrd_ammohead 注册; 本插件用 MarkNativeAsOptional 标记为可选,
// 即使 ammohead 未加载也不影响其它购买功能 (购买前用 GetFeatureStatus 判断可用与否)。
native int ASRDAmmoHead_PlaceDefaultOnClient(int client);

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

// ─── 快捷指令编号上限: /1 ~ /8 与 /buy 1 ~ /buy 8 一一对应 ─
#define BUY_ITEM_MAX         8

// ─── /buy 8 掉落弹药箱: 在玩家身前地面生成一个原版 asw_ammo_drop ─
//   AMMO_DROP_UNITS = 游戏原版弹药量, 见 RD 源码 asw_ammo_drop_shared.h
//   "DEFAULT_AMMO_DROP_UNITS 100" (CASW_Ammo_Drop 构造默认值)。
//   弹药箱本身完全沿用原版: 模型/碰撞/使用逻辑/用光(<=0)自动移除均不变。
#define AMMO_DROP_CLASSNAME  "asw_ammo_drop"
#define AMMO_DROP_UNITS      100     // = DEFAULT_AMMO_DROP_UNITS (游戏原版弹药量, 有限非无限)
#define AMMO_DROP_FORWARD    60.0    // 生成点相对玩家前移距离 (与 /buy 6 掉落武器一致)
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
ConVar g_cvCostMult;     // 积分购买倍率 (缩放所有物品价格)
ConVar g_cvStart;
ConVar g_cvHpScale;
ConVar g_cvNukeCost;
ConVar g_cvNukeCooldown;
ConVar g_cvBetrayCost;
ConVar g_cvPowerCost;
ConVar g_cvSentryCost;
ConVar g_cvRefillCost;
ConVar g_cvChainsawCost;  // 第 6 类 武器箱 6 1: 增强电锯的积分价格
ConVar g_cvRifleCost;     // 第 6 类 武器箱 6 2: 守望者脉冲步枪的积分价格
ConVar g_cvAmmoHeadCost;  // 第 7 类 头顶弹药箱: 标准弹药箱放到自己头顶的积分价格
ConVar g_cvAmmoDropCost;  // 第 8 类 弹药箱: 在玩家身前地面掉落一个原版弹药箱的积分价格
ConVar g_cvHud;
ConVar g_cvHudChannel;
ConVar g_cvHudX;
ConVar g_cvHudY;
ConVar g_cvHudAlpha;
ConVar g_cvDebug;
ConVar g_cvJoinHelp;

// ─── 积分池与 HUD 状态 ──────────────────────────────────
int    g_iPoints;
float  g_fLastHudCheck;         // HUD 帧回调节流时间 (秒)
int    g_iPlayerLevel[MAXPLAYERS + 1];   // 强化等级镜像, 与 asrd_marine_power 同步, 用于满/低级别拦截扣分
float  g_fJoinHelpAt[MAXPLAYERS + 1];    // 进服购买说明的待发时刻 (GetEngineTime; 0=无待发)
float  g_fNukeBuyTime[MAXPLAYERS + 1];   // 每位玩家上次购买核弹的时刻 (GetEngineTime; 用于核弹购买冷却)

// ============================================================================
//  插件信息
// ============================================================================
public Plugin myinfo = {
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "AS:RD 全队共享积分: 击杀虫族得分, 积分购买核弹/叛变虫群/强化等级/武器箱",
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
    g_cvCostMult = CreateConVar(
        "sm_asrd_points_cost_mult", "1.0",
        "积分购买倍率: 所有物品购买价格按此倍率缩放 (例如 10 = 价格x10; 0.5 = 半价; 0=全部免费)",
        FCVAR_NOTIFY, true, 0.0, true, 1000.0
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
        "sm_asrd_points_nuke_cost", "200",
        "核弹(sm_nukepub)积分价格 (0=不设积分门槛)",
        FCVAR_NOTIFY, true, 0.0
    );
    g_cvNukeCooldown = CreateConVar(
        "sm_asrd_points_nuke_cooldown", "3",
        "核弹购买冷却秒数: 同一玩家购买核弹后此时间内不能再购买 (0=不限制)",
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
        "补充全部哨戒塔弹药(/buy 5)积分价格 (0=不设积分门槛)",
        FCVAR_NOTIFY, true, 0.0
    );
    g_cvChainsawCost = CreateConVar(
        "sm_asrd_points_chainsaw_cost", "300",
        "增强电锯(sm_chainsawdrop)积分价格 (0=不设积分门槛)",
        FCVAR_NOTIFY, true, 0.0
    );
    g_cvRifleCost = CreateConVar(
        "sm_asrd_points_rifle_cost", "300",
        "守望者脉冲步枪(sm_watcherdrop)积分价格 (0=不设积分门槛)",
        FCVAR_NOTIFY, true, 0.0
    );
    g_cvAmmoHeadCost = CreateConVar(
        "sm_asrd_points_ammohead_cost", "300",
        "头顶弹药箱(/buy 7)积分价格: 在玩家自己头顶放置标准(游戏默认/有限)弹药箱 (0=不设积分门槛)",
        FCVAR_NOTIFY, true, 0.0
    );
    g_cvAmmoDropCost = CreateConVar(
        "sm_asrd_points_ammodrop_cost", "300",
        "弹药箱(/buy 8)积分价格: 在玩家身前地面掉落一个原版弹药箱 (0=不设积分门槛)",
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
    g_cvJoinHelp = CreateConVar(
        "sm_asrd_points_join_help", "1",
        "玩家连接后私聊通知购买用法 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    // 自动保存/读取配置到 cfg/sourcemod/asrd_points.cfg
    AutoExecConfig(true, "asrd_points");

    // 管理员命令: 一键切换积分机制开关 / 设置积分购买倍率
    RegAdminCmd("sm_asrd_points_toggle", Cmd_TogglePoints, ADMFLAG_GENERIC,
        "一键切换积分机制开关: 不带参数=反转当前状态; 0=关(禁止购买) 1=开");
    RegAdminCmd("sm_asrd_points_mult", Cmd_SetMult, ADMFLAG_GENERIC,
        "设置积分购买倍率: sm_asrd_points_mult <倍率> (例如 10 = 所有物品价格x10; 0.5 = 半价)");

    // 无注册命令: /buy、/1~/5 等聊天框购买统一走 OnClientSayCommand (同一份逻辑);
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

// 标记与 asrd_ammohead 联动的 native 为可选: 即使 ammohead 插件未加载,
// 本插件也能正常编译与运行 (/buy 7 会在购买前用 GetFeatureStatus 判断并优雅拒绝)。
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	MarkNativeAsOptional("ASRDAmmoHead_PlaceDefaultOnClient");
	return APLRes_Success;
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

    // 守望者脉冲步枪 (asw_weapon_ar2) 与副武器能量球 (prop_combine_ball):
    // 这类非常规武器的伤害 attacker 通常是武器/球实体而非 marine, 需先取持有者
    // (marine) 再解析操控它的玩家, 否则用这把步枪造成的击杀不计分。
    if (StrEqual(cls, "asw_weapon_ar2", false) || StrEqual(cls, "prop_combine_ball", false))
        return GetRifleOwnerClient(attacker);

    if (!StrEqual(cls, "asw_marine", false) && !IsAlienClass(cls))
        return 0;

    return GetCommanderClient(attacker);
}

// ============================================================================
//  守望者脉冲步枪 / 能量球的归属解析: 把武器或球实体解析为操控它的玩家
//   (仅在 ResolveKillerClient 判定 attacker 是 asw_weapon_ar2 / prop_combine_ball 时调用)
//   归属字段沿用本仓库 asrd_watcher_pulse_rifle 已验证的读法:
//     m_hOwnerEntity (Send) -> m_hOwner (Data) -> m_hOwnerEntity (Data)
//   持有者可能是 marine 实体 / 玩家 client / 武器本体(能量球归属直接是武器), 逐个归一化
// ============================================================================
int GetRifleOwnerClient(int ent)
{
    int owner = -1;
    if (HasEntProp(ent, Prop_Send, "m_hOwnerEntity"))
    {
        owner = GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity");
        if (owner > 0 && IsValidEntity(owner))
            return NormalizeRifleOwner(owner);
    }
    if (HasEntProp(ent, Prop_Data, "m_hOwner"))
    {
        owner = GetEntPropEnt(ent, Prop_Data, "m_hOwner");
        if (owner > 0 && IsValidEntity(owner))
            return NormalizeRifleOwner(owner);
    }
    if (HasEntProp(ent, Prop_Data, "m_hOwnerEntity"))
    {
        owner = GetEntPropEnt(ent, Prop_Data, "m_hOwnerEntity");
        if (owner > 0 && IsValidEntity(owner))
            return NormalizeRifleOwner(owner);
    }
    return 0;
}

// 把持有者实体 (marine / 玩家 client / 武器本体) 归一化为玩家 client (0=无归属)
int NormalizeRifleOwner(int owner)
{
    if (owner <= 0 || !IsValidEntity(owner))
        return 0;

    if (owner <= MaxClients)
        return IsUsableClient(owner) ? owner : 0;

    char cls[64];
    GetEntityClassname(owner, cls, sizeof(cls));

    if (StrEqual(cls, "asw_marine", false))
        return GetCommanderClient(owner);   // marine -> 操控它的玩家

    if (StrEqual(cls, "asw_weapon_ar2", false))
        return GetRifleOwnerClient(owner);  // 能量球归属直接是武器本体, 再取武器的持有者

    return 0;
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
//  玩家在聊天框输入 /buy、/1~/5、/nukepub、/betraypub、/power_up 等,
//  全部在此解析: 校验 → 扣分 → 转发给原插件命令执行。
//  /1~/5 与 /buy <编号> 完全等价 (可带选项), 见 HandleBuyItem()。
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

    // ── 积分机制关闭: 所有购买相关聊天命令统一拦截 (已禁用则不允许购买, 也不免费放行) ──
    if (!g_cvEnabled.BoolValue && IsPointsCommand(sCmd))
    {
        PrintToChat(client, "\x04[积分]\x01 积分机制已关闭, 暂时无法购买任何物品");
        return Plugin_Handled;
    }

    // ── /buy <编号> [选项] 与快捷指令 /1 ~ /8 走**同一套逻辑** ──
    //    /buy 3 2  等价于  /3 2       (编号后的选项位置不同, 统一收进 sOpt)
    if (StrEqual(sCmd, "buy", false) || IsBuyShortcut(sCmd))
    {
        char sOpt[16];
        sOpt[0] = '\0';
        int iItem = -1;

        if (StrEqual(sCmd, "buy", false))
        {
            char sA1[16];
            if (!GetArgFromString(sText, 1, sA1, sizeof(sA1)))
            {
                ShowBuyHelp(client);
                return Plugin_Handled;
            }
            if (IsNumericArg(sA1))
                iItem = StringToInt(sA1);
            GetArgFromString(sText, 2, sOpt, sizeof(sOpt));   // 选项可缺省
        }
        else
        {
            iItem = StringToInt(sCmd);                        // IsBuyShortcut() 已保证是 1..6
            GetArgFromString(sText, 1, sOpt, sizeof(sOpt));   // 快捷指令的选项紧跟命令
        }

        HandleBuyItem(client, iItem, sOpt);
        return Plugin_Handled;
    }

    if (StrEqual(sCmd, "nukepub", false))
    {
        char sRest[64];
        JoinArgsFrom(sText, 1, sRest, sizeof(sRest));
        BuyNukeFromChat(client, sRest);
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

// ============================================================================
//  快捷指令 /1 ~ /8: 判定 + 与 /buy 共用的分发入口
// ============================================================================
bool IsBuyShortcut(const char[] sCmd)
{
    for (int i = 1; i <= BUY_ITEM_MAX; i++)
    {
        char sNum[4];
        IntToString(i, sNum, sizeof(sNum));
        if (StrEqual(sCmd, sNum, false))
            return true;
    }
    return false;
}

// 参数是否为纯数字 (允许正负号): 防止 /4 abc 被 StringToInt 静默当成 0 而误购
bool IsNumericArg(const char[] s)
{
    int n = strlen(s);
    if (n <= 0)
        return false;

    for (int i = 0; i < n; i++)
    {
        if (i == 0 && (s[i] == '-' || s[i] == '+'))
            continue;
        if (s[i] < '0' || s[i] > '9')
            return false;
    }
    return true;
}

// ============================================================================
//  积分机制是否关闭: 聊天框购买相关命令判定
//  (buy / 1~8 快捷 / nukepub / betraypub / power_up / power_down 全部拦截)
// ============================================================================
bool IsPointsCommand(const char[] sCmd)
{
    if (StrEqual(sCmd, "buy", false) || StrEqual(sCmd, "nukepub", false)
        || StrEqual(sCmd, "betraypub", false) || StrEqual(sCmd, "power_up", false)
        || StrEqual(sCmd, "power_down", false))
        return true;
    if (IsBuyShortcut(sCmd))   // /1 ~/8 与 /buy 1~/8 等价, 一并拦截
        return true;
    return false;
}

// ============================================================================
//  积分购买倍率: 把单个物品的积分价格按 sm_asrd_points_cost_mult 缩放
//    raw<=0 (免费门槛) 直接返回原值; 否则 = round(raw x 倍率)
// ============================================================================
int GetScaledCost(ConVar cv)
{
    int iRaw = cv.IntValue;
    if (iRaw <= 0)
        return iRaw;
    float fMult = g_cvCostMult.FloatValue;
    int iCost = RoundToNearest(float(iRaw) * fMult);
    if (iCost < 0)
        iCost = 0;
    return iCost;
}

// ============================================================================
//  管理员命令: sm_asrd_points_toggle —— 一键切换积分机制开关
//    不带参数 = 反转当前状态; 0 = 关闭(禁止购买) 1 = 开启
//    关闭后: 击杀不计分 / HUD 隐藏 / 玩家无法用任何购买命令 (也不免费放行)
// ============================================================================
public Action Cmd_TogglePoints(int client, int args)
{
    int iNew;
    if (args >= 1)
    {
        char sArg[8];
        GetCmdArg(1, sArg, sizeof(sArg));
        if (StrEqual(sArg, "0", false))
            iNew = 0;
        else if (StrEqual(sArg, "1", false))
            iNew = 1;
        else
            iNew = g_cvEnabled.BoolValue ? 0 : 1;
    }
    else
    {
        iNew = g_cvEnabled.BoolValue ? 0 : 1;
    }

    g_cvEnabled.IntValue = iNew;
    RefreshHud();   // 开启即恢复 HUD; 关闭即清掉残留 HUD 文字

    if (iNew == 0)
        PrintToChatAll("\x04[积分]\x01 积分机制已关闭: 玩家无法再购买任何物品 (击杀不再计分, 积分显示已隐藏)");
    else
        PrintToChatAll("\x04[积分]\x01 积分机制已开启: 击杀计分 / 积分购买 / HUD 显示恢复正常");

    if (g_cvDebug.BoolValue)
        PrintToServer("[积分][debug] %N 将积分机制切换为 %d", client, iNew);

    return Plugin_Handled;
}

// ============================================================================
//  管理员命令: sm_asrd_points_mult <倍率> —— 设置积分购买倍率
//    仅缩放购买花费, 不影响击杀计分。例如 10 = 所有物品价格x10, 0.5 = 半价
// ============================================================================
public Action Cmd_SetMult(int client, int args)
{
    if (args < 1)
    {
        PrintToChat(client, "\x04[积分]\x01 用法: sm_asrd_points_mult <倍率>  (当前倍率 %.2f)",
            g_cvCostMult.FloatValue);
        return Plugin_Handled;
    }

    char sArg[16];
    GetCmdArg(1, sArg, sizeof(sArg));
    float fVal = StringToFloat(sArg);
    if (fVal < 0.0)
    {
        PrintToChat(client, "\x04[积分]\x01 倍率不能为负数");
        return Plugin_Handled;
    }

    g_cvCostMult.FloatValue = fVal;
    PrintToChatAll("\x04[积分]\x01 积分购买倍率已设为 \x05%.2f\x01 (所有物品购买价格按此倍率缩放)", fVal);

    if (g_cvDebug.BoolValue)
        PrintToServer("[积分][debug] %N 将积分购买倍率设为 %.2f", client, fVal);

    return Plugin_Handled;
}

// ============================================================================
//  /buy <编号> [选项] 的统一实现 (唯一扣分入口), 快捷 /编号 亦调用此处
//    iItem  1=强化 2=核弹 3=虫群 4=哨戒塔箱 5=补弹药; 其它 → 编号无效提示
//    sOpt   编号之后的选项 (可缺省; 空串 = 未指定)
// ============================================================================
void HandleBuyItem(int client, int iItem, const char[] sOpt)
{
    switch (iItem)
    {
        case 1:
            BuyPowerFromChat(client, true);

        case 2:
            BuyNukeFromChat(client, "");

        case 3:
        {
            // /buy 3 [1-6] 与 /3 [1-6]: 缺省 = 1 (工蜂×10)
            int iVar = 1;
            if (sOpt[0] != '\0')
            {
                if (!IsNumericArg(sOpt))
                {
                    PrintToChat(client, "\x04[积分]\x01 选项必须是数字: /buy 3 [1-6] 或 /3 [1-6]");
                    return;
                }
                iVar = StringToInt(sOpt);
            }
            if (iVar < 1 || iVar > BUY_BETRAY_VARIANTS)
            {
                PrintToChat(client, "\x04[积分]\x01 /buy 3 选项: 1=工蜂 2=蜂群 3=游侠 4=盾甲虫 5=迫击炮虫 6=治疗虫");
                return;
            }

            char sBetray[64];
            Format(sBetray, sizeof(sBetray), "%s %d", g_sBetrayAlias[iVar], g_iBetrayCount[iVar]);
            PurchaseFromChat(client, "sm_betraypub", sBetray, g_cvBetrayCost,
                "叛变虫群", "sm_asrd_betray_enabled", "sm_asrd_betray_public");
        }

        case 4:
        {
            // /buy 4 [0/1] 与 /4 [0/1]: 强化哨戒塔箱 (0=机枪 1=炮塔; 喷火/冰冻暂不支持)
            bool bHasOpt = (sOpt[0] != '\0');
            int  iType   = 0;                       // 未指定编号 → 默认 0=机枪
            if (bHasOpt)
            {
                if (!IsNumericArg(sOpt))
                {
                    PrintToChat(client, "\x04[积分]\x01 选项必须是数字: /buy 4 <0/1> (0=机枪 1=炮塔)");
                    return;
                }
                iType = StringToInt(sOpt);
            }
            if (iType < 0 || iType > BUY_SENTRY_VARIANTS_MAX)
            {
                PrintToChat(client, "\x04[积分]\x01 /buy 4 编号无效: 0=机枪 1=炮塔 (喷火/冰冻暂不支持)");
                return;
            }
            if (!bHasOpt)
                PrintToChat(client, "\x04[积分]\x01 未指定编号, 默认购买 0=机枪 (炮塔: \x05/buy 4 1\x01 或 \x05/4 1\x01)");

            char sTypeArg[8];
            IntToString(iType, sTypeArg, sizeof(sTypeArg));

            char sFeature[32];
            Format(sFeature, sizeof(sFeature), "强化哨戒塔(%s)", iType == 0 ? "机枪" : "炮塔");

            PurchaseFromChat(client, "sm_sentrydrop", sTypeArg, g_cvSentryCost,
                sFeature, "sm_asrd_sentry_enabled", "sm_asrd_sentry_drop_public");
            return;
        }

        case 5:
        {
            // /buy 5 与 /5: 补充全部哨戒塔弹药 (底层命令实际补满生命与弹药)
            // 先查地图上有没有塔: 一座都没有就别让玩家白扣 refill_cost 分
            if (CountMapSentries() <= 0)
            {
                PrintToChat(client, "\x04[积分]\x01 地图上目前没有任何哨戒塔, 不能购买【%s】", "补充全部哨戒塔弹药");
                return;
            }

            PurchaseFromChat(client, "sm_sentry_refill", "", g_cvRefillCost,
                "补充全部哨戒塔弹药", "sm_asrd_sentry_enabled", "sm_asrd_sentry_refill_public");
            return;
        }

        case 6:
        {
            // /buy 6 [1|2] 与 /6 [1|2]: 第 6 类 = 武器箱
            //   6 1 = 增强电锯 (sm_chainsawdrop)
            //   6 2 = 守望者脉冲步枪 (sm_watcherdrop)
            int iSub = -1;
            if (sOpt[0] != '\0')
            {
                if (!IsNumericArg(sOpt))
                {
                    PrintToChat(client, "\x04[积分]\x01 选项必须是数字: /buy 6 <1|2> (1=增强电锯 2=守望者脉冲步枪)");
                    return;
                }
                iSub = StringToInt(sOpt);
            }

            switch (iSub)
            {
                case 1:
                {
                    PurchaseFromChat(client, "sm_chainsawdrop", "", g_cvChainsawCost,
                        "增强电锯", "sm_asrd_chainsaw_enabled", "sm_asrd_chainsaw_drop_public");
                }
                case 2:
                {
                    PurchaseFromChat(client, "sm_watcherdrop", "", g_cvRifleCost,
                        "守望者脉冲步枪", "sm_asrd_watcher_enabled", "sm_asrd_watcher_drop_public");
                }
                default:
                {
                    PrintToChat(client, "\x04[积分]\x01 第 6 类 武器箱: \x05/buy 6 1\x01 增强电锯 (%d 分)   \x05/buy 6 2\x01 守望者脉冲步枪 (%d 分)",
                        GetScaledCost(g_cvChainsawCost), GetScaledCost(g_cvRifleCost));
                    PrintToChat(client, "\x04[积分]\x01 快捷指令: \x05/6 1\x01 电锯   \x05/6 2\x01 脉冲步枪");
                }
            }
            return;
        }

        case 7:
        {
            // /buy 7 与 /7: 头顶弹药箱 (标准弹药, 放到自己头顶)
            BuyAmmoHead(client);
            return;
        }

        case 8:
        {
            // /buy 8 与 /8: 弹药箱 (在玩家身前地面掉落一个原版弹药箱)
            BuyAmmoDrop(client);
            return;
        }

        default:
            PrintToChat(client, "\x04[积分]\x01 /buy 编号无效, 输入 \x05/buy\x01 查看格式");
    }
}

// ============================================================================
//  核弹购买 (统一入口: /buy 2、/2、/nukepub)
//    冷却: 同一玩家购买核弹后 nuke_cooldown 秒内不能再购买 (默认 3, 0=不限制)
//    冷却仅作用于"扣分路径" (积分开启且价格>0); 积分关闭/免费时不拦截,
//    由原插件自行处理, 保持原有行为
// ============================================================================
void BuyNukeFromChat(int client, const char[] sArgs)
{
    if (g_cvEnabled.BoolValue && g_cvNukeCost.IntValue > 0 &&
        g_cvNukeCooldown.FloatValue > 0.0 && g_fNukeBuyTime[client] > 0.0)
    {
        float fElapsed = GetEngineTime() - g_fNukeBuyTime[client];
        if (fElapsed < g_cvNukeCooldown.FloatValue)
        {
            int iLeft = RoundToCeil(g_cvNukeCooldown.FloatValue - fElapsed);
            PrintToChat(client, "\x04[积分]\x01 核弹倒计时中, 请 \x05%d\x01 秒后再购买", iLeft);
            return;
        }
    }
    if (PurchaseFromChat(client, "sm_nukepub", sArgs, g_cvNukeCost,
        "核弹", "sm_asrd_nuke_enabled", "sm_asrd_nuke_public"))
        g_fNukeBuyTime[client] = GetEngineTime();
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
        // 积分机制关闭: 禁止购买 (聊天入口已拦截, 这里做兜底)
        if (!g_cvEnabled.BoolValue)
        {
            PrintToChat(client, "\x04[积分]\x01 积分机制已关闭, 暂时无法购买强化体型调整");
            return;
        }
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

// ============================================================================
//  头顶弹药箱购买 (/buy 7): 经 asrd_ammohead 的 native 在玩家自己头顶放置
//  "标准(游戏默认)"弹药箱。
//    - 弹药量 = 游戏默认 (asrd_ammohead 内部固定 percent_remaining=100, 有限非无限)
//    - 同一陆战队员头顶同时只能有 1 个 (插件内部放置前会替换旧的)
//    - 不叠加、不无限: 满足"积分购买的弹药箱不能是无限弹药"与"保持原版属性"
//  前置: asrd_ammohead 已加载 (native 可用) 且 sm_asrd_ammohead_enabled/public 开启
// ============================================================================
void BuyAmmoHead(int client)
{
    // 原插件(ammohead)是否已加载? native 可用才放行
    if (GetFeatureStatus(FeatureType_Native, "ASRDAmmoHead_PlaceDefaultOnClient") != FeatureStatus_Available)
    {
        PrintToChat(client, "\x04[积分]\x01 头顶弹药箱插件未加载, 无法购买");
        return;
    }

    // 原插件总开关
    ConVar cvEnabled = FindConVar("sm_asrd_ammohead_enabled");
    if (cvEnabled != null && !cvEnabled.BoolValue)
    {
        PrintToChat(client, "\x04[积分]\x01 头顶弹药箱功能已禁用");
        return;
    }

    // 对玩家开放开关
    ConVar cvPublic = FindConVar("sm_asrd_ammohead_public");
    if (cvPublic == null || !cvPublic.BoolValue)
    {
        PrintToChat(client, "\x04[积分]\x01 头顶弹药箱未对玩家开放 (管理员需设置 sm_asrd_ammohead_public 1)");
        return;
    }

    if (!IsActivePlayer(client))
    {
        PrintToChat(client, "\x04[积分]\x01 不在游戏中的玩家不能购买, 请先加入游戏");
        return;
    }

    // 积分机制关闭: 禁止购买 (聊天入口已拦截, 这里做兜底)
    if (!g_cvEnabled.BoolValue)
    {
        PrintToChat(client, "\x04[积分]\x01 积分机制已关闭, 暂时无法购买头顶弹药箱");
        return;
    }

    int iCost = GetScaledCost(g_cvAmmoHeadCost);
    // 价格=0: 不设门槛, 直接放置(仍受 ammohead 内部"唯一+标准"约束)
    if (iCost <= 0)
    {
        ASRDAmmoHead_PlaceDefaultOnClient(client);
        PrintToChatAll("\x04[积分]\x01 %N 获得【头顶弹药箱】(无积分门槛)", client);
        return;
    }
    if (g_iPoints < iCost)
    {
        PrintToChat(client, "\x04[积分]\x01 积分不足: 头顶弹药箱需要 \x05%d\x01 积分, 当前 \x05%d\x01 积分",
            iCost, g_iPoints);
        return;
    }

    g_iPoints -= iCost;
    RefreshHud();
    PrintToChatAll("\x04[积分]\x01 %N 花费 \x05%d\x01 积分购买【头顶弹药箱】, 剩余 \x05%d\x01 积分",
        client, iCost, g_iPoints);

    ASRDAmmoHead_PlaceDefaultOnClient(client);
}

// ============================================================================
//  弹药箱购买 (/buy 8): 在玩家(其陆战队员)身前地面掉落一个"原版"弹药箱。
//  本功能直接实现在积分插件内, 不依赖任何其它插件 (不像 /buy 6/7 需转发)。
//    - 实体 = asw_ammo_drop, 弹药量 = AMMO_DROP_UNITS(100) = 游戏原版默认
//      (RD 源码 asw_ammo_drop_shared.h: DEFAULT_AMMO_DROP_UNITS = 100)
//    - 除位置外完全沿用原版属性: 模型/碰撞/使用逻辑/用光(<=0)自动移除均不变
//    - 有限、非无限 (与头顶弹药箱一致)
// ============================================================================
void BuyAmmoDrop(int client)
{
    // 不在游戏中 (未控制任何陆战队员) 的玩家不能消费积分 / 也没有落点
    if (!IsActivePlayer(client))
    {
        PrintToChat(client, "\x04[积分]\x01 不在游戏中的玩家不能购买, 请先加入游戏");
        return;
    }

    // 积分机制关闭: 禁止购买 (聊天入口已拦截, 这里做兜底)
    if (!g_cvEnabled.BoolValue)
    {
        PrintToChat(client, "\x04[积分]\x01 积分机制已关闭, 暂时无法购买弹药箱");
        return;
    }

    int iCost = GetScaledCost(g_cvAmmoDropCost);

    // 先校验积分, 不足则不生成、不扣分
    if (iCost > 0 && g_iPoints < iCost)
    {
        PrintToChat(client, "\x04[积分]\x01 积分不足: 弹药箱需要 \x05%d\x01 积分, 当前 \x05%d\x01 积分",
            iCost, g_iPoints);
        return;
    }

    // 先生成: 生成失败(如无有效落点)就别扣分
    int iBox = SpawnAmmoDropNear(client);
    if (iBox <= 0)
    {
        PrintToChat(client, "\x04[积分]\x01 弹药箱生成失败 (请确认自己已控制陆战队员)");
        return;
    }

    if (iCost > 0)
    {
        g_iPoints -= iCost;
        RefreshHud();
        PrintToChatAll("\x04[积分]\x01 %N 花费 \x05%d\x01 积分购买【弹药箱】, 剩余 \x05%d\x01 积分",
            client, iCost, g_iPoints);
    }
    else
    {
        PrintToChatAll("\x04[积分]\x01 %N 获得【弹药箱】(无积分门槛)", client);
    }
}

// ============================================================================
//  在玩家(其陆战队员)身前地面生成一个原版 asw_ammo_drop
//    - 落点: 身前 AMMO_DROP_FORWARD(60) 单位, 再向下探测地面贴地放置(与原版掉落一致)
//    - 返回实体索引 (>0=成功, -1=失败)
//  关键顺序: 先 Teleport 到落点, 再 DispatchSpawn —— 因为 CASW_Ammo_Drop::Spawn()
//  会用 GetAbsOrigin() 做一次贴地/电梯挂接的射线检测, 位置必须先就位。
// ============================================================================
int SpawnAmmoDropNear(int client)
{
    int iMarine = GetClientMarine(client);
    if (iMarine <= 0)
        return -1;

    // 落点 = 陆战队员脚下原点 沿其视角水平前方偏移 (与 asrd_watcher 掉落武器同一算法)
    float fPos[3], fAng[3];
    GetEntPropVector(iMarine, Prop_Data, "m_vecAbsOrigin", fPos);
    GetClientEyeAngles(client, fAng);
    float fYaw = DegToRad(fAng[1]);
    fPos[0] += Cosine(fYaw) * AMMO_DROP_FORWARD;
    fPos[1] += Sine(fYaw) * AMMO_DROP_FORWARD;

    // 从落点上方往下打一条只与场景几何(BRUSH)作用的射线: 命中则把箱子贴到地面,
    // 未命中(悬空/探测失败)则退回"落点上方 20 单位", 与原版掉落观感一致。
    float fStart[3], fEnd[3];
    fStart[0] = fPos[0]; fStart[1] = fPos[1]; fStart[2] = fPos[2] + 64.0;
    fEnd[0]   = fPos[0]; fEnd[1]   = fPos[1]; fEnd[2]   = fPos[2] - 512.0;
    TR_TraceRayFilter(fStart, fEnd, MASK_SOLID_BRUSHONLY, RayType_EndPoint, TraceFilter_AmmoDrop);
    if (TR_DidHit())
    {
        float fHit[3];
        TR_GetEndPosition(fHit);
        fPos[2] = fHit[2];
    }
    else
    {
        fPos[2] += 20.0;
    }

    int iBox = CreateEntityByName(AMMO_DROP_CLASSNAME);
    if (iBox == -1)
    {
        if (g_cvDebug.BoolValue)
            PrintToServer("[积分][debug] CreateEntityByName(%s) 失败 (实体未注册?)", AMMO_DROP_CLASSNAME);
        return -1;
    }

    char sUnits[16];
    IntToString(AMMO_DROP_UNITS, sUnits, sizeof(sUnits));
    DispatchKeyValue(iBox, "percent_remaining", sUnits);   // 100 = 游戏原版默认弹药量

    // 先就位再 DispatchSpawn (见函数头注释)
    TeleportEntity(iBox, fPos, NULL_VECTOR, NULL_VECTOR);
    DispatchSpawn(iBox);

    return iBox;
}

// 弹药箱贴地射线过滤器: 忽略所有实体, 只让场景几何(brush/world)参与碰撞
// (MASK_SOLID_BRUSHONLY 下 world/brush 不受 filter 影响, 故恒返回 false 即可)
public bool TraceFilter_AmmoDrop(int entity, int contentsMask, any data)
{
    return false;
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
    // 积分机制关闭: 禁止购买 (聊天入口已拦截, 这里做兜底)
    if (!g_cvEnabled.BoolValue)
    {
        PrintToChat(client, "\x04[积分]\x01 积分机制已关闭, 暂时无法购买强化加血");
        return;
    }

    int iCostML = GetScaledCost(g_cvPowerCost);
    // 价格=0: 不提供加血, 放行原插件自行处理 (会提示已达最高等级)
    if (iCostML <= 0)
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
    if (g_iPoints < iCostML)
    {
        PrintToChat(client, "\x04[积分]\x01 积分不足: 强化加血需要 \x05%d\x01 积分, 当前 \x05%d\x01 积分",
            iCostML, g_iPoints);
        return;
    }

    g_iPoints -= iCostML;
    RefreshHud();
    PrintToChatAll("\x04[积分]\x01 %N 花费 \x05%d\x01 积分购买【满级加血】, 剩余 \x05%d\x01 积分",
        client, iCostML, g_iPoints);

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

// 购买用法说明 (玩家输入 /buy 查询时显示)
void ShowBuyHelp(int client)
{
    PrintToChat(client, "欢迎 \x05%N\x01! 当前总积分: \x05%d\x01   用法: \x05/buy <编号> [选项]", client, g_iPoints);
    if (g_cvCostMult.FloatValue != 1.0)
        PrintToChat(client, "  (当前购买倍率 \x05x%.2f\x01: 以下价格已按此倍率缩放)", g_cvCostMult.FloatValue);
    PrintToChat(client, "  \x05/buy 1\x01  属性强化 +1 (%d 分; 满级后转为加血)", GetScaledCost(g_cvPowerCost));
    PrintToChat(client, "  \x05/buy 2\x01  战术核弹 (%d 分, 购买后 %d 秒内不能再买)", GetScaledCost(g_cvNukeCost), g_cvNukeCooldown.IntValue);
    PrintToChat(client, "  \x05/buy 3 [1-6]\x01  友军虫群 (%d 分): 1=工蜂 2=蜂群 3=游侠 4=盾甲虫 5=迫击炮虫 6=治疗虫", GetScaledCost(g_cvBetrayCost));
    PrintToChat(client, "  \x05/buy 4 <0/1>\x01  强化哨戒塔箱 (%d 分): 0=机枪 1=炮塔", GetScaledCost(g_cvSentryCost));
    PrintToChat(client, "  \x05/buy 5\x01  补充全部哨戒塔弹药 (%d 分)", GetScaledCost(g_cvRefillCost));
    PrintToChat(client, "  \x05/buy 6 1\x01  增强电锯 (%d 分, 掉落在身边)", GetScaledCost(g_cvChainsawCost));
    PrintToChat(client, "  \x05/buy 6 2\x01  守望者脉冲步枪 (%d 分, 掉落在身边, 击杀计积分)", GetScaledCost(g_cvRifleCost));
    PrintToChat(client, "  \x05/buy 7\x01  头顶弹药箱 (%d 分, 标准弹药放到自己头顶, 游戏默认/有限/同时仅1个)", GetScaledCost(g_cvAmmoHeadCost));
    PrintToChat(client, "  \x05/buy 8\x01  弹药箱 (%d 分, 在身前地面掉落一个原版弹药箱, 走过去补弹)", GetScaledCost(g_cvAmmoDropCost));
    PrintToChat(client, "  快捷指令: \x05/1\x01 强化   \x05/2\x01 核弹   \x05/3 [1-6]\x01 虫群   \x05/4 [0/1]\x01 哨戒塔箱   \x05/5\x01 补弹药   \x05/6 [1|2]\x01 武器箱(1=电锯 2=脉冲步枪)   \x05/7\x01 头顶弹药箱   \x05/8\x01 弹药箱");
    PrintToChat(client, "  例: \x05/3 2\x01 = /buy 3 2 (游侠)   \x05/4 1\x01 = /buy 4 1 (炮塔)   \x05/6 2\x01 = /buy 6 2 (脉冲步枪)");
    PrintToChat(client, "  积分: \x05通过击杀虫族获取\x01");
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
//  仅用于 /buy 5 的前置检查: 一座塔都没有时不允许购买, 免得白扣积分
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

    // 积分机制关闭: 整个机制禁用, 不允许购买 (聊天入口已拦截, 这里做兜底)
    if (!g_cvEnabled.BoolValue)
    {
        PrintToChat(client, "\x04[积分]\x01 积分机制已关闭, 暂时无法购买");
        return false;
    }

    int iCost = GetScaledCost(costCv);
    // 价格=0 (原始为0 或 倍率折算为0): 不设积分门槛, 直接放行原命令
    if (iCost <= 0)
    {
        FakeClientCommand(client, "%s %s", sFullCommand, sArgs);
        return true;
    }

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
//  帧回调: HUD 刷新 (0.5 秒节流) + 进服欢迎/用法提示的延迟发送
//  (不依赖 SourceMod 定时器; 本环境定时器不触发, 否则 HUD 只闪一下)
// ============================================================================
public void OnGameFrame()
{
    float fNow = GetEngineTime();

    // 进服欢迎与用法提示: 到点的玩家逐个私聊发送 (预约见 OnClientPutInServer)
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_fJoinHelpAt[i] <= 0.0 || fNow < g_fJoinHelpAt[i])
            continue;

        g_fJoinHelpAt[i] = 0.0;
        if (g_cvJoinHelp.BoolValue
            && IsClientInGame(i) && !IsFakeClient(i))
            SendJoinWelcome(i);
    }

    if (fNow - g_fLastHudCheck >= HUD_REFRESH)
    {
        g_fLastHudCheck = fNow;
        RefreshHud();
    }
}

// ============================================================================
//  进服欢迎: 仅聊天私发一行 —— 欢迎 + (积分机制开启时)提示输入 /buy 查看用法
//  (无 [积分] 前缀。详细购买命令与快捷指令由玩家输入 /buy 后经 ShowBuyHelp 显示)
//  注意: 积分机制即使关闭, 依然发送欢迎消息; 只是不再附 /buy 用法提示。
// ============================================================================
void SendJoinWelcome(int client)
{
    if (!IsClientInGame(client) || IsFakeClient(client))
        return;

    // 积分机制开启时才追加 /buy 用法提示 (关闭后 /buy 本就被拦截, 提示无意义)
    if (g_cvEnabled.BoolValue)
        PrintToChat(client, "欢迎 \x05%N\x01！请输入\x05/buy\x01查看积分使用方法。", client);
    else
        PrintToChat(client, "欢迎 \x05%N\x01！", client);
}

void RefreshHud()
{
    int iChannel = g_cvHudChannel.IntValue;

    // 积分机制或 HUD 关闭: 清掉残留的 HUD 文字, 防止关闭前显示的旧 "总积分" 仍挂在屏幕上
    if (!g_cvEnabled.BoolValue || !g_cvHud.BoolValue)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsClientInGame(i) || IsFakeClient(i))
                continue;
            ShowHudText(i, iChannel, "");
        }
        return;
    }

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
