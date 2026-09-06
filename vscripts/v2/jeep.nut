// ============================================================================
//  [AS:RD] 载具(jeep) 独立模块 —— 仅管理员调用
//  部署: 与 mapspawn.nut 放在同一目录 <游戏目录>\reactivedrop\scripts\vscripts\
//
//  注意: 本文件故意【不】做 `if (!("SendToConsole" in this)) return` 顶部守卫,
//  因为被 IncludeScript 引入的脚本若带声该守卫会被直接短路、函数全部失效。
//  本文件只定义全局函数(用 :: 前缀进 root), 由 mapspawn.nut 在 player_say 里调用。
//
//  命令(均在 mapspawn.nut 里做管理员校验):
//    /j  /j2  生成一辆吉普车 (asw_vehicle_jeep + models/buggy.mdl)
//    /jk      删除所有已生成的吉普车
//
//  依赖(已验证都存在于原版 RD, 不需改 dll):
//    - 载具实体类 asw_vehicle_jeep       (server.dll 已编译)
//    - 物理脚本 scripts/vehicles/jeep_test.txt (原版自带)
//    - 模型 models/buggy.mdl 全套资源   (原版 pak01/pak02 自带, 引擎自动加载)
// ============================================================================

// 已生成车辆句柄表(单人模式/换图时本模块被重新 Include 则自动清空)
::ASRD_Jeeps <- [];

// 生成一辆吉普车(在调用者面前约 1.5 米、略高, 朝向与调用者一致); 成功 true 否则 false
::ASRD_SpawnJeep <- function(hPlayer)
{
    // 拿到玩家当前 marine 做为生成参考点
    local hMarine = null;
    if (hPlayer && hPlayer.IsValid())
    {
        if (("GetMarine" in hPlayer)) { try { hMarine = hPlayer.GetMarine(); } catch(e) {} }
        if (hMarine == null || !hMarine.IsValid())
            hMarine = Entities.FindByClassname(null, "asw_marine");
    }
    else
    {
        hMarine = Entities.FindByClassname(null, "asw_marine");
    }

    if (hMarine == null || !hMarine.IsValid())
    {
        ClientPrint(null, 3, "载具生成失败：找不到可用的陆战队员");
        return false;
    }

    local jeep = null;
    try
    {
        jeep = Entities.CreateByClassname("asw_vehicle_jeep");
    }
    catch(e) { jeep = null; }

    if (jeep == null)
    {
        ClientPrint(null, 3, "载具生成失败：服务端不支持该实体(asw_vehicle_jeep)");
        return false;
    }

    try
    {
        local fwd = hMarine.GetForwardVector();
        local origin = hMarine.GetOrigin() + Vector(fwd.x * 150, fwd.y * 150, fwd.z * 150) + Vector(0, 0, 50);
        jeep.SetOrigin(origin);
        if (("SetAnglesVector" in jeep)) jeep.SetAnglesVector(hMarine.GetAngles());
        jeep.PrecacheModel("models/buggy.mdl");
        jeep.__KeyValueFromString("model", "models/buggy.mdl");
        jeep.__KeyValueFromString("vehiclescript", "scripts/vehicles/jeep_test.txt");
        jeep.Spawn();
        jeep.Activate();
        ::ASRD_Jeeps.append(jeep);
    }
    catch(e)
    {
        ClientPrint(null, 3, "载具生成失败(异常): " + e);
        return false;
    }

    if (hPlayer && hPlayer.IsValid())
        ClientPrint(null, 3, hPlayer.GetPlayerName() + "：生成了一辆吉普车");
    return true;
}

// 删除所有已生成的吉普车
::ASRD_DeleteJeeps <- function()
{
    local n = 0;
    foreach (j in ::ASRD_Jeeps)
    {
        if (j && j.IsValid())
        {
            try { DoEntFire("!self", "Kill", "", 0, null, j); } catch(e) {}
            n++;
        }
    }
    ::ASRD_Jeeps.clear();
    ClientPrint(null, 3, "已删除 " + n + " 辆吉普车");
}