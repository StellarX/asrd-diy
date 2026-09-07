// ============================================================================
//  [AS:RD] /fx 特效测试工具 —— 一条命令预览各类引擎/脚本特效
//  部署: 放到 <游戏目录>\reactivedrop\scripts\vscripts\effects.nut
//  接入: 修改同目录 mapspawn.nut 两处:
//        1) 顶部(其它 IncludeScript 附近)加:  try { IncludeScript("effects"); } catch(e) {}
//        2) player_say 分发里(/test 之前)加 /fx 分支(见 mapspawn.nut 改动说明)
//
//  用法(所有玩家可用, 测试期):
//    /fx list            列出全部特效名与说明
//    /fx <特效名>        在你所在位置触发
//    /fx <特效名> <玩家> 在指定玩家位置触发 (userid 或名字片段)
//    /fx stop            清理所有持续型特效实体
//
//  特效均为纯视觉/音效, 无伤害; 持续型 2~4 秒后自动清理。
//  注意: 本模块被 IncludeScript 引入, 故意不加 "SendToConsole" 顶部守卫
//        (带守卫会被短路导致函数全部失效, 同 jeep.nut 教训)。
// ============================================================================

// ─── 内部工具: 裁剪空白 ─────────────────────────────────────────────────────
::ASRD_FX_Trim <- function(s)
{
    if (s == null) return "";
    local a = 0, b = s.len();
    while (a < b && (s[a] == 32 || s[a] == 9)) a++;
    while (b > a && (s[b - 1] == 32 || s[b - 1] == 9)) b--;
    return s.slice(a, b);
}

// ─── 内部工具: 解析目标玩家 (userid 或名字包含匹配, 不区分大小写) ───────────
::ASRD_FX_FindPlayer <- function(text)
{
    if (text == null || text == "") return null;
    local isNum = true;
    for (local i = 0; i < text.len(); i++)
    {
        local ch = text[i];
        if ((ch < 48 || ch > 57) && ch != 45) { isNum = false; break; }
    }
    if (isNum) { try { return GetPlayerFromUserID(text.tointeger()); } catch(e) { return null; } }
    local lower = text.tolower();
    local found = null;
    local seen = {};
    foreach (cls in ["player", "asw_player"])
    {
        local h = null;
        while ((h = Entities.FindByClassname(h, cls)))
        {
            if (!h || !h.IsValid()) continue;
            if (h in seen) continue;
            seen[h] <- true;
            try {
                if (h.GetPlayerName().tolower().find(lower) != null) { found = h; break; }
            } catch(e) {}
        }
        if (found != null) break;
    }
    return found;
}

// ─── 内部工具: 取玩家当前陆战队员句柄(失败 null) ───────────────────────────
::ASRD_FX_GetMarine <- function(hPlayer)
{
    try {
        if (hPlayer != null && hPlayer.IsValid() && ("GetMarine" in hPlayer))
        {
            local m = hPlayer.GetMarine();
            if (m != null && m.IsValid()) return m;
        }
    } catch(e) {}
    return null;
}

// ─── 内部工具: 取触发位置(优先 marine, 兜底玩家实体自身) ────────────────────
::ASRD_FX_GetPos <- function(marine, hPlayer)
{
    try { if (marine != null && marine.IsValid()) return marine.GetOrigin(); } catch(e) {}
    try { if (hPlayer != null && hPlayer.IsValid()) return hPlayer.GetOrigin(); } catch(e) {}
    return Vector(0, 0, 0);
}

// ─── 持续特效登记/清理 ──────────────────────────────────────────────────────
::g_ASRD_FX_Active <- [];

::ASRD_FX_StopAll <- function()
{
    local n = 0;
    foreach (e in ::g_ASRD_FX_Active)
    {
        if (e != null && e.IsValid())
        {
            try { DoEntFire("!self", "Kill", "", 0.0, null, e); } catch(x) {}
            n++;
        }
    }
    ::g_ASRD_FX_Active.clear();
    ClientPrint(null, 3, "[特效] 已清理 " + n + " 个持续特效实体");
}

// ============================================================================
//  A 档: 本仓库已验证可用的特效
// ============================================================================

