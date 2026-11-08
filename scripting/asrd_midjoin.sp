/**
 * ============================================================================
 *  [AS:RD] 中途加入 (Mid-Join)
 * 版本 1.0.0  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ─────────────────────────────────────
 *  玩家在任务进行中，可以通过聊天框或控制台输入：
 *      add Sarge          （聊天框直接输入，或 /add Sarge、/sm_add Sarge）
 *      add Wildcat        （也支持 1~8 的数字编号，对应 8 名角色）
 *  即可作为指定角色加入当前正在进行的游戏。
 *
 *  ── 限制条件（与需求一致） ───────────────────────────
 *   1. 每名玩家每局只能成功使用一次 (sm_asrd_midjoin_once, 默认 1)
 *   2. 玩家已经拥有角色（控制任意 NPC 或拥有 marine resource）时无效
 *   3. 任务未开始（Briefing）或已结束（成功/失败）时无效
 *
 *  ── 为什么不会像"直接造实体"那样崩服 ──────────────────
 *  AS:RD 的引擎在 CAlienSwarm::RosterSelect() 里有硬性限制：
 *      if ( !ASWDeathmatchMode() && GetGameState() != ASW_GS_BRIEFING )
 *          return NULL;
 *  也就是说，合作模式中途不允许再"选人"。直接 CreateEntityByName 造
 *  asw_marine 而不同步创建 asw_marine_resource，会在下面这些无条件解引用
 *  GetMarineResource() 的路径上崩服：
 *      CASW_Marine::Weapon_Equip_Post  -> GetMarineResource()->UpdateWeaponIndices()
 *      CASW_Marine::Weapon_Drop        -> GetMarineResource()->UpdateWeaponIndices()
 *      CASW_Marine::TakeWeaponPickup   -> MarineCanPickup(GetMarineResource(), ...)
 *  而且 Player 的 GetMarineResource() 在客户端会因 m_nMarineProfile != -1
 *  直接返回 NULL，导致 HUD 相关的空指针。
 *
 *  本插件不手工拼 marine 实体，而是借用引擎自己的两条完整流程：
 *      RosterSelect()  —— 创建合法 marine resource（含默认武器槽位、指挥官）
 *      SpawnMarineAt() —— 通过玩家侧 ResurrectMarine() 触发，完整生成
 *                         asw_marine（模型、阵营、技能血量、默认武器、复活特效）
 *
 *  具体做法（全部在服务端 VScript 作用域内、同一帧内原子完成）：
 *      a) 暂存 asw_game_resource 的 m_Leader / m_iMaxMarines，
 *         暂存 asw_gamerules 的 m_iGameState；
 *      b) 把 m_iGameState 临时置为 ASW_GS_BRIEFING(1)，让 RosterSelect 放行；
 *      c) 把 m_Leader 临时指向请求玩家、m_iMaxMarines 临时放大到 8；
 *      d) 用引擎暴露的 Convars.ExecuteConCommand() 同步执行 rd_botadd_sv
 *         （该接口明确"忽略 sv_cheats 等要求"，见 asw_gamerules_vscript.cpp）；
 *      e) 立刻还原 m_iGameState / m_Leader / m_iMaxMarines；
 *      f) 把新建 resource 的 m_iWeaponsInSlots 复制到 m_iInitialWeaponsInSlots
 *         （ResurrectMarine 走 bResurrection=true，只会按 initial 槽位发武器）；
 *      g) 调用 player.ResurrectMarine(出生点, true)，由引擎完成 SpawnMarineAt。
 *         它内部会用 GetSkillBasedValueByMarineResource 算血量、发默认武器、
 *         绑定 resource，并在玩家没有 NPC 时自动 SwitchMarine(0) 接管。
 *
 *  临时改 m_iGameState 只持续本条脚本内几行代码，期间不会有任何游戏帧回调
 *  插入执行；还原后客户端收到的仍是最终状态，不会出现中途"回到 Briefing"。
 *
 *  ── 如果角色已经在队伍里 ────────────────────────────────
 *  如果请求的角色已经存在且是"存活的空闲机器人"，插件直接让玩家接管它
 *  （等价于游戏自带的 drop-in 逻辑），不会再造第二个同名角色。
 *  如果该角色正被其他玩家控制、或已经阵亡，则提示无法加入。
 *
 *  ── 已知限制 ───────────────────────────────────────────
 *   - 若角色所属职业已达 asw_marines_max_by_class 上限（默认每职业 2 人），
 *     RosterSelect 会拒绝，插件提示"加入失败"。
 *   - 服务器 rd_player_bots_allowed=0 时，引擎本身禁止 RosterSelect 添加，
 *     插件会给出明确提示，不会强行绕过该开关。
 *   - 新角色不会写入本局的伤害/治疗时间线图表（引擎只在开局时为已有
 *     resource 启动 Timeline），仅影响结算图表美观，不影响玩法。
 *
 *  ── 常用 ConVar ───────────────────────────────────────
 *   sm_asrd_midjoin_enabled   总开关 (0=关 1=开, 默认 1)
 *   sm_asrd_midjoin_public    允许普通玩家使用 (0=仅管理员 1=公开, 默认 1)
 *   sm_asrd_midjoin_once      每名玩家每局只能成功一次 (0=不限, 默认 1)
 *   sm_asrd_midjoin_bare      允许聊天框不带 / 直接输入 "add Sarge" (默认 1)
 *   sm_asrd_midjoin_announce  成功加入后全服公告 (0=仅本人, 默认 1)
 *   sm_asrd_midjoin_debug     调试输出 (默认 0)
 *
 *  ── 部署 ───────────────────────────────────────────────
 *   plugins/tools/sourcemod/scripting/spcomp.exe \
 *     -i plugins/tools/sourcemod/scripting/include \
 *     -o plugins/asrd_midjoin.smx scripting/asrd_midjoin.sp
 *   然后 sm plugins load asrd_midjoin（或换图后自动加载）
 *
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] Mid-Join"
#define PLUGIN_VERSION "1.0.0"

#define MAX_MARINES        8
#define GAME_STATE_INGAME  3

// 角色顺序与引擎 ASW_MARINE_PROFILE_* 一致（asw_marine_profile.cpp / rd_loadout.cpp）
char g_szProfileKey[][] =
{
    "sarge", "wildcat", "faith", "crash", "jaeger", "wolfe", "bastille", "vegas"
};
char g_szProfileName[][] =
{
    "Sarge", "Wildcat", "Faith", "Crash", "Jaeger", "Wolfe", "Bastille", "Vegas"
};

ConVar g_cvEnabled;
ConVar g_cvPublic;
ConVar g_cvOnce;
ConVar g_cvBare;
ConVar g_cvAnnounce;
ConVar g_cvDebug;

// 本局已成功使用过的玩家（按 SteamID64 记录，掉线重连仍算同一人）
StringMap g_hUsedXuid;
// 正在执行中的请求（防止同一帧重复触发）
bool  g_bBusy[MAXPLAYERS + 1];
// 每个玩家的最小请求间隔
float g_fNextUse[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "任务进行中输入 add <角色> 即可作为该角色加入（每局一次）",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
//  插件加载
// ============================================================================
public void OnPluginStart()
{
    g_cvEnabled = CreateConVar(
        "sm_asrd_midjoin_enabled", "1",
        "启用/禁用中途加入 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvPublic = CreateConVar(
        "sm_asrd_midjoin_public", "1",
        "是否允许普通玩家使用 (0=仅管理员 1=公开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvOnce = CreateConVar(
        "sm_asrd_midjoin_once", "1",
        "每名玩家每局只能成功加入一次 (0=不限)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvBare = CreateConVar(
        "sm_asrd_midjoin_bare", "1",
        "允许聊天框不带 / 直接输入 add <角色> (0=只认 /add)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvAnnounce = CreateConVar(
        "sm_asrd_midjoin_announce", "1",
        "成功加入后是否全服公告 (0=仅本人可见)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvDebug = CreateConVar(
        "sm_asrd_midjoin_debug", "0",
        "调试输出到服务器控制台 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    AutoExecConfig(true, "asrd_midjoin");

    g_hUsedXuid = new StringMap();

    for (int i = 0; i <= MAXPLAYERS; i++)
    {
        g_bBusy[i]   = false;
        g_fNextUse[i] = 0.0;
    }

    // 控制台 / 聊天框命令：add Sarge、/add Sarge、sm_add Sarge
    RegConsoleCmd("sm_add", Cmd_Add, "作为指定角色加入当前任务：sm_add <角色名或编号>");
    RegConsoleCmd("add",    Cmd_Add, "作为指定角色加入当前任务：add <角色名或编号>");

    // 任务即时重启(重新开始游戏，不换图) 时重置"每局一次"的计数
    HookEventEx("asw_mission_restart", Event_MissionRestart, EventHookMode_Post);
}

public void OnMapStart()
{
    if (g_hUsedXuid != null)
        g_hUsedXuid.Clear();
}

public void OnClientDisconnect(int client)
{
    g_bBusy[client]   = false;
    g_fNextUse[client] = 0.0;
}

public void Event_MissionRestart(Event event, const char[] name, bool dontBroadcast)
{
    if (g_hUsedXuid != null)
        g_hUsedXuid.Clear();

    for (int i = 0; i <= MAXPLAYERS; i++)
    {
        g_bBusy[i]   = false;
        g_fNextUse[i] = 0.0;
    }

    if (g_cvDebug.BoolValue)
        PrintToServer("[中途加入] 任务重启，已重置每局使用计数");
}

// ============================================================================
//  命令入口
// ============================================================================
public Action Cmd_Add(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[SM] 该命令只能由游戏内玩家执行");
        return Plugin_Handled;
    }

    if (args < 1)
    {
        ShowUsage(client);
        return Plugin_Handled;
    }

    char szArg[64];
    GetCmdArg(1, szArg, sizeof(szArg));

    int profile = FindProfile(szArg);
    if (profile < 0)
    {
        PrintToChat(client, "\x04[中途加入]\x01 未知角色: %s", szArg);
        ShowUsage(client);
        return Plugin_Handled;
    }

    DoMidJoin(client, profile);
    return Plugin_Handled;
}

// 聊天框：/add Sarge、!add Sarge，以及可选的裸 "add Sarge"
public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
        return Plugin_Continue;

    char szText[192];
    strcopy(szText, sizeof(szText), sArgs);
    TrimString(szText);
    if (szText[0] == '\0')
        return Plugin_Continue;

    char szArg[64];
    if (!ExtractAddArg(szText, szArg, sizeof(szArg)))
        return Plugin_Continue;

    if (szArg[0] == '\0')
    {
        ShowUsage(client);
        return Plugin_Handled;
    }

    int profile = FindProfile(szArg);
    if (profile < 0)
    {
        PrintToChat(client, "\x04[中途加入]\x01 未知角色: %s", szArg);
        ShowUsage(client);
        return Plugin_Handled;
    }

    DoMidJoin(client, profile);
    return Plugin_Handled;
}

// 从聊天文本中解析 add 命令与参数；不匹配时返回 false（放行普通聊天）
bool ExtractAddArg(const char[] text, char[] arg, int maxlen)
{
    arg[0] = '\0';

    int start = 0;
    bool bSlash = false;
    if (text[0] == '/' || text[0] == '!')
    {
        start = 1;
        bSlash = true;
    }
    else if (!g_cvBare.BoolValue)
    {
        return false;   // 只认 /add
    }

    // 必须是 add 开头，且后面紧跟结束符或空白
    if (strncmp(text[start], "add", 3, false) != 0)
        return false;

    int p = start + 3;
    if (text[p] != '\0' && text[p] != ' ' && text[p] != '\t')
        return false;

    while (text[p] == ' ' || text[p] == '\t')
        p++;

    // 只取第一个参数（忽略后面的多余内容）
    int n = 0;
    while (text[p] != '\0' && text[p] != ' ' && text[p] != '\t' && n < maxlen - 1)
    {
        arg[n++] = text[p++];
    }
    arg[n] = '\0';

    // /add 但没参数：也由本插件接管并提示用法
    return bSlash || (n > 0) || (start == 0 && text[start + 3] == '\0');
}

// ============================================================================
//  主流程
// ============================================================================
void DoMidJoin(int client, int profile)
{
    if (!g_cvEnabled.BoolValue)
    {
        PrintToChat(client, "\x04[中途加入]\x01 该功能已关闭");
        return;
    }

    if (!IsClientInGame(client) || IsFakeClient(client))
        return;

    if (!g_cvPublic.BoolValue
        && !CheckCommandAccess(client, "sm_asrd_midjoin_admin", ADMFLAG_GENERIC))
    {
        PrintToChat(client, "\x04[中途加入]\x01 你没有权限使用该指令");
        return;
    }

    if (g_bBusy[client])
        return;

    float now = GetGameTime();
    if (now < g_fNextUse[client])
        return;

    // 限制 2：已经拥有角色（控制任意 NPC，或名下有 marine resource）
    if (GetEntPropEnt(client, Prop_Send, "m_hInhabiting") > 0)
    {
        PrintToChat(client, "\x04[中途加入]\x01 你已经在游戏中拥有角色，无法再次加入");
        return;
    }
    if (HasMarineResource(client))
    {
        PrintToChat(client, "\x04[中途加入]\x01 你已经在游戏中拥有角色，无法再次加入");
        return;
    }

    // 限制 1：每局一次
    if (g_cvOnce.BoolValue && HasUsed(client))
    {
        PrintToChat(client, "\x04[中途加入]\x01 你本局已经使用过加入机会");
        return;
    }

    char szCode[4096];
    BuildMidJoinCode(profile, szCode, sizeof(szCode));

    g_bBusy[client]    = true;
    g_fNextUse[client] = now + 2.0;

    SetVariantString(szCode);
    bool ok = AcceptEntityInput(client, "RunScriptCode");
    g_bBusy[client] = false;

    if (!ok)
    {
        PrintToChat(client, "\x04[中途加入]\x01 服务器未启用 VScript，功能不可用");
        if (g_cvDebug.BoolValue)
            PrintToServer("[中途加入] RunScriptCode 输入失败 (client %d)", client);
        return;
    }

    // 脚本内部会在失败时给玩家具体原因；这里只在成功后记录/公告
    if (HasProfileMarine(client, profile))
    {
        MarkUsed(client);

        if (g_cvAnnounce.BoolValue)
        {
            PrintToChatAll("\x04[中途加入]\x01 %N 作为 %s 加入了战斗",
                client, g_szProfileName[profile]);
        }
        else
        {
            PrintToChat(client, "\x04[中途加入]\x01 你已作为 %s 加入战斗",
                g_szProfileName[profile]);
        }

        if (g_cvDebug.BoolValue)
        {
            char szName[MAX_NAME_LENGTH];
            GetClientName(client, szName, sizeof(szName));
            LogMessage("[中途加入] %s 成功加入为 %s", szName, g_szProfileName[profile]);
        }
    }
    else if (g_cvDebug.BoolValue)
    {
        char szName[MAX_NAME_LENGTH];
        GetClientName(client, szName, sizeof(szName));
        LogMessage("[中途加入] %s 加入 %s 失败（具体原因已由脚本提示）",
            szName, g_szProfileName[profile]);
    }
}

// ============================================================================
//  引擎通道：构建并执行服务端 VScript 片段
//
//  说明：SourceMod 无法直接调用 CASW_Player::SwitchMarine / SpawnMarineAt
//  这类 C++ 成员函数，但游戏把 VScript 输入 RunScriptCode 暴露在所有实体上。
//  这里把脚本作为字符串通过 AcceptEntityInput 发给玩家实体，脚本内 self=玩家。
//  InputRunScript 会把反引号 ` 替换成双引号 "，因此脚本字符串统一用 ` 包裹，
//  避免与 SourcePawn 的字符串定界符冲突。
// ============================================================================
void AppendCode(char[] code, int maxlen, const char[] text)
{
    StrCat(code, maxlen, text);
}

void BuildMidJoinCode(int profile, char[] code, int maxlen)
{
    char tmp[64];
    code[0] = '\0';

    // ── 1. 取两个全局实体并做状态校验 ───────────────────────────────
    AppendCode(code, maxlen, "local p=self;");
    AppendCode(code, maxlen, "local gr=Entities.FindByClassname(null,`asw_gamerules`);");
    AppendCode(code, maxlen, "local res=Entities.FindByClassname(null,`asw_game_resource`);");
    AppendCode(code, maxlen, "if(gr==null||res==null){ClientPrint(p,3,`[中途加入] 服务器尚未就绪`);return;}");
    AppendCode(code, maxlen, "if(NetProps.GetPropInt(gr,`m_iGameState`)!=3");
    AppendCode(code, maxlen, "||NetProps.GetPropBool(gr,`m_bMissionSuccess`)");
    AppendCode(code, maxlen, "||NetProps.GetPropBool(gr,`m_bMissionFailed`))");
    AppendCode(code, maxlen, "{ClientPrint(p,3,`[中途加入] 当前不在任务进行中（未开始或已结束）`);return;}");

    // ── 2. 角色已存在则优先接管空闲机器人；否则找空槽 ────────────────
    Format(tmp, sizeof(tmp), "local prof=%d;", profile);
    AppendCode(code, maxlen, tmp);
    AppendCode(code, maxlen, "local existing=null;local freeSlot=-1;");
    AppendCode(code, maxlen, "for(local i=0;i<8;i++){");
    AppendCode(code, maxlen, "local r=NetProps.GetPropEntityArray(res,`m_MarineResources`,i);");
    AppendCode(code, maxlen, "if(r==null){if(freeSlot<0)freeSlot=i;}");
    AppendCode(code, maxlen, "else{if(NetProps.GetPropInt(r,`m_MarineProfileIndex`)==prof)existing=r;}}");
    AppendCode(code, maxlen, "if(existing!=null){");
    AppendCode(code, maxlen, "local em=NetProps.GetPropEntity(existing,`m_MarineEntity`);");
    AppendCode(code, maxlen, "if(em!=null&&em.IsValid()&&em.GetHealth()>0&&!em.IsInhabited()){p.SetNPC(em);return;}");
    AppendCode(code, maxlen, "ClientPrint(p,3,`[中途加入] 该角色已在队伍中（阵亡或正被其他玩家控制）`);return;}");
    AppendCode(code, maxlen, "if(freeSlot<0){ClientPrint(p,3,`[中途加入] 队伍已满（最多8名陆战队员）`);return;}");

    // ── 3. 计算出生点：优先观战对象，其次任一存活队友，最后 info_player_start ──
    AppendCode(code, maxlen, "local pos=null;");
    AppendCode(code, maxlen, "local sp=p.GetSpectatingNPC();");
    AppendCode(code, maxlen, "if(sp!=null&&sp.IsValid()&&sp.GetHealth()>0)pos=sp.GetOrigin()+Vector(40,40,0);");
    AppendCode(code, maxlen, "if(pos==null){local m=null;");
    AppendCode(code, maxlen, "while((m=Entities.FindByClassname(m,`asw_marine`))!=null){");
    AppendCode(code, maxlen, "if(m.IsValid()&&m.GetHealth()>0){pos=m.GetOrigin()+Vector(40,40,0);break;}}}");
    AppendCode(code, maxlen, "if(pos==null){local s=Entities.FindByClassname(null,`info_player_start`);");
    AppendCode(code, maxlen, "if(s!=null)pos=s.GetOrigin();}");
    AppendCode(code, maxlen, "if(pos==null){ClientPrint(p,3,`[中途加入] 找不到可用的出生位置`);return;}");

    // ── 4. 临时伪造 Briefing 状态，让引擎 RosterSelect 放行 ───────────
    //     同帧内完成并还原；不经过任何游戏帧回调。
    //     所有临时改动包在 try 内，异常也一定会走到后面的还原语句。
    AppendCode(code, maxlen, "if(Convars.GetFloat(`rd_player_bots_allowed`)<=0)");
    AppendCode(code, maxlen, "{ClientPrint(p,3,`[中途加入] 服务器已禁用（rd_player_bots_allowed 0）`);return;}");
    AppendCode(code, maxlen, "local os=NetProps.GetPropInt(gr,`m_iGameState`);");
    AppendCode(code, maxlen, "local ol=NetProps.GetPropEntity(res,`m_Leader`);");
    AppendCode(code, maxlen, "local om=NetProps.GetPropInt(res,`m_iMaxMarines`);");
    AppendCode(code, maxlen, "try{");
    AppendCode(code, maxlen, "NetProps.SetPropEntity(res,`m_Leader`,p);");
    AppendCode(code, maxlen, "NetProps.SetPropInt(res,`m_iMaxMarines`,8);");
    AppendCode(code, maxlen, "NetProps.SetPropInt(gr,`m_iGameState`,1);");
    AppendCode(code, maxlen, "Convars.ExecuteConCommand(`rd_botadd_sv `+(prof+1).tostring());");
    AppendCode(code, maxlen, "}catch(e){}");
    AppendCode(code, maxlen, "NetProps.SetPropInt(gr,`m_iGameState`,os);");
    AppendCode(code, maxlen, "NetProps.SetPropEntity(res,`m_Leader`,ol);");
    AppendCode(code, maxlen, "NetProps.SetPropInt(res,`m_iMaxMarines`,om);");

    // ── 5. 找到新建 resource，复制武器槽位，触发引擎 SpawnMarineAt ─────
    //     这里按 profile 找（前面已确认没有同角色），不依赖 m_Leader 临时改写是否成功；
    //     若引擎把 commander 记到了别人身上，则强制改回请求玩家。
    AppendCode(code, maxlen, "local nr=null;local ns=-1;");
    AppendCode(code, maxlen, "for(local i=0;i<8;i++){");
    AppendCode(code, maxlen, "local r=NetProps.GetPropEntityArray(res,`m_MarineResources`,i);");
    AppendCode(code, maxlen, "if(r!=null&&NetProps.GetPropInt(r,`m_MarineProfileIndex`)==prof){nr=r;ns=i;}}");
    AppendCode(code, maxlen, "if(nr==null){ClientPrint(p,3,`[中途加入] 加入失败（该职业人数已满、角色被锁定或服务器禁止添加机器人）`);return;}");
    AppendCode(code, maxlen, "if(NetProps.GetPropEntity(nr,`m_Commander`)!=p){");
    AppendCode(code, maxlen, "NetProps.SetPropEntity(nr,`m_Commander`,p);");
    AppendCode(code, maxlen, "NetProps.SetPropEntity(nr,`m_OriginalCommander`,p);");
    AppendCode(code, maxlen, "NetProps.SetPropInt(nr,`DataMap.m_iCommanderIndex`,p.entindex());}");
    // ResurrectMarine 内部走 bResurrection=true，只会按 Initial 槽位发武器
    AppendCode(code, maxlen, "for(local s=0;s<3;s++){");
    // 注意：m_iInitialWeaponsInSlots 的 SendProp 只有 5~6 bit，直接用 SendProp 写
    // 只会改低字节，会把 -1 写成 0xFFFFFF00。这里用 DataMap. 前缀强制走 datamap
    // 的 32 位 int 写入（NetProps 支持该前缀，见 netpropmanager.cpp）。
    // m_iWeaponsInSlots 是 SPROP_UNSIGNED 小位宽，空槽 -1 会被读成 255，需过滤。
    AppendCode(code, maxlen, "local w=NetProps.GetPropIntArray(nr,`m_iWeaponsInSlots`,s);");
    AppendCode(code, maxlen, "if(w>=0&&w<64)NetProps.SetPropIntArray(nr,");
    AppendCode(code, maxlen, "`DataMap.m_iInitialWeaponsInSlots`,w,s);}");
    AppendCode(code, maxlen, "local mar=p.ResurrectMarine(pos,true);");
    AppendCode(code, maxlen, "if(mar==null){");
    AppendCode(code, maxlen, "NetProps.SetPropEntityArray(res,`m_MarineResources`,null,ns);");
    AppendCode(code, maxlen, "NetProps.SetPropInt(res,`m_iNumMarinesSelected`,");
    AppendCode(code, maxlen, "NetProps.GetPropInt(res,`m_iNumMarinesSelected`)-1);");
    AppendCode(code, maxlen, "EntFireByHandle(nr,`Kill`,``,0.0,null,null);");
    AppendCode(code, maxlen, "ClientPrint(p,3,`[中途加入] 生成陆战队员失败`);return;}");
    AppendCode(code, maxlen, "if(p.GetNPC()!=mar)p.SetNPC(mar);");

    if (g_cvDebug.BoolValue)
    {
        PrintToServer("[中途加入] 脚本长度 %d / %d", strlen(code), maxlen);
        PrintToServer("[中途加入] 脚本内容: %s", code);
    }
}

// ============================================================================
//  工具函数
// ============================================================================
int FindGameResource()
{
    return FindEntityByClassname(-1, "asw_game_resource");
}

// 玩家名下是否有任何一个 marine resource（含阵亡的）
bool HasMarineResource(int client)
{
    int res = FindGameResource();
    if (res <= 0)
        return false;

    for (int i = 0; i < MAX_MARINES; i++)
    {
        int mr = GetEntPropEnt(res, Prop_Send, "m_MarineResources", i);
        if (mr > 0 && GetEntPropEnt(mr, Prop_Send, "m_Commander") == client)
            return true;
    }
    return false;
}

// 成功后校验：玩家名下存在指定 profile 的 marine resource
bool HasProfileMarine(int client, int profile)
{
    int res = FindGameResource();
    if (res <= 0)
        return false;

    for (int i = 0; i < MAX_MARINES; i++)
    {
        int mr = GetEntPropEnt(res, Prop_Send, "m_MarineResources", i);
        if (mr <= 0)
            continue;
        if (GetEntProp(mr, Prop_Send, "m_MarineProfileIndex") != profile)
            continue;
        if (GetEntPropEnt(mr, Prop_Send, "m_Commander") == client)
            return true;
    }
    return false;
}

// 角色名解析：数字 1~8 / 完整英文名 / 唯一前缀（大小写不敏感）
int FindProfile(const char[] arg)
{
    if (arg[0] == '\0')
        return -1;

    // 纯数字 1~8
    bool bNumeric = true;
    for (int i = 0; arg[i] != '\0'; i++)
    {
        if (arg[i] < '0' || arg[i] > '9')
        {
            bNumeric = false;
            break;
        }
    }
    if (bNumeric)
    {
        int n = StringToInt(arg);
        if (n >= 1 && n <= MAX_MARINES)
            return n - 1;
        return -1;
    }

    // 完整名称
    for (int i = 0; i < MAX_MARINES; i++)
    {
        if (StrEqual(arg, g_szProfileKey[i], false))
            return i;
    }

    // 唯一前缀（至少 2 个字符，避免 w 同时命中 Wildcat/Wolfe）
    if (strlen(arg) >= 2)
    {
        int found = -1;
        for (int i = 0; i < MAX_MARINES; i++)
        {
            if (StrContains(g_szProfileKey[i], arg, false) == 0)
            {
                if (found >= 0)
                    return -1;   // 多个候选
                found = i;
            }
        }
        if (found >= 0)
            return found;
    }

    return -1;
}

void ShowUsage(int client)
{
    PrintToChat(client, "\x04[中途加入]\x01 用法: add <角色>，例如 add Sarge");
    PrintToChat(client, "\x04[中途加入]\x01 可选角色: Sarge(1) Wildcat(2) Faith(3) Crash(4) Jaeger(5) Wolfe(6) Bastille(7) Vegas(8)");
}

// 本局使用记录（SteamID64 优先；取不到时退回 userid）
bool GetUseKey(int client, char[] key, int maxlen)
{
    if (GetClientAuthId(client, AuthId_SteamID64, key, maxlen))
        return true;

    Format(key, maxlen, "#%d", GetClientUserId(client));
    return false;
}

bool HasUsed(int client)
{
    char key[64];
    GetUseKey(client, key, sizeof(key));

    bool value = false;
    return g_hUsedXuid.GetValue(key, value);
}

void MarkUsed(int client)
{
    char key[64];
    GetUseKey(client, key, sizeof(key));
    g_hUsedXuid.SetValue(key, true);
}