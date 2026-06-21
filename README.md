# Alien Swarm: Reactive Drop — 服务器管理插件

适用于 **Alien Swarm: Reactive Drop** (AppID 563560) 的 SourceMod 插件集合。

## 📦 包含的插件

| 插件 | 文件 | 功能 |
|------|------|------|
| AFK 自动踢人 | `asrd_afk_kick.smx` | 检测挂机玩家，5分钟无操作自动踢出 |
| 欢迎/告别消息 | `asrd_welcome.smx` | 玩家进出服务器时广播打招呼语 |

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

## ⚙️ 配置说明

### AFK 自动踢人 (`asrd_afk_kick`)

配置文件自动生成在 `cfg/sourcemod/asrd_afk_kick.cfg`

| CVar | 默认值 | 说明 |
|------|--------|------|
| `sm_asrd_afk_enabled` | `1` | 启用/禁用插件 (0=禁用, 1=启用) |
| `sm_asrd_afk_kick_time` | `300` | 挂机多少秒后踢出 (默认300=5分钟) |
| `sm_asrd_afk_warn_time` | `240` | 挂机多少秒后警告 (默认240=4分钟) |
| `sm_asrd_afk_check_interval` | `10` | 检测间隔秒数 (默认10秒) |

**示例：改为10分钟踢出**
```
sm_asrd_afk_kick_time 600
sm_asrd_afk_warn_time 540
```

### 欢迎/告别消息 (`asrd_welcome`)

配置文件自动生成在 `cfg/sourcemod/asrd_welcome.cfg`

| CVar | 默认值 | 说明 |
|------|--------|------|
| `sm_asrd_welcome_enabled` | `1` | 启用/禁用插件 |
| `sm_asrd_welcome_msg` | `欢迎 {player} 加入服务器！当前在线: {count} 人` | 加入广播消息 |
| `sm_asrd_goodbye_msg` | `{player} 离开了服务器，当前在线: {count} 人` | 离开广播消息 |
| `sm_asrd_welcome_personal` | `1` | 是否向加入者发送专属欢迎信息 |
| `sm_asrd_show_country` | `0` | 是否显示玩家国家/地区 |
| `sm_asrd_welcome_sound` | `""` | 加入音效路径 (留空不播放) |

**支持的变量:**
- `{player}` — 玩家名称
- `{count}` — 当前在线人数
- `{country}` — 玩家国家/地区 (需启用 `sm_asrd_show_country`)

**自定义消息示例:**
```
sm_asrd_welcome_msg "🎮 {player} 上线了！服务器现有 {count} 人"
sm_asrd_goodbye_msg "👋 {player} 溜了，还剩 {count} 个战友"
sm_asrd_welcome_sound "ui/menu_enter.wav"
```

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
