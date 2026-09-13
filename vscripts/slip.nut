ClientPrint(null, 3, "[系统]:小心地滑！！小心地滑！！小心地滑！！");
ClientPrint(null, 3, "[系统]:小心地滑！！小心地滑！！小心地滑！！");
function Slip()
{
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
local randomIndex = RandomInt(0, targetList.len() - 1);
local selectedTarget = targetList[randomIndex];
DoEntFire(selectedTarget, "RunScriptCode", "self.Knockdown(Vector(2,2,2))", 0.0, null, null);
DoEntFire(selectedTarget, "RunScriptCode", "self.SetVelocity(self.GetForwardVector()*700 + Vector(0, 0, 300))", 0.0, null, null);
ClientPrint(null, 3, "有人滑倒了！！！怎么这么不小心？？？");
}
local timer = Entities.CreateByClassname("logic_timer");
timer.__KeyValueFromString("RefireTime", "12"); // 间隔秒
timer.ConnectOutput("OnTimer", "Slip");
EntFireByHandle(timer, "Enable", "", 0.0, null, null);