// 1. spark 火花 (env_spark ×3)
::ASRD_FX_spark <- function(hPlayer, m, pos)
{
    local s = Entities.CreateByClassname("env_spark");
    s.SetOrigin(pos + Vector(0, 0, 30));
    s.__KeyValueFromFloat("MaxDelay", 0.2);
    s.__KeyValueFromInt("Magnitude", 10);
    s.__KeyValueFromInt("TrailLength", 3);
    DoEntFire("!self", "SparkOnce", "", 0.0, null, s);
    DoEntFire("!self", "SparkOnce", "", 0.3, null, s);
    DoEntFire("!self", "SparkOnce", "", 0.6, null, s);
    DoEntFire("!self", "Kill", "", 1.5, null, s);
    return true;
}

// 2. boom 光爆 (env_explosion 无伤害)
::ASRD_FX_boom <- function(hPlayer, m, pos)
{
    local b = Entities.CreateByClassname("env_explosion");
    b.SetOrigin(pos);
    b.__KeyValueFromInt("iMagnitude", 0);
    b.__KeyValueFromInt("spawnflags", 31);
    DoEntFire("!self", "Explode", "", 0.0, null, b);
    DoEntFire("!self", "Kill", "", 1.0, null, b);
    return true;
}

// 3. sprite 发光点 (env_sprite; scale 必须 2^N 且 ≤64)
::ASRD_FX_sprite <- function(hPlayer, m, pos)
{
    local s = Entities.CreateByClassname("env_sprite");
    s.SetOrigin(pos + Vector(0, 0, 60));
    s.__KeyValueFromString("model", "sprites/light_glow03.vmt");
    s.__KeyValueFromInt("scale", 8);
    s.__KeyValueFromString("rendercolor", "255 255 255");
    s.__KeyValueFromInt("renderamt", 255);
    s.__KeyValueFromInt("spawnflags", 1);
    try { s.Spawn(); s.Activate(); } catch(e) {}
    DoEntFire("!self", "Hide", "", 1.5, null, s);
    DoEntFire("!self", "Kill", "", 2.0, null, s);
    return true;
}

// 4. glowte 客户端光粒子 (TempEnts GlowSprite; 对齐 nuke.nut 成熟写法)
::g_ASRD_FX_GlowIdx <- -1;          // PrecacheModel 索引缓存(-1=未缓存)
::ASRD_FX_GlowSprite <- "sprites/light_glow03.vmt";
::g_ASRD_FX_GlowTEProbed <- false;  // 是否已探测 TempEnts 名称
::g_ASRD_FX_GlowTE <- "GlowSprite"; // 解析后的临时实体名

// 解析 AS:RD 真实支持的 TempEnts 名(优先 GlowSprite, 否则含 glow/sprite, 否则任意 sprite)
::ASRD_FX_ResolveTEName <- function()
{
    if (::g_ASRD_FX_GlowTEProbed) return ::g_ASRD_FX_GlowTE;
    ::g_ASRD_FX_GlowTEProbed = true;
    local names = [];
    local got = false;
    try { TempEnts.GetNames(names); got = true; }
    catch(e) { try { TempEnts.GetNames("", names); got = true; } catch(e2) {} }
    if (got && names.len() > 0)
    {
        try {
            foreach (n in names) if (n == "GlowSprite") { ::g_ASRD_FX_GlowTE = n; return n; }
            foreach (n in names) { local l = ("" + n).tolower(); if (l.find("glow") != null && l.find("sprite") != null) { ::g_ASRD_FX_GlowTE = n; return n; } }
            foreach (n in names) { local l = ("" + n).tolower(); if (l.find("sprite") != null) { ::g_ASRD_FX_GlowTE = n; return n; } }
        } catch(e) {}
    }
    return ::g_ASRD_FX_GlowTE;
}

::ASRD_FX_EnsureGlow <- function()
{
    if (::g_ASRD_FX_GlowIdx >= 0) return true;
    local host = null;
    foreach (cls in ["player", "asw_player", "asw_marine"])
    {
        try { host = Entities.FindByClassname(null, cls); } catch(e) { host = null; }
        if (host != null && host.IsValid()) break;
    }
    if (host == null || !host.IsValid()) return false;
    try {
        foreach (cand in [::ASRD_FX_GlowSprite, "materials/" + ::ASRD_FX_GlowSprite])
        {
            try {
                local idx = host.PrecacheModel(cand);
                if (idx >= 0) { ::g_ASRD_FX_GlowIdx = idx; return true; }
            } catch(e) {}
        }
    } catch(e) {}
    return false;
}

