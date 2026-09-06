// ============================================================================
//  [AS:RD] /fh 复活 + /tp 传送 + 管理员 /smfh 复活 + /asft 开关
//  部署: 替换 <游戏目录>\reactivedrop\scripts\vscripts\mapspawn.nut
//  （单文件自包含; 不在运行时 Include 其它脚本, 避免多脚本加载不可靠）
//
//  规则:
//    - /fh 、/tp  每名玩家每局各一次; 本关重新开始(任务重开)时自动重置
//    - /smfh <目标> 仅白名单管理员可用, 不限次数
//    - /asft on|off 管理员开关普通玩家 /fh /tp（持久化到文件, 换图后保持, 管理员不受限）
//    - /fhb <目标> 管理员恶搞复活: 全服大字+红光闪+音效(占位)
//    - /nuke 管理员呼叫战术核弹; /nukepub 公众核弹(需在 nuke.nut 开启 Public)
//  自检:
//    - /test : 显示名单是否读取、你的昵称、你的 XUID(SteamID64)、是否为管理员
//  管理员名单: 在服务器的 rd_admins.nut 里按 SteamID64 维护（GetClientXUID 精确识别）。
// ============================================================================

// 仅服务端执行（客户端作用域没有 SendToConsole）
if (!("SendToConsole" in this))
    return;

// 管理员名单从服务器本地文件 rd_admins.nut 读取（纯数据文件, 存的是 SteamID64）。
// 改名单不用碰本文件; 文件缺失时表现为无管理员而不报错。
try { IncludeScript("rd_admins"); } catch(e) {}

// 载具(jeep)独立模块：定义 ::ASRD_SpawnJeep / ::ASRD_DeleteJeeps（仅管理员可调用，见下方分发）。
try { IncludeScript("jeep"); } catch(e) {}

// 核弹(nuke)独立模块：定义 ::ASRD_NukeStart / ::ASRD_NukeStartPublic / ::ASRD_NukeReset（见下方分发）。
try { IncludeScript("nuke"); } catch(e) {}

// 名单是否成功加载（供 /test 自检用）
::g_ASRD_AdminsLoaded <- ("g_ASRD_AdminSteamIDs" in ::getroottable()) ? 1 : 0;

// 存活 marine 映射（marine_selected 事件维护）
::g_tPlayerMarineList <- {};
// 各命令使用标记; 换图时本文件重新执行 => 自动重置
::g_ASRD_FH_Used <- {};
::g_ASRD_TP_Used <- {};
// 普通玩家 /fh /tp 总开关；用 save/vscripts/asrd_fh_switch.txt 持久化,
// 换图后保持管理员上次设置的 on/off。无该文件时默认关闭。
local _fhSwitchRead = "0";
try {
    local v = FileToString("asrd_fh_switch.txt");
    if (v != null && v != "" && v.tostring().find("1") != null)
        _fhSwitchRead = "1";
} catch(e) {}
::g_ASRD_PlayerCommandsEnabled <- (_fhSwitchRead == "1");
// /fhb 恶搞复活的音效（留空则不播放）。
// 命名要不含 sound/ 前缀、不含扩展名, 全英文小写为佳（中文/特殊符号易失声）。
// 示例: 文件放 sound/rd/fhb.mp3 → 这里填 "rd/fhb"
::g_ASRD_FHB_Sound <- "rd/fhb";

// 裁剪字符串首尾空白（空格/Tab）
function TrimSpace(s)
{
    if (s == null) return "";
    local a = 0, b = s.len();
    while (a < b && (s[a] == 32 || s[a] == 9)) a++;
    while (b > a && (s[b - 1] == 32 || s[b - 1] == 9)) b--;
    return s.slice(a, b);
}

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

// 本关重新开始（失败重开该关 / 进入下一关）时, 重置 /fh /tp 使用次数,
// 这样重开本关后每名玩家又能各用一次, 不必换一张地图。
function OnGameEvent_asw_mission_restart(params)
{
    ::g_ASRD_FH_Used.clear();
    ::g_ASRD_TP_Used.clear();
    if ("ASRD_NukeReset" in ::getroottable())
        ASRD_NukeReset();   // 清理核弹倒计时/冲击波计时器与状态
}

