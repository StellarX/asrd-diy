/**
 * ============================================================================
 *  Plugin: [AS:RD] 叛变虫群 (Alien Civil War)
 *
 *  描述: 生成一批"叛变虫群", 它们的攻击对象是**虫族**而不是玩家。
 *        通过着色(RenderColor)与普通虫族在外观上区分, 免冷却, 可自选虫种。
 *  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  命令:
 *    sm_betray     [type] [count]   管理员: 生成一批叛变虫群 (可指定虫种/数量)
 *    sm_betraypub  [type] [count]   玩家:   同上 (需管理员开启 public)
 *    sm_betray_list                 列出可生成的虫种
 *    sm_betray_clear                清除本插件生成的所有叛变虫
 *
 *  绑定按键 (玩家控制台输入一次, 存入 config.cfg 跨局生效):
 *    bind F8 "sm_betraypub"
 *
 *  实现原理:
 *    1. CreateEntityByName(<虫族类名>) + DispatchSpawn 生成虫族实体。
 *    2. DispatchKeyValue("targetname", "asrd_betray_swarm") 打唯一标记。
 *    3. 用 ai_relationship 实体改写关系:
 *       - 叛变虫 ↔ 所有虫族类: 仇恨(Hate, 互反), 使双方互相攻击;
 *       - 叛变虫之间: 友善(Like, 优先级更高), 避免同批自相残杀;
 *       - 叛变虫 ↔ 陆战队员: 中立(Neutral), 使其不攻击玩家。
 *       (AS:RD 虫族继承 CAI_BaseNPC, IRelationType 走标准关系系统;
 *        哨戒塔自 2022 更新起同样使用 ai_relationship, 该实体在 AS:RD 可用)
 *    4. SetEntProp(m_clrRender) 着色, 与正常虫族外观区分。
 *
 *  依赖: SourceMod 1.11+ (核心 + sdktools; 不依赖 SDKHooks)
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] 叛变虫群"
#define PLUGIN_VERSION "1.0.0"

// 叛变虫的统一 targetname, 供 ai_relationship 以"名字"精确匹配
#define INFECTED_NAME  "asrd_betray_swarm"
// 单次生成数量上限, 防止刷屏/卡服
#define MAX_BATCH      80

// 关系枚举 (与 basecombatcharacter.h 的 Disposition_t 一致)
#define DISP_HATE      1
#define DISP_FEAR      2
#define DISP_LIKE      3
#define DISP_NEUTRAL   4

// 关系优先级 (rank, 越大越强)
#define RANK_MAIN      90   // 叛变虫对虫族/陆战队员的主关系
#define RANK_SELF      95   // 叛变虫之间保持友善, 略高于主关系

// ─── 可生成的虫种: {类名, 中文名, 别名} ──────────────────
char g_sTypes[][3][] = {
    { "asw_drone",         "普通工蜂",   "drone"    },
    { "asw_drone_jumper",  "跳跃工蜂",   "jumper"   },
    { "asw_drone_uber",    "强化工蜂",   "uber"     },
    { "asw_drone_antlion", "蚁狮工蜂",   "antlion"  },
    { "asw_boomer",        "爆裂虫",     "boomer"   },
    { "asw_parasite",      "抱脸寄生虫", "parasite" },
    { "asw_ranger",        "游侠",       "ranger"   },
    { "asw_mortarbug",     "迫击炮虫",   "mortar"   },
    { "asw_shieldbug",     "盾甲虫",     "shield"   },
    { "asw_buzzer",        "蜂群",       "buzzer"   },
    { "asw_harvester",     "收割者",     "harvester"},
    { "asw_grub",          "幼虫",       "grub"     }
};

// ─── 场上所有"敌方虫族"类名 (叛变虫对它们持仇恨态度) ────
char g_sAlienClasses[][] = {
    "asw_drone",
    "asw_drone_jumper",
    "asw_drone_uber",
    "asw_drone_antlion",
    "asw_parasite",
    "asw_parasite_defanged",
    "asw_egg",
    "asw_boomer",
    "asw_buzzer",
    "asw_harvester",
    "asw_mortarbug",
    "asw_ranger",
    "asw_shieldbug",
    "asw_grub",
    "asw_queen"
};

// ─── ConVar 句柄 ─────────────────────────────────────────
ConVar g_cvEnabled;
ConVar g_cvType;
ConVar g_cvCount;
ConVar g_cvSpread;
ConVar g_cvColor;
ConVar g_cvHostile;
ConVar g_cvPublic;
ConVar g_cvDebug;

// 关系实体是否已建立 (每个地图只建一次)
bool g_bRelReady;

// ============================================================================
//  插件信息
// ============================================================================
public Plugin myinfo = {
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "生成攻击虫族的叛变虫群, 可着色区分、免冷却、自选虫种",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
//  插件加载
// ============================================================================
public void OnPluginStart()
{
    CreateConVar("sm_asrd_betray_version", PLUGIN_VERSION,
        "插件版本", FCVAR_NOTIFY | FCVAR_DONTRECORD);

    g_cvEnabled = CreateConVar(
        "sm_asrd_betray_enabled", "1",
        "启用/禁用叛变虫群 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvType = CreateConVar(
        "sm_asrd_betray_type", "asw_drone",
        "默认生成的虫种类名 (如 asw_drone / asw_boomer, 见 sm_betray_list)",
        FCVAR_NOTIFY);

    g_cvCount = CreateConVar(
        "sm_asrd_betray_count", "10",
        "默认每批生成数量",
        FCVAR_NOTIFY, true, 1.0, true, float(MAX_BATCH));

    g_cvSpread = CreateConVar(
        "sm_asrd_betray_spread", "120.0",
        "生成时相对召唤者闪光点的散布半径(游戏单位)",
        FCVAR_NOTIFY, true, 0.0, true, 500.0);

    g_cvColor = CreateConVar(
        "sm_asrd_betray_color", "255 40 40",
        "叛变虫着色 RGB (如 180 0 255 紫色), 用空格分隔",
        FCVAR_NOTIFY);

    g_cvHostile = CreateConVar(
        "sm_asrd_betray_hostile", "1",
        "是否让叛变虫与虫族互相敌对 (0=仅着色仍攻击陆战队员, 用于排查)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvPublic = CreateConVar(
        "sm_asrd_betray_public", "0",
        "允许普通玩家使用 sm_betraypub (0=仅管理员 1=所有人)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvDebug = CreateConVar(
        "sm_asrd_betray_debug", "0",
        "调试输出 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    AutoExecConfig(true, "asrd_alien_civilwar");

    RegAdminCmd("sm_betray", Command_Betray, ADMFLAG_GENERIC,
        "生成一批叛变虫群. 用法: sm_betray [type] [count]");
    RegConsoleCmd("sm_betraypub", Command_BetrayPublic, "生成叛变虫群 (需管理员开启)");
    RegAdminCmd("sm_betray_list", Command_List, ADMFLAG_GENERIC, "列出可生成的虫种");
    RegAdminCmd("sm_betray_clear", Command_Clear, ADMFLAG_GENERIC, "清除本插件生成的叛变虫");
}

// ============================================================================
//  地图加载: 关系实体随地图重建
// ============================================================================
public void OnMapStart()
{
    g_bRelReady = false;
}

// ============================================================================
//  命令 (管理员): sm_betray [type] [count]
// ============================================================================
public Action Command_Betray(int client, int args)
{
    return DoBetray(client, args);
}

// ============================================================================
//  命令 (玩家): sm_betraypub [type] [count]
// ============================================================================
public Action Command_BetrayPublic(int client, int args)
{
    if (!g_cvPublic.BoolValue)
    {
        ReplyToCommand(client, "[叛变虫群] 该功能未对玩家开放");
        return Plugin_Handled;
    }
    return DoBetray(client, args);
}

// ============================================================================
//  核心: 解析参数并生成
// ============================================================================
Action DoBetray(int client, int args)
{
    if (!g_cvEnabled.BoolValue)
    {
        ReplyToCommand(client, "[叛变虫群] 功能已禁用");
        return Plugin_Handled;
    }

    // ── 解析虫种 ──
    char sType[64];
    g_cvType.GetString(sType, sizeof(sType));

    if (args >= 1)
    {
        char sArg[64];
        GetCmdArg(1, sArg, sizeof(sArg));

        if (!ResolveType(sArg, sType, sizeof(sType)))
        {
            ReplyToCommand(client, "[叛变虫群] 未知虫种 \"%s\", 用 sm_betray_list 查看可选虫种", sArg);
            return Plugin_Handled;
        }
    }

    // ── 解析数量 ──
    int iCount = g_cvCount.IntValue;
    if (args >= 2)
    {
        char sArg[16];
        GetCmdArg(2, sArg, sizeof(sArg));
        int n = StringToInt(sArg);
        if (n > 0)
            iCount = n;
    }
    if (iCount < 1) iCount = 1;
    if (iCount > MAX_BATCH) iCount = MAX_BATCH;

    // ── 生成中心: 召唤者控制的陆战队员 ──
    float fCenter[3];
    if (!GetMarineOrigin(client, fCenter))
    {
        ReplyToCommand(client, "[叛变虫群] 无法确定生成位置");
        return Plugin_Handled;
    }

    // 关系实体 (首次调用时建立)
    EnsureRelationships();

    float fSpread = g_cvSpread.FloatValue;
    int iOk = 0;

    for (int i = 0; i < iCount; i++)
    {
        float fPos[3];
        fPos[0] = fCenter[0] + GetRandomFloat(-fSpread, fSpread);
        fPos[1] = fCenter[1] + GetRandomFloat(-fSpread, fSpread);
        fPos[2] = fCenter[2];

        if (SpawnAlien(sType, fPos) != -1)
            iOk++;
    }

    if (g_cvDebug.BoolValue)
        PrintToServer("[叛变虫群] client=%d type=%s count=%d 成功=%d", client, sType, iCount, iOk);

    char sName[MAX_NAME_LENGTH];
    GetClientName(client, sName, sizeof(sName));
    PrintToChatAll("\x04[叛变虫群]\x01 %s 召唤了 %d 只\x05叛变%s\x01!",
        sName, iOk, sType);

    return Plugin_Handled;
}

// ============================================================================
//  生成单个叛变虫
// ============================================================================
int SpawnAlien(const char[] sClass, const float fPos[3])
{
    int ent = CreateEntityByName(sClass);
    if (ent == -1)
    {
        if (g_cvDebug.BoolValue)
            PrintToServer("[叛变虫群] 创建实体 %s 失败", sClass);
        return -1;
    }

    // 打统一标记, 供 ai_relationship 按名字匹配
    DispatchKeyValue(ent, "targetname", INFECTED_NAME);
    // 强制睡眠时也渲染 (AS:RD 睡眠虫默认不渲染, 是"看不见"的常见原因)
    DispatchKeyValue(ent, "visiblewhenasleep", "1");

    float fAng[3];
    fAng[1] = GetRandomFloat(0.0, 360.0);
    // 先设位置再生成, 对齐 asw_spawner 的 SetAbsOrigin → DispatchSpawn 顺序
    TeleportEntity(ent, fPos, fAng, NULL_VECTOR);

    DispatchSpawn(ent);
    ActivateEntity(ent);

    // 生成后再确认一次位置 (兜底, 防 NPC 出生重置回原点)
    TeleportEntity(ent, fPos, fAng, NULL_VECTOR);

    // 着色区分
    ApplyTint(ent);

    if (g_cvDebug.BoolValue)
        LogSpawned(ent, sClass, fPos);

    return ent;
}

// ============================================================================
//  调试: 打印单个生成实体的模型/位置/有效性
// ============================================================================
void LogSpawned(int ent, const char[] sClass, const float fWant[3])
{
    char sModel[128] = "(无)";
    GetEntPropString(ent, Prop_Data, "m_ModelName", sModel, sizeof(sModel));

    float fOrg[3];
    if (HasEntProp(ent, Prop_Send, "m_vecOrigin"))
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", fOrg);

    PrintToServer("[叛变虫群] #%d %s 有效=%d model=%s 期望=%.0f,%.0f,%.0f 实际=%.0f,%.0f,%.0f",
        ent, sClass, IsValidEntity(ent), sModel,
        fWant[0], fWant[1], fWant[2], fOrg[0], fOrg[1], fOrg[2]);
}

// ============================================================================
//  着色: 用 m_clrRender 给叛变虫染色 (存在性做兜底, 避免 ThrowError)
// ============================================================================
void ApplyTint(int ent)
{
    char sClass[64];
    GetEntityClassname(ent, sClass, sizeof(sClass));

    int iColor;
    if (!ParseColor(iColor))
    {
        if (g_cvDebug.BoolValue)
            PrintToServer("[叛变虫群] 调色板解析失败, 跳过着色");
        return;
    }

    // 渲染模式: RENDER_TRANSCOLOR(1) 才能让顶点色生效
    if (HasEntProp(ent, Prop_Send, "m_nRenderMode"))
        SetEntProp(ent, Prop_Send, "m_nRenderMode", 1, 1);

    if (HasEntProp(ent, Prop_Send, "m_clrRender"))
        SetEntProp(ent, Prop_Send, "m_clrRender", iColor, 4);
    else if (g_cvDebug.BoolValue)
        PrintToServer("[叛变虫群] %s 无 m_clrRender, 跳过着色", sClass);
}

// ============================================================================
//  解析着色 CVar "R G B" → 0xAABBGGRR
// ============================================================================
bool ParseColor(int &out)
{
    char sColor[32];
    g_cvColor.GetString(sColor, sizeof(sColor));

    int v[3];
    int n = 0;

    char sPart[8];
    int l = 0;
    int len = strlen(sColor);

    for (int i = 0; i <= len; i++)
    {
        if (sColor[i] == ' ' || sColor[i] == '\0')
        {
            if (l > 0 && n < 3)
            {
                sPart[l] = '\0';
                v[n] = StringToInt(sPart);
                n++;
            }
            l = 0;
        }
        else if (IsCharNumeric(sColor[i]) && l < sizeof(sPart) - 1)
        {
            sPart[l++] = sColor[i];
        }
        else
        {
            return false; // 含非法字符
        }
    }

    if (n < 3)
        return false;

    // 钳制到 0~255
    int r = ClampI(v[0]);
    int g = ClampI(v[1]);
    int b = ClampI(v[2]);

    out = (255 << 24) | (b << 16) | (g << 8) | r;
    return true;
}

int ClampI(int v)
{
    if (v < 0) return 0;
    if (v > 255) return 255;
    return v;
}

// ============================================================================
//  建立 ai_relationship: 叛变虫 ↔ 虫族 互敌, 叛变虫内部友善, 对陆战队员中立
// ============================================================================
void EnsureRelationships()
{
    if (g_bRelReady)
        return;
    g_bRelReady = true;

    if (!g_cvHostile.BoolValue)
        return;

    // 1) 叛变虫仇视所有虫族 (互反, 让正常虫族也反击叛变虫)
    for (int i = 0; i < sizeof(g_sAlienClasses); i++)
        CreateRelationship(INFECTED_NAME, g_sAlienClasses[i], DISP_HATE, RANK_MAIN, true);

    // 2) 叛变虫之间保持友善 (优先级略高, 覆盖同一类名互仇, 避免自相残杀)
    CreateRelationship(INFECTED_NAME, INFECTED_NAME, DISP_LIKE, RANK_SELF, true);

    // 3) 叛变虫对陆战队员中立 (不主动攻击玩家)
    CreateRelationship(INFECTED_NAME, "asw_marine", DISP_NEUTRAL, RANK_MAIN, false);
}

void CreateRelationship(const char[] sSubject, const char[] sTarget,
                        int iDisp, int iRank, bool bReciprocal)
{
    int rel = CreateEntityByName("ai_relationship");
    if (rel == -1)
    {
        if (g_cvDebug.BoolValue)
            PrintToServer("[叛变虫群] 创建 ai_relationship 失败");
        return;
    }

    char buf[8];

    DispatchKeyValue(rel, "subject", sSubject);
    DispatchKeyValue(rel, "target", sTarget);
    IntToString(iDisp, buf, sizeof(buf));
    DispatchKeyValue(rel, "disposition", buf);
    IntToString(iRank, buf, sizeof(buf));
    DispatchKeyValue(rel, "rank", buf);
    DispatchKeyValue(rel, "Reciprocal", bReciprocal ? "1" : "0");
    DispatchKeyValue(rel, "StartActive", "0"); // 显式用 ApplyRelationship, 规避多人/换图 StartActive 失效

    DispatchSpawn(rel);
    ActivateEntity(rel);
    // ApplyRelationship 后, 之后生成的匹配实体同样生效
    AcceptEntityInput(rel, "ApplyRelationship");
}

// ============================================================================
//  命令: 列出可生成虫种
// ============================================================================
public Action Command_List(int client, int args)
{
    ReplyToCommand(client, "[叛变虫群] 可生成虫种 (类名 = 中文名):");
    for (int i = 0; i < sizeof(g_sTypes); i++)
        ReplyToCommand(client, "  %s = %s", g_sTypes[i][0], g_sTypes[i][1]);
    return Plugin_Handled;
}

// ============================================================================
//  命令: 清除本插件生成的叛变虫
// ============================================================================
public Action Command_Clear(int client, int args)
{
    int iCount = 0;
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "*")) != -1)
    {
        char sName[64];
        if (GetEntPropString(ent, Prop_Data, "m_iName", sName, sizeof(sName))
            && StrEqual(sName, INFECTED_NAME))
        {
            AcceptEntityInput(ent, "Kill");
            iCount++;
        }
    }

    ReplyToCommand(client, "[叛变虫群] 已清除 %d 只叛变虫", iCount);
    return Plugin_Handled;
}

// ============================================================================
//  虫种解析: 支持类名 / 别名 / 中文名 (大小写不敏感)
// ============================================================================
bool ResolveType(const char[] sInput, char[] sOut, int outLen)
{
    for (int i = 0; i < sizeof(g_sTypes); i++)
    {
        if (StrEqual(sInput, g_sTypes[i][0], false)      // 类名
            || StrEqual(sInput, g_sTypes[i][2], false)   // 别名
            || StrEqual(sInput, g_sTypes[i][1], false))  // 中文名
        {
            strcopy(sOut, outLen, g_sTypes[i][0]);
            return true;
        }
    }
    return false;
}

// ============================================================================
//  取召唤者控制的陆战队员坐标 (三种办法, 失败返回 false)
// ============================================================================
bool GetMarineOrigin(int client, float fOut[3])
{
    if (client <= 0 || !IsClientInGame(client))
        return false;

    int iMarine = GetPlayerMarine(client);
    if (IsValidEntity(iMarine))
    {
        // m_vecOrigin 是网络属性, 用 Prop_Send 读取; 带存在性兜底避免 ThrowError
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

    // 兜底: 直接用客户端位置
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

    // 办法1: 玩家身上的 m_hInhabiting 网络属性 (最快)
    char sNetClass[64];
    if (GetEntityNetClass(client, sNetClass, sizeof(sNetClass))
        && FindSendPropInfo(sNetClass, "m_hInhabiting") > 0)
    {
        int iMarine = GetEntPropEnt(client, Prop_Send, "m_hInhabiting");
        if (iMarine > 0 && IsValidEntity(iMarine))
            return iMarine;
    }

    // 办法2: 数据属性
    if (FindDataMapInfo(client, "m_hInhabiting") > 0)
    {
        int iMarine = GetEntPropEnt(client, Prop_Data, "m_hInhabiting");
        if (iMarine > 0 && IsValidEntity(iMarine))
            return iMarine;
    }

    // 办法3: 遍历 marine, 找操控者是该玩家的那个
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "asw_marine")) != -1)
    {
        if (FindDataMapInfo(ent, "m_hCommander") > 0
            && GetEntPropEnt(ent, Prop_Data, "m_hCommander") == client)
            return ent;
    }

    return 0;
}