/**
 * ============================================================================
 *  [AS:RD] L3a 重型战术护甲增强 (Armor)
 *  版本 2.0.3  |  (2.0.3: 取消护甲破损时的"变红+闪烁"提示, 无论破损与否一律显示 "护甲厚度：N")
 *                 (2.0.2: 穿戴提示改为"减伤，移速，防蚊虫叮咬、烧烤、寄生，部分武器免伤。")
 *                 (2.0.1: 新增火焰伤害完全免伤 sm_asrd_armor_immune_burn — 燃烧地雷/地图火焰/燃烧弹等按 DMG_BURN 拦截, 不掉血不消耗护甲层)  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ──────────────────────────────────────
 *  对陆战队员的 L3a 重型战术护甲 (实体 asw_weapon_normal_armor) 增强:
 *    1. 自定义默认参数: 用插件 ConVar 作"真源", 把引擎护甲 ConVar 设为一套
 *       新基准 (倍率 0.2 / 总涂层 20 / 停手 3s 后开始恢复 / 每层 1s)。
 *       —— 全部参数在 cfg/sourcemod/asrd_armor.cfg 中可改 (插件重载/换图生效)。
 *    2. 穿戴提示: 玩家穿上护甲后在聊天框私聊通知“已穿戴 IAF 动力护甲”。
 *    3. 层数 HUD: 屏幕上常驻显示该玩家当前的护甲剩余层数 ("护甲厚度：N"),
 *       仅本人可见, 显示位置/颜色可配置; 护甲破损与否都显示同一字样。
 *    4. 移速加成: 穿戴护甲时按加成倍率提升移速 (写 AS:RD 的 m_fSpeedScale)。
 *    5. 免伤: 穿戴护甲时免疫一组指定武器的伤害 (默认: 火枪/步枪/毒气手雷等),
 *       并对火焰伤害 (燃烧地雷/地图火焰/燃烧弹, 引擎标志 DMG_BURN) 完全免伤,
 *       不掉血也不消耗护甲层 (开关 sm_asrd_armor_immune_burn, 默认开)。
 *    6. 管理员指令: 掉落护甲 / 改属性 / 查状态。
 *
 *  ── 插件 ConVar (cfg/sourcemod/asrd_armor.cfg) ─────────
 *   sm_asrd_armor_scale       基础减伤倍率 (默认 0.2, 越小越强, 0=全免, 1=不减伤)
 *   sm_asrd_armor_layers      护甲总涂层数 (默认 20)
 *   sm_asrd_armor_protection  每层吸收伤害比例 (默认 0.04)
 *   sm_asrd_armor_delay       停手后开始恢复一层的延迟秒数 (默认 3)
 *   sm_asrd_armor_interval    之后每层恢复间隔秒数 (默认 1)
 *   sm_asrd_armor_recover_maxspeed  停手后护甲层最高恢复速度
 *                            (层/秒, 默认 3)。以本次待恢复层数为基数, 按已恢复比例
 *                            分三档提速(默认 1→2→3 层/秒); 0=恒定基础速度
 *   sm_asrd_armor_enabled     护甲掉层/恢复机制开关 (默认 1)
 *   sm_asrd_armor_speed_bonus 穿戴时的移速加成 (默认 0.1 = +10%; 0=不加)
 *   sm_asrd_armor_hud_enabled 穿戴层数 HUD 开关 (默认 1)
 *   sm_asrd_armor_hud_x       HUD 横向位置 (默认 0.01; -1=水平居中)
 *   sm_asrd_armor_hud_y       HUD 纵向位置 (默认 0.06)
 *   sm_asrd_armor_hud_channel HUD 通道 (默认 7, 避开 4/5/6 其它插件)
 *   sm_asrd_armor_hud_r/g/b    HUD 颜色 (默认 0/255/200)
 *   sm_asrd_armor_notify      穿戴聊天通知开关 (默认 1)
 *   sm_asrd_armor_immune      免伤武器列表 (空格分隔的实体类名)
 *   sm_asrd_armor_immune_burn 火焰伤害完全免伤 (默认 1; 燃烧地雷/地图火焰/燃烧弹等
 *                            按 DMG_BURN 拦截, 不消耗护甲层; 0=火焰照常烧甲)
 *
 *  ── 管理员命令 (ADMFLAG_GENERIC) ────────────────────────
 *   sm_asrd_armor                         查看属性面板
 *   sm_asrd_armor set <键> <值>          修改属性 (键: 同各 ConVar 同名部分)
 *   sm_asrd_armor drop [目标]            掉落玩家的重甲 (名字/#userid/me/@all)
 *   sm_asrd_armor status                 查属性 + 各玩家护甲层数
 *   sm_asrd_armor reset                  恢复默认参数
 *   sm_armor                             别名
 * ============================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] Armor"
#define PLUGIN_VERSION "2.0.3"

#define ARMOR_CLASS  "asw_weapon_normal_armor"
#define MARINE_CLASS "asw_marine"
#define PARASITE_CLASS  "asw_parasite"
#define PARASITE_DEF_CLASS "asw_parasite_defanged"

// DMG_INFEST 未在 SourceMod 头文件预定义; 源码中 = DMG_AIRBOAT = (1<<25)
#define DMG_INFEST  (1 << 25)

// 默认参数 (首装/ reset 时写回插件 ConVar)
#define CFG_SCALE        0.2
#define CFG_LAYERS       20
#define CFG_PROTECTION   0.04
#define CFG_DELAY        3.0
#define CFG_INTERVAL     1.0
#define CFG_MAXSPEED     3.0
#define CFG_ENABLED      1
#define CFG_SPEED_BONUS  0.3
#define CFG_REGEN        2.0
#define CFG_HUD_X        0.01
#define CFG_HUD_Y        0.06
#define CFG_HUD_CH       7
#define CFG_IMMUNE       "asw_weapon_flamer asw_weapon_rifle asw_weapon_gas_grenades asw_flamer_projectile asw_gas_grenade_projectile asw_parasite asw_parasite_defanged asw_mine asw_firewall_piece env_fire"

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

// 引擎护甲 ConVar 句柄
ConVar g_cvScale;
ConVar g_cvLayers;
ConVar g_cvProtection;
ConVar g_cvDelay;
ConVar g_cvInterval;
ConVar g_cvLayersEnabled;

// 插件 ConVar (真源, 会写入 cfg/sourcemod/asrd_armor.cfg)
ConVar g_ScaleCv;
ConVar g_LayersCv;
ConVar g_ProtectionCv;
ConVar g_DelayCv;
ConVar g_IntervalCv;
ConVar g_EnabledCv;
ConVar g_SpeedBonusCv;
ConVar g_HudEnabledCv;
ConVar g_HudXCv;
ConVar g_HudYCv;
ConVar g_HudChCv;
ConVar g_HudRCv;
ConVar g_HudGCv;
ConVar g_HudBCv;
ConVar g_NotifyCv;
ConVar g_ImmuneCv;
ConVar g_ImmuneBurnCv; // 火焰伤害完全免伤开关 (DMG_BURN, 默认 1)
ConVar g_RegenCv;   // 护甲满护免伤时缓慢回血速率 (生命/秒, 0=关闭)
ConVar g_MaxSpeedCv; // 护甲层恢复的最高速度 (层/秒)

// 免伤列表缓存
#define MAX_IMMUNE 16
char g_sImmune[MAX_IMMUNE][64];
int  g_iImmuneCount;

// 上一帧是否穿戴护甲 (用于穿戴转换检测: 通知/移速恢复)
bool g_bPrevWorn[MAXPLAYERS + 1];
float g_fLastHudTime;
// 缓慢回血的浮点累积 (避免整数血量逐 tick 取整丢失, 攒够 1 点再一次性加)
float g_fRegenAccum[MAXPLAYERS + 1];

// 护甲层"插件接管恢复"的逐玩家状态:
//   hitTimer   = 上次受击掉层的时刻
//   accum      = 恢复节律的浮点累积 (攒够 1 层才恢复)
//   lastMiss   = 上一帧记录的缺失层数 (用于检测掉层=受击)
//   restoreBase= 本次"待恢复总量" (受击/首穿那一刻的缺失层数, 作为分档加速的基数)
//   tracking   = 是否已开始跟踪该玩家护甲 (首次穿戴时初始化)
float g_fArmorHitTimer[MAXPLAYERS + 1];
float g_fArmorAccum[MAXPLAYERS + 1];
int   g_iArmorLastMissing[MAXPLAYERS + 1];
int   g_iArmorRestoreBase[MAXPLAYERS + 1];
bool  g_bArmorTracking[MAXPLAYERS + 1];

// ============================================================================
//  Plugin / 配置初始化
// ============================================================================
public Plugin myinfo =
{
    name = PLUGIN_NAME,
    author = "AS:RD",
    description = "L3a 重型战术护甲增强: 自定义参数/穿戴提示/层数HUD/移速加成/免伤",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    FindEngineCvars();

    // 插件 ConVar (真源, 自动生成/读取 cfg/sourcemod/asrd_armor.cfg)
    g_ScaleCv        = CreateConVar("sm_asrd_armor_scale",       "0.2",  "基础减伤倍率 (越小越强, 0=全免, 1=不减伤)");
    g_LayersCv       = CreateConVar("sm_asrd_armor_layers",      "20",   "护甲总涂层数");
    g_ProtectionCv   = CreateConVar("sm_asrd_armor_protection",  "0.04", "每层吸收的伤害比例");
    g_DelayCv        = CreateConVar("sm_asrd_armor_delay",       "3",    "停手后开始恢复一层的延迟秒数");
    g_IntervalCv     = CreateConVar("sm_asrd_armor_interval",    "1",    "之后每层恢复间隔秒数");
    g_EnabledCv      = CreateConVar("sm_asrd_armor_enabled",     "1",    "护甲掉层/恢复机制开关");
    g_SpeedBonusCv   = CreateConVar("sm_asrd_armor_speed_bonus", "0.3",  "穿戴护甲时的移速加成 (0.3 = +30%, 0=不加; 与强化移速取较大值)");
    g_HudEnabledCv   = CreateConVar("sm_asrd_armor_hud_enabled", "1",    "穿戴层数 HUD 开关");
    g_HudXCv         = CreateConVar("sm_asrd_armor_hud_x",       "0.01", "HUD 横向位置 (0~1, -1=水平居中)");
    g_HudYCv         = CreateConVar("sm_asrd_armor_hud_y",       "0.06", "HUD 纵向位置 (0~1)");
    g_HudChCv        = CreateConVar("sm_asrd_armor_hud_channel", "7",    "HUD 通道 (避开其它插件占用的 4/5/6)");
    g_HudRCv         = CreateConVar("sm_asrd_armor_hud_r",       "0",    "HUD 文字红色");
    g_HudGCv         = CreateConVar("sm_asrd_armor_hud_g",       "255",  "HUD 文字绿色");
    g_HudBCv         = CreateConVar("sm_asrd_armor_hud_b",       "200",  "HUD 文字蓝色");
    g_NotifyCv       = CreateConVar("sm_asrd_armor_notify",      "1",    "穿戴护甲聊天通知开关");
    g_ImmuneCv       = CreateConVar("sm_asrd_armor_immune",      CFG_IMMUNE, "免伤武器实体类名列表 (空格分隔)");
    g_ImmuneBurnCv   = CreateConVar("sm_asrd_armor_immune_burn", "1", "火焰伤害完全免伤: 燃烧地雷/地图火焰/燃烧弹等 (DMG_BURN) 不掉血不消耗护甲层 (0=火焰照常烧甲)");
    g_RegenCv         = CreateConVar("sm_asrd_armor_regen",       "2",     "护甲满护免伤时缓慢回血速率 (生命/秒, 0=关闭)");
    g_MaxSpeedCv      = CreateConVar("sm_asrd_armor_recover_maxspeed","3", "护甲层最高恢复速度 (层/秒): 以本次待恢复层数为基数, 按已恢复比例分三档提速(默认 1→2→3 层/秒) (0=恒定基础速度)");

    // 首次加载生成 / 每次加载执行 cfg/sourcemod/asrd_armor.cfg
    //   需在所有 CreateConVar 之后调用, 才会把上面的参数写进配置文件
    AutoExecConfig(true, "asrd_armor");

    // ConVar 一变即重新映射到引擎护甲参数 / 刷新免伤列表
    HookConVarChange(g_ScaleCv,      OnArmorCvarChanged);
    HookConVarChange(g_LayersCv,     OnArmorCvarChanged);
    HookConVarChange(g_ProtectionCv, OnArmorCvarChanged);
    HookConVarChange(g_DelayCv,      OnArmorCvarChanged);
    HookConVarChange(g_IntervalCv,   OnArmorCvarChanged);
    HookConVarChange(g_EnabledCv,    OnArmorCvarChanged);
    HookConVarChange(g_ImmuneCv,     OnArmorCvarChanged);

    // 初次映射
    ApplyAllToEngine();
    RefreshImmune();

    RegAdminCmd("sm_asrd_armor", Cmd_Armor, ADMFLAG_GENERIC,
        "L3a 护甲管理: sm_asrd_armor [set <键> <值> | drop [目标] | status | reset]");
    RegAdminCmd("sm_armor", Cmd_Armor, ADMFLAG_GENERIC, "L3a 护甲管理 (sm_asrd_armor 别名)");

    // 自杀命令绕过护甲: 拦截 asw_suicide, 改用护甲豁免的伤害类型直接致死
    AddCommandListener(Cmd_Suicide, "asw_suicide");
}

void FindEngineCvars()
{
    g_cvScale          = FindConVar("asw_marine_passive_armor_scale");
    g_cvLayers         = FindConVar("rd_marine_passive_armor_layers_amount");
    g_cvProtection     = FindConVar("rd_marine_passive_armor_layer_protection_value");
    g_cvDelay          = FindConVar("rd_marine_passive_armor_layer_update_interval_initial");
    g_cvInterval       = FindConVar("rd_marine_passive_armor_layer_update_interval");
    g_cvLayersEnabled  = FindConVar("rd_marine_passive_armor_layers_enabled");
}

public void OnConfigsExecuted()
{
    // cfg 已执行完, 再应用一次以确保 cfg 里改的值反映到引擎
    ApplyAllToEngine();
}

public void OnMapStart()
{
    for (int i = 1; i <= MaxClients; i++)
        g_bPrevWorn[i] = false;
    g_fLastHudTime = 0.0;
}

void ApplyAllToEngine()
{
    if (g_cvScale == null || g_LayersCv == null)
        return;   // 引擎 ConVar 没找到就什么都不做, 避免写坏

    // 减伤相关参数仍映射给引擎; 但"护甲层恢复"改由插件接管, 因此把引擎的两个恢复计时器
    // ConVar 顶到极大值, 让引擎原生 LayerRestoreThink 基本不再触发, 避免与插件加速节律冲突。
    SetConVarFloat(g_cvDelay,          9999.0);
    SetConVarFloat(g_cvLayers,          g_LayersCv.FloatValue);
    SetConVarFloat(g_cvProtection,      g_ProtectionCv.FloatValue);
    SetConVarFloat(g_cvInterval,       9999.0);
    SetConVarInt(g_cvLayersEnabled,     g_EnabledCv.IntValue >= 1 ? 1 : 0);
    SetConVarFloat(g_cvScale,           g_ScaleCv.FloatValue);
}

public void OnArmorCvarChanged(ConVar cv, const char[] oldv, const char[] newv)
{
    ApplyAllToEngine();
    RefreshImmune();
}

void RefreshImmune()
{
    g_iImmuneCount = 0;
    char sFull[512];
    GetConVarString(g_ImmuneCv, sFull, sizeof(sFull));
    char sParts[MAX_IMMUNE][64];
    int n = ExplodeString(sFull, " ", sParts, MAX_IMMUNE, 64, false);
    for (int i = 0; i < n; i++)
    {
        TrimString(sParts[i]);
        if (sParts[i][0] == '\0')
            continue;
        if (g_iImmuneCount >= MAX_IMMUNE)
            break;
        strcopy(g_sImmune[g_iImmuneCount], 64, sParts[i]);
        g_iImmuneCount++;
    }
}

// 为新生成的陆战队员挂上免伤回调
public void OnEntityCreated(int entity, const char[] classname)
{
    if (entity <= 0)
        return;
    if (StrEqual(classname, MARINE_CLASS, false))
        SDKHook(entity, SDKHook_OnTakeDamage, OnMarineDamaged);
    else if (StrEqual(classname, PARASITE_CLASS, false) || StrEqual(classname, PARASITE_DEF_CLASS, false))
        SDKHook(entity, SDKHook_Touch, OnParasiteTouch);
}

// ============================================================================
//  免伤: 穿戴护甲的陆战队员免疫免伤列表中的武器伤害
// ============================================================================
public Action OnMarineDamaged(int victim, int &attacker, int &inflictor,
    float &damage, int &damagetype)
{
    if (!MarineHasArmor(victim))
        return Plugin_Continue;

    // 寄生虫寄生/吸血伤害: attacker/inflictor 均为 NULL, 只能靠 DMG_INFEST 标志识别。
    // 阻断吸血(不掉血), 并清除已附着的寄生虫(消除寄生视觉)。
    if (damagetype & DMG_INFEST)
    {
        KillAttachedParasites(victim);
        return Plugin_Handled;
    }

    // 火焰伤害: AS:RD 引擎统一打 DMG_BURN 标志 — 燃烧地雷 (弹药类型 ASW_MINES,
    // asw_gamerules.cpp AddAmmoType) / 地图火焰与附着燃烧 (EntityFlame.cpp:
    // DMG_BURN 或 DMG_BURN|DMG_DIRECT) / 自然火 (fire.cpp FIRE_NATURAL) / 燃烧弹等。
    // 穿甲完全免伤: 不掉血也不消耗护甲层。类名列表对火焰不可靠 (火焰伤害的
    // attacker/inflictor 常是火焰实体或 NULL), 故按伤害类型兜底。
    // 注: AS:RD 中 DMG_SLOWBURN 是冷冻 (asw_shareddefs.h: #define DMG_COLD DMG_SLOWBURN), 不拦。
    if (g_ImmuneBurnCv.BoolValue && (damagetype & DMG_BURN))
        return Plugin_Handled;

    // 几乎所有枪械: 陆战队员实弹枪械(步枪/手枪/冲锋枪/霰弹等)均以 DMG_BULLET 造成伤害,
    // 穿戴护甲时对这些子弹伤害免伤。(能量武器如 railgun 走 DMG_SONIC, 不在此列)
    if (damagetype & DMG_BULLET)
        return Plugin_Handled;

    if (IsImmuneEntity(attacker) || IsImmuneEntity(inflictor))
        return Plugin_Handled;

    return Plugin_Continue;
}

// 阻止寄生虫"选中/寄生"穿戴护甲的陆战队员: 拦截接触即可跳过寄生流程 (NormalTouch→InfestMarine)
public Action OnParasiteTouch(int parasite, int other)
{
    if (MarineHasArmor(other))
        return Plugin_Handled;
    return Plugin_Continue;
}

// 移除已附着(寄生)在指定陆战队员身上的寄生虫实体
void KillAttachedParasites(int victim)
{
    char sClasses[2][24] = { PARASITE_CLASS, PARASITE_DEF_CLASS };
    for (int i = 0; i < 2; i++)
    {
        int ent = -1;
        while ((ent = FindEntityByClassname(ent, sClasses[i])) != -1)
        {
            // 寄生虫寄生时会 SetParent 到陆战队员身上
            if (GetEntPropEnt(ent, Prop_Data, "m_pParent") == victim)
                AcceptEntityInput(ent, "Kill");
        }
    }
}

bool IsImmuneEntity(int ent)
{
    if (ent <= 0 || ent > 2048)
        return false;
    char sClass[64];
    if (!GetEntityClassname(ent, sClass, sizeof(sClass)))
        return false;
    for (int i = 0; i < g_iImmuneCount; i++)
    {
        if (StrEqual(sClass, g_sImmune[i], false))
            return true;
    }
    return false;
}

// ============================================================================
//  帧回调: HUD 层数 + 穿戴检测(通知) + 移速 (每 0.1 秒节流)
// ============================================================================
public void OnGameFrame()
{
    float fNow = GetEngineTime();
    float fElapsed = fNow - g_fLastHudTime;
    if (fElapsed < 0.1)
        return;
    g_fLastHudTime = fNow;

    int iLayersMax = g_LayersCv.IntValue;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsUsableClient(i) || !IsActivePlayer(i))
        {
            // 非活跃: 若之前叠加了状态, 复位
            if (g_bPrevWorn[i])
            {
                g_bPrevWorn[i] = false;
                RestoreSpeed(i);
                ClearHud(i);
            }
            continue;
        }

        bool bWorn = (GetArmorForClient(i) > 0);

        // 穿戴状态转换检测
        if (bWorn && !g_bPrevWorn[i])
        {
            if (g_NotifyCv.IntValue >= 1)
                PrintToChat(i, "\x04[护甲]\x01 你已穿戴 \x05IAF 动力护甲\x01, 护甲层 \x05%d\x01 层: 减伤，移速，防蚊虫叮咬、烧烤、寄生，部分武器免伤。", iLayersMax);
        }

        // 移速: 穿戴时取 max(护甲加成, 强化移速)为最终值; 刚掉落/脱下时还原为强化倍率(无强化=1.0)
        int marine = GetClientMarine(i);
        if (marine > 0 && HasEntProp(marine, Prop_Send, "m_fSpeedScale"))
        {
            if (bWorn)
            {
                float fFinal = GetPowerSpeedMul(i);
                float fArmor = 1.0 + g_SpeedBonusCv.FloatValue;
                if (fArmor > fFinal)
                    fFinal = fArmor;
                SetEntPropFloat(marine, Prop_Send, "m_fSpeedScale", fFinal);
            }
            else if (g_bPrevWorn[i])
            {
                SetEntPropFloat(marine, Prop_Send, "m_fSpeedScale", GetPowerSpeedMul(i));
            }
        }

        // HUD 显示当前剩余层数
        if (bWorn)
        {
            int missing = GetEntProp(GetArmorForClient(i), Prop_Send, "m_iLayersMissing");

            // 携带榴弹发射器: 护甲有效总层数降至 3 (榴弹伤害大, 高护甲层会近乎无敌)。
            // 丢弃后由已有恢复机制按"本次待恢复量为基数"慢慢加速补回。
            bool bHasGL = HasGrenadeLauncher(marine);
            if (bHasGL)
            {
                int forcedMissing = iLayersMax - 3;
                if (missing < forcedMissing)
                {
                    SetEntProp(GetArmorForClient(i), Prop_Send, "m_iLayersMissing", forcedMissing);
                    missing = forcedMissing;
                }
                // 固定层数期间不做恢复: 重设恢复基准并把停手计时置为过去, 丢弃后立即开始缓慢恢复
                g_iArmorLastMissing[i] = missing;
                g_iArmorRestoreBase[i] = missing;
                g_fArmorAccum[i] = 0.0;
                g_fArmorHitTimer[i] = 0.0;
            }

            int left = iLayersMax - missing;
            if (left < 0) left = 0;
            DrawArmorHud(i, left);

            // 插件接管恢复: 首次穿戴初始化; 之后检测掉层(受击)刷新停手计时
            if (!g_bArmorTracking[i])
            {
                g_bArmorTracking[i] = true;
                g_iArmorLastMissing[i] = missing;
                g_iArmorRestoreBase[i] = missing;
                g_fArmorHitTimer[i] = fNow;
                g_fArmorAccum[i] = 0.0;
            }
            else if (missing > g_iArmorLastMissing[i])
            {
                // 掉层 = 刚受伤: 停手计时器归零, 恢复进度清零, 本次待恢复总量刷新
                g_iArmorRestoreBase[i] = missing;
                g_fArmorHitTimer[i] = fNow;
                g_fArmorAccum[i] = 0.0;
            }
            g_iArmorLastMissing[i] = missing;

            // 护甲层恢复 (停手 delay 秒后开始, 以本次待恢复量为基数分三档提速: 1→2→3 层/秒)
            // 携带榴弹发射器时层数固定为 3, 不自动恢复
            if (g_EnabledCv.IntValue >= 1 && missing > 0 && !bHasGL)
                TryArmorRestore(i, missing, fElapsed, fNow);

            // 下一击完全免伤且未满血 → 缓慢回血
            if (ComputeScale(left) < 0.0001)
                TryPassiveRegen(i, fElapsed);
        }
        else if (g_bPrevWorn[i])
        {
            ClearHud(i);
            g_fRegenAccum[i] = 0.0;
            g_bArmorTracking[i] = false;
            g_fArmorAccum[i] = 0.0;
        }

        g_bPrevWorn[i] = bWorn;
    }

    // 观战者视角: 让正在观战某护甲佩戴者的玩家, 看到与佩戴者一致的护甲 HUD
    if (g_HudEnabledCv.IntValue >= 1)
    {
        for (int j = 1; j <= MaxClients; j++)
        {
            if (!IsUsableClient(j))
                continue;

            int target = GetEntPropEnt(j, Prop_Send, "m_hObserverTarget");
            if (target <= 0)
                continue;   // 未在观战

            int owner = GetCommanderClient(target);   // 被观战陆战队员的佩戴者 client
            if (owner <= 0 || owner == j)
                continue;   // 跳观看自己
            if (GetArmorForClient(owner) <= 0)
                continue;   // 佩戴者没穿护甲

            int missing = GetEntProp(GetArmorForClient(owner), Prop_Send, "m_iLayersMissing");
            int left = iLayersMax - missing;
            if (left < 0) left = 0;
            DrawArmorHud(j, left);
        }
    }
}

// 恢复移速的便捷封装 (海洋里传 client 或 marine)
void RestoreSpeed(int client)
{
    int marine = GetClientMarine(client);
    if (marine > 0 && HasEntProp(marine, Prop_Send, "m_fSpeedScale"))
        SetEntPropFloat(marine, Prop_Send, "m_fSpeedScale", 1.0);
}

void DrawArmorHud(int client, int left)
{
    if (g_HudEnabledCv.IntValue < 1)
        return;

    float fX = g_HudXCv.FloatValue;
    float fY = g_HudYCv.FloatValue;

    if (g_EnabledCv.IntValue >= 1)
    {
        // 护甲无论是否破损, 统一显示 "护甲厚度：N", 颜色用配置值 (不做变红/闪烁)
        SetHudTextParams(fX, fY, 0.6, g_HudRCv.IntValue, g_HudGCv.IntValue, g_HudBCv.IntValue, 210, 0, 0.0, 0.1, 0.1);
        ShowHudText(client, g_HudChCv.IntValue, "护甲厚度：%d", left);
    }
    else
    {
        SetHudTextParams(fX, fY, 0.6, g_HudRCv.IntValue, g_HudGCv.IntValue, g_HudBCv.IntValue, 210, 0, 0.0, 0.1, 0.1);
        ShowHudText(client, g_HudChCv.IntValue, "动力护甲：层机制已关闭");
    }
}

// 按当前护甲参数计算"受下一击"的减伤系数 (与引擎 GetDamageScaleFactor 同式):
//   scale = sm_asrd_armor_scale − (总层 − 掉层后缺失) × sm_asrd_armor_protection, 最小 0
//   注: 引擎结算时"受击先掉一层护甲", 故缺失率用 当前缺失+1 代入。
float ComputeScale(int left)
{
    int iTotal = g_LayersCv.IntValue;
    if (left > iTotal) left = iTotal;

    int iMiss = iTotal - left;      // 当前缺失层数
    int iMissNext = iMiss + 1;      // 受下一击会先掉一层, 再按该层数缩放
    if (iMissNext > iTotal) iMissNext = iTotal;

    float flScale = g_ScaleCv.FloatValue - (iTotal - iMissNext) * g_ProtectionCv.FloatValue;
    return (flScale < 0.0) ? 0.0 : flScale;
}

// 护甲满护免伤时的缓慢回血: 按速率每秒累积, 攒够整数点再一次性加给陆战队员
void TryPassiveRegen(int client, float fElapsed)
{
    float fRate = g_RegenCv.FloatValue;
    if (fRate <= 0.0)
        return;

    int marine = GetClientMarine(client);
    if (marine <= 0)
        return;

    float fHealth = float(GetEntProp(marine, Prop_Data, "m_iHealth"));
    float fMax     = float(GetEntProp(marine, Prop_Data, "m_iMaxHealth"));
    if (fHealth >= fMax)
    {
        g_fRegenAccum[client] = 0.0;
        return;
    }

    g_fRegenAccum[client] += fRate * fElapsed;
    int iGain = RoundToFloor(g_fRegenAccum[client]);
    if (iGain <= 0)
        return;

    fHealth += float(iGain);
    if (fHealth > fMax) fHealth = fMax;
    SetEntProp(marine, Prop_Data, "m_iHealth", RoundToFloor(fHealth));
    g_fRegenAccum[client] -= float(iGain);
    if (fHealth >= fMax)
        g_fRegenAccum[client] = 0.0;
}

// 护甲层"插件接管"的恢复节律 (按本次待恢复量分档加速):
//   停手 delay 秒后开始。以"本次待恢复总量 restoreBase"为基数, 按已恢复比例分三档提速:
//     已恢复 < 1/3  → 基础速度 (默认 1 层/秒)
//     已恢复 1/3~2/3 → 中速 (默认 2 层/秒)
//     已恢复 > 2/3  → 最高速度 (默认 3 层/秒)
//   基数是"本次待恢复层数"而非护甲总层数, 因此只掉几层也能完整经历 1→2→3 的提速,
//   且修改护甲总层数 / 掉层多少都自动适配节奏。浮点累积避免每 tick 取整丢失。
void TryArmorRestore(int client, int missing, float fElapsed, float fNow)
{
    float fStopped = fNow - g_fArmorHitTimer[client];
    if (fStopped < g_DelayCv.FloatValue)
        return;

    float fMin = 1.0 / g_IntervalCv.FloatValue;  // 基础恢复速度 (层/秒)
    float fMax = g_MaxSpeedCv.FloatValue;         // 最高恢复速度 (层/秒)
    if (fMax <= 0.0)
        fMax = fMin;                              // 未开启加速 → 恒定基础速度
    float fMid = (fMin + fMax) * 0.5;             // 中速档 (默认 2 层/秒)
    if (fMid < fMin) fMid = fMin;

    // 基数 = 本次待恢复总量 (受击/首穿那一刻的缺失层数); 兜底用当前缺失
    int base = g_iArmorRestoreBase[client];
    if (base <= 0) base = missing;

    // 已恢复层数 = 基数 − 当前缺失 → 比例 0(刚掉完) → 1(快满)
    int restored = base - missing;
    if (restored < 0) restored = 0;
    if (restored > base) restored = base;
    float fRatio = (base > 0) ? float(restored) / float(base) : 0.0;

    // 三档提速: 按已恢复比例切换速度
    float fSpeed = fMin;
    if (fRatio >= 2.0 / 3.0)
        fSpeed = fMax;
    else if (fRatio >= 1.0 / 3.0)
        fSpeed = fMid;

    g_fArmorAccum[client] += fSpeed * fElapsed;

    int armor = GetArmorForClient(client);
    if (armor <= 0)
        return;

    while (g_fArmorAccum[client] >= 1.0 && missing > 0)
    {
        g_fArmorAccum[client] -= 1.0;
        missing--;
        SetEntProp(armor, Prop_Send, "m_iLayersMissing", missing);
    }
    if (missing <= 0)
        g_fArmorAccum[client] = 0.0;
}

void ClearHud(int client)
{
    ShowHudText(client, g_HudChCv.IntValue, "");
}

// ============================================================================
//  管理员命令入口
// ============================================================================
public Action Cmd_Armor(int client, int args)
{
    if (args < 1)
    {
        ShowPanel(client);
        return Plugin_Handled;
    }

    char sSub[16];
    GetCmdArg(1, sSub, sizeof(sSub));

    if (StrEqual(sSub, "set", false))          return Cmd_ArmorSet(client, args);
    if (StrEqual(sSub, "drop", false))         return Cmd_ArmorDrop(client, args);
    if (StrEqual(sSub, "status", false))       return Cmd_ArmorStatus(client);
    if (StrEqual(sSub, "reset", false))
    {
        SetConVarFloat(g_ScaleCv, CFG_SCALE);
        SetConVarInt(g_LayersCv, CFG_LAYERS);
        SetConVarFloat(g_ProtectionCv, CFG_PROTECTION);
        SetConVarFloat(g_DelayCv, CFG_DELAY);
        SetConVarFloat(g_IntervalCv, CFG_INTERVAL);
        SetConVarFloat(g_MaxSpeedCv, CFG_MAXSPEED);
        SetConVarFloat(g_RegenCv,    CFG_REGEN);
        SetConVarInt(g_EnabledCv, CFG_ENABLED);
        SetConVarFloat(g_SpeedBonusCv, CFG_SPEED_BONUS);
        ReplyArmor(client, "已恢复默认参数 (倍率 %.2f | 层数 %d | 每层吸收 %.2f | 延迟 %.0fs | 间隔 %.0fs | 最高速度 %.0f 层/s | 移速+%.0f%%)",
            g_ScaleCv.FloatValue, g_LayersCv.IntValue, g_ProtectionCv.FloatValue,
            g_DelayCv.FloatValue, g_IntervalCv.FloatValue, g_MaxSpeedCv.FloatValue,
            g_SpeedBonusCv.FloatValue * 100.0);
        return Plugin_Handled;
    }

    ShowUsage(client);
    return Plugin_Handled;
}

public Action Cmd_ArmorSet(int client, int args)
{
    if (args < 3)
    {
        ShowKeyHelp(client);
        return Plugin_Handled;
    }

    char sKey[32], sVal[32];
    GetCmdArg(2, sKey, sizeof(sKey));
    GetCmdArg(3, sVal, sizeof(sVal));

    if (StrEqual(sKey, "scale", false))
    {
        float v = clampf(StringToFloat(sVal), 0.0, 1.0);
        SetConVarFloat(g_ScaleCv, v);
        ReplyArmor(client, "基础减伤倍率已设为 %.2f (全体生效)", g_ScaleCv.FloatValue);
    }
    else if (StrEqual(sKey, "layers", false) || StrEqual(sKey, "amount", false))
    {
        int v = StringToInt(sVal);
        if (v < 1) v = 1;
        SetConVarInt(g_LayersCv, v);
        ReplyArmor(client, "护甲总涂层数已设为 %d (全体生效)", g_LayersCv.IntValue);
    }
    else if (StrEqual(sKey, "protection", false))
    {
        float v = clampf(StringToFloat(sVal), 0.0, 1.0);
        SetConVarFloat(g_ProtectionCv, v);
        ReplyArmor(client, "每层护甲吸收比例已设为 %.3f (全体生效)", g_ProtectionCv.FloatValue);
    }
    else if (StrEqual(sKey, "interval", false))
    {
        float v = StringToFloat(sVal);
        if (v < 0.1) v = 0.1;
        SetConVarFloat(g_IntervalCv, v);
        ReplyArmor(client, "每层护甲恢复间隔已设为 %.1f 秒 (全体生效)", g_IntervalCv.FloatValue);
    }
    else if (StrEqual(sKey, "delay", false) || StrEqual(sKey, "cd", false))
    {
        float v = StringToFloat(sVal);
        if (v < 0.0) v = 0.0;
        SetConVarFloat(g_DelayCv, v);
        ReplyArmor(client, "停手后开始恢复延迟已设为 %.1f 秒 (全体生效)", g_DelayCv.FloatValue);
    }
    else if (StrEqual(sKey, "maxspeed", false) || StrEqual(sKey, "accel", false))
    {
        float v = StringToFloat(sVal);
        if (v < 0.0) v = 0.0;
        SetConVarFloat(g_MaxSpeedCv, v);
        ReplyArmor(client, "护甲层最高恢复速度已设为 %.1f 层/秒 (0=保持基础速度, 全体生效)", g_MaxSpeedCv.FloatValue);
    }
    else if (StrEqual(sKey, "enabled", false) || StrEqual(sKey, "check", false))
    {
        int v = StringToInt(sVal) != 0 ? 1 : 0;
        SetConVarInt(g_EnabledCv, v);
        ReplyArmor(client, "护甲掉层/恢复机制已%s", g_EnabledCv.IntValue ? "开启" : "关闭");
    }
    else if (StrEqual(sKey, "on", false) || StrEqual(sKey, "off", false))
    {
        SetConVarInt(g_EnabledCv, StrEqual(sKey, "on", false) ? 1 : 0);
        ReplyArmor(client, "护甲掉层/恢复机制已%s", g_EnabledCv.IntValue ? "开启" : "关闭");
    }
    else if (StrEqual(sKey, "speed", false))
    {
        float v = StringToFloat(sVal);
        if (v < 0.0) v = 0.0;
        SetConVarFloat(g_SpeedBonusCv, v);
        ReplyArmor(client, "穿戴护甲移速加成已设为 +%.0f%% (全体生效)", g_SpeedBonusCv.FloatValue * 100.0);
    }
    else if (StrEqual(sKey, "immune", false))
    {
        SetConVarString(g_ImmuneCv, sVal);
        ReplyArmor(client, "免伤武器列表已更新");
    }
    else
    {
        ShowKeyHelp(client);
    }
    return Plugin_Handled;
}

public Action Cmd_ArmorDrop(int client, int args)
{
    int target;
    bool bAll = false;

    if (args >= 2)
    {
        char sArg[64];
        GetCmdArg(2, sArg, sizeof(sArg));
        if (StrEqual(sArg, "@all", false))    bAll = true;
        else if (StrEqual(sArg, "me", false)) target = client;
        else                                  target = FindTargetPlayer(client, sArg);
    }
    else
    {
        target = client;
    }

    if (!bAll && target <= 0)
    {
        ReplyArmor(client, "目标无效");
        return Plugin_Handled;
    }

    int count = 0;
    if (bAll)
    {
        for (int i = 1; i <= MaxClients; i++)
            if (IsUsableClient(i) && IsActivePlayer(i) && RemoveArmorOn(i) > 0)
                count++;
    }
    else if (RemoveArmorOn(target) > 0)
    {
        count = 1;
    }

    if (count <= 0)
    {
        ReplyArmor(client, "目标没有可掉落的护甲");
        return Plugin_Handled;
    }

    if (bAll)
    {
        ReplyArmor(client, "已掉落 %d 名玩家的 L3a 护甲", count);
    }
    else
    {
        char sName[MAX_NAME_LENGTH];
        GetClientName(target, sName, sizeof(sName));
        PrintToChat(target, "\x04[护甲]\x01 你的 L3a 护甲已被掉落");
        ReplyArmor(client, "已掉落 %s 的 L3a 护甲", sName);
    }
    return Plugin_Handled;
}

public Action Cmd_ArmorStatus(int client)
{
    int iLayers = g_LayersCv.IntValue;
    float fScale = g_ScaleCv.FloatValue;
    float fProt  = g_ProtectionCv.FloatValue;

    float fFull = fScale - float(iLayers) * fProt;
    if (fFull < 0.0) fFull = 0.0;

    PrintToConsole(client, "=== L3a 护甲状态 ===");
    PrintToConsole(client, "基础减伤倍率 %.2f | 满层实际承受 %.3f (减伤 %.1f%%)", fScale, fFull, (1.0 - fFull) * 100.0);
    PrintToConsole(client, "总层数 %d | 每层吸收 %.3f | 恢复延迟 %.1fs | 每层间隔 %.1fs | 恢复最高速度 %.1f 层/s | 层机制 %s | 移速+%.0f%%",
        iLayers, fProt, g_DelayCv.FloatValue, g_IntervalCv.FloatValue,
        g_MaxSpeedCv.FloatValue,
        g_EnabledCv.IntValue ? "开" : "关", g_SpeedBonusCv.FloatValue * 100.0);
    char sImm[512];
    GetConVarString(g_ImmuneCv, sImm, sizeof(sImm));
    PrintToConsole(client, "免伤武器: %s", sImm);

    if (client > 0)
        PrintToChat(client, "\x04[护甲]\x01 状态已输出到控制台");

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsUsableClient(i) || !IsActivePlayer(i)) continue;
        char sName[MAX_NAME_LENGTH];
        GetClientName(i, sName, sizeof(sName));
        int missing = GetMissingLayers(i);
        if (missing < 0)
            PrintToConsole(client, "  %s : 无护甲", sName);
        else
            PrintToConsole(client, "  %s : 护甲层 %d/%d", sName, iLayers - missing, iLayers);
    }
    return Plugin_Handled;
}

// ============================================================================
//  面板 / 帮助
// ============================================================================
void ShowPanel(int client)
{
    PrintToConsole(client, "=== L3a 护甲 (v%s) ===", PLUGIN_VERSION);
    PrintToConsole(client, "基础减伤倍率 : %.2f (受 1 点伤害实际承受 %.2f, 越低越强)", g_ScaleCv.FloatValue, g_ScaleCv.FloatValue);
    PrintToConsole(client, "护甲总涂层数 : %d", g_LayersCv.IntValue);
    PrintToConsole(client, "每层吸收比例 : %.3f", g_ProtectionCv.FloatValue);
    PrintToConsole(client, "停手后恢复延迟 : %.1f 秒", g_DelayCv.FloatValue);
    PrintToConsole(client, "每层恢复间隔 : %.1f 秒", g_IntervalCv.FloatValue);
    PrintToConsole(client, "恢复最高速度 : %.1f 层/秒 (以本次待恢复量为基数分三档: 1→2→3 层/秒)", g_MaxSpeedCv.FloatValue);
    PrintToConsole(client, "掉层/恢复机制 : %s", g_EnabledCv.IntValue ? "开" : "关");
    PrintToConsole(client, "穿戴移速加成 : +%.0f%%", g_SpeedBonusCv.FloatValue * 100.0);
    ShowUsage(client);
    if (client > 0)
        PrintToChat(client, "\x04[护甲]\x01 当前属性已输出到控制台, 用法见 sm_asrd_armor (或 sm_armor)");
}

void ShowUsage(int client)
{
    PrintToConsole(client, "用法: sm_asrd_armor <命令> [参数]");
    PrintToConsole(client, "  sm_asrd_armor                      查看属性面板");
    PrintToConsole(client, "  sm_asrd_armor set <键> <值>        修改属性 (键: scale/layers/protection/interval/delay/maxspeed/enabled/speed/immune)");
    PrintToConsole(client, "  sm_asrd_armor drop [目标]           掉落玩家的重甲 (目标=名字/#userid/me/@all)");
    PrintToConsole(client, "  sm_asrd_armor status                查询属性与各玩家护甲层数");
    PrintToConsole(client, "  sm_asrd_armor reset                 恢复默认参数");
}

void ShowKeyHelp(int client)
{
    PrintToConsole(client, "可设置的键 (sm_asrd_armor set <键> <值>):");
    PrintToConsole(client, "  scale       基础减伤倍率 (0~1, 越小越强)");
    PrintToConsole(client, "  layers      护甲总涂层数 (>=1)");
    PrintToConsole(client, "  protection  每层吸收伤害比例 (0~1)");
    PrintToConsole(client, "  interval    每层护甲恢复间隔秒数");
    PrintToConsole(client, "  delay       停手后开始恢复延迟秒数");
    PrintToConsole(client, "  maxspeed    停手后护甲层恢复的最高速度 (层/秒, 0=恒定基础)");
    PrintToConsole(client, "  enabled/on/off  护甲层机制开关");
    PrintToConsole(client, "  speed       穿戴移速加成 (0.1 = +10%%)");
    PrintToConsole(client, "  immune      免伤武器实体类名列表 (空格分隔)");
    if (client > 0)
        PrintToChat(client, "\x04[护甲]\x01 用法见控制台 (sm_asrd_armor set <键> <值>)");
}

// ============================================================================
//  Helper
// ============================================================================
int RemoveArmorOn(int client)
{
    int marine = GetClientMarine(client);
    if (marine <= 0) return 0;
    int count = 0;
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, ARMOR_CLASS)) != -1)
    {
        if (GetWeaponOwner(ent) != marine) continue;
        AcceptEntityInput(ent, "Kill");
        count++;
    }
    return count;
}

int GetArmorForClient(int client)
{
    int marine = GetClientMarine(client);
    if (marine <= 0) return 0;
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, ARMOR_CLASS)) != -1)
        if (GetWeaponOwner(ent) == marine)
            return ent;
    return 0;
}

int GetMissingLayers(int client)
{
    int ent = GetArmorForClient(client);
    if (ent <= 0) return -1;
    return GetEntProp(ent, Prop_Send, "m_iLayersMissing");
}

bool MarineHasArmor(int marine)
{
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, ARMOR_CLASS)) != -1)
        if (GetWeaponOwner(ent) == marine)
            return true;
    return false;
}

int GetWeaponOwner(int weapon)
{
    if (FindDataMapInfo(weapon, "m_hOwnerEntity") > 0)
    {
        int o = GetEntPropEnt(weapon, Prop_Data, "m_hOwnerEntity");
        if (o > 0) return o;
    }
    char sNetClass[64];
    if (GetEntityNetClass(weapon, sNetClass, sizeof(sNetClass))
        && FindSendPropInfo(sNetClass, "m_hOwnerEntity") > 0)
    {
        int o = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
        if (o > 0) return o;
    }
    return 0;
}

// 判断某陆战队员的武器库存中是否携带榴弹发射器 (asw_weapon_grenade_launcher),
// 不要求当前正拿在手上
bool HasGrenadeLauncher(int marine)
{
    if (marine <= 0)
        return false;
    int w = -1;
    while ((w = FindEntityByClassname(w, "asw_weapon_grenade_launcher")) != -1)
        if (GetWeaponOwnerEntity(w) == marine)
            return true;
    return false;
}

// 读取武器所属实体 (网络属性名优先 m_hOwner, 兜底 m_hOwnerEntity)
int GetWeaponOwnerEntity(int weapon)
{
    if (weapon <= 0 || !IsValidEntity(weapon))
        return -1;
    if (HasEntProp(weapon, Prop_Send, "m_hOwner"))
        return GetEntPropEnt(weapon, Prop_Send, "m_hOwner");
    if (HasEntProp(weapon, Prop_Send, "m_hOwnerEntity"))
        return GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
    return -1;
}

int GetClientMarine(int client)
{
    if (!IsUsableClient(client)) return 0;
    int e = -1;
    while ((e = FindEntityByClassname(e, MARINE_CLASS)) != -1)
        if (GetCommanderClient(e) == client)
            return e;
    return 0;
}

// 自杀命令绕过护甲 (asw_suicide):
//   原版自杀伤害会被护甲按 GetDamageScaleFactor() 缩放, 导致护甲满层时"1血保护"迟迟不死。
//   这里拦截命令, 改用护甲明确豁免的溺水类(DMG_DROWN)伤害直接结算——引擎的
//   ApplyPassiveArmorEffects() 对这类伤害会跳过护甲缩放, 99999 一次性致死。
public Action Cmd_Suicide(int client, const char[] command, int argc)
{
    if (client <= 0 || !IsClientInGame(client))
        return Plugin_Continue;

    int marine = GetClientMarine(client);
    if (marine <= 0)
        return Plugin_Continue;

    SDKHooks_TakeDamage(marine, client, client, 99999.0, DMG_DROWN);
    return Plugin_Handled;
}

// 跨插件读取强化移速倍率 (asrd_marine_power 未加载/无函数则返回 1.0)
float GetPowerSpeedMul(int client)
{
    Handle hPower = FindPluginByFile("asrd_marine_power.smx");
    if (hPower == INVALID_HANDLE || GetPluginStatus(hPower) != Plugin_Running)
        return 1.0;
    Function fn = GetFunctionByName(hPower, "ASRD_GetPowerSpeedMul");
    if (fn == INVALID_FUNCTION)
        return 1.0;
    float ret;
    Call_StartFunction(hPower, fn);
    Call_PushCell(client);
    Call_Finish(ret);
    return ret;
}

int GetCommanderClient(int ent)
{
    if (FindDataMapInfo(ent, "m_Commander") > 0)
    {
        int client = GetEntPropEnt(ent, Prop_Data, "m_Commander");
        if (IsUsableClient(client)) return client;
    }
    char sNetClass[64];
    if (GetEntityNetClass(ent, sNetClass, sizeof(sNetClass))
        && FindSendPropInfo(sNetClass, "m_Commander") > 0)
    {
        int client = GetEntPropEnt(ent, Prop_Send, "m_Commander");
        if (IsUsableClient(client)) return client;
    }
    return 0;
}

bool IsUsableClient(int client)
{
    return client > 0 && client <= MaxClients
        && IsClientInGame(client) && !IsFakeClient(client);
}

bool IsActivePlayer(int client)
{
    if (!IsUsableClient(client)) return false;
    int e = -1;
    while ((e = FindEntityByClassname(e, MARINE_CLASS)) != -1)
        if (GetCommanderClient(e) == client)
            return true;
    return false;
}

int FindTargetPlayer(int client, const char[] szArg)
{
    if (szArg[0] == '#')
    {
        int who = GetClientOfUserId(StringToInt(szArg[1]));
        if (who > 0 && IsUsableClient(who)) return who;
        PrintToConsole(client, "[Armor] 找不到该 userid 对应的在线玩家");
        return 0;
    }
    int found = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;
        char sName[MAX_NAME_LENGTH];
        GetClientName(i, sName, sizeof(sName));
        if (StrEqual(sName, szArg, false)) return i;
        if (StrContains(sName, szArg, false) != -1)
        {
            if (found != 0)
            {
                PrintToConsole(client, "[Armor] 匹配到多名玩家, 请用更完整的名字或 #userid");
                if (client > 0) PrintToChat(client, "\x04[护甲]\x01 匹配到多名玩家, 请用更完整的名字或 #userid");
                return 0;
            }
            found = i;
        }
    }
    if (found == 0) PrintToConsole(client, "[Armor] 找不到在线玩家 \"%s\"", szArg);
    return found;
}

float clampf(float v, float lo, float hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

void ReplyArmor(int client, const char[] sFmt, any ...)
{
    char sMsg[256];
    VFormat(sMsg, sizeof(sMsg), sFmt, 3);
    PrintToConsole(client, "[Armor] %s", sMsg);
    if (client > 0)
        PrintToChat(client, "\x04[护甲]\x01 %s", sMsg);
}