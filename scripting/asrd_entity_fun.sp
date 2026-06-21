/**
 * ============================================================================
 *  Plugin: [AS:RD] Entity Fun - 实体趣味操控
 *
 *  描述: 演示如何对 AS:RD 中的实体进行自定义操控
 *  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  功能:
 *    - sm_sentryhat [target]  — 把机枪塔放到目标玩家头顶
 *    - sm_sentryhat_off       — 取消头顶机枪塔
 *    - sm_stack [target1] [target2] — 把 target1 叠到 target2 头顶
 *    - sm_noclip_marine [target]    — 让目标海洋陆战队员穿墙飞行
 *    - sm_freeze_marine [target]    — 冻结/解冻目标海洋陆战队员
 *    - sm_launch [target]     — 把目标向上弹射
 *    - sm_slam [target]       — 把目标砸向地面
 *
 *  核心技术:
 *    1. TeleportEntity() — 传送实体到指定坐标
 *    2. SetParent — 父子绑定，子实体跟随父实体移动
 *    3. m_CollisionGroup — 修改碰撞组，让实体互相穿透
 *    4. SetEntityMoveType — 修改移动类型（冻结/飞行/穿墙等）
 *    5. OnGameFrame — 每帧追踪更新位置
 *
 *  安装:
 *    将编译后的 .smx 放入 addons/sourcemod/plugins/
 *
 *  依赖:
 *    SourceMod 1.11+
 * ============================================================================
 */

#include <sourcemod>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] Entity Fun"
#define PLUGIN_VERSION "1.0.0"

#define MAX_ENTITIES  2048

// ─── 头顶机枪塔追踪 ─────────────────────────────────────
// sentry ref → marine userid
int g_iSentryHatMarine[MAX_ENTITIES];
// 是否使用父子绑定模式
bool g_bSentryHatParented[MAX_ENTITIES];

// ─── 穿墙模式追踪 ───────────────────────────────────────
bool g_bNoclipMarine[MAXPLAYERS + 1];
MoveType g_iOrigMoveType[MAXPLAYERS + 1];
int g_iOrigCollision[MAXPLAYERS + 1];

// ─── 冻结模式追踪 ───────────────────────────────────────
bool g_bFrozenMarine[MAXPLAYERS + 1];

