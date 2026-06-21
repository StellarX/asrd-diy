/**
 * ============================================================================
 *  Plugin: [AS:RD] Welcome & Goodbye Messages
 *  
 *  描述: 玩家进入/离开服务器时显示自定义欢迎及告别语
 *  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *  
 *  功能:
 *    - 玩家加入时全服广播欢迎消息
 *    - 玩家离开时全服广播告别消息
 *    - 对加入的玩家本人显示专属欢迎信息
 *    - 支持彩色文字
 *    - 支持自定义消息内容 (CVar)
 *  
 *  安装:
 *    将编译后的 .smx 放入 addons/sourcemod/plugins/
 *  
 *  依赖:
 *    SourceMod 1.11+ (无需额外扩展)
 * ============================================================================
 */

#include <sourcemod>
#include <geoip>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] Welcome Messages"
#define PLUGIN_VERSION "1.0.0"

// ─── CVar 句柄 ──────────────────────────────────────────
ConVar g_cvWelcomeEnabled;
ConVar g_cvWelcomeMsg;
ConVar g_cvGoodbyeMsg;
ConVar g_cvWelcomePersonal;
ConVar g_cvShowCountry;
ConVar g_cvWelcomeSound;

// ============================================================================
//  插件信息
// ============================================================================
public Plugin myinfo = {
    name        = PLUGIN_NAME,
    author      = "OpenClaw",
    description = "玩家进出服务器时显示欢迎/告别消息",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
//  插件加载
// ============================================================================
public void OnPluginStart()
{
    // ─── 注册 CVar ─────────────────────────────────────
    g_cvWelcomeEnabled = CreateConVar(
        "sm_asrd_welcome_enabled", "1",
        "启用/禁用欢迎消息 (0=禁用, 1=启用)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    g_cvWelcomeMsg = CreateConVar(
        "sm_asrd_welcome_msg",
        "欢迎 {player} 加入服务器！当前在线: {count} 人",
        "玩家加入时的全服广播消息\n支持变量: {player}=玩家名, {count}=在线人数",
        FCVAR_NOTIFY
    );

    g_cvGoodbyeMsg = CreateConVar(
        "sm_asrd_goodbye_msg",
        "{player} 离开了服务器，当前在线: {count} 人",
        "玩家离开时的全服广播消息\n支持变量: {player}=玩家名, {count}=在线人数",
        FCVAR_NOTIFY
    );

    g_cvWelcomePersonal = CreateConVar(
        "sm_asrd_welcome_personal", "1",
        "是否向加入的玩家本人发送专属欢迎信息 (0=禁用, 1=启用)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    g_cvShowCountry = CreateConVar(
        "sm_asrd_show_country", "0",
        "是否显示玩家所在国家/地区 (需要 GeoIP 扩展, 0=禁用, 1=启用)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    g_cvWelcomeSound = CreateConVar(
        "sm_asrd_welcome_sound", "",
        "玩家加入时播放的音效文件路径 (留空则不播放)\n示例: ui/menu_enter.wav",
        FCVAR_NOTIFY
    );

    // 自动生成配置文件
    AutoExecConfig(true, "asrd_welcome");

    // 加载翻译文件 (可选)
    LoadTranslations("common.phrases");
}

// ============================================================================
//  玩家进入服务器
// ============================================================================

/**
 * 当玩家完全进入服务器时触发
 * 此时玩家已经加载完毕，可以正常接收消息
 */
public void OnClientPutInServer(int client)
{
    // 延迟发送，确保玩家客户端已准备好接收消息
    CreateTimer(1.0, Timer_WelcomePlayer, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

/**
 * 延迟欢迎定时器回调
 */
public Action Timer_WelcomePlayer(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);

    // 如果玩家在此期间断开了连接，直接返回
    if (client <= 0 || !IsClientInGame(client))
        return Plugin_Stop;

    // 检查是否启用
    if (!g_cvWelcomeEnabled.BoolValue)
        return Plugin_Stop;

    // 跳过 Bot
    if (IsFakeClient(client))
        return Plugin_Stop;

    // ─── 获取玩家信息 ─────────────────────────────────
    char sName[MAX_NAME_LENGTH];
    GetClientName(client, sName, sizeof(sName));

    // 获取当前在线人数 (排除 Bot)
    int iPlayerCount = GetRealPlayerCount();

    // ─── 获取国家信息 (可选) ──────────────────────────
    char sCountry[64] = "";
    if (g_cvShowCountry.BoolValue)
    {
        char sIP[32];
        GetClientIP(client, sIP, sizeof(sIP));

        if (LibraryExists("geoip"))
        {
            char sCode[3];
            GeoipCode2(sIP, sCode);
            strcopy(sCountry, sizeof(sCountry), sCode);
        }
    }


    // ─── 全服广播欢迎消息 ─────────────────────────────
    char sWelcomeMsg[256];
    g_cvWelcomeMsg.GetString(sWelcomeMsg, sizeof(sWelcomeMsg));

    char sFormatted[512];
    FormatMessage(sFormatted, sizeof(sFormatted), sWelcomeMsg, sName, iPlayerCount, sCountry);

    // 带颜色的全服广播
    // \x04 = 绿色 (团队色), \x03 = 队伍色 (一般玩家名), \x01 = 默认色
    PrintToChatAll(
        "\x04[欢迎]\x01 %s",
        sFormatted
    );

    // ─── 专属欢迎信息 ─────────────────────────────────
    if (g_cvWelcomePersonal.BoolValue)
    {
        PrintToChat(client,
            "\x04[Alien Swarm: Reactive Drop]\x01 欢迎 \x03%s\x01 来到服务器！",
            sName
        );

        // 屏幕中央欢迎
        PrintCenterText(client, "欢迎, %s！", sName);

        // 服务器信息面板 (显示在聊天框上方的 Hint 区域)
        PrintHintText(client,
            "欢迎 %s 来到本服\n在线玩家: %d 人\n祝游戏愉快！",
            sName, iPlayerCount
        );
    }

    // ─── 播放加入音效 ─────────────────────────────────
    char sSound[PLATFORM_MAX_PATH];
    g_cvWelcomeSound.GetString(sSound, sizeof(sSound));
    if (sSound[0] != '\0')
    {
        // 对所有玩家播放音效
        for (int i = 1; i <= MaxClients; i++)
        {
            if (IsClientInGame(i) && !IsFakeClient(i))
            {
                ClientCommand(i, "play %s", sSound);
            }
        }
    }

    // ─── 记录日志 ─────────────────────────────────────
    LogMessage("\"%s\" joined the server (%d players online)", sName, iPlayerCount);

    return Plugin_Stop;
}

// ============================================================================
//  玩家离开服务器
// ============================================================================

/**
 * 当玩家断开连接时触发
 */
public void OnClientDisconnect(int client)
{
    // 检查是否启用
    if (!g_cvWelcomeEnabled.BoolValue)
        return;

    // 跳过 Bot
    if (IsFakeClient(client))
        return;

    // 获取玩家名称 (在断开连接后仍可获取)
    char sName[MAX_NAME_LENGTH];
    GetClientName(client, sName, sizeof(sName));

    // 获取剩余在线人数
    int iPlayerCount = GetRealPlayerCount() - 1; // 要减1，因为当前玩家还在计数中
    if (iPlayerCount < 0)
        iPlayerCount = 0;

    // ─── 获取离开原因 ─────────────────────────────────
    char sReason[64];
    GetDisconnectReason(client, sReason, sizeof(sReason));

    // ─── 广播告别消息 ─────────────────────────────────
    char sGoodbyeMsg[256];
    g_cvGoodbyeMsg.GetString(sGoodbyeMsg, sizeof(sGoodbyeMsg));

    char sFormatted[512];
    FormatMessage(sFormatted, sizeof(sFormatted), sGoodbyeMsg, sName, iPlayerCount, "");

    PrintToChatAll(
        "\x04[告别]\x01 %s",
        sFormatted
    );

    // ─── 记录日志 ─────────────────────────────────────
    LogMessage("\"%s\" left the server (reason: %s, %d players remaining)",
        sName, sReason, iPlayerCount);
}

// ============================================================================
//  辅助函数
// ============================================================================

/**
 * 格式化消息，替换变量占位符
 * 
 * @param buffer      输出缓冲区
 * @param maxlen      缓冲区最大长度
 * @param format      格式字符串
 * @param playerName  玩家名称 ({player})
 * @param count       在线人数 ({count})
 * @param extra       额外信息 ({country})
 */
stock void FormatMessage(char[] buffer, int maxlen,
    const char[] format,
    const char[] playerName, int count, const char[] extra)
{
    strcopy(buffer, maxlen, format);

    // 替换 {player} → 带颜色的玩家名
    ReplaceString(buffer, maxlen, "{player}", playerName);

    // 替换 {count} → 在线人数
    char sCount[16];
    IntToString(count, sCount, sizeof(sCount));
    ReplaceString(buffer, maxlen, "{count}", sCount);

    // 替换 {country} → 国家/地区
    if (extra[0] != '\0')
        ReplaceString(buffer, maxlen, "{country}", extra);
    else
        ReplaceString(buffer, maxlen, " ({country})", "");
}

/**
 * 获取真实玩家数量 (排除 Bot 和 SourceTV)
 * 
 * @return 真实玩家数
 */
stock int GetRealPlayerCount()
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            count++;
        }
    }
    return count;
}

/**
 * 获取玩家断开连接的原因 (人类可读)
 */
stock void GetDisconnectReason(int client, char[] buffer, int maxlen)
{
    // OnClientDisconnect 无法直接获取断开原因字符串
    // 这里使用简单判断
    if (IsClientInKickQueue(client))
    {
        strcopy(buffer, maxlen, "被踢出");
    }
    else
    {
        strcopy(buffer, maxlen, "正常离开");
    }
}
