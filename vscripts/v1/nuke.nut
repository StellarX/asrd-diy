// ============================================================================
//  [AS:RD] 核弹轰炸 (Nuke Strike) —— VScript 版（参考 scripting/asrd_nuke.sp v1.7.1）
//  部署: 与 mapspawn.nut 放在同一目录 <游戏目录>\reactivedrop\scripts\vscripts\
//
//  注意: 本文件故意【不】做 `if (!("SendToConsole" in this)) return` 顶部守卫,
//  因为被 IncludeScript 引入的脚本若带该守卫会被短路、函数全部失效。
//  本文件只定义全局函数与全局状态, 由 mapspawn.nut 负责:
//      - IncludeScript("nuke") 引入本模块
//      - 在 player_say 里校验并分发 /nuke 与 /nukepub
//      - 在 asw_mission_restart 里调用 ASRD_NukeReset()
//
//  功能（对齐 SourceMod 版 asrd_nuke.sp）:
//    /nuke    管理员: 呼叫战术核弹, 倒计时后全图清除虫族
//    /nukepub 玩家:   呼叫战术核弹 (需管理员开启公众模式)
//
//  与 SourceMod 版的差异（VScript 适配, 均为已验证结论）:
//    1. VScript 无法注册 ConVar → 用下方"配置区"全局变量替代（改后换图生效）
//    2. AS:RD VScript 不调用 Update() 钩子 → 倒计时与冲击波均用
//       logic_timer + OnTimer 回调驱动
//    3. 全图清虫改为按离爆心距离从近到远"分批击杀", 避免一次性大量死亡
//       导致客户端状态不一致闪退（每批 ceil(虫数/BatchWaves), 总波次≤BatchWaves）
//    4. 引爆特效 = 光点放大(TempEnts GlowSprite) + 火球光爆(env_explosion) + 震屏(env_shake) + 音效(ASWBarrel.Explode)
// ============================================================================

// ─── 配置区（对应 SourceMod 版 ConVar, 改后换图即生效）──────────────────
::g_ASRD_Nuke_Enabled      <- true;          // 总开关 (对应 sm_asrd_nuke_enabled)
::g_ASRD_Nuke_Damage       <- 999999.0;      // 对虫族单下伤害 (对应 sm_asrd_nuke_damage)
::g_ASRD_Nuke_Delay        <- 3;             // 倒计时秒数 ETA (对应 sm_asrd_nuke_delay)
::g_ASRD_Nuke_Public       <- false;         // 允许普通玩家用 /nukepub (对应 sm_asrd_nuke_public)
::g_ASRD_Nuke_Debug        <- true;         // 调试日志 (对应 sm_asrd_nuke_debug)
::g_ASRD_Nuke_BatchWaves   <- 12;            // 冲击波总波次上限 (分批击杀)
::g_ASRD_Nuke_WaveInterval <- 0.2;           // 冲击波每波间隔 (秒); 12 波约 2.2 秒内清完全图
// ─── 光点放大特效 (TempEnts 客户端临时实体, 方案 B) ─────────────────────
::g_ASRD_Nuke_GlowEnabled    <- true;         // 光点放大开关 (关闭则纯光爆)
::g_ASRD_Nuke_GlowSprite     <- "sprites/light_glow03.vmt"; // 光点材质 (游戏自带光晕)
::g_ASRD_Nuke_GlowStartScale <- 6.0;          // 初始光点大小 (约一名队员)
::g_ASRD_Nuke_GlowMaxScale   <- 25.0;         // 放大上限 (GlowSprite 网络上限 25)
::g_ASRD_Nuke_GlowFrames     <- 14;           // 放大动画帧数
::g_ASRD_Nuke_GlowFrameInterval <- 0.06;      // 帧间隔 (秒); 14 帧约 0.84 秒扩散