// ============================================================================
//  插件信息
// ============================================================================
public Plugin myinfo = {
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "AS:RD 实体趣味操控演示",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
//  插件加载
// ============================================================================
public void OnPluginStart()
{
    // 机枪塔头顶
    RegAdminCmd("sm_sentryhat", Command_SentryHat, ADMFLAG_GENERIC, "把最近的机枪塔放到目标玩家头顶. 用法: sm_sentryhat [target]");
    RegAdminCmd("sm_sentryhat_off", Command_SentryHatOff, ADMFLAG_GENERIC, "取消所有头顶机枪塔");

    // 叠人
    RegAdminCmd("sm_stack", Command_Stack, ADMFLAG_GENERIC, "把 target1 叠到 target2 头顶. 用法: sm_stack <target1> <target2>");

    // 穿墙飞行
    RegAdminCmd("sm_noclip_marine", Command_NoclipMarine, ADMFLAG_GENERIC, "让目标海洋陆战队员穿墙飞行. 用法: sm_noclip_marine [target]");

    // 冻结
    RegAdminCmd("sm_freeze_marine", Command_FreezeMarine, ADMFLAG_GENERIC, "冻结/解冻目标海洋陆战队员. 用法: sm_freeze_marine [target]");

    // 弹射/砸地
    RegAdminCmd("sm_launch", Command_Launch, ADMFLAG_GENERIC, "把目标向上弹射. 用法: sm_launch [target]");
    RegAdminCmd("sm_slam", Command_Slam, ADMFLAG_GENERIC, "把目标砸向地面. 用法: sm_slam [target]");

    ResetAllTracking();
}

void ResetAllTracking()
{
    for (int i = 0; i < MAX_ENTITIES; i++)
    {
        g_iSentryHatMarine[i] = 0;
        g_bSentryHatParented[i] = false;
    }
    for (int i = 0; i <= MaxClients; i++)
    {
        g_bNoclipMarine[i] = false;
        g_iOrigMoveType[i] = MOVETYPE_WALK;
        g_iOrigCollision[i] = 0;
        g_bFrozenMarine[i] = false;
    }
}

public void OnMapStart()
{
    ResetAllTracking();
}

public void OnClientDisconnect(int client)
{
    // 清理该玩家的穿墙/冻结状态
    if (g_bNoclipMarine[client])
    {
        g_bNoclipMarine[client] = false;
    }
    g_bFrozenMarine[client] = false;
}

// ============================================================================
//  每帧更新：追踪头顶机枪塔位置
// ============================================================================
public void OnGameFrame()
{
    for (int i = 0; i < MAX_ENTITIES; i++)
    {
        if (g_iSentryHatMarine[i] == 0)
            continue;

        // 如果使用父子绑定模式，不需要手动追踪
        if (g_bSentryHatParented[i])
            continue;

        int iSentry = EntRefToEntIndex(i);
        if (iSentry == INVALID_ENT_REFERENCE || !IsValidEntity(iSentry))
        {
            g_iSentryHatMarine[i] = 0;
            continue;
        }

        int iMarine = GetClientOfUserId(g_iSentryHatMarine[i]);
        if (iMarine <= 0 || !IsClientInGame(iMarine) || !IsPlayerAlive(iMarine))
        {
            g_iSentryHatMarine[i] = 0;
            continue;
        }

        // 获取玩家头部位置
        float fEyePos[3];
        GetClientEyePosition(iMarine, fEyePos);
        fEyePos[2] += 15.0; // 在头顶上方一点

        // 获取玩家视角方向
        float fEyeAngles[3];
        GetClientEyeAngles(iMarine, fEyeAngles);
        fEyeAngles[0] = 0.0; // 不俯仰

        // 传送机枪塔到头顶
        TeleportEntity(iSentry, fEyePos, fEyeAngles, NULL_VECTOR);
    }
}

// ============================================================================
//  命令：把机枪塔放到玩家头顶
// ============================================================================
public Action Command_SentryHat(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "用法: sm_sentryhat <target>");
        return Plugin_Handled;
    }

    // 获取目标玩家
    char sTarget[MAX_NAME_LENGTH];
    GetCmdArg(1, sTarget, sizeof(sTarget));

    int iTarget = FindTarget(client, sTarget, true, false);
    if (iTarget <= 0)
        return Plugin_Handled;

    if (!IsPlayerAlive(iTarget))
    {
        ReplyToCommand(client, "目标玩家已阵亡");
        return Plugin_Handled;
    }

    // 找到最近的机枪塔
    int iSentry = FindNearestSentry(iTarget);
    if (iSentry == -1)
    {
        ReplyToCommand(client, "附近没有找到机枪塔");
        return Plugin_Handled;
    }

    // ─── 方法1: 父子绑定（推荐） ───
    // 让机枪塔成为玩家的子实体，自动跟随移动
    SetSentryParent(iSentry, iTarget);

    // 记录追踪信息
    int ref = EntIndexToEntRef(iSentry);
    if (ref >= 0 && ref < MAX_ENTITIES)
    {
        g_iSentryHatMarine[ref] = GetClientUserId(iTarget);
        g_bSentryHatParented[ref] = true;
    }

    char sName[MAX_NAME_LENGTH];
    GetClientName(iTarget, sName, sizeof(sName));
    ReplyToCommand(client, "已把机枪塔放到 %s 头顶（父子绑定模式）", sName);

    return Plugin_Handled;
}

// ============================================================================
//  命令：取消头顶机枪塔
// ============================================================================
public Action Command_SentryHatOff(int client, int args)
{
    int iCount = 0;

    for (int i = 0; i < MAX_ENTITIES; i++)
    {
        if (g_iSentryHatMarine[i] == 0)
            continue;

        int iSentry = EntRefToEntIndex(i);
        if (iSentry != INVALID_ENT_REFERENCE && IsValidEntity(iSentry))
        {
            // 解除父子绑定
            AcceptEntityInput(iSentry, "SetParent", -1);
            AcceptEntityInput(iSentry, "ClearParent");

            // 恢复正常碰撞
            SetEntProp(iSentry, Prop_Send, "m_CollisionGroup", 0);
        }

        g_iSentryHatMarine[i] = 0;
        g_bSentryHatParented[i] = false;
        iCount++;
    }

    ReplyToCommand(client, "已取消 %d 个头顶机枪塔", iCount);
    return Plugin_Handled;
}