::ASRD_FX_glowte <- function(hPlayer, m, pos)
{
    if (!::ASRD_FX_EnsureGlow()) return false;
    local teName = "GlowSprite";
    try { teName = ::ASRD_FX_ResolveTEName(); } catch(e) { teName = "GlowSprite"; }
    for (local i = 0; i < 6; i++)
    {
        try {
            TempEnts.Create(null, teName, 0.0, {
                m_vecOrigin   = pos + Vector(0, 0, 40),
                m_nModelIndex = ::g_ASRD_FX_GlowIdx,
                m_fScale      = 25.0,
                m_fLife       = 0.6,
                m_nBrightness = 255
            });
        } catch(e) { return false; }
    }
    return true;
}

// 5. redfade 屏幕红闪 (ScreenFade; 只用 FFADE_IN=1, 勿组合 IN|OUT)
::ASRD_FX_redfade <- function(hPlayer, m, pos)
{
    if (hPlayer == null || !hPlayer.IsValid()) return false;
    try { ScreenFade(hPlayer, 255, 0, 0, 180, 0.3, 0.6, 1); return true; } catch(e) {}
    return false;
}

// 6. center 屏幕中央大字 (ClientPrint dest=4 HUD_PRINTCENTER)
::ASRD_FX_center <- function(hPlayer, m, pos)
{
    ClientPrint(null, 4, "[特效] 屏幕中央大字测试 (HUD_PRINTCENTER)");
    return true;
}

// 7. sound 音效 (ASWBarrel.Explode, 项目已验证该音效存在)
::ASRD_FX_sound <- function(hPlayer, m, pos)
{
    try {
        if (m != null && m.IsValid() && ("EmitSound" in m)) { m.EmitSound("ASWBarrel.Explode"); return true; }
    } catch(e) {}
    try {
        if (hPlayer != null && hPlayer.IsValid() && ("EmitSound" in hPlayer)) { hPlayer.EmitSound("ASWBarrel.Explode"); return true; }
    } catch(e) {}
    return false;
}

// 8. fxtimer 连续火花 (logic_timer + OnTimer 回调, 4 秒后自动停)
::g_ASRD_FX_TimerH <- null;
::g_ASRD_FX_TimerPos <- Vector(0, 0, 0);

::ASRD_FX_TimerTick <- function()
{
    local s = null;
    try { s = Entities.CreateByClassname("env_spark"); } catch(e) { s = null; }
    if (s == null) return;
    s.SetOrigin(::g_ASRD_FX_TimerPos + Vector(RandomInt(-40, 40), RandomInt(-40, 40), RandomInt(0, 60)));
    s.__KeyValueFromFloat("MaxDelay", 0.1);
    s.__KeyValueFromInt("Magnitude", 8);
    s.__KeyValueFromInt("TrailLength", 2);
    DoEntFire("!self", "SparkOnce", "", 0.0, null, s);
    DoEntFire("!self", "Kill", "", 0.5, null, s);
}

::ASRD_FX_fxtimer <- function(hPlayer, m, pos)
{
    if (::g_ASRD_FX_TimerH != null && ::g_ASRD_FX_TimerH.IsValid())
        try { DoEntFire("!self", "Kill", "", 0.0, null, ::g_ASRD_FX_TimerH); } catch(e) {}
    ::g_ASRD_FX_TimerH = null;
    ::g_ASRD_FX_TimerPos = pos;
    local t = null;
    try { t = Entities.CreateByClassname("logic_timer"); } catch(e) { t = null; }
    if (t == null) return false;
    try {
        t.__KeyValueFromFloat("RefireTime", 0.35);
        t.ValidateScriptScope();
        t.ConnectOutput("OnTimer", "ASRD_FX_TimerTick");
        DoEntFire("!self", "Enable", "", 0.0, null, t);
        DoEntFire("!self", "Kill", "", 4.0, null, t);
        ::g_ASRD_FX_TimerH = t;
        return true;
    } catch(e) { return false; }
}

