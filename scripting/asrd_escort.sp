/**
 * ============================================================================
 *  [AS:RD] 护送模式 (Escort)
 *  版本 1.2.0  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ──────────────────────────────────────
 *  每局任务开始 (m_iGameState 进入 ASW_GS_INGAME) 时, 从"真实玩家"中随机
 *  指定一名护送对象, 并全服聊天公告。
 *
 *  之后每 0.2 秒检查一次该对象的陆战队员:
 *    - 处于"倒地"状态 (m_bKnockedOut = 1, 血量 = 最大血量-10, 可被队友扶起)
 *      → 不算阵亡, 继续任务; 并全服广播一次救援提示 (每次倒地只播一次,
 *        被扶起后复位, 再次倒地会重新提示)
 *    - 彻底阵亡 (未倒地 且 血量 <= 0, 或 marine 实体已从世界移除)
 *      → 全服公告, 并调用 VScript 的 Director.MissionComplete(false)
 *        直接判本局任务失败
 *
 *  ── 为什么这样判断 ──────────────────────────────────────
 *  见 rd_asw_marine.cpp: OnTakeDamage 里血量 <= 0 时, 若 rd_allow_revive 开启
 *  则先 SetHealth(GetMaxHealth()-10) + SetKnockedOut(true) (倒地);
 *  若已经处于倒地状态再被打死, 则 SetKnockedOut(false) 后 Event_Killed,
 *  最终血量仍 <= 0。所以"未倒地 + 血量 <= 0"才是彻底阵亡。
 *
 *  ── 任务失败通道 ───────────────────────────────────────
 *  SourceMod 无法直接调用 C++ 的 CAlienSwarm::MissionComplete,
 *  但游戏通过 VScript 向所有实体暴露了 RunScriptCode 输入
 *  (rd_baseentity.cpp: InputRunScript), 而 CDirector 单例的
 *  MissionComplete(bool) 在 asw_gamerules_vscript.cpp 中注册。
 *  因此本插件向 asw_gamerules 实体发送 RunScriptCode:
 *      Director.MissionComplete(false);
 *  失败时退回向玩家实体发送 (与该服务器已验证可用的 asrd_midjoin 同一通道)。
 *
 *  ── 特殊情况 ───────────────────────────────────────────
 *  - 护送对象掉线: 若掉线前已经彻底阵亡, 仍判任务失败; 否则重新随机指定
 *    一名新的护送对象并公告 (不会因掉线而误判失败)。
 *  - 换图 / 任务重开 (asw_mission_restart / mp_restartgame / restart) 会
 *    重置状态, 新一局重新指定。
 *
 *  ── 护送对象血量 ───────────────────────────────────────
 *  选中时把其陆战队员的最大血量改为 "该角色原生最大血量 × sm_asrd_escort_hp_ratio"
 *  (默认 0.5 = 一半), 当前血量只向下夹到新上限 (不回血)。
 *  原生最大血量在陆战队员生成时记录 (OnEntityCreated + 0.05s), 避免误抓到
 *  已被强化过的数值; 另向 asrd_marine_power 查询它记录的原生值作交叉校验。
 *  同时对外暴露 public ASRD_Escort_IsVipClient(client), asrd_marine_power
 *  据此跳过护送对象的一切强化 (血量 / 体型 / 移速 / 近战加成),
 *  全队强化等级升级也不会把护送对象顶回去。
 *  关闭总开关 / 换护送对象 / 插件卸载时会恢复原生最大血量。
 *
 *  ── ConVar (自动生成 cfg/sourcemod/asrd_escort.cfg) ─────
 *   sm_asrd_escort_enabled   总开关 (默认 1)
 *   sm_asrd_escort_hp_ratio  护送对象最大血量比例 (默认 0.5, 范围 0.1~1.0)
 *   sm_asrd_escort_debug     调试输出 (默认 0)
 *
 *  依赖: SourceMod 1.11+ (核心 + sdktools), 服务器需启用 VScript
 * ============================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_NAME    "[AS:RD] Escort"
#define PLUGIN_VERSION "1.2.0"

#define GAME_STATE_INGAME   3       // ASW_GS_INGAME (asw_gamerules.h)
#define MAX_MARINE_RES      32      // ASW_MAX_MARINE_RESOURCES (asw_shareddefs.h)
#define VIP_CHECK_INTERVAL  0.2     // 护送对象状态检查间隔(秒)
#define MAX_ESCORT_ENT      2048    // 实体索引上限 (按实体索引存原生最大血量)

ConVar g_cvEnabled;
ConVar g_cvHpRatio;
ConVar g_cvDebug;

// 当前护送对象
int  g_iVipUserid = 0;              // 断线重连后 userid 变化, 用 userid 识别
int  g_iVipRes = 0;                 // 护送对象的 marine resource 实体索引
char g_szVipName[MAX_NAME_LENGTH];
bool g_bPicked = false;
bool g_bFailed = false;
bool g_bVipDownedNotified = false;  // 本次倒地是否已广播过救援提示 (扶起后复位)

// 护送对象血量: 原生最大血量 / 目标最大血量 (选中时算一次, 之后只重断言不重算)
int   g_iVipBaseHp = 0;
int   g_iVipTargetHp = 0;
float g_fVipRatioUsed = -1.0;       // 计算目标值时用的 hp_ratio (改 ConVar 时据此重算)

// 陆战队员生成时的原生最大血量 (按实体索引存; 实体重建时覆盖)
int  g_iMarineBaseHp[MAX_ESCORT_ENT];

float g_fNextPickAt = 0.0;
float g_fNextCheckAt = 0.0;

public Plugin myinfo =
{
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "开局随机指定护送对象, 其彻底阵亡(不含倒地)则直接判任务失败",
    version     = PLUGIN_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    g_cvEnabled = CreateConVar("sm_asrd_escort_enabled", "1",
        "护送模式总开关 (0=关 1=开)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvHpRatio = CreateConVar("sm_asrd_escort_hp_ratio", "0.5",
        "护送对象最大血量 = 该角色原生最大血量 × 此比例 (0.5=一半, 1.0=不削减)",
        FCVAR_NOTIFY, true, 0.1, true, 1.0);
    g_cvDebug = CreateConVar("sm_asrd_escort_debug", "0",
        "调试输出 (0=关 1=开)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    HookConVarChange(g_cvEnabled, OnEnabledChanged);
    HookConVarChange(g_cvHpRatio, OnHpRatioChanged);

    AutoExecConfig(true, "asrd_escort");

    // 同图重开: asw_mission_restart + mp_restartgame / restart (与友伤/积分插件同一套监听)
    HookEventEx("asw_mission_restart", Event_MissionRestart, EventHookMode_Post);
    AddCommandListener(Listener_Restart, "mp_restartgame");
    AddCommandListener(Listener_Restart, "restart");
}

// ── 同图重开命令: 重置并等待新一局开局 ──
public Action Listener_Restart(int client, const char[] command, int argc)
{
    ResetEscortState();
    return Plugin_Continue;
}

// ── 换图: 重置并等待新一局开局 ──
public void OnMapStart()
{
    // 新地图的实体索引会重新使用, 清掉上一张图记录的原生血量
    for (int i = 0; i < MAX_ESCORT_ENT; i++)
        g_iMarineBaseHp[i] = 0;

    // 上一张图的实体已经不存在, 这里只清状态, 不再去改血量
    ClearVipState();
}

// ── 插件卸载: 撤销对当前护送对象的血量修改 ──
public void OnPluginEnd()
{
    RestoreVipMaxHealth();
}

// ── 同图任务重开: 重置并等待新一局开局 ──
public void Event_MissionRestart(Event event, const char[] name, bool dontBroadcast)
{
    ResetEscortState();
}

void ResetEscortState()
{
    // 先还原被削减的最大血量, 再清状态
    RestoreVipMaxHealth();
    ClearVipState();
}

// 只清状态 (不碰实体血量; 换图等旧实体已失效的场合用)
void ClearVipState()
{
    g_iVipUserid = 0;
    g_iVipRes = 0;
    g_szVipName[0] = '\0';
    g_bPicked = false;
    g_bFailed = false;
    g_bVipDownedNotified = false;
    g_iVipBaseHp = 0;
    g_iVipTargetHp = 0;
    g_fVipRatioUsed = -1.0;
    g_fNextPickAt = 0.0;
    g_fNextCheckAt = 0.0;

    if (g_cvDebug.BoolValue)
        PrintToServer("[护送] 状态已重置");
}

// ── 每帧: 开局选人 + 检查护送对象 ──
public void OnGameFrame()
{
    if (!g_cvEnabled.BoolValue)
        return;

    // 只在任务进行中判定 (结算界面里陆战队员还在世界里, 不能误判)
    if (GameRules_GetProp("m_iGameState") != GAME_STATE_INGAME)
        return;

    if (g_bFailed)
        return;

    float now = GetEngineTime();

    if (!g_bPicked)
    {
        // 开局陆战队员可能还没全部生成, 每 0.5 秒重试
        if (now >= g_fNextPickAt)
        {
            g_fNextPickAt = now + 0.5;
            TryPickVip();
        }
        return;
    }

    int vip = GetClientOfUserId(g_iVipUserid);
    if (vip <= 0 || !IsClientInGame(vip))
    {
        // 兜底: 正常会先由 OnClientDisconnect 处理
        ReassignVip("护送对象已离开服务器");
        return;
    }

    if (now < g_fNextCheckAt)
        return;
    g_fNextCheckAt = now + VIP_CHECK_INTERVAL;

    // 每 0.2 秒重断言护送对象的最大血量 (防止被其它插件/事件顶回去)
    int vipMarine = GetVipMarine();
    if (vipMarine > 0)
    {
        ApplyVipMaxHealth(vipMarine);

        // 倒地 (可被队友扶起) 时广播救援提示; 每次倒地只广播一次, 扶起后复位
        bool bDowned = (GetEntProp(vipMarine, Prop_Send, "m_bKnockedOut") != 0);
        if (bDowned && !g_bVipDownedNotified)
        {
            g_bVipDownedNotified = true;
            PrintToChatAll("\x04[护送]\x01 护送对象 \x05%s\x01 已\x07倒地\x01，请队友立即前往救援！", g_szVipName);
        }
        else if (!bDowned)
        {
            g_bVipDownedNotified = false;
        }
    }

    if (IsVipMarineDead())
        FailMission(vip);
}

// ── 随机指定护送对象 ──
void TryPickVip()
{
    int candidates[MAXPLAYERS + 1];
    int count = 0;

    for (int c = 1; c <= MaxClients; c++)
    {
        if (!IsClientInGame(c) || IsFakeClient(c))
            continue;

        // 只考虑"玩家当前真正操控"的陆战队员 (排除 AI 队友)
        int marine = GetPlayerMarine(c);
        if (marine <= 0)
            continue;

        if (IsMarineDownedOrDead(marine))
            continue;

        if (FindResourceByMarineEntity(marine) > 0)
            candidates[count++] = c;
    }

    if (count == 0)
        return;

    int vip = candidates[GetRandomInt(0, count - 1)];

    int marine = GetPlayerMarine(vip);
    if (marine <= 0)
        return;

    int mr = FindResourceByMarineEntity(marine);
    if (mr <= 0)
        return;

    g_iVipUserid = GetClientUserId(vip);
    g_iVipRes = mr;
    g_bPicked = true;
    g_fNextCheckAt = GetEngineTime() + 0.5;   // 稍等半秒再开始判定

    // 削减最大血量 (至原生最大血量的 hp_ratio, 默认一半)
    g_iVipBaseHp = 0;
    g_iVipTargetHp = 0;
    ApplyVipMaxHealth(marine);

    GetClientName(vip, g_szVipName, sizeof(g_szVipName));

    PrintToChatAll("\x04[护送]\x01 本局护送对象：\x05%s\x01，请全队保护，若其彻底阵亡任务将立即失败！",
        g_szVipName);

    if (g_cvDebug.BoolValue)
        PrintToServer("[护送] 选定 %s (userid %d, resource %d)", g_szVipName, g_iVipUserid, mr);
}

// ── 掉线/重新指定 ──
public void OnClientDisconnect(int client)
{
    if (!g_bPicked || g_bFailed)
        return;

    if (GetClientUserId(client) != g_iVipUserid)
        return;

    // 总开关关闭期间: 不判失败, 也不重新指定; 对象掉线就清掉状态,
    // 等到重新开启后按新一局规则重新抽取
    if (!g_cvEnabled.BoolValue)
    {
        ResetEscortState();
        return;
    }

    bool running = (GameRules_GetProp("m_iGameState") == GAME_STATE_INGAME);

    // 掉线前已经彻底阵亡 → 仍按护送失败处理
    if (running && IsVipMarineDead())
    {
        FailMission(client);
        return;
    }

    if (running)
        ReassignVip("护送对象已离开服务器");
    else
        ResetEscortState();
}

// 取消当前对象并等待下一次随机指定
void ReassignVip(const char[] reason)
{
    if (g_bFailed)
        return;

    // 旧对象不再是护送对象, 恢复其原生最大血量
    RestoreVipMaxHealth();

    PrintToChatAll("\x04[护送]\x01 %s，正在重新指定护送对象...", reason);

    g_iVipUserid = 0;
    g_iVipRes = 0;
    g_szVipName[0] = '\0';
    g_bPicked = false;
    g_bVipDownedNotified = false;
    g_iVipBaseHp = 0;
    g_iVipTargetHp = 0;
    g_fVipRatioUsed = -1.0;
    g_fNextPickAt = 0.0;
    g_fNextCheckAt = 0.0;
}

// ── 玩家当前操控的 marine 实体 (m_hInhabiting; 找不到返回 0) ──
// 与 asrd_ff.sp 同款实现: 先读网络属性, 再退回 datamap
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
    return 0;
}

// ── 记录陆战队员生成时的原生最大血量 ──
// OnEntityCreated 时实体还没 Spawn(属性尚未写入), 延迟 0.05 秒再读;
// 这个时间远早于强化插件的 1 秒定时器, 读到的通常是角色原生值。
public void OnEntityCreated(int entity, const char[] classname)
{
    if (strcmp(classname, "asw_marine") != 0)
        return;

    CreateTimer(0.05, Timer_CaptureBaseHp, EntIndexToEntRef(entity), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_CaptureBaseHp(Handle timer, any ref)
{
    int entity = EntRefToEntIndex(ref);
    if (entity <= 0 || entity >= MAX_ESCORT_ENT || !IsValidEntity(entity))
        return Plugin_Stop;

    int hp = GetEntProp(entity, Prop_Data, "m_iMaxHealth");
    if (hp > 0)
        g_iMarineBaseHp[entity] = hp;

    return Plugin_Stop;
}

// ── 当前护送对象的 marine 实体 (无效返回 0) ──
int GetVipMarine()
{
    if (g_iVipRes <= 0 || !IsValidEntity(g_iVipRes))
        return 0;

    // 防止实体索引被别的实体复用后误读属性
    char cls[64];
    GetEdictClassname(g_iVipRes, cls, sizeof(cls));
    if (strcmp(cls, "asw_game_resource") != 0)
        return 0;

    int marine = GetEntPropEnt(g_iVipRes, Prop_Send, "m_MarineEntity");
    if (marine <= 0 || !IsValidEntity(marine))
        return 0;

    return marine;
}

// ── 落实护送对象的最大血量 = 原生最大血量 × hp_ratio ──
void ApplyVipMaxHealth(int marine)
{
    if (marine <= 0 || !IsValidEntity(marine))
        return;

    float ratio = g_cvHpRatio.FloatValue;
    if (g_iVipTargetHp <= 0 || g_fVipRatioUsed != ratio)
    {
        g_iVipBaseHp = ResolveVipBaseHp(marine);
        g_iVipTargetHp = RoundToNearest(float(g_iVipBaseHp) * ratio);
        if (g_iVipTargetHp < 1)
            g_iVipTargetHp = 1;
        g_fVipRatioUsed = ratio;

        if (g_cvDebug.BoolValue)
            PrintToServer("[护送] 原生最大血量 %d × %.2f = %d",
                g_iVipBaseHp, g_cvHpRatio.FloatValue, g_iVipTargetHp);
    }

    if (GetEntProp(marine, Prop_Data, "m_iMaxHealth") != g_iVipTargetHp)
        SetEntProp(marine, Prop_Data, "m_iMaxHealth", g_iVipTargetHp);

    // 只向下夹到新上限, 不回血
    if (GetEntProp(marine, Prop_Data, "m_iHealth") > g_iVipTargetHp)
        SetEntProp(marine, Prop_Data, "m_iHealth", g_iVipTargetHp);
}

// ── 取该陆战队员的原生最大血量 ──
// 优先级: asrd_marine_power 记录的原生值 > 生成时抓到的值 > 当前值
int ResolveVipBaseHp(int marine)
{
    // 已算过就沿用, 避免从"已被削减"的当前值反推 (改 hp_ratio 时重算)
    if (g_iVipBaseHp > 0)
        return g_iVipBaseHp;

    int client = GetClientOfUserId(g_iVipUserid);
    int base = (client > 0) ? GetPowerBaseHealth(client) : 0;
    if (base > 0)
        return base;

    if (marine < MAX_ESCORT_ENT && g_iMarineBaseHp[marine] > 0)
        return g_iMarineBaseHp[marine];

    base = GetEntProp(marine, Prop_Data, "m_iMaxHealth");
    return (base > 0) ? base : 100;
}

// ── 恢复护送对象的原生最大血量 (只改上限, 不回血) ──
void RestoreVipMaxHealth()
{
    int marine = GetVipMarine();
    if (marine > 0 && g_iVipBaseHp > 0)
        SetEntProp(marine, Prop_Data, "m_iMaxHealth", g_iVipBaseHp);

    g_iVipBaseHp = 0;
    g_iVipTargetHp = 0;
}

// ── 向 asrd_marine_power 查询该玩家强化前的原生最大血量 (未加载/无记录返回 0) ──
int GetPowerBaseHealth(int client)
{
    Handle hPower = FindPluginByFile("asrd_marine_power.smx");
    if (hPower == INVALID_HANDLE || GetPluginStatus(hPower) != Plugin_Running)
        return 0;

    Function fn = GetFunctionByName(hPower, "ASRD_GetPowerBaseHealth");
    if (fn == INVALID_FUNCTION)
        return 0;

    int ret = 0;
    Call_StartFunction(hPower, fn);
    Call_PushCell(client);
    Call_Finish(ret);
    return ret;
}

// ── 供 asrd_marine_power 跨插件调用 ──
// 返回 1 = 该玩家是本局护送对象, 强化插件需跳过对其的血量强化
public int ASRD_Escort_IsVipClient(int client)
{
    if (!g_cvEnabled.BoolValue || !g_bPicked || g_bFailed)
        return 0;
    if (client <= 0)
        return 0;

    return (GetClientUserId(client) == g_iVipUserid) ? 1 : 0;
}

// ── 总开关变更: 关闭时撤销血量修改, 重新开启时再落实 ──
public void OnEnabledChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (convar.BoolValue)
    {
        if (g_bPicked && !g_bFailed)
        {
            int marine = GetVipMarine();
            if (marine > 0)
            {
                g_iVipBaseHp = 0;
                g_iVipTargetHp = 0;
                ApplyVipMaxHealth(marine);
            }
        }
        return;
    }

    RestoreVipMaxHealth();
}

// ── 血量比例变更: 用已记录的原生值重算上限 ──
public void OnHpRatioChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (!g_bPicked || !g_cvEnabled.BoolValue)
        return;

    int marine = GetVipMarine();
    if (marine <= 0)
        return;

    g_iVipTargetHp = 0;
    ApplyVipMaxHealth(marine);
}

// ── 通过 marine 实体找到它在 asw_game_resource 里的 resource 实体 ──
int FindResourceByMarineEntity(int marine)
{
    int res = FindEntityByClassname(-1, "asw_game_resource");
    if (res <= 0)
        return 0;

    for (int i = 0; i < MAX_MARINE_RES; i++)
    {
        int mr = GetEntPropEnt(res, Prop_Send, "m_MarineResources", i);
        if (mr <= 0)
            continue;

        if (GetEntPropEnt(mr, Prop_Send, "m_MarineEntity") == marine)
            return mr;
    }
    return 0;
}

// ── 陆战队员是否倒地或阵亡 (两者都不能作为开局护送对象的人选) ──
bool IsMarineDownedOrDead(int marine)
{
    if (marine <= 0 || !IsValidEntity(marine))
        return true;

    if (GetEntProp(marine, Prop_Send, "m_bKnockedOut") != 0)
        return true;

    return GetEntProp(marine, Prop_Data, "m_iHealth") <= 0;
}

// ── 护送对象是否已彻底阵亡 (倒地不算) ──
bool IsVipMarineDead()
{
    int mr = g_iVipRes;
    if (mr <= 0 || !IsValidEntity(mr))
        return true;

    int marine = GetEntPropEnt(mr, Prop_Send, "m_MarineEntity");
    if (marine <= 0 || !IsValidEntity(marine))
        return true;

    // 倒地: 血量 = 最大血量-10, 仍 > 0, 可被队友扶起
    if (GetEntProp(marine, Prop_Send, "m_bKnockedOut") != 0)
        return false;

    return GetEntProp(marine, Prop_Data, "m_iHealth") <= 0;
}

// ── 判任务失败 ──
void FailMission(int vipClient)
{
    if (g_bFailed)
        return;
    g_bFailed = true;

    PrintToChatAll("\x04[护送]\x01 护送对象 \x05%s\x01 已阵亡，\x07任务失败！\x01", g_szVipName);
    PrintToServer("[护送] 护送对象 %s 阵亡, 调用 Director.MissionComplete(false)", g_szVipName);

    if (!TriggerMissionFail(vipClient))
    {
        PrintToServer("[护送] 警告: RunScriptCode 调用失败, 任务失败未生效 (服务器是否启用 VScript?)");
        PrintToChatAll("\x04[护送]\x01 警告：服务器 VScript 不可用，任务失败未能生效");
    }
}

// ── 通过 RunScriptCode 输入调用 VScript: Director.MissionComplete(false) ──
bool TriggerMissionFail(int vipClient)
{
    // 优先发给 asw_gamerules 实体 (任务期间一定存在, 不依赖玩家状态)
    int gamerules = FindEntityByClassname(-1, "asw_gamerules");
    if (gamerules > 0)
    {
        SetVariantString("Director.MissionComplete(false);");
        if (AcceptEntityInput(gamerules, "RunScriptCode"))
            return true;
    }

    // 退回: 发给护送对象本人 (与该服务器已验证的 asrd_midjoin 同一通道)
    if (vipClient > 0 && IsClientInGame(vipClient))
    {
        SetVariantString("Director.MissionComplete(false);");
        if (AcceptEntityInput(vipClient, "RunScriptCode"))
            return true;
    }

    // 最后兜底: 任意真实玩家
    for (int c = 1; c <= MaxClients; c++)
    {
        if (!IsClientInGame(c) || IsFakeClient(c))
            continue;

        SetVariantString("Director.MissionComplete(false);");
        if (AcceptEntityInput(c, "RunScriptCode"))
            return true;
    }

    return false;
}
