/**
 * ============================================================================
 *  [AS:RD] 积分机制 (Points)
 *  版本 1.8.0  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ──────────────────────────────────────
 *  引入一套全队共享的积分经济:
 *    1. 击杀计分: 玩家击杀虫族获得积分, 按被杀虫族的实际最大血量计算
 *       (血量越高积分越多, 倍率见 sm_asrd_points_hp_scale, 最少 1 分)
 *    2. 积分购买: 玩家使用 sm_nukepub / sm_betraypub / sm_power_up|down 时,
 *       先扣除积分再放行给原插件执行功能
 *    3. 积分显示: 屏幕左上方常驻显示总积分, 每 0.5 秒刷新, 击杀/消费即时更新
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
 *    价格设为 0 = 该功能不设积分门槛, 维持原插件自己的开关行为。
 *    管理员命令 (sm_nuke / sm_betray / sm_power_set) 不拦截, 不受积分影响。
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
 *      / 被玩家附身的虫族(查 m_Commander), 其它来源 (核弹/哨戒塔/扫描机/
 *      虫族互杀) 不计分
 *    - 友军虫 (targetname=asrd_betray_swarm, 含玩家附身虫) 不计分, 防刷分
 *
 *  ── 命令 ────────────────────────────────────────────────
 *   sm_buy              玩家: 参数式购买 (聊天框 /buy)
 *                        /buy 1=核弹  /buy 2 [1-6]=叛变虫群  /buy 3=强化+1
 *                        /buy 2 无选项=drone×10; 无参数=显示命令格式
 *   sm_points           玩家: 查看当前总积分与功能价格
 *   sm_1 / sm_2 / sm_3  玩家: 快捷购买 核弹 / 叛变虫群(默认drone) / 强化等级
 *   sm_points_add <n>   管理员: 给积分池加 n
 *   sm_points_set <n>   管理员: 把积分池设为 n
 *   sm_points_reset     管理员: 积分池清零
 *   sm_points_status    管理员: 查看积分池与各功能价格
 *
 *  ── 常用 ConVar (自动生成 cfg/sourcemod/asrd_points.cfg) ──
 *   sm_asrd_points_enabled    总开关 (0=关 1=开, 默认 1)
 *   sm_asrd_points_start      每局初始积分 (默认 1000; 开局/换图时重置)
 *   sm_asrd_points_hp_scale   击杀积分 = 虫族最大血量 x 倍率 (默认 0.05, 最少 1 分)
 *   sm_asrd_points_nuke_cost  核弹价格 (默认 100, 0=不设门槛)
 *   sm_asrd_points_betray_cost 叛变虫群价格 (默认 100, 0=不设门槛)
 *   sm_asrd_points_power_cost 强化等级价格 (默认 200, 0=不设门槛)
 *   sm_asrd_points_hud        积分显示开关 (0=关 1=开, 默认 1)
 *   sm_asrd_points_hud_channel HUD 通道 (默认 6, 避开 4=哨戒塔/X-33, 5=核弹)
 *   sm_asrd_points_hud_x      横向位置 (默认 0.01 左上角; -1=居中)
 *   sm_asrd_points_hud_y      纵向位置 (默认 0.02)
 *   sm_asrd_points_hud_alpha  文字透明度 (默认 170 半透明; 0=全透明 255=不透明)
 *   sm_asrd_points_debug      调试输出 (默认 0)
 *   sm_asrd_points_advert     聊天公告使用说明开关 (默认 1)
 *   sm_asrd_points_advert_interval 公告间隔秒数 (默认 30)
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
#define PLUGIN_VERSION "1.8.0"

// ─── HUD 显示 (左上角, 与 4=哨戒塔/X-33、5=核弹 错开) ─────
#define HUD_CHANNEL     6
#define HUD_X           0.01
#define HUD_Y           0.02
#define HUD_HOLD        1.2
#define HUD_REFRESH     0.5

// ─── /buy 2 叛变虫群可选虫种 (别名 + 数量, 对应 asrd_alien_civilwar 的 sm_betraypub) ─
#define BUY_BETRAY_VARIANTS  6
char g_sBetrayAlias[BUY_BETRAY_VARIANTS + 1][16] = { "", "drone", "buzzer", "ranger", "shield", "mortar", "shaman" };
int  g_iBetrayCount[BUY_BETRAY_VARIANTS + 1] = { 0, 10, 20, 10, 5, 10, 5 };

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
ConVar g_cvHud;
ConVar g_cvHudChannel;
ConVar g_cvHudX;
ConVar g_cvHudY;
ConVar g_cvHudAlpha;
ConVar g_cvDebug;
ConVar g_cvAdvert;
ConVar g_cvAdvertInterval;

// ─── 积分池与 HUD 状态 ──────────────────────────────────
int    g_iPoints;
float  g_fLastHudCheck;         // HUD 帧回调节流时间 (秒)
float  g_fLastAdvert;           // 使用说明公告帧回调节流时间 (秒)
int    g_iPlayerLevel[MAXPLAYERS + 1];   // 强化等级镜像, 与 asrd_marine_power 同步, 用于满/低级别拦截扣分

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
        "sm_asrd_points_nuke_cost", "100",
        "核弹(sm_nukepub)积分价格 (0=不设积分门槛)",
        FCVAR_NOTIFY, true, 0.0
    );
    g_cvBetrayCost = CreateConVar(
        "sm_asrd_points_betray_cost", "100",
        "叛变虫群(sm_betraypub)积分价格 (0=不设积分门槛)",
        FCVAR_NOTIFY, true, 0.0
    );
    g_cvPowerCost = CreateConVar(
        "sm_asrd_points_power_cost", "200",
        "强化等级(sm_power_up/sm_power_down)积分价格 (0=不设积分门槛; sm_power_reset 免费)",
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

    // 自动保存/读取配置到 cfg/sourcemod/asrd_points.cfg
    AutoExecConfig(true, "asrd_points");

    // 玩家命令
    RegConsoleCmd("sm_points", Cmd_Points, "查看当前总积分与功能价格");
    RegConsoleCmd("sm_buy",    Cmd_Buy, "购买: /buy 1核弹 /buy 2 [虫种]虫群 /buy 3强化; 无参数显示格式");

    // 快捷购买命令: 聊天框 /1 /2 /3 (或控制台 sm_1) 直接触发对应购买,
    // 实际转发给原功能命令, 由下面的命令监听统一扣分/放行
    RegConsoleCmd("sm_1", Cmd_BuyNukeShortcut,   "快捷购买核弹 (等同 sm_nukepub)");
    RegConsoleCmd("sm_2", Cmd_BuyBetrayShortcut, "快捷购买叛变虫群 (等同 sm_betraypub)");
    RegConsoleCmd("sm_3", Cmd_BuyPowerShortcut,  "快捷强化等级 (等同 sm_power_up)");

    // 管理员命令
    RegAdminCmd("sm_points_add",    Cmd_PointsAdd,    ADMFLAG_GENERIC, "给积分池加 n (用法: sm_points_add <n>)");
    RegAdminCmd("sm_points_set",    Cmd_PointsSet,    ADMFLAG_GENERIC, "把积分池设为 n (用法: sm_points_set <n>)");
    RegAdminCmd("sm_points_reset",  Cmd_PointsReset,  ADMFLAG_GENERIC, "积分池清零");
    RegAdminCmd("sm_points_status", Cmd_PointsStatus, ADMFLAG_GENERIC, "查看积分池与各功能价格");

    // 拦截玩家功能命令: 扣积分后放行给原插件 (零修改现有插件)
    AddCommandListener(Listener_NukePub,   "sm_nukepub");
    AddCommandListener(Listener_BetrayPub, "sm_betraypub");
    AddCommandListener(Listener_PowerUp,   "sm_power_up");
    AddCommandListener(Listener_PowerDown, "sm_power_down");
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
//  玩家加入: 引导查看快捷购买指令 (屏幕 HUD 只留总积分, 帮助按需查看)
// ============================================================================
public void OnClientPutInServer(int client)
{
    PrintToChat(client, "\x04[积分]\x01 输入 \x05/buy\x01 查看快捷购买格式 (总积分: \x05%d\x01)", g_iPoints);
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
    if (!StrEqual(cls, "asw_marine", false) && !IsAlienClass(cls))
        return 0;

    return GetCommanderClient(attacker);
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
//  命令监听: sm_nukepub
// ============================================================================
public Action Listener_NukePub(int client, const char[] command, int argc)
{
    return HandlePurchase(client, command, argc, g_cvNukeCost,
        "核弹", "sm_asrd_nuke_enabled", "sm_asrd_nuke_public");
}

// ============================================================================
//  命令监听: sm_betraypub
// ============================================================================
public Action Listener_BetrayPub(int client, const char[] command, int argc)
{
    return HandlePurchase(client, command, argc, g_cvBetrayCost,
        "叛变虫群", "sm_asrd_betray_enabled", "sm_asrd_betray_public");
}

// ============================================================================
//  命令监听: sm_power_up / sm_power_down (带满/低级别保护)
//  达到等级上限/下限时直接放行给原插件(其会提示已达边界), 不扣积分;
//  可升降时才扣分, 成功后同步等级镜像避免下次误判。
// ============================================================================
public Action Listener_PowerUp(int client, const char[] command, int argc)
{
    // 已达最高等级: 不再扣分 (镜像判断; 放行让原插件提示满级)
    if (g_iPlayerLevel[client] >= GetPowerMaxLevel())
        return Plugin_Continue;

    Action act = HandlePurchase(client, command, argc, g_cvPowerCost,
        "强化等级", "sm_asrd_power_enabled", "sm_asrd_power_public");
    if (act == Plugin_Continue)
        g_iPlayerLevel[client]++;
    return act;
}

public Action Listener_PowerDown(int client, const char[] command, int argc)
{
    // 已达最小体型: 不再扣分
    if (g_iPlayerLevel[client] <= -GetPowerShrinkMax())
        return Plugin_Continue;

    Action act = HandlePurchase(client, command, argc, g_cvPowerCost,
        "强化等级", "sm_asrd_power_enabled", "sm_asrd_power_public");
    if (act == Plugin_Continue)
        g_iPlayerLevel[client]--;
    return act;
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

// 读取 asrd_marine_power 的等级上限/体型下限 (找不到时用其代码默认值)
int GetPowerMaxLevel()
{
    ConVar c = FindConVar("sm_asrd_power_max_level");
    return c != null ? c.IntValue : 5;
}

int GetPowerShrinkMax()
{
    ConVar c = FindConVar("sm_asrd_power_shrink_max");
    return c != null ? c.IntValue : 3;
}

// ============================================================================
//  购买核心: 校验 → 扣分 → 放行给原插件 (Plugin_Continue)
// ============================================================================
Action HandlePurchase(int client, const char[] command, int argc,
    ConVar costCv, const char[] sFeature,
    const char[] sEnabledCv, const char[] sPublicCv)
{
    if (client <= 0)
        return Plugin_Continue;

    // 不在游戏中 (未控制任何陆战队员: 观战/等待/未入队) 的玩家不能消耗积分
    if (!IsActivePlayer(client))
    {
        if (g_cvDebug.BoolValue)
            PrintToServer("[积分][debug] %N 队伍=%d, 拒绝购买 (未控制陆战队员)", client, GetClientTeam(client));
        ReplyToCommand(client, "\x04[积分]\x01 不在游戏中的玩家不能购买, 请先加入游戏");
        return Plugin_Handled;
    }

    if (!g_cvEnabled.BoolValue)
        return Plugin_Continue;

    int iCost = costCv.IntValue;
    if (iCost <= 0)
        return Plugin_Continue;   // 0 = 该功能不设积分门槛

    // 原插件总开关: 关着就拒绝, 不扣分
    ConVar cvEnabled = FindConVar(sEnabledCv);
    if (cvEnabled != null && !cvEnabled.BoolValue)
    {
        PrintToChat(client, "\x04[积分]\x01 %s 功能已禁用", sFeature);
        return Plugin_Handled;
    }

    // 原插件 public 开关: 未开就拒绝, 不扣分
    ConVar cvPublic = FindConVar(sPublicCv);
    if (cvPublic == null)
    {
        PrintToChat(client, "\x04[积分]\x01 %s 对应插件未加载, 无法购买", sFeature);
        return Plugin_Handled;
    }
    if (!cvPublic.BoolValue)
    {
        PrintToChat(client, "\x04[积分]\x01 %s 未对玩家开放 (管理员需设置 \x05%s\x01 1)",
            sFeature, sPublicCv);
        return Plugin_Handled;
    }

    // sm_betraypub: 扣分前预校验虫种, 防止打错字白扣积分
    if (StrEqual(command, "sm_betraypub", false) && argc >= 1)
    {
        char sArg[64];
        GetCmdArg(1, sArg, sizeof(sArg));
        if (!IsValidBetrayType(sArg))
        {
            PrintToChat(client, "\x04[积分]\x01 未知虫种 \"%s\", 用 sm_betray_list 查看可选虫种", sArg);
            return Plugin_Handled;
        }
    }

    if (g_iPoints < iCost)
    {
        PrintToChat(client, "\x04[积分]\x01 积分不足: %s 需要 \x05%d\x01 积分, 当前 \x05%d\x01 积分",
            sFeature, iCost, g_iPoints);
        return Plugin_Handled;
    }

    // 扣分并放行给原插件执行
    g_iPoints -= iCost;
    RefreshHud();
    PrintToChatAll("\x04[积分]\x01 %N 花费 \x05%d\x01 积分购买【%s】, 剩余 \x05%d\x01 积分",
        client, iCost, sFeature, g_iPoints);

    if (g_cvDebug.BoolValue)
        PrintToServer("[积分][debug] %N 购买 %s 花费 %d, 剩余 %d",
            client, sFeature, iCost, g_iPoints);

    return Plugin_Continue;
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
//  玩家命令: sm_points 查看总积分与购买引导
// ============================================================================
public Action Cmd_Points(int client, int args)
{
    char sMsg[256];
    Format(sMsg, sizeof(sMsg),
        "\x04[积分]\x01 总积分: \x05%d\x01 | 输入 \x05/buy\x01 查看命令格式\n" ...
        "快捷: \x05/buy 1\x01核弹(%d)  \x05/buy 2\x01虫群(%d)  \x05/buy 3\x01强化(%d)",
        g_iPoints, g_cvNukeCost.IntValue, g_cvBetrayCost.IntValue, g_cvPowerCost.IntValue);

    if (client > 0)
        PrintToChat(client, "%s", sMsg);
    else
        PrintToConsole(client, "%s", sMsg);

    return Plugin_Handled;
}

// ============================================================================
//  玩家命令: sm_buy 参数式购买
//   /buy           → 显示命令格式
//   /buy 1         → 战术核弹
//   /buy 2 [1-6]   → 叛变虫群 (1=drone×10 2=buzzer×20 3=ranger×10
//                     4=shieldbug×5 5=mortarbug×10 6=shaman×5; 缺省=1 drone×10)
//   /buy 3         → 强化等级 +1
//  实际转发给原功能命令, 由命令监听统一扣分/放行 (含满级保护/积分校验)
// ============================================================================
public Action Cmd_Buy(int client, int args)
{
    if (client <= 0)
        return Plugin_Handled;

    // 不在游戏中 (未控制任何陆战队员) 的玩家不能消耗积分
    if (!IsActivePlayer(client))
    {
        ReplyToCommand(client, "\x04[积分]\x01 不在游戏中的玩家不能购买, 请先加入游戏");
        return Plugin_Handled;
    }

    if (args < 1)
    {
        PrintToChat(client, "\x04[积分]\x01 命令格式: \x05/buy <编号> [选项]\x01  (总积分: \x05%d\x01)", g_iPoints);
        PrintToChat(client, "  \x05/buy 1\x01  战术核弹 (%d 分)", g_cvNukeCost.IntValue);
        PrintToChat(client, "  \x05/buy 2 [1-6]\x01  叛变虫群 (%d 分): 1=工蜂×10 2=蜂群×20 3=游侠×10 4=盾甲虫×5 5=迫击炮虫×10 6=治疗虫×5", g_cvBetrayCost.IntValue);
        PrintToChat(client, "  \x05/buy 3\x01  强化等级 +1 (%d 分)", g_cvPowerCost.IntValue);
        PrintToChat(client, "控制台也可输入 sm_buy; 输入 \x05/sm_points\x01 查看总积分");
        return Plugin_Handled;
    }

    char sArg[8];
    GetCmdArg(1, sArg, sizeof(sArg));
    int iItem = StringToInt(sArg);

    switch (iItem)
    {
        case 1:
        {
            FakeClientCommand(client, "sm_nukepub");
        }
        case 2:
        {
            int iVar = 1;   // 缺省 = drone × 10
            if (args >= 2)
            {
                GetCmdArg(2, sArg, sizeof(sArg));
                int n = StringToInt(sArg);
                if (n >= 1 && n <= BUY_BETRAY_VARIANTS)
                    iVar = n;
                else
                {
                    ReplyToCommand(client, "\x04[积分]\x01 /buy 2 选项: 1=工蜂 2=蜂群 3=游侠 4=盾甲虫 5=迫击炮虫 6=治疗虫");
                    return Plugin_Handled;
                }
            }
            FakeClientCommand(client, "sm_betraypub %s %d",
                g_sBetrayAlias[iVar], g_iBetrayCount[iVar]);
        }
        case 3:
        {
            FakeClientCommand(client, "sm_power_up");
        }
        default:
        {
            ReplyToCommand(client, "\x04[积分]\x01 /buy 编号无效, 输入 \x05/buy\x01 查看格式");
            return Plugin_Handled;
        }
    }
    return Plugin_Handled;
}

// ============================================================================
//  快捷购买: sm_1 / sm_2 / sm_3
//  直接在聊天框输入 /1 /2 /3 (控制台输入 sm_1 等), 转发给原功能命令,
//  由下方命令监听统一扣分/放行。sm_2 等价 /buy 2 1 = 10 只 drone。
// ============================================================================
public Action Cmd_BuyNukeShortcut(int client, int args)
{
    if (client <= 0)
        return Plugin_Handled;
    FakeClientCommand(client, "sm_nukepub");
    return Plugin_Handled;
}

public Action Cmd_BuyBetrayShortcut(int client, int args)
{
    if (client <= 0)
        return Plugin_Handled;
    FakeClientCommand(client, "sm_betraypub %s %d", g_sBetrayAlias[1], g_iBetrayCount[1]);
    return Plugin_Handled;
}

public Action Cmd_BuyPowerShortcut(int client, int args)
{
    if (client <= 0)
        return Plugin_Handled;
    FakeClientCommand(client, "sm_power_up");
    return Plugin_Handled;
}

// ============================================================================
//  管理员命令
// ============================================================================
public Action Cmd_PointsAdd(int client, int args)
{
    if (args < 1)
    {
        PrintToConsole(client, "用法: sm_points_add <n>");
        return Plugin_Handled;
    }

    char sArg[16];
    GetCmdArg(1, sArg, sizeof(sArg));
    int n = StringToInt(sArg);
    g_iPoints += n;
    RefreshHud();

    if (client > 0)
        PrintToChatAll("\x04[积分]\x01 %N 给积分池添加 \x05%d\x01 积分, 当前 \x05%d\x01",
            client, n, g_iPoints);
    else
        PrintToServer("[积分] 服务器管理员添加 %d 积分, 当前 %d", n, g_iPoints);
    return Plugin_Handled;
}

public Action Cmd_PointsSet(int client, int args)
{
    if (args < 1)
    {
        PrintToConsole(client, "用法: sm_points_set <n>");
        return Plugin_Handled;
    }

    char sArg[16];
    GetCmdArg(1, sArg, sizeof(sArg));
    g_iPoints = StringToInt(sArg);
    if (g_iPoints < 0)
        g_iPoints = 0;
    RefreshHud();

    if (client > 0)
        PrintToChatAll("\x04[积分]\x01 %N 把积分池设为 \x05%d\x01", client, g_iPoints);
    else
        PrintToServer("[积分] 服务器管理员把积分池设为 %d", g_iPoints);
    return Plugin_Handled;
}

public Action Cmd_PointsReset(int client, int args)
{
    g_iPoints = 0;
    RefreshHud();

    if (client > 0)
        PrintToChatAll("\x04[积分]\x01 %N 已清零积分池", client);
    else
        PrintToServer("[积分] 服务器管理员已清零积分池");
    return Plugin_Handled;
}

public Action Cmd_PointsStatus(int client, int args)
{
    PrintToConsole(client, "[积分] 总开关=%d 初始积分=%d hp_scale=%.3f 当前积分=%d",
        g_cvEnabled.IntValue, g_cvStart.IntValue, g_cvHpScale.FloatValue, g_iPoints);
    PrintToConsole(client, "[积分] 价格: 核弹=%d 叛变虫群=%d 强化等级=%d (0=不设门槛)",
        g_cvNukeCost.IntValue, g_cvBetrayCost.IntValue, g_cvPowerCost.IntValue);
    PrintToConsole(client, "[积分] HUD: 开关=%d 通道=%d 位置=(%.2f, %.2f) 透明度=%d",
        g_cvHud.IntValue, g_cvHudChannel.IntValue, g_cvHudX.FloatValue, g_cvHudY.FloatValue,
        g_cvHudAlpha.IntValue);
    return Plugin_Handled;
}

// ============================================================================
//  帧回调: HUD 刷新 (0.5 秒节流) + 使用说明公告 (默认 30 秒节流)
//  (不依赖 SourceMod 定时器; 本环境定时器不触发, 否则 HUD 只闪一下)
// ============================================================================
public void OnGameFrame()
{
    float fNow = GetEngineTime();

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
    PrintToChatAll("\x04[积分]\x01 快捷购买: \x05/buy 1\x01核弹(%d)  \x05/buy 2\x01虫群(%d)  \x05/buy 3\x01强化(%d) | 击杀虫族获取积分, 输入 \x05/buy\x01 查看格式",
        g_cvNukeCost.IntValue, g_cvBetrayCost.IntValue, g_cvPowerCost.IntValue);
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
