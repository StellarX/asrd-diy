// ============================================================================
//  [AS:RD] /fh 复活 + /tp 传送 + 管理员 /smfh 复活 + /asft 开关
//  部署: 替换 <游戏目录>\reactivedrop\scripts\vscripts\mapspawn.nut
//  （单文件自包含; 不在运行时 Include 其它脚本, 避免多脚本加载不可靠）
//
//  规则:
//    - /fh 、/tp  每名玩家每局各一次; 本关重新开始(任务重开)时自动重置
//    - /tp 只传送到最近的"存活且未倒地"队友旁（倒地可被扶起的状态不算有效目标）
//    - /smfh <目标> 仅白名单管理员可用, 不限次数
//    - /asft on|off 管理员开关普通玩家 /fh /tp（持久化到文件, 换图后保持, 管理员不受限）
//    - /fhb <目标> 管理员恶搞复活: 全服大字+红光闪+音效(占位)
//    - /joi <角色简称> 中途加入: 中途连入的观战玩家现场新建一名指定角色的陆战队员参战
//      （简称按英文名前缀匹配, 如 jag -> Jaeger）
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

// 油桶变身(barrel)独立模块：定义 ::ASRD_BarrelTransform / ::ASRD_BarrelRevert / ::ASRD_BarrelThrow
// （管理员 /smbarrel 聊天命令 + SM 控制台指令共用；蹲下键检测由 SM 插件 asrd_barrel.smx 完成）
try { IncludeScript("barrel"); } catch(e) {}

// 名单是否成功加载（供 /test 自检用）
::g_ASRD_AdminsLoaded <- ("g_ASRD_AdminSteamIDs" in ::getroottable()) ? 1 : 0;

// 存活 marine 映射（marine_selected 事件维护）
::g_tPlayerMarineList <- {};
// 各命令使用标记; 换图时本文件重新执行 => 自动重置
::g_ASRD_FH_Used <- {};
::g_ASRD_TP_Used <- {};
// 倒地兜底表（仅当 NetProps 取不到 m_bKnockedOut 时才用, 由 marine_incapacitated / marine_revived 事件维护）
::g_ASRD_DownedFallback <- {};
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

// 预缓存 /fh 运输船复活用的模型（还原"自爆"挑战 /r 流程）
try {
    local _pm = Entities.CreateByClassname("info_target");
    _pm.PrecacheModel("models/props/vehicles/dropship/dropship.mdl");
    DoEntFire("!self", "Kill", "", 0, null, _pm);
} catch(e) {}

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

// 已加入对局（至少选中过一次陆战队员）的玩家标记。
// 未加入对局的纯观战者没有该标记，无法使用玩家/载具指令。
::g_ASRD_Joined <- {};

// 玩家选中陆战队员时记录（存活判断依据）
function OnGameEvent_marine_selected(tEventData)
{
    local hPlayer = GetPlayerFromUserID(tEventData["userid"]);
    local hMarine = EntIndexToHScript(tEventData["new_marine"]);
    if (hPlayer && hMarine && hPlayer.IsValid() && hMarine.IsValid())
    {
        ::g_tPlayerMarineList[hPlayer] <- hMarine;
        ::g_ASRD_Joined[hPlayer] <- true;   // 标记已加入对局
    }
}

// 玩家是否已加入对局（曾选中陆战队员；阵亡等待复活仍视为已加入, 才能用 /fh）
function HasJoinedMatch(hPlayer)
{
    return (hPlayer && hPlayer.IsValid() && ::g_ASRD_Joined.rawin(hPlayer));
}

// 陆战队员被击倒（倒地）时记录: 事件 marine_incapacitated { entindex }
// 倒地时游戏会把血量设成 最大血量-10（仍 > 0）, 所以不能只靠血量判断
function OnGameEvent_marine_incapacitated(tEventData)
{
    // 保留事件钩子：仅在 NetProps 不可用的极端情况下作兜底记录
    local hMarine = EntIndexToHScript(tEventData["entindex"]);
    if (hMarine != null && hMarine.IsValid())
        ::g_ASRD_DownedFallback[hMarine] <- true;
}

// 陆战队员被队友扶起时清除标记: 事件 marine_revived { entindex, reviver }
function OnGameEvent_marine_revived(tEventData)
{
    local hMarine = EntIndexToHScript(tEventData["entindex"]);
    if (hMarine != null && hMarine.IsValid() && ::g_ASRD_DownedFallback.rawin(hMarine))
        ::g_ASRD_DownedFallback.rawdelete(hMarine);
}

