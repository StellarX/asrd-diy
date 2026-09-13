/**
 * ============================================================================
 *  [AS:RD] 守望者标准型脉冲步枪 (Watcher Standard Pulse Rifle)
 *  版本 1.4.0  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ─────────────────────────────────────
 *  游戏里这把武器 (Overwatch Standard Issue Pulse Rifle / OSIPR / AR2 / 联合军脉冲步枪)
 *  只在少数特殊模式中出现, 正常挑战不会掉落。本插件让服务器主动把它的武器实体
 *  (asw_weapon_ar2) 生成在玩家身边供拾取, 并允许管理员用 ConVar 调高它造成的伤害。
 *
 *  说明: "守望者" = Overwatch, "标准型脉冲步枪" = Standard Issue Pulse Rifle,
 *  二者拼起来就是官方武器名 Overwatch Standard Issue Pulse Rifle; 游戏脚本
 *  scripts/asw_weapon_ar2.txt 第一行注释即为该名, 实体类名 asw_weapon_ar2
 *  (Source 引擎: 武器脚本文件名 <-> 实体类名 1:1)。
 *
 *  ── 管理员命令 ─────────────────────────────────────────
 *   sm_watcher_drop [玩家]  给指定玩家(或自己)在身边掉一把守望者脉冲步枪
 *   sm_watcher_status        查看当前谁拿着本插件掉落的增强步枪 / 伤害倍率 / 配色
 *   sm_watcher_color <R> <G> <B> [A]  设置掉落步枪的染色 (例: sm_watcher_color 0 200 255)
 *   sm_watcher_color <预设名>         用预设配色 (white/gold/red/orange/yellow/green/cyan/blue/purple/pink)
 *   sm_watcher_color                  不带参数 = 查看当前配色和可用预设
 *
 *  ── 玩家命令 ───────────────────────────────────────────
 *   sm_watcherdrop      在自己身边掉一把守望者脉冲步枪 (受 sm_asrd_watcher_drop_public 限制, 默认开放)
 *
 *  ── 常用 ConVar (自动生成 cfg/sourcemod/asrd_watcher_pulse_rifle.cfg) ─
 *   sm_asrd_watcher_enabled          总开关 (0=关 1=开, 默认 1)
 *   sm_asrd_watcher_dmg_mult         主武器(脉冲)伤害倍率 (默认 2.0; 仅本插件掉落的步枪享受;
 *                                    对 ALL 受害者生效: 虫族 / 场景物体 / 队友; 设为 1.0 即不改; 上限 500)
 *   sm_asrd_watcher_alt_dmg_mult     副武器(能量球)伤害倍率 (默认 2.0; 同样对所有受害者生效; 上限 500)
 *   sm_asrd_watcher_drop_public      允许玩家用 sm_watcherdrop 自己掉步枪 (0=仅管理员, 默认 1)
 *   sm_asrd_watcher_alt_ammo         副武器(能量球)弹药数量 (默认 10; 0=不覆盖, 沿用游戏默认 3; 上限 2000)
 *   sm_asrd_watcher_clip_ammo        主武器弹匣弹药量 (默认 200; 每弹夹的发数; 上限 2000)
 *   sm_asrd_watcher_reserve_clips    主武器备弹格数 (默认 4; HUD 下方弹夹格数, 4=全满; 上限 20)
 *   sm_asrd_watcher_color_r/g/b      掉落步枪染色 RGB (各 0~255, 默认 0 200 255 = 青色, 一眼可辨)
 *   sm_asrd_watcher_color_a          染色透明度 (0~255, 默认 255=不透明)
 *   sm_asrd_watcher_debug            调试输出 (默认 0)
 *   注: 该武器"不使用传统弹药", 游戏弹药箱无法直接补给 AR2 弹药类型;
 *       插件自带弹药箱检测逻辑, 站在弹药箱旁可补满备弹 (自定义实现, 不依赖游戏弹药箱系统)
 *
 *  ── 实现原理 ───────────────────────────────────────────
 *   - 在玩家控制的 marine 实体 (m_hInhabiting / m_hCommander) 旁边生成
 *     asw_weapon_ar2 武器实体 (Teleport + DispatchSpawn + ActivateEntity), 走过去即可拾取。
 *   - 用 g_bEnhancedWatcher[] 标记"本插件掉落的步枪": 仅这些实体享受伤害倍率;
 *     玩家用其它途径拿到的不会被标记, 保持原伤害。实体销毁时清除标记,
 *     避免索引复用把别的武器误判为增强步枪。
 *   - 能量球 (prop_combine_ball) 由本插件掉落的增强步枪发射时, 在生成瞬间标记
 *     g_bEnhancedBall[], 使副武器伤害也享受独立倍率。
 *   - 伤害修改: 给"所有可能受伤的实体"挂 SDKHook_OnTakeDamage (虫族 / 场景物体 /
 *     队友 marine 都覆盖, 用 g_bDamageHooked[] 去重防止倍率叠加); 当伤害来源是
 *     本插件标记的 asw_weapon_ar2 (主武器) 或标记过的 prop_combine_ball (副武器) 时,
 *     把 damage 乘以对应倍率。该方案与 asrd_chainsaw_turbo.sp 同源。
 *   - 弹药: 主武器弹匣由 sm_asrd_watcher_clip_ammo 控制 (默认 200), 主武器备弹格数由
 *     sm_asrd_watcher_reserve_clips 控制 (默认 4, 即 HUD 下方 4 格全满; 备弹=clip×clips),
 *     副武器(能量球)数量由 sm_asrd_watcher_alt_ammo 控制。三者都在"武器被 marine 拾取"时写入该 marine 的
 *     m_iAmmo[对应弹药类型] 储备池 + 武器 m_iClip1/m_iClip2, 确保主/副弹夹与备弹都填满
 *     (AR2 副弹药类型由武器 m_iSecondaryAmmoType 读取, 不硬编码)。
 *     注意: m_iAmmo 在 asw_marine 上是 sendprop 数组 (DT_ASW_Marine, 非 datamap),
 *     必须用 GetEntityNetClass + FindSendPropInfo + SetEntProp(带元素下标) 写, 写完读回验证;
 *     读回不一致时再用 SetEntData 绝对偏移直写 (CNetworkArray 数据内联, 元素步长 4 字节)。
 *   - 备弹上限同步: AR2 主/副弹药的 MaxCarry 由游戏 ConVar sk_max_ar2 (默认 180) /
 *     sk_max_ar2_altfire (默认 3) 控制。弹匣 200 时 180/200=0 弹夹, HUD 显示"备弹 0",
 *     且游戏内拾取弹药会被截断到 180。插件启动时强制 sk_max_ar2 = clip_ammo*(reserve_clips+1)
 *     (=默认 1000)、sk_max_ar2_altfire = 副武器目标值, 保证 HUD 显示 4 个弹夹且上限足够。
 *   - 弹药箱补给: 游戏自带弹药箱 (asw_ammo_drop) 的成本表不含 AR2 弹药,
 *     GetAmmoUnitCost 返回 9999 导致弹药箱对 AR2 直接判定"无法补给"。本插件每 0.25 秒
 *     检查持枪 marine 是否站在弹药箱补给半径内 (ASW_MARINE_USE_RADIUS=100), 是则从弹药箱
 *     扣减单位数并补满主/副备弹。弹药箱 m_iAmmoUnitsRemaining 为 sendprop, 可直接读写。
 *   - 换弹上限同步: 游戏换弹时 m_iClip1 补满到 GetMaxClip1()、m_iClip2 补满到 GetMaxClip2(),
 *     二者来自装备定义 ConVar asw_ammo_count_ar2 (默认 30) / asw_ammo_count_ar2_grenade
 *     (默认 3), 若不同步改大会把弹匣压回 30/3。插件启动时强制设为 sm_asrd_watcher_clip_ammo /
 *     副武器目标值, 并在 ConVar 变化时跟随更新。
 *   - 视觉标记: 给掉落的步枪染上设定色 (m_clrRender); AS:RD 武器每帧会复位该属性,
 *     故 OnGameFrame 里对增强步枪持续重涂, 保证地上/手里都稳定是设定色。
 *
 *  依赖: SourceMod 1.11+ (不依赖任何扩展, 只用核心 API + sdktools + sdkhooks)
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] 守望者标准型脉冲步枪 (Watcher Pulse Rifle)"
#define PLUGIN_VERSION "1.5.0"

// 武器实体类名: 游戏源码 scripts/asw_weapon_ar2.txt 对应实体 asw_weapon_ar2
// (Overwatch Standard Issue Pulse Rifle / AR2 / 联合军脉冲步枪)
#define WATCHER_CLASSNAME "asw_weapon_ar2"

// 副武器(能量球)实体类名: HL2 引擎自带实体, AR2 副武器发射的就是它
#define BALL_CLASSNAME "prop_combine_ball"

// 掉落步枪的默认视觉标记色 —— 青色, 运行时可用 ConVar 或 sm_watcher_color 命令自定义。
// 格式 RGBA, 直接给步枪模型染色 (m_clrRender); 默认青色与原版明显不同, 一眼可辨。
#define ENHANCED_COLOR_R 0
#define ENHANCED_COLOR_G 200
#define ENHANCED_COLOR_B 255
#define ENHANCED_COLOR_A 255

// 主武器弹匣弹药与备弹: 由 ConVar 控制, 见 OnPluginStart
//   sm_asrd_watcher_clip_ammo      弹匣弹药量 (默认 200)
//   sm_asrd_watcher_reserve_clips  备弹槽位数 (默认 4, 即 HUD 4 个备弹槽全满)
//   备弹 = clip_ammo * reserve_clips; MaxCarry = clip_ammo * (reserve_clips + 1)

// 弹药箱补给判定半径: 对齐游戏 ASW_MARINE_USE_RADIUS (marine 按 E 使用实体的距离)
#define WATCHER_BOX_RADIUS 100.0

// 弹药箱补给节奏: 每 0.25 秒检查一次 (站在弹药箱旁约 1 秒补满一次)
#define WATCHER_BOX_INTERVAL 0.25

// 弹药箱单次补给量: 主武器每次 +100 发 (耗 50 单位), 能量球每次 +3 个 (免费, 对齐 rd_refill_secondary 风格)
#define WATCHER_BOX_PRIMARY_GIVE 100
#define WATCHER_BOX_PRIMARY_COST 50
#define WATCHER_BOX_ALT_GIVE      3

// 享受增强所需的管理员权限 (仅当 sm_asrd_watcher_drop_public 为 0 时要求)
#define WATCHER_ADMIN_FLAG   ADMFLAG_GENERIC

// ============================================================================
//  ConVar 句柄
// ============================================================================
ConVar g_cvEnabled;     // 总开关
ConVar g_cvDmgMult;     // 主武器(脉冲)伤害倍率 (仅本插件掉落的步枪享受)
ConVar g_cvAltDmgMult;  // 副武器(能量球)伤害倍率 (仅本插件掉落的步枪发射的能量球享受)
ConVar g_cvDropPublic;  // 普通玩家能否用 sm_watcherdrop 自己掉步枪
ConVar g_cvAltAmmo;     // 副武器(能量球)弹药数量
ConVar g_cvClipAmmo;    // 主武器弹匣弹药量
ConVar g_cvReserveClips;// 主武器备弹槽位数
ConVar g_cvDebug;
ConVar g_cvColorR;      // 掉落步枪染色 R (0~255)
ConVar g_cvColorG;      // 掉落步枪染色 G (0~255)
ConVar g_cvColorB;      // 掉落步枪染色 B (0~255)
ConVar g_cvColorA;      // 掉落步枪染色透明度 (0~255, 255=不透明)

// ============================================================================
//  增强步枪标记: 仅本插件掉落(asw_weapon_ar2)的步枪为 true;
//  玩家用其它途径拿到的不会被标记, 保持原伤害。索引即实体编号。
bool  g_bEnhancedWatcher[2049];

//  能量球标记: 仅由增强步枪发射的 prop_combine_ball 为 true, 享受副武器倍率。
bool  g_bEnhancedBall[2049];

//  伤害钩子去重: 同一实体只挂一次 SDKHook_OnTakeDamage, 避免倍率被叠加。
bool  g_bDamageHooked[2049];

//  已为哪个持枪 marine 补过弹: 避免每帧重复写 (仅在持枪者变化时补一次)
int   g_iAppliedOwner[2049];

//  弹药箱补给下次检查时刻 (游戏时间)
float g_fNextBoxRefill;

// ============================================================================
//  插件信息
// ============================================================================
public Plugin myinfo = {
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "AS:RD 主动掉落守望者标准型脉冲步枪(AR2)并支持可调主/副武器伤害倍率",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
//  插件启动: 创建 ConVar、注册命令
// ============================================================================
public void OnPluginStart()
{
    g_cvEnabled = CreateConVar(
        "sm_asrd_watcher_enabled", "1",
        "启用/禁用守望者脉冲步枪掉落与伤害增强 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvDmgMult = CreateConVar(
        "sm_asrd_watcher_dmg_mult", "2.0",
        "主武器(脉冲)伤害倍率 (1.0=原始伤害; 仅本插件掉落的步枪享受; 对虫族/场景物体/队友均生效; 上限 500)",
        FCVAR_NOTIFY, true, 0.01, true, 500.0
    );
    g_cvAltDmgMult = CreateConVar(
        "sm_asrd_watcher_alt_dmg_mult", "2.0",
        "副武器(能量球)伤害倍率 (1.0=原始伤害; 仅本插件掉落的步枪发射的能量球享受; 对虫族/场景物体/队友均生效; 上限 500)",
        FCVAR_NOTIFY, true, 0.01, true, 500.0
    );
    g_cvDropPublic = CreateConVar(
        "sm_asrd_watcher_drop_public", "1",
        "普通玩家能否用 sm_watcherdrop 自己掉一把步枪在身边 (0=仅管理员 sm_watcher_drop)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvAltAmmo = CreateConVar(
        "sm_asrd_watcher_alt_ammo", "10",
        "副武器(能量球)弹药数量 (0=不覆盖, 沿用游戏默认 3; 设为其他值即强制给持枪者该数量的能量球; 上限 2000)",
        FCVAR_NOTIFY, true, 0.0, true, 2000.0
    );
    HookConVarChange(g_cvAltAmmo, OnAltAmmoChanged);
    g_cvClipAmmo = CreateConVar(
        "sm_asrd_watcher_clip_ammo", "200",
        "主武器弹匣弹药量 (每弹夹的发数; 默认 200; 上限 2000)",
        FCVAR_NOTIFY, true, 1.0, true, 2000.0
    );
    HookConVarChange(g_cvClipAmmo, OnClipAmmoChanged);
    g_cvReserveClips = CreateConVar(
        "sm_asrd_watcher_reserve_clips", "4",
        "主武器备弹槽位数 (HUD 显示的备弹格数; 默认 4 = 全部填满; 设 3 = 3 格满 1 格空)",
        FCVAR_NOTIFY, true, 0.0, true, 20.0
    );
    HookConVarChange(g_cvReserveClips, OnClipAmmoChanged);
    g_cvDebug = CreateConVar(
        "sm_asrd_watcher_debug", "0",
        "调试模式 (向服务器控制台输出检测/掉落/弹药日志)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    // ── 掉落步枪染色 (可用 sm_watcher_color 命令一键改) ────────────────
    g_cvColorR = CreateConVar(
        "sm_asrd_watcher_color_r", "0",
        "掉落步枪染色 - 红 (0~255)",
        FCVAR_NOTIFY, true, 0.0, true, 255.0
    );
    g_cvColorG = CreateConVar(
        "sm_asrd_watcher_color_g", "200",
        "掉落步枪染色 - 绿 (0~255)",
        FCVAR_NOTIFY, true, 0.0, true, 255.0
    );
    g_cvColorB = CreateConVar(
        "sm_asrd_watcher_color_b", "255",
        "掉落步枪染色 - 蓝 (0~255)",
        FCVAR_NOTIFY, true, 0.0, true, 255.0
    );
    g_cvColorA = CreateConVar(
        "sm_asrd_watcher_color_a", "255",
        "掉落步枪染色 - 透明度 (0~255, 255=完全不透明)",
        FCVAR_NOTIFY, true, 0.0, true, 255.0
    );

    RegAdminCmd("sm_watcher_drop",     Command_WatcherDrop,     ADMFLAG_GENERIC, "管理员给指定玩家(或自己)在身边掉一把守望者脉冲步枪");
    RegConsoleCmd("sm_watcherdrop",     Command_WatcherDropPublic, "在自己身边掉一把守望者脉冲步枪 (受 sm_asrd_watcher_drop_public 限制)");

    // 地图开始时横扫所有已存在的实体并补挂伤害钩子
    HookExistingEntities();

    // 同步游戏弹药上限 ConVar:
    //   asw_ammo_count_ar2            = 弹匣上限 (换弹补满目标, 默认 30, 不改成 200 则换弹后被压回 30)
    //   asw_ammo_count_ar2_grenade    = 能量球上限 (换弹补满目标, 默认 3, 不改成 10 则能量球被压回 3)
    SyncGameAmmoConVars();

    // 自动保存/读取配置到 cfg/sourcemod/asrd_watcher_pulse_rifle.cfg
    AutoExecConfig(true, "asrd_watcher_pulse_rifle");

    RegAdminCmd("sm_watcher_status", Command_WatcherStatus, ADMFLAG_GENERIC, "查看守望者脉冲步枪状态");
    RegAdminCmd("sm_watcher_color",  Command_WatcherColor,  ADMFLAG_GENERIC,
        "设置掉落步枪的染色: sm_watcher_color <R> <G> <B> [A] 或 <预设名>");
}

// ============================================================================
//  游戏弹药 ConVar 同步 (服务器启动时执行):
//     asw_ammo_count_ar2         弹匣上限(换弹补满目标)  -> sm_asrd_watcher_clip_ammo
//     asw_ammo_count_ar2_grenade 能量球上限(换弹补满目标) -> sm_asrd_watcher_alt_ammo
//     sk_max_ar2                 主武器备弹上限(MaxCarry) -> clip_ammo * (reserve_clips + 1)
//     sk_max_ar2_altfire         副武器备弹上限(MaxCarry) -> sm_asrd_watcher_alt_ammo
//  (前两个是 AR2 装备定义指针, 见游戏源码 asw_equipment_list.cpp 508-509 行;
//   后两个是 AR2/AR2G 弹药 MaxCarry, 见 gh_asw_gamerules.cpp 830-831/1443-1444 行)
// ============================================================================
void SyncGameAmmoConVars()
{
    int iClip = g_cvClipAmmo.IntValue;
    int iReserveClips = g_cvReserveClips.IntValue;
    int iReserve = iClip * iReserveClips;
    int iMaxCarry = iClip + iReserve;

    ConVar cvPri = FindConVar("asw_ammo_count_ar2");
    if (cvPri != null)
        cvPri.IntValue = iClip;
    else if (g_cvDebug.BoolValue)
        PrintToServer("[守望者步枪] 警告: 找不到游戏 ConVar asw_ammo_count_ar2");

    int iAlt = g_cvAltAmmo.IntValue;

    ConVar cvAlt = FindConVar("asw_ammo_count_ar2_grenade");
    if (cvAlt != null)
        cvAlt.IntValue = (iAlt > 0) ? iAlt : 3;
    else if (g_cvDebug.BoolValue)
        PrintToServer("[守望者步枪] 警告: 找不到游戏 ConVar asw_ammo_count_ar2_grenade");

    ConVar cvMaxPri = FindConVar("sk_max_ar2");
    if (cvMaxPri != null)
        cvMaxPri.IntValue = iMaxCarry;
    else if (g_cvDebug.BoolValue)
        PrintToServer("[守望者步枪] 警告: 找不到游戏 ConVar sk_max_ar2");

    ConVar cvMaxAlt = FindConVar("sk_max_ar2_altfire");
    if (cvMaxAlt != null)
        cvMaxAlt.IntValue = (iAlt > 0) ? iAlt : 3;
    else if (g_cvDebug.BoolValue)
        PrintToServer("[守望者步枪] 警告: 找不到游戏 ConVar sk_max_ar2_altfire");
}

// sm_asrd_watcher_clip_ammo 或 reserve_clips 变化时, 同步游戏 ConVar 并重补当前持枪者
public void OnClipAmmoChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    SyncGameAmmoConVars();
    // 重补所有当前持枪者
    for (int w = MaxClients + 1; w < sizeof(g_bEnhancedWatcher); w++)
    {
        if (!g_bEnhancedWatcher[w])
            continue;
        int iMarine = GetWatcherMarine(w);
        if (iMarine > 0)
        {
            ApplyWatcherAmmo(w, iMarine);
            g_iAppliedOwner[w] = iMarine;
        }
    }
}

// sm_asrd_watcher_alt_ammo 变化时, 让游戏能量球上限跟着变, 避免换弹把能量球压回旧值;
// 同时立即给所有当前持有增强步枪的玩家重补副弹, 确保新配置立刻生效
public void OnAltAmmoChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    int iAlt = g_cvAltAmmo.IntValue;
    ConVar cvAlt = FindConVar("asw_ammo_count_ar2_grenade");
    if (cvAlt != null)
        cvAlt.IntValue = (iAlt > 0) ? iAlt : 3;
    ConVar cvMaxAlt = FindConVar("sk_max_ar2_altfire");
    if (cvMaxAlt != null)
        cvMaxAlt.IntValue = (iAlt > 0) ? iAlt : 3;

    // 立即给所有正在使用增强步枪的玩家重补副弹 (让新配置立刻生效, 不用等下次换枪)
    for (int w = MaxClients + 1; w < sizeof(g_bEnhancedWatcher); w++)
    {
        if (!g_bEnhancedWatcher[w])
            continue;
        int iMarine = GetWatcherMarine(w);
        if (iMarine <= 0)
            continue;
        if (iAlt > 0)
        {
            SetWeaponClip2(w, iAlt);
            int iSec = GetWeaponAmmoType(w, "m_iSecondaryAmmoType");
            if (iSec < 0)
                iSec = 1; // 回退 AR2G
            SetMarineAmmo(iMarine, iSec, iAlt);
        }
    }
}

// ============================================================================
//  每游戏帧: 对增强步枪持续重涂染色 (AS:RD 武器会复位 m_clrRender, 只设一次会被刷掉)
// ============================================================================
public void OnGameFrame()
{
    if (!g_cvEnabled.BoolValue)
        return;

    int iR, iG, iB, iA;
    GetEnhancedColor(iR, iG, iB, iA);

    // 弹药箱补给: 每 0.25 秒检查一次 (站在弹药箱旁时补满主/副备弹)
    float fNow = GetGameTime();
    if (g_fNextBoxRefill <= fNow)
    {
        CheckAmmoBoxRefill();
        g_fNextBoxRefill = fNow + WATCHER_BOX_INTERVAL;
    }

    for (int w = MaxClients + 1; w < sizeof(g_bEnhancedWatcher); w++)
    {
        if (!g_bEnhancedWatcher[w])
            continue;
        ApplyEnhancedColor(w, iR, iG, iB, iA);

        // ── 弹药: 检测当前持枪者, 持枪者变化(含首次拾取)时补满主/副弹夹与备弹 ──
        int iMarine = GetWatcherMarine(w);
        if (iMarine > 0)
        {
            if (w < sizeof(g_iAppliedOwner) && g_iAppliedOwner[w] != iMarine)
            {
                ApplyWatcherAmmo(w, iMarine);
                g_iAppliedOwner[w] = iMarine;
            }
        }
        else if (w < sizeof(g_iAppliedOwner))
        {
            g_iAppliedOwner[w] = -1; // 没人持有时, 下次被拾取再补弹
        }
    }
}

// ============================================================================
//  找某个玩家当前控制的 marine 实体 (依次尝试三种办法)
// ============================================================================
int GetPlayerMarine(int client)
{
    if (client <= 0 || !IsClientInGame(client))
        return -1;

    // 办法1: 玩家身上的 m_hInhabiting 网络属性 (最快)
    char sNetClass[64];
    if (GetEntityNetClass(client, sNetClass, sizeof(sNetClass)))
    {
        if (FindSendPropInfo(sNetClass, "m_hInhabiting") > 0)
        {
            int iMarine = GetEntPropEnt(client, Prop_Send, "m_hInhabiting");
            if (iMarine > 0 && IsValidEntity(iMarine))
                return iMarine;
        }
    }

    // 办法2: 玩家身上的 m_hInhabiting 数据属性
    if (FindDataMapInfo(client, "m_hInhabiting") > 0)
    {
        int iMarine = GetEntPropEnt(client, Prop_Data, "m_hInhabiting");
        if (iMarine > 0 && IsValidEntity(iMarine))
            return iMarine;
    }

    // 办法3: 遍历所有 marine, 找操控者是该玩家的那个
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "asw_marine")) != -1)
    {
        if (FindDataMapInfo(entity, "m_hCommander") > 0)
        {
            if (GetEntPropEnt(entity, Prop_Data, "m_hCommander") == client)
                return entity;
        }
    }

    return -1;
}

// ============================================================================
//  伤害倍率回调挂钩目标: 给"所有可能受伤的实体"挂 SDKHook_OnTakeDamage ——
//  虫族 / 场景物体(门/可破坏物) / 队友(marine) 全覆盖。
//  用 g_bDamageHooked[] 防止重复挂钩导致倍率叠加。
// ============================================================================
void TryHookDamage(int entity)
{
    if (entity <= 0 || entity >= sizeof(g_bDamageHooked))
        return;
    if (!IsValidEntity(entity))
        return;
    // 世界(spawn)不需要挂: 墙体没有血量, 且世界实体收 OnTakeDamage 易异常
    char sClass[16];
    if (GetEntityClassname(entity, sClass, sizeof(sClass)) && StrEqual(sClass, "worldspawn"))
        return;
    if (g_bDamageHooked[entity])
        return;
    if (SDKHookEx(entity, SDKHook_OnTakeDamage, OnWatcherDamaged))
        g_bDamageHooked[entity] = true;
}

// 地图开始时横扫所有已存在的实体并补挂 (与 OnEntityCreated 互补, 靠 g_bDamageHooked 去重)
void HookExistingEntities()
{
    for (int e = 1; e < sizeof(g_bDamageHooked); e++)
        TryHookDamage(e);
}

// ============================================================================
//  掉落步枪伤害倍率 (管理员可调)
//   主武器(脉冲): 倍率 sm_asrd_watcher_dmg_mult
//   副武器(能量球 prop_combine_ball): 倍率 sm_asrd_watcher_alt_dmg_mult
//  对 ALL 受害者生效: 虫族 / 场景物体 / 队友。仅本插件掉落的"增强步枪"及其能量球享受。
// ============================================================================
public Action OnWatcherDamaged(int victim, int &attacker, int &inflictor,
    float &damage, int &damagetype, int &weapon,
    float damageForce[3], float damagePosition[3], int damagecustom)
{
    if (!g_cvEnabled.BoolValue)
        return Plugin_Continue;
    if (damage <= 0.0)
        return Plugin_Continue;
    // 不对自身伤害加成 (避免自杀/环境伤害被放大)
    if (attacker == victim)
        return Plugin_Continue;

    // ── 副武器(能量球)优先判定: inflictor 是标记过的 prop_combine_ball ──
    bool bBall = false;
    if (inflictor > 0 && IsValidEntity(inflictor))
    {
        char sInf[64];
        if (GetEntityClassname(inflictor, sInf, sizeof(sInf))
            && StrEqual(sInf, BALL_CLASSNAME, false))
        {
            if (inflictor < sizeof(g_bEnhancedBall) && g_bEnhancedBall[inflictor])
                bBall = true;
        }
    }

    // ── 主武器(脉冲直击): 伤害来源武器是标记过的 asw_weapon_ar2 ──
    bool bPrimary = false;
    if (!bBall)
    {
        int iWep = (weapon > 0 && IsValidEntity(weapon)) ? weapon : inflictor;
        if (iWep > 0 && IsValidEntity(iWep))
        {
            char sWeapon[64];
            if (GetEntityClassname(iWep, sWeapon, sizeof(sWeapon))
                && StrEqual(sWeapon, WATCHER_CLASSNAME, false)
                && iWep < sizeof(g_bEnhancedWatcher)
                && g_bEnhancedWatcher[iWep])
            {
                bPrimary = true;
            }
        }
    }

    if (!bPrimary && !bBall)
        return Plugin_Continue;

    float mult = bBall ? g_cvAltDmgMult.FloatValue : g_cvDmgMult.FloatValue;
    if (mult <= 0.0 || mult == 1.0)
        return Plugin_Continue;

    if (g_cvDebug.BoolValue)
        PrintToServer("[守望者步枪] %s 伤害倍率 x%.1f (%.1f -> %.1f) 受害者 %d",
            bBall ? "副武器(能量球)" : "主武器(脉冲)", mult, damage, damage * mult, victim);

    damage *= mult;
    return Plugin_Changed;
}

// ============================================================================
//  伤害回调挂钩: 所有实体生成即挂 + 地图开始横扫; 能量球生成时标记归属
// ============================================================================
public void OnEntityCreated(int entity, const char[] classname)
{
    TryHookDamage(entity);
    // 能量球: 延迟一帧确认归属(创建瞬间 owner 可能尚未设置), 再判断是否由增强步枪发射
    if (StrEqual(classname, BALL_CLASSNAME, false))
        RequestFrame(OnCombineBallSpawned, entity);
}

// 实体销毁: 清除增强标记/钩子标记, 避免索引复用误判
public void OnEntityDestroyed(int entity)
{
    if (entity >= 0 && entity < sizeof(g_bEnhancedWatcher))
    {
        g_bEnhancedWatcher[entity] = false;
        g_bDamageHooked[entity] = false;
    }
    if (entity >= 0 && entity < sizeof(g_iAppliedOwner))
        g_iAppliedOwner[entity] = -1;
    if (entity >= 0 && entity < sizeof(g_bEnhancedBall))
        g_bEnhancedBall[entity] = false;
}

// 能量球生成后: 若发射者手持"本插件掉落的增强步枪", 标记该球也享受副武器倍率
void OnCombineBallSpawned(any aBall)
{
    int iBall = aBall;
    if (iBall <= 0 || !IsValidEntity(iBall))
        return;

    int iOwner = GetEntPropEnt(iBall, Prop_Send, "m_hOwnerEntity");
    if (iOwner <= 0 || !IsValidEntity(iOwner))
        iOwner = GetEntPropEnt(iBall, Prop_Data, "m_hOwnerEntity");
    if (iOwner <= 0 || !IsValidEntity(iOwner))
        return;

    // 发射者可能是 marine 实体, 也可能是控制 marine 的玩家 client, 也可能直接是武器
    int iMarine = -1;
    if (IsMarine(iOwner))
    {
        iMarine = iOwner;
    }
    else if (IsWatcherRifle(iOwner))
    {
        // owner 直接是武器: 武器本身被标记过就标记球
        if (iOwner < sizeof(g_bEnhancedWatcher) && g_bEnhancedWatcher[iOwner])
            g_bEnhancedBall[iBall] = true;
        return;
    }
    else
    {
        iMarine = GetPlayerMarine(iOwner);
    }
    if (iMarine <= 0)
        return;

    int iWeapon = GetActiveWeapon(iMarine);
    if (iWeapon > 0 && iWeapon < sizeof(g_bEnhancedWatcher) && g_bEnhancedWatcher[iWeapon])
        g_bEnhancedBall[iBall] = true;
}

bool IsMarine(int entity)
{
    if (entity <= 0 || !IsValidEntity(entity))
        return false;
    char sClass[32];
    if (!GetEntityClassname(entity, sClass, sizeof(sClass)))
        return false;
    return StrEqual(sClass, "asw_marine", false);
}

bool IsWatcherRifle(int entity)
{
    if (entity <= 0 || !IsValidEntity(entity))
        return false;
    char sClass[64];
    if (!GetEntityClassname(entity, sClass, sizeof(sClass)))
        return false;
    return StrEqual(sClass, WATCHER_CLASSNAME, false);
}

// 解析某把守望者步枪当前被哪个 marine 持有 (没有持有者返回 -1)
int GetWatcherMarine(int iWeapon)
{
    if (iWeapon <= 0 || !IsValidEntity(iWeapon))
        return -1;
    int iOwner = GetEntPropEnt(iWeapon, Prop_Send, "m_hOwnerEntity");
    if (iOwner <= 0 || !IsValidEntity(iOwner))
        iOwner = GetEntPropEnt(iWeapon, Prop_Data, "m_hOwner");
    if (iOwner <= 0 || !IsValidEntity(iOwner))
        return -1;
    if (IsMarine(iOwner))
        return iOwner;
    if (IsClientInGame(iOwner))
        return GetPlayerMarine(iOwner);
    return -1;
}

// 解析某 marine 当前手持武器实体
int GetActiveWeapon(int iMarine)
{
    int iWeapon = GetEntPropEnt(iMarine, Prop_Data, "m_hActiveWeapon");
    if (iWeapon <= 0 || !IsValidEntity(iWeapon))
        iWeapon = GetEntPropEnt(iMarine, Prop_Send, "m_hActiveWeapon");
    return iWeapon;
}

// ============================================================================
//  掉落: 在玩家身边生成一把守望者脉冲步枪武器实体 (拾取后自动装备)
// ============================================================================
int SpawnWatcherRifleNear(int client)
{
    int iMarine = GetPlayerMarine(client);
    if (iMarine <= 0)
        return -1;

    float fPos[3], fAng[3];
    GetEntPropVector(iMarine, Prop_Send, "m_vecOrigin", fPos);
    GetClientEyeAngles(client, fAng);
    float fYaw = DegToRad(fAng[1]);
    fPos[0] += Cosine(fYaw) * 60.0;
    fPos[1] += Sine(fYaw) * 60.0;
    fPos[2] += 20.0;

    int iWeapon = CreateEntityByName(WATCHER_CLASSNAME);
    if (iWeapon == -1)
    {
        if (g_cvDebug.BoolValue)
            PrintToServer("[守望者步枪] CreateEntityByName(%s) 失败 (实体未注册?)", WATCHER_CLASSNAME);
        return -1;
    }

    float fZeroAng[3];
    TeleportEntity(iWeapon, fPos, fZeroAng, NULL_VECTOR);
    DispatchSpawn(iWeapon);
    ActivateEntity(iWeapon);

    // 主武器弹匣: 落地即填满 (ConVar sm_asrd_watcher_clip_ammo 控制); 拾取时 OnGameFrame 还会再补一次
    int iClip = g_cvClipAmmo.IntValue;
    int iClip1Off = GetEntitySendPropOff(iWeapon, "m_iClip1");
    if (iClip1Off != -1)
        SetEntProp(iWeapon, Prop_Send, "m_iClip1", iClip);
    else
    {
        int dm = FindDataMapInfo(iWeapon, "m_iClip1");
        if (dm != -1)
            SetEntData(iWeapon, dm, iClip, 4, true);
    }

    // 主武器备弹: 写武器实体的 m_iPrimaryAmmoCount (datamap 字段, 拾取时通过 GiveAmmo
    // 转移到 marine 的 m_iAmmo 储备池, 见 rd_asw_marine.cpp 3073 行)。
    // HUD 下方弹夹格数 = 备弹 / MaxClip1; 默认 4 格全满 = clip_ammo * 4
    int iReserve = iClip * g_cvReserveClips.IntValue;
    int iPriAmmo = FindDataMapInfo(iWeapon, "m_iPrimaryAmmoCount");
    if (iPriAmmo != -1)
        SetEntData(iWeapon, iPriAmmo, iReserve, 4, true);

    // 副武器(能量球): 落地即填 m_iClip2 (AR2 副武器走 clip2)
    int iAlt = g_cvAltAmmo.IntValue;
    if (iAlt > 0)
        SetWeaponClip2(iWeapon, iAlt);

    // 标记为"增强步枪": 仅此实体享受 sm_asrd_watcher_dmg_mult 倍率
    if (iWeapon >= 0 && iWeapon < sizeof(g_bEnhancedWatcher))
        g_bEnhancedWatcher[iWeapon] = true;
    // 重置补弹记录: 让 OnGameFrame 在该武器被 marine 拾取时补满主/副弹夹与备弹
    if (iWeapon >= 0 && iWeapon < sizeof(g_iAppliedOwner))
        g_iAppliedOwner[iWeapon] = -1;

    // 视觉标记: 按当前配色给步枪染色, 让掉落的增强步枪一眼可辨
    if (iWeapon >= 0)
        MakeEnhancedVisual(iWeapon);

    if (g_cvDebug.BoolValue)
        PrintToServer("[守望者步枪] 已在玩家 %N 身边生成 %s (实体 %d)", client, WATCHER_CLASSNAME, iWeapon);

    return iWeapon;
}

// 用实体实际网络类名查发送属性偏移 (GetEntityNetClass + FindSendPropInfo 两步,
// 与官方 HasEntProp 同一套路; 网络类名来自实体 ServerClass, 不能拿实体类名字符串硬凑)
int GetEntitySendPropOff(int entity, const char[] sProp)
{
    if (entity <= 0 || !IsValidEntity(entity))
        return -1;
    char sNetClass[64];
    if (!GetEntityNetClass(entity, sNetClass, sizeof(sNetClass)) || !sNetClass[0])
        return -1;
    return FindSendPropInfo(sNetClass, sProp);
}

// 读取武器实体的弹药类型索引 (CBaseCombatWeapon 标准属性 m_iPrimaryAmmoType / m_iSecondaryAmmoType)
//   先试 sendprop, 再试 datamap; 都查不到返回 -1
int GetWeaponAmmoType(int iWeapon, const char[] sProp)
{
    if (iWeapon <= 0 || !IsValidEntity(iWeapon))
        return -1;
    if (GetEntitySendPropOff(iWeapon, sProp) != -1)
        return GetEntProp(iWeapon, Prop_Send, sProp);
    int dm = FindDataMapInfo(iWeapon, sProp);
    if (dm != -1)
        return GetEntProp(iWeapon, Prop_Data, sProp);
    return -1;
}

// 解析 marine 实体上 m_iAmmo 发送属性偏移。
//   m_iAmmo 是 sendprop 数组 (DT_ASW_Marine 里的 SendPropArray3, 10bit 无符号, 见游戏源码
//   rd_asw_marine.cpp 第 210 行), 不在 datamap 里, 必须走 Prop_Send。
//   用 GetEntityNetClass 动态取网络类名再查, 与官方 HasEntProp 同一套路
int GetMarineAmmoOffset(int iMarine)
{
    if (iMarine <= 0 || !IsValidEntity(iMarine))
        return -1;
    return GetEntitySendPropOff(iMarine, "m_iAmmo");
}

// 读取 marine.m_iAmmo[弹药类型] 当前储备量 (读不到返回 0)
int GetMarineAmmo(int iMarine, int iAmmoType)
{
    if (iAmmoType < 0)
        return 0;
    int off = GetMarineAmmoOffset(iMarine);
    if (off == -1)
        return 0;
    return GetEntProp(iMarine, Prop_Send, "m_iAmmo", 4, iAmmoType);
}

// 给持枪 marine 的 m_iAmmo[弹药类型] 储备池写弹药数量, 写完立即读回验证。
//   关键1: asw_marine 的 m_iAmmo 是 sendprop 数组 (SendPropArray3, 非 datamap), 必须带元素下标走 Prop_Send。
//   关键2: SetEntData 兜底时第5参数必须传 changeState=true —— 默认是 false,
//          只改服务器内存不触发网络同步, 客户端 HUD 永远看不到新备弹 (见官方文档/entity.inc)。
//   写失败或读回不一致时输出调试日志, 便于在真实服务器上定位。
void SetMarineAmmo(int iMarine, int iAmmoType, int iCount)
{
    if (iAmmoType < 0 || iCount < 0)
        return;

    int off = GetMarineAmmoOffset(iMarine);
    if (off == -1)
    {
        if (g_cvDebug.BoolValue)
            PrintToServer("[守望者步枪] 设置弹药失败: 找不到 marine(%d) 的 m_iAmmo 发送属性 (弹药类型=%d)",
                iMarine, iAmmoType);
        return;
    }

    // 方案1: SourceMod 标准 sendprop 数组写入 (自动按实体网络类名解析, 触发网络同步)
    SetEntProp(iMarine, Prop_Send, "m_iAmmo", iCount, 4, iAmmoType);
    int iNow = GetEntProp(iMarine, Prop_Send, "m_iAmmo", 4, iAmmoType);
    if (iNow == iCount)
    {
        if (g_cvDebug.BoolValue)
            PrintToServer("[守望者步枪] 已写 marine %d m_iAmmo[%d]=%d (偏移 %d)",
                iMarine, iAmmoType, iCount, off);
        return;
    }

    // 方案2: 绝对偏移直写 (CNetworkArray 数据内联在 m_Value[count], 无前缀字段,
    //        FindSendPropInfo 返回的偏移即数据起点, 元素步长 4 字节)
    SetEntData(iMarine, off + iAmmoType * 4, iCount, 4, true);
    int iNow2 = GetEntProp(iMarine, Prop_Send, "m_iAmmo", 4, iAmmoType);
    if (iNow2 == iCount)
    {
        if (g_cvDebug.BoolValue)
            PrintToServer("[守望者步枪] m_iAmmo[%d] SetEntProp 读回不一致, SetEntData(偏移 %d, changeState=true) 写入成功: %d",
                iAmmoType, off + iAmmoType * 4, iCount);
        return;
    }

    // 双方案都读回不一致: 用 GetEntData 直读确认服务器内存最终值
    int iNow3 = GetEntData(iMarine, off + iAmmoType * 4, 4);
    if (g_cvDebug.BoolValue)
        PrintToServer("[守望者步枪] 警告: marine %d m_iAmmo[%d] 写入读回不一致 (期望 %d, SetEntProp后=%d, SetEntData后=%d, 内存直读=%d)",
            iMarine, iAmmoType, iCount, iNow, iNow2, iNow3);
}

// 取控制该 marine 的玩家 client (用于弹药写入回退)
int GetMarineCommander(int iMarine)
{
    if (!IsMarine(iMarine))
        return -1;
    int c = GetEntPropEnt(iMarine, Prop_Data, "m_hCommander");
    if (c > 0 && IsClientInGame(c))
        return c;
    c = GetEntPropEnt(iMarine, Prop_Send, "m_hCommander");
    if (c > 0 && IsClientInGame(c))
        return c;
    return -1;
}

// 武器被 marine 拾取时调用: 填满主武器弹匣 + 主/副备弹储备池
//   - 主武器弹匣 m_iClip1 = sm_asrd_watcher_clip_ammo (默认 200)
//   - 主武器备弹: marine.m_iAmmo[主弹药类型] = clip_ammo * reserve_clips (默认 4 格全满)
//   - 副武器(能量球): 武器 m_iClip2 = sm_asrd_watcher_alt_ammo, 同时写 marine.m_iAmmo[副弹药类型]
void ApplyWatcherAmmo(int iWeapon, int iMarine)
{
    if (iWeapon <= 0 || !IsValidEntity(iWeapon) || iMarine <= 0 || !IsValidEntity(iMarine))
        return;

    int iClip = g_cvClipAmmo.IntValue;
    int iReserve = iClip * g_cvReserveClips.IntValue;

    // 主武器弹匣填满
    int iClip1Off = GetEntitySendPropOff(iWeapon, "m_iClip1");
    if (iClip1Off != -1)
    {
        SetEntProp(iWeapon, Prop_Send, "m_iClip1", iClip);
    }
    else
    {
        int dm = FindDataMapInfo(iWeapon, "m_iClip1");
        if (dm != -1)
            SetEntData(iWeapon, dm, iClip, 4, true);
    }

    // 主武器备弹(储备)填满, 让换弹后有子弹
    // 回退 0 = AS:RD 弹药注册顺序第一个 "AR2" (见 gh_asw_gamerules.cpp GetAmmoDef 1443 行)
    int iPri = GetWeaponAmmoType(iWeapon, "m_iPrimaryAmmoType");
    if (iPri < 0)
        iPri = 0;
    SetMarineAmmo(iMarine, iPri, iReserve);

    // 副武器(能量球)弹药
    int iAlt = g_cvAltAmmo.IntValue;
    int iSec = -1;
    if (iAlt > 0)
    {
        // 回退 1 = AS:RD 弹药注册顺序第二个 "AR2G" (gh_asw_gamerules.cpp 1444 行)
        iSec = GetWeaponAmmoType(iWeapon, "m_iSecondaryAmmoType");
        if (iSec < 0)
            iSec = 1;
        // 填武器 m_iClip2 (AR2 副武器实际走 clip2, UsesClipsForAmmo2)
        SetWeaponClip2(iWeapon, iAlt);
        // 同步写储备池 (换弹补 clip2 时从池子里扣, 两边数值保持一致)
        SetMarineAmmo(iMarine, iSec, iAlt);
    }

    if (g_cvDebug.BoolValue)
        PrintToServer("[守望者步枪] 已为 marine %d 补弹: 主弹匣=%d 主备弹=%d(类型=%d) 副弹数=%d(类型=%d)",
            iMarine, iClip, iReserve, iPri, iAlt, iSec);
}

// 读取武器 m_iClip2 (AR2 副武器能量球 clip; 发送表在嵌套表 DT_ASWLocalWeaponData)
int GetWeaponClip2(int iWeapon)
{
    if (iWeapon <= 0 || !IsValidEntity(iWeapon))
        return 0;
    if (GetEntitySendPropOff(iWeapon, "m_iClip2") != -1)
        return GetEntProp(iWeapon, Prop_Send, "m_iClip2");
    int dm = FindDataMapInfo(iWeapon, "m_iClip2");
    if (dm != -1)
        return GetEntProp(iWeapon, Prop_Data, "m_iClip2");
    return 0;
}

// 写武器 m_iClip2 (能量球 clip; 发送表在嵌套表 DT_ASWLocalWeaponData)
void SetWeaponClip2(int iWeapon, int iValue)
{
    if (iWeapon <= 0 || !IsValidEntity(iWeapon))
        return;
    int off = GetEntitySendPropOff(iWeapon, "m_iClip2");
    if (off != -1)
    {
        SetEntProp(iWeapon, Prop_Send, "m_iClip2", iValue);
        int iNow = GetEntProp(iWeapon, Prop_Send, "m_iClip2");
        if (iNow != iValue)
        {
            SetEntData(iWeapon, off, iValue, 4, true);
            if (g_cvDebug.BoolValue)
                PrintToServer("[守望者步枪] m_iClip2 读回不一致 (期望 %d 实际 %d), 已用 SetEntData(changeState=true) 兜底",
                    iValue, iNow);
        }
        return;
    }
    int dm = FindDataMapInfo(iWeapon, "m_iClip2");
    if (dm != -1)
        SetEntData(iWeapon, dm, iValue, 4, true);
}

// ============================================================================
//  弹药箱补给: 游戏自带弹药箱对 AR2 无效 (成本表不含 AR2 弹药, GetAmmoUnitCost=9999),
//  本插件改为: 持枪 marine 站在弹药箱补给半径内且确实缺弹药时, 每 0.25 秒从弹药箱
//  扣单位数并补主/副备弹。只有守望者步枪为当前武器时才补 (与游戏 GetAmmoUseUnits 行为一致)。
// ============================================================================
void CheckAmmoBoxRefill()
{
    if (!g_cvEnabled.BoolValue)
        return;

    for (int w = MaxClients + 1; w < sizeof(g_bEnhancedWatcher); w++)
    {
        if (!g_bEnhancedWatcher[w])
            continue;

        int iMarine = GetWatcherMarine(w);
        if (iMarine <= 0)
            continue;
        // 仅当守望者步枪是当前武器 (玩家正端着它站在弹药箱旁)
        if (GetActiveWeapon(iMarine) != w)
            continue;

        int iClient = GetMarineCommander(iMarine);
        int iPri = GetWeaponAmmoType(w, "m_iPrimaryAmmoType");
        int iSec = GetWeaponAmmoType(w, "m_iSecondaryAmmoType");
        int iReserve = (iPri >= 0) ? GetMarineAmmo(iMarine, iPri) : 0;
        int iAltTarget = g_cvAltAmmo.IntValue;
        int iClip2 = GetWeaponClip2(w);

        int iMaxReserve = g_cvClipAmmo.IntValue * g_cvReserveClips.IntValue;
        bool bNeedPrimary = (iPri >= 0) && (iReserve < iMaxReserve);
        bool bNeedAlt = (iAltTarget > 0) && (iClip2 < iAltTarget);
        if (!bNeedPrimary && !bNeedAlt)
            continue;

        // 在补给半径内找有剩余单位的弹药箱
        float fMarinePos[3];
        GetEntPropVector(iMarine, Prop_Send, "m_vecOrigin", fMarinePos);

        int iBox = -1;
        while ((iBox = FindEntityByClassname(iBox, "asw_ammo_drop")) != -1)
        {
            if (GetEntProp(iBox, Prop_Send, "m_iAmmoUnitsRemaining") <= 0)
                continue;

            float fBoxPos[3];
            GetEntPropVector(iBox, Prop_Send, "m_vecOrigin", fBoxPos);
            float fDx = fMarinePos[0] - fBoxPos[0];
            float fDy = fMarinePos[1] - fBoxPos[1];
            float fDz = fMarinePos[2] - fBoxPos[2];
            if (fDx * fDx + fDy * fDy + fDz * fDz > WATCHER_BOX_RADIUS * WATCHER_BOX_RADIUS)
                continue;

            // ── 补给主武器备弹 ──
            if (bNeedPrimary)
            {
                int iGive = WATCHER_BOX_PRIMARY_GIVE;
                if (iReserve + iGive > iMaxReserve)
                    iGive = iMaxReserve - iReserve;
                if (iGive > 0)
                {
                    SetMarineAmmo(iMarine, iPri, iReserve + iGive);
                    int iUnits = GetEntProp(iBox, Prop_Send, "m_iAmmoUnitsRemaining");
                    int iCost = (iGive * WATCHER_BOX_PRIMARY_COST) / WATCHER_BOX_PRIMARY_GIVE;
                    if (iCost < 1)
                        iCost = 1;
                    int iLeft = iUnits - iCost;
                    if (iLeft < 0)
                        iLeft = 0;
                    SetEntProp(iBox, Prop_Send, "m_iAmmoUnitsRemaining", iLeft);
                    if (g_cvDebug.BoolValue)
                        PrintToServer("[守望者步枪] 弹药箱补给: marine %d 主备弹 %d -> %d (弹药箱剩余 %d 单位, client %d)",
                            iMarine, iReserve, iReserve + iGive, iLeft, iClient);
                }
            }

            // ── 补给能量球 (clip2) ──
            if (bNeedAlt)
            {
                int iNewClip2 = iClip2 + WATCHER_BOX_ALT_GIVE;
                if (iNewClip2 > iAltTarget)
                    iNewClip2 = iAltTarget;
                SetWeaponClip2(w, iNewClip2);
                if (iSec >= 0)
                    SetMarineAmmo(iMarine, iSec, iNewClip2);
                if (g_cvDebug.BoolValue)
                    PrintToServer("[守望者步枪] 弹药箱补给: marine %d 能量球 %d -> %d (client %d)",
                        iMarine, iClip2, iNewClip2, iClient);
            }

            break; // 每次只补给一个弹药箱
        }
    }
}

// 命令(管理员): 在身边掉落增强步枪
public Action Command_WatcherDrop(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
    {
        ReplyToCommand(client, "你必须存活才能使用此命令");
        return Plugin_Handled;
    }
    if (SpawnWatcherRifleNear(client) == -1)
    {
        ReplyToCommand(client, "创建守望者步枪失败 (实体 asw_weapon_ar2 可能未加载)");
        return Plugin_Handled;
    }
    ReplyToCommand(client, "已在身边掉落一把守望者标准型脉冲步枪");
    return Plugin_Handled;
}

// 命令(玩家): 经积分插件购买后转发到此 (需 sm_asrd_watcher_drop_public 1)
public Action Command_WatcherDropPublic(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
    {
        ReplyToCommand(client, "你必须存活才能使用此命令");
        return Plugin_Handled;
    }
    if (!g_cvDropPublic.BoolValue)
    {
        ReplyToCommand(client, "守望者步枪掉落功能未对玩家开放");
        return Plugin_Handled;
    }
    if (SpawnWatcherRifleNear(client) == -1)
    {
        ReplyToCommand(client, "创建守望者步枪失败 (实体 asw_weapon_ar2 可能未加载)");
        return Plugin_Handled;
    }
    ReplyToCommand(client, "已在身边掉落一把守望者标准型脉冲步枪, 走过去即可拾取");
    return Plugin_Handled;
}

// ============================================================================
//  状态命令(管理员): 查询时直接解析谁手持增强步枪 / 伤害倍率 / 配色
// ============================================================================
public Action Command_WatcherStatus(int client, int args)
{
    PrintToConsole(client, "========== 守望者脉冲步枪状态 (v%s) ==========", PLUGIN_VERSION);
    PrintToConsole(client, "启用: %s", g_cvEnabled.BoolValue ? "开" : "关");
    PrintToConsole(client, "主武器(脉冲)伤害倍率: x%.1f | 副武器(能量球)伤害倍率: x%.1f",
        g_cvDmgMult.FloatValue, g_cvAltDmgMult.FloatValue);
    PrintToConsole(client, "主武器弹匣: %d | 备弹格数: %d (备弹 %d) | 副武器弹药: %s",
        g_cvClipAmmo.IntValue, g_cvReserveClips.IntValue,
        g_cvClipAmmo.IntValue * g_cvReserveClips.IntValue,
        g_cvAltAmmo.IntValue > 0 ? "自定义" : "游戏默认(3)");
    if (g_cvAltAmmo.IntValue > 0)
        PrintToConsole(client, "  (副武器弹药数量 = %d)", g_cvAltAmmo.IntValue);
    PrintToConsole(client, "玩家自掉: %s", g_cvDropPublic.BoolValue ? "开" : "关");

    int cR, cG, cB, cA;
    GetEnhancedColor(cR, cG, cB, cA);
    PrintToConsole(client, "掉落步枪染色: %d %d %d (透明度 %d)", cR, cG, cB, cA);
    PrintToConsole(client, "------------------------------");

    int iCount = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i) || !IsPlayerAlive(i))
            continue;

        int iWeapon = GetHeldWatcher(i);
        if (iWeapon > 0)
        {
            iCount++;
            bool bEnhanced = (iWeapon < sizeof(g_bEnhancedWatcher) && g_bEnhancedWatcher[iWeapon]);
            PrintToConsole(client, "[%N] 手持步枪实体 %d | 增强标记=%d",
                i, iWeapon, bEnhanced ? 1 : 0);
        }
    }
    if (iCount == 0)
        PrintToConsole(client, "当前没有玩家手持本插件掉落的步枪");

    PrintToConsole(client, "==============================");
    return Plugin_Handled;
}

// 解析某玩家当前手持的守望者步枪 (没拿返回 -1)
int GetHeldWatcher(int client)
{
    int iMarine = GetPlayerMarine(client);
    if (iMarine <= 0)
        return -1;

    int iWeapon = GetEntPropEnt(iMarine, Prop_Data, "m_hActiveWeapon");
    if (iWeapon <= 0 || !IsValidEntity(iWeapon))
        iWeapon = GetEntPropEnt(iMarine, Prop_Send, "m_hActiveWeapon");
    if (iWeapon <= 0 || !IsValidEntity(iWeapon))
        return -1;

    char sClass[64];
    if (!GetEntityClassname(iWeapon, sClass, sizeof(sClass)))
        return -1;
    if (StrEqual(sClass, WATCHER_CLASSNAME))
        return iWeapon;

    return -1;
}

// ============================================================================
//  视觉标记: 仅作用于本插件掉落的增强步枪
//  - 直接给步枪模型染色 (m_clrRender + RENDER_TRANSCOLOR); 这是步枪自身属性,
//    天然跟着步枪走 —— 在地上、被捡起、被持有时都显示, 不会和步枪分离。
//  - 同时给持有者的第一人称视图模型 (m_hViewModel) 上同色, 让持枪者自己也能看出不同。
//  不影响拾取/伤害逻辑; 非本插件掉落的步枪不经过 SpawnWatcherRifleNear, 不会有此染色。
// ============================================================================
void MakeEnhancedVisual(int iWeapon)
{
    int iR, iG, iB, iA;
    GetEnhancedColor(iR, iG, iB, iA);
    ApplyEnhancedColor(iWeapon, iR, iG, iB, iA);
}

void GetEnhancedColor(int &iR, int &iG, int &iB, int &iA)
{
    iR = g_cvColorR.IntValue;
    iG = g_cvColorG.IntValue;
    iB = g_cvColorB.IntValue;
    iA = g_cvColorA.IntValue;
}

// 给增强步枪及其持有者的视图模型染上标记色 (每帧调用以对抗引擎复位)
void ApplyEnhancedColor(int iWeapon, int iR, int iG, int iB, int iA)
{
    if (!IsValidEntity(iWeapon))
        return;

    SetEntityRenderMode(iWeapon, RENDER_TRANSCOLOR);
    SetEntityRenderColor(iWeapon, iR, iG, iB, iA);

    // 持有者的第一人称视图模型也上色, 持枪者自己视角里同样是标记色
    int iOwner = GetEntPropEnt(iWeapon, Prop_Send, "m_hOwnerEntity");
    if (iOwner > 0 && IsValidEntity(iOwner))
    {
        int iVM = GetEntPropEnt(iOwner, Prop_Send, "m_hViewModel", 0);
        if (iVM > 0 && IsValidEntity(iVM))
        {
            SetEntityRenderMode(iVM, RENDER_TRANSCOLOR);
            SetEntityRenderColor(iVM, iR, iG, iB, iA);
        }
    }
}

// ---------------------------------------------------------------------------
//  预设配色表: sm_watcher_color <预设名> 直接套用
// ---------------------------------------------------------------------------
char g_sColorPresets[][] = {
    "white", "gold", "red", "orange", "yellow",
    "green", "cyan", "blue", "purple", "pink"
};
int  g_iColorPresets[][] = {
    {255, 255, 255},   // white  纯白
    {255, 215, 0},     // gold   金色
    {255, 0, 0},       // red    红色
    {255, 128, 0},     // orange 橙色
    {255, 255, 0},     // yellow 黄色
    {0, 255, 0},       // green  绿色
    {0, 255, 255},     // cyan   青色 (默认)
    {0, 128, 255},     // blue   蓝色
    {160, 32, 240},    // purple 紫色
    {255, 105, 180}    // pink   粉色
};

// 命令(管理员): 设置/查看掉落步枪的染色
public Action Command_WatcherColor(int client, int args)
{
    if (args == 0)
    {
        int iR, iG, iB, iA;
        GetEnhancedColor(iR, iG, iB, iA);
        ReplyToCommand(client, "当前掉落步枪染色: %d %d %d (透明度 %d)", iR, iG, iB, iA);
        ReplyToCommand(client, "用法: sm_watcher_color <R> <G> <B> [A]   例: sm_watcher_color 0 200 255");
        ReplyToCommand(client, "或:   sm_watcher_color <预设名>          可选: white gold red orange yellow green cyan blue purple pink");
        return Plugin_Handled;
    }

    char sArg[32];
    GetCmdArg(1, sArg, sizeof(sArg));

    // 预设名 (英文)
    int iPreset = FindColorPreset(sArg);
    if (iPreset >= 0)
    {
        g_cvColorR.IntValue = g_iColorPresets[iPreset][0];
        g_cvColorG.IntValue = g_iColorPresets[iPreset][1];
        g_cvColorB.IntValue = g_iColorPresets[iPreset][2];
        ReplyToCommand(client, "掉落步枪染色已设为 %s (%d %d %d)",
            g_sColorPresets[iPreset], g_iColorPresets[iPreset][0],
            g_iColorPresets[iPreset][1], g_iColorPresets[iPreset][2]);
        return Plugin_Handled;
    }

    // 自定义 RGB(A)
    if (args < 3)
    {
        ReplyToCommand(client, "参数不足: 需要 <R> <G> <B> [A], 或给一个预设名 (如 cyan)");
        return Plugin_Handled;
    }

    char sG[16], sB[16], sA[16];
    GetCmdArg(2, sG, sizeof(sG));
    GetCmdArg(3, sB, sizeof(sB));
    sA = "255";
    if (args >= 4)
        GetCmdArg(4, sA, sizeof(sA));

    int iR = Clamp255(StringToInt(sArg));
    int iG = Clamp255(StringToInt(sG));
    int iB = Clamp255(StringToInt(sB));
    int iA = Clamp255(StringToInt(sA));

    g_cvColorR.IntValue = iR;
    g_cvColorG.IntValue = iG;
    g_cvColorB.IntValue = iB;
    g_cvColorA.IntValue = iA;

    ReplyToCommand(client, "掉落步枪染色已设为 %d %d %d (透明度 %d)", iR, iG, iB, iA);
    return Plugin_Handled;
}

int FindColorPreset(const char[] sName)
{
    for (int i = 0; i < sizeof(g_sColorPresets); i++)
    {
        if (StrEqual(sName, g_sColorPresets[i], false))
            return i;
    }
    // 中文别名
    if (StrEqual(sName, "白色", false)) return 0;
    if (StrEqual(sName, "金色", false)) return 1;
    if (StrEqual(sName, "红色", false)) return 2;
    if (StrEqual(sName, "橙色", false)) return 3;
    if (StrEqual(sName, "黄色", false)) return 4;
    if (StrEqual(sName, "绿色", false)) return 5;
    if (StrEqual(sName, "青色", false)) return 6;
    if (StrEqual(sName, "蓝色", false)) return 7;
    if (StrEqual(sName, "紫色", false)) return 8;
    if (StrEqual(sName, "粉色", false)) return 9;
    return -1;
}

int Clamp255(int iValue)
{
    if (iValue < 0)   return 0;
    if (iValue > 255) return 255;
    return iValue;
}
