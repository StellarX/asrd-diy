// ============================================================
//  AS:RD 积分挑战  (纯 VScript, 无需 SourceMod)
//
//  玩法:
//    - 击杀虫族获得全队共享积分 (按虫族最大血量 x 5%)
//    - 聊天框 #buy / #1..#9 购买, 与 SourceMod 积分插件一致
//    - 默认开启护送模式: 开局立即随机指定护送对象 (VIP), 其最大生命减半;
//      本版本 (C5) 无倒地状态: 任何玩家血量归零直接阵亡, VIP 阵亡 = 任务失败
//    - 定向刷虫: 每隔 20~40 秒 (随机) 刷一波精英 (任务节点期间 5 秒),
//      从 6 种精英中随机一种 (红巨/电甲/蓝巨/追踪/自爆/寄生);
//      用 SpawnAlienAuto 实时生成于引擎合法 nav 点, 与原版 horde 节奏解耦;
//      刷怪点远离玩家且不在视线内
//    - 保留自动空投 (每 120 秒随机一件)
//    - 自动力场护盾: 任一存活玩家血量 < 30 时, 血量最低者获得 5 秒
//      斥力护盾 (弹开近身虫族); 全队共享 120 秒冷却
//
//  命令:
//    #buy           显示帮助
//    #buy 1 / #1    全队强化等级 +1        (500)
//    #buy 2 / #2    强化核弹 (全图)        (200, 30s 冷却)
//    #buy 4 [0/1]   哨戒塔箱 0=机枪 1=炮塔 (300)
//    #buy 6 [1-5]   武器                   (300)
//    #buy 7         动力护甲               (300)
//    #buy 9         弹药掉落               (100)
// ============================================================

// ── 积分 ────────────────────────────────────────────────
POINTS_START        <- 1000;
POINTS_HP_SCALE     <- 0.01;      // 击杀得分 = 最大血量 x 该比例, 至少 1 分
POINTS_AUTO_INTERVAL<- 120.0;     // 自动空投间隔(秒)

// ── 价格 ────────────────────────────────────────────────
COST_POWER   <- 500;
COST_NUKE    <- 200;
COST_SENTRY  <- 300;
COST_WEAPON  <- 300;
COST_ARMOR   <- 300;
COST_AMMO    <- 100;

// ── 强化等级 ────────────────────────────────────────────
POWER_MAX_LEVEL   <- 5;
POWER_HP_STEP     <- 50;    // 每级 +50 最大血量
POWER_SCALE_STEP  <- 0.1;   // 每级体型 +0.1
POWER_SPEED_STEP  <- 0.1;   // 每级移速 +0.1
CAM_BASE          <- 412;   // 视角高度基准相机距离 (游戏原生默认)
CAM_STEP          <- 25;    // 每级视角抬升 (asw_cam_marine_dist, 全服统一)
MELEE_MULT        <- [1.0, 2.0, 4.0, 8.0, 16.0, 32.0];   // 等级 0~5 近战倍率

// ── 核弹 ────────────────────────────────────────────────
NUKE_DELAY    <- 3.0;
NUKE_COOLDOWN <- 30.0;
NUKE_DAMAGE   <- 999999.0;
NUKE_CLASSES <- [
	"asw_drone", "asw_drone_jumper", "asw_drone_uber", "asw_drone_antlion",
	"asw_parasite", "asw_parasite_defanged", "asw_egg",
	"asw_boomer", "asw_boomer_blob", "asw_buzzer",
	"asw_harvester", "asw_mortarbug", "asw_ranger", "asw_shieldbug",
	"asw_grub", "asw_grub_sac", "asw_queen", "asw_mender", "asw_shaman",
	"asw_xenomite", "asw_antlion_guard",
	"npc_antlionguard", "npc_antlionguard_cavern", "npc_antlionguard_normal", "npc_antlion_worker"
];

// ── 自动力场护盾 (原 asrd_points 联动 asrd_repulse 的自动护盾) ──
SHIELD_HP_THRESHOLD <- 30;      // 任一存活玩家血量低于此值触发
SHIELD_COOLDOWN     <- 120.0;   // 全队共享冷却 (护盾真正加上后才开始计时)
SHIELD_DURATION     <- 5.0;     // 护盾作用时长
SHIELD_RADIUS       <- 300.0;   // 斥力半径
SHIELD_PUSH_SPEED   <- 1000.0;  // 弹开虫族的速度

// ── 护送 ────────────────────────────────────────────────
ESCORT_HP_RATIO           <- 0.5;
// VIP 阵亡后延迟结算: 引擎 MissionComplete(false) 会立即 SetGameState(ASW_GS_DEBRIEF)
// (asw_gamerules.cpp:4955), 瞬间切到结算界面; 这里留出时间让玩家看到失败提示
ESCORT_FAIL_DELAY         <- 5.0;
// VIP 滑倒 (娱乐效果, 移植自 slip.nut): 每 2~5 分钟随机挑 1 名存活护送目标摔倒
SLIP_MIN_INTERVAL         <- 120.0;
SLIP_MAX_INTERVAL         <- 300.0;
SLIP_PUSH_SPEED           <- 700.0;  // 前冲速度 (slip.nut 原值 700)
SLIP_PUSH_UP              <- 300.0;  // 上抛速度 (slip.nut 原值 300)

// ── 定向刷虫压力 (护送) ─────────────────────────────────
// 用 Director.SpawnAlienAuto 在引擎合法 nav 点实时生成普通虫 (不碰 horde 计时器,
// 与原版刷怪解耦; 引擎选点带路线校验, 绝不卡墙/卡地板), 再把虫变异成精英
// (改染色/体型/血量/特效, 见 drone_mutation 同款做法)
PRESSURE_MIN_INTERVAL <- 20.0;    // 刷虫间隔: 20~40 秒随机
PRESSURE_MAX_INTERVAL <- 40.0;
// 任务节点 (黑客/开门) 期间的高频刷虫
PRESSURE_RUSH_INTERVAL <- 5.0;    // 任务节点期间: 每 5 秒一波 (替代 20~40)
RUSH_WINDOW_SECONDS    <- 15.0;  // 事件型节点 (按钮/焊接门) 触发的高频窗口时长
//  可检测信号: asw_button_area.m_fHackProgress (0<x<1 = 正在黑客) / m_bIsInUse
//  (asw_button_area.cpp:64-66 是 SendProp, VScript 可读);
//  OnGameEvent_button_area_used / door_welded / door_unwelded 事件开窗口。
//  门的 m_eDoorState 非 SendProp, VScript 读不到"正在开门", 故纯等待用事件窗口近似。
ELITE_HP              <- 400;     // 电甲爪虫血量 (红巨爪/蓝巨虫 各有独立血量, 见下)
RED_GIANT_HP          <- 500;     // 红巨爪虫血量
BLUE_GIANT_HP         <- 2000;    // 蓝巨虫血量
BLUE_GIANT_SPEED_MULT <- 0.7;     // 蓝巨虫移速倍率 (m_fSpeedScale, 原版 0.7 倍)
TRACKER_HP            <- 250;     // 追踪虫血量
TRACKER_SPEED_MULT    <- 2.0;     // 追踪虫移速倍率 (m_fSpeedScale, 原版 2 倍)
TRACKER_DMG_MULT      <- 2.0;     // 追踪虫攻击力倍数 (近战伤害, 走 OnTakeDamage_Alive_Any 钩子)
ELITE_NAMES           <- ["追踪虫", "红巨爪虫", "电甲爪虫", "蓝巨虫", "自爆虫", "寄生虫"];
ELITE_WAVE_MIN        <- 5;       // 每波精英数量下限
ELITE_WAVE_MAX        <- 10;      // 每波精英数量上限
BOOMER_WAVE_MIN       <- 2;       // 自爆虫波数量下限 (炮弹太多会卡, 单独压低)
BOOMER_WAVE_MAX       <- 5;       // 自爆虫波数量上限
BOOMER_SCALE          <- 2.0;     // 自爆虫体型倍数
BOOMER_HP             <- 5000;    // 自定义精英自爆虫血量 (仅脚本 MutateElite 变异体, 不改原版 asw_boomer_health)
BOOMER_MELEE_DMG      <- 200.0;   // 精英自爆虫脚踢固定伤害 (原版 sk_asw_boomer_melee_damage 4~6)
                                  // 小炸弹爆炸伤害保持原版 55, 钩子里遇 DMG_BLAST 直接原样放过
BOOMER_EXTRA_BLOBS    <- 54;      // 自爆虫死亡时额外生成的炮弹数 (引擎最多 8 只, 8+54=62)
// 脚本补的炮弹要对齐引擎炮弹数值, 否则会走 CASW_Boomer_Blob::Spawn 的默认值 80 伤害 / 165 半径
// (asw_boomer_blob.cpp:71-72); 引擎走的是 Boomer_Blob_Create 传入的
// sk_asw_boomer_bomb_damage(默认 55) 与 keyvalue radius(240) (asw_boomer.cpp:317-318)
BOOMER_BLOB_DAMAGE    <- 55.0;    // 原版炮弹伤害
BOOMER_BLOB_RADIUS    <- 240.0;   // 原版炮弹爆炸半径

// ── 哨戒塔增强 (原 asrd_sentry_enhancer 复刻) ─────────────
// 伤害 x2: m_fDamageScale 未注册 netprop/datamap 无法脚本写,
//          机枪/喷火走 OnTakeDamage 钩子 x2, 炮塔走 txt 下发 asw_sentry_top_cannon_dmg_override 120 (60x2)
// 弹药 x4: m_iMaxAmmo/m_iAmmo 网络属性直接写 (原版 机枪450/炮40, 见原插件 GetSentryMaxAmmo)
// 射速 x3: 炮口 m_fNextFireTime (datamap FIELD_TIME) 间隔压缩为 1/3
SENTRY_DMG_MULT       <- 2.0;
SENTRY_AMMO_MULT      <- 4;
SENTRY_RATE_MULT      <- 3.0;
SENTRY_MG_AMMO        <- 450;    // 机枪塔原版满弹药 (拾取箱 BulletsInGun 必须写满, 默认 1 会导致部署提示弹药耗尽)
SENTRY_CANNON_AMMO    <- 40;     // 炮塔原版满弹药
// 部署/拆卸加速 (引擎两个时长都是编译期常量, 没有对应 convar, 只能写网络属性绕过):
//   装配时长 #define SENTRY_ASSEMBLE_TIME 7.0f      (asw_sentry_base.cpp:307)
//   拆卸按住时长 #define ASW_USE_KEY_HOLD_SENTRY_TIME 2.0 (asw_player_shared.h:20)
SENTRY_FAST_ASSEMBLE      <- 0.999;  // 装配进度预置值, 按住 E 后第一拍即满
SENTRY_DISMANTLE_HOLD     <- 0.25;   // 按住超过该秒数才视为"要拆卸" (轻点仍为旋转炮塔)
SENTRY_DISMANTLE_BACKDATE <- 3.0;    // 把 m_flUseKeyDownTime 前推到 now-3.0, 一定超过 2.0 秒阈值
ZAP_RADIUS      <- 70.0;    // 电甲爪虫触电半径
ZAP_DAMAGE      <- 8.0;     // 每次触电伤害
ZAP_INTERVAL    <- 1.0;     // 同一只电甲虫的触电间隔

// ── 护甲 ────────────────────────────────────────────────
ARMOR_CLASS       <- "asw_weapon_normal_armor";
ARMOR_LAYERS      <- 10;
ARMOR_HIT_SCALE   <- 0.2;   // 有层时实受伤害倍率 (减伤 80%); 0 层实受 100%
ARMOR_SPEED_BONUS <- 1.3;
ARMOR_REGEN       <- 2.0;

// ── 武器/道具 (增强效果复刻原 SourceMod 插件, 见 challenges/asrd_points.txt convars 块) ──
// 伤害增强由引擎 ConVar 全局下发 (官方 traitors 挑战同款做法):
//   电锯 rd_chainsaw_dmg_base=600 (原插件掉落电锯 x10), 守望者 sk_plr_dmg_ar2=30 (原 x2),
//   导轨 rd_railgun_dmg_base=210 (基础翻倍), AVK36 asw_skill_accuracy_sniper_rifle_dmg_base=65,
//   黏弹 asw_skill_grenades_flechette_dmg_base=50 (原插件默认 50)
// 此处负责: 掉落武器染色标记 (引擎会周期性复位 m_clrRender, 故每拍重涂),
//           拾取时弹匣/备弹写满 (m_iClip1/m_iClip2/m_iPrimaryAmmoCount/m_iSecondaryAmmoCount),
//           增强电锯按住攻击键时锯片转速 x3 (原 asrd_chainsaw_turbo 的 m_flPlaybackRate 方案)
WEAPON_ENH <- {
	asw_weapon_chainsaw     = { tint = [255, 255, 255], clip1 = -1,   clip2 = -1,  ammo1 = -1,  ammo2 = -1  },   // 纯白染色 (原插件默认)
	asw_weapon_ar2          = { tint = [0, 200, 255],   clip1 = 200,  clip2 = 10,  ammo1 = 200, ammo2 = 10  },   // 青色染色; 弹匣 200 + 备弹 200 = 共 2 个弹匣
	asw_weapon_flechette    = { tint = null,            clip1 = 60,   clip2 = -1,  ammo1 = 60,  ammo2 = -1  },
	asw_weapon_railgun      = { tint = null,            clip1 = 36,   clip2 = -1,  ammo1 = 36,  ammo2 = -1  },
	asw_weapon_sniper_rifle = { tint = null,            clip1 = 12,   clip2 = -1,  ammo1 = 60,  ammo2 = -1  }
};
CHAINSAW_TURBO_MULT <- 3.0;   // 增强电锯按住攻击键时的锯片转速倍率 (原插件 sm_asrd_chainsaw_speed 默认 3.0)
RAILGUN_FIRE_INTERVAL <- 0.2; // 导轨步枪两次射击最小间隔 (原服务器配置 sm_asrd_railgun_fire_interval 0.2)
AR2_BALL_DAMAGE      <- 10000.0; // 守望者下挂能量球 (prop_combine_ball) 单发伤害
CHAINSAW_DAMAGE_MULT <- 10.0; // 增强电锯伤害倍率 (原插件默认; 仅掉落标记电锯生效, 经伤害钩子)

// ── Laidback Potato 弹药机制 (移植自 challenge_laidback_potato__inc_vars.nut) ──
// 弹匣永远补满的武器 (照搬 Potato 的 infWeapon, 只去掉 sniper_rifle:
// AVK-36 保留本挑战自己的 12 发弹匣 + 60 发备弹设定, 不走无限弹匣)
PO_INF_WEAPON <- {
	asw_weapon_rifle = 1, asw_weapon_vindicator = 1, asw_weapon_prifle = 1,
	asw_weapon_50calmg = 1, asw_weapon_autogun = 1, asw_weapon_deagle = 1,
	asw_weapon_pdw = 1, asw_weapon_ricochet = 1, asw_weapon_tesla_gun = 1,
	asw_weapon_medrifle = 1, asw_weapon_heavy_rifle = 1, asw_weapon_combat_rifle = 1,
	asw_weapon_pistol = 1, asw_weapon_minigun = 1
};
// 慢速回填: 数值 = 补满一次弹匣需要的秒数 (每发间隔 = 0.1 + 数值 / 总备弹)
PO_REGEN_INTERVAL <- {
	asw_weapon_mines = 125, asw_weapon_electrified_armor = 95, asw_weapon_freeze_grenades = 70,
	asw_weapon_grenades = 50, asw_weapon_laser_mines = 75, asw_weapon_tesla_trap = 40,
	asw_weapon_hornet_barrage = 130, asw_weapon_heal_grenade = 60, asw_weapon_gas_grenades = 125,
	asw_weapon_stim = 130, asw_weapon_buff_grenade = 105, asw_weapon_devastator = 10,
	asw_weapon_pistol = 20, asw_weapon_grenade_launcher = 50, asw_weapon_shotgun = 10,
	asw_weapon_medical_satchel = 30, asw_weapon_medkit = 30, asw_weapon_jump_jet = 100,
	asw_weapon_blink = 50, asw_weapon_fire_extinguisher = 25, asw_weapon_flechette = 50,
	asw_weapon_mining_laser = 2, asw_weapon_flashlight = 0, asw_weapon_night_vision = 0,
	asw_weapon_bait = 100, asw_weapon_flares = 100
};
// 单弹匣武器的弹匣上限覆盖 (照搬 Potato 的 ammoCount)
PO_AMMO_COUNT <- {
	asw_weapon_mines = 3, asw_weapon_electrified_armor = 3, asw_weapon_freeze_grenades = 3,
	asw_weapon_grenades = 5, asw_weapon_laser_mines = 9, asw_weapon_tesla_trap = 8,
	asw_weapon_hornet_barrage = 2, asw_weapon_medkit = 5, asw_weapon_heal_grenade = 6,
	asw_weapon_gas_grenades = 3, asw_weapon_stim = 2, asw_weapon_buff_grenade = 3,
	asw_weapon_medical_satchel = 30, asw_weapon_sentry = 2105, asw_weapon_devastator = 200,
	asw_weapon_pistol = 300, asw_weapon_flamer = 70, asw_weapon_grenade_launcher = 30,
	asw_weapon_shotgun = 16, asw_weapon_mining_laser = 33, asw_weapon_fire_extinguisher = 140
};
// 副弹匣 (下挂榴弹/手雷) 回填间隔与上限 (照搬 Potato 的 regenInterval2 / undCount)
PO_REGEN_INTERVAL2 <- {
	asw_weapon_rifle = 8, asw_weapon_prifle = 9, asw_weapon_vindicator = 9,
	asw_weapon_combat_rifle = 1, asw_weapon_heavy_rifle = 5
};
PO_UND_COUNT <- {
	asw_weapon_rifle = 5, asw_weapon_prifle = 5, asw_weapon_vindicator = 6,
	asw_weapon_combat_rifle = 5, asw_weapon_heavy_rifle = 5
};
// 开火后多久才开始回填 (照搬 Potato 的 regenDelay; 表内没有的武器默认 5 秒)
PO_REGEN_DELAY <- {
	asw_weapon_mines = 0, asw_weapon_electrified_armor = 0, asw_weapon_freeze_grenades = 0,
	asw_weapon_grenades = 0, asw_weapon_laser_mines = 0, asw_weapon_tesla_trap = 0,
	asw_weapon_hornet_barrage = 0, asw_weapon_heal_grenade = 0, asw_weapon_gas_grenades = 0,
	asw_weapon_stim = 0, asw_weapon_buff_grenade = 0, asw_weapon_medkit = 0,
	asw_weapon_medical_satchel = 0, asw_weapon_jump_jet = 0, asw_weapon_blink = 0,
	asw_weapon_flashlight = 0, asw_weapon_bait = 0, asw_weapon_night_vision = 0,
	asw_weapon_flares = 0
};
PO_DEFAULT_REGEN_DELAY <- 5.0;   // 表外武器 (枪械类) 开火后 5 秒延迟
PO_REFILL_TICK         <- 0.1;    // 回填检查间隔 (秒)
PO_SINGLE_CLIP_PENALTY <- 0.55;   // 单弹匣武器弹匣容量惩罚
PO_NOCLIP_PENALTY      <- 4;      // 弹匣数低于该值时套用上面的惩罚