// ============================================================================
//  B 档: AS:RD 官方 VScript API 明确存在 (粒子/音效表)
// ============================================================================

// 粒子载体: 建 info_target 并在其上播粒子, 播完自动清理
::ASRD_FX_Particle <- function(pos, name, life)
{
    local e = null;
    try { e = Entities.CreateByClassname("info_target"); } catch(x) { e = null; }
    if (e == null) return false;
    try { e.SetOrigin(pos); e.Spawn(); e.Activate(); } catch(x) {}
    try {
        e.DispatchParticleEffect(name);
    } catch(x) {
        try { DoEntFire("!self", "Kill", "", 0.0, null, e); } catch(y) {}
        return false;
    }
    DoEntFire("!self", "Kill", "", life, null, e);
    return true;
}

// 9. pboom 粒子爆炸 (asw_env_explosion)
::ASRD_FX_pboom <- function(hPlayer, m, pos)
{
    return ::ASRD_FX_Particle(pos, "asw_env_explosion", 3.0);
}

// 10. pzap 粒子电击闪光 (electrified_armor_burst, electrical_fx.pcf 自动precache)
::ASRD_FX_pzap <- function(hPlayer, m, pos)
{
    return ::ASRD_FX_Particle(pos, "electrified_armor_burst", 3.0);
}

// 11. ptesla 粒子电弧 (electrical_arc_01_system, electrical_fx.pcf 自动precache, 持续型)
::ASRD_FX_ptesla <- function(hPlayer, m, pos)
{
    return ::ASRD_FX_Particle(pos, "electrical_arc_01_system", 3.0);
}

// 12. pflare 粒子闪光 (dissolve_flashes, asw_weapon_fx_7a.pcf 自动precache)
::ASRD_FX_pflare <- function(hPlayer, m, pos)
{
    return ::ASRD_FX_Particle(pos, "dissolve_flashes", 3.0);
}

// 13. pbeam 粒子光束 (electric_weapon_beam, electrical_fx.pcf 自动precache, 持续型)
::ASRD_FX_pbeam <- function(hPlayer, m, pos)
{
    return ::ASRD_FX_Particle(pos, "electric_weapon_beam", 2.5);
}

// 14. sndtable 带参数音效 (EmitSoundTable: 音量/音高/声道)
::ASRD_FX_sndtable <- function(hPlayer, m, pos)
{
    try {
        if (m != null && m.IsValid() && ("EmitSoundTable" in m))
        {
            m.EmitSoundTable("ASWBarrel.Explode", { volume = 0.9, pitch = 130 });
            return true;
        }
    } catch(e) {}
    return ::ASRD_FX_sound(hPlayer, m, pos);
}

// ============================================================================
//  C 档: Source 通用特效实体 (理论可用, AS:RD 未验证, 实测目标)
// ============================================================================

// 15. beam 激光光束 (env_beam; 需要两个 info_target 端点)
::ASRD_FX_beam <- function(hPlayer, m, pos)
{
    local fwd = Vector(1, 0, 0);
    try { if (m != null && m.IsValid() && ("GetForwardVector" in m)) fwd = m.GetForwardVector(); } catch(e) {}
    local a = null, b = null;
    try {
        a = Entities.CreateByClassname("info_target");
        a.__KeyValueFromString("targetname", "asrd_fx_beam_a");
        a.SetOrigin(pos);
        a.Spawn(); a.Activate();
        b = Entities.CreateByClassname("info_target");
        b.__KeyValueFromString("targetname", "asrd_fx_beam_b");
        b.SetOrigin(pos + Vector(fwd.x * 300, fwd.y * 300, fwd.z * 300 + 30));
        b.Spawn(); b.Activate();
    } catch(e) { return false; }
    local beam = null;
    try { beam = Entities.CreateByClassname("env_beam"); } catch(e) { beam = null; }
    if (beam == null) return false;
    try {
        beam.__KeyValueFromString("texture", "sprites/laserbeam.vmt");
        beam.__KeyValueFromString("rendercolor", "0 255 255");
        beam.__KeyValueFromInt("renderamt", 200);
        beam.__KeyValueFromFloat("BoltWidth", 4.0);
        beam.__KeyValueFromString("StartEntity", "asrd_fx_beam_a");
        beam.__KeyValueFromString("EndEntity", "asrd_fx_beam_b");
        beam.Spawn(); beam.Activate();
    } catch(e) {}
    DoEntFire("!self", "TurnOn", "", 0.0, null, beam);
    DoEntFire("asrd_fx_beam_a", "Kill", "", 2.0, null, null);
    DoEntFire("asrd_fx_beam_b", "Kill", "", 2.0, null, null);
    DoEntFire("!self", "Kill", "", 2.1, null, beam);
    return true;
}