// 玩家是否存活（当前 marine 句柄仍有效）
function IsAlive(hPlayer)
{
    return (hPlayer && hPlayer.IsValid()
        && ::g_tPlayerMarineList.rawin(hPlayer)
        && ::g_tPlayerMarineList[hPlayer]
        && ::g_tPlayerMarineList[hPlayer].IsValid());
}

// 是否为白名单管理员（按 SteamID64 比对, 名单来自服务器文件 rd_admins.nut）
// 用全局函数 GetClientXUID(hPlayer) 取玩家 SteamID64, 精确匹配, 不能冒用。
function IsAdmin(hPlayer)
{
    if (!hPlayer || !hPlayer.IsValid()) return false;
    if (!("g_ASRD_AdminSteamIDs" in ::getroottable())) return false;
    local xuid = GetClientXUID(hPlayer);
    if (xuid == null || xuid == "" || xuid == "0") return false;
    foreach (id in ::g_ASRD_AdminSteamIDs)
        if (xuid == id.tostring()) return true;
    return false;
}

// 找离 hPlayer 最近的存活队友陆战队员（含人机），没有则 null
function FindNearestAlly(hPlayer)
{
    local my = ::g_tPlayerMarineList.rawin(hPlayer) ? ::g_tPlayerMarineList[hPlayer] : null;
    local myPos = (my && my.IsValid()) ? my.GetOrigin() : hPlayer.GetOrigin();

    local best = null, bestD = 1.0e30;
    local m = null;
    while ((m = Entities.FindByClassname(m, "asw_marine")))
    {
        if (!m.IsValid()) continue;
        if (m == my) continue;
        if (m.GetHealth() <= 0) continue;
        local pos = m.GetOrigin();
        local dx = pos.x - myPos.x, dy = pos.y - myPos.y, dz = pos.z - myPos.z;
        local d = dx * dx + dy * dy + dz * dz;
        if (d < bestD) { bestD = d; best = m; }
    }
    return best;
}

// 计算复活落点：优先最近队友位置，兜底任意陆战队员；失败 null
function FindRespawnPos(hPlayer)
{
    local target = FindNearestAlly(hPlayer);
    local pos = null;
    if (target != null) pos = target.GetOrigin();
    else
    {
        local m = Entities.FindByClassname(null, "asw_marine");
        if (m != null) pos = m.GetOrigin();
    }
    if (pos == null) return null;
    return pos + Vector(40, 40, 0);
}

// 在指定位置播复活特效（火花 + 无伤光爆）
function ApplyRespawnEffect(fpos)
{
    local spark = Entities.CreateByClassname("env_spark");
    spark.SetOrigin(fpos + Vector(0, 0, 30));
    spark.__KeyValueFromFloat("MaxDelay", 0.2);
    spark.__KeyValueFromInt("Magnitude", 10);
    spark.__KeyValueFromInt("TrailLength", 3);
    DoEntFire("!self", "SparkOnce", "", 0.0, null, spark);
    DoEntFire("!self", "SparkOnce", "", 0.3, null, spark);
    DoEntFire("!self", "SparkOnce", "", 0.6, null, spark);
    DoEntFire("!self", "Kill", "", 1.5, null, spark);

    local boom = Entities.CreateByClassname("env_explosion");
    boom.SetOrigin(fpos);
    boom.__KeyValueFromInt("iMagnitude", 0);
    boom.__KeyValueFromInt("spawnflags", 31);
    DoEntFire("!self", "Explode", "", 0.0, null, boom);
    DoEntFire("!self", "Kill", "", 1.0, null, boom);
}

// 对玩家执行复活（含落点与特效）
function RespawnPlayer(hPlayer)
{
    local pos = FindRespawnPos(hPlayer);
    if (pos == null) return false;
    hPlayer.ResurrectMarine(pos, true);
    ApplyRespawnEffect(pos);
    return true;
}