WEAPONS      <- ["asw_weapon_chainsaw", "asw_weapon_ar2", "asw_weapon_flechette", "asw_weapon_railgun", "asw_weapon_sniper_rifle"];
WEAPON_NAMES <- ["增强型电锯", "守望者脉冲步枪", "增强型黏弹发射器", "导轨步枪", "AVK-36 神射手步枪"];

// 自动空投 (与原积分插件当前候选一致; 电锯不启用高速旋转)
AUTO_DROPS <- [
	{ cls = "asw_weapon_chainsaw",       name = "增强型电锯" },
	{ cls = "asw_weapon_ar2",            name = "守望者脉冲步枪" },
	{ cls = "asw_weapon_railgun",        name = "导轨步枪" },
	{ cls = "asw_weapon_sniper_rifle",   name = "AVK-36 神射手步枪" },
	{ cls = "asw_weapon_flechette",      name = "增强型黏弹发射器" },
	{ cls = "asw_weapon_jump_jet",       name = "喷气背包" }
];

// ── HUD ────────────────────────────────────────────────
// rd_hud_vscript 每个实体仅支持 1 个字符串 (索引 0, 见 rd_hud_vscript_shared.cpp),
// 故每行一个实体。行数动态: 0 积分 / 1 强化 / 2 护甲 / 3.. 护送 (每位 VIP 独占一行,
// 多 VIP 时换行显示) / 末行 护盾。护送人数变化时 EnsureHuds 整组重建。
function HudLineNeed()
{
	local n = g_escorts.len();
	if (n < 1)
	{
		n = 1;   // 无护送目标时保留 1 个护送空行, 行结构稳定
	}
	return 4 + n;
}

// ── 运行时状态 ──────────────────────────────────────────
g_points       <- POINTS_START;
g_huds         <- {};       // player entindex -> [HudLineNeed() 个 rd_hud_vscript]
g_hudAt        <- 0.0;
g_powerAt      <- 0.0;
g_lastTick     <- 0.0;
g_nextAutoDrop <- 0.0;
g_nukeAt       <- 0.0;
g_nukeReadyAt  <- 0.0;
// 护送目标集合: marine 实体句柄 -> { player, name, downAt, usedDown }
// 人数: 开局随机 1 ~ floor(玩家数/3); 选人: 完全随机
g_escorts      <- {};
g_escortDone   <- false;
g_failBroadcasted <- false;    // 失败播报去重: VIP 阵亡与引擎 mission_failed 都可能触发, 只播一次
g_escortPicked <- false;    // 是否已完成过开局点名 (true 后护送名单清空 = 补选场景, 只补 1 名)
g_escortFailAt <- -1.0;     // VIP 阵亡后延迟结算的触发时刻 (-1=无待结算失败)
g_pressureAt   <- 0.0;      // 下一次定向刷虫时刻
g_rushUntil    <- 0.0;      // 任务节点高频刷虫窗口到期时刻 (事件型; 0=无窗口)
g_slipAt       <- 0.0;      // 下一次 VIP 滑倒时刻 (2~5 分钟随机)
g_pressureWave <- 0;        // 已刷波数 (决定每波数量)
g_zappers      <- {};       // 电甲爪虫 entindex -> 下次触电时刻
g_shieldEnd    <- {};       // marine entindex -> 护盾结束时刻
g_shieldReadyAt<- 0.0;      // 全队共享的护盾冷却截止时刻
g_camDist      <- -1;       // 已下发的相机距离 (-1=未下发)
g_eliteIdx     <- {};       // 已变异精英的 entindex -> true (防重复变异)
g_mutatePending<- 0;        // 本波待变异的精英数量 (引擎 horde 刷出后逐只变异)
g_mutateType   <- 0;        // 本波精英种类 (每波同一种, 波次轮换 6 种, 寄生虫也在其中)
g_trackers     <- {};       // 追踪虫 entindex -> true (每拍强制仇恨指向最近存活要员)
g_trackersAt   <- 0.0;      // 追踪虫仇恨刷新节流
g_tintWpn      <- {};       // 需每拍重涂染色的实体 entindex -> {r,g,b} (增强武器)
g_sentryEnh    <- {};       // 哨戒塔底座 entindex -> true (弹药已 x4 增强)
g_sentryFire   <- {};       // 哨戒塔炮口 entindex -> 上次压缩后的 m_fNextFireTime (射速 x3 用)
g_boomers      <- {};       // 精英自爆虫 entindex -> true (死亡瞬间补生成 BOOMER_EXTRA_BLOBS 只炮弹)
g_boomerEnt    <- {};       // 精英自爆虫 entindex -> 实体句柄 (TickBoomerDeaths 兜底检测死亡)
g_boomerPos    <- {};       // 精英自爆虫 entindex -> 最后一个存活位置
g_paraPending  <- 0;        // 待替换的寄生虫数量 (引擎 horde 刷出普通虫后逐只 Kill 原位换成寄生虫)
g_paraExpireAt <- 0.0;      // 寄生虫替换超时 (超时清零防卡 pending)
g_boomerPending<- 0;        // 待替换成自爆虫的数量 (引擎 horde 刷出普通虫后逐只 Kill 原位换成 asw_boomer)
g_boomerExpireAt<- 0.0;     // 自爆虫替换超时
g_redPending   <- 0;        // 待替换成红巨爪虫的数量 (需新建实体才能关掉 flinchable, 见 TickMutate)
g_redExpireAt  <- 0.0;      // 红巨爪虫替换超时
g_lastMutateType<- -1;      // 上一波精英种类 (随机时避免连续重复)
g_balls        <- {};       // 能量球 prop_combine_ball entindex -> 上一拍位置 (爆炸时给门补足伤害)
g_rockets      <- {};       // 黏弹火箭 asw_rocket entindex -> 上一拍位置
g_railClip     <- {};       // 导轨步枪 entindex -> 上一拍弹匣数 (检测开火)
g_railFireAt   <- {};       // 导轨步枪 entindex -> 上次开火时刻
g_armorHinted  <- {};       // 已提示过护甲功能的 marine entindex -> true
g_regenAccum   <- {};       // 护甲回血浮点累积: marine entindex -> float (攒够 1 点再加)
g_armorMissing <- {};       // 护甲击前"已损失层数"缓存: marine entindex -> m_iLayersMissing (0..10)
                            // 引擎先扣层再触发脚本钩子 (asw_marine.cpp:1996 -> 1655), 钩子读到的
                            // m_iLayersMissing 已扣过, 故用上一拍缓存的击前值判定: pre<10 = 还有层。
g_nukeText     <- null;     // 核弹倒计时 game_text 实体 (全员可见红字)
g_nukeEtaShown <- -1;       // 已显示的倒计时秒数 (避免重复刷新)
// Laidback Potato 弹药回填状态
g_poNext       <- {};       // weapon entindex -> 下次回填时刻 (弹匣)
g_poLast       <- {};       // weapon entindex -> 上次看到的弹匣数
g_poNext2      <- {};       // weapon entindex -> 下次回填时刻 (副弹匣)
g_poLast2      <- {};       // weapon entindex -> 上次看到的副弹匣数
g_poAt         <- 0.0;      // 回填节流时刻

// ============================================================
//  入口: 挑战脚本加载时执行
//  注意: ConVar 统一由 resource/challenges/asrd_points.txt 下发 (官方机制),
//        此处顶层只保留无风险语句, 其余初始化推迟到首次 Update
// ============================================================
g_errShown <- {};   // 子系统名 -> true (同一错误只打印一次)
g_booted   <- false;
g_bootAt   <- 0.0;      // 开局玩法广播/购买说明的生成时刻 (0=已完成)

// ── 任务结束清理 ──────────────────────────────────────────
// 挑战脚本绑定在 asw_challenge_thinker 上, 换图时该实体销毁、脚本作用域重建
// (asw_gamerules_vscript.cpp:1297-1350), 引擎没有 shutdown 回调。
// mission_success / mission_failed 在换图前触发 (asw_gamerules.cpp:4781/4797),
// 是可靠的清理时机: 任务结束后停掉主循环并清掉自定义实体, 不再每帧操作实体。
g_finished <- false;    // true = 任务已结束, Update 不再创建或操作任何实体
g_objHelp  <- null;     // 购买说明 asw_objective_dummy 实体句柄 (原先是局部变量, 无法清理)

printl("[要员护送] 脚本加载成功, 等待主循环启动...");

// 子系统保护执行: 单个子系统报错不影响其他功能, 且同名错误只打印一次
function Guard(name, fn)
{
	try { fn(); }
	catch (e)
	{
		if (!(name in g_errShown))
		{
			g_errShown[name] <- true;
			printl("[要员护送] 错误@" + name + ": " + e);
		}
	}
}

// ============================================================
//  任务结束清理 (换图前调用, 避免自定义实体与失效句柄跨图残留)
//  mission_success / mission_failed 是唯一早于 Host_Changelevel 的回调时机
// ============================================================
function CleanupOnMissionEnd()
{
	// 1) 每名玩家的多行 HUD: rd_hud_vscript 带 client_vscript 引用, 数量最多
	foreach (idx, huds in g_huds)
	{
		if (huds == null)
		{
			continue;
		}
		foreach (h in huds)
		{
			if (h != null && h.IsValid())
			{
				try { DoEntFire("!self", "Kill", "", 0, null, h); } catch (e) {}
			}
		}
	}
	g_huds = {};

	// 2) 核弹倒计时 game_text
	NukeKillText();

	// 3) 任务详情里的购买说明 asw_objective_dummy
	if (g_objHelp != null)
	{
		if (g_objHelp.IsValid())
		{
			try { DoEntFire("!self", "Kill", "", 0, null, g_objHelp); } catch (e) {}
		}
		g_objHelp = null;
	}

	// 4) 清空持有实体句柄 / 实体索引的全局表, 不让失效引用随作用域一起销毁
	//    (其中 g_escorts 的 key、g_boomerEnt 的 value 是实体句柄)
	g_escorts     = {};
	g_boomerEnt   = {};
	g_boomerPos   = {};
	g_boomers     = {};
	g_trackers    = {};
	g_zappers     = {};
	g_shieldEnd   = {};
	g_tintWpn     = {};
	g_sentryEnh   = {};
	g_sentryFire  = {};
	g_balls       = {};
	g_rockets     = {};
	g_railClip    = {};
	g_railFireAt  = {};
	g_armorHinted = {};
	g_regenAccum  = {};
	g_armorMissing = {};
	g_poNext      = {};
	g_poLast      = {};
	g_poNext2     = {};
	g_poLast2     = {};
	g_eliteIdx    = {};

	g_bootAt     = 0.0;
	g_pressureAt = 0.0;
	g_rushUntil  = 0.0;
	g_slipAt     = 0.0;
	g_nukeAt     = 0.0;
	printl("[要员护送] 任务结束: 自定义实体已清理, 主循环已停止, 等待换图");
}

function FinishMission()
{
	if (g_finished)
	{
		return;   // 幂等: 成功与失败事件可能都来
	}
	g_finished = true;
	CleanupOnMissionEnd();
}

// 任务正常完成: 播报胜利 + 走统一收尾流程 (与 VIP 阵亡的 FailEscort 对称)
// 引擎 MissionComplete(true) 里先 fire mission_success 再切 debrief, 故在此广播
function SucceedMission()
{
	if (g_finished)
	{
		return;
	}
	g_escortDone = true;
	Broadcast("护送成功！VIP安全抵达，干得漂亮！");
	FinishMission();
}

// 换图会重建脚本作用域 (g_finished 初始即 false);
// 同一张图重试时由此恢复主循环与护送判定, 避免清理后玩法失效
function OnMissionStart()
{
	g_finished     = false;
	g_escortDone   = false;
	g_failBroadcasted = false;
	g_escortPicked = false;
	g_escorts      = {};
	g_booted       = false;   // 重新走一次开局广播 + 重建购买说明 (ResetPowerLevels 幂等)
}

// ============================================================
//  主循环 (返回下一次调用间隔, 秒)
// ============================================================
function Update()
{
	// 任务已结束: 不再创建或操作任何实体, 直到换图时作用域重建
	// (否则 mission 结束到 Host_Changelevel 之间仍会每帧重建 HUD / 刷虫 / 生成物品)
	if (g_finished)
	{
		return 0.001;
	}

	local now = Time();

	// 开局 5 秒后: 广播玩法说明 + 生成任务详情里的购买说明 (一次性)
	if (!g_booted)
	{
		g_booted = true;
		g_bootAt = now + 5.0;
		Guard("resetpower", ResetPowerLevels);
	}
	if (g_bootAt > 0 && now >= g_bootAt)
	{
		g_bootAt = 0.0;
		Guard("objhelp", SpawnBuyHelpObjectives);
	}

	EnsureHuds();
	UpdateHud(now);
	TickPower(now);
	TickArmor(now);
	TickArmorParasite();
	TickNuke(now);
	TickNukeEta(now);
	TickEnhancedWeapons(now);
	TickPotatoAmmo(now);
	TickRailgun(now);
	TickAutoDrop(now);
	TickShield(now);
	TickEscort(now);
	TickEscortFail(now);
	TickVipSlip(now);
	TickDownedRule();
	TickPressure(now);
	Guard("mutate", TickMutate);
	Guard("boomerdeath", TickBoomerDeaths);
	Guard("sentry", TickSentry);
	Guard("sentrybuild", TickSentryFastBuild);
	Guard("sentrydismantle", TickSentryFastDismantle);
	Guard("doorball", TickDoorBall);
	TickTrackers(now);
	TickZappers(now);

	g_lastTick = now;
	return 0.001;   // 远小于 tick 间隔 (0.0303s), 保证每 tick 都执行:
	               // 引擎帧序是 think(本 Update) 先于武器 ItemPostFrame, 每 tick 预钳
	               // m_flNextPrimaryAttack 才能拦住引擎每 tick 的开火检查
	               // (asw_weapon_shared.cpp:447 检查 next<=curtime, 491 行按住时重置 next=curtime)
	               // 其余子系统 (HUD/刷虫/染色等) 均有各自的时间节流, 不受此频率影响
}

// ============================================================
//  HUD
// ============================================================
function EnsureHuds()
{
	local hPlayer = null;
	while ((hPlayer = Entities.FindByClassname(hPlayer, "player")) != null)
	{
		local idx = hPlayer.entindex();
		local huds = (idx in g_huds) ? g_huds[idx] : null;
		local ok = (huds != null && huds.len() == HudLineNeed());
		if (ok)
		{
			foreach (h in huds)
			{
				if (h == null || !h.IsValid())
				{
					ok = false;
					break;
				}
			}
		}
		if (ok)
		{
			continue;
		}
		// 有旧实体残留则清掉, 整组重建
		if (huds != null)
		{
			foreach (h in huds)
			{
				if (h != null && h.IsValid())
				{
					DoEntFire("!self", "Kill", "", 0, null, h);
				}
			}
		}
		huds = [];
		for (local k = 0; k < HudLineNeed(); k++)
		{
			local hHud = Entities.CreateByClassname("rd_hud_vscript");
			if (hHud == null)
			{
				continue;
			}
			hHud.__KeyValueFromString("client_vscript", "asrd_points_hud.nut");
			hHud.Spawn();
			hHud.Activate();
			hHud.SetEntity(0, hPlayer);
			hHud.SetInt(0, k);   // 行号, 客户端 Paint 用它决定纵坐标
			huds.append(hHud);
		}
		g_huds[idx] <- huds;
	}
}