// 16. light 动态光源 (light_dynamic)
::ASRD_FX_light <- function(hPlayer, m, pos)
{
    local l = null;
    try { l = Entities.CreateByClassname("light_dynamic"); } catch(e) { l = null; }
    if (l == null) return false;
    l.SetOrigin(pos + Vector(0, 0, 50));
    l.__KeyValueFromString("_light", "255 200 100 255");
    l.__KeyValueFromFloat("distance", 400);
    l.__KeyValueFromFloat("spotlight_radius", 0);
    try { l.Spawn(); l.Activate(); } catch(e) {}
    DoEntFire("!self", "Kill", "", 2.5, null, l);
    return true;
}

// 17. envglow 发光球 (env_glow; scale 同样按 2^N ≤64)
::ASRD_FX_envglow <- function(hPlayer, m, pos)
{
    local g = null;
    try { g = Entities.CreateByClassname("env_glow"); } catch(e) { g = null; }
    if (g == null) return false;
    g.SetOrigin(pos + Vector(0, 0, 60));
    g.__KeyValueFromString("model", "sprites/light_glow03.vmt");
    g.__KeyValueFromInt("scale", 2);
    g.__KeyValueFromString("rendercolor", "100 200 255");
    g.__KeyValueFromInt("renderamt", 255);
    try { g.Spawn(); g.Activate(); } catch(e) {}
    DoEntFire("!self", "Kill", "", 2.0, null, g);
    return true;
}

// 18. spot 聚光灯 (用已验证生效的 light_dynamic 加窄锥角实现, point_spotlight 在 AS:RD 常未注册)
::ASRD_FX_spot <- function(hPlayer, m, pos)
{
    local s = null;
    try { s = Entities.CreateByClassname("light_dynamic"); } catch(e) { s = null; }
    if (s == null) return false;
    s.SetOrigin(pos + Vector(0, 0, 80));
    s.__KeyValueFromString("_light", "255 255 255 255");
    s.__KeyValueFromFloat("distance", 400);
    s.__KeyValueFromFloat("_cone", 23);       // 内锥角: 聚光收窄
    s.__KeyValueFromFloat("_cone2", 30);      // 外锥角: 柔和边缘
    s.__KeyValueFromFloat("_inner_cone_angle", 10);
    s.__KeyValueFromFloat("spotlight_radius", 40);
    s.__KeyValueFromInt("spawnflags", 1);
    try { s.Spawn(); s.Activate(); } catch(e) {}
    DoEntFire("!self", "TurnOn", "", 0.0, null, s);
    DoEntFire("!self", "Kill", "", 2.5, null, s);
    return true;
}

// 19. fire 火焰 (env_fire; fireattack=0 纯视觉不烧人)
::ASRD_FX_fire <- function(hPlayer, m, pos)
{
    local f = null;
    try { f = Entities.CreateByClassname("env_fire"); } catch(e) { f = null; }
    if (f == null) return false;
    f.SetOrigin(pos);
    f.__KeyValueFromInt("health", 10);
    f.__KeyValueFromInt("firesize", 80);
    f.__KeyValueFromInt("fireattack", 0);
    f.__KeyValueFromInt("StartOn", 1);
    try { f.Spawn(); f.Activate(); } catch(e) {}
    DoEntFire("!self", "StartFire", "", 0.0, null, f);
    DoEntFire("!self", "Kill", "", 2.0, null, f);
    return true;
}