// /fh：阵亡后复活（每局一次）
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
    if (RespawnPlayer(hPlayer))
    {
        ::g_ASRD_FH_Used[hPlayer] <- true;
        Chat(hPlayer.GetPlayerName() + "：已复活（本局复活机会已用完）");
    }
    else
    {
        Chat(hPlayer.GetPlayerName() + "：找不到可用的复活位置");
    }
}

// /tp：传送到最近的存活队友旁（每局一次）
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
    local tpPos = target.GetOrigin() + Vector(40, 40, 0);
    my.SetOrigin(tpPos);
    ApplyRespawnEffect(tpPos);   // 与 /fh 相同的复活特效风格
    ::g_ASRD_TP_Used[hPlayer] <- true;
    Chat(hPlayer.GetPlayerName() + "：已传送到最近队友旁（本局传送机会已用完）");
}

// 遍历所有玩家实体, 由回调处理; classname 兼容 "player"/"asw_player", 集合去重
::g_ASRD_SeenPlayer <- {};
function ForEachPlayer(callback)
{
    ::g_ASRD_SeenPlayer.clear();
    foreach (cls in ["player", "asw_player"])
    {
        local h = null;
        while ((h = Entities.FindByClassname(h, cls)))
        {
            if (!h || !h.IsValid()) continue;
            if (::g_ASRD_SeenPlayer.rawin(h)) continue;
            ::g_ASRD_SeenPlayer[h] <- true;
            callback(h);
        }
    }
    ::g_ASRD_SeenPlayer.clear();
}

// 罗列在线玩家（管理员工具）
function ListPlayers(hAdmin)
{
    local out = "[玩家列表] ";
    local first = true;
    ForEachPlayer(function(hPlayer) {
        if (!first) out += " | ";
        first = false;
        out += hPlayer.GetPlayerName();
        if (IsAdmin(hPlayer))
            out += "(管理员)";
    });
    ClientPrint(hAdmin, 3, hAdmin.GetPlayerName() + out);
}

// 解析目标玩家: 数字当作 userid, 否则按名字做不区分大小写的包含匹配
function FindTargetPlayer(text)
{
    if (text == null || text == "") return null;

    local isNum = text.len() > 0;
    for (local i = 0; i < text.len(); i++)
    {
        local ch = text[i];
        if ((ch < 48 || ch > 57) && ch != 45) { isNum = false; break; }
    }
    if (isNum) return GetPlayerFromUserID(text.tointeger());

    local lower = text.tolower();
    local found = null;
    ForEachPlayer(function(hPlayer) {
        if (found != null) return;
        if (hPlayer.GetPlayerName().tolower().find(lower) != null)
            found = hPlayer;
    });
    return found;
}

// 管理员复活: 不限次数, 复活指定目标（阵亡玩家）
function DoAdminResurrect(hAdmin, targetText)
{
    if (targetText == null || targetText == "")
    {
        ClientPrint(hAdmin, 3, hAdmin.GetPlayerName() + "：用法 /smfh <userid 或 玩家名片段>  可用 /players 查看在线玩家");
        return;
    }
    local hTarget = FindTargetPlayer(targetText);
    if (hTarget == null || !hTarget.IsValid())
    {
        ClientPrint(hAdmin, 3, hAdmin.GetPlayerName() + "：未找到玩家 \"" + targetText + "\"");
        return;
    }
    if (IsAlive(hTarget))
    {
        ClientPrint(hAdmin, 3, hAdmin.GetPlayerName() + "：" + hTarget.GetPlayerName() + " 仍存活，无需复活");
        return;
    }
    if (RespawnPlayer(hTarget))
        ClientPrint(hAdmin, 3, "已复活 " + hTarget.GetPlayerName());
    else
        ClientPrint(hAdmin, 3, "找不到可用复活位置");
}