function UpdateHud(now)
{
	if (now < g_hudAt)
	{
		return;
	}
	g_hudAt = now + 0.5;

	// 护送行对所有玩家相同, 先拼好 (每位 VIP 独占一行, 避免 VIP 较多时一行过长)
	local escortLines = [];
	foreach (hVip, e in g_escorts)
	{
		local seg = e.name;
		if (hVip != null && hVip.IsValid())
		{
			if (e.downAt > 0)
			{
				seg = e.name + " 倒地血量" + hVip.GetHealth();
			}
			else
			{
				local eMaxHp = hVip.GetMaxHealth();
				if (eMaxHp > 0)
				{
					seg = e.name + " 血量" + ((hVip.GetHealth() * 100) / eMaxHp) + "%";
				}
			}
		}
		escortLines.append("护送  " + seg);
	}
	if (escortLines.len() == 0)
	{
		escortLines.append("");
	}

	local hPlayer = null;
	while ((hPlayer = Entities.FindByClassname(hPlayer, "player")) != null)
	{
		local idx = hPlayer.entindex();
		if (!(idx in g_huds))
		{
			continue;
		}
		local huds = g_huds[idx];

		// 行序: 0 积分 / 1 强化 / 2 护甲 / 3.. 护送(每 VIP 一行) / 末行 护盾
		local lines = [];
		lines.append("积分  " + g_points);

		local hMarine = GetMarineOfPlayer(hPlayer);
		if (hMarine != null)
		{
			lines.append("强化  Lv." + GetPowerLevel(hMarine));

			local armor = FindArmor(hMarine);
			if (armor != null)
			{
				local missing = TryGetInt(armor, "m_iLayersMissing", 0);
				local left = ARMOR_LAYERS - missing;
				if (left < 0)
				{
					left = 0;
				}
				lines.append("护甲  " + left + "/" + ARMOR_LAYERS);
			}
			else
			{
				lines.append("");
			}
		}
		else
		{
			lines.append("");
			lines.append("");
		}
		foreach (el in escortLines)
		{
			lines.append(el);
		}

		local shieldLine = "";
		if (hMarine != null)
		{
			local midx = hMarine.entindex();
			if (midx in g_shieldEnd)
			{
				local left = ((g_shieldEnd[midx].end - now) + 0.5).tointeger();
				if (left < 0)
				{
					left = 0;
				}
				shieldLine = "护盾  " + left + " 秒";
			}
		}
		lines.append(shieldLine);

		for (local k = 0; k < lines.len() && k < huds.len(); k++)
		{
			local hHud = huds[k];
			if (hHud != null && hHud.IsValid())
			{
				hHud.SetString(0, lines[k]);
			}
		}
	}
}

// ============================================================
//  通用小工具
// ============================================================
function GetMarineOfPlayer(hPlayer)
{
	if (hPlayer == null || !hPlayer.IsValid())
	{
		return null;
	}
	local m = null;
	try { m = hPlayer.GetMarine(); } catch (e) { m = null; }
	if (m == null || !m.IsValid())
	{
		return null;
	}
	return m;
}

function TrySetFloat(ent, prop, value)
{
	try { NetProps.SetPropFloat(ent, prop, value); } catch (e) {}
}

function TrySetModelScale(ent, scale)
{
	// 第二个参数是变化时长, 必须传 float (int 会让 VScript 绑定类型校验失败, 异常被吞后体型不变)
	try { ent.SetModelScale(scale, 0.0); }
	catch (e)
	{
		if (!("modelscale" in g_errShown))
		{
			g_errShown["modelscale"] <- true;
			printl("[要员护送] SetModelScale 失败: " + e);
		}
	}
}

function TrySetInt(ent, prop, value)
{
	try { NetProps.SetPropInt(ent, prop, value); } catch (e) {}
}

function TryGetInt(ent, prop, def)
{
	local v = def;
	try { v = NetProps.GetPropInt(ent, prop); } catch (e) { v = def; }
	return v;
}

function TryGetEntity(ent, prop)
{
	local v = null;
	try { v = NetProps.GetPropEntity(ent, prop); } catch (e) { v = null; }
	return v;
}

function Reply(hPlayer, msg)
{
	ClientPrint(hPlayer, 3, TextColor(120, 220, 255) + msg);
}

function Broadcast(msg)
{
	ClientPrint(null, 3, TextColor(255, 210, 90) + msg);
}

function Pay(cost, hPlayer)
{
	if (g_points < cost)
	{
		Reply(hPlayer, "积分不足：需要 " + cost + " 分，当前 " + g_points + " 分");
		return false;
	}
	g_points -= cost;
	return true;
}

function JoinStrings(arr, sep)
{
	local s = "";
	for (local i = 0; i < arr.len(); i++)
	{
		if (i > 0)
		{
			s += sep;
		}
		s += arr[i];
	}
	return s;
}

function Tokenize(str)
{
	local out = [];
	local cur = "";
	for (local i = 0; i < str.len(); i++)
	{
		local c = str.slice(i, i + 1);
		if (c == " " || c == "\t")
		{
			if (cur != "")
			{
				out.append(cur);
				cur = "";
			}
		}
		else
		{
			cur += c;
		}
	}
	if (cur != "")
	{
		out.append(cur);
	}
	return out;
}

function GetActivePlayers()
{
	local list = [];
	local hPlayer = null;
	while ((hPlayer = Entities.FindByClassname(hPlayer, "player")) != null)
	{
		if (GetMarineOfPlayer(hPlayer) != null)
		{
			list.append(hPlayer);
		}
	}
	return list;
}

// ============================================================
//  强化等级 (原 asrd_marine_power)
//    等级存在玩家(或 marine)的脚本作用域里, 换 marine 后仍保留
// ============================================================
function GetPowerHolder(hMarine)
{
	local p = null;
	try { p = hMarine.GetCommander(); } catch (e) { p = null; }
	if (p != null && p.IsValid() && p.GetClassname() == "player")
	{
		return p;
	}
	return hMarine;
}

// 重开任务必须把强化等级清零。
// 引擎的"即时重开" (asw_instant_restart 默认 1, asw_gamerules.cpp:1676) 不会重载地图,
// 只销毁地图实体再重新解析 (asw_gamerules.cpp:3241-3291), 而 "player" 在保留名单里
// (asw_gamerules.cpp:1715 AddKeepEntity("player")), 玩家实体与其脚本作用域不会重建,
// 于是 asrdPowerLevel 会残留下上一局的等级。挑战脚本本身随 asw_challenge_thinker
// 重建而重新执行 (asw_gamerules.cpp:10178-10194), 故在脚本首帧统一清零。
function ResetPowerLevels()
{
	local p = null;
	while ((p = Entities.FindByClassname(p, "player")) != null)
	{
		if (p == null || !p.IsValid())
		{
			continue;
		}
		p.ValidateScriptScope();
		p.GetScriptScope().asrdPowerLevel <- 0;
	}
}

function GetPowerLevel(hMarine)
{
	if (hMarine == null || !hMarine.IsValid())
	{
		return 0;
	}
	local holder = GetPowerHolder(hMarine);
	holder.ValidateScriptScope();
	local ss = holder.GetScriptScope();
	if (!("asrdPowerLevel" in ss))
	{
		ss.asrdPowerLevel <- 0;
	}
	return ss.asrdPowerLevel;
}

function SetPowerLevel(hMarine, lvl)
{
	local holder = GetPowerHolder(hMarine);
	holder.ValidateScriptScope();
	holder.GetScriptScope().asrdPowerLevel <- lvl;
}

// 该 marine 已经应用到的强化等级 (存 marine 自身作用域)
// 血量走"增量"而不是"基准血量 + 50 x 等级"重算: 后者的基准缓存一旦被重置
// (GetCommander 在 player / marine 之间切换时 holder 变了), 就会把已经强化过的
// 血量当成新基准, 导致高级时血量暴涨 (例如 4->5 级一次加了 250)
function GetAppliedLvl(hMarine)
{
	hMarine.ValidateScriptScope();
	local ss = hMarine.GetScriptScope();
	if (!("asrdAppliedLvl" in ss))
	{
		ss.asrdAppliedLvl <- 0;
	}
	return ss.asrdAppliedLvl;
}

function ApplyPower(hMarine)
{
	if (hMarine == null || !hMarine.IsValid())
	{
		return;
	}
	if (IsEscort(hMarine))
	{
		return;
	}

	local lvl = GetPowerLevel(hMarine);
	local applied = GetAppliedLvl(hMarine);
	if (lvl > applied)
	{
		// 每级只加 POWER_HP_STEP (50) 点, 4->5 级同样只加 50
		local add = POWER_HP_STEP * (lvl - applied);
		hMarine.SetMaxHealth(hMarine.GetMaxHealth() + add);
		hMarine.SetHealth(hMarine.GetHealth() + add);
		hMarine.GetScriptScope().asrdAppliedLvl <- lvl;
	}

	TrySetModelScale(hMarine, 1.0 + POWER_SCALE_STEP * lvl);

	local speed = 1.0 + POWER_SPEED_STEP * lvl;
	if (FindArmor(hMarine) != null && speed < ARMOR_SPEED_BONUS)
	{
		speed = ARMOR_SPEED_BONUS;
	}
	TrySetFloat(hMarine, "m_fSpeedScale", speed);
}

function TickPower(now)
{
	if (now < g_powerAt)
	{
		return;
	}
	g_powerAt = now + 1.0;

	local maxLvl = 0;
	local m = null;
	while ((m = Entities.FindByClassname(m, "asw_marine")) != null)
	{
		if (m == null || !m.IsValid())
		{
			continue;
		}
		if (m.GetHealth() <= 0)
		{
			continue;
		}

		local lvl = GetPowerLevel(m);
		if (lvl > maxLvl)
		{
			maxLvl = lvl;
		}
		if (IsEscort(m))
		{
			TrySetModelScale(m, 1.0);
			TrySetFloat(m, "m_fSpeedScale", 1.0);
			continue;
		}
		if (lvl <= 0)
		{
			continue;
		}

		// 每秒兜底: 新加入的队员 (applied=0) 或等级已提升但还没应用过血量
		ApplyPower(m);
	}

	// 视角高度: 全队共享等级
	// asw_cam_marine_dist 是全服唯一 convar, 无法按玩家区分
	local camDist = CAM_BASE + CAM_STEP * maxLvl;
	if (camDist != g_camDist)
	{
		g_camDist = camDist;
		Convars.SetValue("asw_cam_marine_dist", camDist);
	}
}

function BuyPower(hPlayer)
{
	local marines = [];
	local m = null;
	while ((m = Entities.FindByClassname(m, "asw_marine")) != null)
	{
		if (m == null || !m.IsValid())
		{
			continue;
		}
		if (m.GetHealth() <= 0)
		{
			continue;
		}
		local p = null;
		try { p = m.GetCommander(); } catch (e) { p = null; }
		if (p == null || !p.IsValid())
		{
			continue;
		}
		if (m in g_escorts)
		{
			continue;   // 护送目标不参与强化
		}
		marines.append(m);
	}

	if (marines.len() == 0)
	{
		Reply(hPlayer, "当前没有存活的陆战队员");
		return;
	}

	local allMax = true;
	foreach (mm in marines)
	{
		if (GetPowerLevel(mm) < POWER_MAX_LEVEL)
		{
			allMax = false;
		}
	}
	if (allMax)
	{
		Reply(hPlayer, "所有队员均已满级（Lv." + POWER_MAX_LEVEL + "），未扣除积分");
		return;
	}

	if (!Pay(COST_POWER, hPlayer))
	{
		return;
	}

	local upgraded = 0;
	foreach (mm in marines)
	{
		local lvl = GetPowerLevel(mm);
		if (lvl < POWER_MAX_LEVEL)
		{
			SetPowerLevel(mm, lvl + 1);
			ApplyPower(mm);
			upgraded++;
		}
	}
	Broadcast(hPlayer.GetPlayerName() + " 购买了全队强化，" + upgraded + " 名队员提升 1 级");
}

// ============================================================
//  护甲 (原 asrd_armor: 引擎 ConVar 负责减伤, 这里补移速/回血/HUD)
// ============================================================
function FindArmor(hMarine)
{
	if (hMarine == null || !hMarine.IsValid())
	{
		return null;
	}
	local armor = null;
	while ((armor = Entities.FindByClassname(armor, ARMOR_CLASS)) != null)
	{
		local owner = TryGetEntity(armor, "m_hOwnerEntity");
		if (owner == hMarine)
		{
			return armor;
		}
	}
	return null;
}

function TickArmor(now)
{
	local dt = now - g_lastTick;
	if (dt <= 0)
	{
		return;
	}

	local armor = null;
	while ((armor = Entities.FindByClassname(armor, ARMOR_CLASS)) != null)
	{
		local owner = TryGetEntity(armor, "m_hOwnerEntity");
		if (owner == null || !owner.IsValid())
		{
			continue;
		}
		if (owner.GetClassname() != "asw_marine")
		{
			continue;
		}
		if (owner.GetHealth() <= 0)
		{
			continue;
		}

		// 穿上动力护甲时私聊提示功能 (每件护甲提示一次, 脱下再穿会重新提示)
		local midx = owner.entindex();
		if (!(midx in g_armorHinted))
		{
			g_armorHinted[midx] <- true;
			local pc = null;
			try { pc = owner.GetCommander(); } catch (e) { pc = null; }
			if (pc != null && pc.IsValid())
			{
				Reply(pc, "动力护甲: 每层减伤 80% (层耗尽失效) | 免疫火/寄生/毒气 | 移速提升 | 防小爆虫");
			}
		}

		// 防寄生 (引擎原生机制): 续期电甲激活时间 -> IsElectrifiedArmorActive()=true
		// -> 寄生虫 CheckInfestTarget 直接拒绝 (asw_parasite.cpp:667), 寄生流程完全不启动,
		//    虫碰到穿甲玩家会被电死; 引擎副作用仅限 DMG_SLASH 的受击音效分支, 不吸收伤害
		TrySetFloat(owner, "m_flElectrifiedArmorEndTime", now + 2.0);

		// 护甲满层时缓慢回血 (2 生命/秒, 浮点累积攒够 1 点再加, 与原插件一致;
		//  不能每拍取整后保底 +1, 否则每 tick 跑时会变成每秒 +33)
		local missing = TryGetInt(armor, "m_iLayersMissing", 0);
		// 同步击前层数缓存: 引擎的回层/扣层都反映在 m_iLayersMissing 上, 每拍刷新,
		// 供伤害钩子在"引擎已扣本击的层"后仍能判定击前是否还有层可挡。
		g_armorMissing[midx] <- missing;
		if (missing > 0)
		{
			continue;
		}
		local hp = owner.GetHealth();
		local maxHp = owner.GetMaxHealth();
		if (hp <= 0 || hp >= maxHp)
		{
			continue;
		}
		local acc = (midx in g_regenAccum) ? g_regenAccum[midx] : 0.0;
		acc += ARMOR_REGEN * dt;
		local gain = acc.tointeger();
		if (gain >= 1)
		{
			g_regenAccum[midx] <- acc - gain;
			local newHp = hp + gain;
			if (newHp > maxHp)
			{
				newHp = maxHp;
			}
			owner.SetHealth(newHp);
		}
		else
		{
			g_regenAccum[midx] <- acc;
		}
	}

	// 脱下护甲后清除提示标记 (再穿会重新提示)
	local am = null;
	while ((am = Entities.FindByClassname(am, "asw_marine")) != null)
	{
		if (am == null || !am.IsValid())
		{
			continue;
		}
		local aidx = am.entindex();
		if ((aidx in g_armorHinted) && FindArmor(am) == null)
		{
			delete g_armorHinted[aidx];
		}
	}
}

// 防寄生虫/小爆虫 (原 asrd_armor 插件同款效果, 见 asrd_armor.sp):
//   寄生虫寄生时会 SetParent 到陆战队员身上; VScript 无法拦截接触,
//   改为每拍清除已附着在穿甲队员身上的寄生虫/小爆虫 (附着即被秒杀, 无法完成寄生)
function TickArmorParasite()
{
	local p = null;
	while ((p = Entities.FindByClassname(p, "asw_parasite")) != null)
	{
		CureArmorParasite(p);
	}
	p = null;
	while ((p = Entities.FindByClassname(p, "asw_parasite_defanged")) != null)
	{
		CureArmorParasite(p);
	}
}

function CureArmorParasite(p)
{
	if (p == null || !p.IsValid())
	{
		return;
	}
	local holder = null;
	try { holder = p.GetMoveParent(); } catch (e) { holder = null; }
	if (holder == null || !holder.IsValid() || holder.GetClassname() != "asw_marine")
	{
		return;
	}
	if (FindArmor(holder) == null)
	{
		return;
	}
	DoEntFire("!self", "Kill", "", 0, null, p);
}

// ============================================================
//  核弹 (原 asrd_nuke: 3 秒后全图清虫)
// ============================================================
function TickNuke(now)
{
	if (g_nukeAt <= 0 || now < g_nukeAt)
	{
		return;
	}
	g_nukeAt = 0;
	g_nukeReadyAt = now + NUKE_COOLDOWN;
	NukeKillText();
	NukeFlash();

	local killed = 0;
	foreach (cls in NUKE_CLASSES)
	{
		local ent = null;
		while ((ent = Entities.FindByClassname(ent, cls)) != null)
		{
			if (ent == null || !ent.IsValid())
			{
				continue;
			}
			if (ent.GetHealth() <= 0)
			{
				continue;
			}
			if (killed < 120)
			{
				SpawnExplosion(ent.GetOrigin());
			}
			ent.TakeDamage(NUKE_DAMAGE, 64, null);   // 64 = DMG_BLAST
			killed++;
		}
	}
	Broadcast("核弹轰炸结束，共清除 " + killed + " 只虫族");
}

function SpawnExplosion(pos)
{
	local boom = Entities.CreateByClassname("env_explosion");
	if (boom == null)
	{
		return;
	}
	boom.SetOrigin(pos);
	boom.__KeyValueFromInt("iMagnitude", 0);
	boom.__KeyValueFromInt("fireballsprite", 1);
	EntFireByHandle(boom, "Explode", "", 0, null, null);
	EntFireByHandle(boom, "Kill", "", 1.0, null, null);
}

