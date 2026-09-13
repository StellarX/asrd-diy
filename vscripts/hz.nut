// 轰炸区脚本
ClientPrint(null, 3, "[系统]:已开启轰炸区，随机抽取倒霉蛋！！");
ClientPrint(null, 3, "[系统]:已开启轰炸区，随机抽取倒霉蛋！！");
function StartBombingZone()
{
    // 1. 定义可供随机选择的目标角色列表
    local targetList = [
        "#asw_name_jaeger",
        "#asw_name_wolfe", 
        "#asw_name_faith",
        "#asw_name_bastille",
        "#asw_name_sarge",
        "#asw_name_wildcat", 
        "#asw_name_vegas",
        "#asw_name_crash"
    ];
    
    // 2. 随机选择一个目标
    local randomIndex = RandomInt(0, targetList.len() - 1);
    local selectedTarget = targetList[randomIndex];
    
    // 3. 查找目标实体并获取其位置
    local targetEntity = Entities.FindByName(null, selectedTarget);
    local bombPos = targetEntity.GetOrigin();
        
    // 4. 依次释放四种炸弹，略有间隔以避免完全重叠
    DropStunGrenade(50.0, 300.0, bombPos + Vector(0,0,100));
    DropFragGrenade(100.0, 250.0, bombPos + Vector(0,0,200));
    DropGasGrenade(20.0, 0.5, 25.0, 1.5, bombPos + Vector(0,0,300));
    DropIncendiaryGrenade(75.0, 200.0, bombPos + Vector(0,0,300));
}

local timer = Entities.CreateByClassname("logic_timer");
timer.__KeyValueFromString("RefireTime", "10"); // 间隔秒
timer.ConnectOutput("OnTimer", "StartBombingZone");
EntFireByHandle(timer, "Enable", "", 0.0, null, null);



