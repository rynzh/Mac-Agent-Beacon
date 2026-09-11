# Mac Agent Beacon

让 MacBook 的 Caps Lock 小绿灯，成为后台 AI 编程任务的状态灯。

任务跑着时不用一直盯着窗口；需要你批准或处理失败时，看一眼键盘就知道。
**常亮 = 工作中 · 快闪 = 需要关注 · 熄灭 = 已完成 / 空闲。**

macOS 本地运行，不需要额外 API Key、付费服务、Homebrew 或 Node.js。
默认只控制灯，不模拟按键、不改变 Caps Lock 的逻辑状态、不修改键位映射。

> **实验性项目，不是通用即装即用的成熟产品。** 当前主要验证了一个 MacBook 环境。
> Codex Desktop 实时审批依赖内部接口；键盘型号、Karabiner 配置及 Codex 更新可能影响兼容性。
> 请先看下面的环境要求，尤其是你仍需要正常使用 Caps Lock 时。

## 30 秒了解功能

| 情况 | 灯光 |
| --- | --- |
| Agent 正在工作；权限自动获批；仍在自动重试 | 常亮 |
| Codex Desktop 确实停下来等待人工批准或结构化输入 | 快闪，约每秒 2.5 次 |
| 最后一个待批准请求解除，任务继续 | 恢复常亮，不等命令执行完 |
| 额度耗尽、网络或权限错误使任务终止失败 | 持续快闪 |
| 观察中的任务与本地实时监听失去连接 | 快闪，表示无法再确认进展 |
| 正常完成或空闲 | 熄灭 |

多个任务同时运行时：**需要关注优先于工作中**。失败提醒不会被同一轮的普通结束事件盖掉；新一轮任务可清除该任务的失败状态。

这里的“网络失败”指 Codex 已报告的终止失败；短暂断网但仍在重试时保持常亮。
本地监听断开不等于互联网断开。没有错误信号的静默卡住不会靠“多久没输出”来猜。
普通文字“你回复同意后我再做”目前不做语义识别。

## 环境要求

| 项目 | 要求 / 已知范围 |
| --- | --- |
| 系统 | macOS；已测 macOS 15.5，其他版本需要验证 |
| 键盘 | 系统识别为 `Apple Internal Keyboard / Trackpad` 的内置键盘；外接键盘、Magic Keyboard 不支持 |
| 编译环境 | Xcode Command Line Tools 或完整 Xcode，包含 `clang`、Apple SDK、`make`、`git` |
| 运行环境 | 系统 `/usr/bin/ruby` 2.6+、`sqlite3`；安装器会检查 |
| Agent | 已安装并登录 Codex；Claude Code 可选，安装器不安装这些产品 |
| Codex Desktop | 已测内置 CLI 0.153.4、IPC stream v11；不是对其他版本的兼容承诺 |
| 系统权限 | 为安装后的 `beacon-led` 开启“输入监控” |
| Codex 权限 | 在支持 hooks 的 Codex CLI 中通过 `/hooks` 审核并信任本项目的处理器 |

没有 Apple 编译工具时，先执行并完成系统安装提示，再运行本项目安装命令：

```sh
xcode-select --install
```

目前没有签名、公证的预编译安装包，所以**全新系统可能还需要这一步**。安装器不会擅自安装开发工具或获取管理员权限。

### Caps Lock 和 Karabiner：安装前必读

- **Caps 已经改成 Command 等键：**安装器保留你的映射，但如果 Karabiner 独占内置键盘，仍可能无法访问 LED。
- **Caps 仍用来切换大小写 / 输入法：**功能不会被禁用，但系统也可能改写同一颗灯。当前不能保证灯始终独立显示 Agent 状态。
- **使用 Karabiner：**不要直接禁用整个 Karabiner，否则可能失去你需要的改键。需针对内置设备协调 HID 访问，保留其他设备配置。
- 仓库保留的 `persistence.rb` 是早期特定三键映射方案，**不是默认安装步骤**，新安装器不执行它。已有该方案的用户见 [安全与迁移说明](docs/SAFETY.md)。

## 快速安装

### 从 GitHub 安装：一段命令

在普通终端中运行，**不要加 sudo**：

```sh
curl -fsSL https://raw.githubusercontent.com/rynzh/Mac-Agent-Beacon/main/install.sh | /bin/bash -s -- --repo https://github.com/rynzh/Mac-Agent-Beacon.git
```

此命令下载并执行仓库代码。只在信任项目时使用；想先审查代码，可克隆仓库后运行 `bash install.sh`。
命令取的是 GitHub 上的 `main`；本地尚未 push 的修改不会被下载。