function BuyNuke(hPlayer)
{
	local now = Time();
	if (g_nukeAt > 0)
	{
		Reply(hPlayer, "核弹已在倒计时中");
		return;
	}
	if (now < g_nukeReadyAt)
	{
		Reply(hPlayer, "核弹冷却中，还需 " + (g_nukeReadyAt - now).tointeger() + " 秒");
		return;
	}
	if (!Pay(COST_NUKE, hPlayer))
	{
		return;
	}
	g_nukeAt = now + NUKE_DELAY;
	g_nukeEtaShown = -1;
	NukeEnsureText();
	Broadcast(hPlayer.GetPlayerName() + " 发射了强化核弹，3 秒后全图轰炸！");
}

// ============================================================
//  核弹倒计时红字 (复刻原 asrd_nuke: game_text 实体, channel 5,
//  红色居中偏上, 每秒刷新 "呼叫战术核弹 ETA n 秒", 逐玩家 Display 全员可见)
// ============================================================
function NukeEnsureText()
{
	if (g_nukeText != null && g_nukeText.IsValid())
	{
		return g_nukeText;
	}
	local t = Entities.CreateByClassname("game_text");
	if (t == null)
	{
		return null;
	}
	t.__KeyValueFromString("targetname", "asrd_nuke_eta");
	t.__KeyValueFromInt("spawnflags", 0);
	t.__KeyValueFromInt("channel", 5);
	t.__KeyValueFromFloat("x", -1.0);    // -1 = 水平居中
	t.__KeyValueFromFloat("y", 0.10);
	t.__KeyValueFromInt("effect", 0);
	t.__KeyValueFromString("color", "255 0 0");
	t.__KeyValueFromFloat("fadein", 0.05);
	t.__KeyValueFromFloat("fadeout", 0.1);
	t.__KeyValueFromFloat("holdtime", 1.0);
	t.Spawn();
	g_nukeText = t;
	return t;
}

function NukeKillText()
{
	if (g_nukeText != null)
	{
		if (g_nukeText.IsValid())
		{
			DoEntFire("!self", "Kill", "", 0, null, g_nukeText);
		}
		g_nukeText = null;
	}
	g_nukeEtaShown = -1;
}

function TickNukeEta(now)
{
	if (g_nukeAt <= 0)
	{
		return;
	}
	local eta = (g_nukeAt - now + 0.9).tointeger();
	if (eta < 1)
	{
		eta = 1;
	}
	if (eta == g_nukeEtaShown)
	{
		return;
	}
	g_nukeEtaShown = eta;
	local t = NukeEnsureText();
	if (t == null)
	{
		return;
	}
	t.__KeyValueFromString("message", "战术核弹 ETA " + eta + " 秒");
	local p = null;
	while ((p = Entities.FindByClassname(p, "player")) != null)
	{
		EntFireByHandle(t, "Display", "", 0, p, null);
	}
}

// 引爆时的全屏白色炫光 (复刻原 asrd_nuke 的 ScreenFlashAll: Fade 用户消息
// FFADE_IN 全白 -> 淡出; 此处用 env_fade 实体实现, 不设 ONLYONE 即全员可见)
function NukeFlash()
{
	local f = Entities.CreateByClassname("env_fade");
	if (f == null)
	{
		return;
	}
	f.__KeyValueFromInt("spawnflags", 1);          // 1 = FADE_IN (从全白淡出到正常画面)
	f.__KeyValueFromFloat("duration", 2.0);        // 淡出时长 (原插件 512/255 秒 ≈ 2)
	f.__KeyValueFromFloat("holdtime", 1.0);        // 全白保持 (原插件 256/255 秒 ≈ 1)
	f.__KeyValueFromString("rendercolor", "255 244 180");   // 白中带黄 (原插件同款颜色)
	f.__KeyValueFromInt("renderamt", 255);
	f.Spawn();
	EntFireByHandle(f, "Fade", "", 0, null, null);
	EntFireByHandle(f, "Kill", "", 3.5, null, null);
}

// ============================================================
//  增强武器 (复刻原插件的掉落增强: 染色标记 + 弹匣/备弹写满 + 电锯转速)
//  伤害倍率部分由 challenges/asrd_points.txt 的 convars 块全局下发
// ============================================================
function SpawnWeaponEnhanced(hPlayer, cls, dist)
{
	local wpn = SpawnNear(hPlayer, cls, dist);
	if (wpn == null || !(cls in WEAPON_ENH))
	{
		return wpn;
	}
	local enh = WEAPON_ENH[cls];
	if (enh.clip1 >= 0)
	{
		TrySetInt(wpn, "m_iClip1", enh.clip1);
	}
	if (enh.clip2 >= 0)
	{
		TrySetInt(wpn, "m_iClip2", enh.clip2);
	}
	if (enh.ammo1 >= 0)
	{
		TrySetInt(wpn, "m_iPrimaryAmmoCount", enh.ammo1);   // 拾取时加入弹药池的备弹 (原 railgun 插件同款写法)
	}
	if (enh.ammo2 >= 0)
	{
		TrySetInt(wpn, "m_iSecondaryAmmoCount", enh.ammo2);
	}
	if (enh.tint != null)
	{
		g_tintWpn[wpn.entindex()] <- { r = enh.tint[0], g = enh.tint[1], b = enh.tint[2] };
	}
	return wpn;
}

function TintColorValue(c)
{
	return (c.r & 255) | ((c.g & 255) << 8) | ((c.b & 255) << 16) | (255 << 24);
}

function TickEnhancedWeapons(now)
{
	// 1) 重涂染色 (增强武器)
	local del = [];
	foreach (idx, c in g_tintWpn)
	{
		local ent = EntIndexToHScript(idx);
		if (ent == null || !ent.IsValid())
		{
			del.append(idx);
			continue;
		}
		TrySetInt(ent, "m_clrRender", TintColorValue(c));
	}
	foreach (idx in del)
	{
		delete g_tintWpn[idx];
	}

	// 2) 增强电锯: 手持标记电锯且按住攻击键时, 锯片转速 x3 (原 asrd_chainsaw_turbo 的 m_flPlaybackRate 方案)
	local p = null;
	while ((p = Entities.FindByClassname(p, "player")) != null)
	{
		local m = GetMarineOfPlayer(p);
		if (m == null || m.GetHealth() <= 0)
		{
			continue;
		}
		local w = TryGetEntity(m, "m_hActiveWeapon");
		if (w == null || !w.IsValid())
		{
			continue;
		}
		if (!(w.entindex() in g_tintWpn) || w.GetClassname() != "asw_weapon_chainsaw")
		{
			continue;
		}
		local buttons = TryGetInt(p, "m_nButtons", 0);
		local rate = ((buttons & 1) != 0) ? CHAINSAW_TURBO_MULT : 1.0;   // 1 = IN_ATTACK
		TrySetFloat(w, "m_flPlaybackRate", rate);
	}
}

// ============================================================
//  Laidback Potato 弹药系统 (每 0.1 秒检查一次)
//  - PO_INF_WEAPON 内的武器弹匣始终补满 (无限弹匣)
//  - 其余武器按 PO_REGEN_INTERVAL 逐发回填 (弹药耗尽后自动恢复)
//  - 副弹匣 (下挂榴弹等) 按 PO_REGEN_INTERVAL2 回填
//  - 单弹匣武器套用 Potato 的弹匣容量惩罚
// ============================================================
function TickPotatoAmmo(now)
{
	if (now < g_poAt)
	{
		return;
	}
	g_poAt = now + PO_REFILL_TICK;

	local m = null;
	while ((m = Entities.FindByClassname(m, "asw_marine")) != null)
	{
		if (m == null || !m.IsValid() || m.GetHealth() <= 0)
		{
			continue;
		}

		local w = null;
		for (w = m.FirstMoveChild(); w != null; w = w.NextMovePeer())
		{
			if (w == null || !w.IsValid() || !("GetMaxClip1" in w))
			{
				continue;
			}

			local cls = w.GetClassname();
			local idx = w.entindex();
			local maxClip1 = w.GetMaxClip1();
			if (maxClip1 < 1)
			{
				continue;
			}

			if (cls in PO_INF_WEAPON)
			{
				if (w.Clip1() < maxClip1)
				{
					w.SetClip1(maxClip1);
				}
			}
			else
			{
				local maxAmmo = w.GetMaxAmmo1();
				if (maxAmmo < maxClip1)
				{
					maxAmmo = maxClip1;
				}

				local capClip = maxClip1;
				local clips = maxAmmo / maxClip1;
				if (clips < PO_NOCLIP_PENALTY)
				{
					if (cls in PO_AMMO_COUNT)
					{
						capClip = PO_AMMO_COUNT[cls];
					}
					else
					{
						local scaled = ceil(maxClip1 * (1.0 - PO_SINGLE_CLIP_PENALTY / clips));
						capClip = scaled.tointeger();
					}
				}
				if (capClip < 1)
				{
					capClip = 1;
				}
				if (w.Clip1() > capClip)
				{
					w.SetClip1(capClip);
				}

				local rate = (cls in PO_REGEN_INTERVAL) ? PO_REGEN_INTERVAL[cls] : 50;
				local perShot = rate.tofloat() / maxAmmo;
				// 开火后延迟: 手雷/护甲类 0 秒, 枪械类 5 秒 (与 Potato regenDelay 一致)
				local delay0 = (cls in PO_REGEN_DELAY) ? PO_REGEN_DELAY[cls].tofloat() : PO_DEFAULT_REGEN_DELAY;

				if (!(idx in g_poNext))
				{
					// 35 式泵动霰弹枪: 引擎给新枪的 m_iClip1 是原版 4 发, 本挑战把弹匣上限
					// 提到 16 (PO_AMMO_COUNT), 首次装备时直接补满, 否则只能靠逐发回填慢慢涨到 16
					if (cls == "asw_weapon_shotgun" && w.Clip1() < capClip)
					{
						w.SetClip1(capClip);
					}
					g_poNext[idx] <- now + perShot;
					g_poLast[idx] <- w.Clip1();
				}
				else if (w.Clip1() != g_poLast[idx])
				{
					// 刚开过枪: 重置回填计时 (含开火后延迟)
					g_poLast[idx] = w.Clip1();
					g_poNext[idx] = now + delay0 + perShot;
				}
				else if (g_poNext[idx] <= now && w.Clip1() < capClip)
				{
					w.SetClip1(w.Clip1() + 1);
					g_poLast[idx] = w.Clip1();
					g_poNext[idx] = now + PO_REFILL_TICK + perShot;
				}
			}

			// 副弹匣 (下挂榴弹/手雷)
			if (!("GetMaxClip2" in w))
			{
				continue;
			}
			local cap2 = (cls in PO_UND_COUNT) ? PO_UND_COUNT[cls] : w.GetMaxClip2();
			if (cap2 < 1)
			{
				continue;
			}
			if (w.Clip2() > cap2)
			{
				w.SetClip2(cap2);
			}
			if ((cls in PO_REGEN_INTERVAL2) && w.Clip2() < cap2)
			{
				local rate2 = PO_REGEN_INTERVAL2[cls].tofloat();
				if (!(idx in g_poNext2))
				{
					g_poNext2[idx] <- now + rate2;
					g_poLast2[idx] <- w.Clip2();
				}
				else if (w.Clip2() != g_poLast2[idx])
				{
					g_poLast2[idx] = w.Clip2();
					g_poNext2[idx] = now + rate2;
				}
				else if (g_poNext2[idx] <= now)
				{
					w.SetClip2(w.Clip2() + 1);
					g_poLast2[idx] = w.Clip2();
					g_poNext2[idx] = now + rate2;
				}
			}
		}
	}
}

// ============================================================
//  导轨步枪射速钳制 (原 asrd_railgun 的 fire_interval 方案:
//  弹匣减少视为开火并记录时刻, 每拍把 m_flNextPrimaryAttack 钳到
//  max(当前值, 上次开火 + 0.2); 弹匣空时 (换弹中) 不干预, 保持引擎 1.3 秒节奏)
// ============================================================
function TickRailgun(now)
{
	local w = null;
	while ((w = Entities.FindByClassname(w, "asw_weapon_railgun")) != null)
	{
		if (w == null || !w.IsValid())
		{
			continue;
		}
		local idx = w.entindex();
		local clip = TryGetInt(w, "m_iClip1", -1);
		if (clip < 0)
		{
			continue;
		}
		local prev = (idx in g_railClip) ? g_railClip[idx] : clip;
		if (clip < prev)
		{
			g_railFireAt[idx] <- now;   // 弹匣减少 = 开火了
		}
		g_railClip[idx] <- clip;
		if (clip > 0 && (idx in g_railFireAt))
		{
			local minNext = g_railFireAt[idx] + RAILGUN_FIRE_INTERVAL;
			local cur = 0.0;
			try { cur = NetProps.GetPropFloat(w, "m_flNextPrimaryAttack"); } catch (e) { cur = 0.0; }
			if (cur < minNext)
			{
				TrySetFloat(w, "m_flNextPrimaryAttack", minNext);
			}
		}
	}
	// 清理已销毁武器的跟踪记录
	local live = {};
	w = null;
	while ((w = Entities.FindByClassname(w, "asw_weapon_railgun")) != null)
	{
		if (w != null && w.IsValid())
		{
			live[w.entindex()] <- true;
		}
	}
	foreach (idx, v in g_railClip)
	{
		if (!(idx in live))
		{
			delete g_railClip[idx];
			if (idx in g_railFireAt)
			{
				delete g_railFireAt[idx];
			}
		}
	}
}

// ============================================================
//  精英虫生成 (供 TickMutate 原位替换用)
// ============================================================
// kv 可选: 生成前写入的 KeyValue (字符串->字符串), 只对 Spawn 前的实体有效
function SpawnAlien(cls, org, kv = null)
{
	local alien = Entities.CreateByClassname(cls);
	if (alien == null)
	{
		return null;
	}
	if (kv != null)
	{
		foreach (k, v in kv)
		{
			try { alien.__KeyValueFromString(k, v); } catch (e) {}
		}
	}
	alien.SetOrigin(org);
	alien.SetAngles(0, RandomFloat(0.0, 360.0), 0);
	alien.Spawn();
	try { alien.Activate(); } catch (e) {}
	return alien;
}

// ============================================================
//  生成物品
// ============================================================
function SpawnNear(hPlayer, cls, dist)
{
	local hMarine = GetMarineOfPlayer(hPlayer);
	if (hMarine == null)
	{
		return null;
	}

	local fwd = hMarine.GetForwardVector();
	local org = hMarine.GetOrigin();
	local pos = Vector(org.x + fwd.x * dist, org.y + fwd.y * dist, org.z + 12.0);

	local ent = Entities.CreateByClassname(cls);
	if (ent == null)
	{
		return null;
	}
	ent.SetOrigin(pos);
	ent.SetAngles(0, 0, 0);
	ent.Spawn();
	try { ent.Activate(); } catch (e) {}
	return ent;
}

function BuySentry(hPlayer, opt)
{
	local hMarine0 = GetMarineOfPlayer(hPlayer);
	if (hMarine0 == null)
	{
		Reply(hPlayer, "你当前没有陆战队员");
		return;
	}
	local cls = (opt == "1") ? "asw_pickup_sentry_cannon" : "asw_pickup_sentry";
	if (!Pay(COST_SENTRY, hPlayer))
	{
		return;
	}
	// 手工生成: BulletsInGun 必须在 Spawn() 前写入 (原插件 asrd_sentry_enhancer.sp:2203:
	// 拾取箱默认近乎空弹 BulletsInGun=1, 拾取后部署会提示"弹药耗尽"而无法部署)
	local fwd = hMarine0.GetForwardVector();
	local org = hMarine0.GetOrigin();
	local ent = Entities.CreateByClassname(cls);
	if (ent == null)
	{
		g_points += COST_SENTRY;
		Reply(hPlayer, "生成哨戒塔箱失败，积分已退还");
		return;
	}
	ent.SetOrigin(Vector(org.x + fwd.x * 60.0, org.y + fwd.y * 60.0, org.z + 12.0));
	ent.SetAngles(0, 0, 0);
	try { ent.__KeyValueFromInt("BulletsInGun", (opt == "1") ? SENTRY_CANNON_AMMO : SENTRY_MG_AMMO); } catch (e) {}
	ent.Spawn();
	try { ent.Activate(); } catch (e) {}
	Broadcast(hPlayer.GetPlayerName() + " 购买了" + ((opt == "1") ? "炮塔" : "机枪塔") + "哨戒塔箱");
}

