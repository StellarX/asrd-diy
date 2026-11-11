// ============================================================
//  积分挑战 - 客户端 HUD (单行)
//  每名玩家有若干个 rd_hud_vscript 实体, 每个实体负责一行:
//  服务端 SetInt(0) = 行号 (0 积分/1 强化/2 护甲/3.. 护送每 VIP 一行/末行 护盾),
//  SetString(0) = 该行文本 (rd_hud_vscript 只允许字符串索引 0, 见 rd_hud_vscript_shared.cpp)
// ============================================================

FONT_POINTS <- self.LookupFont("DefaultMedium");

function Paint()
{
	// 只显示给 HUD 绑定的那个玩家
	if (self.GetEntity(0) != GetLocalPlayer())
	{
		return;
	}

	local s = self.GetString(0);
	if (s == null || s == "")
	{
		return;
	}

	local line = self.GetInt(0);
	local x = 40;
	local lineH = self.GetFontTall(FONT_POINTS) + 6;
	local y = 40 + line * lineH;
	local w = self.GetTextWide(FONT_POINTS, s);

	self.PaintRectangle(x - 10, y - 4, x + w + 10, y + lineH - 2, 0, 0, 0, 120);
	self.PaintText(x, y, 255, 255, 170, 255, FONT_POINTS, s);
}
