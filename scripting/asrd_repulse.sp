/**
 * ============================================================================
 *  [AS:RD] 范围击退 (Repulse)
 *  版本 1.10.1  |  (1.10.1: cfg 描述改 ASCII 英文, 修复中文在 AutoExecConfig 下编码损坏导致打不开)  游戏: Alien Swarm: Reactive Drop (AppID 563560)
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
 *     特效放大: 信标的 m_flRadius (网络属性, 原版由武器传入 120) 会被客户端
 *     每帧写进脉冲粒子 buffgrenade_pulse 的控制点 CP1, 决定那圈"水面涟漪"
 *     向外扩散的范围; 护盾期间把它放大即可让波纹变大 (视觉最大约 1.55 倍值)。
 *     服务器只在信标落地时按 GetEffectRadius()==m_flRadius 生成一次 AOE 触发盒,
 *     因此只在落地(m_bSettled)之后再改 — 只改视觉, 不会扩大伤害增益的判定范围。
 *     想真的扩大"伤害增益给谁"的范围, 用 sm_asrd_repulse_x33_buff_radius: 它在信标
 *     落地前写入, 落地那一瞬生成的触发盒就是大圈 (只对下一次扔出的信标生效)。
 *     光晕强度 m_flScale / 颜色 (镜像客户端 cvar asw_buffgrenade) 同理可改。
 *     护盾期间可把信标附着到 marine 身上跟着走 (sm_asrd_repulse_x33_follow, 默认开):
 *     复刻 VPK 挑战里 X33 的"电弧跟随"观感 — 信标模型隐形, 只剩涟漪+连向附近队友的
 *     电弧, 且随人移动; 落地的 AOE 触发盒一并跟到 marine, 增益/电弧判定照常工作。
 *     原生实现靠客户端 cvar attach_sw / attach_sw_auto (仅重武兵能捡起携带, 且是
 *     每客户端 USERINFO 服务器改无效), 这里直接服务端复刻 AttachToMarine, 不受职业限制。
 *
 *  ── 投射物(炮弹) ───────────────────────────────────────
 *   已内置:
 *     asw_mortarbug_shell  迫击炮虫的炮弹
 *     asw_missile_round    ranger 酸球 + 玩家导弹/火箭 (同一实体)
 *     grenade_spit         蚁狮工兵 npc_antlion_worker 的酸液弹
 *                          (引擎 npc_antlion.cpp 的 AE_ANTLION_WORKER_SPIT
 *                           一次创建 6 枚)
 *   用"速度弹开"而非 teleport, 防止被投射物原速度拉回;
 *   护盾模式下除 asw_mortarbug_shell 外一律直接消失(阻挡)。
 *   其余投射物可在 debug 抓到类名后,
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
 *   sm_asrd_repulse_aura           管理员指定护盾总开关 (默认 1) — 配合 sm_repulseaura
 *   sm_asrd_repulse_aura_radius    护盾半径/游戏单位 (默认 300)
 *   sm_asrd_repulse_aura_mode      护盾模式 (默认 0: 0=斥力击退平滑弹开; 1=直接阻挡钉在圈外)
 *   sm_asrd_repulse_aura_push_speed 护盾斥力弹开怪的速度/单位每秒 (默认 1000; 持续速度外推, 顺滑不卡)
 *
 *   sm_asrd_repulse_x33            X-33 威力增强器护盾 (默认 1): 仅 Wildcat/Wolfe (重武兵)
 *                                  使用 X-33 时获得限时护盾; 不依赖 sm_asrd_repulse_aura,
 *                                  护盾方式(斥力/阻挡)仍由 sm_asrd_repulse_aura_mode 决定
 *   sm_asrd_repulse_x33_buff_radius X-33 伤害增益范围/游戏单位 (默认 0=不改, 保持原版 120)
 *   sm_asrd_repulse_x33_fx_scale   X-33 信标光晕强度 (默认 1.0=原版; 0=关掉光晕)
 *   sm_asrd_repulse_x33_fx_color   X-33 信标颜色 "R G B" (默认空=不改, 原版 98 34 16)
 *   sm_asrd_repulse_x33_fx_radius  X-33 护盾特效(水面涟漪那圈光波)的扩散半径/游戏单位
 *                                  (默认 200; 0=不改, 保持原版的 120; 见下方"特效放大原理")
 *   sm_asrd_repulse_x33_follow    X-33 信标附着到 marine 身上跟着走 (默认 1=开; 0=不附着,
 *                                  信标固定地面; 复刻 VPK 挑战 X33 的"电弧跟随"观感: 信标模型
 *                                  隐形, 只剩涟漪+连向附近队友的电弧, 随人移动; 落地的 AOE 触发盒
 *                                  一并跟到 marine, 增益/电弧判定照常工作; 不受原生 attach_sw 职业限制)
 *   sm_asrd_repulse_x33_duration   每使用一次 X-33 的护盾秒数 (默认 15; 只叠时间不叠强度;
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

#define PLUGIN_NAME    "[AS:RD] Area Repulse"
#define PLUGIN_VERSION "1.10.1"

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
// asw_mortarbug_shell = mortarbug(迫击炮虫)的炮弹 (护盾模式下也只用速度弹开, 不删除)
// asw_missile_round   = ranger 酸球 + 玩家的导弹/火箭, 共用同一实体!
//   ⚠ 当前**不做敌我区分** (见 PushProjectiles 注释): 玩家自己打出的导弹进入半径
//     同样会被弹开 / 护盾模式下被删除。
// grenade_spit        = 蚁狮工兵 npc_antlion_worker 的酸液弹
//   (引擎 src/game/server/hl2/npc_antlion.cpp:1099, 动画事件 AE_ANTLION_WORKER_SPIT
//    一次创建 6 枚; 仅该 NPC 的发射动作会用到, 玩家武器不使用此类名)
// 其余可在 debug 抓到类名后追加
char g_sBuiltinProjClasses[][] =
{
    "asw_mortarbug_shell",
    "asw_missile_round",
    "grenade_spit"
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
ConVar g_cvX33FxRadius;
ConVar g_cvX33BuffRadius;
ConVar g_cvX33FxScale;
ConVar g_cvX33Color;
ConVar g_cvBuffColor;
ConVar g_cvX33Follow;
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
float  g_fX33FxOrig[MAXPLAYERS + 1];   // 放大前信标原版特效半径 (0=未记录; 护盾结束后还原)
float  g_fX33ScaleOrig[MAXPLAYERS + 1];// 放大前信标原版光晕强度 (0=未记录; 护盾结束后还原)
bool   g_bX33Attached[MAXPLAYERS + 1]; // 本帧护盾是否已把信标附着到 marine (避免每帧重复 SetParent)
int    g_iX33BeaconEnt[MAXPLAYERS + 1];// 已附着的信标实体引用 (护盾结束时据此解除附着, 不依赖 marine 是否还活着)
float  g_fX33AttachOrig[MAXPLAYERS + 1][3]; // 附着前信标的地面世界坐标 (护盾结束/阵亡时还原为"掉落的信标")

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
        "Enable/disable area repulse (0=off 1=on)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvPublic = CreateConVar("sm_asrd_repulse_public", "1",
        "Allow normal players to use sm_repulse (1=everyone 0=admins only)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvRadius = CreateConVar("sm_asrd_repulse_radius", "400",
        "Manual repulse radius (game units)", FCVAR_NOTIFY, true, 50.0, true, 3000.0);
    g_cvForce = CreateConVar("sm_asrd_repulse_force", "160",
        "Total outward displacement per repulse (game units)", FCVAR_NOTIFY, true, 0.0, true, 2000.0);
    g_cvLift = CreateConVar("sm_asrd_repulse_lift", "80",
        "Upward lift height per repulse (game units)", FCVAR_NOTIFY, true, 0.0, true, 500.0);
    g_cvPullTime = CreateConVar("sm_asrd_repulse_pull_time", "0.35",
        "Repulse push duration in seconds (higher=slower, smoother)", FCVAR_NOTIFY, true, 0.05, true, 3.0);
    g_cvCooldown = CreateConVar("sm_asrd_repulse_cooldown", "0",
        "Min interval seconds between manual triggers (0=no cooldown)", FCVAR_NOTIFY, true, 0.0, true, 60.0);
    g_cvAura = CreateConVar("sm_asrd_repulse_aura", "1",
        "Persistent repulsion shield (1=on 0=off)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvAuraRadius = CreateConVar("sm_asrd_repulse_aura_radius", "300",
        "Shield radius (game units)", FCVAR_NOTIFY, true, 50.0, true, 3000.0);
    g_cvAuraMode = CreateConVar("sm_asrd_repulse_aura_mode", "0",
        "Shield mode (0=repel smoothly; 1=block, pin outside)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvAuraPushSpeed = CreateConVar("sm_asrd_repulse_aura_push_speed", "1000",
        "Shield repel speed (units/sec) for mode 0; continuous push is smoother than stepped anim", FCVAR_NOTIFY, true, 50.0, true, 2000.0);
    g_cvX33 = CreateConVar("sm_asrd_repulse_x33", "1",
        "X-33 amplifies shield (1=on 0=off); only Wildcat/Wolfe get timed shield when using X-33, independent of aura; mode set by sm_asrd_repulse_aura_mode",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvX33Duration = CreateConVar("sm_asrd_repulse_x33_duration", "15",
        "X-33 shield duration in seconds per use (default 15); refresh end time on each use, stacks time only; beacon FX burn cutoff synced each frame",
        FCVAR_NOTIFY, true, 1.0, true, 600.0);
    g_cvX33FxRadius = CreateConVar("sm_asrd_repulse_x33_fx_radius", "200",
        "X-33 shield FX ripple radius (game units, default 200; 0=keep vanilla 120); client writes m_flRadius to particle CP1 each frame; visual reaches ~1.55x; set to shield_radius/1.55 to align edge",
        FCVAR_NOTIFY, true, 0.0, true, 2000.0);
    g_cvX33BuffRadius = CreateConVar("sm_asrd_repulse_x33_buff_radius", "0",
        "X-33 damage buff radius (game units, default 0=keep vanilla 120); server spawns AOE trigger at beacon land using m_flRadius; affects next thrown beacon only",
        FCVAR_NOTIFY, true, 0.0, true, 3000.0);
    g_cvX33FxScale = CreateConVar("sm_asrd_repulse_x33_fx_scale", "1.0",
        "X-33 beacon glow intensity (default 1.0=vanilla; dynamic light radius = value*120*(light/32), ~375*value max; 0=off, FX stops at value<0.01)",
        FCVAR_NOTIFY, true, 0.0, true, 10.0);
    g_cvX33Follow = CreateConVar("sm_asrd_repulse_x33_follow", "1",
        "X-33 beacon attaches to marine and follows (default 1=on; 0=stays on ground); replicates VPK 'arc follow' look: invisible model, only ripple+arcs to nearby teammates; AOE trigger follows too; server-side AttachToMarine, no class limit",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvX33Color = CreateConVar("sm_asrd_repulse_x33_fx_color", "",
        "X-33 beacon color as 'R G B' (e.g. '0 128 255'); empty=keep vanilla 98 34 16; mirrored to client cvar asw_buffgrenade for glow/dynamic light color",
        FCVAR_NOTIFY);
    // 镜像客户端 cvar: 服务器上本来没有 asw_buffgrenade (它定义在 client.dll),
    // 这里建一个同名 + FCVAR_REPLICATED 的"影子", 改它的值即可把颜色推给客户端
    g_cvBuffColor = CreateConVar("asw_buffgrenade", "98 34 16",
        "[mirror of client cvar] X-33 beacon color, driven by sm_asrd_repulse_x33_fx_color; do not edit manually",
        FCVAR_REPLICATED);
    g_cvX33HudChannel = CreateConVar("sm_asrd_repulse_x33_hud_channel", "4",
        "X-33 shield countdown HUD channel (avoid nuke plugin's 5; try 2/6/7 if hidden; no recompile)",
        FCVAR_NOTIFY, true, 0.0, true, 15.0);
    g_cvX33HudX = CreateConVar("sm_asrd_repulse_x33_hud_x", "-1.0",
        "X-33 countdown X position (-1=center 0=left 0.9=right); default -1 matches nuke plugin; x=0.75 right side may not render, use center; no recompile",
        FCVAR_NOTIFY, true, -1.0, true, 0.95);
    g_cvX33HudY = CreateConVar("sm_asrd_repulse_x33_hud_y", "0.30",
        "X-33 countdown Y position (0=top 1=bottom); same default as nuke plugin, change e.g. 0.22 to avoid overlap",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvClasses = CreateConVar("sm_asrd_repulse_classes", "",
        "Extra entity classes to repulse (space separated, empty=none)", FCVAR_NOTIFY);
    g_cvProjectiles = CreateConVar("sm_asrd_repulse_projectiles", "1",
        "Repel enemy projectiles like mortar bug shells (0=off 1=on)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvProjSpeed = CreateConVar("sm_asrd_repulse_projectile_speed", "400",
        "Projectile repel speed (game units/sec)", FCVAR_NOTIFY, true, 50.0, true, 3000.0);
    g_cvProjClasses = CreateConVar("sm_asrd_repulse_projectile_classes", "",
        "Extra enemy projectile classes to repel (space separated, empty=none)", FCVAR_NOTIFY);
    g_cvDebug = CreateConVar("sm_asrd_repulse_debug", "0",
        "Debug output (0=off 1=on; lists real class names in radius to catch projectiles/missed aliens)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    HookConVarChange(g_cvClasses, OnClassesChanged);
    HookConVarChange(g_cvProjClasses, OnProjClassesChanged);
    // 颜色改动即时下发客户端 (改 sm_asrd_repulse_x33_fx_color 不用重编译/换图)
    HookConVarChange(g_cvX33Color, OnX33ColorChanged);

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

// 放大 / 还原 X-33 信标的视觉与范围 (三件事一起做, 只遍历一次信标列表):
//
//   ① 涟漪范围 m_flRadius (视觉) — 客户端 C_ASW_AOEGrenade_Projectile 每帧把网络
//      属性 m_flRadius 写进脉冲粒子 buffgrenade_pulse 的控制点 CP1, 它就是那圈
//      "水面涟漪"扩散的半径; 原版由武器传入 (asw_weapon_buff_grenade: 120)。
//   ② 伤害增益范围 (逻辑) — 服务器 AOEGrenadeTouch() 在信标落地那一瞬执行
//      radius = GetEffectRadius() (返回 m_flRadius) 后 UTIL_SetSize 生成 AOE 触发盒,
//      此后不再重算。所以"落地前改半径"= 改增益范围, "落地后改半径"= 只改视觉。
//      两者因此可以同时拥有不同的值 (落地前写 buff_radius, 落地后写 fx_radius)。
//   ③ 光晕强度 m_flScale — 客户端 ClientThink 里 baseScale = m_flScale,
//      动态光半径 = baseScale × 120 × (m_fLightRadius / 32); 小于 0.01 时整个
//      信标特效停摆 (函数直接 return), 因此 0 可当作"关掉光晕"用。
//
// 第一次改写前把原版值记到 g_fX33FxOrig / g_fX33ScaleOrig, bRestore 时写回并清空。
void ApplyX33BeaconFx(int marine, int client, bool bRestore)
{
    if (marine <= 0 || client <= 0)
        return;

    float fFxRadius   = g_cvX33FxRadius.FloatValue;     // 0=不改
    float fBuffRadius = g_cvX33BuffRadius.FloatValue;   // 0=不改
    float fFxScale    = g_cvX33FxScale.FloatValue;      // <0 表示不改 (当前最小值为 0)

    // 从没改过就无需还原; 放大时直接往下走, 每一项各自判断 (没配的项保持原版,
    // 且写入前有 != 判断, 值没变就不写, 不会白白改动网络属性)
    if (bRestore && g_fX33FxOrig[client] <= 0.0 && g_fX33ScaleOrig[client] <= 0.0)
        return;

    int ent = -1;
    while ((ent = FindEntityByClassname(ent, X33_BEACON_CLASS)) != -1)
    {
        if (!IsValidEntity(ent))
            continue;
        if (!HasEntProp(ent, Prop_Send, "m_hOwnerEntity")
            || GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity") != marine)
            continue;

        bool bHasRadius = HasEntProp(ent, Prop_Send, "m_flRadius");
        bool bHasScale  = HasEntProp(ent, Prop_Send, "m_flScale");

        // 记下原版值 (只在第一次改写前记, 之后一直用它还原)
        if (!bRestore)
        {
            if (bHasRadius && g_fX33FxOrig[client] <= 0.0)
                g_fX33FxOrig[client] = GetEntPropFloat(ent, Prop_Send, "m_flRadius");
            if (bHasScale && g_fX33ScaleOrig[client] <= 0.0)
                g_fX33ScaleOrig[client] = GetEntPropFloat(ent, Prop_Send, "m_flScale");
        }

        // ① + ② 半径
        if (bHasRadius)
        {
            bool bSettled = !HasEntProp(ent, Prop_Send, "m_bSettled")
                || GetEntProp(ent, Prop_Send, "m_bSettled") != 0;

            float fTarget;
            if (bRestore)
                fTarget = g_fX33FxOrig[client];                    // 还原原版值
            else if (!bSettled && fBuffRadius > 0.0)
                fTarget = fBuffRadius;                             // 落地前 → 决定增益范围
            else
                fTarget = fFxRadius;                               // 落地后 → 只改视觉

            if (fTarget > 0.0 && GetEntPropFloat(ent, Prop_Send, "m_flRadius") != fTarget)
                SetEntPropFloat(ent, Prop_Send, "m_flRadius", fTarget);
        }

        // ③ 光晕强度
        if (bHasScale)
        {
            float fTarget = bRestore ? g_fX33ScaleOrig[client] : fFxScale;
            if (fTarget >= 0.0 && GetEntPropFloat(ent, Prop_Send, "m_flScale") != fTarget)
                SetEntPropFloat(ent, Prop_Send, "m_flScale", fTarget);
        }
    }

    if (bRestore)
    {
        g_fX33FxOrig[client] = 0.0;
        g_fX33ScaleOrig[client] = 0.0;
    }
}

// 把该 marine 名下已落地的 X-33 信标附着到 marine 身上跟着走 — 复刻 VPK 挑战里
// X-33 的"电弧跟随"观感 (原生 CASW_BuffGrenade_Projectile::AttachToMarine):
//   SetParent(marine, "manhack") 让信标跟随移动; 同时把它的 AOE 触发盒
//   (asw_aoegrenade_touch_trigger, 原生 AttachToMarine 也一起 SetParent) 也挂上,
//   所以跟随过程中依旧给附近队友加增益、画电弧; 信标模型 SetRenderMode(kRenderNone)
//   隐形, 只剩涟漪+电弧。
//   只在 m_bSettled (已落地生成触发盒) 之后做一次; 护盾结束(bAttach=false)时还原:
//   解除父子关系并把信标放回记录的原位置 (阵亡时变回"掉落的信标"继续增益队友)。
//   原生实现靠客户端 cvar attach_sw / attach_sw_auto (仅重武兵能捡起携带, 且是
//   每客户端 USERINFO 服务器改无效) — 这里直接服务端复刻, 不受职业限制, 任何 marine
//   的护盾都能获得跟随效果。
void ApplyX33BeaconFollow(int marine, int client, bool bAttach)
{
    if (client <= 0)
        return;

    // ── 护盾结束: 解除附着, 还原信标 ──
    if (!bAttach)
    {
        if (g_bX33Attached[client]
            && g_iX33BeaconEnt[client] > 0
            && IsValidEntity(g_iX33BeaconEnt[client]))
        {
            int ent = g_iX33BeaconEnt[client];

            // 解除信标本身
            AcceptEntityInput(ent, "ClearParent");
            SetEntityRenderMode(ent, RENDER_NORMAL);
            // 放回附着前的地面位置 (阵亡时即是"掉落的信标")
            if (g_fX33AttachOrig[client][0] != 0.0
                || g_fX33AttachOrig[client][1] != 0.0
                || g_fX33AttachOrig[client][2] != 0.0)
            {
                TeleportEntity(ent, g_fX33AttachOrig[client], NULL_VECTOR, NULL_VECTOR);
            }

            // 解除 AOE 触发盒的父子关系 (它原本是信标子实体, 附着时被一并挂到 marine)
            int trig = -1;
            while ((trig = FindEntityByClassname(trig, "asw_aoegrenade_touch_trigger")) != -1)
            {
                if (!IsValidEntity(trig))
                    continue;
                if (HasEntProp(trig, Prop_Data, "m_pMoveParent")
                    && GetEntPropEnt(trig, Prop_Data, "m_pMoveParent") == ent)
                {
                    AcceptEntityInput(trig, "ClearParent");
                }
            }
        }
        g_bX33Attached[client] = false;
        g_iX33BeaconEnt[client] = 0;
        g_fX33AttachOrig[client][0] = 0.0;
        g_fX33AttachOrig[client][1] = 0.0;
        g_fX33AttachOrig[client][2] = 0.0;
        return;
    }

    // ── 护盾生效: 仅在开启且尚未附着时做一次 ──
    if (!g_cvX33Follow.BoolValue || g_bX33Attached[client] || marine <= 0)
        return;

    int ent = -1;
    while ((ent = FindEntityByClassname(ent, X33_BEACON_CLASS)) != -1)
    {
        if (!IsValidEntity(ent))
            continue;
        if (!HasEntProp(ent, Prop_Send, "m_hOwnerEntity")
            || GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity") != marine)
            continue;

        // 必须已落地 (否则还没生成 AOE 触发盒, 附着了也不会给队友加增益/画电弧)
        bool bSettled = !HasEntProp(ent, Prop_Send, "m_bSettled")
            || GetEntProp(ent, Prop_Send, "m_bSettled") != 0;
        if (!bSettled)
            continue;

        // 记录当前(地面)位置, 护盾结束/阵亡时还原
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", g_fX33AttachOrig[client]);

        // 信标 → marine (manhack 挂点), 归零本地原点让特效贴在挂载点
        SetVariantString("!activator");
        AcceptEntityInput(ent, "SetParent", marine);
        SetVariantString("manhack");
        AcceptEntityInput(ent, "SetParentAttachment", marine);
        float vZero[3];
        vZero[0] = vZero[1] = vZero[2] = 0.0;
        SetEntPropVector(ent, Prop_Data, "m_vecOrigin", vZero);
        SetEntityRenderMode(ent, RENDER_NONE);   // 信标模型隐形, 只剩涟漪+电弧 (原生 AttachToMarine)

        // AOE 触发盒一并跟到 marine (原生 AttachToMarine 也这么做, 增益/电弧判定照常)
        int trig = -1;
        while ((trig = FindEntityByClassname(trig, "asw_aoegrenade_touch_trigger")) != -1)
        {
            if (!IsValidEntity(trig))
                continue;
            if (HasEntProp(trig, Prop_Data, "m_pMoveParent")
                && GetEntPropEnt(trig, Prop_Data, "m_pMoveParent") == ent)
            {
                SetVariantString("!activator");
                AcceptEntityInput(trig, "SetParent", marine);
                SetVariantString("manhack");
                AcceptEntityInput(trig, "SetParentAttachment", marine);
                SetEntPropVector(trig, Prop_Data, "m_vecOrigin", vZero);
            }
        }

        g_bX33Attached[client] = true;
        g_iX33BeaconEnt[client] = ent;
        break;   // 一个 marine 通常只有一个 X-33 信标
    }
}

// 下发 X-33 信标颜色: 设置镜像 cvar asw_buffgrenade 的值 (FCVAR_REPLICATED 会自己
// 同步给客户端), 再对每个在线玩家补一次 SendConVarValue 双保险。
// 客户端 C_ASW_BuffGrenade_Projectile::GetGrenadeColor() 读的就是这个 cvar。
void ApplyX33BeaconColor()
{
    char sColor[32];
    g_cvX33Color.GetString(sColor, sizeof(sColor));
    if (sColor[0] == '\0')
        return;                        // 空=不改, 保持原版

    g_cvBuffColor.SetString(sColor);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;
        SendConVarValue(i, g_cvBuffColor, sColor);
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
        g_fX33FxOrig[c] = 0.0;   // 信标随切图消失, 放大记录一并清掉
        g_fX33ScaleOrig[c] = 0.0;
        g_bX33Attached[c] = false;   // 信标随切图消失, 附着状态一并清掉
        g_iX33BeaconEnt[c] = 0;
        g_fX33AttachOrig[c][0] = g_fX33AttachOrig[c][1] = g_fX33AttachOrig[c][2] = 0.0;
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

public void OnX33ColorChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    ApplyX33BeaconColor();
}

// cfg 全部执行完 (此时 sm_asrd_repulse_x33_fx_color 才是最终值) 再下发一次颜色,
// 晚进服的玩家在 OnClientPutInServer 里补发
public void OnConfigsExecuted()
{
    ApplyX33BeaconColor();
}

public void OnClientPutInServer(int client)
{
    char sColor[32];
    g_cvX33Color.GetString(sColor, sizeof(sColor));
    if (sColor[0] != '\0' && IsClientInGame(client) && !IsFakeClient(client))
        SendConVarValue(client, g_cvBuffColor, sColor);
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

                // 特效自定义: 涟漪范围 / 增益范围 / 光晕强度 (未配的项保持原版)
                ApplyX33BeaconFx(marine, client, false);

                // 把信标附着到 marine 身上跟着走 (复刻 VPK 挑战的"电弧跟随"观感)
                ApplyX33BeaconFollow(marine, client, true);

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

                    // 还原信标的原版特效参数 (阵亡时信标掉落按原版继续燃烧, 同样还原)
                    ApplyX33BeaconFx(marine, client, true);

                    // 解除信标附着, 还原为"掉落的信标" (阵亡时变回地面继续增益队友)
                    ApplyX33BeaconFollow(marine, client, false);

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
    g_fX33FxOrig[client] = 0.0;
    g_fX33ScaleOrig[client] = 0.0;
    g_bX33Attached[client] = false;
    g_iX33BeaconEnt[client] = 0;
    g_fX33AttachOrig[client][0] = g_fX33AttachOrig[client][1] = g_fX33AttachOrig[client][2] = 0.0;

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