// ============================================================
//  哨戒塔增强 (伤害 x2 见 OnTakeDamage 钩子 + txt 炮塔 ConVar; 此处每拍):
//    弹药 x4 (首次见到塔时记录原版 m_iMaxAmmo 再放大, 并把当前弹药补满)
//    射速 x3 (引擎开火时重设 m_fNextFireTime, 检测其跳变后把剩余间隔压缩为 1/3)
// ============================================================
// 门 (asw_door) 不是 CBaseCombatCharacter, 引擎不会调 VScript 的 OnTakeDamage_Alive_Any
// (basecombatcharacter.cpp:2304), 所以伤害钩子里的武器增强对门一律无效。
// 改为: 追踪增强武器的投射物, 在它消失(爆炸/命中)时给附近门补足伤害。
function TickDoorBall()
{
	local seenB = {};
	local b = null;
	while ((b = Entities.FindByClassname(b, "prop_combine_ball")) != null)
	{
		if (b == null || !b.IsValid())
		{
			continue;
		}
		local idx = b.entindex();
		seenB[idx] <- true;
		g_balls[idx] <- b.GetOrigin();
	}
	foreach (idx, pos in g_balls)
	{
		if (idx in seenB)
		{
			continue;
		}
		DoorBurst(pos, 400.0, AR2_BALL_DAMAGE);
		delete g_balls[idx];
	}

	local seenR = {};
	local r = null;
	while ((r = Entities.FindByClassname(r, "asw_rocket")) != null)
	{
		if (r == null || !r.IsValid())
		{
			continue;
		}
		local ridx = r.entindex();
		seenR[ridx] <- true;
		g_rockets[ridx] <- r.GetOrigin();
	}
	foreach (ridx, rpos in g_rockets)
	{
		if (ridx in seenR)
		{
			continue;
		}
		DoorBurst(rpos, 220.0, 120.0);
		delete g_rockets[ridx];
	}
}

// 对 pos 半径内的门补足伤害: 门血量 1800/2400, 补足后最低留 1 点
// (直接写 0 不会触发门的倒塌逻辑, 留 1 血玩家再补一枪即倒)
function DoorBurst(pos, radius, dmg)
{
	local d = null;
	while ((d = Entities.FindByClassname(d, "asw_door")) != null)
	{
		if (d == null || !d.IsValid() || d.GetHealth() <= 0)
		{
			continue;
		}
		if ((d.GetOrigin() - pos).Length() > radius)
		{
			continue;
		}
		local hp = d.GetHealth() - dmg;
		if (hp < 1)
		{
			hp = 1;
		}
		try { NetProps.SetPropInt(d, "m_iHealth", hp); } catch (e) {}
	}
}

function TickSentry()
{
	local now = Time();
	local b = null;
	while ((b = Entities.FindByClassname(b, "asw_sentry_base")) != null)
	{
		if (b == null || !b.IsValid() || b.GetHealth() <= 0)
		{
			continue;
		}
		local bidx = b.entindex();
		if (!(bidx in g_sentryEnh))
		{
			g_sentryEnh[bidx] <- true;
			try
			{
				local maxa = NetProps.GetPropInt(b, "m_iMaxAmmo");
				if (maxa > 0)
				{
					NetProps.SetPropInt(b, "m_iMaxAmmo", maxa * SENTRY_AMMO_MULT);
					b.SetAmmo(maxa * SENTRY_AMMO_MULT);
				}
			}
			catch (e) {}
		}
		// 射速: 炮口实体要等装配完成才出现
		local top = null;
		try { top = b.GetSentryTop(); } catch (e) { top = null; }
		if (top == null || !top.IsValid())
		{
			continue;
		}
		local tidx = top.entindex();
		local nf = 0.0;
		try { nf = NetProps.GetPropFloat(top, "m_fNextFireTime"); } catch (e) { continue; }
		if (!(tidx in g_sentryFire))
		{
			g_sentryFire[tidx] <- nf;   // 首次只记录基准, 不压缩
			continue;
		}
		if (nf != g_sentryFire[tidx])
		{
			// 引擎刚更新了下次开火时间 (开火瞬间) -> 剩余间隔压缩为 1/3
			if (nf > now)
			{
				local comp = now + (nf - now) / SENTRY_RATE_MULT;
				try { NetProps.SetPropFloat(top, "m_fNextFireTime", comp); } catch (e) {}
				g_sentryFire[tidx] <- comp;
			}
			else
			{
				g_sentryFire[tidx] <- nf;
			}
		}
	}
}

// 哨戒塔部署加速: 未装配的 asw_sentry_base 装配进度预置到 99.9%,
// 玩家按住 E 后 NPCUsing 第一拍 (deltatime/7) 就跨过 1.0 完成装配并生成炮头
function TickSentryFastBuild()
{
	local b = null;
	while ((b = Entities.FindByClassname(b, "asw_sentry_base")) != null)
	{
		if (b == null || !b.IsValid())
		{
			continue;
		}
		try
		{
			if (NetProps.GetPropBool(b, "m_bAssembled"))
			{
				continue;
			}
			if (NetProps.GetPropFloat(b, "m_fAssembleProgress") < SENTRY_FAST_ASSEMBLE)
			{
				NetProps.SetPropFloat(b, "m_fAssembleProgress", SENTRY_FAST_ASSEMBLE);
			}
		}
		catch (e) {}
	}
}

// 哨戒塔拆卸加速: 原版要按住 E 满 2 秒 (asw_player_shared.h:20) 才判定 ASW_USE_HOLD_RELEASE_FULL。
// 玩家按住的实体是已装配的哨戒塔、且已按住 SENTRY_DISMANTLE_HOLD 秒时,
// 把玩家网络属性 m_flUseKeyDownTime 往前推, 让 "curtime - 按下时刻 >= 2.0" 立刻成立
function TickSentryFastDismantle()
{
	local now = Time();
	local p = null;
	while ((p = Entities.FindByClassname(p, "player")) != null)
	{
		if (p == null || !p.IsValid())
		{
			continue;
		}
		local holdEnt = null;
		local t0 = 0.0;
		try
		{
			holdEnt = NetProps.GetPropEntity(p, "m_hUseKeyDownEnt");
			t0 = NetProps.GetPropFloat(p, "m_flUseKeyDownTime");
		}
		catch (e) { continue; }
		if (holdEnt == null || !holdEnt.IsValid() || holdEnt.GetClassname() != "asw_sentry_base")
		{
			continue;
		}
		try
		{
			if (!NetProps.GetPropBool(holdEnt, "m_bAssembled"))
			{
				continue;   // 正在装配的不处理, 那是部署流程
			}
		}
		catch (e) { continue; }
		// 轻点 E 是旋转炮塔, 按满 SENTRY_DISMANTLE_HOLD 秒才算想拆卸
		if (now - t0 < SENTRY_DISMANTLE_HOLD)
		{
			continue;
		}
		if (t0 > now - SENTRY_DISMANTLE_BACKDATE)
		{
			try { NetProps.SetPropFloat(p, "m_flUseKeyDownTime", now - SENTRY_DISMANTLE_BACKDATE); } catch (e) {}
		}
	}
}

function BuyWeapon(hPlayer, opt)
{
	if (opt == "")
	{
		for (local i = 0; i < WEAPONS.len(); i++)
		{
			Reply(hPlayer, "#buy 6 " + (i + 1) + " = " + WEAPON_NAMES[i]);
		}
		return;
	}
	if (GetMarineOfPlayer(hPlayer) == null)
	{
		Reply(hPlayer, "你当前没有陆战队员");
		return;
	}

	local idx = opt.tointeger();
	if (idx < 1 || idx > WEAPONS.len())
	{
		Reply(hPlayer, "武器编号只能是 1~" + WEAPONS.len());
		return;
	}
	if (!Pay(COST_WEAPON, hPlayer))
	{
		return;
	}
	if (SpawnWeaponEnhanced(hPlayer, WEAPONS[idx - 1], 60.0) == null)
	{
		g_points += COST_WEAPON;
		Reply(hPlayer, "生成武器失败，积分已退还");
		return;
	}
	Broadcast(hPlayer.GetPlayerName() + " 购买了 " + WEAPON_NAMES[idx - 1]);
}

function BuyArmor(hPlayer)
{
	if (GetMarineOfPlayer(hPlayer) == null)
	{
		Reply(hPlayer, "你当前没有陆战队员");
		return;
	}
	if (!Pay(COST_ARMOR, hPlayer))
	{
		return;
	}
	if (SpawnNear(hPlayer, ARMOR_CLASS, 60.0) == null)
	{
		g_points += COST_ARMOR;
		Reply(hPlayer, "生成动力护甲失败，积分已退还");
		return;
	}
	Broadcast(hPlayer.GetPlayerName() + " 购买了动力护甲");
}

function BuyAmmo(hPlayer)
{
	if (GetMarineOfPlayer(hPlayer) == null)
	{
		Reply(hPlayer, "你当前没有陆战队员");
		return;
	}
	if (!Pay(COST_AMMO, hPlayer))
	{
		return;
	}
	if (SpawnNear(hPlayer, "asw_ammo_drop", 60.0) == null)
	{
		g_points += COST_AMMO;
		Reply(hPlayer, "生成弹药失败，积分已退还");
		return;
	}
	Broadcast(hPlayer.GetPlayerName() + " 掉落了弹药箱");
}

// ============================================================
//  自动力场护盾 (原 asrd_points 的自动护盾; 斥力效果简化自 asrd_repulse)
//    触发: 任一存活且未倒地的玩家血量 < 30 → 血量最低者获得 10 秒护盾
//    冷却: 全队共享 120 秒, 只在护盾真正加上后才开始计时
//    倒地玩家不参与 (既不触发也不当选目标); 目标已有护盾时本轮跳过
// ============================================================
function TickShield(now)
{
	// ── 维持已有护盾: 持续弹开半径内的虫族 + 维护特效信标 ──
	local del = [];
	foreach (idx, sh in g_shieldEnd)
	{
		local m = EntIndexToHScript(idx);
		if (m == null || !m.IsValid() || now >= sh.end || m.GetHealth() <= 0)
		{
			del.append(idx);
			continue;
		}
		PushAliensAway(m);

		// X-33 同款特效信标 (涟漪+光晕, 无增益): 没有就创建, 燃烧截止=护盾结束,
		// 到期由引擎自动燃尽移除, 无需手动删
		local beacon = (sh.beacon > 0) ? EntIndexToHScript(sh.beacon) : null;
		if (beacon == null || !beacon.IsValid())
		{
			beacon = FindMarineBeacon(m);
			if (beacon == null)
			{
				beacon = CreateShieldBeacon(m, sh.end);
			}
			sh.beacon = (beacon != null) ? beacon.entindex() : 0;
			sh.disarmed = false;
		}
		if (beacon != null && beacon.IsValid())
		{
			TrySetFloat(beacon, "m_flTimeBurnOut", sh.end);
			TrySetFloat(beacon, "m_flModelScale", 0.0);   // 引擎可能重置缩放, 每拍压回 0
			if (!sh.disarmed)
			{
				sh.disarmed = DisarmShieldBeacon(beacon);
			}
			// 不能用 SetParent: 带 parent 的实体被引擎 PhysicsPushEntity 推动时会刷
			// "pushing entity (asw_buffgrenade_projectile) that has parent"
			// (physics_main.cpp:1343-1347), 改为每拍传送到 marine 脚下跟随
			// (必须每拍都传, 只传一次的话人一走特效就留在原地)
			try { beacon.SetOrigin(m.GetOrigin()); } catch (e) {}
		}
	}
	foreach (idx in del)
	{
		delete g_shieldEnd[idx];
	}

	// ── 冷却未到不触发 ──
	if (now < g_shieldReadyAt)
	{
		return;
	}

	// ── 找血量最低的存活未倒地玩家 ──
	local target = null;
	local lowest = 999999;
	local m = null;
	while ((m = Entities.FindByClassname(m, "asw_marine")) != null)
	{
		if (m == null || !m.IsValid())
		{
			continue;
		}
		local hp = m.GetHealth();
		if (hp <= 0)
		{
			continue;
		}
		if (TryGetInt(m, "m_bKnockedOut", 0) != 0)
		{
			continue;
		}
		local p = null;
		try { p = m.GetCommander(); } catch (e) { p = null; }
		if (p == null || !p.IsValid())
		{
			continue;
		}
		if (hp < lowest)
		{
			lowest = hp;
			target = m;
		}
	}

	if (target == null || lowest >= SHIELD_HP_THRESHOLD)
	{
		return;
	}

	// 目标已有护盾: 本轮静默跳过, 不消耗冷却
	if (target.entindex() in g_shieldEnd)
	{
		return;
	}

	g_shieldEnd[target.entindex()] <- { end = now + SHIELD_DURATION, beacon = 0, disarmed = false };
	g_shieldReadyAt = now + SHIELD_COOLDOWN;

	local name = "陆战队员";
	local p = null;
	try { p = target.GetCommander(); } catch (e) { p = null; }
	if (p != null && p.IsValid())
	{
		name = p.GetPlayerName();
	}
	Broadcast("局势危急，" + name + " 开启紧急力场护盾（" + SHIELD_DURATION + " 秒）！");
}

// 找 marine 名下已存在的增益信标 (与 repulse 的 FindMarineBeacon 一致)
function FindMarineBeacon(hMarine)
{
	local ent = null;
	while ((ent = Entities.FindByClassname(ent, "asw_buffgrenade_projectile")) != null)
	{
		if (ent == null || !ent.IsValid())
		{
			continue;
		}
		if (TryGetEntity(ent, "m_hOwnerEntity") == hMarine)
		{
			return ent;
		}
	}
	return null;
}

// 创建特效信标: 放 marine 脚下、零速度, 燃烧截止 = 护盾结束 (repulse 的 CreateTimedShieldBeacon)
function CreateShieldBeacon(hMarine, endAt)
{
	local ent = Entities.CreateByClassname("asw_buffgrenade_projectile");
	if (ent == null)
	{
		return null;
	}
	ent.SetOrigin(hMarine.GetOrigin());
	ent.SetAngles(0, 0, 0);
	ent.Spawn();
	try { ent.Activate(); } catch (e) {}
	try { NetProps.SetPropEntity(ent, "m_hOwnerEntity", hMarine); } catch (e) {}
	try { ent.SetVelocity(Vector(0, 0, 0)); } catch (e) {}
	local dur = endAt - Time();
	if (dur < 0.1)
	{
		dur = 0.1;
	}
	TrySetFloat(ent, "m_flTimeBurnOut", endAt);
	TrySetFloat(ent, "m_flDuration", dur);
	TrySetFloat(ent, "m_flModelScale", 0.0);   // 隐藏中心的 X-33 道具模型, 只留波纹/光环粒子
	return ent;
}

// 解除信标的增益能力: 把它落地生成的触发盒移到地图外 (repulse 的 DisarmShieldBeacon)
// 返回 true = 已移走 (触发盒要等信标落地才生成, 没找到时下帧再试)
function DisarmShieldBeacon(beacon)
{
	local trig = null;
	while ((trig = Entities.FindByClassname(trig, "asw_aoegrenade_touch_trigger")) != null)
	{
		if (trig == null || !trig.IsValid())
		{
			continue;
		}
		if (TryGetEntity(trig, "m_hOwnerEntity") != beacon)
		{
			continue;
		}
		trig.SetOrigin(Vector(16384.0, 16384.0, -16384.0));
		return true;
	}
	return false;
}

function PushAliensAway(hMarine)
{
	local origin = hMarine.GetOrigin();
	local ent = null;
	while ((ent = Entities.FindInSphere(ent, origin, SHIELD_RADIUS)) != null)
	{
		if (ent == null || !ent.IsValid())
		{
			continue;
		}
		local isAlien = false;
		try { isAlien = ent.IsAlien(); } catch (e) { isAlien = false; }
		if (!isAlien || ent.GetHealth() <= 0)
		{
			continue;
		}
		local d = ent.GetOrigin() - origin;
		local flat = Vector(d.x, d.y, 0.0);
		if (flat.Length() < 1.0)
		{
			continue;
		}
		flat.Norm();
		try { ent.SetVelocity(flat * SHIELD_PUSH_SPEED); } catch (e) {}
	}
}

// ============================================================
//  护送模式 (默认开启, 原 asrd_escort 简化版)
// ============================================================
function IsEscort(hMarine)
{
	return (hMarine != null && (hMarine in g_escorts));
}

function TickEscort(now)
{
	if (g_escortDone)
	{
		return;
	}

	// 开局立即指定 (陆战队员尚未生成时每次 Update 重试, 无延迟);
	// 中途最后一名护送对象离开导致名单清空时, 从剩余玩家补选恰好 1 名
	if (g_escorts.len() == 0)
	{
		PickEscort(g_escortPicked);
		return;
	}

	local dropList = [];
	foreach (hVip, e in g_escorts)
	{
		if (hVip == null || !hVip.IsValid())
		{
			// marine 实体被移除: 玩家已掉线则移除该护送名额; 玩家还在则视为彻底阵亡
			if (e.player == null || !e.player.IsValid())
			{
				Broadcast("护送对象 " + e.name + " 已离开服务器，护送名额移除");
				dropList.append(hVip);
				continue;
			}
			FailEscort();
			return;
		}

		// 玩家掉线但 marine 还在 (变 AI): 尝试刷新操控者显示
		if (e.player == null || !e.player.IsValid())
		{
			local np = null;
			try { np = hVip.GetCommander(); } catch (ex) { np = null; }
			if (np != null && np.IsValid())
			{
				e.player = np;
				try { e.name = np.GetPlayerName(); } catch (ex2) {}
			}
		}

		// ── 倒地 (VIP 特权: 仅第一次血量归零时倒地; 倒地后由引擎原生流血, 耗尽即阵亡) ──
		if (TryGetInt(hVip, "m_bKnockedOut", 0) != 0)
		{
			if (e.downAt <= 0)
			{
				if (e.usedDown)
				{
					// 第二次血量归零: 不再享有倒地特权, 直接阵亡
					hVip.TakeDamage(99999.0, 64, null);   // 64 = DMG_BLAST
					continue;
				}
				e.usedDown = true;
				e.downAt = now;
				Broadcast("护送对象 " + e.name + " 倒地！血量持续流失，耗尽即阵亡！");
			}
			// 血量流失由引擎倒地机制处理, 脚本只检测耗尽阵亡
			if (hVip.GetHealth() <= 0)
			{
				FailEscort();
				return;
			}
			continue;
		}
		e.downAt = 0.0;   // 未倒地: 复位倒地标记

		// 未倒地且血量 <= 0 = 彻底阵亡
		if (hVip.GetHealth() <= 0)
		{
			FailEscort();
			return;
		}
	}
	foreach (h in dropList)
	{
		g_escorts.rawdelete(h);
	}
}