// 本关重新开始（失败重开该关 / 进入下一关）时, 重置 /fh /tp 使用次数,
// 这样重开本关后每名玩家又能各用一次, 不必换一张地图。
function OnGameEvent_asw_mission_restart(params)
{
    ::g_ASRD_FH_Used.clear();
    ::g_ASRD_TP_Used.clear();
    ::g_ASRD_DownedFallback.clear();
}

// 玩家是否存活（当前 marine 句柄仍有效）
function IsAlive(hPlayer)
{
    return (hPlayer && hPlayer.IsValid()
        && ::g_tPlayerMarineList.rawin(hPlayer)
        && ::g_tPlayerMarineList[hPlayer]
        && ::g_tPlayerMarineList[hPlayer].IsValid());
}

// 该陆战队员是否处于"倒地"状态（被击倒但没死, 可以被队友扶起, 不能作为传送目标）。
// 倒地时游戏执行 SetHealth(最大血量-10) 且血量仍 > 0, 所以不能只凭血量判断;
// 真正的标志是 asw_marine 的网络字段 m_bKnockedOut（SendPropBool）。
// 用 VScript 内置的 NetProps 单例直接读网络字段, 取不到(-1)时退回事件表。
function IsDowned(hMarine)
{
    if (hMarine == null || !hMarine.IsValid()) return false;
    if ("NetProps" in ::getroottable())
    {
        local v = NetProps.GetPropInt(hMarine, "m_bKnockedOut");
        if (v >= 0) return (v != 0);
    }
    return ::g_ASRD_DownedFallback.rawin(hMarine);
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

// 找离 hPlayer 最近的存活且未倒地的队友陆战队员（含人机），没有则 null
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
        // 倒地(被击倒但未死, 可被队友扶起)的队友不作为传送目标
        if (IsDowned(m)) continue;
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

// 对玩家执行复活（含落点与特效；bEffect=false 时不播特效，供 /fh 使用）
function RespawnPlayer(hPlayer, bEffect = true)
{
    local pos = FindRespawnPos(hPlayer);
    if (pos == null) return false;
    hPlayer.ResurrectMarine(pos, true);
    if (bEffect) ApplyRespawnEffect(pos);
    // 复活后清掉兜底表里可能残留的倒地标记
    // （倒地者被致命伤直接杀死时游戏只调 SetKnockedOut(false), 不会触发 marine_revived 事件）
    if (hPlayer && ::g_tPlayerMarineList.rawin(hPlayer))
    {
        local hMarine = ::g_tPlayerMarineList[hPlayer];
        if (hMarine != null && ::g_ASRD_DownedFallback.rawin(hMarine))
            ::g_ASRD_DownedFallback.rawdelete(hMarine);
    }
    return true;
}

// /fh：阵亡后复活。普通玩家每局一次；管理员无限次。
// 还原"自爆"挑战 /r 流程：呼叫运输船 → 运输船降落动画 → 在船下复活。
function DoFH(hPlayer)
{
    if (IsAlive(hPlayer))
    {
        Chat(hPlayer.GetPlayerName() + "：仍处于存活状态，无需复活");
        return;
    }
    local isAdmin = IsAdmin(hPlayer);
    if (!isAdmin && (hPlayer in ::g_ASRD_FH_Used))
    {
        Chat(hPlayer.GetPlayerName() + "：本局复活机会已用完");
        return;
    }
    if (RespawnWithDropship(hPlayer))
    {
        if (!isAdmin) ::g_ASRD_FH_Used[hPlayer] <- true;
        Chat(hPlayer.GetPlayerName() + "：已呼叫运输船");
    }
    else
    {
        Chat(hPlayer.GetPlayerName() + "：找不到可用的复活位置");
    }
}

// 用运输船复活（还原"自爆"挑战 /r 的运输船流程）
// 在任一存活陆战队员头顶 270 生成 dropship 播放 deima_dropDown 降落动画，
// 玩家在运输船位置复活；3.4 秒后运输船自动消失。
// 若场上没有存活陆战队员作参照，则退化为普通复活。
function RespawnWithDropship(hPlayer)
{
    if (!hPlayer || !hPlayer.IsValid()) return false;

    local anchor = null;
    local m = null;
    while ((m = Entities.FindByClassname(m, "asw_marine")) != null)
    {
        if (m.IsValid() && m.GetHealth() > 0)
        {
            anchor = m;
            break;
        }
    }

    // 复活落点：优先存活陆战队员头顶 +270（船位），全队阵亡则退回普通落点
    local pos;
    if (anchor != null)
        pos = anchor.GetOrigin() + anchor.GetForwardVector() * 1 + Vector(0, 0, 270);
    else
    {
        pos = FindRespawnPos(hPlayer);
        if (pos == null) return false;
    }

    ClientPrint(null, 3, "正在呼叫运输船");

    // 立即复活（同步状态最干净，失败可直接感知；延迟到 timer 回调复活在部分
    // 状态下会因资源/指挥官关系变化而静默失败）
    local revived = hPlayer.ResurrectMarine(pos, true);
    if (revived == null)
    {
        ClientPrint(null, 3, "复活失败：当前游戏状态无法复活，请稍后再试");
        return false;
    }

    // 玩家已在船位 → 生成运输船降落动画（纯视觉，3.4 秒后自动消失）
    local ship = Entities.CreateByClassname("prop_dynamic");
    if (ship != null)
    {
        ship.__KeyValueFromString("model", "models/props/vehicles/dropship/dropship.mdl");
        ship.__KeyValueFromFloat("modelscale", 0.4);
        ship.SetOrigin(pos);
        ship.SetAnglesVector(anchor != null ? anchor.GetAngles() : Vector(0, 0, 0));
        DoEntFire("!self", "SetDefaultAnimation", "deima_dropDown", 0, ship, ship);
        DoEntFire("!self", "SetAnimation", "deima_dropDown", 0, ship, ship);
        ship.Spawn();
        ship.Activate();
        DoEntFire("!self", "Kill", "", 3.4, null, ship);
    }
    ClientPrint(null, 3, "！！注意！！，运输船已抵达");
    return true;
}

// ---------------------------------------------------------------------------
// /smfh：还原通信中心"飞船跳下 + 喷气背包"
// 1) 生成 dropship 降落动画（存活锚点头顶 +270）
// 2) 玩家在船位复活，自动喷气滑翔 0.8 秒落到地面
// 3) 落地时播放合并特效（原火花/光爆 + 自爆挑战爆炸粒子/白闪/震动/音效）
// 若场上没有存活陆战队员作锚点，退化为普通复活（带特效）。
// ---------------------------------------------------------------------------
function RespawnWithDropshipJet(hPlayer)
{
    if (!hPlayer || !hPlayer.IsValid()) return false;

    local anchor = null;
    local m = null;
    while ((m = Entities.FindByClassname(m, "asw_marine")) != null)
    {
        if (m.IsValid() && m.GetHealth() > 0) { anchor = m; break; }
    }

    // 船位 = 锚点头顶 +800（还原通信中心飞船高空悬停）；全队阵亡则退回普通落点
    local startPos, landPos;
    if (anchor != null)
    {
        startPos = anchor.GetOrigin() + anchor.GetForwardVector() * 1 + Vector(0, 0, 800);
        landPos  = anchor.GetOrigin();
    }
    else
    {
        landPos = FindRespawnPos(hPlayer);
        if (landPos == null) return false;
        startPos = landPos + Vector(0, 0, 800);
    }

    // 全服公告：指挥部正在为 XX 呼叫运输船
    ClientPrint(null, 3, "指挥部正在为 " + hPlayer.GetPlayerName() + " 呼叫运输船");

    // dropship 降落动画（纯视觉，3.4 秒后自动消失）
    local ship = Entities.CreateByClassname("prop_dynamic");
    if (ship != null)
    {
        ship.__KeyValueFromString("model", "models/props/vehicles/dropship/dropship.mdl");
        ship.__KeyValueFromFloat("modelscale", 0.4);
        ship.SetOrigin(startPos);
        ship.SetAnglesVector(anchor != null ? anchor.GetAngles() : Vector(0, 0, 0));
        DoEntFire("!self", "SetDefaultAnimation", "deima_dropDown", 0, ship, ship);
        DoEntFire("!self", "SetAnimation", "deima_dropDown", 0, ship, ship);
        ship.Spawn();
        ship.Activate();
        DoEntFire("!self", "Kill", "", 3.4, null, ship);
    }

    // 船位复活（立即执行，失败可直接感知）
    local revived = hPlayer.ResurrectMarine(startPos, true);
    if (revived == null)
    {
        ClientPrint(null, 3, "复活失败：当前游戏状态无法复活，请稍后再试");
        return false;
    }

    // 喷气跳伞：引擎驱动 jump jet 动画（不 GiveWeapon，避免替换玩家原有装备）
    if (revived != null && revived.IsValid())
        StartJetGlide(revived, startPos, landPos, hPlayer);
    return true;
}

// 喷气跳伞：创建 trigger_rd_marine_jumpjet 触发引擎 jump jet 动画（陆战队员
// 摆出喷气姿态飞向落点，由 melee 系统驱动），同时用 logic_timer 监控：
//  - 引擎动画接管（位置明显下降）→ 只等落地，落地播合并特效
//  - 引擎动画未接管（trigger 未触发）→ 兜底平滑下放，同样落地播特效
// 全程不发放 jump jet 武器，玩家原有装备不被替换。
function StartJetGlide(marine, startPos, landPos, hPlayer)
{
    // 落点目标实体（trigger 的 Destination1 指向它）
    if (!("g_ASRD_SMFH_Seq" in ::getroottable())) ::g_ASRD_SMFH_Seq <- 0;
    ::g_ASRD_SMFH_Seq++;
    local destName = "asrd_smfh_land_" + ::g_ASRD_SMFH_Seq;

    local dest = Entities.CreateByClassname("info_target");
    if (dest != null)
    {
        dest.SetOrigin(landPos);
        dest.__KeyValueFromString("targetname", destName);
        dest.Spawn();
        DoEntFire("!self", "Kill", "", 6.0, null, dest);
    }

    // 触发实体：放在复活点（marine 生成即与它重叠 → 触发 jump jet 动画）
    local trig = Entities.CreateByClassname("trigger_rd_marine_jumpjet");
    if (trig != null)
    {
        trig.__KeyValueFromString("Destination1", destName);
        trig.__KeyValueFromInt("JumpType", 0);
        trig.__KeyValueFromFloat("JumpTimeOverride", 1.4);   // 800 高度稍慢更自然
        trig.SetOrigin(startPos);
        trig.Spawn();
        trig.Activate();
        trig.SetSize(Vector(-140, -140, -180), Vector(140, 140, 80));
        DoEntFire("!self", "Kill", "", 4.5, null, trig);
    }

    // 监控/兜底定时器
    local timer = Entities.CreateByClassname("logic_timer");
    if (timer == null)
    {
        ApplyLandingFX(landPos, hPlayer);
        return;
    }
    timer.__KeyValueFromFloat("RefireTime", 0.05);
    DoEntFire("!self", "Disable", "", 0, null, timer);
    timer.ValidateScriptScope();
    local ts = timer.GetScriptScope();
    ts.marine  <- marine;
    ts.hPlayer <- hPlayer;
    ts.start   <- startPos;
    ts.land    <- landPos;
    ts.startTime <- Time();
    ts.fallback  <- false;      // 引擎动画未接管时启用兜底下放
    ts.fallTime  <- 0.0;
    ts.timerEnt  <- timer;      // 供回调 Kill 自身
    // 注意：ConnectOutput 触发的回调不保留闭包变量，必须用 self（= 实体脚本作用域表 = ts）访问数据
    ts.Check <- function()
    {
        local d = self;         // 实体脚本作用域表
        if (!d.marine.IsValid())
        {
            DoEntFire("!self", "Kill", "", 0, null, d.timerEnt);
            return;
        }
        local pos = d.marine.GetOrigin();
        local t = Time() - d.startTime;

        // 1.0 秒时位置仍未明显下降 → 判定引擎动画未接管，启用兜底
        if (!d.fallback && t >= 1.0)
        {
            if (d.start.z - pos.z < 50)
            {
                d.fallback = true;
                d.fallTime = Time();
                try { d.marine.EmitSound("ASW_JumpJet.Activate"); } catch(e) {}
            }
        }

        if (d.fallback)
        {
            // 平滑下放（1.0 秒到位，Z 带喷气弧线）
            local t2 = (Time() - d.fallTime) / 1.0;
            if (t2 >= 1.0)
            {
                d.marine.SetOrigin(d.land);
                DoEntFire("!self", "Kill", "", 0, null, d.timerEnt);
                ClientPrint(null, 3, "运输船已抵达");
                ApplyLandingFX(d.land, d.hPlayer);
                return;
            }
            local v = d.start + (d.land - d.start) * t2;
            v.z += sin(t2 * M_PI) * 60.0;
            d.marine.SetOrigin(v);
            return;
        }

        // 引擎动画驱动：等落地
        if (pos.z <= d.land.z + 40)
        {
            d.marine.SetOrigin(d.land);
            DoEntFire("!self", "Kill", "", 0, null, d.timerEnt);
            ClientPrint(null, 3, "运输船已抵达");
            ApplyLandingFX(d.land, d.hPlayer);
            return;
        }
        // 异常兜底：超时强制落地
        if (t >= 4.0)
        {
            d.marine.SetOrigin(d.land);
            DoEntFire("!self", "Kill", "", 0, null, d.timerEnt);
            ApplyLandingFX(d.land, d.hPlayer);
            return;
        }
    };
    timer.ConnectOutput("OnTimer", "Check");
    DoEntFire("!self", "Enable", "", 0.2, null, timer);
    DoEntFire("!self", "Kill", "", 5.5, null, timer);
}

// 落地合并特效：原火花/光爆（ApplyRespawnEffect）+ 自爆挑战爆炸特效
function ApplyLandingFX(fpos, hPlayer)
{
    if (fpos == null) return;

    // 咱自己的：火花 + 光爆
    ApplyRespawnEffect(fpos);

    // 新特效：自爆挑战爆炸粒子（还原 challenge_expose_oneself_1_1.nut 死亡特效）
    CreateParticleFunc(2.5, fpos + Vector(0, 0, 30), Vector(0, 0, 0), "portal_rift_flash_01b");
    CreateParticleFunc(2.5, fpos + Vector(0, 0, 30), Vector(0, 0, 0), "citadel_shockwave");
    CreateParticleFunc(2.5, fpos + Vector(0, 0, 30), Vector(0, 0, 0), "portal_rift_02e");
    CreateParticleFunc(2.5, fpos, Vector(0, 0, 0), "VindGrenade");
    CreateParticleFunc(2.5, fpos, Vector(0, 0, 0), "HugeExplosion");
    CreateParticleFunc(2.5, fpos, Vector(0, 0, 0), "explosion_huge");
    CreateParticleFunc(2.5, fpos, Vector(0, 0, 0), "citadel_shockwave__");
    CreateParticleFunc(2.5, fpos + Vector(0, 0, 800), Vector(0, 0, 0), "portal_rift_01");

    // 新特效：爆炸音效（用临时实体在落点播放）
    local sndEnt = Entities.CreateByClassname("info_target");
    if (sndEnt != null)
    {
        sndEnt.SetOrigin(fpos);
        sndEnt.Spawn();
        try { sndEnt.EmitSound("explode_1"); } catch(e) {}
        try { sndEnt.EmitSound("explode_2"); } catch(e) {}
        try { sndEnt.EmitSound("explode_4"); } catch(e) {}
        try { sndEnt.EmitSound("explode_5"); } catch(e) {}
        try { sndEnt.EmitSound("explode_9"); } catch(e) {}
        try { sndEnt.EmitSound("explosions/timor/warhead.wav"); } catch(e) {}
        try { sndEnt.EmitSound("explosions/timor/warheadlf.wav"); } catch(e) {}
        DoEntFire("!self", "Kill", "", 1.0, null, sndEnt);
    }

    // 新特效：屏幕震动 + 白闪
    try { ScreenShake(fpos, 500.0, 500.0, 3, 3000.0, 1, true); } catch(e) {}
    if (hPlayer != null && hPlayer.IsValid())
    {
        try { ScreenFade(hPlayer, 255, 250, 255, 160, 4, 0.6, 1); } catch(e) {}
    }
}

// 生成一次性粒子系统（还原挑战 CreateParticleFunc）
function CreateParticleFunc(flAliveTime, VecOrigin, VecAngles, strParticleClass)
{
    local hParticle = Entities.CreateByClassname("info_particle_system");
    if (hParticle == null) return;
    hParticle.__KeyValueFromString("effect_name", strParticleClass);
    hParticle.__KeyValueFromString("start_active", "1");
    hParticle.SetOrigin(VecOrigin);
    hParticle.SetAnglesVector(VecAngles);
    hParticle.Spawn();
    hParticle.Activate();
    DoEntFire("!self", "Kill", "", flAliveTime, null, hParticle);
}

// /tp：传送到最近的"存活且未倒地"队友旁。普通玩家每局一次；管理员无限次。
function DoTP(hPlayer)
{
    if (!IsAlive(hPlayer))
    {
        Chat(hPlayer.GetPlayerName() + "：当前状态不可传送，请先输入 /fh 复活");
        return;
    }
    local isAdmin = IsAdmin(hPlayer);
    if (!isAdmin && (hPlayer in ::g_ASRD_TP_Used))
    {
        Chat(hPlayer.GetPlayerName() + "：本局传送机会已用完");
        return;
    }
    local target = FindNearestAlly(hPlayer);
    if (target == null)
    {
        Chat(hPlayer.GetPlayerName() + "：没有可传送的队友（可能只有你一人，或队友都已倒地/阵亡）");
        return;
    }
    local my = ::g_tPlayerMarineList[hPlayer];
    local tpPos = target.GetOrigin() + Vector(40, 40, 0);
    my.SetOrigin(tpPos);
    ApplyRespawnEffect(tpPos);   // 与 /fh 相同的复活特效风格
    if (!isAdmin) ::g_ASRD_TP_Used[hPlayer] <- true;
    Chat(hPlayer.GetPlayerName() + "：已传送到最近队友旁");
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
    if (RespawnWithDropshipJet(hTarget))
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
//   dir==1: /tp1 <目标>  把目标拉到自己身边
//   dir==2: /tp2 <目标> 传送到目标位置
// 回显仅本人可见
function DoSMTP(dir, hAdmin, targetText)
{
    local hAdmMarine = GetMarineOf(hAdmin);
    if (hAdmMarine == null || !hAdmMarine.IsValid())
    {
        ClientPrint(hAdmin, 3, hAdmin.GetPlayerName() + "：无法取得你的陆战队员");
        return;
    }

    if (targetText == null || targetText == "")
    {
        ClientPrint(hAdmin, 3, (dir == 1 ? "用法 /tp1 <目标>：把目标拉到自己身边" : "用法 /tp2 <目标>：传送到目标位置"));
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

// ============================================================================
//  /joi <角色简称>  中途加入
//  中途连入的观战玩家在聊天框输入该命令, 指定角色参战。
//  简称按英文名前缀匹配: jag -> Jaeger / sar -> Sarge / wild -> Wildcat ...
//  流程: 直接新建一名该角色的陆战队员给你操作（不去接管现成的 Bot）。
//  新建原理(逆向, 复用引擎正常复活流程):
//    引擎只给了 player.ResurrectMarine() 这一个入口, 它要求存在一条
//    「指挥官是自己 + 无 marine 实体(即 GetHealthPercent()==0)」的
//    asw_marine_resource。于是脚本先用 NetProps 手搓一条这样的资源并登记进
//    asw_game_resource.m_MarineResources, 再调 ResurrectMarine —— 引擎内部
//    会走 ScriptResurrect → SpawnMarineAt, 于是真正生成出一名新陆战队员。
//  档案索引与源码 ASW_MARINE_PROFILE_* 一致(asw_shareddefs.h):
//  0 sarge / 1 wildcat / 2 faith / 3 crash / 4 jaeger / 5 wolfe / 6 bastille / 7 vegas
// ============================================================================
::g_ASRD_ProfileNames <- [
    "sarge", "wildcat", "faith", "crash", "jaeger", "wolfe", "bastille", "vegas"
];

// 新建陆战队员时给的初始装备 = 源码 RosterSelect 的兜底值:
// slot0 步枪(常规0) / slot1 无(-1) / slot2 医疗包(额外0)
::g_ASRD_DefaultWeapons <- [0, -1, 0];
// asw_game_resource.m_MarineResources 的数组长度(源码 ASW_MAX_MARINE_RESOURCES)
::g_ASRD_MaxMarineResources <- 32;

// 把玩家输入的简称解析成档案索引; 解析失败返回 -1
function ResolveProfileIndex(sKey)
{
    if (sKey == null || sKey == "") return -1;
    for (local i = 0; i < ::g_ASRD_ProfileNames.len(); i++)
        if (::g_ASRD_ProfileNames[i].find(sKey) == 0) return i;
    // 兜底: 按游戏内实际显示的名字匹配（本地化语言下也能用）
    local m = null;
    while ((m = Entities.FindByClassname(m, "asw_marine")) != null)
    {
        if (!m.IsValid()) continue;
        local n = "";
        try { n = m.GetMarineName().tolower(); } catch(e) { continue; }
        if (n == "") continue;
        if (n.find(sKey) == 0 || sKey.find(n) == 0) return m.GetMarineProfile();
    }
    return -1;
}

// 列出可用角色简称（空格分隔）
function ListProfileKeys()
{
    local s = "";
    for (local i = 0; i < ::g_ASRD_ProfileNames.len(); i++)
        s += (i == 0 ? "" : " / ") + ::g_ASRD_ProfileNames[i];
    return s;
}

// 安全取陆战队员显示名
function SafeMarineName(m)
{
    if (m == null || !m.IsValid()) return "?";
    try { return m.GetMarineName(); } catch(e) {}
    return "?";
}

// 取本局的 asw_game_resource 单例
function FindGameResource()
{
    return Entities.FindByClassname(null, "asw_game_resource");
}

// 该玩家名下是否已经有一条 marine_resource
function PlayerOwnsMarineResource(hGameRes, hPlayer)
{
    for (local i = 0; i < ::g_ASRD_MaxMarineResources; i++)
    {
        local mr = NetProps.GetPropEntityArray(hGameRes, "m_MarineResources", i);
        if (mr == null || !mr.IsValid()) continue;
        if (NetProps.GetPropEntity(mr, "m_Commander") == hPlayer) return true;
    }
    return false;
}

// m_MarineResources 里第一个空槽位; 没有返回 -1
function FindFreeMarineSlot(hGameRes)
{
    for (local i = 0; i < ::g_ASRD_MaxMarineResources; i++)
    {
        local mr = NetProps.GetPropEntityArray(hGameRes, "m_MarineResources", i);
        if (mr == null || !mr.IsValid()) return i;
    }
    return -1;
}

// 现场新建一名指定档案的陆战队员给 hPlayer；成功返回陆战队员实体，失败返回 null。
// 做法: 手搓一条「无 marine 实体」的 asw_marine_resource 并登记进 game_resource,
//       再调引擎已暴露的 ResurrectMarine(), 由引擎内部 SpawnMarineAt 真正生成。
function SpawnNewMarine(hPlayer, profileIdx)
{
    local hGameRes = FindGameResource();
    if (hGameRes == null || !hGameRes.IsValid()) return null;
    if (PlayerOwnsMarineResource(hGameRes, hPlayer)) return null;   // 已有资源, 不重复造

    local slot = FindFreeMarineSlot(hGameRes);
    if (slot == -1) return null;

    local mr = Entities.CreateByClassname("asw_marine_resource");
    if (mr == null || !mr.IsValid()) return null;

    // 档案 + 指挥官（对应源码 SetProfileIndex / SetCommander）
    NetProps.SetPropInt(mr, "m_MarineProfileIndex", profileIdx);
    NetProps.SetPropEntity(mr, "m_Commander", hPlayer);
    NetProps.SetPropEntity(mr, "m_OriginalCommander", hPlayer);
    NetProps.SetPropInt(mr, "m_iCommanderIndex", hPlayer.entindex());
    // 初始装备（复活分支读的是 m_iInitialWeaponsInSlots，两个都写上保持一致）
    for (local s = 0; s < 3; s++)
    {
        NetProps.SetPropIntArray(mr, "m_iWeaponsInSlots", ::g_ASRD_DefaultWeapons[s], s);
        NetProps.SetPropIntArray(mr, "m_iInitialWeaponsInSlots", ::g_ASRD_DefaultWeapons[s], s);
    }

    mr.Spawn();

    // 登记到 game_resource（对应源码 AddMarineResource）
    NetProps.SetPropEntityArray(hGameRes, "m_MarineResources", mr, slot);

    // 落点沿用 /fh 的逻辑: 最近队友旁
    local pos = FindRespawnPos(hPlayer);
    if (pos == null) pos = hPlayer.GetOrigin();

    // 引擎内部会走 ScriptResurrect → SpawnMarineAt, 并把玩家切到新陆战队员
    local marine = hPlayer.ResurrectMarine(pos, true);
    if (marine == null || !marine.IsValid())
    {
        // 回滚: 删掉刚造的资源（CHandle 数组元素会随实体销毁自动变空）
        DoEntFire("!self", "Kill", "", 0, null, mr);
        return null;
    }
    return marine;
}

// /joi 主逻辑：为中途连入的观战玩家现场新建一名指定角色的陆战队员。
function DoJoin(hPlayer, arg)
{
    arg = TrimSpace(arg).tolower();

    // 已经在操作单位（不是中途连入的观战者）=> 不处理
    local cur = null;
    try { cur = hPlayer.GetNPC(); } catch(e) {}
    if (cur != null && cur.IsValid())
    {
        ClientPrint(hPlayer, 3, "[加入] 你已经在操作一名陆战队员了");
        return;
    }

    // 不带参数: 提示用法并列出可选角色简称
    if (arg == "")
    {
        ClientPrint(hPlayer, 3, "[加入] 用法 /joi <角色简称>，例如 /joi jag；可选: " + ListProfileKeys());
        return;
    }

    local idx = ResolveProfileIndex(arg);
    if (idx == -1)
    {
        ClientPrint(hPlayer, 3, "[加入] 没有这个角色: " + arg + "；可选: " + ListProfileKeys());
        return;
    }

    // 现场新建一名该角色的陆战队员
    local marine = SpawnNewMarine(hPlayer, idx);
    if (marine == null)
    {
        ClientPrint(hPlayer, 3, "[加入] 新建陆战队员失败（需任务进行中，或资源槽已满）");
        return;
    }
    ClientPrint(hPlayer, 3, "[加入] 已生成 " + SafeMarineName(marine) + "，参战。");
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
            ClientPrint(hPlayer, 3, hPlayer.GetPlayerName() + "：你没有权限执行该指令");
    }
    else if (trimmed.find("/asft") == 0 || trimmed.find("!asft") == 0)
    {
        if (IsAdmin(hPlayer))
            DoASFT(hPlayer, TrimSpace(trimmed.slice("/asft".len())));
        else
            ClientPrint(hPlayer, 3, hPlayer.GetPlayerName() + "：你没有权限执行该指令");
    }
    else if (trimmed.find("/fhb") == 0 || trimmed.find("!fhb") == 0)
    {
        if (IsAdmin(hPlayer))
            DoAdminResurrectFHB(hPlayer, TrimSpace(trimmed.slice("/fhb".len())));
        else
            ClientPrint(hPlayer, 3, hPlayer.GetPlayerName() + "：你没有权限执行该指令");
    }
    else if (trimmed.find("!players") == 0 || trimmed.find("/players") == 0)
    {
        if (IsAdmin(hPlayer))
            ListPlayers(hPlayer);
        else
            ClientPrint(hPlayer, 3, hPlayer.GetPlayerName() + "：你没有权限执行该指令");
    }
    else if (trimmed.find("/tp1") == 0 || trimmed.find("!tp1") == 0)
    {
        if (IsAdmin(hPlayer))
            DoSMTP(1, hPlayer, TrimSpace(trimmed.slice("/tp1".len())));
        else
            ClientPrint(hPlayer, 3, hPlayer.GetPlayerName() + "：你没有权限执行该指令");
    }
    else if (trimmed.find("/tp2") == 0 || trimmed.find("!tp2") == 0)
    {
        if (IsAdmin(hPlayer))
            DoSMTP(2, hPlayer, TrimSpace(trimmed.slice("/tp2".len())));
        else
            ClientPrint(hPlayer, 3, hPlayer.GetPlayerName() + "：你没有权限执行该指令");
    }
    // 载具命令(仅管理员)：/jk 删除全部; /j /j2 各生成一辆吉普
    else if (trimmed == "/jk" || trimmed == "!jk"
        || trimmed == "/j" || trimmed == "!j"
        || trimmed == "/j2" || trimmed == "!j2")
    {
        if (!HasJoinedMatch(hPlayer)) return;   // 未加入对局的观战者无响应
        if (IsAdmin(hPlayer))
        {
            if (trimmed == "/jk" || trimmed == "!jk")
                ASRD_DeleteJeeps(hPlayer);
            else
                ASRD_SpawnJeep(hPlayer);
        }
        else
            ClientPrint(hPlayer, 3, hPlayer.GetPlayerName() + "：你没有权限执行该指令");
    }
    // 中途加入（所有玩家，不需要管理员）：/joi <角色简称> 新建一名指定角色的陆战队员
    else if (trimmed.find("/joi") == 0 || trimmed.find("!joi") == 0)
    {
        DoJoin(hPlayer, trimmed.slice("/joi".len()));
    }
    // 玩家命令（管理员也用它，且无限次）
    else if (trimmed.find("/fh") == 0 || trimmed.find("!fh") == 0)
    {
        if (!HasJoinedMatch(hPlayer)) return;   // 未加入对局的观战者无响应
        if (!IsAdmin(hPlayer) && !::g_ASRD_PlayerCommandsEnabled)
            Chat(hPlayer.GetPlayerName() + "：当前 /fh 已被关闭");
        else
            DoFH(hPlayer);
    }
    else if (trimmed.find("/tp") == 0 || trimmed.find("!tp") == 0)
    {
        if (!HasJoinedMatch(hPlayer)) return;   // 未加入对局的观战者无响应
        if (!IsAdmin(hPlayer) && !::g_ASRD_PlayerCommandsEnabled)
            Chat(hPlayer.GetPlayerName() + "：当前 /tp 已被关闭");
        else
            DoTP(hPlayer);
    }
    else if (trimmed.find("/test") == 0 || trimmed.find("!test") == 0)
        DoTest(hPlayer);
}