// 20. smoke 烟柱 (env_smokestack)
::ASRD_FX_smoke <- function(hPlayer, m, pos)
{
    local s = null;
    try { s = Entities.CreateByClassname("env_smokestack"); } catch(e) { s = null; }
    if (s == null) return false;
    s.SetOrigin(pos + Vector(0, 0, 30));
    s.__KeyValueFromInt("BaseSpread", 20);
    s.__KeyValueFromInt("SpreadSpeed", 30);
    s.__KeyValueFromInt("StartSize", 20);
    s.__KeyValueFromInt("EndSize", 60);
    s.__KeyValueFromString("SmokeMaterial", "particle/particle_smokegrenade.vmt");
    s.__KeyValueFromString("rendercolor", "200 200 200");
    s.__KeyValueFromInt("renderamt", 150);
    s.__KeyValueFromInt("StartOn", 1);
    try { s.Spawn(); s.Activate(); } catch(e) {}
    DoEntFire("!self", "Kill", "", 3.0, null, s);
    return true;
}

// 21. overlay 全屏遮罩 (env_screenoverlay; 材质可能不显示, 实测项)
::ASRD_FX_overlay <- function(hPlayer, m, pos)
{
    local o = null;
    try { o = Entities.CreateByClassname("env_screenoverlay"); } catch(e) { o = null; }
    if (o == null) return false;
    o.__KeyValueFromString("OverlayName", "models/effects/portalfx_halo");
    try { o.Spawn(); o.Activate(); } catch(e) {}
    DoEntFire("!self", "StartOverlay", "", 0.0, null, o);
    DoEntFire("!self", "StopOverlay", "", 2.0, null, o);
    DoEntFire("!self", "Kill", "", 2.2, null, o);
    return true;
}

// 22. fadefx 全屏淡入淡出 (env_fade 实体; 与 ScreenFade 机制不同, 若闪退请停用)
::ASRD_FX_fadefx <- function(hPlayer, m, pos)
{
    local f = null;
    try { f = Entities.CreateByClassname("env_fade"); } catch(e) { f = null; }
    if (f == null) return false;
    f.__KeyValueFromFloat("duration", 1.0);
    f.__KeyValueFromFloat("holdtime", 0.5);
    f.__KeyValueFromString("rendercolor", "255 255 255");
    f.__KeyValueFromInt("renderamt", 180);
    try { f.Spawn(); f.Activate(); } catch(e) {}
    DoEntFire("!self", "Fade", "", 0.0, null, f);
    DoEntFire("!self", "Kill", "", 2.0, null, f);
    return true;
}

// 23. infoparticle 实体版粒子 (info_particle_system)
::ASRD_FX_infoparticle <- function(hPlayer, m, pos)
{
    local p = null;
    try { p = Entities.CreateByClassname("info_particle_system"); } catch(e) { p = null; }
    if (p == null) return false;
    p.SetOrigin(pos);
    p.__KeyValueFromString("effect_name", "asw_env_explosion");
    p.__KeyValueFromInt("start_active", 1);
    try { p.Spawn(); p.Activate(); } catch(e) {}
    DoEntFire("!self", "Start", "", 0.0, null, p);
    DoEntFire("!self", "Kill", "", 2.5, null, p);
    return true;
}

// ============================================================================
//  特效注册表 + 命令分发
// ============================================================================