// 失败播报 (统一出口, 去重): VIP 阵亡走 FailEscort, 其余失败 (超时/全灭/objective)
// 由引擎 fire mission_failed 走 OnGameEvent_mission_failed, 两条路径都必须广播。
function BroadcastFail()
{
	if (g_failBroadcasted)
	{
		return;
	}
	g_failBroadcasted = true;
	Broadcast("任务失败！别灰心，再接再厉。");
}

function FailEscort()
{
	if (g_escortDone)
	{
		return;
	}
	g_escortDone = true;
	BroadcastFail();
	// 不立即 MissionComplete: 引擎会当场 SetGameState(ASW_GS_DEBRIEF) 直接切结算界面,
	// 改为延迟结算, 由 TickEscortFail 到点触发
	g_escortFailAt = Time() + ESCORT_FAIL_DELAY;
}

// VIP 阵亡延迟结算: 到点后才真正结束任务
function TickEscortFail(now)
{
	if (g_escortFailAt < 0.0)
	{
		return;
	}
	if (now < g_escortFailAt)
	{
		return;
	}
	g_escortFailAt = -1.0;
	Director.MissionComplete(false);
}

// single = false: 开局点名, 人数随机 1 ~ floor(玩家数/3), 完全随机选人
// single = true : 补选 (最后一名护送对象离开后), 从剩余玩家固定补 1 名;
//                 两种路径都走同一套血量减半 (ESCORT_HP_RATIO) 与强化排除逻辑
function PickEscort(single)
{
	local list = [];
	local hPlayer = null;
	while ((hPlayer = Entities.FindByClassname(hPlayer, "player")) != null)
	{
		local m = GetMarineOfPlayer(hPlayer);
		if (m == null || m.GetHealth() <= 0)
		{
			continue;
		}
		if (TryGetInt(m, "m_bKnockedOut", 0) != 0)
		{
			continue;
		}
		list.append({ player = hPlayer, marine = m });
	}

	if (list.len() == 0)
	{
		return;   // 陆战队员还没生成, 下一次 Update 再试
	}

	// 完全随机选人: 洗牌后取前 N 个
	for (local i = list.len() - 1; i > 0; i--)
	{
		local j = RandomInt(0, i);
		local tmp = list[i];
		list[i] = list[j];
		list[j] = tmp;
	}

	// 人数: 开局随机 1 ~ floor(玩家数/3) (整数除法, 至少 1 名); 补选固定 1 名
	local nVip = 1;
	if (!single)
	{
		local maxVip = list.len() / 3;
		if (maxVip < 1)
		{
			maxVip = 1;
		}
		nVip = RandomInt(1, maxVip);
	}

	local names = [];
	for (local i = 0; i < nVip; i++)
	{
		local pick = list[i];
		local pname = "陆战队员";
		try { pname = pick.player.GetPlayerName(); } catch (e) {}
		g_escorts[pick.marine] <- {
			player = pick.player,
			name = pname,
			downAt = 0.0,
			usedDown = false
		};

		// 护送对象不再吃强化加成; 最大生命 = 原生血量 x 比例
		// 原生血量 = 当前最大血量 - 已应用的强化增量 (introduced by GetAppliedLvl),
		// 避免把已经被强化过的血量当成原生值
		local appliedLvl = GetAppliedLvl(pick.marine);
		local baseHp = pick.marine.GetMaxHealth() - POWER_HP_STEP * appliedLvl;
		if (baseHp < 1)
		{
			baseHp = pick.marine.GetMaxHealth();
		}
		local newMax = (baseHp * ESCORT_HP_RATIO).tointeger();
		if (newMax < 1)
		{
			newMax = 1;
		}
		pick.marine.SetMaxHealth(newMax);
		if (pick.marine.GetHealth() > newMax)
		{
			pick.marine.SetHealth(newMax);
		}

		names.append(pname);
	}

	g_pressureAt = Time() + RandomFloat(PRESSURE_MIN_INTERVAL, PRESSURE_MAX_INTERVAL);
	g_escortPicked = true;

	if (single)
	{
		Broadcast("最后一名护送对象已离开，从剩余队员中补选新护送目标：" + JoinStrings(names, "、") + "（血量减半）");
	}
	else
	{
		Broadcast("护送目标 " + nVip + " 名：" + JoinStrings(names, "、"));
		Broadcast("任意护送目标阵亡则任务失败，积分可用于购买支援武器，输入#buy查看");
	}

	// 选完 VIP 后按身份单独私聊每位玩家 (上面两条是全体广播, 这里是各收各的)
	// 遍历 list (本次全部存活玩家); g_escorts 的 key 就是 VIP 的 marine 实体,
	// 用 IsEscort 判定身份。补选场景同样适用: 新 VIP 收 VIP 提示, 其余收护送提示。
	for (local i = 0; i < list.len(); i++)
	{
		local pick = list[i];
		local pc = pick.player;
		if (pc == null || !pc.IsValid())
		{
			continue;
		}
		if (IsEscort(pick.marine))
		{
			Reply(pc, "你是 VIP，血量减半，阵亡则任务失败。");
		}
		else
		{
			Reply(pc, "你是护送人员，护送VIP到达终点");
		}
	}
}

// ============================================================
//  VIP 滑倒 (娱乐): 移植自 slip.nut 的 Collapse + 冲量写法
//  - 每 SLIP_MIN_INTERVAL ~ SLIP_MAX_INTERVAL 秒 (2~5 分钟) 随机一次
//  - 每次只作用于 1 名存活的护送目标, 其他玩家/非 VIP 一律不受影响
//  - Knockdown 是引擎原生脚本函数 (asw_marine.cpp:409 ScriptKnockdown 绑定为 "Knockdown")
// ============================================================
function TickVipSlip(now)
{
	// 开局先上弦: 第一次滑倒也要等满 2~5 分钟, 不能开局就摔
	if (g_slipAt <= 0)
	{
		g_slipAt = now + RandomFloat(SLIP_MIN_INTERVAL, SLIP_MAX_INTERVAL);
		return;
	}
	if (now < g_slipAt)
	{
		return;
	}
	g_slipAt = now + RandomFloat(SLIP_MIN_INTERVAL, SLIP_MAX_INTERVAL);

	if (g_escortDone || g_escorts.len() == 0)
	{
		return;
	}

	// 收集存活且未倒地的护送目标
	local vips = [];
	foreach (hVip, e in g_escorts)
	{
		if (hVip == null || !hVip.IsValid())
		{
			continue;
		}
		if (e.downAt > 0 || hVip.GetHealth() <= 0)
		{
			continue;
		}
		vips.append(hVip);
	}
	if (vips.len() == 0)
	{
		return;
	}

	local v = vips[RandomInt(0, vips.len() - 1)];
	// 摔倒: 先给 knockdown 状态 (播摔倒动画), 再按 slip.nut 给前冲 + 上抛速度
	try { v.Knockdown(Vector(2, 2, 2)); } catch (e) { return; }
	try { v.SetVelocity(v.GetForwardVector() * SLIP_PUSH_SPEED + Vector(0, 0, SLIP_PUSH_UP)); } catch (e) {}
	Broadcast(g_escorts[v].name + " 滑倒了！！！怎么这么不小心？？？");
}

// ============================================================
//  倒地特权: 只有 VIP 能进入倒地状态, 其他玩家血量归零直接阵亡
//  (挑战配置强制 rd_allow_revive 1, 引擎先给所有人倒地,
//    这里每拍把非 VIP 的倒地玩家补掉; AI 队友保持原生规则)
// ============================================================
function TickDownedRule()
{
	local m = null;
	while ((m = Entities.FindByClassname(m, "asw_marine")) != null)
	{
		if (m == null || !m.IsValid())
		{
			continue;
		}
		if (TryGetInt(m, "m_bKnockedOut", 0) == 0)
		{
			continue;
		}
		if (IsEscort(m))
		{
			continue;   // VIP 的倒地由 TickEscort 管理
		}
		local p = null;
		try { p = m.GetCommander(); } catch (e) { p = null; }
		if (p == null || !p.IsValid())
		{
			continue;
		}
		m.TakeDamage(99999.0, 64, null);   // 64 = DMG_BLAST
	}
}

// ============================================================
//  定向刷虫压力: 每隔 20~40 秒 (随机) 刷一波精英
//    用 Director.SpawnAlienAuto 在引擎合法 nav 节点实时生成普通虫 (不碰 horde 计时器,
//    与原版刷怪节奏解耦), 再由 TickMutate 把刷出的普通虫逐只变异/替换成精英。
//    引擎选点自带路线校验, 不会卡墙/卡地板。
// ============================================================

// 判断此刻是否处于"任务节点" (黑客面板进行中 / 事件型高频窗口未过期)
//  黑客面板: asw_button_area 的 m_fHackProgress (0<x<1) 或 m_bIsInUse (均为 SendProp)
function IsTaskRush(now)
{
	if (now < g_rushUntil)
	{
		return true;
	}
	local btn = null;
	while ((btn = Entities.FindByClassname(btn, "asw_button_area")) != null)
	{
		if (btn == null || !btn.IsValid())
		{
			continue;
		}
		local progress = 0.0;
		try { progress = NetProps.GetPropFloat(btn, "m_fHackProgress"); } catch (e) {}
		local inUse = TryGetInt(btn, "m_bIsInUse", 0);
		if ((progress > 0.0 && progress < 1.0) || inUse != 0)
		{
			return true;
		}
	}
	return false;
}

function TickPressure(now)
{
	if (g_escortDone || g_escorts.len() == 0)
	{
		return;
	}
	if (now < g_pressureAt)
	{
		return;
	}
	// 仅在有存活 VIP 时才刷 (引擎 horde 自行选择玩家附近的合法刷点)
	local liveVips = 0;
	foreach (hVip, e in g_escorts)
	{
		if (hVip != null && hVip.IsValid() && hVip.GetHealth() > 0)
		{
			liveVips++;
		}
	}
	if (liveVips == 0)
	{
		return;
	}
	// 任务节点期间加速到每 5 秒一波, 节点过后恢复 20~40 秒
	if (IsTaskRush(now))
	{
		g_pressureAt = now + PRESSURE_RUSH_INTERVAL;
	}
	else
	{
		g_pressureAt = now + RandomFloat(PRESSURE_MIN_INTERVAL, PRESSURE_MAX_INTERVAL);
	}
	g_pressureWave++;

	// 数量: 每波完全随机 5~10 只 (不再随波次递增); 每波精英同一种, 波次轮换 6 种
	// (寄生虫也作为其中一种精英, 第 1 波起就有概率抽到, 不再要求第 10 波之后)
	// 自爆虫波单独压低到 2~5 只 (每只死亡补 54 只炮弹, 数量太多会卡)
	local count = RandomInt(ELITE_WAVE_MIN, ELITE_WAVE_MAX);
	// 精英种类每波随机 (不与上一波重复, 避免连续两波同一种)
	local nTypes = ELITE_NAMES.len();
	local t = RandomInt(0, nTypes - 1);
	if (nTypes > 1)
	{
		local guard = 0;
		while (t == g_lastMutateType && guard < 8)
		{
			t = RandomInt(0, nTypes - 1);
			guard++;
		}
	}
	g_mutateType = t;
	g_lastMutateType = t;
	if (g_mutateType == 4)
	{
		// 自爆虫波单独压低数量 (炮弹太多会卡)
		count = RandomInt(BOOMER_WAVE_MIN, BOOMER_WAVE_MAX);
	}
	// 实时生成精英波: 在引擎验证过的合法远点直接生成目标精英 (SpawnEliteDirect)。
	// 关键: 不再用 Entities.FindByClassname 全场扫描普通虫来变异 —— 那会把地图预刷虫
	// (txt 的 rm_prespawn_num_uber_drones / boomers 等) 和引擎自然刷的虫一起变异,
	// 导致红巨爪/自爆等在玩家附近"突然冒出来"。现在只动本次生成的虫, 预刷虫完全不碰。
	// 刷怪点由 Director.FindHordePosition 提供 (距离区间 + 路线校验 + 防不可破坏门后),
	// 且**不碰 director 的 horde 计时器** —— 精英波与原版刷怪节奏彻底解耦。
	for (local i = 0; i < count; i++)
	{
		SpawnEliteDirect(g_mutateType);
	}
}

// 在引擎验证过的合法刷怪点直接生成一只精英 (不扫描全场, 不动地图预刷虫)。
// Director.FindHordePosition 内部 UpdateCandidateNodes + FindHordePos: 带距离区间
// (asw_horde_min/max_distance) + BuildRouteForHull 路线校验 + 防刷在不可破坏门后,
// 返回的点是远的、合法的、玩家视野外的 (asw_gamerules_vscript.cpp:253-272)。
function SpawnEliteDirect(t)
{
	local pos = null;
	try { pos = Director.FindHordePosition(RandomInt(0, 1) == 0); } catch (e) {}
	if (pos == null)
	{
		return;   // 无合法点则本只放弃, 下一波再试 (不会误伤预刷虫)
	}

	local a = null;
	if (t == 4)       // 自爆虫
	{
		a = SpawnAlien("asw_boomer", pos);
	}
	else if (t == 5)  // 寄生虫
	{
		a = SpawnAlien("asw_parasite", pos);
	}
	else if (t == 1)  // 红巨爪: 必须生成前写 flinchable=0
	{
		a = SpawnAlien("asw_drone_uber", pos, { flinchable = "0" });
	}
	else              // 追踪/电甲/蓝巨: 普通爪虫底材
	{
		a = SpawnAlien("asw_drone", pos);
	}
	if (a == null)
	{
		return;
	}
	if (t == 5)
	{
		// 寄生虫: 保持原语义 —— 不进 g_eliteIdx, 不加自爆虫那套特效, 只锁敌
		try { a.ChaseNearestMarine(); } catch (e) {}
	}
	else
	{
		MutateElite(a, t);
	}
}

// 旧机制 (全场扫描普通虫变异) 已废弃, 由 SpawnEliteDirect 直接生成精英替代。
// 保留函数体仅为回退参考; 立刻返回, 不执行任何实体操作。
// 废弃原因: Entities.FindByClassname 会扫到地图预刷虫 (uber_drones=15 / boomers=5)
// 和引擎自然刷的虫, 导致精英在玩家附近突然冒出来。
function TickMutate()
{
	return;

	/* 以下为废弃的旧实现 (不可达)
	// 寄生虫波: 引擎 horde 刷出的普通虫 Kill 掉, 原位换成 asw_parasite
	// (引擎不刷寄生虫; 引擎选点合法, 替换后绝不卡墙)
	if (g_paraPending > 0)
	{
		if (Time() > g_paraExpireAt)
		{
			g_paraPending = 0;
		}
		else
		{
			local killed = {};   // 本拍已 Kill 的实体 (Kill 下一帧才移除, 防同拍重复处理)
			foreach (cls in ["asw_drone", "asw_drone_jumper", "asw_drone_uber"])
			{
				local a = null;
				while (g_paraPending > 0 && (a = Entities.FindByClassname(a, cls)) != null)
				{
					if (a == null || !a.IsValid() || a.GetHealth() <= 0)
					{
						continue;
					}
					local aidx = a.entindex();
					if ((aidx in g_eliteIdx) || (aidx in killed))
					{
						continue;
					}
					killed[aidx] <- true;
					local pos = a.GetOrigin();
					try { EntFireByHandle(a, "Kill", "", 0, null, null); } catch (e) {}
					local p = SpawnAlien("asw_parasite", pos);
					if (p != null)
					{
						try { p.ChaseNearestMarine(); } catch (e) {}
					}
					g_paraPending--;
				}
			}
		}
	}
	// 自爆虫波: 引擎 horde 刷出的普通虫 Kill 掉, 原位换成 asw_boomer 再变异成精英
	// (引擎选点合法, 不会出现 "NPC asw_boomer stuck in wall")
	if (g_boomerPending > 0)
	{
		if (Time() > g_boomerExpireAt)
		{
			g_boomerPending = 0;
		}
		else
		{
			local bKilled = {};
			foreach (cls in ["asw_drone", "asw_drone_jumper", "asw_drone_uber"])
			{
				local ba = null;
				while (g_boomerPending > 0 && (ba = Entities.FindByClassname(ba, cls)) != null)
				{
					if (ba == null || !ba.IsValid() || ba.GetHealth() <= 0)
					{
						continue;
					}
					local bidx = ba.entindex();
					if ((bidx in g_eliteIdx) || (bidx in bKilled))
					{
						continue;
					}
					bKilled[bidx] <- true;
					local bpos = ba.GetOrigin();
					try { EntFireByHandle(ba, "Kill", "", 0, null, null); } catch (e) {}
					local nb = SpawnAlien("asw_boomer", bpos);
					if (nb != null)
					{
						MutateElite(nb, 4);
					}
					g_boomerPending--;
				}
			}
		}
	}
	// 红巨爪虫波: 引擎 horde 刷出的普通虫 Kill 掉, 原位换成 asw_drone_uber
	// 只有新建实体才能在 Spawn 前写 flinchable=0 (m_bFlinchable 非网络属性, 已刷出的虫改不了)
	if (g_redPending > 0)
	{
		if (Time() > g_redExpireAt)
		{
			g_redPending = 0;
		}
		else
		{
			local rKilled = {};
			foreach (cls in ["asw_drone", "asw_drone_jumper", "asw_drone_uber"])
			{
				local ra = null;
				while (g_redPending > 0 && (ra = Entities.FindByClassname(ra, cls)) != null)
				{
					if (ra == null || !ra.IsValid() || ra.GetHealth() <= 0)
					{
						continue;
					}
					local ridx = ra.entindex();
					if ((ridx in g_eliteIdx) || (ridx in rKilled))
					{
						continue;
					}
					rKilled[ridx] <- true;
					local rpos = ra.GetOrigin();
					try { EntFireByHandle(ra, "Kill", "", 0, null, null); } catch (e) {}
					local nr = SpawnAlien("asw_drone_uber", rpos, { flinchable = "0" });
					if (nr != null)
					{
						MutateElite(nr, 1);
					}
					g_redPending--;
				}
			}
		}
	}
	if (g_mutatePending <= 0)
	{
		return;
	}
	local pool = (g_mutateType == 4) ? ["asw_boomer"] : ["asw_drone", "asw_drone_jumper", "asw_drone_uber"];
	foreach (cls in pool)
	{
		local a = null;
		while (g_mutatePending > 0 && (a = Entities.FindByClassname(a, cls)) != null)
		{
			if (a == null || !a.IsValid() || a.GetHealth() <= 0)
			{
				continue;
			}
			local aidx = a.entindex();
			if (aidx in g_eliteIdx)
			{
				continue;   // 已是精英, 跳过
			}
			MutateElite(a, g_mutateType);
			g_mutatePending--;
		}
	}
	*/
}

