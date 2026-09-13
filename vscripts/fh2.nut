ClientPrint(null, 3, "[系统]:已开启周期性复活，请你战至最后一刻！！");
function TimerCallback() {
    // 这是您要每30秒执行的代码
    DoEntFire("player", "RunScriptCode", "self.ResurrectMarine(Entities.FindByClassname(null, \"asw_marine\").GetOrigin(), true)", 3.0, null, null);
	DoEntFire("asw_marine", "RunScriptCode", "PlaceHealBeacon(1000, 1000, 1000, 8, 50, self.GetOrigin() + self.GetForwardVector() + Vector(0, 0, 0))", 4.0, null, null);
	ClientPrint(null, 3, "[系统]:死了就玩手机？");
}
// 创建永久计时器
local timer = Entities.CreateByClassname("logic_timer");
timer.__KeyValueFromString("RefireTime", "25"); // 间隔30秒
timer.ConnectOutput("OnTimer", "TimerCallback");
EntFireByHandle(timer, "Enable", "", 0.0, null, null);