::g_ASRD_FX_List <- {
    spark        = { fn = ::ASRD_FX_spark,       desc = "火花 env_spark(已验证)" },
    boom         = { fn = ::ASRD_FX_boom,        desc = "光爆 env_explosion(已验证)" },
    sprite       = { fn = ::ASRD_FX_sprite,      desc = "发光点 env_sprite(已验证)" },
    glowte       = { fn = ::ASRD_FX_glowte,      desc = "客户端光粒 TempEnts(已验证)" },
    redfade      = { fn = ::ASRD_FX_redfade,     desc = "屏幕红闪 ScreenFade(已验证)" },
    center       = { fn = ::ASRD_FX_center,      desc = "中央大字 ClientPrint(已验证)" },
    sound        = { fn = ::ASRD_FX_sound,       desc = "音效 EmitSound(已验证)" },
    fxtimer      = { fn = ::ASRD_FX_fxtimer,     desc = "连续火花 logic_timer(已验证)" },
    pboom        = { fn = ::ASRD_FX_pboom,       desc = "粒子爆炸(官方API待验)" },
    pzap         = { fn = ::ASRD_FX_pzap,        desc = "粒子电击闪光(pcf确认)" },
    ptesla       = { fn = ::ASRD_FX_ptesla,      desc = "粒子电弧(pcf确认)" },
    pflare       = { fn = ::ASRD_FX_pflare,      desc = "粒子闪光(pcf确认)" },
    pbeam        = { fn = ::ASRD_FX_pbeam,       desc = "粒子光束(pcf确认)" },
    sndtable     = { fn = ::ASRD_FX_sndtable,    desc = "带参数音效 EmitSoundTable(官方API待验)" },
    beam         = { fn = ::ASRD_FX_beam,        desc = "激光光束 env_beam(需实测)" },
    light        = { fn = ::ASRD_FX_light,       desc = "动态光源 light_dynamic(需实测)" },
    envglow      = { fn = ::ASRD_FX_envglow,     desc = "发光球 env_glow(需实测)" },
    spot         = { fn = ::ASRD_FX_spot,        desc = "聚光灯 point_spotlight(需实测)" },
    fire         = { fn = ::ASRD_FX_fire,        desc = "火焰 env_fire(需实测)" },
    smoke        = { fn = ::ASRD_FX_smoke,       desc = "烟柱 env_smokestack(需实测)" },
    overlay      = { fn = ::ASRD_FX_overlay,     desc = "全屏遮罩 env_screenoverlay(需实测)" },
    fadefx       = { fn = ::ASRD_FX_fadefx,      desc = "全屏淡入淡出 env_fade(需实测)" },
    infoparticle = { fn = ::ASRD_FX_infoparticle, desc = "实体版粒子 info_particle_system(需实测)" },
};

::ASRD_FX_Dispatch <- function(hPlayer, args)
{
    local arg = ASRD_FX_Trim(args);
    if (arg == "" || arg == "help" || arg == "?")
    {
        ClientPrint(hPlayer, 3, "[特效] 用法: /fx list | /fx stop | /fx <特效名> [玩家名]");
        return;
    }
    local lower = arg.tolower();
    if (lower == "list")
    {
        // TextMsg 单条上限 511 字节(UTF-8, 中文占 3 字节), 分组发送避免整条被拒收
        local keys = [], descs = [];
        foreach (k, v in ::g_ASRD_FX_List)
        {
            keys.append(k);
            descs.append(v.desc);
        }
        local perMsg = 6;
        local total = keys.len();
        local pages = (total + perMsg - 1) / perMsg;
        for (local i = 0; i < total; i += perMsg)
        {
            local out = "[特效清单 " + (i / perMsg + 1) + "/" + pages + "] ";
            for (local j = i; j < i + perMsg && j < total; j++)
            {
                if (j > i) out += " | ";
                out += keys[j] + "=" + descs[j];
            }
            ClientPrint(hPlayer, 3, out);
        }
        return;
    }
    if (lower == "stop")
    {
        ::ASRD_FX_StopAll();
        return;
    }

    local sp = arg.find(" ");
    local fxName = (sp == null) ? lower : lower.slice(0, sp);
    local targetText = (sp == null) ? "" : ASRD_FX_Trim(arg.slice(sp + 1));

    if (!(fxName in ::g_ASRD_FX_List))
    {
        ClientPrint(hPlayer, 3, "[特效] 未知特效 \"" + fxName + "\"，输入 /fx list 查看全部");
        return;
    }

    local hTarget = hPlayer;
    if (targetText != "")
    {
        local t = ASRD_FX_FindPlayer(targetText);
        if (t == null)
            ClientPrint(hPlayer, 3, "[特效] 未找到玩家 \"" + targetText + "\"，改在你位置播放");
        else
            hTarget = t;
    }

    local marine = ASRD_FX_GetMarine(hTarget);
    local pos = ASRD_FX_GetPos(marine, hTarget);
    local ok = false;
    try { ok = ::g_ASRD_FX_List[fxName].fn(hTarget, marine, pos); } catch(e) { ok = false; }
    ClientPrint(hPlayer, 3, "[特效] /fx " + fxName + " → " + (ok ? "已触发(持续型自动清理)" : "触发失败(看服务器控制台)"));
}