// 把一只虫变异为本波指定精英类型 (血量均以顶部常量为准):
// 0 追踪虫(TRACKER_HP,速度x2,优先攻击要员) / 1 红巨爪(RED_GIANT_HP,免硬直) /
// 2 电甲(ELITE_HP) / 3 蓝巨(BLUE_GIANT_HP) / 4 自爆虫(BOOMER_HP,体型2倍,炮弹62只)
function MutateElite(a, t)
{
	g_eliteIdx[a.entindex()] <- true;
	if (t == 0)
	{
		// 追踪虫: 高饱和品红 (Color 是 m_clrRender 乘色, 只留红/蓝通道去掉绿,
		// 与纯红红巨爪/蓝巨虫/黄色系都拉开差距, 暗色场景里最跳) + TRACKER_HP + 移速 x2,
		// TickTrackers 每拍强制仇恨 = 最近存活要员
		try { EntFireByHandle(a, "Color", "255 0 255", 0, a, a); } catch (e) {}
		a.SetMaxHealth(TRACKER_HP);
		a.SetHealth(TRACKER_HP);
		// 移速 x2: m_fSpeedScale 直接参与 GetIdealSpeed() 计算 (asw_inhabitable_npc.cpp:466)
		try { NetProps.SetPropFloat(a, "m_fSpeedScale", TRACKER_SPEED_MULT); } catch (e) {}
		g_trackers[a.entindex()] <- true;
	}
	else if (t == 1)
	{
		// 红巨爪虫: 红色 + 体型放大 + RED_GIANT_HP
		// 免硬直: 实体是由 SpawnAlien(..., {flinchable="0"}) 新建的,
		// m_bFlinchable=False 后 ShouldStumble 直接返回 false (asw_ai_behavior_flinch.cpp:221)
		a.SetMaxHealth(RED_GIANT_HP);
		a.SetHealth(RED_GIANT_HP);
		try { EntFireByHandle(a, "Color", "255 0 0", 0, a, a); } catch (e) {}
		TrySetModelScale(a, 1.2);
	}
	else if (t == 2)
	{
		// 电甲爪虫: 真电甲虫 = 普通虫颜色 + 周身电环绕材质 (不染色!)
		// 电材质 = 引擎客户端按 m_bElectroStunned 渲染 (c_asw_inhabitable_npc.cpp:194),
		// 但 NPCThink 会在 m_flElectroStunSlowMoveTime < curtime 时清掉该标志
		// (asw_inhabitable_npc.cpp:259-266), 故必须同时把时间戳设为极大值
		// 副作用: ElectroStun 期间移速乘 asw_alien_stunned_speed, txt 已下发为 1 (不减速)
		a.SetMaxHealth(ELITE_HP);
		a.SetHealth(ELITE_HP);
		TrySetModelScale(a, 1.2);
		try { a.__KeyValueFromInt("Teslable", 0); } catch (e) {}
		// 注意: __KeyValueFrom* 只对 Spawn 前的实体有效, 已刷出的虫必须走 NetProps 写网络属性
		try { NetProps.SetPropBool(a, "m_bElectroStunned", true); }
		catch (e) { try { a.__KeyValueFromInt("m_bElectroStunned", 1); } catch (e2) {} }
		try { NetProps.SetPropFloat(a, "m_flElectroStunSlowMoveTime", Time() + 60.0); } catch (e) {}
		g_zappers[a.entindex()] <- 0.0;
	}
	else if (t == 3)
	{
		// 蓝巨虫: ASBI Blue Giant 同款 (高饱和蓝 0 80 255 + 体型 1.05) + BLUE_GIANT_HP
		a.SetMaxHealth(BLUE_GIANT_HP);
		a.SetHealth(BLUE_GIANT_HP);
		try { EntFireByHandle(a, "Color", "0 80 255", 0, a, a); } catch (e) {}
		TrySetModelScale(a, 1.05);
		// 移速 0.7 倍: m_fSpeedScale 默认 1.0, 直接乘进 GetIdealSpeed()
		// (asw_inhabitable_npc.cpp:466), 设 0.7 即原速 70%
		try { NetProps.SetPropFloat(a, "m_fSpeedScale", BLUE_GIANT_SPEED_MULT); } catch (e) {}
	}
	else
	{
		// 自爆虫 (asw_boomer 底材): 体型 2 倍, 脚踢固定 200 (OnTakeDamage 钩子按 g_eliteIdx 改写),
		// 死亡瞬间补生成 BOOMER_EXTRA_BLOBS 只炮弹 (引擎硬编码最多 8 只, 8+54=62)
		TrySetModelScale(a, BOOMER_SCALE);
		// 血量 BOOMER_HP (仅此精英变异体; 原版 asw_boomer 由 txt 的 asw_boomer_health 控制, 未改)
		a.SetMaxHealth(BOOMER_HP);
		a.SetHealth(BOOMER_HP);
		local bidx = a.entindex();
		g_boomers[bidx] <- true;
		g_boomerEnt[bidx] <- a;
		g_boomerPos[bidx] <- a.GetOrigin();
	}
	// 强制锁敌: 引擎索敌有距离限制, 远距刷出的精英会一直发呆;
	// 直接把仇恨指向最近的存活陆战队员 (m_hEnemy, 与追踪虫同一接口)
	try { a.ChaseNearestMarine(); } catch (e) {}
	local best = null;
	local bestD = 0.0;
	local hm = null;
	while ((hm = Entities.FindByClassname(hm, "asw_marine")) != null)
	{
		if (hm.GetHealth() > 0)
		{
			local d = (a.GetOrigin() - hm.GetOrigin()).Length();
			if (best == null || d < bestD)
			{
				best = hm;
				bestD = d;
			}
		}
	}
	if (best != null)
	{
		try { NetProps.SetPropEntity(a, "m_hEnemy", best); } catch (e) {}
	}
}

// ============================================================
//  精英自爆虫: 死亡补生成炮弹
// ============================================================
// 引擎自身爆炸最多 8 只炮弹 (asw_boomer.cpp:310 max_projectiles="8";
// 实际数量 = (8+1)*蓄气进度 再 clamp 到 1~8, 见 asw_ai_behavior_explode.cpp:374-376),
// 这里在死亡瞬间补 BOOMER_EXTRA_BLOBS 只, 合计 8+54=62。
// 生成顺序必须与 Boomer_Blob_Create 一致 (asw_boomer_blob.cpp:261-281):
// 先 Spawn 再 SetOrigin/SetVelocity; 否则 Spawn() 内的模型/移动类型/引信初始化会覆盖先前设置。
// 必须给初速度: 引擎的炮弹是朝四周甩出去的 (min_velocity 150 / max_velocity 450),
// 若速度为零会全部堆在自爆虫脚下、同一帧一起炸, 看起来和原版几只没有区别。
function SpawnBoomerExtraBlobs(pos, owner)
{
	if (g_escortDone)
	{
		return 0;
	}
	local n = 0;
	for (local i = 0; i < BOOMER_EXTRA_BLOBS; i++)
	{
		local blob = null;
		try { blob = Entities.CreateByClassname("asw_boomer_blob"); } catch (e) { blob = null; }
		if (blob == null)
		{
			continue;
		}
		try { blob.Spawn(); } catch (e) { blob = null; }
		if (blob == null)
		{
			continue;
		}
		local ang = RandomFloat(0.0, 6.2831853);
		local spd = RandomFloat(150.0, 450.0);
		try
		{
			// Spawn() 内部会把 m_flDamage/m_DmgRadius 写成 80/165, 必须之后覆盖
			// (两者都在 CBaseGrenade 的 datamap 与 sendtable 里, basegrenade_shared.cpp:37-41/65-66)
			NetProps.SetPropFloat(blob, "m_flDamage", BOOMER_BLOB_DAMAGE);
			NetProps.SetPropFloat(blob, "m_DmgRadius", BOOMER_BLOB_RADIUS);
			blob.SetOrigin(Vector(pos.x + RandomFloat(-16.0, 16.0), pos.y + RandomFloat(-16.0, 16.0), pos.z + 40.0));
			blob.SetVelocity(Vector(cos(ang) * spd, sin(ang) * spd, RandomFloat(150.0, 450.0)));
			if (owner != null && owner.IsValid())
			{
				blob.SetOwner(owner);
			}
		}
		catch (e) {}
		n++;
	}
	if (n > 0)
	{
		printl("[escort VIP] 自爆虫死亡, 额外生成炮弹 " + n + " 只");
	}
	return n;
}

// 兜底: 伤害钩子没拦到的自爆虫 (例如被引擎行为直接 Kill) 每拍检查一次,
// 句柄失效或血量归零即视为死亡, 在最后存活位置补炮弹
function TickBoomerDeaths()
{
	if (g_boomerEnt.len() < 1)
	{
		return;
	}
	local gone = [];
	foreach (idx, e in g_boomerEnt)
	{
		if (e != null && e.IsValid() && e.GetHealth() > 0)
		{
			g_boomerPos[idx] = e.GetOrigin();
			continue;
		}
		gone.append(idx);
		local pos = (idx in g_boomerPos) ? g_boomerPos[idx] : Vector(0, 0, 0);
		SpawnBoomerExtraBlobs(pos, null);
	}
	foreach (idx in gone)
	{
		if (idx in g_boomerEnt) { delete g_boomerEnt[idx]; }
		if (idx in g_boomers) { delete g_boomers[idx]; }
		if (idx in g_boomerPos) { delete g_boomerPos[idx]; }
	}
}

// 追踪虫: 每 0.5 秒把仇恨强制指向最近的存活要员 (引擎只暴露 ChaseNearestMarine,
// 没有指定目标的追击接口, 故用 netprop m_hEnemy 周期性覆盖)
function TickTrackers(now)
{
	if (now < g_trackersAt)
	{
		return;
	}
	g_trackersAt = now + 0.5;
	if (g_trackers.len() == 0)
	{
		return;
	}
	local del = [];
	foreach (idx, v in g_trackers)
	{
		local a = EntIndexToHScript(idx);
		if (a == null || !a.IsValid() || a.GetHealth() <= 0)
		{
			del.append(idx);
			continue;
		}
		local best = null;
		local bestD = 0.0;
		foreach (hVip, e in g_escorts)
		{
			if (hVip == null || !hVip.IsValid() || hVip.GetHealth() <= 0)
			{
				continue;
			}
			local d = (a.GetOrigin() - hVip.GetOrigin()).Length();
			if (best == null || d < bestD)
			{
				best = hVip;
				bestD = d;
			}
		}
		if (best != null)
		{
			try { NetProps.SetPropEntity(a, "m_hEnemy", best); } catch (e) {}
		}
	}
	foreach (idx in del)
	{
		delete g_trackers[idx];
	}
}

// 电甲爪虫: 贴近的玩家每秒被电 8 点血 (伤害类型 256=DMG_SHOCK, 音效用游戏原生电击声)
function TickZappers(now)
{
	local del = [];
	foreach (idx, nextZap in g_zappers)
	{
		local a = EntIndexToHScript(idx);
		if (a == null || !a.IsValid() || a.GetHealth() <= 0)
		{
			del.append(idx);
			continue;
		}
		// 电甲虫: 每拍续期电晕时间戳, 否则 NPCThink 判定超时后会清掉 m_bElectroStunned
		// (asw_inhabitable_npc.cpp:259-266), 客户端的 FX_ElectroStun 电环绕就消失
		try { NetProps.SetPropFloat(a, "m_flElectroStunSlowMoveTime", now + 60.0); } catch (e) {}
		try { NetProps.SetPropBool(a, "m_bElectroStunned", true); } catch (e) {}
		// 抵消电晕减速: m_fHurtSlowMoveTime 是 ShouldMoveSlow() 的判据, 清成 0 后
		// 即使 m_bElectroStunned=true, 速度也不会乘 asw_alien_stunned_speed;
		// 这样 asw_alien_stunned_speed 可保持原版 0.3, 电枪/电炸弹对普通虫仍有减速效果
		try { NetProps.SetPropFloat(a, "m_fHurtSlowMoveTime", 0.0); } catch (e) {}
		if (now < nextZap)
		{
			continue;
		}
		local org = a.GetOrigin();
		local victim = null;
		local m = null;
		while ((m = Entities.FindInSphere(m, org, ZAP_RADIUS)) != null)
		{
			if (m == null || !m.IsValid() || m.GetClassname() != "asw_marine")
			{
				continue;
			}
			if (m.GetHealth() <= 0 || TryGetInt(m, "m_bKnockedOut", 0) != 0)
			{
				continue;
			}
			victim = m;
			break;
		}
		if (victim != null)
		{
			g_zappers[idx] <- now + ZAP_INTERVAL;
			victim.TakeDamage(ZAP_DAMAGE, 256, a);
		}
	}
	foreach (idx in del)
	{
		delete g_zappers[idx];
	}
}

// ============================================================
//  自动空投
// ============================================================
function TickAutoDrop(now)
{
	if (now < g_nextAutoDrop)
	{
		return;
	}
	g_nextAutoDrop = now + POINTS_AUTO_INTERVAL;

	local players = GetActivePlayers();
	if (players.len() == 0)
	{
		return;
	}

	local p = players[RandomInt(0, players.len() - 1)];
	local item = AUTO_DROPS[RandomInt(0, AUTO_DROPS.len() - 1)];
	if (SpawnWeaponEnhanced(p, item.cls, 60.0) != null)
	{
		Broadcast("自动空投：" + item.name + " 已掉落在 " + p.GetPlayerName() + " 附近");
	}
}

// ============================================================
//  任务节点事件: 玩家使用面板 / 焊接门 -> 开 15 秒高频刷虫窗口
//  (button_area_used / door_welded / door_unwelded 均在 VScript 事件白名单内,
//   see ScriptGameEventListener.cpp:415-417, 383-386)
// ============================================================
// 开任务窗口: 同时把"下一次刷怪"提前到最多 5 秒后, 让玩家立刻感到压力上升
function StartTaskRush()
{
	if (g_finished)
	{
		return;
	}
	g_rushUntil = Time() + RUSH_WINDOW_SECONDS;
	local due = Time() + PRESSURE_RUSH_INTERVAL;
	if (g_pressureAt > due)
	{
		g_pressureAt = due;
	}
}

function OnGameEvent_button_area_used(params) { StartTaskRush(); }
function OnGameEvent_door_welded(params)      { StartTaskRush(); }
function OnGameEvent_door_unwelded(params)    { StartTaskRush(); }

// ============================================================
//  击杀计分
// ============================================================
function OnGameEvent_entity_killed(params)
{
	if (!("entindex_killed" in params))
	{
		return;
	}

	local victim = EntIndexToHScript(params["entindex_killed"]);
	if (victim == null || !victim.IsValid())
	{
		return;
	}

	local isAlien = false;
	try { isAlien = victim.IsAlien(); } catch (e) { isAlien = false; }
	if (!isAlien)
	{
		return;
	}

	local attacker = null;
	if ("entindex_attacker" in params)
	{
		attacker = EntIndexToHScript(params["entindex_attacker"]);
	}
	if (!IsPlayerSource(attacker))
	{
		return;
	}

	local hp = victim.GetMaxHealth();
	if (hp <= 0)
	{
		hp = 1;
	}
	local gain = (hp * POINTS_HP_SCALE).tointeger();
	if (gain < 1)
	{
		gain = 1;
	}
	g_points += gain;
}

function IsPlayerSource(ent)
{
	if (ent == null || !ent.IsValid())
	{
		return false;
	}
	local cls = ent.GetClassname();
	if (cls == "player" || cls == "asw_marine")
	{
		return true;
	}
	local isAlien = false;
	try { isAlien = ent.IsAlien(); } catch (e) { isAlien = false; }
	if (isAlien)
	{
		local cmd = null;
		try { cmd = ent.GetCommander(); } catch (e) { cmd = null; }
		return (cmd != null && cmd.IsValid());
	}
	return false;
}