// ─── 怪物实体类名清单（与 asrd_nuke.sp 完全一致）────────────────────────
::g_ASRD_Nuke_AlienClasses <- [
    "asw_drone",
    "asw_drone_jumper",
    "asw_drone_uber",
    "asw_drone_antlion",
    "asw_parasite",
    "asw_parasite_defanged",
    "asw_egg",
    "asw_boomer",
    "asw_boomer_blob",
    "asw_buzzer",
    "asw_harvester",
    "asw_mortarbug",
    "asw_ranger",
    "asw_shieldbug",
    "asw_grub",
    "asw_grub_sac",
    "asw_queen",
    "asw_mender",
    "asw_shaman",
    "asw_xenomite",
    "asw_antlion_guard",
    "npc_antlionguard",
    "npc_antlionguard_cavern",
    "npc_antlionguard_normal",
    "npc_antlion_worker"
];

// ─── 运行时状态（单发锁定, 同一时刻仅一发在路上）────────────────────────
::g_ASRD_Nuke_Pending   <- false;        // 是否有核弹正在倒计时/冲击波推进
::g_ASRD_Nuke_Eta       <- 0;            // 剩余秒数
::g_ASRD_Nuke_Center    <- Vector(0,0,0);// 爆心（触发者陆战队员位置）
::g_ASRD_Nuke_EtaTimer  <- null;         // 倒计时 logic_timer 句柄
::g_ASRD_Nuke_WaveTimer <- null;         // 冲击波 logic_timer 句柄
::g_ASRD_Nuke_KillQueue <- [];           // 按距离排序的虫族清单: [{ent=, dist=}]
::g_ASRD_Nuke_WaveIndex <- 0;            // 冲击波已推进到的队列下标
::g_ASRD_Nuke_BatchSize <- 1;            // 每波击杀数量
::g_ASRD_Nuke_Killed    <- 0;            // 累计击杀数
::g_ASRD_Nuke_GlowSpriteIndex <- -1;      // 光点材质 PrecacheModel 索引缓存 (-1=未缓存)
::g_ASRD_Nuke_GlowTEName  <- "GlowSprite"; // 临时实体名缓存 (Source 通用网络名)
::g_ASRD_Nuke_GlowTEProbed <- false;      // 是否已探测 TempEnts 名称列表

// ─── 工具：红色聊天文本（TextColor 仅对 HUD_PRINTTALK 聊天框生效）────────
::NukeRed <- function(msg)
{
    try {
        if ("TextColor" in ::getroottable())
            return (::TextColor(255, 0, 0)).tostring() + msg;
    } catch(e) {}
    return msg;
}

// ─── 工具：创建 logic_timer 并绑定 OnTimer 回调（cbName 为全局函数名）────
::NukeMakeTimer <- function(refire, cbName)
{
    local t = null;
    try { t = Entities.CreateByClassname("logic_timer"); } catch(e) { t = null; }
    if (t == null) return null;
    try {
        t.__KeyValueFromFloat("RefireTime", refire);
        t.ValidateScriptScope();
        t.ConnectOutput("OnTimer", cbName);
        DoEntFire("!self", "Enable", "", 0.0, null, t);
        return t;
    } catch(e) { return null; }
}

// ─── 停止并销毁倒计时计时器 ──────────────────────────────────────────────
::NukeStopCountdown <- function()
{
    if (::g_ASRD_Nuke_EtaTimer != null)
    {
        local t = ::g_ASRD_Nuke_EtaTimer;
        ::g_ASRD_Nuke_EtaTimer = null;
        if (t != null && t.IsValid())
            try { DoEntFire("!self", "Kill", "", 0.0, null, t); } catch(e) {}
    }
    ClientPrint(null, 4, " ");
}

// ─── 停止并销毁冲击波计时器 ──────────────────────────────────────────────
::NukeStopWaveTimer <- function()
{
    if (::g_ASRD_Nuke_WaveTimer != null)
    {
        local t = ::g_ASRD_Nuke_WaveTimer;
        ::g_ASRD_Nuke_WaveTimer = null;
        if (t != null && t.IsValid())
            try { DoEntFire("!self", "Kill", "", 0.0, null, t); } catch(e) {}
    }
}

// ─── 屏幕中央倒计时（HUD_PRINTCENTER, 引擎限制为白色小字）─────────────────
::NukeShowEta <- function(sec)
{
    ClientPrint(null, 4, "呼叫战术核弹  ETA " + sec + " 秒");
}

