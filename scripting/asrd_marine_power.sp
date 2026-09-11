/**
 * ============================================================================
 *  [AS:RD] 陆战队员强化 (Marine Power)
 *  版本 1.3.0  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ─────────────────────────────────────
 *  玩家按键实时调大/调小自己的 血量 / 体型 / 近战 / 移速:
 *    - 放大(等级 1~5): 血量固定: L1=200 / L2=300 / L3=500 / L4=800 / L5=1000
 *                      + 体型 +0.1/级 + 移速同步(随等级) + 近战加成(逐人)
 *    - 缩小(等级 -1~-3): 仅模型变小(0.8/0.6/0.4倍), 血量/近战/移速等属性不变
 *    - 等级0 = 恢复默认(100血 / 1.0倍体型 / 1.0倍移速)
 *
 *  近战加成只作用于**普通近战**(徒手/踢击那套, 引擎伤害类型 DMG_CLUB),
 *  按**攻击者本人**的等级取倍率, 逐次命中时叠加。
 *  【电锯 (asw_weapon_chainsaw) 属于独立伤害系统, 完全不受强化等级影响】
 *    —— 电锯伤害 = 武器基础伤害 + 陆战队员"近战"技能值 (引擎侧, DMG_SLASH),
 *       本插件对此不做任何干预。
 *
 *  ── 玩家命令 (绑定 2 个按键即可) ─────────────────────
 *   sm_power_up      调大 1 级
 *   sm_power_down    调小 1 级
 *   sm_power_reset   恢复默认(等级0)
 *   示例(控制台输入一次, 自动保存到 config.cfg):
 *     bind F6 "sm_power_up"
 *     bind F7 "sm_power_down"
 *
 *  ── 管理员命令 ─────────────────────────────────────
 *   sm_power_status                查看所有玩家强化状态
 *   sm_power_set <玩家> <等级>      指定强化某个玩家 (等级= -缩小max ~ 放大max, 0=恢复默认)
 *                                  玩家可填 名字 / 部分名字 / #userid
 *
 *  ── 常用 ConVar (仅代码默认值, 不生成 cfg 文件) ─
 *   sm_asrd_power_enabled        总开关 (0=关 1=开, 默认 1)
 *   sm_asrd_power_public         是否允许普通玩家自行强化 (0=仅管理员 1=公开, 默认 1)
 *   sm_asrd_power_max_level      放大最大等级 (默认 5)
 *   血量上限(固定, 代码内配置): L1=200 / L2=300 / L3=500 / L4=800 / L5=1000
 *   sm_asrd_power_scale_step     每级体型增量 (默认 0.1, 5级=1.5)
 *   sm_asrd_power_shrink_max     缩小最大等级 (默认 3, 仅缩模型)
 *   sm_asrd_power_shrink_step    每级缩小比例 (默认 0.2, 3级=0.4倍)
 *   sm_asrd_power_speed_enabled  放大时是否同步提高移速 (0/1, 默认 1)
 *   sm_asrd_power_speed_step     每级移速增量 (默认 0.1, 与体型同比例)
 *   sm_asrd_power_melee_enabled  是否启用近战加成 (0/1, 默认 1; 只加成普通近战)
 *   近战倍率(固定): 等级1~5 = x2 / x4 / x8 / x16 / x32 (逐人, 按攻击者本人等级)
 *   sm_asrd_power_debug          调试输出 (默认 0)
 *
 *  ── 实现原理 ───────────────────────────────────────
 *   - 玩家控制的是"指挥官"实体, 真正带血量/模型/移速的是其 m_hInhabiting
 *     指向的 "asw_marine" 实体 (与 asrd_chainsaw_turbo 相同的查找方式)
 *   - 血量: 写 marine 的 m_iMaxHealth / m_iHealth (Prop_Data)
 *   - 体型: 写 marine 的 m_flModelScale (Prop_Send), 纯视觉缩放(不改变碰撞)
 *   - 移速: 写 marine 的 m_fSpeedScale (Prop_Send, AS:RD MaxSpeed 中的乘数)
 *   - 近战: SDKHook_OnTakeDamage 挂在虫族 victim 侧 (与 asrd_points 同模式),
 *     只在"普通近战"(damagetype & DMG_CLUB) 时把伤害乘以攻击者本人等级的倍率;
 *     电锯 (DMG_SLASH) 天然不满足条件, 另加类名双保险 —— 一律放行不改。
 *   - **绝不改写任何引擎 ConVar**: v1.3.0 起不再触碰 asw_skill_melee_dmg_base/_step
 *     (旧版按全场最高等级全局放大这两个 cvar, 会连带把电锯伤害放大 x32, 故废弃)
 *   - 定时器(1s)重新断言血量/体型/移速, 应对换人/复活, 但不会持续回血
 *
 *  依赖: SourceMod 1.11+ (核心 API + sdktools + SDKHooks)
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] Marine Power"
#define PLUGIN_VERSION "1.3.0"

// 重新断言周期(秒): 换陆战队员/复活后仍生效, 不回血
#define REAPPLY_INTERVAL 1.0

// 默认基础血量(AS:RD 陆战队员基础 100)
#define DEFAULT_BASE_HEALTH 100

// 各强化等级对应的血量上限(绝对上限值; 下标即等级)
//   L1=200  L2=300  L3=500  L4=800  L5=1000;  等级超过 LEVEL_COUNT 按 L5 封顶
#define LEVEL_COUNT 5
int g_iHpForLevel[LEVEL_COUNT + 1] = { 0, 200, 300, 500, 800, 1000 };

// 近战加成倍率表的最大等级 (与 LEVEL_COUNT 一致: 1~5 级 = x2 / x4 / x8 / x16 / x32)
#define MELEE_MULT_LEVELS 5

// 电锯实体类名 (游戏源码: asw_weapon_chainsaw_shared.cpp)
// 电锯伤害走 DMG_SLASH + 独立公式, 本插件对它一律放行
#define CHAINSAW_CLASSNAME "asw_weapon_chainsaw"

// ─── ConVar 句柄 ──────────────────────────────────────
ConVar g_cvEnabled;
ConVar g_cvPublic;
ConVar g_cvMaxLevel;
ConVar g_cvScaleStep;
ConVar g_cvMeleeEnabled;
ConVar g_cvShrinkMax;
ConVar g_cvShrinkStep;
ConVar g_cvSpeedEnabled;
ConVar g_cvSpeedStep;
ConVar g_cvDebug;

// ─── 每玩家状态 ───────────────────────────────────────
int  g_iLevel[MAXPLAYERS + 1];          // 当前强化等级 0..maxLevel
int  g_iBaseMaxHealth[MAXPLAYERS + 1];  // 首次强化前记录的原生最大血量(等级0恢复用)
Handle g_hReapplyTimer = null;

// ─── 可被近战加成的虫族类名 (与 asrd_points 保持一致) ──
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

// ============================================================================
//  插件信息
// ============================================================================
public Plugin myinfo =
{
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "按键实时调大/调小血量/体型/移速(逐人); 近战加成逐次命中生效, 电锯不受影响",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
//  插件加载
// ============================================================================
public void OnPluginStart()
{
    g_cvEnabled = CreateConVar(
        "sm_asrd_power_enabled", "1",
        "启用/禁用陆战队员强化 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvPublic = CreateConVar(
        "sm_asrd_power_public", "1",
        "是否允许普通玩家自行强化 (0=仅管理员 1=公开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvMaxLevel = CreateConVar(
        "sm_asrd_power_max_level", "5",
        "最大强化等级 (1~10)",
        FCVAR_NOTIFY, true, 1.0, true, 10.0
    );
    g_cvScaleStep = CreateConVar(
        "sm_asrd_power_scale_step", "0.1",
        "每级体型增量 (默认 0.1, 5级=1.5), 体型 = 1.0 + step*等级",
        FCVAR_NOTIFY, true, 0.0
    );
    g_cvMeleeEnabled = CreateConVar(
        "sm_asrd_power_melee_enabled", "1",
        "启用近战加成 (0=关 1=开; 只加成普通近战, 电锯不受影响)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvShrinkMax = CreateConVar(
        "sm_asrd_power_shrink_max", "3",
        "缩小最大等级 (1~5, 仅缩小模型, 不改其他属性)",
        FCVAR_NOTIFY, true, 1.0, true, 5.0
    );
    g_cvShrinkStep = CreateConVar(
        "sm_asrd_power_shrink_step", "0.2",
        "每级缩小比例 (默认0.2, 3级=0.4倍模型)",
        FCVAR_NOTIFY, true, 0.05, true, 0.4
    );
    g_cvSpeedEnabled = CreateConVar(
        "sm_asrd_power_speed_enabled", "1",
        "放大时是否同步提高移速 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvSpeedStep = CreateConVar(
        "sm_asrd_power_speed_step", "0.1",
        "每级移速增量 (默认0.1, 与体型同比例, 5级=x1.5)",
        FCVAR_NOTIFY, true, 0.0
    );
    g_cvDebug = CreateConVar(
        "sm_asrd_power_debug", "0",
        "调试输出到服务器控制台 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    // 不生成 cfg: 参数统一使用代码默认值, 避免旧 cfg 覆盖新默认值

    // 玩家命令
    RegConsoleCmd("sm_power_up",    Cmd_PowerUp,    "调大 1 级强化");
    RegConsoleCmd("sm_power_down",  Cmd_PowerDown,  "调小 1 级强化");
    RegConsoleCmd("sm_power_reset", Cmd_PowerReset, "恢复默认强化(等级0)");

    // 管理员命令
    RegAdminCmd("sm_power_status", Cmd_PowerStatus, ADMFLAG_GENERIC, "查看所有玩家强化状态");
    RegAdminCmd("sm_power_set", Cmd_PowerSet, ADMFLAG_GENERIC, "指定强化某个玩家 (用法: sm_power_set <玩家> <等级>)");

    // 任务即时重启(重新开始游戏): AS:RD 实测事件 asw_mission_restart, 用于清除上一局强化
    HookEventEx("asw_mission_restart", Event_MissionRestart, EventHookMode_Post);

    // 迟加载(地图运行中 sm plugins load)时, 补挂当前已存在的虫族
    HookExistingAliens();

    // 周期性重新断言(换人/复活后仍生效)
    g_hReapplyTimer = CreateTimer(REAPPLY_INTERVAL, Timer_Reapply, _, TIMER_REPEAT);
}

// AS:RD 任务即时重启(重新开始游戏, 不换图): 清除所有玩家的强化
public void Event_MissionRestart(Event event, const char[] name, bool dontBroadcast)
{
    // 该事件在游戏帧处理中段触发, 且 RestartMission 即刻重建陆战队员实体,
    // 延迟到实体重建后再恢复, 避免中途改写实体属性导致崩溃
    CreateTimer(REAPPLY_INTERVAL, Timer_ResetAllPower);
}

public Action Timer_ResetAllPower(Handle timer)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && g_iLevel[i] != 0)
            RestoreMarine(i);
        ResetPlayer(i);
    }
    return Plugin_Continue;
}

public void OnPluginEnd()
{
    // 插件卸载前恢复所有被强化玩家的体型/血量, 避免残留
    // (近战加成不再改写任何引擎 ConVar, 无需恢复)
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && g_iLevel[i] > 0)
            RestoreMarine(i);
        ResetPlayer(i);
    }
    if (g_hReapplyTimer != null)
    {
        KillTimer(g_hReapplyTimer);
        g_hReapplyTimer = null;
    }
}

public void OnMapStart()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        // 换图/新局: 上一局被强化的玩家先恢复实体属性, 再清内存等级
        if (g_iLevel[i] != 0)
            RestoreMarine(i);
        ResetPlayer(i);
    }

    // 新地图的虫族都要重新挂伤害回调
    HookExistingAliens();
}

public void OnClientDisconnect(int client)
{
    if (g_iLevel[client] > 0)
        RestoreMarine(client);
    ResetPlayer(client);
}

// ============================================================================
//  玩家命令
// ============================================================================
public Action Cmd_PowerUp(int client, int args)
{
    if (!CanUsePower(client))
        return Plugin_Handled;

    int max = g_cvMaxLevel.IntValue;
    if (g_iLevel[client] >= max)
    {
        PrintToChat(client, "\x04[强化]\x01 已达最高等级 \x05%d\x01", max);
        ShowStatus(client);
        return Plugin_Handled;
    }

    g_iLevel[client]++;
    ApplyPower(client, true);
    ShowStatus(client);
    return Plugin_Handled;
}

public Action Cmd_PowerDown(int client, int args)
{
    if (!CanUsePower(client))
        return Plugin_Handled;

    int minLevel = -g_cvShrinkMax.IntValue;
    if (g_iLevel[client] <= minLevel)
    {
        PrintToChat(client, "\x04[强化]\x01 已达最小体型 (等级 \x05%d\x01)", minLevel);
        ShowStatus(client);
        return Plugin_Handled;
    }

    g_iLevel[client]--;
    ApplyPower(client, true);
    ShowStatus(client);
    return Plugin_Handled;
}

public Action Cmd_PowerReset(int client, int args)
{
    if (!CanUsePower(client))
        return Plugin_Handled;

    g_iLevel[client] = 0;
    ApplyPower(client, true);
    ShowStatus(client);
    return Plugin_Handled;
}

// ============================================================================
//  管理员命令: 指定强化某个玩家
//  sm_power_set <玩家> <等级>   (等级范围= -缩小max ~ 放大max, 0=恢复默认)
// ============================================================================
public Action Cmd_PowerSet(int client, int args)
{
    if (args < 2)
    {
        PrintToConsole(client, "用法: sm_power_set <玩家> <等级> (等级范围 %d~%d, 0=恢复默认)",
            -g_cvShrinkMax.IntValue, g_cvMaxLevel.IntValue);
        if (client > 0)
            PrintToChat(client, "\x04[强化]\x01 用法: \x05sm_power_set <玩家> <等级>\x01");
        return Plugin_Handled;
    }

    char sArg[64], sLevel[16];
    GetCmdArg(1, sArg, sizeof(sArg));
    GetCmdArg(2, sLevel, sizeof(sLevel));

    int target = FindTargetPlayer(client, sArg);
    if (target == 0)
        return Plugin_Handled;

    int level = StringToInt(sLevel);
    int minLevel = -g_cvShrinkMax.IntValue;
    int maxLevel = g_cvMaxLevel.IntValue;
    if (level < minLevel || level > maxLevel)
    {
        PrintToConsole(client, "等级超出范围 (%d~%d)", minLevel, maxLevel);
        if (client > 0)
            PrintToChat(client, "\x04[强化]\x01 等级必须在 \x05%d\x01 ~ \x05%d\x01 之间", minLevel, maxLevel);
        return Plugin_Handled;
    }

    // 写入目标玩家等级并应用(与普通玩家自调走同一套逻辑)
    g_iLevel[target] = level;
    ApplyPower(target, true);
    ShowStatus(target);

    if (client > 0)
        PrintToChat(client, "\x04[强化]\x01 已将 \x05%N\x01 设为等级 \x05%d\x01", target, level);
    PrintToServer("[强化] 管理员(玩家 %N) 将 %N 设为等级 %d", client, target, level);
    return Plugin_Handled;
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
                if (client > 0)
                    PrintToChat(client, "\x04[强化]\x01 匹配到多名玩家, 请用更完整的名字或 #userid");
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
//  管理员命令
// ============================================================================
public Action Cmd_PowerStatus(int client, int args)
{
    if (client > 0)
    {
        PrintToChat(client, "\x04[强化]\x01 ============ 玩家强化状态 (v%s) ============", PLUGIN_VERSION);
        PrintToChat(client, "\x04[强化]\x01 开关:%s | 公开:%s | 血量上限 %d/%d/%d/%d/%d | 体型+%.1f/级 | 移速+%.1f/级 | 等级%d~%d",
            g_cvEnabled.BoolValue ? "开" : "关",
            g_cvPublic.BoolValue ? "是" : "否",
            g_iHpForLevel[1], g_iHpForLevel[2], g_iHpForLevel[3], g_iHpForLevel[4], g_iHpForLevel[5],
            g_cvScaleStep.FloatValue,
            g_cvSpeedStep.FloatValue,
            -g_cvShrinkMax.IntValue, g_cvMaxLevel.IntValue);
        PrintToChat(client, "\x04[强化]\x01 近战加成:%s (逐人, 电锯不受影响) | 倍率 L1~L5 = x2/x4/x8/x16/x32",
            g_cvMeleeEnabled.BoolValue ? "开" : "关");
    }

    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;

        count++;
        if (client > 0)
        {
            char sName[MAX_NAME_LENGTH];
            GetClientName(i, sName, sizeof(sName));
            PrintToConsole(client, "[%s] L%d | 血量%d | 体型x%.2f | 近战x%.2f",
                sName, g_iLevel[i], GetHpForLevel(i), GetScaleForLevel(i), GetMeleeMultForLevel(g_iLevel[i]));
        }
    }

    if (count == 0 && client > 0)
        PrintToChat(client, "\x04[强化]\x01 当前无真实玩家在线");

    return Plugin_Handled;
}

// ============================================================================
//  强化应用: 把某玩家的等级写入其 marine 实体
// ============================================================================
void ApplyPower(int client, bool refill)
{
    int marine = GetPlayerMarine(client);
    if (marine <= 0)
        return;

    int level = g_iLevel[client];

    // 首次放大前记录原生最大血量, 供等级0恢复
    if (g_iBaseMaxHealth[client] <= 0 && level > 0)
    {
        g_iBaseMaxHealth[client] = GetEntProp(marine, Prop_Data, "m_iMaxHealth");
        if (g_iBaseMaxHealth[client] <= 0)
            g_iBaseMaxHealth[client] = DEFAULT_BASE_HEALTH;
    }

    // 体型: 放大/缩小/默认 三态 (纯视觉, 不改变碰撞)
    float newScale = GetScaleForLevel(client);
    if (HasEntProp(marine, Prop_Send, "m_flModelScale"))
        SetEntPropFloat(marine, Prop_Send, "m_flModelScale", newScale);

    // 移速: 仅放大时变快 (AS:RD MaxSpeed 中的 m_fSpeedScale 乘数), 缩小/默认保持 1.0
    if (HasEntProp(marine, Prop_Send, "m_fSpeedScale"))
        SetEntPropFloat(marine, Prop_Send, "m_fSpeedScale", GetSpeedForLevel(client));

    // 血量: 缩小只缩模型不碰血量上限; 放大按等级缩放; 默认恢复
    if (level >= 0)
    {
        int newMax = GetHpForLevel(client);
        SetEntProp(marine, Prop_Data, "m_iMaxHealth", newMax);

        // 升级/降级时直接补齐到新上限; 定时重断言时仅当当前值超上限才回拉(不回血)
        int curHp = GetEntProp(marine, Prop_Data, "m_iHealth");
        if (refill || curHp > newMax)
            SetEntProp(marine, Prop_Data, "m_iHealth", newMax);
    }

    if (g_cvDebug.BoolValue)
        PrintToServer("[强化] %N L%d: 体型=x%.2f 移速=x%.2f 近战=x%.2f",
            client, level, newScale, GetSpeedForLevel(client), GetMeleeMultForLevel(level));
}

// 恢复某玩家 marine 的原始血量/体型/移速
void RestoreMarine(int client)
{
    int marine = GetPlayerMarine(client);
    if (marine <= 0)
        return;

    // 血量: 仅曾放大(记录过原生上限)才恢复; 缩小/未强化不碰血量
    if (g_iBaseMaxHealth[client] > 0)
    {
        int base = g_iBaseMaxHealth[client];
        SetEntProp(marine, Prop_Data, "m_iMaxHealth", base);
        if (GetEntProp(marine, Prop_Data, "m_iHealth") > base)
            SetEntProp(marine, Prop_Data, "m_iHealth", base);
    }

    if (HasEntProp(marine, Prop_Send, "m_flModelScale"))
        SetEntPropFloat(marine, Prop_Send, "m_flModelScale", 1.0);
    if (HasEntProp(marine, Prop_Send, "m_fSpeedScale"))
        SetEntPropFloat(marine, Prop_Send, "m_fSpeedScale", 1.0);
}

// ============================================================================
//  等级 → 数值换算
// ============================================================================
int GetHpForLevel(int client)
{
    int level = g_iLevel[client];
    if (level <= 0)
        return (g_iBaseMaxHealth[client] > 0) ? g_iBaseMaxHealth[client] : DEFAULT_BASE_HEALTH;
    if (level > LEVEL_COUNT)
        level = LEVEL_COUNT;
    return g_iHpForLevel[level];
}

float GetScaleForLevel(int client)
{
    int level = g_iLevel[client];
    if (level > 0)
        return 1.0 + g_cvScaleStep.FloatValue * level;
    if (level < 0)
    {
        float s = 1.0 - g_cvShrinkStep.FloatValue * (-level);
        return (s > 0.1) ? s : 0.1;
    }
    return 1.0;
}

// 移速倍率: 放大时随等级提高(与体型同比例), 缩小/默认保持 1.0
float GetSpeedForLevel(int client)
{
    int level = g_iLevel[client];
    if (level > 0 && g_cvSpeedEnabled.BoolValue)
        return 1.0 + g_cvSpeedStep.FloatValue * level;
    return 1.0;
}

// ============================================================================
//  近战加成倍率: 放大等级 1~5 = x2 / x4 / x8 / x16 / x32; 其余(含缩小/0级) = x1.0
//  【逐人】: 只按"出手那个人"自己的等级取倍率, 不再受其他玩家等级影响
// ============================================================================
float GetMeleeMultForLevel(int level)
{
    if (level <= 0)
        return 1.0;
    if (level > MELEE_MULT_LEVELS)
        level = MELEE_MULT_LEVELS;

    static const float s_fMultTable[MELEE_MULT_LEVELS + 1] = { 1.0, 2.0, 4.0, 8.0, 16.0, 32.0 };
    return s_fMultTable[level];
}

// ============================================================================
//  近战加成 (SDKHooks, 挂在虫族 victim 侧):
//    只处理"普通近战" —— 引擎里 CASW_Marine::MeleeTraceHullAttack() 发出的
//    DMG_CLUB 伤害(伤害值 = 陆战队员近战技能值), 乘以攻击者本人等级的倍率。
//
//    电锯完全不受影响, 两道保险:
//      1) 电锯伤害类型是 DMG_SLASH (asw_weapon_chainsaw_shared.cpp), 不满足 DMG_CLUB
//      2) 再显式判断攻击武器类名不是 asw_weapon_chainsaw
// ============================================================================
public Action OnAlienDamaged(int victim, int &attacker, int &inflictor,
    float &damage, int &damagetype, int &weapon,
    float damageForce[3], float damagePosition[3], int damagecustom)
{
    if (!g_cvEnabled.BoolValue || !g_cvMeleeEnabled.BoolValue)
        return Plugin_Continue;

    // 只看普通近战 (徒手/踢击), 电锯的 DMG_SLASH 在这里就被排除
    if ((damagetype & DMG_CLUB) == 0)
        return Plugin_Continue;
    if (damage <= 0.0)
        return Plugin_Continue;

    // 双保险: 攻击武器若是电锯, 一律不参与强化
    if (weapon > 0 && IsValidEntity(weapon))
    {
        char sWeapon[64];
        if (GetEntityClassname(weapon, sWeapon, sizeof(sWeapon))
            && StrEqual(sWeapon, CHAINSAW_CLASSNAME, false))
            return Plugin_Continue;
    }

    int client = ResolveMeleeAttackerClient(attacker);
    if (client <= 0)
        return Plugin_Continue;

    float mult = GetMeleeMultForLevel(g_iLevel[client]);
    if (mult <= 1.0)
        return Plugin_Continue;

    if (g_cvDebug.BoolValue)
        PrintToServer("[强化] %N L%d 近战加成 x%.1f (%.1f -> %.1f)",
            client, g_iLevel[client], mult, damage, damage * mult);

    damage *= mult;
    return Plugin_Changed;
}

// ============================================================================
//  普通近战的攻击者 -> 操控该陆战队员的玩家 (0=不是玩家操控的陆战队员)
//  只认 asw_marine: 被玩家附身的虫族走的是虫族自己的近战路径, 不在此加成范围内
// ============================================================================
int ResolveMeleeAttackerClient(int attacker)
{
    if (attacker <= 0)
        return 0;

    if (attacker <= MaxClients)
        return IsUsableClient(attacker) ? attacker : 0;

    if (!IsValidEntity(attacker))
        return 0;

    char cls[64];
    if (!GetEntityClassname(attacker, cls, sizeof(cls)))
        return 0;
    if (!StrEqual(cls, "asw_marine", false))
        return 0;

    return GetCommanderClient(attacker);
}

// ============================================================================
//  查实体上的 m_Commander (CASW_Inhabitable_NPC 字段, marine 持有):
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
//  虫族伤害回调挂钩: 新虫族生成时补挂 + 地图开始时横扫已有虫族
// ============================================================================
public void OnEntityCreated(int entity, const char[] classname)
{
    if (IsAlienClass(classname))
        SDKHookEx(entity, SDKHook_OnTakeDamage, OnAlienDamaged);
}

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

// ============================================================================
//  权限与状态校验
// ============================================================================
bool CanUsePower(int client)
{
    if (!g_cvEnabled.BoolValue)
    {
        if (client > 0)
            PrintToChat(client, "\x04[强化]\x01 功能已关闭");
        return false;
    }
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
        return false;
    if (!g_cvPublic.BoolValue && !CheckCommandAccess(client, "sm_power_admin", ADMFLAG_GENERIC))
    {
        PrintToChat(client, "\x04[强化]\x01 仅管理员可使用");
        return false;
    }
    return true;
}

void ShowStatus(int client)
{
    float scale = GetScaleForLevel(client);
    float melee = GetMeleeMultForLevel(g_iLevel[client]);
    float speed = GetSpeedForLevel(client);
    PrintHintText(client, "强化等级 %d (范围 %d~%d)\n血量上限: %d | 体型: x%.2f\n移速: x%.2f | 近战: x%.2f (电锯除外)",
        g_iLevel[client], -g_cvShrinkMax.IntValue, g_cvMaxLevel.IntValue,
        GetHpForLevel(client), scale, speed, melee);
    PrintToChat(client, "\x04[强化]\x01 等级 \x05%d\x01 | 血量 \x05%d\x01 | 体型 x\x05%.2f\x01 | 移速 x\x05%.2f\x01 | 近战 x\x05%.2f\x01",
        g_iLevel[client], GetHpForLevel(client), scale, speed, melee);
}

void ResetPlayer(int client)
{
    g_iLevel[client] = 0;
    g_iBaseMaxHealth[client] = 0;
}

// ============================================================================
//  周期定时器: 重新断言血量上限/体型/移速(换人/复活后仍生效, 不回血)
// ============================================================================
public Action Timer_Reapply(Handle timer)
{
    if (g_cvEnabled.BoolValue)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsClientInGame(i) || IsFakeClient(i) || g_iLevel[i] == 0)
                continue;
            ApplyPower(i, false);
        }
    }
    return Plugin_Continue;
}

// ============================================================================
//  找某玩家当前控制的 marine 实体 (与 asrd_chainsaw_turbo 相同)
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
            int marine = GetEntPropEnt(client, Prop_Send, "m_hInhabiting");
            if (marine > 0 && IsValidEntity(marine))
                return marine;
        }
    }

    // 办法2: 玩家身上的 m_hInhabiting 数据属性
    if (FindDataMapInfo(client, "m_hInhabiting") > 0)
    {
        int marine = GetEntPropEnt(client, Prop_Data, "m_hInhabiting");
        if (marine > 0 && IsValidEntity(marine))
            return marine;
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
