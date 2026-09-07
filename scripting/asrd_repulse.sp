/**
 * ============================================================================
 *  [AS:RD] 范围击退 (Repulse)
 *  版本 1.7.3  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ──────────────────────────────────────
 *  1. 手动击退: 按绑定键以自己为中心, 把周围虫族沿径向往外推开。
 *     每游戏帧推进(OnGameFrame)并附带速度, 客户端帧间插值 → 短击退也平滑,
 *     推进速度可用时长控制, 不会"瞬移"也不会"一顿一顿"。
 *  2. 持续护盾: (可选) 开启后就像能量斥力场, 自动把靠近你的虫族
 *     缓慢持续往外推, 保持在护盾半径之外。同时也会弹开敌方投射物(炮弹)。
 *     管理员可用 sm_repulseaura 给指定玩家永久开/关 (特权, 需 ConVar=1)。
 *  3. X-33 威力增强器护盾: 仅 Wildcat/Wolfe (重武兵) 每使用一次 X-33
 *     (asw_weapon_buff_grenade, 默认 5 充能, 存于 m_iClip1, 用完武器销毁)
 *     就获得一次限时护盾; 叠加规则: 只叠加生效时间不叠加强度, 结束时间
 *     以最后一次使用为基准刷新; 充能耗尽后无法再开启。
 *     原版机制说明: X-33 信标基础时长对全角色固定 30 秒, 无角色差异;
 *     差异在于只有重武兵能把信标捡起来带着走 (携带移动每秒扣 1.125 秒)。
 *     特效同步: 护盾期间每帧把信标的燃烧截止时间回填为护盾结束时间 —
 *     抵消携带消耗, 保证增益特效与屏幕倒计时同时开始/结束;
 *     护盾自然到期时信标同步燃尽 (marine 阵亡则保留信标原版自然燃烧)。
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
 *   sm_repulse        手动范围击退 (可绑定按键连按)
 *   sm_repulseaura    [管理员] 给指定玩家永久开/关护盾 (特权):
 *                     sm_repulseaura [玩家] [on|off|1|0]
 *                     (无玩家=自己, 无状态=切换; 需 sm_asrd_repulse_aura 1)
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
 *   sm_asrd_repulse_aura           管理员指定护盾总开关 (默认 0) — 配合 sm_repulseaura
 *   sm_asrd_repulse_aura_radius    护盾半径/游戏单位 (默认 260)
 *   sm_asrd_repulse_aura_mode      护盾模式 (默认 0: 0=斥力击退平滑弹开; 1=直接阻挡钉在圈外)
 *   sm_asrd_repulse_aura_push_speed 护盾斥力弹开怪的速度/单位每秒 (默认 500; 持续速度外推, 顺滑不卡)
 *
 *   sm_asrd_repulse_x33            X-33 威力增强器护盾 (默认 1): 仅 Wildcat/Wolfe (重武兵)
 *                                  使用 X-33 时获得限时护盾; 不依赖 sm_asrd_repulse_aura,
 *                                  护盾方式(斥力/阻挡)仍由 sm_asrd_repulse_aura_mode 决定
 *   sm_asrd_repulse_x33_duration   每使用一次 X-33 的护盾秒数 (默认 30=原版信标时长;
 *                                  信标特效燃烧截止时间每帧同步为护盾结束时间,
 *                                  抵消携带消耗; >30 时等效延长原版增益信标)
 *   sm_asrd_repulse_x33_hud_channel 倒计时 HUD 通道 (默认 4; 需避开核弹插件的 5)
 *   sm_asrd_repulse_x33_hud_x      倒计时横向位置 (默认 -1=居中, 与核弹同款已验证位置;
 *                                  注意: 该游戏右侧 x=0.75 的 HudText 实测不渲染)
 *   sm_asrd_repulse_x33_hud_y      倒计时纵向位置 (默认 0.30; 与核弹同时显示时建议错开)
 *
 *   sm_asrd_repulse_classes        追加要击退的实体类名 (空格分隔, 空=不追加)
 *   sm_asrd_repulse_debug          调试输出 (默认 0; 1 会列出半径内所有 asw_ 与 npc_ 实体的真实类名)
 *
 *  依赖: SourceMod 1.11+ (核心 + sdktools)
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>
#include <sdktools_trace>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] 范围击退"
#define PLUGIN_VERSION "1.7.3"

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
ConVar g_cvX33;
ConVar g_cvX33Duration;
ConVar g_cvClasses;
ConVar g_cvProjectiles;
ConVar g_cvProjSpeed;
ConVar g_cvProjClasses;
ConVar g_cvDebug;
ConVar g_cvAuraPushSpeed;
ConVar g_cvX33HudChannel;
ConVar g_cvX33HudX;
ConVar g_cvX33HudY;

// ─── 按玩家激活的护盾 (由管理员命令 sm_repulseaura 指定, 默认全场无护盾) ──
bool g_bAuraOn[MAXPLAYERS + 1];

// ─── X-33 威力增强器触发的限时护盾 ─────────────────────
// 仅 Wildcat/Wolfe (重武兵职业, 档案索引 1/5) 使用 X-33 (asw_weapon_buff_grenade)
// 时触发: 每次使用把该玩家的护盾结束时间刷新为 now+时长 (以最后一次使用为基准,
// 只叠加时间不叠加强度)。充能由游戏本身管理: 存于武器 m_iClip1 (默认 5 次,
// 用完武器即销毁); 原版事件 damage_amplifier_placed 携带信标 entindex 与
// marine 实体索引, 且先于充能扣减触发 (此时 m_iClip1 仍是使用前的值)。
// 职业判定: 真实档案索引在 asw_marine_resource 的 m_MarineProfileIndex 上
// (marine 自身的 m_nMarineProfile 是地图摆放 keyfield, 游戏生成时恒为 -1, 不可用)。
static const char X33_WEAPON_CLASS[]  = "asw_weapon_buff_grenade";
#define X33_BEACON_CLASS      "asw_buffgrenade_projectile"
#define PROFILE_WILDCAT      1         // ASW_MARINE_PROFILE_WILDCAT
#define PROFILE_WOLFE        5         // ASW_MARINE_PROFILE_WOLFE
#define X33_HUD_HOLD         1.1       // 停留秒数, 大于 0.5s 定时器刷新间隔 (与核弹插件一致)
float  g_fX33End[MAXPLAYERS + 1];      // 护盾结束时间(游戏时间), 0=未激活
bool   g_bX33Active[MAXPLAYERS + 1];   // 上一帧是否处于 X-33 护盾中(到期边缘检测)
bool   g_bAnyX33Active;                // 是否有任一玩家处于 X-33 护盾中(帧回调开关)
int    g_iX33HudMode[MAXPLAYERS + 1];  // 倒计时显示模式: 0=未检测 1=内置HudText 2=game_text兜底
int    g_iX33TextEnt[MAXPLAYERS + 1];  // game_text 兜底实体引用 (模式2)

float g_fLastUse[MAXPLAYERS + 1];   // 手动击退冷却用

// ============================================================================
//  插件信息
// ============================================================================
public Plugin myinfo = {
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "范围击退(平滑推进) + 持续斥力护盾 + X-33 威力增强器护盾",
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
    g_cvAuraMode = CreateConVar("sm_asrd_repulse_aura_mode", "0",
        "护盾模式 (0=斥力击退 平滑弹开; 1=直接阻挡 钉在圈外)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvAuraPushSpeed = CreateConVar("sm_asrd_repulse_aura_push_speed", "500",
        "护盾斥力弹开把怪推出界外的速度/单位每秒 (作用于 sm_asrd_repulse_aura_mode 0 的斥力模式), 持续速度外推比分段动画更顺滑", FCVAR_NOTIFY, true, 50.0, true, 2000.0);
    g_cvX33 = CreateConVar("sm_asrd_repulse_x33", "1",
        "X-33 威力增强器护盾 (1=开 0=关), 开启后仅 Wildcat/Wolfe (重武兵) 使用 X-33 (asw_weapon_buff_grenade) 时获得限时护盾, 不依赖 sm_asrd_repulse_aura, 护盾方式由 sm_asrd_repulse_aura_mode 决定",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvX33Duration = CreateConVar("sm_asrd_repulse_x33_duration", "30",
        "每使用一次 X-33 的护盾秒数 (默认 30=原版信标时长; 叠加规则: 结束时间以最后一次使用为基准刷新, 只叠时间不叠强度; 增益信标特效的燃烧截止时间每帧同步为护盾结束时间 — 顺带抵消携带信标移动的额外消耗, 并在时长>30 时等效延长信标)",
        FCVAR_NOTIFY, true, 1.0, true, 600.0);
    g_cvX33HudChannel = CreateConVar("sm_asrd_repulse_x33_hud_channel", "4",
        "X-33 护盾倒计时 HUD 通道 (需避开核弹插件的 5; 若倒计时不显示可换 2/6/7 等通道试验, 无需重编译)",
        FCVAR_NOTIFY, true, 0.0, true, 15.0);
    g_cvX33HudX = CreateConVar("sm_asrd_repulse_x33_hud_x", "-1.0",
        "X-33 倒计时横向位置 (-1=居中 0=最左 0.9=近最右, 文字从该点向右绘制; 默认 -1 与核弹插件同位置 — 经测试该游戏 x=0.75 右侧位置的 HudText 不渲染, 居中可正常显示; 改完无需重编译)",
        FCVAR_NOTIFY, true, -1.0, true, 0.95);
    g_cvX33HudY = CreateConVar("sm_asrd_repulse_x33_hud_y", "0.30",
        "X-33 倒计时纵向位置 (0=最上 1=最下; 与核弹插件同默认值, 避免重叠可改 0.22 等)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);
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

    // X-33 使用事件 (游戏原生): 武器源码在创建信标后、扣减 m_iClip1 前触发,
    // 携带 entindex=信标实体 与 marine=marine 实体索引
    HookEvent("damage_amplifier_placed", Event_X33Placed, EventHookMode_Post);

    // X-33 倒计时 HUD 定时器 — 与核弹插件一致的"定时器驱动"显示方式。
    // (之前从 OnGameFrame 里直接发 HudText 在部分客户端不渲染, 核弹的定时器发送是已验证可用的)
    CreateTimer(0.5, Timer_X33Hud, _, TIMER_REPEAT);

    AutoExecConfig(true, "asrd_repulse");

    RegConsoleCmd("sm_repulse", Command_Repulse, "范围击退 (可绑定按键连按)");
    RegAdminCmd("sm_repulseaura", Command_Aura, ADMFLAG_GENERIC,
        "[管理员] 给指定玩家开关护盾: sm_repulseaura [玩家] [on|off|1|0] (无玩家=自己, 无状态=切换)");

    ParseCustomClasses();
    ParseProjClasses();
}

// ============================================================================
//  X-33 使用事件: 仅 Wildcat/Wolfe (重武兵) 触发限时护盾
//  叠加规则: 只叠时间不叠强度 — 每次使用把结束时间刷新为 now+时长,
//  即"以最后一次使用的时间为基准", 与原版多次扔信标的行为一致。
// ============================================================================
public void Event_X33Placed(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnabled.BoolValue || !g_cvX33.BoolValue)
        return;

    int marine = event.GetInt("marine");
    if (marine <= 0 || !IsValidEntity(marine))
        return;

    // debug: 记录事件与职业判定, 便于排查"用了 X-33 但没护盾"的情况
    if (g_cvDebug.BoolValue)
    {
        PrintToServer("[击退][x33] 事件触发: marine=%d 职业=%d (需1=Wildcat/5=Wolfe) 控制玩家=%d",
            marine, GetMarineProfileIndex(marine), ClientOfMarine(marine));
    }

    if (!IsSpecialWeaponsProfile(marine))
        return;

    int client = ClientOfMarine(marine);
    if (client <= 0 || IsFakeClient(client))
        return;   // 无人控制的 marine(纯AI) 不给护盾

    float now = GetGameTime();
    float duration = g_cvX33Duration.FloatValue;

    g_fX33End[client] = now + duration;
    g_bAnyX33Active = true;

    // 信标特效的截止时间不在这里改 — 由 ThinkAura 每帧同步为护盾结束时间,
    // 顺带抵消原版"携带信标移动每秒额外烧 1.125s"的消耗 (见 LoseTimeForMoving)

    // 剩余次数: 事件先于 m_iClip1 扣减触发, 本次使用后剩余 = 当前充能 - 1
    int remaining = X33RemainingCharges(marine);

    char sName[64];
    GetClientName(client, sName, sizeof(sName));
    if (remaining >= 0)
        PrintToChatAll("\x04%s\x01 使用x33威力增强器，\x05力场护盾激活\x01，剩余\x05%d\x01次", sName, remaining);
    else
        PrintToChatAll("\x04%s\x01 使用x33威力增强器，\x05力场护盾激活\x01", sName);
}

// 读取 marine 的职业档案索引 (0=Sarge 1=Wildcat 5=Wolfe, 找不到返回 -1)
// 注意: 不能读 marine 自身的 m_nMarineProfile — 那只是地图摆放 keyfield,
// 游戏过程中生成的 marine 该值恒为 -1; 真实索引存在 asw_marine_resource
// 实体的 m_MarineProfileIndex 网络属性上, 用 m_MarineEntity 句柄反查
int GetMarineProfileIndex(int marine)
{
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "asw_marine_resource")) != -1)
    {
        if (!IsValidEntity(ent))
            continue;
        if (!HasEntProp(ent, Prop_Send, "m_MarineEntity"))
            continue;
        if (GetEntPropEnt(ent, Prop_Send, "m_MarineEntity") != marine)
            continue;
        if (!HasEntProp(ent, Prop_Send, "m_MarineProfileIndex"))
            continue;
        return GetEntProp(ent, Prop_Send, "m_MarineProfileIndex");
    }
    return -1;
}

// 仅重武兵 (MARINE_CLASS_SPECIAL_WEAPONS) 有护盾效果:
// Wildcat(档案1) / Wolfe(档案5), 也是原版唯一能携带 X-33 信标走的职业
bool IsSpecialWeaponsProfile(int marine)
{
    int profile = GetMarineProfileIndex(marine);
    return profile == PROFILE_WILDCAT || profile == PROFILE_WOLFE;
}

// 找该 marine 携带的 X-33 武器, 返回本次使用后的剩余充能 (找不到返回 -1)
// 充能存于武器 m_iClip1 (默认 5, 用完武器即被游戏销毁 → 永远开不了护盾)
int X33RemainingCharges(int marine)
{
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, X33_WEAPON_CLASS)) != -1)
    {
        if (!IsValidEntity(ent))
            continue;

        int owner = 0;
        if (HasEntProp(ent, Prop_Data, "m_hOwner"))
            owner = GetEntPropEnt(ent, Prop_Data, "m_hOwner");
        if (owner <= 0 && HasEntProp(ent, Prop_Send, "m_hOwnerEntity"))
            owner = GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity");
        if (owner != marine)
            continue;

        if (!HasEntProp(ent, Prop_Send, "m_iClip1"))
            continue;

        return GetEntProp(ent, Prop_Send, "m_iClip1") - 1;
    }
    return -1;
}

// 把该 marine 扔出的所有增益信标 (asw_buffgrenade_projectile) 的燃烧截止时间
// 统一设为 fEnd — 护盾期间每帧调用 fEnd=护盾结束时间, 抵消原版携带移动的额外
// 消耗 (LoseTimeForMoving: 每秒烧 1.125s, 只有重武兵能携带, 故 Wildcat/Wolfe
// 的特效会早于倒计时熄灭); 到期时调用 fEnd=now 即同步燃尽。
// 信标被捡起携带仍是同一实体 (AttachToMarine 只是 SetParent), 所以按 owner
// 匹配即可覆盖"扔在地上"与"被带着走"两种状态。
void SyncX33Beacons(int marine, float fEnd)
{
    if (marine <= 0)
        return;

    int ent = -1;
    while ((ent = FindEntityByClassname(ent, X33_BEACON_CLASS)) != -1)
    {
        if (!IsValidEntity(ent))
            continue;
        if (!HasEntProp(ent, Prop_Send, "m_hOwnerEntity")
            || GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity") != marine)
            continue;
        if (!HasEntProp(ent, Prop_Send, "m_flTimeBurnOut"))
            continue;

        SetEntPropFloat(ent, Prop_Send, "m_flTimeBurnOut", fEnd);
    }
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

    // 切图后 GetGameTime() 从 0 重置, 必须清掉 X-33 护盾时间戳,
    // 否则上一张图残留的大时间戳会让状态机误判为"永久生效中"
    g_bAnyX33Active = false;
    for (int c = 1; c <= MaxClients; c++)
    {
        g_fX33End[c] = 0.0;
        g_bX33Active[c] = false;
        g_iX33HudMode[c] = 0;    // game_text 实体随切图销毁, 重新做模式检测
        g_iX33TextEnt[c] = 0;
    }

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
            //   0 (默认) = 斥力推: 每帧沿径向小步向外推
            //   1        = 直接阻挡: 每帧把范围内怪物钉回半径边界, 形成"墙"
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

                // 碰撞感知: 钉回途中被墙挡则停到墙边, 不穿墙
                float fFrom[3];
                fFrom[0] = fPos[0];
                fFrom[1] = fPos[1];
                fFrom[2] = fPos[2];
                TraceMoveBlocked(entity, fFrom, fNew);

                float fZero[3];
                fZero[0] = fZero[1] = fZero[2] = 0.0;
                TeleportEntity(entity, fNew, NULL_VECTOR, fZero);
            }
            else
            {
                // ── 斥力弹开: 给一个持续的朝外速度, 交给引擎物理连续移动, 触发时才平滑流畅。
                // 不再用分段平滑动画——分段动画首尾速度都会归零, 连续推时一卡一卡(视觉卡顿)。
                // 撞墙由引擎物理自动停下, 不会穿墙。
                float fVel[3];
                fVel[0] = (dx / fLen) * g_cvAuraPushSpeed.FloatValue;
                fVel[1] = (dy / fLen) * g_cvAuraPushSpeed.FloatValue;
                fVel[2] = 90.0;   // 小幅上抬, 避免贴地拖着走的生硬感
                TeleportEntity(entity, NULL_VECTOR, NULL_VECTOR, fVel);
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
    // 无动画且未开任何护盾模式时直接跳过, 避免空转
    // (X-33 护盾激活期间 g_bAnyX33Active 保持 true, 状态机会一直跑到全部到期才停)
    bool bHasAura = g_cvEnabled.BoolValue
        && (g_cvAura.BoolValue || g_bAnyX33Active);
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

        // 目标帧插值位置
        float fPos[3];
        for (int a = 0; a < 3; a++)
            fPos[a] = g_fPushSrc[i][a] + (g_fPushDst[i][a] - g_fPushSrc[i][a]) * s;

        // 起点 = 上一帧已应用的位置
        float fFrom[3];
        fFrom[0] = g_fPushPrev[i][0];
        fFrom[1] = g_fPushPrev[i][1];
        fFrom[2] = g_fPushPrev[i][2];

        // 碰撞感知: 途中被墙挡则停到碰撞点并结束动画, 不再继续往里穿透
        if (TraceMoveBlocked(ent, fFrom, fPos))
        {
            float fZero[3];
            fZero[0] = fZero[1] = fZero[2] = 0.0;
            TeleportEntity(ent, fPos, NULL_VECTOR, fZero);
            g_bPushActive[i] = false;
            continue;
        }

        float fVel[3];
        for (int a = 0; a < 3; a++)
        {
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
    float now = GetGameTime();
    float fRadius  = g_cvAuraRadius.FloatValue;
    float fRadius2 = fRadius * fRadius;
    int   iPushed  = 0;

    // 护盾模式下若开了 debug, 每隔 3 秒点名一次半径内所有实体类名,
    // 方便直接确认某只虫(如治疗虫)的真实类名, 不用改代码
    bool bDumpPending = g_cvDebug.BoolValue
        && (now - g_fLastAuraDump >= 3.0);
    bool bDumped = false;

    // X-33 状态机汇总: 本帧是否仍有人处于 X-33 护盾中
    g_bAnyX33Active = false;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
            continue;

        // ── X-33 限时护盾状态机: 到期/阵亡检测 + 右侧倒计时 HUD ──
        bool bX33 = false;
        if (g_fX33End[client] > 0.0)
        {
            // marine 必须存活且仍被该玩家控制, 阵亡即护盾失效
            int marine = GetPlayerMarine(client);
            bool bAlive = marine > 0
                && HasEntProp(marine, Prop_Send, "m_iHealth")
                && GetEntProp(marine, Prop_Send, "m_iHealth") > 0;

            bX33 = g_cvX33.BoolValue && bAlive && (g_fX33End[client] > now);

            if (bX33)
            {
                g_bAnyX33Active = true;
                g_bX33Active[client] = true;

                // 信标特效同步: 每帧把该 marine 名下增益信标的燃烧截止时间回填为
                // 护盾结束时间 — 抵消原版"携带信标移动每秒额外烧 1.125s"的消耗,
                // 保证特效与倒计时同时结束 (Wildcat/Wolfe 才能携带信标, 故尤其明显)
                SyncX33Beacons(marine, g_fX33End[client]);

                // 倒计时显示由 Timer_X33Hud 定时器负责 (与核弹插件一致的发送方式)
            }
            else
            {
                // 到期 / 被关闭 / marine 阵亡 → 清除倒计时与状态, 提示一次
                g_fX33End[client] = 0.0;
                if (g_bX33Active[client])
                {
                    g_bX33Active[client] = false;
                    ClearX33Hud(client);

                    // 自然到期(非阵亡) → 信标特效同步燃尽, 与倒计时同时结束;
                    // 阵亡则不烧 — 保留原版行为: 掉落的信标继续给队友提供增益
                    if (bAlive)
                        SyncX33Beacons(marine, now - 0.1);

                    PrintToChat(client, "\x04[击退]\x01 X-33 力场护盾已失效");
                }
            }
        }

        // 该玩家是否有有效盾: 管理员手动指定 或 X-33 护盾生效中
        bool bActive = (g_cvAura.BoolValue && g_bAuraOn[client]) || bX33;
        if (!bActive)
            continue;

        float fCenter[3];
        if (!GetMarineOrigin(client, fCenter))
            continue;

        if (bDumpPending && !bDumped)
        {
            bDumped = true;
            g_fLastAuraDump = now;
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
        && now - g_fLastAuraLog >= 1.0)
    {
        PrintToServer("[击退][aura] 本秒推开 %d 只", iPushed);
        g_fLastAuraLog = now;
    }
}

// ============================================================================
//  X-33 倒计时显示 (与核弹插件同款双模式):
//  先试内置 HudText 用户消息, 客户端不支持(返回-1)则降级为 game_text 实体兜底
//  参数形态与核弹插件完全一致 (hold 1.1 / fadeIn 0.05 / fadeOut 0.15),
//  仅位置/颜色/文本不同 — 核弹的这组参数是已验证可显示的
// ============================================================================
void ShowX33Hud(int client, const char[] text)
{
    if (g_iX33HudMode[client] == 2)
    {
        ShowX33ViaGameText(client, text);
        return;
    }

    SetHudTextParams(g_cvX33HudX.FloatValue, g_cvX33HudY.FloatValue, X33_HUD_HOLD, 0, 255, 0, 255, 0, 0.0, 0.05, 0.15);
    int ret = ShowHudText(client, g_cvX33HudChannel.IntValue, text);

    if (ret == -1)
    {
        g_iX33HudMode[client] = 2;
        if (g_cvDebug.BoolValue)
            PrintToServer("[击退][x33] 内置HudText不可用(返回-1), 改用 game_text 兜底: client=%d", client);
        ShowX33ViaGameText(client, text);
    }
    else if (g_iX33HudMode[client] != 1)
    {
        g_iX33HudMode[client] = 1;
        if (g_cvDebug.BoolValue)
            PrintToServer("[击退][x33] 内置HudText可用(返回通道=%d): client=%d", ret, client);
    }
}

// X-33 倒计时刷新定时器 (0.5s): 只负责显示, 到期检测仍在 ThinkAura 每帧进行。
// 护盾状态由 ThinkAura 维护 (g_bX33Active=当前帧处于护盾中), 这里仅读取。
public Action Timer_X33Hud(Handle timer)
{
    if (!g_cvEnabled.BoolValue || !g_cvX33.BoolValue || !g_bAnyX33Active)
        return Plugin_Continue;

    float now = GetGameTime();
    for (int c = 1; c <= MaxClients; c++)
    {
        if (!g_bX33Active[c] || g_fX33End[c] <= now)
            continue;
        if (!IsClientInGame(c) || IsFakeClient(c))
            continue;

        int secs = RoundToCeil(g_fX33End[c] - now);
        if (secs < 1)
            secs = 1;
        char sBuf[64];
        Format(sBuf, sizeof(sBuf), "护盾 %d 秒", secs);
        ShowX33Hud(c, sBuf);

        if (g_cvDebug.BoolValue)
            PrintToServer("[击退][x33] HUD刷新: client=%d 剩余=%ds 模式=%d 通道=%d 位置=(%.2f, %.2f)",
                c, secs, g_iX33HudMode[c], g_cvX33HudChannel.IntValue, g_cvX33HudX.FloatValue, g_cvX33HudY.FloatValue);
    }
    return Plugin_Continue;
}

// 护盾到期时清除倒计时字样
void ClearX33Hud(int client)
{
    if (g_iX33HudMode[client] == 1)
    {
        SetHudTextParams(g_cvX33HudX.FloatValue, g_cvX33HudY.FloatValue, 0.1, 0, 255, 0, 0, 0, 0.0, 0.1, 0.1);
        ShowHudText(client, g_cvX33HudChannel.IntValue, " ");
    }
    else if (g_iX33HudMode[client] == 2)
    {
        int ent = EntRefToEntIndex(g_iX33TextEnt[client]);
        // ent > 0: 引用为 0 时解析成 worldspawn, 误 Kill 会崩服
        if (ent != INVALID_ENT_REFERENCE && ent > 0 && IsValidEntity(ent))
            AcceptEntityInput(ent, "Kill");
        g_iX33TextEnt[client] = 0;
    }
}

// 兜底显示: 为某玩家取得 (没有则创建) 一个 game_text 实体并显示
int GetX33GameText(int client)
{
    int ent = EntRefToEntIndex(g_iX33TextEnt[client]);
    // ent > 0: 引用为 0 时解析成 worldspawn, 不能当 game_text 用
    if (ent != INVALID_ENT_REFERENCE && ent > 0 && IsValidEntity(ent))
        return ent;

    ent = CreateEntityByName("game_text");
    if (ent == -1)
        return -1;

    char sName[48];
    Format(sName, sizeof(sName), "asrd_x33_hud_%d", GetClientUserId(client));

    char sCh[8], sX[16], sY[16];
    IntToString(g_cvX33HudChannel.IntValue, sCh, sizeof(sCh));
    Format(sX, sizeof(sX), "%.4f", g_cvX33HudX.FloatValue);
    Format(sY, sizeof(sY), "%.4f", g_cvX33HudY.FloatValue);

    DispatchKeyValue(ent, "targetname", sName);
    DispatchKeyValue(ent, "spawnflags", "0");
    DispatchKeyValue(ent, "channel",   sCh);
    DispatchKeyValue(ent, "x",         sX);
    DispatchKeyValue(ent, "y",         sY);
    DispatchKeyValue(ent, "effect",    "0");
    DispatchKeyValue(ent, "color",     "0 255 0");
    DispatchKeyValue(ent, "fadein",    "0.05");
    DispatchKeyValue(ent, "fadeout",   "0.1");
    DispatchKeyValue(ent, "holdtime",  "1.0");
    DispatchSpawn(ent);

    if (g_cvDebug.BoolValue)
        PrintToServer("[击退][x33] 创建 game_text 兜底实体 #%d (client=%d 通道=%d)",
            ent, client, g_cvX33HudChannel.IntValue);

    g_iX33TextEnt[client] = EntIndexToEntRef(ent);
    return ent;
}

void ShowX33ViaGameText(int client, const char[] msg)
{
    int ent = GetX33GameText(client);
    if (ent == -1)
        return;

    DispatchKeyValue(ent, "message", msg);
    AcceptEntityInput(ent, "Display", client);
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
//  碰撞感知位移: 把实体从 fFrom 推向 fTarget。
//  仅被环境几何(world/brush 墙等)阻挡; 虫与虫、虫与玩家之间不互相阻挡,
//  避免多只虫一起被推开时相互误判堆叠。
//  若路径被墙挡, 将 fTarget 截断到碰撞点并沿原方向回退一小段, 返回 true。
// ============================================================================
// filter 返回 true=允许该实体被命中, false=忽略该实体
// world/brush 不受 filter 影响, 始终参与 trace → 只有墙能挡虫
public bool TraceFilter_None(int entity, int contentsMask, any data)
{
    return false;
}

bool TraceMoveBlocked(int self, const float fFrom[3], float fTarget[3])
{
    TR_TraceRayFilter(fFrom, fTarget, MASK_SOLID_BRUSHONLY, RayType_EndPoint, TraceFilter_None, self);
    if (!TR_DidHit())
        return false;

    float fHit[3];
    TR_GetEndPosition(fHit);

    // 碰撞点沿推进方向略回退, 避免半个身子陷进墙里
    float fx = fTarget[0] - fFrom[0];
    float fy = fTarget[1] - fFrom[1];
    float fz = fTarget[2] - fFrom[2];
    float fLen = fx*fx + fy*fy + fz*fz;
    if (fLen > 1.0)
    {
        fLen = SquareRoot(fLen);
        float fBack = 8.0;
        fTarget[0] = fHit[0] - (fx / fLen) * fBack;
        fTarget[1] = fHit[1] - (fy / fLen) * fBack;
        fTarget[2] = fHit[2] - (fz / fLen) * fBack;
    }
    else
    {
        fTarget[0] = fHit[0];
        fTarget[1] = fHit[1];
        fTarget[2] = fHit[2];
    }
    return true;
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

// 找控制某 marine 实体的人类玩家 (找不到返回 0)
int ClientOfMarine(int iMarine)
{
    for (int c = 1; c <= MaxClients; c++)
    {
        if (!IsClientInGame(c) || IsFakeClient(c))
            continue;
        if (GetPlayerMarine(c) == iMarine)
            return c;
    }
    return 0;
}

// 玩家离开时清掉管理员护盾与 X-33 护盾状态, 避免残留
public void OnClientDisconnect(int client)
{
    g_bAuraOn[client] = false;
    g_fX33End[client] = 0.0;
    g_bX33Active[client] = false;

    // 清理 game_text 兜底实体: 只有确实创建过(模式2)才清理。
    // 警告: EntRefToEntIndex(0) 返回 0 = worldspawn(世界实体) 且 IsValidEntity(0)
    // 为 true, 引用为 0 时对它 Kill 会直接崩服, 必须用 ent > 0 挡住!
    if (g_iX33HudMode[client] == 2)
    {
        int ent = EntRefToEntIndex(g_iX33TextEnt[client]);
        if (ent != INVALID_ENT_REFERENCE && ent > 0 && IsValidEntity(ent))
            AcceptEntityInput(ent, "Kill");
    }
    g_iX33HudMode[client] = 0;
    g_iX33TextEnt[client] = 0;
}