// ============================================================================
//  命令：叠人 — 把 target1 放到 target2 头顶
// ============================================================================
public Action Command_Stack(int client, int args)
{
    if (args < 2)
    {
        ReplyToCommand(client, "用法: sm_stack <target1> <target2>");
        return Plugin_Handled;
    }

    char sTarget1[MAX_NAME_LENGTH], sTarget2[MAX_NAME_LENGTH];
    GetCmdArg(1, sTarget1, sizeof(sTarget1));
    GetCmdArg(2, sTarget2, sizeof(sTarget2));

    int iTarget1 = FindTarget(client, sTarget1, true, false);
    int iTarget2 = FindTarget(client, sTarget2, true, false);

    if (iTarget1 <= 0 || iTarget2 <= 0)
        return Plugin_Handled;

    if (!IsPlayerAlive(iTarget1) || !IsPlayerAlive(iTarget2))
    {
        ReplyToCommand(client, "两个目标都必须存活");
        return Plugin_Handled;
    }

    // 获取 target2 的位置
    float fTarget2Pos[3];
    GetClientAbsOrigin(iTarget2, fTarget2Pos);

    // 在 target2 头顶上方放置 target1
    float fNewPos[3];
    fNewPos = fTarget2Pos;
    fNewPos[2] += 80.0; // 角色高度偏移

    // ─── 关键：修改碰撞组，让角色不互相推开 ───
    // COLLISION_GROUP_DEBRIS (2) 不会与角色碰撞
    SetEntProp(iTarget1, Prop_Send, "m_CollisionGroup", 2);

    // 传送 target1 到 target2 头顶
    TeleportEntity(iTarget1, fNewPos, NULL_VECTOR, NULL_VECTOR);

    char sName1[MAX_NAME_LENGTH], sName2[MAX_NAME_LENGTH];
    GetClientName(iTarget1, sName1, sizeof(sName1));
    GetClientName(iTarget2, sName2, sizeof(sName2));
    ReplyToCommand(client, "已把 %s 叠到 %s 头顶", sName1, sName2);

    return Plugin_Handled;
}

// ============================================================================
//  命令：穿墙飞行
// ============================================================================
public Action Command_NoclipMarine(int client, int args)
{
    int iTarget = client;

    if (args >= 1)
    {
        char sTarget[MAX_NAME_LENGTH];
        GetCmdArg(1, sTarget, sizeof(sTarget));
        iTarget = FindTarget(client, sTarget, true, false);
        if (iTarget <= 0)
            return Plugin_Handled;
    }

    if (g_bNoclipMarine[iTarget])
    {
        // 恢复
        SetEntityMoveType(iTarget, g_iOrigMoveType[iTarget]);
        SetEntProp(iTarget, Prop_Send, "m_CollisionGroup", g_iOrigCollision[iTarget]);
        g_bNoclipMarine[iTarget] = false;

        ReplyToCommand(client, "已取消穿墙模式");
    }
    else
    {
        // 保存原始值
        g_iOrigMoveType[iTarget] = GetEntityMoveType(iTarget);
        g_iOrigCollision[iTarget] = GetEntProp(iTarget, Prop_Send, "m_CollisionGroup");

        // MOVETYPE_NOCLIP = 穿墙飞行
        SetEntityMoveType(iTarget, MOVETYPE_NOCLIP);
        // COLLISION_GROUP_DEBRIS = 不与任何东西碰撞
        SetEntProp(iTarget, Prop_Send, "m_CollisionGroup", 2);
        g_bNoclipMarine[iTarget] = true;

        ReplyToCommand(client, "已启用穿墙飞行模式");
    }

    return Plugin_Handled;
}

// ============================================================================
//  命令：冻结/解冻
// ============================================================================
public Action Command_FreezeMarine(int client, int args)
{
    int iTarget = client;

    if (args >= 1)
    {
        char sTarget[MAX_NAME_LENGTH];
        GetCmdArg(1, sTarget, sizeof(sTarget));
        iTarget = FindTarget(client, sTarget, true, false);
        if (iTarget <= 0)
            return Plugin_Handled;
    }

    if (g_bFrozenMarine[iTarget])
    {
        SetEntityMoveType(iTarget, MOVETYPE_WALK);
        g_bFrozenMarine[iTarget] = false;
        ReplyToCommand(client, "已解冻");
    }
    else
    {
        SetEntityMoveType(iTarget, MOVETYPE_NONE);
        g_bFrozenMarine[iTarget] = true;
        ReplyToCommand(client, "已冻结");
    }

    return Plugin_Handled;
}