// ─── 计算爆心（触发者陆战队员位置, 拿不到则退化为首个陆战队员/原点）──────
::NukeSetCenter <- function(hPlayer)
{
    local center = Vector(0, 0, 0);
    local m = null;
    if (hPlayer && hPlayer.IsValid())
    {
        try { if ("GetMarine" in hPlayer) m = hPlayer.GetMarine(); } catch(e) { m = null; }
    }
    if (m == null || !m.IsValid())
    {
        local f = null;
        try { f = Entities.FindByClassname(null, "asw_marine"); } catch(e) { f = null; }
        m = f;
    }
    if (m != null && m.IsValid())
        center = m.GetOrigin();
    ::g_ASRD_Nuke_Center = center;
}

// ─── 收集全图虫族并按离爆心距离排序（预计算距离, 减少 GetOrigin 调用）─────
::NukeCollectBugs <- function(center)
{
    ::g_ASRD_Nuke_KillQueue = [];
    foreach (cls in ::g_ASRD_Nuke_AlienClasses)
    {
        local ent = null;
        while ((ent = Entities.FindByClassname(ent, cls)) != null)
        {
            if (!ent.IsValid()) continue;
            local hp = 0.0;
            try { hp = ent.GetHealth(); } catch(e) { hp = 0.0; }
            if (hp <= 0) continue;
            local p = ent.GetOrigin();
            local dx = p.x - center.x;
            local dy = p.y - center.y;
            local dz = p.z - center.z;
            ::g_ASRD_Nuke_KillQueue.append({ ent = ent, dist = dx*dx + dy*dy + dz*dz });
        }
    }
    ::g_ASRD_Nuke_KillQueue.sort(function(a, b) {
        if (a.dist < b.dist) return -1;
        if (a.dist > b.dist) return 1;
        return 0;
    });
}

// ─── 击杀单只虫族（正常死亡流程 + 无击退伤害类型, 对未死实体 Kill 兜底）───
::NukeKillOne <- function(ent)
{
    if (ent == null || !ent.IsValid()) return;
    local hp = 0.0;
    try { ent.TakeDamage(::g_ASRD_Nuke_Damage, 0, ent); } catch(e) {}
    try { hp = ent.GetHealth(); } catch(e) { hp = 0.0; }
    // 仅对仍然存活(免疫/特殊状态)的实体强制 Kill, 已进入死亡动画的实体不强行移除, 避免闪退
    if (ent.IsValid() && hp > 0)
        try { DoEntFire("!self", "Kill", "", 0.0, null, ent); } catch(e) {}
}

// ─── 冲击波：击杀当前一波, 返回是否还有下一波 ────────────────────────────
::NukePulse <- function()
{
    local total = ::g_ASRD_Nuke_KillQueue.len();
    if (::g_ASRD_Nuke_WaveIndex >= total) return false;
    local end = ::g_ASRD_Nuke_WaveIndex + ::g_ASRD_Nuke_BatchSize;
    if (end > total) end = total;
    for (local i = ::g_ASRD_Nuke_WaveIndex; i < end; i++)
    {
        ::NukeKillOne(::g_ASRD_Nuke_KillQueue[i].ent);
        ::g_ASRD_Nuke_Killed++;
    }
    ::g_ASRD_Nuke_WaveIndex = end;
    return ::g_ASRD_Nuke_WaveIndex < total;
}

// ─── 遍历所有在线玩家（用于全图音效, 与 mapspawn ForEachPlayer 同思路）──────
::g_ASRD_Nuke_SeenPlayer <- {};
::NukeForeachPlayer <- function(cb)
{
    ::g_ASRD_Nuke_SeenPlayer.clear();
    foreach (cls in ["player", "asw_player"])
    {
        local h = null;
        while ((h = Entities.FindByClassname(h, cls)) != null)
        {
            if (!h || !h.IsValid()) continue;
            if (::g_ASRD_Nuke_SeenPlayer.rawin(h)) continue;
            ::g_ASRD_Nuke_SeenPlayer[h] <- true;
            cb(h);
        }
    }
    ::g_ASRD_Nuke_SeenPlayer.clear();
}