// /asft on|off：控制普通玩家 /fh /tp 是否可用；管理员自己不受限
function DoASFT(hAdmin, arg)
{
    arg = arg.tolower();
    if (arg == "on" || arg == "1" || arg == "enable")
    {
        ::g_ASRD_PlayerCommandsEnabled = true;
        try { StringToFile("asrd_fh_switch.txt", "1"); } catch(e) {}
        ClientPrint(hAdmin, 3, "开启 fh tp");
    }
    else if (arg == "off" || arg == "0" || arg == "disable")
    {
        ::g_ASRD_PlayerCommandsEnabled = false;
        try { StringToFile("asrd_fh_switch.txt", "0"); } catch(e) {}
        ClientPrint(hAdmin, 3, "关闭 fh tp");
    }
    else
    {
        ClientPrint(hAdmin, 3, hAdmin.GetPlayerName() + "：当前普通玩家 /fh /tp = " + (::g_ASRD_PlayerCommandsEnabled ? "开" : "关") + "（用法 /asft on | off）");
    }
}

// 取得某玩家当前的陆战队员句柄（没有则 null）
function GetMarineOf(hPlayer)
{
    if (hPlayer && ::g_tPlayerMarineList.rawin(hPlayer) && ::g_tPlayerMarineList[hPlayer]
        && ::g_tPlayerMarineList[hPlayer].IsValid())
        return ::g_tPlayerMarineList[hPlayer];
    try {
        if (hPlayer && ("GetMarine" in hPlayer)) {
            local m = hPlayer.GetMarine();
            if (m != null && m.IsValid()) return m;
        }
    } catch(e) {}
    return null;
}

// 管理员传送：
//   dir==1: /smtp <目标>  把目标拉到自己身边
//   dir==2: /smtp2 <目标> 传送到目标位置
//   dir==3: /smtp         传送到最近玩家旁（管理员版 /tp）
// 回显仅管理员可见
function DoSMTP(dir, hAdmin, targetText)
{
    local hAdmMarine = GetMarineOf(hAdmin);
    if (hAdmMarine == null || !hAdmMarine.IsValid())
    {
        ClientPrint(hAdmin, 3, hAdmin.GetPlayerName() + "：无法取得你的陆战队员");
        return;
    }

    // dir3: 传送到最近队友旁
    if (dir == 3)
    {
        local ally = FindNearestAlly(hAdmin);
        if (ally == null)
        {
            ClientPrint(hAdmin, 3, hAdmin.GetPlayerName() + "：没有找到其他队友");
            return;
        }
        local pos = ally.GetOrigin() + Vector(40, 40, 0);
        hAdmMarine.SetOrigin(pos);
        ApplyRespawnEffect(pos);
        ClientPrint(hAdmin, 3, hAdmin.GetPlayerName() + "：已传送到最近队友旁");
        return;
    }

    if (targetText == null || targetText == "")
    {
        ClientPrint(hAdmin, 3, (dir == 1 ? "用法 /smtp1 <目标>：把目标拉到你身边" : "用法 /smtp2 <目标>：传送到目标位置"));
        return;
    }
    local hTarget = FindTargetPlayer(targetText);
    if (hTarget == null || !hTarget.IsValid())
    {
        ClientPrint(hAdmin, 3, "未找到玩家 \"" + targetText + "\"");
        return;
    }
    local hTgtMarine = GetMarineOf(hTarget);
    if (hTgtMarine == null || !hTgtMarine.IsValid())
    {
        ClientPrint(hAdmin, 3, hTarget.GetPlayerName() + "：无法取得其陆战队员");
        return;
    }

    if (dir == 1)
    {
        // 把目标拉到自己身边
        local pos = hAdmMarine.GetOrigin() + Vector(40, 40, 0);
        hTgtMarine.SetOrigin(pos);
        ApplyRespawnEffect(pos);
        ClientPrint(hAdmin, 3, "已将 " + hTarget.GetPlayerName() + " 传送到你身边");
    }
    else
    {
        // 传送到目标位置
        local pos = hTgtMarine.GetOrigin() + Vector(40, 40, 0);
        hAdmMarine.SetOrigin(pos);
        ApplyRespawnEffect(pos);
        ClientPrint(hAdmin, 3, "已传送到 " + hTarget.GetPlayerName() + " 位置");
    }
}