安装器自动完成：

1. 检查 macOS、Ruby 和 Apple 编译工具。
2. 下载源码到临时目录，编译 LED helper 并运行测试。
3. 将程序安装到 `~/Library/Application Support/AgentBeacon/app/`。
4. 备份并合并 Codex hooks，保留已有的其他处理器。
5. 注册当前用户的登录自启服务，并启动控制器；缺少输入监控权限时每 30 秒重试。
6. 输出需要授权的准确文件位置及排障命令。

默认不会修改键位、Karabiner、shell 配置文件、Codex 操作权限或审批策略。
编译失败不安装 hooks / 服务；后续失败会尽量恢复未被并发修改的配置，并保留失败安装副本供排查。

### 然后只做人工授权

**① 系统设置 → 隐私与安全性 → 输入监控**

添加或启用这个文件（可在文件选择框用 `⌘⇧G` 输入路径）：

```text
~/Library/Application Support/AgentBeacon/app/build/beacon-led
```

**② 在 Codex CLI 的 `/hooks` 页面审核本项目处理器并信任。**

命令应指向 `AgentBeacon/app/bin/agent-beacon.rb hook codex`，不是陌生脚本。
不要为了让灯工作而扩大 Codex 的文件权限、关闭审批或信任不相关的 hooks。
参见 [Codex 官方 hooks 文档](https://learn.chatgpt.com/docs/hooks)。

完成后打开 Codex Desktop，开始一个新任务。控制器会自动重试；若系统要求重启应用，先保存工作再重启。
想立即重试，可运行：

```sh
"$HOME/Library/Application Support/AgentBeacon/app/bin/beacon" service restart
```

### 本地安装和可选项

在仓库目录中：

```sh
bash install.sh                  # Codex hooks + 后台服务
bash install.sh --with-claude    # 另外安装 Claude Code hooks
```

| 参数 | 用途 |
| --- | --- |
| `--with-claude` | 同时配置 Claude Code |
| `--no-hooks` | 不更改任何 Agent 配置 |
| `--no-service` | 不注册或启动后台服务，用于手动运行 / 隔离测试 |
| `--prefix PATH` | 安装到独立目录；不能是主目录或文件系统根目录 |
| `--repo URL --ref BRANCH_OR_TAG` | 从指定仓库分支 / 标签下载；发布标签后可固定版本 |

重复安装会安全拒绝，**不会覆盖正在使用的程序、后台服务或已授权的 helper**。目前还没有自动升级器。

## 安装后如何确认

```sh
"$HOME/Library/Application Support/AgentBeacon/app/bin/beacon" status
```

- `controller_running: true`：控制器进程存在，不单独证明灯能写入。
- `output.simulated: false`：不是测试模拟模式。
- 活动任务期间 `live_observer.connected: true` 且 `subscribed > 0`：已收到桌面端任务快照。
- 没有活动任务时订阅数为 0 可以正常；也要检查状态时间戳是否新鲜。
- 让一个任务正常执行，再遇到真正的人工审批时观察灯；批准后应恢复常亮。

硬件演示需要先停止控制器，避免两个进程竞争同一颗灯：

```sh
BEACON_APP="$HOME/Library/Application Support/AgentBeacon/app"
"$BEACON_APP/bin/beacon" stop
# 等待约 1 秒，再执行：
"$BEACON_APP/bin/beacon" demo
"$BEACON_APP/bin/beacon" service restart
```

`doctor` 只检查能否发现 LED 接口，不代表已获权限或能写入。`demo` 的真实灯光才是硬件验证。

## 实现方法

| 层 | 工作方式 |
| --- | --- |
| 生命周期 | Codex / Claude hooks 报告开始、工具执行和结束，区分不同任务 / 轮次 |
| 桌面端等待 | 本地 IPC 只读订阅，结合等待标记和待处理请求判断人工审批；自动审查本身不触发快闪 |
| 终止失败 | 只读查询 Codex 本地 `thread_turns`，识别额度、网络、权限等失败类别 |
| 状态合并 | 有任何任务需要关注就快闪，否则有任务运行就常亮，否则熄灭 |
| LED 输出 | Ruby 控制器通过常驻 C helper 调用 IOKit 写 LED，不注入键盘事件 |

监听只发送观察所需的初始化、订阅和否定能力声明，不代替用户批准、拒绝、启动或停止任务。
IPC 内部版本不匹配时不会按未知格式继续解释。连接断开后会重连并重建订阅。

### Agent 支持范围

| Agent | 工作 / 完成 | 人工等待 | 失败 |
| --- | --- | --- | --- |
| Codex Desktop | hooks + 本地状态库 | 内部实时接口，主要验证对象 | 已记录的终止失败 |
| 独立 Codex CLI | hooks；状态库取决于本机版本 | **不支持桌面端式精确等待检测** | 取决于是否写入兼容状态库 |
| Claude Code | hooks | 现有权限 / 输入通知 hooks；未达到同等实测覆盖 | 支持 `StopFailure` hook |
| 其他本地 Agent | 手动接通用事件接口 | 由调用方报告 | 由调用方报告 |

例如其他 Agent 可以调用：

```sh
BEACON_APP="$HOME/Library/Application Support/AgentBeacon/app"
"$BEACON_APP/bin/beacon" event my-agent task-1 working turn-1
"$BEACON_APP/bin/beacon" event my-agent task-1 attention turn-1
"$BEACON_APP/bin/beacon" event my-agent task-1 done turn-1
```

## 排障

| 现象 | 检查 |
| --- | --- |
| 安装前提示缺少编译工具 | 完成 `xcode-select --install` 后重试 |
| 找不到 / 无法打开 LED | 确认是支持的内置键盘、输入监控授权准确、Karabiner 没有独占设备 |
| 授权后仍不亮 | 重启服务，确认新任务已开始、hooks 已信任；查看 `controller.log` |
| 有工作但没有实时订阅 | 打开兼容的 Codex Desktop，检查 IPC / 状态库版本和日志 |
| 一直快闪 | 用 `status` 查看哪个任务及 `reason`；可能是失败或监听断开，并非一定在等审批 |
| Caps 按键改变了灯 | 系统与 Agent 争用 LED，见安装前说明；不代表项目改了键位 |
| 升级 Codex 后失效 | 内部 IPC / SQLite 格式可能变化，提交脱敏兼容性报告 |

默认文件位置：

```text
~/Library/Application Support/AgentBeacon/
  app/                   程序、helper、文档和测试
  state.json             每个任务的状态 / 原因
  output.json            最近的灯光输出
  live-status.json        桌面监听连接状态
  controller.log         新安装后台服务日志
  service-receipt.json    服务归属校验记录
~/Library/LaunchAgents/local.agent-beacon.controller.plist
~/.codex/hooks.json       合并 hooks；旁边保留原配置备份
```

早期版本的日志名可能是 `local.agent-beacon.controller.log`。不要公开完整用户配置或对话数据库。

## 卸载和升级

以下适用于**新安装器**；早期改键安装先阅读 [安全与迁移说明](docs/SAFETY.md)。

```sh
BEACON_APP="$HOME/Library/Application Support/AgentBeacon/app"
"$BEACON_APP/bin/beacon" uninstall-hooks codex
# 如果当初用了 --with-claude，再执行：
# "$BEACON_APP/bin/beacon" uninstall-hooks claude
"$BEACON_APP/bin/beacon" service remove
```

只移除本项目 hooks 和归属校验通过的服务，保留程序、备份及日志。需要清除文件时，在 Finder 中把明确的 `AgentBeacon` 文件夹移入废纸篓即可。
输入监控授权可在系统设置中手动关闭。不会自动改变你的键位。

目前升级方式是：停止并卸载旧集成，备份 / 移走旧安装目录，再安装新版本。**没有自动迁移、回滚更新或签名二进制分发**；更换 helper 后可能需要重新授权。

## 隐私与安全

运行时不上传数据，不需要模型 API Key。任务库查询只取任务标识、时间、状态和失败分类。
**桌面端 IPC 快照可能包含对话内容，程序会在内存中解析并丢弃不需要的字段**；不把提示词、回复或工具参数持久化到自身状态文件。
输入监控是一项敏感系统权限，即使本项目用途只是控制 LED，也请先审查源码。
安装时的配置备份可能包含你原有的配置内容，应留在本机，不要上传到 issue。

## 开发与项目成熟度

```sh
make test
```

测试包括状态机、IPC 分片和重连、配置保留、服务注册失败清理及安装保护；不自动写真实键盘 LED。
安装演练已在隔离目录完成，不代表已通过多台全新 Mac、睡眠唤醒和长期运行验收。
参见 [审批验证记录](docs/APPROVAL-VERIFICATION.md) 和 [成熟度评估 / 待优化项](docs/PROJECT-REVIEW.md)。

欢迎提交键盘型号、macOS / Codex 版本与脱敏错误；贡献方式见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## License

[MIT](LICENSE)。LED helper 参考并改编自 CapsPulse，保留了原版权声明；见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