// ─── 光斑：无伤光爆（env_explosion, 与 /fh 重生特效同款, 引擎原生稳定）────
::NukeLightBurst <- function(center)
{
    try {
        local boom = Entities.CreateByClassname("env_explosion");
        boom.SetOrigin(center);
        boom.__KeyValueFromInt("iMagnitude", 0);
        boom.__KeyValueFromInt("spawnflags", 31);
        DoEntFire("!self", "Explode", "", 0.0, null, boom);
        DoEntFire("!self", "Kill", "", 1.0, null, boom);
    } catch(e) {}
}

// ─── 确保光点材质已 Precache, 返回模型索引 ────────────────────────────────
::NukeEnsureGlow <- function()
{
    if (!::g_ASRD_Nuke_GlowEnabled) return false;
    if (::g_ASRD_Nuke_GlowSpriteIndex >= 0) return true;
    local host = null;
    foreach (cls in ["player", "asw_player", "asw_marine"])
    {
        try { host = Entities.FindByClassname(null, cls); } catch(e) { host = null; }
        if (host != null && host.IsValid()) break;
    }
    if (host == null || !host.IsValid()) return false;
    try {
        foreach (cand in [::g_ASRD_Nuke_GlowSprite, "materials/" + ::g_ASRD_Nuke_GlowSprite])
        {
            try {
                local idx = host.PrecacheModel(cand);
                if (idx >= 0) { ::g_ASRD_Nuke_GlowSpriteIndex = idx; return true; }
            } catch(e) {}
        }
    } catch(e) {}
    return false;
}

// ─── 探测 AS:RD 真实支持的临时实体名 (优先 GlowSprite) ───────────────────
::NukeResolveTEName <- function()
{
    if (::g_ASRD_Nuke_GlowTEProbed)
        return ::g_ASRD_Nuke_GlowTEName;
    ::g_ASRD_Nuke_GlowTEProbed = true;

    local names = [];
    local got = false;
    try { TempEnts.GetNames(names); got = true; }
    catch(e) { try { TempEnts.GetNames("", names); got = true; } catch(e2) {} }

    if (::g_ASRD_Nuke_Debug)
    {
        try {
            local listStr = "";
            foreach (n in names) { if (listStr != "") listStr += ", "; listStr = listStr + n; }
            if (listStr == "") listStr = "(空)";
            printl("[核弹] TempEnts 列表: " + (got ? listStr : "(GetNames 不可用)"));
        } catch(e) {}
    }

    if (got && names.len() > 0)
    {
        try {
            foreach (n in names) if (n == "GlowSprite") { ::g_ASRD_Nuke_GlowTEName = n; return n; }
            foreach (n in names) { local l = "" + n; l = l.tolower(); if (l.find("glow") != null && l.find("sprite") != null) { ::g_ASRD_Nuke_GlowTEName = n; return n; } }
            foreach (n in names) { local l = "" + n; l = l.tolower(); if (l.find("sprite") != null) { ::g_ASRD_Nuke_GlowTEName = n; return n; } }
        } catch(e) {}
    }
    return ::g_ASRD_Nuke_GlowTEName;
}