// /fhb <目标>：管理员恶搞复活 —— 全服大字 "复活吧我的爱人" + 目标红光闪 + 音效
function DoAdminResurrectFHB(hAdmin, targetText)
{
    if (targetText == null || targetText == "")
    {
        ClientPrint(hAdmin, 3, hAdmin.GetPlayerName() + "：用法 /fhb <userid 或 玩家名片段>");
        return;
    }
    local hTarget = FindTargetPlayer(targetText);
    if (hTarget == null || !hTarget.IsValid())
    {
        ClientPrint(hAdmin, 3, hAdmin.GetPlayerName() + "：未找到玩家 \"" + targetText + "\"");
        return;
    }
    if (IsAlive(hTarget))
    {
        ClientPrint(hAdmin, 3, hAdmin.GetPlayerName() + "：" + hTarget.GetPlayerName() + " 仍存活，无需复活");
        return;
    }
    local name = hTarget.GetPlayerName();
    if (RespawnPlayer(hTarget))
    {
        // 全服屏幕中央大字：管理员名：复活吧我的爱人 目标（红光由 ScreenFade 承担）
        ClientPrint(null, 4, hAdmin.GetPlayerName() + "：复活吧我的爱人 " + name);
        // 对目标玩家屏幕红色闪烁
        try { ScreenFade(hTarget, 255, 0, 0, 180, 0.3, 0.6, 1); } catch(e) {}
        // 音效（占位，填上 g_ASRD_FHB_Sound 后生效）；对全体在线玩家各播一次 => 全服可闻
        if (::g_ASRD_FHB_Sound != "")
        {
            try {
                if ("PrecacheScriptSound" in this.getroottable()) PrecacheScriptSound(::g_ASRD_FHB_Sound);
                if ("PrecacheSound" in this.getroottable()) PrecacheSound("sound/" + ::g_ASRD_FHB_Sound);
                ForEachPlayer(function(p) {
                    if (p.IsValid() && ("EmitSound" in p)) p.EmitSound(::g_ASRD_FHB_Sound);
                });
            } catch(e) {}
        }
        Chat(hAdmin.GetPlayerName() + "：复活吧我的爱人 " + name);
    }
    else
    {
        ClientPrint(hAdmin, 3, hAdmin.GetPlayerName() + "：找不到可用复活位置");
    }
}

// /test：链路自检；显示名单是否加载 + 当前玩家 XUID(SteamID64) 与管理员判定
function DoTest(hPlayer)
{
    local n = 0;
    local m = null;
    while ((m = Entities.FindByClassname(m, "asw_marine")))
        if (m.IsValid()) n++;

    local xuid = "null";
    try {
        local v = GetClientXUID(hPlayer);
        if (v != null && v != "") xuid = v.tostring();
    } catch(e) { xuid = "(异常:" + e + ")"; }

    local msg = "[自检] 陆战队员数 = " + n;
    msg += " | 名单已读 = " + ::g_ASRD_AdminsLoaded;
    msg += " | 你的昵称 = " + hPlayer.GetPlayerName();
    msg += " | XUID = " + xuid;
    msg += " | 管理员 = " + IsAdmin(hPlayer);
    ClientPrint(hPlayer, 3, msg);
}