// ============================================================
//  伤害钩子: 守望者 x2 / 近战按强化等级倍率
// ============================================================
function OnTakeDamage_Alive_Any(victim, inflictor, attacker, weapon, damage, damageType, ammoName)
{
	if (victim == null || !victim.IsValid())
	{
		return damage;
	}

	// 动力护甲免伤 (原插件 asrd_armor.sp:283-287 同款):
	//   寄生吸血 DMG_INFEST=1<<25 (33554432)
	//   火焰     DMG_BURN=1<<3 (8) / DMG_PLASMA=1<<24 (16777216)
	// 火焰 DoT 常带 DMG_DIRECT(1<<28) 走 ASW_Ignite 持续伤害路径, 引擎
	// ApplyPassiveArmorEffects 覆盖不到, 故在 VScript 钩子里直接归零。
	// asw_fire.cpp:1185 确认自然火/燃烧地雷=DMG_BURN, 其它火=DMG_PLASMA。
	local isMarine = false;
	try { isMarine = (victim.GetClassname() == "asw_marine"); } catch (e) { isMarine = false; }

	// ── 动力护甲减伤判定 ──────────────────────────────────
	// 引擎 ApplyPassiveArmorEffects 在 VScript 钩子之前先扣层 (asw_marine.cpp:1996
	// 再 1655 调 BaseClass), 钩子里直接读 m_iLayersMissing 拿到的是击后值。
	// 故用 TickArmor 每拍同步的击前缓存 pre (已损失层数) 判定: pre<10 有层实受 20%,
	// pre>=10 (0 层) 实受 100%。
	// 引擎 ConVar 已设中性 (armor_scale=1, protection=0), 减伤全由这里接管。
	local armorEnt = null;
	local armorMul = 1.0;
	if (isMarine)
	{
		armorEnt = FindArmor(victim);
		if (armorEnt != null)
		{
			local vidx = victim.entindex();
			local pre = (vidx in g_armorMissing) ? g_armorMissing[vidx] : TryGetInt(armorEnt, "m_iLayersMissing", ARMOR_LAYERS);
			armorMul = (pre < ARMOR_LAYERS) ? ARMOR_HIT_SCALE : 1.0;
			// 同步缓存到击后值, 保证同帧多击/下一击判定正确 (引擎每击扣 1 层, 上限层数)
			g_armorMissing[vidx] <- (pre < ARMOR_LAYERS) ? (pre + 1) : ARMOR_LAYERS;
		}
	}

	// 动力护甲免伤 (火焰/寄生吸血/毒气手雷): 只要穿着护甲就免疫, 与层数无关
	//   寄生吸血 DMG_INFEST  =1<<25 (33554432)
	//   火焰     DMG_BURN    =1<<3  (8) / DMG_PLASMA=1<<24 (16777216)
	//   毒气手雷 DMG_NERVEGAS=1<<16 (65536)
	// 火焰 DoT 常带 DMG_DIRECT(1<<28) 走 ASW_Ignite 持续伤害路径, 引擎
	// ApplyPassiveArmorEffects 覆盖不到, 故在 VScript 钩子里直接归零。
	// asw_fire.cpp:1185 确认自然火/燃烧地雷=DMG_BURN, 其它火=DMG_PLASMA。
	// 毒气: asw_gamerules.cpp:1509 弹药类型=DMG_NERVEGAS; 毒云伤害由
	// asw_radiation_volume.cpp:142-145 设置 (weapon=asw_gas_grenade_projectile)。
	// 类名兜底: 防 DMG_NERVEGAS 位值在不同二进制有差异 (原插件 asrd_armor.sp:80
	// 的免伤列表同时含 asw_gas_grenade_projectile)。
	if (armorEnt != null)
	{
		local immune = (damageType & (33554432 | 8 | 16777216 | 65536)) != 0;
		if (!immune)
		{
			try
			{
				if (weapon != null && weapon.IsValid() && weapon.GetClassname() == "asw_gas_grenade_projectile")
				{
					immune = true;
				}
			}
			catch (e) {}
		}
		if (immune)
		{
			return 0.0;
		}
	}

	// 精英自爆虫脚踢: 固定 200 (引擎原版 4~6, 见 asw_boomer.cpp:39-40);
	// 仅精英波变异出的自爆虫 (g_eliteIdx), 地图预刷的普通自爆虫保持原版 4~6
	// 小炸弹爆炸 (DMG_BLAST = 1<<2 = 4) 保持原版 55, 不做放大
	// (炮弹 attacker 就是爆虫本体, 见 asw_ai_behavior_explode.cpp:415 / asw_boomer_blob.cpp:315)
	if (attacker != null && attacker.IsValid())
	{
		try
		{
			if (attacker.GetClassname() == "asw_boomer")
			{
				local bidx = attacker.entindex();
				local inElite = (bidx in g_eliteIdx);
				local isBlast = ((damageType & 4) != 0);
				// 诊断日志: 确认脚踢分支为何命中/未命中 (仅 boomer 攻击时打印, 不刷屏)
				try
				{
					printl("[护送][脚踢诊断] boomer idx=" + bidx
						+ " elite=" + (inElite ? "1" : "0")
						+ " blast=" + (isBlast ? "1" : "0")
						+ " dtype=" + damageType
						+ " rawDmg=" + damage
						+ " armorMul=" + armorMul);
				}
				catch (e) {}
				if (inElite && !isBlast)
				{
					return BOOMER_MELEE_DMG * armorMul;
				}
			}
		}
		catch (e) {}
	}

	// 精英追踪虫: 攻击力 x2 (追踪虫由引擎普通虫变异而来, 种类不固定,
	// 故按 g_trackers 记录的 entindex 判定, 不做 classname 判断)
	if (attacker != null && attacker.IsValid())
	{
		try
		{
			if (attacker.entindex() in g_trackers)
			{
				return damage * TRACKER_DMG_MULT * armorMul;
			}
		}
		catch (e) {}
	}

	// 精英自爆虫被打死: 引擎爆炸炮弹数硬编码最多 8 只 (asw_boomer.cpp:310 max_projectiles="8",
	// 实际数量 = (8+1)*buildup进度, 上限 8, 见 asw_ai_behavior_explode.cpp:374-377),
	// 死亡瞬间在此补生成 BOOMER_EXTRA_BLOBS 只, 凑到 8+54=62
	try
	{
		local vidx = victim.entindex();
		if ((vidx in g_boomers) && victim.GetClassname() == "asw_boomer" && (victim.GetHealth() - damage) <= 0)
		{
			// 先注销记录, TickBoomerDeaths 就不会再补一次
			delete g_boomers[vidx];
			if (vidx in g_boomerEnt) { delete g_boomerEnt[vidx]; }
			SpawnBoomerExtraBlobs(victim.GetOrigin(), victim);
		}
	}
	catch (e) {}

	// 增强哨戒塔: 机枪/喷火塔伤害 x2 (m_fDamageScale 无 netprop/datamap 注册无法脚本写;
	// 炮塔走 txt 下发的 asw_sentry_top_cannon_dmg_override 120, 此处不叠乘)
	if (attacker != null && attacker.IsValid())
	{
		local scls = "";
		try { scls = attacker.GetClassname(); } catch (e) { scls = ""; }
		if (scls == "asw_sentry_top_machinegun" || scls == "asw_sentry_top_flamer")
		{
			damage = damage * SENTRY_DMG_MULT;
		}
		else if (scls == "asw_sentry_base")
		{
			// 子弹 attacker 也可能是底座: 按枪型区分, 炮塔(1)跳过防与 ConVar 叠乘
			local gt = 0;
			try { gt = NetProps.GetPropInt(attacker, "m_nGunType"); } catch (e) { gt = 0; }
			if (gt != 1)
			{
				damage = damage * SENTRY_DMG_MULT;
			}
		}
	}

	// 增强黏弹发射器: 火箭 (asw_rocket) 对门的伤害对齐对虫伤害 (引擎半径 50 衰减后对门远低于 120)
	if (inflictor != null && inflictor.IsValid())
	{
		local vcls = "";
		try { vcls = victim.GetClassname(); } catch (e) { vcls = ""; }
		if (vcls == "asw_door")
		{
			try { if (inflictor.GetClassname() == "asw_rocket") { damage = 120.0; } } catch (e) {}
		}
	}

	// 增强武器伤害 (仅购买/空投掉落的标记武器生效, 与原插件"仅掉落枪增强"一致):
	// 增强电锯 x10。守望者脉冲步枪不在这里处理: 它的基础伤害统一由挑战 convar
	// rd_ar2_dmg_base=100 抬高 (见 asrd_points_c3.txt), 这样对虫子/虫卵/门 都是同一个值
	if (weapon != null && weapon.IsValid() && (weapon.entindex() in g_tintWpn))
	{
		local wcls = weapon.GetClassname();
		if (wcls == "asw_weapon_chainsaw")
		{
			damage = damage * CHAINSAW_DAMAGE_MULT;
		}
	}

	// 守望者下挂能量球 (prop_combine_ball, 见 asw_weapon_ar2_shared.cpp) 单发 10000
	if (inflictor != null && inflictor.IsValid() && inflictor.GetClassname() == "prop_combine_ball")
	{
		damage = AR2_BALL_DAMAGE;
	}
	local isAlien = false;
	try { isAlien = victim.IsAlien(); } catch (e) { isAlien = false; }
	if (!isAlien)
	{
		return damage * armorMul;
	}


	// 普通近战 (DMG_CLUB=128) 按攻击者强化等级加成; 电锯是 DMG_SLASH, 不受影响
	if (attacker != null && attacker.IsValid() && (damageType & 128) != 0)
	{
		local m = null;
		if (attacker.GetClassname() == "asw_marine")
		{
			m = attacker;
		}
		else if (attacker.GetClassname() == "player")
		{
			m = GetMarineOfPlayer(attacker);
		}
		if (m != null)
		{
			local lvl = GetPowerLevel(m);
			if (lvl > 0 && lvl <= POWER_MAX_LEVEL)
			{
				damage = damage * MELEE_MULT[lvl];
			}
		}
	}

	// 哨戒塔伤害不折算积分 (哨戒塔消耗靠购买时的积分, 击杀也不给分, 见 IsPlayerSource)

	return damage * armorMul;
}

// ============================================================
//  导轨步枪射速 (原 asrd_railgun 的 fire_interval)
// ============================================================
function OnGameEvent_weapon_fire(params)
{
	if (!("weapon" in params))
	{
		return;
	}
	local w = EntIndexToHScript(params["weapon"]);
	if (w == null || !w.IsValid())
	{
		return;
	}
	if (w.GetClassname() != "asw_weapon_railgun")
	{
		return;
	}
	local now = Time();
	g_railFireAt[w.entindex()] <- now;   // 记录开火时刻 (每拍兜底钳制用)
	TrySetFloat(w, "m_flNextPrimaryAttack", now + RAILGUN_FIRE_INTERVAL);
}

// ============================================================
//  任务结束: 停止护送判定 + 清理自定义实体 (必须早于换图, 否则残留实体跨作用域)
// ============================================================
function OnGameEvent_mission_success(params)
{
	SucceedMission();
}

function OnGameEvent_mission_failed(params)
{
	// 引擎判负 (超时/全灭/objective 失败) 不经过 FailEscort, 必须在这里补播失败文案
	BroadcastFail();
	g_escortDone = true;
	FinishMission();
}

// 即时重开 (!restart) 会直接 ChangeLevel, 且不会触发 mission_success/failed
// (asw_gamerules.cpp:3191 发事件, 3221-3225 换图), 必须同样清理
function OnGameEvent_asw_mission_restart(params)
{
	FinishMission();
}

// ============================================================
//  聊天命令
// ============================================================
function OnGameEvent_player_say(params)
{
	if (!("text" in params) || params["text"] == null)
	{
		return;
	}
	if (!("userid" in params) || params["userid"] == null)
	{
		return;
	}

	local raw = params["text"];
	if (raw.len() < 1)
	{
		return;
	}

	local prefix = raw.slice(0, 1);
	if (prefix != "#" && prefix != "/" && prefix != "!")
	{
		return;
	}

	local hPlayer = GetPlayerFromUserID(params["userid"]);
	if (hPlayer == null || !hPlayer.IsValid())
	{
		return;
	}

	local tokens = Tokenize(raw.slice(1, raw.len()).tolower());
	if (tokens.len() < 1)
	{
		ShowHelp(hPlayer);
		return;
	}

	local cmd = tokens[0];
	local opt = (tokens.len() > 1) ? tokens[1] : "";

	if (cmd == "buy")
	{
		if (opt == "")
		{
			ShowHelp(hPlayer);
			return;
		}
		local opt2 = (tokens.len() > 2) ? tokens[2] : "";
		Buy(opt, opt2, hPlayer);
		return;
	}
	if (cmd == "1") { BuyPower(hPlayer); return; }
	if (cmd == "2") { BuyNuke(hPlayer); return; }
	if (cmd == "4") { BuySentry(hPlayer, opt); return; }
	if (cmd == "6") { BuyWeapon(hPlayer, opt); return; }
	if (cmd == "7") { BuyArmor(hPlayer); return; }
	if (cmd == "9") { BuyAmmo(hPlayer); return; }

	if (cmd == "points")
	{
		Reply(hPlayer, "当前全队积分：" + g_points);
		return;
	}

	// 兼容原功能命令
	if (cmd == "nukepub") { BuyNuke(hPlayer); return; }
	if (cmd == "power_up" || cmd == "powerup") { BuyPower(hPlayer); return; }
	if (cmd == "power_down" || cmd == "powerdown")
	{
		Reply(hPlayer, "积分挑战不支持降级");
		return;
	}
	if (cmd == "power_reset" || cmd == "powerreset")
	{
		Reply(hPlayer, "积分挑战不支持重置等级");
		return;
	}

	// 单独输入 #1 之类已被上面处理; 其它未知命令忽略 (不刷屏)
}

function Buy(cat, opt, hPlayer)
{
	local n = cat.tointeger();
	switch (n)
	{
		case 1: BuyPower(hPlayer); return;
		case 2: BuyNuke(hPlayer); return;
		case 4: BuySentry(hPlayer, opt); return;
		case 6: BuyWeapon(hPlayer, opt); return;
		case 7: BuyArmor(hPlayer); return;
		case 9: BuyAmmo(hPlayer); return;
	}
	Reply(hPlayer, "未知购买分类：" + cat + "（#buy 查看帮助）");
}

function ShowHelp(hPlayer)
{
	Reply(hPlayer, "当前积分：" + g_points + "  |  输入 #buy <分类> [编号] 购买");
	Reply(hPlayer, "#1 全队强化 +1 (500)  ※护送目标不参与强化");
	Reply(hPlayer, "#2 强化核弹 (200)");
	Reply(hPlayer, "#4 [0/1] 哨戒塔箱 (300):");
	Reply(hPlayer, "　　0机枪 1炮塔");
	Reply(hPlayer, "#6 [1-5] 武器 (300):");
	Reply(hPlayer, "　　1增强型电锯 2守望者脉冲步枪 3增强黏弹发射器");
	Reply(hPlayer, "　　4导轨步枪 5AVK-36神射手步枪");
	Reply(hPlayer, "#7 动力护甲 (300)");
	Reply(hPlayer, "#9 弹药掉落 (100)");
	Reply(hPlayer, "#points 查询积分 | 血量低于30自动开力场护盾 (全队120秒冷却)");
}

// ============================================================
//  任务详情购买说明 (复刻原 asrd_points 插件的 SpawnBuyHelpObjectives:
//  asw_objective_dummy 是游戏自带的纯文字目标实体, 标题经 SendProp 下发,
//  显示在任务详情的目标列表里 (简报/准备阶段也能看到), 点击后右侧面板
//  显示 4 段说明 (objectivedescription1~4, 段内 \n 换行);
//  m_bOptional=1 + m_bComplete=1: 不参与通关判定, 不拉低任务统计)
// ============================================================
function SpawnBuyHelpObjectives()
{
	local d1 = "#buy 1 全队强化+1级 (" + COST_POWER + "分) ※护送目标除外\n"
		+ "#buy 2 战术核弹 (" + COST_NUKE + "分, 冷却" + NUKE_COOLDOWN.tointeger() + "秒)";
	local d2 = "#buy 4 0/1 哨戒塔箱 (" + COST_SENTRY + "分): 0机枪 1炮塔\n"
		+ "#buy 6 1 增强型电锯 (" + COST_WEAPON + "分)\n"
		+ "#buy 6 2 守望者脉冲步枪 (" + COST_WEAPON + "分)";
	local d3 = "#buy 6 3 增强型黏弹发射器 (" + COST_WEAPON + "分)\n"
		+ "#buy 6 4 导轨步枪 (" + COST_WEAPON + "分)\n"
		+ "#buy 6 5 AVK-36 神射手步枪 (" + COST_WEAPON + "分)\n"
		+ "#buy 7 动力护甲 (" + COST_ARMOR + "分)";
	local d4 = "#buy 9 掉落弹药 (" + COST_AMMO + "分)\n"
		+ "积分来源: 击杀虫族 (血量越多积分越多)";

	local ent = Entities.CreateByClassname("asw_objective_dummy");
	if (ent == null)
	{
		return;
	}
	ent.__KeyValueFromString("objectivetitle", "积分购买说明 (点击看详情)");
	ent.__KeyValueFromString("objectivedescription1", d1);
	ent.__KeyValueFromString("objectivedescription2", d2);
	ent.__KeyValueFromString("objectivedescription3", d3);
	ent.__KeyValueFromString("objectivedescription4", d4);
	ent.Spawn();
	try { NetProps.SetPropInt(ent, "m_bOptional", 1); } catch (e) {}
	try { NetProps.SetPropInt(ent, "m_bComplete", 1); } catch (e) {}
	g_objHelp = ent;   // 保存句柄, 供换图前 CleanupOnMissionEnd() 清理
}
