// ============================================================================
//  [AS:RD] /fh 复活 + /tp 传送到最近队友  (VScript / Squirrel)
//  部署: 替换 <游戏目录>\reactivedrop\scripts\vscripts\mapspawn.nut
//  规则: /fh、/tp 每名玩家每局各一次; 聊天 /test 自检
//  说明: API 与原 mapspawn.nut 保持一致, 不使用 printl 等未确认函数
// ============================================================================

// 仅服务端执行（客户端作用域没有 SendToConsole）
if (!("SendToConsole" in this))
    return;

// 存活 marine 映射（marine_selected 事件维护, 原文件同款机制）
::g_tPlayerMarineList <- {};
// 各命令使用标记; 本文件每局重新执行 => 自动重置
::g_ASRD_FH_Used <- {};
::g_ASRD_TP_Used <- {};
// 加载已广播标记
::g_ASRD_Loaded_Announced <- false;

// 广播一条聊天消息
function Chat(msg)
{
    ClientPrint(null, 3, msg);
}

// 玩家选中陆战队员时记录（存活判断依据）
function OnGameEvent_marine_selected(tEventData)
{
    local hPlayer = GetPlayerFromUserID(tEventData["userid"]);
    local hMarine = EntIndexToHScript(tEventData["new_marine"]);
    if (hPlayer && hMarine && hPlayer.IsValid() && hMarine.IsValid())
        ::g_tPlayerMarineList[hPlayer] <- hMarine;
}

// 玩家完全加入时自动广播一次, 作为"脚本已加载"的可见证明
function OnGameEvent_player_fullyjoined(params)
{
    if (::g_ASRD_Loaded_Announced)
        return;
    ::g_ASRD_Loaded_Announced <- true;
    Chat("[ASRD-fh/tp] 脚本已加载: /fh 复活, /tp 传送, /test 自检");
}

// 玩家是否存活（当前 marine 句柄仍有效）
function IsAlive(hPlayer)
{
    return (hPlayer && hPlayer.IsValid()
        && ::g_tPlayerMarineList.rawin(hPlayer)
        && ::g_tPlayerMarineList[hPlayer]
        && ::g_tPlayerMarineList[hPlayer].IsValid());
}

// 找离 hPlayer 最近的存活队友陆战队员（含人机），没有则返回 null
function FindNearestAlly(hPlayer)
{
    local my = ::g_tPlayerMarineList.rawin(hPlayer) ? ::g_tPlayerMarineList[hPlayer] : null;
    local myPos = (my && my.IsValid()) ? my.GetOrigin() : hPlayer.GetOrigin();

    local best = null;
    local bestD = 1.0e30;

    local m = null;
    while ((m = Entities.FindByClassname(m, "asw_marine")))
    {
        if (!m.IsValid())
            continue;
        if (m == my)               // 排除自己
            continue;
        if (m.GetHealth() <= 0)    // 排除阵亡
            continue;

        local pos = m.GetOrigin();
        local dx = pos.x - myPos.x;
        local dy = pos.y - myPos.y;
        local dz = pos.z - myPos.z;
        local d = dx * dx + dy * dy + dz * dz;
        if (d < bestD)
        {
            bestD = d;
            best = m;
        }
    }
    return best;
}

// /fh：阵亡后复活
function DoFH(hPlayer)
{
    if (IsAlive(hPlayer))
    {
        Chat(hPlayer.GetPlayerName() + "：你仍存活，无需复活");
        return;
    }
    if (hPlayer in ::g_ASRD_FH_Used)
    {
        Chat(hPlayer.GetPlayerName() + "：你本局已复活过，机会已用完");
        return;
    }

    // 复活落点：优先最近队友位置，兜底任意陆战队员
    local target = FindNearestAlly(hPlayer);
    local pos = null;
    if (target != null)
        pos = target.GetOrigin();
    else
    {
        local m = Entities.FindByClassname(null, "asw_marine");
        if (m != null)
            pos = m.GetOrigin();
    }
    if (pos == null)
    {
        Chat(hPlayer.GetPlayerName() + "：找不到可用的复活位置");
        return;
    }

    hPlayer.ResurrectMarine(pos + Vector(40, 40, 0), true);

    ::g_ASRD_FH_Used[hPlayer] <- true;
    Chat(hPlayer.GetPlayerName() + "：已复活（本局复活机会已用完）");
}

// /tp：传送到最近的存活队友旁
function DoTP(hPlayer)
{
    if (!IsAlive(hPlayer))
    {
        Chat(hPlayer.GetPlayerName() + "：你已阵亡，请先输入 /fh 复活");
        return;
    }
    if (hPlayer in ::g_ASRD_TP_Used)
    {
        Chat(hPlayer.GetPlayerName() + "：你本局已传送过，机会已用完");
        return;
    }

    local target = FindNearestAlly(hPlayer);
    if (target == null)
    {
        Chat(hPlayer.GetPlayerName() + "：没有找到其他队友（可能场上只有你一个人）");
        return;
    }

    local my = ::g_tPlayerMarineList[hPlayer];
    my.SetOrigin(target.GetOrigin() + Vector(40, 40, 0));

    ::g_ASRD_TP_Used[hPlayer] <- true;
    Chat(hPlayer.GetPlayerName() + "：已传送到最近队友旁（本局传送机会已用完）");
}

// /test：链路自检
function DoTest(hPlayer)
{
    local n = 0;
    local m = null;
    while ((m = Entities.FindByClassname(m, "asw_marine")))
        if (m.IsValid())
            n++;
    Chat("[自检] 脚本已生效! 场上陆战队员数 = " + n);
}

// 聊天监听：前缀匹配分发（兼容 /xx 与 !xx 及尾部空格）
function OnGameEvent_player_say(params)
{
    if (!("text" in params) || params["text"] == null || !("userid" in params) || params["userid"] == null)
        return;

    local hPlayer = GetPlayerFromUserID(params["userid"]);
    if (!hPlayer || !hPlayer.IsValid())
        return;

    local text = params["text"].tolower();

    if (text.find("/fh") == 0 || text.find("!fh") == 0)
        DoFH(hPlayer);
    else if (text.find("/tp") == 0 || text.find("!tp") == 0)
        DoTP(hPlayer);
    else if (text.find("/test") == 0 || text.find("!test") == 0)
        DoTest(hPlayer);
}