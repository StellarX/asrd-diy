# [AS:RD] 变身油桶人 指令说明

插件版本：v7.0.0
配置文件：`cfg/sourcemod/asrd_barrel.cfg`（重载插件时自动生成/更新）

---

## 一、管理员命令

| 命令 | 权限 | 说明 |
|------|------|------|
| `sm_barrel <userid\|名字>` | ADMFLAG_SLAY（管理员） | 把目标变成油桶人。变身后直到战死才解除变身。目标支持 userid 或名字片段。 |

---

## 二、ConVar 参数

### 变身相关

| ConVar | 默认值 | 说明 |
|--------|--------|------|
| `asrd_barrel_health` | `2000` | 变身油桶人的血量 |
| `asrd_barrel_bodyscale` | `2.0` | 变身时跟随身体油桶模型的放大倍数（仅限身体的桶，扔出的桶保持原大小） |

### 扔桶相关

| ConVar | 默认值 | 说明 |
|--------|--------|------|
| `asrd_barrel_throwcooldown` | `1.5` | 扔桶冷却时间（秒） |
| `asrd_barrel_throwspeed` | `750.0` | 扔桶初速度 |
| `asrd_barrel_throwup` | `300.0` | 扔桶附加向上速度（从脚底抛出，决定弧线高度） |
| `asrd_barrel_throwdamage` | `500` | 扔出的桶落地爆炸伤害 |
| `asrd_barrel_throwradius` | `280` | 扔出的桶落地爆炸半径 |
| `asrd_barrel_throwfuse` | `1.0` | 扔出的桶引信时间（秒），落地更早则更早炸 |

> 扔出的桶爆炸只对场景可破坏物和敌对生物造成伤害，不会伤害陆战队员（队友和自己）。

### 高跳相关

| ConVar | 默认值 | 说明 |
|--------|--------|------|
| `asrd_barrel_jumpboost` | `345.0` | 高跳向上速度（正常跳跃约 335 / 70 高） |
| `asrd_barrel_jumpcooldown` | `1.0` | 高跳落地冷却（秒），防止连续跳 |

### 死亡自爆相关

| ConVar | 默认值 | 说明 |
|--------|--------|------|
| `asrd_barrel_explodedamage` | `5000` | 油桶人死亡爆炸伤害 |
| `asrd_barrel_exploderadius` | `260` | 油桶人死亡爆炸半径 |

> 死亡自爆对所有东西造成高额伤害，包括队友（不豁免任何实体）。

---

## 三、操作说明

- **变身**：管理员执行 `sm_barrel <目标>`，变身期间直到战死才解除
- **扔桶**：按鼠标左键（`IN_ATTACK`），按一下扔一次，冷却结束才能再扔；8 个方向各抛出一个油桶
- **高跳**：按跳跃键（`IN_JUMP`），仅在落地时触发，落地后有冷却
- **死亡**：战死时触发死亡自爆，伤害所有目标，包括队友

## 四、修改参数示例

```c
// 服务器控制台（或 cfg 文件）直接设置
asrd_barrel_explodedamage 8000
asrd_barrel_throwcooldown 2.0
```

重载插件生效：`sm plugins reload asrd_barrel`