// ─── 光点放大特效: 队员大小的极亮光点快速扩散并淡化 (TempEnts GlowSprite) ──
::NukeLightGlow <- function(center)
{
    if (!::g_ASRD_Nuke_GlowEnabled) return false;
    if (!::NukeEnsureGlow()) return false;

    local teName = "GlowSprite";
    try { teName = ::NukeResolveTEName(); } catch(e) { teName = "GlowSprite"; }
    local idx = ::g_ASRD_Nuke_GlowSpriteIndex;
    local frames = ::g_ASRD_Nuke_GlowFrames;
    if (frames < 1) frames = 1;
    local interval = ::g_ASRD_Nuke_GlowFrameInterval;
    local startScale = ::g_ASRD_Nuke_GlowStartScale;
    local maxScale = ::g_ASRD_Nuke_GlowMaxScale;
    if (maxScale < startScale) maxScale = startScale;

    local ok = false;
    try {
        for (local i = 0; i < frames; i++)
        {
            local t = (frames <= 1) ? 0.0 : (i / (frames - 1.0));        // 0..1
            local scale = startScale + (maxScale - startScale) * (t * t); // 先慢后快的爆闪放大
            local life  = 0.10 + 0.30 * t;                               // 大光斑残留稍久
            local bright = 255 - (170.0 * t).tointeger();                // 越后越淡
            if (bright < 0) bright = 0;
            TempEnts.Create(null, teName, i * interval, {
                m_vecOrigin   = Vector(center.x, center.y, center.z),
                m_nModelIndex = idx,
                m_fScale      = scale,
                m_fLife       = life,
                m_nBrightness = bright
            });
        }
        ok = true;
    } catch(e) {
        if (::g_ASRD_Nuke_Debug) printl("[核弹] GlowSprite 创建失败: " + e);
    }
    return ok;
}

// ─── 音效：全图播放游戏自带油桶爆炸音（ASWBarrel.Explode, 已随游戏注册）──
::NukePlaySound <- function()
{
    ::NukeForeachPlayer(function(p) {
        try { p.EmitSound("ASWBarrel.Explode"); } catch(e) {}
    });
}

// ─── 震屏（env_shake, 对齐 SourceMod 版 amplitude=14, 全局）────────────────
::NukeScreenShake <- function()
{
    local shake = null;
    try { shake = Entities.CreateByClassname("env_shake"); } catch(e) { shake = null; }
    if (shake == null) return;
    try {
        shake.__KeyValueFromFloat("amplitude", 14.0);
        shake.__KeyValueFromFloat("frequency", 40.0);
        shake.__KeyValueFromFloat("duration", 2.5);
        shake.__KeyValueFromInt("spawnflags", 1);
        DoEntFire("!self", "StartShake", "", 0.0, null, shake);
        DoEntFire("!self", "Kill", "", 3.0, null, shake);
    } catch(e) {}
}

// ─── 引爆：震屏+爆炸 → 冲击波分批击杀 → 击杀数广播 ──────────────────────
::NukeDetonate <- function()
{
    ::g_ASRD_Nuke_Pending = false;
    ::NukeCollectBugs(::g_ASRD_Nuke_Center);
    local total = ::g_ASRD_Nuke_KillQueue.len();

    ::NukeScreenShake();
    ::NukeLightBurst(::g_ASRD_Nuke_Center);   // 中心火球光爆 (保留, 引擎原生稳定)
    ::NukeLightGlow(::g_ASRD_Nuke_Center);    // 光点快速放大扩散 (TempEnts 方案, 内部容错)
    ::NukePlaySound();

    if (total <= 0)
    {
        ::NukeShowKillCount(0);
        return;
    }

    ::g_ASRD_Nuke_WaveIndex = 0;
    ::g_ASRD_Nuke_Killed = 0;
    ::g_ASRD_Nuke_BatchSize = (total + ::g_ASRD_Nuke_BatchWaves - 1) / ::g_ASRD_Nuke_BatchWaves;
    if (::g_ASRD_Nuke_BatchSize < 1) ::g_ASRD_Nuke_BatchSize = 1;

    // 第一波立即触发, 后续波次用冲击波计时器推进
    if (!::NukePulse()) { ::NukeFinishWaves(); return; }

    local t = ::NukeMakeTimer(::g_ASRD_Nuke_WaveInterval, "NukeWaveTick");
    if (t == null)
    {
        // 计时器创建失败 fallback: 一次性清完所有虫族
        while (::NukePulse()) {}
        ::NukeFinishWaves();
        if (::g_ASRD_Nuke_Debug) printl("[核弹] 冲击波计时器创建失败, 改为一次性清除");
    }
    else
    {
        ::g_ASRD_Nuke_WaveTimer = t;
    }
}

