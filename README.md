# Alien Swarm: Reactive Drop — 服务器管理插件

适用于 **Alien Swarm: Reactive Drop** (AppID 563560) 的 SourceMod 插件集合。

## 📦 包含的插件

| 插件 | 文件 | 功能 |
|------|------|------|
| AFK 自动踢人 | `asrd_afk_kick.smx` | 检测挂机玩家，5分钟无操作自动踢出 |
| 欢迎/告别消息 | `asrd_welcome.smx` | 玩家进出服务器时广播打招呼语 |
| 电锯高速旋转 | `asrd_chainsaw_turbo.smx` | 手持电锯按攻击键时高速旋转，转速可调 |
| 哨戒塔增强 | `asrd_sentry_enhancer.smx` | 哨戒塔属性倍率增强 + 头顶哨戒塔 |
| 陆战队员强化 | `asrd_marine_power.smx` | 按键调大/调小血量/体型/移速与近战，放大5级+缩小3级 |
| 叛变虫群 | `asrd_alien_civilwar.smx` | 生成一批攻击虫族(而非玩家)的着色叛变虫，可自选虫种、免冷却 |
| 一键开锁 | `asrd_unlock.smx` | 一键破解门锁 mini-game，直接解锁上锁的按钮区/大门 |

> 所有插件的**命令与 ConVar 设置**详见 [插件命令总览](插件命令总览.md)。

## 🔧 前置要求

- **MetaMod:Source** 1.12+
- **SourceMod** 1.11+
- 无额外扩展依赖（不依赖 SDKHooks）

> ⚠️ **注意:** AS:RD 使用 Alien Swarm 引擎分支，部分 SourceMod 扩展（如 SDKHooks）存在兼容性问题。本插件刻意避免了这些依赖，仅使用 SourceMod 核心 API。

## 📥 安装步骤

### 1. 安装 MetaMod:Source 和 SourceMod

```bash
# 下载 MetaMod:Source
# https://www.sourcemm.net/downloads.php

# 下载 SourceMod
# https://www.sourcemod.net/downloads.php
```

安装到服务器目录：
```
reactivedrop/
└── addons/
    ├── metamod/
    │   └── ...
    └── sourcemod/
        ├── plugins/
        ├── scripting/
        ├── configs/
        └── ...
```

### 2. 编译插件

**方法 A: 在线编译**
1. 访问 https://www.sourcemod.net/compiler.php
2. 上传 `scripting/asrd_afk_kick.sp`
3. 下载生成的 `asrd_afk_kick.smx`
4. 同样操作 `asrd_welcome.sp`

**方法 B: 本地编译**
```bash
# 将 .sp 文件放入 addons/sourcemod/scripting/
# 运行编译器
cd addons/sourcemod/scripting/
./spcomp asrd_afk_kick.sp -o ../plugins/asrd_afk_kick.smx
./spcomp asrd_welcome.sp -o ../plugins/asrd_welcome.smx
```

### 3. 安装编译好的插件

将 `.smx` 文件放入：
```
reactivedrop/addons/sourcemod/plugins/
```

### 4. 重启服务器或加载插件

```bash
# 方法1: 重启服务器

# 方法2: 在服务器控制台或 RCON 中加载
sm plugins load asrd_afk_kick
sm plugins load asrd_welcome
```

## ⚙️ 插件功能说明

### AFK 自动踢人 (`asrd_afk_kick`)

检测挂机玩家，5 分钟无操作自动踢出（时间可调）。检测依据：WASD 移动、鼠标按键、切换武器/使用物品；**不检测聊天消息**；拥有 `kick` 权限的管理员豁免。

### 欢迎/告别消息 (`asrd_welcome`)

玩家进出服务器时广播打招呼语，支持自定义消息内容与 `{player}`/`{count}`/`{country}` 变量，可播放加入音效。

### 电锯高速旋转 (`asrd_chainsaw_turbo`)

玩家手持电锯且**按住攻击键**时锯片高速旋转（旋转 + 伤害 + 音效由游戏原生接管，只是更快），**松开攻击键立即恢复默认速度**；换掉电锯后不再生效。

### 哨戒塔增强 (`asrd_sentry_enhancer`)

增强地图哨戒塔（生命/射速/射程/弹药/伤害可单独微调），支持无敌、关闭误伤队友，并可将塔放到头顶当随行炮台，带信息 HUD。

### 陆战队员强化 (`asrd_marine_power`)

按键实时调大/调小自己的血量、体型、移速与近战，放大 5 级 + 缩小 3 级，普通玩家默认可自行强化。

### 叛变虫群 (`asrd_alien_civilwar`)

生成一批**攻击虫族、而不是玩家**的叛变虫，外观着色（默认绿色）区分，免冷却，可自选虫种。支持 drone 体型缩放、叛变虫攻击力增强（默认 4 倍，仅影响叛变虫造成的伤害）。想让叛变虫立刻开打，最好在虫潮进攻时召唤——叛变虫会就近寻找普通虫族交战。

### 一键开锁 (`asrd_unlock`)

一键破解游戏内的门锁 mini-game（连线拼图/转盘破解），直接解锁上锁的按钮区（大门）让任务继续。可解锁以玩家为中心一定范围内的最近门锁，或由管理员解锁整图。

## 🧪 测试

```bash
# 查看插件状态
sm plugins list

# 查看 AFK 插件信息
sm plugins info asrd_afk_kick

# 手动重载插件
sm plugins reload asrd_afk_kick
sm plugins reload asrd_welcome
```

## 📝 AFK 检测逻辑

插件通过 `OnPlayerRunCmd` 每帧检测玩家操作：

- **WASD 移动** — 任何方向的移动输入都会重置计时
- **鼠标按键** — 开火/技能/换弹等
- **切换操作** — 切换武器、使用物品等

**不检测聊天消息** — 仅凭聊天不能证明在游戏（可以挂机发消息）。如需添加聊天检测，可自行修改。

**管理员豁免** — 拥有 `kick` 权限（ADMFLAG_KICK）的管理员不会被 AFK 踢出。

## ⚠️ 已知限制

1. **SDKHooks 不兼容** — AS:RD 的 Alien Swarm 引擎分支不完全支持 SDKHooks 扩展，因此本插件刻意不依赖它
2. **GeoIP 扩展** — 国家显示功能需要 `geoip` 扩展支持，默认关闭
3. **观战玩家** — 阵亡后观战的玩家如果没有操作也会被计入 AFK 时间。如遇问题可适当延长 `sm_asrd_afk_kick_time`

## 📂 项目结构

```
asrd-plugins/
├── scripting/
│   ├── asrd_afk_kick.sp      # AFK踢人插件源码
│   └── asrd_welcome.sp       # 欢迎消息插件源码
├── plugins/
│   ├── asrd_afk_kick.smx     # 编译后的AFK插件
│   └── asrd_welcome.smx      # 编译后的欢迎插件
└── README.md
```

## 🔗 相关链接

- [Alien Swarm: Reactive Drop 开发者 FAQ](https://developer.reactivedrop.com/faq.html)
- [SourceMod 官网](https://www.sourcemod.net/)
- [MetaMod:Source 官网](https://www.sourcemm.net/)
- [SourcePawn API 文档](https://sm.alliedmods.net/new-api/)
- [AS:RD GitHub (开源代码)](https://github.com/ReactiveDrop/reactivedrop_public_src)