// ============================================================================
//  命令：弹射
// ============================================================================
public Action Command_Launch(int client, int args)
{
    int iTarget = client;

    if (args >= 1)
    {
        char sTarget[MAX_NAME_LENGTH];
        GetCmdArg(1, sTarget, sizeof(sTarget));
        iTarget = FindTarget(client, sTarget, true, false);
        if (iTarget <= 0)
            return Plugin_Handled;
    }

    if (!IsPlayerAlive(iTarget))
    {
        ReplyToCommand(client, "目标已阵亡");
        return Plugin_Handled;
    }

    // 设置向上的速度
    float fVelocity[3];
    fVelocity[0] = 0.0;
    fVelocity[1] = 0.0;
    fVelocity[2] = 1500.0; // 向上弹射力度

    TeleportEntity(iTarget, NULL_VECTOR, NULL_VECTOR, fVelocity);

    ReplyToCommand(client, "已弹射目标");
    return Plugin_Handled;
}

// ============================================================================
//  命令：砸向地面
// ============================================================================
public Action Command_Slam(int client, int args)
{
    int iTarget = client;

    if (args >= 1)
    {
        char sTarget[MAX_NAME_LENGTH];
        GetCmdArg(1, sTarget, sizeof(sTarget));
        iTarget = FindTarget(client, sTarget, true, false);
        if (iTarget <= 0)
            return Plugin_Handled;
    }

    if (!IsPlayerAlive(iTarget))
    {
        ReplyToCommand(client, "目标已阵亡");
        return Plugin_Handled;
    }

    float fVelocity[3];
    fVelocity[0] = 0.0;
    fVelocity[1] = 0.0;
    fVelocity[2] = -3000.0; // 向下砸

    TeleportEntity(iTarget, NULL_VECTOR, NULL_VECTOR, fVelocity);

    ReplyToCommand(client, "已砸向地面");
    return Plugin_Handled;
}

// ============================================================================
//  辅助：找最近的机枪塔
// ============================================================================
int FindNearestSentry(int iClient)
{
    float fClientPos[3];
    GetClientAbsOrigin(iClient, fClientPos);

    int iBest = -1;
    float fBestDist = 999999.0;

    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "asw_sentry_base")) != -1)
    {
        float fSentryPos[3];
        GetEntPropVector(entity, Prop_Data, "m_vecOrigin", fSentryPos);

        float fDist = GetVectorDistance(fClientPos, fSentryPos);
        if (fDist < fBestDist)
        {
            fBestDist = fDist;
            iBest = entity;
        }
    }

    // 也搜索其他类型的机枪塔
    char sSentryClasses[][] = {
        "asw_sentry_machine",
        "asw_sentry_flamer",
        "asw_sentry_freeze",
        "asw_sentry_cannon"
    };

    for (int i = 0; i < sizeof(sSentryClasses); i++)
    {
        entity = -1;
        while ((entity = FindEntityByClassname(entity, sSentryClasses[i])) != -1)
        {
            float fSentryPos[3];
            GetEntPropVector(entity, Prop_Data, "m_vecOrigin", fSentryPos);

            float fDist = GetVectorDistance(fClientPos, fSentryPos);
            if (fDist < fBestDist)
            {
                fBestDist = fDist;
                iBest = entity;
            }
        }
    }

    return iBest;
}

// ============================================================================
//  辅助：设置机枪塔的父实体（父子绑定）
// ============================================================================
void SetSentryParent(int iSentry, int iMarine)
{
    // 1. 关闭机枪塔碰撞，防止卡住玩家
    //    COLLISION_GROUP_DEBRIS (2) = 碎片组，不与角色碰撞
    SetEntProp(iSentry, Prop_Send, "m_CollisionGroup", 2);

    // 2. 获取玩家头部位置
    float fEyePos[3];
    GetClientEyePosition(iMarine, fEyePos);
    fEyePos[2] += 15.0;

    float fEyeAngles[3];
    GetClientEyeAngles(iMarine, fEyeAngles);
    fEyeAngles[0] = 0.0;

    // 3. 先传送到头顶位置
    TeleportEntity(iSentry, fEyePos, fEyeAngles, NULL_VECTOR);

    // 4. 设置父实体 — 让机枪塔跟随玩家移动
    //    方法: 通过 SetParent 输入绑定
    char sParentName[64];
    Format(sParentName, sizeof(sParentName), "marine_%d", iMarine);

    // 给玩家实体设置一个目标名
    DispatchKeyValue(iMarine, "targetname", sParentName);

    // 绑定父子关系
    SetVariantString(sParentName);
    AcceptEntityInput(iSentry, "SetParent");

    // 5. 设置偏移量（相对于父实体的位置偏移）
    //    通过 SetParentAttachmentMaintainOffset 保持当前位置偏移
    //    或者用本地偏移
    SetVariantString("0 0 75");  // 偏移量 (forward right up)
    AcceptEntityInput(iSentry, "SetParentOffset");
}