// ─── 冲击波结束: 停计时器 + 广播红色击杀数 ───────────────────────────────
::NukeFinishWaves <- function()
{
    ::NukeStopWaveTimer();
    ::NukeShowKillCount(::g_ASRD_Nuke_Killed);
    if (::g_ASRD_Nuke_Debug) printl("[核弹] 全图清除虫族=" + ::g_ASRD_Nuke_Killed);
}

// ─── 红色击杀数广播（唯一全服聊天提示）──────────────────────────────────
::NukeShowKillCount <- function(n)
{
    ClientPrint(null, 3, ::NukeRed("[核弹] 已消灭 " + n + " 只虫子"));
}

// ─── 倒计时 OnTimer 回调 ────────────────────────────────────────────────
::NukeEtaTick <- function()
{
    ::g_ASRD_Nuke_Eta -= 1;
    if (::g_ASRD_Nuke_Eta <= 0)
    {
        ::NukeStopCountdown();
        ::NukeDetonate();
    }
    else
    {
        ::NukeShowEta(::g_ASRD_Nuke_Eta);
    }
}

// ─── 冲击波 OnTimer 回调 ─────────────────────────────────────────────────
::NukeWaveTick <- function()
{
    if (!::NukePulse())
        ::NukeFinishWaves();
}

// ─── 内部：启动核弹倒计时（enabled/pending 已在入口校验）───────────────────
::NukeStart <- function(hPlayer)
{
    ::NukeSetCenter(hPlayer);

    if (::g_ASRD_Nuke_Delay <= 0)
    {
        ::NukeDetonate();
        return;
    }

    ::g_ASRD_Nuke_Pending = true;
    ::g_ASRD_Nuke_Eta = ::g_ASRD_Nuke_Delay;
    ::NukeShowEta(::g_ASRD_Nuke_Eta);

    local t = ::NukeMakeTimer(1.0, "NukeEtaTick");
    if (t == null)
    {
        // 计时器创建失败 fallback: 立即引爆
        ::g_ASRD_Nuke_Pending = false;
        if (::g_ASRD_Nuke_Debug) printl("[核弹] 倒计时计时器创建失败, 立即引爆");
        ::NukeDetonate();
    }
    else
    {
        ::g_ASRD_Nuke_EtaTimer = t;
    }
}

// ─── 对外入口：管理员 /nuke ──────────────────────────────────────────────
::ASRD_NukeStart <- function(hPlayer)
{
    if (!::g_ASRD_Nuke_Enabled)
    {
        ClientPrint(hPlayer, 3, "[核弹] 功能已禁用");
        return;
    }
    if (::g_ASRD_Nuke_Pending)
    {
        ClientPrint(hPlayer, 3, "[核弹] 战术核弹已在路上 (预计 " + ::g_ASRD_Nuke_Eta + " 秒抵达), 请稍候");
        return;
    }
    ::NukeStart(hPlayer);
}

// ─── 对外入口：玩家 /nukepub ─────────────────────────────────────────────
::ASRD_NukeStartPublic <- function(hPlayer)
{
    if (!::g_ASRD_Nuke_Enabled)
    {
        ClientPrint(hPlayer, 3, "[核弹] 功能已禁用");
        return;
    }
    if (!::g_ASRD_Nuke_Public)
    {
        ClientPrint(hPlayer, 3, "[核弹] 该功能未对玩家开放");
        return;
    }
    if (::g_ASRD_Nuke_Pending)
    {
        ClientPrint(hPlayer, 3, "[核弹] 战术核弹已在路上 (预计 " + ::g_ASRD_Nuke_Eta + " 秒抵达), 请稍候");
        return;
    }
    ::NukeStart(hPlayer);
}

// ─── 对外入口：任务重开时清理计时器与状态（由 mapspawn.nut 调用）─────────
::ASRD_NukeReset <- function()
{
    ::NukeStopCountdown();
    ::NukeStopWaveTimer();
    ::g_ASRD_Nuke_Pending = false;
    ::g_ASRD_Nuke_Eta = 0;
    ::g_ASRD_Nuke_KillQueue = [];
    ::g_ASRD_Nuke_WaveIndex = 0;
    ::g_ASRD_Nuke_Killed = 0;
}

printl("[ASRD] v1 nuke.nut loaded");