// 聊天监听：前缀匹配分发（兼容 /xx 与 !xx）
function OnGameEvent_player_say(params)
{
    if (!("text" in params) || params["text"] == null || !("userid" in params) || params["userid"] == null)
        return;

    local hPlayer = GetPlayerFromUserID(params["userid"]);
    if (!hPlayer || !hPlayer.IsValid()) return;

    local trimmed = TrimSpace(params["text"].tolower());

    // 管理员命令
    if (trimmed.find("/smfh") == 0 || trimmed.find("!smfh") == 0)
    {
        if (IsAdmin(hPlayer))
            DoAdminResurrect(hPlayer, TrimSpace(trimmed.slice("/smfh".len())));
        else
            ClientPrint(hPlayer, 3, hPlayer.GetPlayerName() + "：你没有管理员权限");
    }
    else if (trimmed.find("/asft") == 0 || trimmed.find("!asft") == 0)
    {
        if (IsAdmin(hPlayer))
            DoASFT(hPlayer, TrimSpace(trimmed.slice("/asft".len())));
        else
            ClientPrint(hPlayer, 3, hPlayer.GetPlayerName() + "：你没有管理员权限");
    }
    else if (trimmed.find("/fhb") == 0 || trimmed.find("!fhb") == 0)
    {
        if (IsAdmin(hPlayer))
            DoAdminResurrectFHB(hPlayer, TrimSpace(trimmed.slice("/fhb".len())));
        else
            ClientPrint(hPlayer, 3, hPlayer.GetPlayerName() + "：你没有管理员权限");
    }
    else if (trimmed.find("!players") == 0 || trimmed.find("/players") == 0)
    {
        if (IsAdmin(hPlayer))
            ListPlayers(hPlayer);
        else
            ClientPrint(hPlayer, 3, hPlayer.GetPlayerName() + "：你没有管理员权限");
    }
    else if (trimmed.find("/smtp1") == 0 || trimmed.find("!smtp1") == 0)
    {
        if (IsAdmin(hPlayer))
            DoSMTP(1, hPlayer, TrimSpace(trimmed.slice("/smtp1".len())));
        else
            ClientPrint(hPlayer, 3, hPlayer.GetPlayerName() + "：你没有管理员权限");
    }
    else if (trimmed.find("/smtp2") == 0 || trimmed.find("!smtp2") == 0)
    {
        if (IsAdmin(hPlayer))
            DoSMTP(2, hPlayer, TrimSpace(trimmed.slice("/smtp2".len())));
        else
            ClientPrint(hPlayer, 3, hPlayer.GetPlayerName() + "：你没有管理员权限");
    }
    else if (trimmed.find("/smtp") == 0 || trimmed.find("!smtp") == 0)
    {
        if (IsAdmin(hPlayer))
            DoSMTP(3, hPlayer, null);
        else
            ClientPrint(hPlayer, 3, hPlayer.GetPlayerName() + "：你没有管理员权限");
    }
    // 载具命令(仅管理员)：/jk 删除全部; /j /j2 各生成一辆吉普
    else if (trimmed == "/jk" || trimmed == "!jk"
        || trimmed == "/j" || trimmed == "!j"
        || trimmed == "/j2" || trimmed == "!j2")
    {
        if (IsAdmin(hPlayer))
        {
            if (trimmed == "/jk" || trimmed == "!jk")
                ASRD_DeleteJeeps(hPlayer);
            else
                ASRD_SpawnJeep(hPlayer);
        }
        else
            ClientPrint(hPlayer, 3, hPlayer.GetPlayerName() + "：你没有管理员权限");
    }
    // 核弹命令：/nuke 管理员; /nukepub 公众模式(需管理员在 nuke.nut 开启 Public)
    // 注意必须先匹配 /nukepub 再匹配 /nuke, 避免前缀吞掉
    else if (trimmed.find("/nukepub") == 0 || trimmed.find("!nukepub") == 0)
    {
        ASRD_NukeStartPublic(hPlayer);
    }
    else if (trimmed.find("/nuke") == 0 || trimmed.find("!nuke") == 0)
    {
        if (IsAdmin(hPlayer))
            ASRD_NukeStart(hPlayer);
        else
            ClientPrint(hPlayer, 3, hPlayer.GetPlayerName() + "：你没有管理员权限");
    }
    // 玩家命令
    else if (trimmed.find("/fh") == 0 || trimmed.find("!fh") == 0)
    {
        if (!IsAdmin(hPlayer) && !::g_ASRD_PlayerCommandsEnabled)
            Chat(hPlayer.GetPlayerName() + "：普通玩家 /fh 已被管理员关闭");
        else
            DoFH(hPlayer);
    }
    else if (trimmed.find("/tp") == 0 || trimmed.find("!tp") == 0)
    {
        if (!IsAdmin(hPlayer) && !::g_ASRD_PlayerCommandsEnabled)
            Chat(hPlayer.GetPlayerName() + "：普通玩家 /tp 已被管理员关闭");
        else
            DoTP(hPlayer);
    }
    else if (trimmed.find("/test") == 0 || trimmed.find("!test") == 0)
        DoTest(hPlayer);
}