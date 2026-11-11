# Ziv — Zig 自学习 Agent 使用说明

> 一个用 Zig 构建的支持多 LLM 后端、具备自动学习能力（记忆+反思+知识库）的 CLI Agent。
> 核心算法由三大数学常数驱动：**pi** 圆融信息、**e** 控制增长、**phi** 浓缩知识。
> v0.4.0 — 自学习闭环 · v0.5.x — 工具自动调用 + MCP + Skill · v0.6.x — 输入系统重写（块渲染/kitty 协议/粘贴折叠）+ 记忆飞轮升级 · v0.6.1 — 稳定性（看护狗/任务系统/Ctrl-C 协作取消）· v0.7.x — 事件循环重构（回合中输入全程在线）、工具批次 Esc 取消、keep-alive 重试、raw 终端治理；
> **v0.8.0 — 会话恢复（/resume）、提炼压缩梯子（onset 75% + /compact 焦点文本）、错误选择器 + auto_fix、后台任务（run_in_background + /bg + BgTask）、WebFetch、/tasks /last /trace 命令、前缀缓存观测（/stats）、子代理白名单/fork/max_turns、代码索引 FTS5、/config 中文菜单自动保存、TUI 可读性（配色五分类 + Ctrl+O 折叠）**；
> **v0.9.0 — harness 效率批次：utf8proc 宽度判定、sqlite-vec 记忆语义去重、项目根锚定（子目录共享上级 .ziv）、MCP 启动自动连接、Skill tools 强制门、M6 Hooks（Pre/PostToolUse）、M7 `-p` 非交互一发模式、tree-sitter 编辑后语法校验、退出零 LLM 等待（延迟提取档）**；
> **v0.9.1 — TUI v2 框架化（IDLE/TURN/MODAL 状态机、常驻输入区、模态退出零残留、统一工具头）、Concise 输出风格（/style）、全能力子代理（write:true、容量上限 10、实时进度行）、请求体 UTF-8 清洗**；
> **v0.9.2 — 并发审查五修复（子代理 LLM 请求 250ms 可取消 / live_dispatch 悬垂根治）、skill 命令族（new/show/remove/reload 热加载 + 失败可见化）、MCP stdio 根治（npx 形态可用，9 工具实测桥接）、项目规则 ziv.md（CLAUDE.md/AGENTS.md 兼容整合 + /agents 命令族 + 热重载）、DirTree 工具（第 16 个内置）、AskUserQuestion 选项化、/resume 两修复（ended_at 误报 + flush 收缩重建）、Ctrl-C 退出窗口 3s→1s**。

---

**目录**：[1 环境要求](#1-环境要求) · [2 构建与运行](#2-构建与运行) · [3 CLI 使用](#3-cli-使用) · [4 架构总览](#4-架构总览) · [5 核心能力](#5-核心能力) · [6 配置说明](#6-配置说明) · [7 项目结构](#7-项目结构) · [8 当前状态](#8-当前状态与待完成项) · [9 使用前须知](#9-使用前须知)

## 1. 环境要求

| 依赖 | 版本 | 说明 |
|------|------|------|
| Zig | 0.17.0 | 编译器 |
| SQLite3 | amalgamation | 已内置于 `deps/sqlite3/`（含 sqlite-vec） |
| OpenSSL | 系统 | HTTPS 请求 (macOS 使用 Security.framework) |
| C 编译器 | clang/gcc | SQLite / sqlite-vec / tree-sitter C 编译 |
| ripgrep (可选) | 系统 | Grep 工具优先使用 rg，不可用时回退到内置搜索 |

## 2. 构建与运行

```bash
cd agent/

# 构建
zig build

# 运行
zig build run

# 运行测试
zig build test

# 安装到 zig-out/bin/
zig build install
```

### 2.1 打包发布（release.sh）

**日常发布 SOP（三步）**：

```bash
# ① 改版本号 —— 只改一处：版本单一事实源
#    （启动 banner、/version、--version、MCP clientInfo、release.sh 全部读它）
vim src/util/version.zig   # pub const version = "0.9.2";

# ② 构建 + 安装包打包（唯一入口，产物见下方表格）
./release.sh

# ③ 安装升级（本机）或分发（别的机器）
./dist/ziv-vX.Y.Z/install.sh                    # 本机升级，原子覆盖
scp -r dist/ziv-vX.Y.Z user@server:             # 分发后在目标机 ./install.sh
```

也可以显式传版本号 `./release.sh 0.9.2`，但**传参不构成 bump**——必须先改 `src/util/version.zig`，传参与源码不符会被拒绝。

**版本防呆**：脚本从 `src/util/version.zig` 抽取版本；显式传参必须与源码一致，否则拒绝构建：

```
✗ version mismatch: src/util/version.zig='0.9.0' arg='0.9.1'
  bump src/util/version.zig, then rerun (or omit the argument)
```

脚本流程：
1. `rm -rf dist` —— 先清空整个 dist/（旧版本目录会被删除，git 状态里旧产物显示为 deleted）
2. 依次交叉编译 4 个 target（`zig build -Doptimize=ReleaseFast -Dstrip=true -Dtarget=...`）→ 裸二进制
3. 每个 target 打 `tar.gz`（CLI 工具标准发布形态）
4. `lipo` 合并 arm64+x86_64 → `pkgbuild` 出 macOS 安装包；构建机有 `dpkg-deb` 则再出 2 个 `.deb`
5. 生成离线安装器 `install.sh` + 覆盖全部产物的 `SHA256SUMS.txt`

| 产物 | 形态 | 说明 |
|------|------|------|
| `ziv-<target>` ×4 | 裸二进制 | aarch64/x86_64 × macOS/linux-musl（Linux 版为静态 ELF，无运行时依赖），scp + chmod 直接执行 |
| `ziv-$V-<target>.tar.gz` ×4 | tar.gz | 解压即用，等同裸二进制 |
| `ziv-$V-macos.pkg` | **macOS 安装包** | universal（arm64+x86_64 合一），安装到 `/usr/local/bin/ziv`，收据入 `/var/db/receipts`，可用 `pkgutil` 卸载 |
| `ziv_$V-1_amd64.deb` / `ziv_$V-1_arm64.deb` | **Linux 安装包** | 静态无依赖；需构建机装有 `dpkg-deb`（`brew install dpkg`），缺失时自动跳过 |
| `install.sh` | 离线安装器 | 自动识别平台，从本目录选对应二进制装到 `<prefix>/bin`（默认 /usr/local，无写权限自动回退 ~/.local）；`uninstall` 子命令可卸载；tmp+mv 原子替换，旧版运行中也可安全覆盖升级 |
| `SHA256SUMS.txt` | 校验和 | 覆盖目录内全部产物（`shasum -c SHA256SUMS.txt` 验证） |

注意：
- 脚本每次运行先 `rm -rf dist`，只保留**最新一个版本**的产物目录；要保留历史版本需自行归档（如 `mv dist/ziv-vX.Y.Z ~/releases/`）
- 脚本跑完后 `zig-out/bin/ziv` 是循环中**最后一个 target**（aarch64-linux-musl）的产物，在 macOS 上直接运行会报格式错误，属正常现象——分发请用 dist/ 内对应平台的文件
- 脚本依赖 `rg`（提取版本号）、`shasum`；`lipo`/`pkgbuild` 为 macOS 原生自带；`dpkg-deb` 可选
- `.pkg` 未签名公证（需 Apple 开发者账号）：首次安装如被 Gatekeeper 拦，右键→打开，或 `xattr -d com.apple.quarantine ziv-*.pkg`

### 2.2 命令行用法

产物为单文件可执行，免安装；配置读取与开发版完全一致（`~/.config/ziv/settings.json` + 项目锚点 `.ziv/`，见 2.3）。

```bash
ziv                 # 交互式 REPL（默认）
ziv -p "prompt"     # 非交互一发模式（M7）：跑一个完整 agent 回合，
                    #   打印结果退出——CI/脚本的门票
echo "hi" | ziv -p  # prompt 省略或为空 → 读 stdin 到 EOF（上限 4 MiB）
ziv --version       # 或 -V：打印版本退出
ziv --help          # 或 -h：打印用法退出
```

`-p` 模式的输出纪律：**回答走 stdout，诊断走 stderr**——`ziv -p "..." | jq` 永远不会把错误碎语混进管道流。子代理、hooks、权限规则在 `-p` 下同样生效（无头纪律：ask 级操作直接拒绝，不会卡在交互确认上）。非零退出码表示回合失败，脚本可用 `$?` 判定。

版本号唯一来源是 `src/util/version.zig`（启动 banner、REPL `/version`、`--version`、release.sh 同读一处）。

四种安装方式按需选：

```bash
cd agent/dist/ziv-v0.9.2

# 方式一：离线安装脚本（自动识别平台；默认 /usr/local，无写权限自动回退 ~/.local）
./install.sh
./install.sh uninstall     # 卸载二进制（配置与 .ziv/ 数据保留，按需手动删）

# 方式二：macOS 安装包（universal，装到 /usr/local/bin/ziv）
sudo installer -pkg ziv-0.9.2-macos.pkg -target /        # 或双击安装
sudo pkgutil --forget com.ziv.ziv                        # 卸载登记（另需 sudo rm /usr/local/bin/ziv）

# 方式三：Linux .deb（卸载：sudo dpkg -r ziv）
sudo dpkg -i ziv_0.9.2-1_amd64.deb

# 方式四：tar.gz / 裸二进制，解压即用
tar xzf ziv-0.9.2-aarch64-macos.tar.gz && ./ziv-aarch64-macos
```

- 传输后确认执行位（`chmod +x`）；Linux musl 版为静态链接，目标机无需安装任何运行时
- macOS：经浏览器/聊天工具下载的文件带 quarantine 属性会被 Gatekeeper 拦截，执行 `xattr -d com.apple.quarantine ziv-aarch64-macos` 解除；scp/rsync 传输一般不触发
- **升级二进制后需退出并重启 ziv 会话**（运行中的旧会话仍执行旧二进制）

### 2.3 运行时数据落点（项目根锚定）

**v0.9.0 起锚定规则**：从启动目录（cwd）**逐级向上**（含自身）找第一个已存在的 `.ziv/` 目录作为存储锚点——在项目子目录里启动 ziv，记忆/会话/索引/检查点与项目根**共享同一份**；子目录自建 `.ziv/` 则就近锚定（本地覆盖）；到根都没有则锚在 cwd（历史行为）。锚点继承了上级目录时启动有提示。符号链接经 realpath 归一，不分裂。

| 路径（相对锚点根） | 内容 |
|------|------|
| `.ziv/memory.db` | SQLite 情景记忆库（含 -shm/-wal，跨会话；v0.9.0 起内嵌 sqlite-vec 做语义去重） |
| `.ziv/sessions.db` | 会话库（v0.8.0 起，/resume 恢复用，含未正常退出标记） |
| `.ziv/index.db` | 代码索引（FTS5，v0.8.0 起；/stats 的 Code context 指标来自此） |
| `.ziv/checkpoints/` | 文件快照（/rewind 回滚用，首次文件编辑时创建） |
| `.ziv/traces/*.jsonl` | 回合决策链遥测（默认开，`ZIV_TRACE=0` 关闭，`/trace` 直读） |
| `.ziv/tasks/<id>.log` | 后台任务输出全文（Bash `run_in_background:true` 启动的命令） |
| `.ziv/skills/<名>/SKILL.md` | 项目级 Skill（覆盖同名全局 Skill） |
| `.ziv/plan.md` | /plan 计划文件 |
| `.ziv/input_history` | 输入历史（最近 500 条，跨会话 ↑ 召回） |
| `.ziv/settings.json` / `settings.local.json` | 项目级配置（优先级高于用户级） |
| stderr | 结构化运行日志（`./ziv 2>ziv.log` 落盘） |

## 3. CLI 使用

启动后进入交互式 REPL：

```
╔══════════════════════════════════════╗
║  Ziv - v0.9.2 | (Self-learning)      ║
║  π 圆融 · e 增长 · φ 浓缩             ║
╚══════════════════════════════════════╝
  π   = 3.1415926536
  e   = 2.7182818285
  φ   = 0.6180339887

  cwd: ~/projects/xxx        ← 当前工作目录（~ 压缩，数据锚点见 2.3）
```

启动自检（编译进二进制的全量单元测试）**成功时静默**，失败才红字提示。启动时自动执行：记忆注入（跨会话记忆按 e 衰减 × 向量相似度排序注入 system prompt）、MCP 自动连接（配置过的服务器握手 + 工具桥接，`mcp_autostart` 可关）、崩溃会话检测（上次未正常退出时提示 /resume）。

### 多行输入（Claude Code 风格）

**Enter 提交；以下按键插入换行**：

| 按键 | 说明 |
|------|------|
| Shift+Enter / Ctrl+Enter | **开箱即用**（kitty 键盘终端）：ziv 启动时自动启用 kitty 键盘协议（`CSI >1u`），终端把修饰回车编码为 `CSI 13;2u`/`13;5u`，退出时自动恢复；Esc 编码为 `CSI 27u`、**Ctrl+字母** 编码为 `CSI <码点>;5u`——ziv 均映射回传统控制码，所有 Ctrl 快捷键在协议终端下行为不变 |
| `\` + Enter | 行尾反斜杠续行（回车前删掉 `\` 并换行）——所有终端可用 |
| Ctrl+J | 字面换行符 |
| Option/Alt + Enter | 发送 `ESC+CR` 的终端（macOS Terminal 等） |
| **粘贴多行文本** | 自动走 bracketed paste：整段作为**一条**输入（不会被逐行执行），CRLF/CR 归一为 LF；**超过 8 行或 1 KiB 的大段自动折叠**为一枚青色 pill（`[📄 粘贴 · N 行 · B]`），pill 前后可继续打字，退格一次整枚删除，回车提交时自动展开，模型收到完整原文（同一提示下最多 4 枚 pill，超出按原文粘贴） |

多行缓冲的编辑体验：**整个缓冲区全文可见**——每条逻辑行都渲染出来，超宽行按显示宽度**软折行**（宽字符不跨行拆分，utf8proc 判宽，歧义宽度字符整类 bug 已根治）；内容超出 16 行的窗口预算时，显示以光标为中心的窗口，上下边缘灰色 `↟ +N 行` / `↡ +N 行` 提示被折叠的行数。↑/↓ 在多行缓冲的行间移动（首行↑/末行↓仍走历史）；超过 4 KiB 的粘贴自动扩容（上限 1 MiB）。多行输入一律作为消息发给模型（不会被当作斜杠命令）；多行内容仅本会话内 ↑ 召回，不写入跨会话历史文件。

**行编辑快捷键（Emacs 系）**：`Ctrl+A`/`Ctrl+E` 行首/行尾 · `Ctrl+B`/`Ctrl+F` 左/右一字符 · `Ctrl+W` 删前一个词 · `Ctrl+U` 删到行首 · `Ctrl+K` 删到行尾 · `Ctrl+H` 退格 · `Ctrl+D` 空行=退出、非空=向后删。

**Ctrl+R 历史搜索**：按 `Ctrl+R` 进入反向搜索，输入关键词实时匹配（不区分大小写，覆盖会话内全部历史含多行）；再按 `Ctrl+R` 翻更早匹配；`Enter` 选中并发送；`Esc` 保留当前内容退出搜索；无匹配显示红色 `(failing)`。

**Shift+Enter 一键配置**：`/terminal-setup` 按当前终端（iTerm2 / VS Code / WezTerm / 其他）打印对应配置步骤。

**发送的消息**以粗体品红定格在对话记录中；↑↓ 翻输入历史时回溯行同样品红。历史**跨会话持久化**于 `.ziv/input_history`。**Ctrl-C**：单击清行（防误触），**1 秒内快速连按两次**优雅退出；**Ctrl-Z** 挂起照常可用。

### TUI v2：常驻输入区与模态（v0.9.1）

屏幕由三态状态机统一仲裁（`docs/tui-architecture.md`）：

- **IDLE**：region 武装，**输入区常驻屏幕底部**（不再与输出混流），上方一行 hint（当前模式/模型提示）
- **TURN**：回合进行中，同一输入块保持 pinned 底部、全程可编辑（见下节），meta 行变为状态行（当前工具/子代理进度）
- **MODAL**：菜单/面板（/config、/resume、/bg、模型选择器…）打开时 region 解除、菜单流内自绘；**退出必经统一收口**——清残留 → 重 arm region → 输入块规范重画。菜单退出后不再有字符残留/输入被吞

工具调用在对话记录中呈现**统一工具头** `⏺ Name(args)`（/run 与 agent 回合同一格式）；工具输出暗色显示，**Ctrl+O 切换详细/简要**（默认详细；简要=长输出只出前 3 行 + `… +N 行` 折叠提示，提示符下与回合中都可切）；**Ctrl+T 互切输出风格** default/concise（同 `/style`，同样两处可按，切换反馈行即时打印）。完整输出用 `/last` 回看。表格渲染用实心制表线（`┌─┬─┐` 全框），歧义宽度字符（em dash 等）按窄列对齐不劈叉。

### Esc / Ctrl-C 中断与撤回

- **生成期间按 Esc（或 Ctrl-C）**：立刻中断当前回复流，刚发出的消息**自动回到输入框**（可编辑后回车重发），期间你提前打的字也会接在后面
- **工具执行期间按 Esc（或 Ctrl-C）**：取消当前工具批次——正在跑的 Bash 由其看门狗**击杀整个进程组**（`timeout: 0` 无限命令也能解绑），尚未开始的调用直接短路跳过。取消后回合结束，取消/部分结果已按规范写入历史
- **生成期间 / 工具执行期间直接打字**：输入框**全程在线、全功能**——方向键、Home/End/Delete、Ctrl 编辑键、↑↓ 翻历史、Shift+Enter 换行，与提示符下完全同一套编辑器。**回车 = 排队**：排队的补充在下一个工具轮注入**本轮**对话，流结束后仍未消费的排队内容自动作为下一轮发送；多行粘贴仍算**一条**消息。**编辑键永远不会取消生成**——只有 Esc / Ctrl-C 会
- **提交后 5 秒内在空输入框按 Esc**：同样把刚发的消息撤回到输入框（回答已飞快完成时兜底）
- 中断是干净的：已收到的部分不会写入对话历史

### 内置命令

| 命令 | 说明 |
|------|------|
| `/help`, `/h` | 显示帮助信息 |
| `/quit`, `/q`, `/exit` | 退出 Ziv（**大小写不敏感**）；等价退出：空行 Ctrl-D、提示符下 **1 秒内快速连按两次 Ctrl-C**——三者都走完整收尾（记忆提取 + 反思 + Goodbye；v0.9.0 起默认**零 LLM 等待**档：启发式提取毫秒完成，LLM 深度提取存档后下次启动后台补提，实测退出 ~0.5s） |
| `/version` | 显示版本号 |
| `/terminal-setup` | Shift+Enter 换行的终端配置指引（kitty 协议终端已自动支持） |
| `/stats` | 会话统计：消息数/token 估算/操作数、代码上下文片段数、压缩次数与回收量、**前缀缓存命中率**（cached_tokens，网关支持时显示）、模式/模型/能力档、总 token |
| `/tools` | 列出所有已注册工具（含安全属性） |
| `/run <ToolName> <json>` | 直接执行工具（走同一权限门 + hooks，不再绕过 Plan 模式） |
| `/style` | **输出风格开关**（v0.9.1）：`/style` 查看当前风格；`/style concise` 切换简洁模式（结果优先：省略开场白/过程叙述/结尾复述）；`/style default` 切回。**Ctrl+T 快捷键两态互切**（提示符与回合中都可按）。写入 settings 并立即重建 system prompt，下一回合生效；也可在 `/config` 菜单选择 |
| **模型 & 配置** | |
| `/model`、`/models` | **交互式模型选择器**（方向键 + Enter；q 显示纯文本列表） |
| `/model <name>` | 切换到指定模型（如 `claude-sonnet-4-6`、`gpt-4o`、`llama3.2`，自定义名如 `glm-4.6` 可选后端接入） |
| `/mode` | 切换权限模式（**已持久化**到 settings，重启不再回落） |
| `/config` | 打开交互式配置菜单（中文，方向键导航，**改动自动保存**即时生效） |
| **对话管理** | |
| `/compact` | LLM 提炼压缩：摘要替换较早历史、**最近消息原样保留**（双侧保护）；可带自由文本引导重点——`/compact 重点保留数据库迁移的决策` |
| `/compact phi` | φ 截断压缩：保留 system + 最近 61.8% 消息，无 LLM 调用 |
| `/clear` | 清空对话，重新开始（别名: `/reset`, `/new`；旧会话保留可 /resume 恢复） |
| `/context` | 上下文/token 用量 + **检测规则现场检查**（规则失败逐条列出并给建议动作，按「可自动/需确认」分级） |
| `/trace` | **上一回合逐步耗时**（直读 `.ziv/traces/*.jsonl`：流式/工具各阶段时长，超 80 步截断） |
| `/undo` | 撤销上一轮对话 |
| `/history` | 显示操作历史记录 |
| `/rewind` | **双重回滚**：恢复文件 + 对话按精确索引截断回该时刻（`[0]` 回卷全部） |
| `/plan <目标>` | 计划文件：向 `.ziv/plan.md` 写入目标/步骤模板并**锚定到 system prompt**（勾选 `[x]` 后注入摘要自动同步）；`/plan` 查看当前计划，`/plan off` 停用 |
| `/resume [编号]` | **会话恢复**（v0.8.0）：交互选择最近 9 个会话（编号·时间·轮数·首句·未正常退出标记）或直接 `/resume 42`；恢复消息 + 模型 + 权限模式，继续对话即可 |
| **任务 & 后台** | |
| `/tasks` | 任务面板：模型用 TaskCreate 建的任务在此查看进度 |
| `/bg` | **后台任务面板**（v0.8.0）：`run_in_background:true` 启动的命令在此查看状态/耗时/输出预览（30 行帽，全文见 `.ziv/tasks/<id>.log`）与停止（杀整组）；非 TTY 环境降级纯文本列表 |
| `/last [N]` | **工具输出全文回看**（v0.8.0）：`/last` = 最近一条，`/last 3` = 第 3 近（对话流里的预览刻意截断，这是展开阀；环容量 8 条） |
| **记忆 & 自学习** | |
| `/memory` | 查看本会话注入的记忆条数与最近存储的记忆 |
| `/research <topic>` | 网络自主研究：φ 生成多组查询并发搜索、精选方案并给出 ★ 推荐 |
| `/diagnose <concern>` | 自诊断：对薄弱回答建立决策链（live 埋点优先），定位低于 φ 置信度的环节并给建议 |
| `/knowledge` | 查看知识图谱统计（节点总数、最近节点、π 周期扫描出的孤立节点/断边） |
| **MCP & Skill** | |
| `/skills` | 列出已安装 Skill + 未加载原因（详见 5.14） |
| `/skill <sub>` | Skill 管理：new / show / remove / **reload 热重扫**（详见 5.14） |
| `/agents <sub>` | **项目规则管理**（ziv.md 单一源）：状态 / init（整合 AGENTS.md、CLAUDE.md 生成）/ sync（刷新外来内容区，专属节不动）/ reload（重读注入）——详见下文「项目规则」节 |
| `/mcp <sub>` | MCP 服务器管理：install / add / connect / disconnect / list / remove（详见 5.13） |

输入框中斜杠命令实时着色：已知命令青色、未知暗灰；打错命令给出 Did-you-mean 提示。

### 非交互一发模式（`ziv -p`）

CI/脚本的门票（v0.9.0 M7）：

```bash
# 单发提问，答案打印到 stdout
ziv -p "总结 src/main.zig 的入口逻辑"

# 管道输入
git diff | ziv -p "审查这个 diff，只报正确性问题"

# 退出码判定
ziv -p "..." || echo "回合失败"
```

- 完整 agent 回合（工具调用、压缩、hooks 全部生效），跑完即退
- 无头纪律：需要人工确认（ask 级）的操作直接拒绝而不是挂死
- 子代理可用（同 REPL 的 agent 工具语义）
- stdout 只有回答；诊断/警告全走 stderr

### `agent` 并行子代理

子代理派发是注册给模型的动态工具，**默认开启**（`ZIV_AGENT_TOOL=0` 关闭），由 LLM 在对话中自主调用，也可 `/run agent {...}` 手动触发：

```json
{
  "tasks": ["审查 src/llm 的错误处理", "列出未加锁的全局变量"],
  "tools": ["FileRead", "Grep"],          // 可选：工具白名单（只收窄）
  "fork": true,                            // 可选：继承最近对话尾部 ~16K tokens
  "write": true,                           // 可选：全能力模式（默认 false 只读）
  "max_turns": 10                          // 可选：每个子代理回合上限 1-10
}
```

- **容量**：1-10 个子代理并行（`subagent_concurrency` 控制并发 worker，默认 4，clamp 1..10；`/config` 菜单可改）；dispatch 超过 10 条任务**可见化报错**而非静默丢弃
- **只读默认 / 全能力**：默认只读（研究/验证 fan-out）；`write:true` 经**用户真实权限规则**放行写操作（无头纪律：ask 级仍拒绝），写型 dispatch 恒串行
- **进度可见**（v0.9.1）：dispatch 期间状态行实时显示各 agent 状态
- **Ctrl-C 协作取消**：未开始的 job 直接跳过，**进行中的 LLM 请求由看护狗在 250ms 内击杀 socket**（取消即时生效，不再等超时）；取消结果折叠为 `(canceled by user)` 不计失败
- **输出预算与主会话同源**：子代理每轮输出预算跟随 `settings.max_tokens`（默认 16384）——思考型模型的思考 token 计入输出预算，固定小值会"想完就没字"
- **禁入工具**：TaskCreate/TaskList/TaskUpdate/TaskGet（会话级任务跟踪）、AskUserQuestion（交互提问）、BgTask（全局后台任务管理）、agent（防递归 fan-out）
- 每个 LLM 请求由看护狗保护（默认 180s 空闲超时，持续出数据的长流不杀，`ZIV_LLM_TIMEOUT_MS` 可调）

### 权限模式 (Permission Modes)

Ziv 内置 6 种授权执行模式，通过 `/mode` 命令循环切换（选择持久化；无快捷键）：

| 模式 | 提示符 | 说明 |
|------|--------|------|
| **Default** | `ziv>` | 默认模式，危险操作需要用户确认 |
| **Accept Edits** | `ziv[edit]>` | 自动接受文件编辑操作，破坏性操作仍需确认 |
| **Plan** | `ziv[plan]>` | 只读模式，所有写操作被阻止 |
| **Bypass** | `ziv[bypass]>` | 跳过所有权限检查 |
| **Don't Ask** | `ziv[dontask]>` | 自动拒绝所有需要确认的操作 |
| **Auto** | `ziv[auto]>` | 分类器自动决定；ask 级操作交 LLM 分类，失败降级规则；判定按 (工具+入参) 缓存 |

权限管道 6 步检查：
1. **Deny rules** — 全局拒绝规则
2. **Ask rules** — 必须确认的规则（bypass-immune）
3. **Tool check** — 工具自身权限检查
4. **Safety paths** — 保护路径检测（.git/、系统文件等）
5. **Mode behavior** — 当前模式行为
6. **Allow rules** — 全局允许规则

**bypass 不是免死金牌**：第 2/3/4 步在 bypass 之前执行且不受其豁免——配置了 `ask_rules`、命令/路径涉及保护位置、或工具自身判定需确认时，bypass 模式下依然会问。

### 工具执行示例

```bash
# 执行 shell 命令
ziv> /run Bash {"command":"ls -la"}

# 后台命令（v0.8.0）：立即返回任务 id，/bg 或 BgTask 查看/停止
ziv> /run Bash {"command":"npm run watch","run_in_background":true}

# 读取文件
ziv> /run FileRead {"path":"/tmp/test.txt"}

# 写入 / 编辑文件
ziv> /run FileWrite {"path":"/tmp/hello.txt","content":"Hello, Ziv!"}
ziv> /run FileEdit {"path":"test.txt","old_string":"hello","new_string":"world","replaceAll":true}

# 文件 / 内容搜索
ziv> /run Glob {"pattern":"src/**/*.ts"}
ziv> /run Grep {"pattern":"TODO","maxResults":10}

# 网络搜索（免 key 用 DuckDuckGo；设 BRAVE_API_KEY 自动切 Brave）
ziv> /run WebSearch {"query":"zig programming language","maxResults":3}
# 网页抓取（v0.8.0）：URL → Markdown
ziv> /run WebFetch {"url":"https://ziglang.org/learn/"}

# 任务管理（taskId 为数字；TaskGet 给全文详情）
ziv> /run TaskCreate {"subject":"修复 bug #42","description":"修复登录验证问题"}
ziv> /run TaskUpdate {"taskId":"1","status":"in_progress"}   # pending | in_progress | completed
ziv> /run TaskList {}
ziv> /run TaskGet {"id":1}

# 后台任务自管理（v0.8.0）：模型侧的 /bg
ziv> /run BgTask {"action":"status"}
ziv> /run BgTask {"action":"output","id":1}
ziv> /run BgTask {"action":"stop","id":1}

# 向用户提问
ziv> /run AskUserQuestion {"question":"要使用哪个配置？"}

# 搜索工具
ziv> /run ToolSearch {"query":"file read"}
```

### 操作历史与回滚

```bash
# 查看操作历史
ziv[edit]> /history
  Operation history (5 operations):
    [1] Bash
    [2] FileEdit
    ...

# 回滚到检查点（文件快照 + 对话截断，双重）
ziv[edit]> /rewind
```

### 普通对话 (Agent Loop)

输入非 `/` 开头的文本即为对话消息：

- **系统提示词已注入当前本地日期时间**——问"今天几号/几点"直接回答；跨午夜长会话记得 /clear 刷新
- 推理模型（GLM reasoning_content / Claude thinking）思考期间显示暗色 `(thinking…)` 指示
- 每次请求携带**系统提示词 + 完整对话历史**；LLM 返回 `tool_use` 时自动执行工具并回传结果，循环直到完成
- 权限检查集成在工具执行中（`default` 模式下破坏性操作需确认）
- 上下文压力梯子（v0.8.0 P2.5）：**≤75% 不动**（前缀缓存稳定优先）→ 超限先 **LLM 提炼压缩**（摘要 + 最近轮原文保留，`auto_deep_compact`）→ 仍超才 φ 截断（有损兜底）
- 回合工具轮上限 `agent_loop_limit`（默认 50，clamp 1..200）；到限不再硬停——预填「继续」一键接续
- 每轮 FileWrite/FileEdit 上限 15 次（写马拉松回合显式收束）
- 编辑后自动 tree-sitter 语法校验（py/js/ts/tsx/java/zig，见 5.15）

提示符中的 `[N%]` 显示当前上下文使用百分比。

### 模型切换

```
ziv> /model                 # 交互选择器（方向键+Enter；q 纯文本列表）
ziv> /model claude-sonnet-4-6
  Switched to claude-sonnet-4-6 (Claude)
ziv> /model glm-4.6         # 识别不了的自定义名 + 已配网关 → 询问走哪个后端
```

模型名自动识别后端：`claude-*` → Anthropic，`gpt-*`/`o1-*`/`o3-*` → OpenAI，其他 → Ollama。**`default_backend` 显式覆盖**：settings.json 设 `"default_backend": "openai"` 后，任意自定义模型名（glm/deepseek 等）都路由到 OpenAI 兼容网关——名字检测不再挡路。

### 交互式配置 (/config)

`/config` 打开中文交互菜单（方向键导航，**改动自动保存并即时生效**，Esc 逐层退出零副作用）：

```
=== Ziv 配置 ===
  API Keys
  默认模型: gpt-4o
  最大 tokens: 16384
  记忆注入预算: 1200 tokens
  子代理并发: 4
  权限模式: Default
  检查点: 开
  系统提示词: (默认)
  输出风格: default
  自动错误修复: 开（429/超时退避重试）
  回合工具轮上限: 50
  上下文提炼压缩: 开（LLM 摘要优先，截断兜底）
  退出
```

保存目标 `~/.config/ziv/settings.json`。自动错误修复关掉后，429/超时/溢出等错误直接进**错误选择器**（重试/换模型/压缩/放弃，人工裁决）。

### 对话管理命令

```bash
# 查看上下文用量 + 检测规则现场
ziv (gpt-4o) [12%] > /context
  Context: 2450 / 128000 tokens (1.9%)
  ...
  检测规则: 全部通过

# LLM 提炼压缩（默认；带焦点文本引导摘要）
ziv (gpt-4o) [78%] > /compact
  Compacting: summarizing 14 messages (~52000 tokens)…
  Compacted: 15 → 2 messages (~52000 → ~2400 tokens)
# 失败时历史保持原样并提示改用截断：
#   Summary model unavailable (error.MissingApiKey).
#   History untouched — try /compact phi for plain truncation.

# φ 截断压缩（无 LLM 调用）
ziv (gpt-4o) [78%] > /compact phi

# 恢复上一个会话
ziv> /resume
  恢复会话（当前对话将被替换；q 取消）:
    #41 · 2026-11-10 14:02 · 12 轮 · 修复登录验证问题
    #40 · 2026-11-09 18:44 · 3 轮 · (无消息) · 未正常退出
ziv> 已恢复会话 #41：24 条消息（~8100 tokens · 模型 gpt-4o · 模式 default）。继续对话即可。
```

---

## 4. 架构总览

```
Ziv Agent v0.9.2
├── math/           数学常数核心 (pi, e, phi)
├── llm/            多 LLM 后端 (Claude, OpenAI, Ollama) + 流式 + 消息压缩
├── tools/          comptime 工具系统 (16 内置工具 + agent 动态工具) + 权限 + 编排
├── agent/          子代理执行器 (subagent) + 非交互一发 (oneshot)
├── turn/           回合子系统 (流式/工具/历史压缩/ask)
├── commands/       斜杠命令分发 (dispatch/config_menu/history_cmds)
├── session/        会话存储/模型切换/记忆操作/输入历史
├── hooks/          M6 Pre/PostToolUse 外部钩子
├── mcp/            MCP 客户端 (stdio + Streamable HTTP)
├── skills/         SKILL.md 加载器 (tools 门)
├── task/           异步任务系统 (线程池, MPSC队列, 事件总线, 定时任务)
├── storage/        持久化层 (SQLite, 向量存储)
├── memory/         三层记忆 (工作记忆, 情景记忆, 反思, 经验提取)
├── knowledge/      知识图谱 + 网络搜索
├── runtime/        运行时检测 + 自诊断 + 错误处理
├── research/       自主优化研究引擎
├── checkpoint/     操作记录 + 文件快照 + 回滚引擎
├── util/           工具库 (40+ 文件: lineinput, menu, zivroot, treesitter, uwidth, turn_clock...)
├── config.zig      五层配置层级
├── repl.zig        交互式 REPL + TUI v2 状态机
└── system_prompt.zig 系统提示词（含输出风格/工具清单动态生成）
```

---

## 5. 核心能力

### 5.1 数学常数驱动算法

| 常数 | 应用 | 说明 |
|------|------|------|
| **pi** | 环形记忆缓冲区 | PiRingBuffer 用 pi 分数序列分散索引，均匀覆盖 |
| **pi** | 事件历史 | EventBus 用 pi ring buffer 存储最近 1024 个事件 |
| **e** | sigmoid/logistic | 资源压力评分、并发上限、重试退避 |
| **e** | 知识衰减 | `relevance(t) = initial * e^(-lambda * t)` |
| **e** | 记忆注入排序 | 0.5×e 衰减 + 0.5×与最新记忆的向量余弦混合 |
| **phi** | 知识浓缩 | 每次反思将知识压缩到 61.8% |
| **phi** | Fibonacci 哈希 | 最均匀的哈希分布，用于记忆索引 |
| **phi** | 上下文溢出检测 | 使用率超过 61.8% 时预警 |
| **phi** | 任务失败率检测 | 失败率超过 38.2% (1-phi) 时告警 |

### 5.2 多 LLM 后端

| 后端 | 配置 | 状态 |
|------|------|------|
| **Claude** (Anthropic) | 需要 API Key | 完整实现 (claude-opus-4-6, claude-sonnet-4-6, claude-haiku-4-5) |
| **OpenAI** | 需要 API Key | 完整实现 (GPT-4o 等)；`openai_base_url` 指向兼容网关可接 glm/deepseek 等 |
| **Ollama** (本地) | 需要 Ollama 运行 | 完整实现 (llama3.2 等) |

统一接口（comptime vtable）：`complete()` 同步 · `stream()` SSE 流式（REPL 默认）· `countTokens()` 估算。模型名自动路由（`claude-*`/`gpt-*`/其他），`default_backend` 显式覆盖。

**请求体 UTF-8 清洗**（v0.9.1）：非法 UTF-8 字节在出网前被清洗净化——网关对脏字节的 400 InvalidRequest 不再发生。

### 5.3 工具系统（16 内置 + 动态）

comptime 泛型注册，零运行时开销。每个工具支持并发安全检查（输入级）、破坏性检测（输入级）、输入验证、权限检查、别名匹配。

| 工具 | 别名 | 类型 | 并发安全 | 说明 |
|------|------|------|----------|------|
| **Bash** | Shell, sh | 读写/破坏性 | 不安全 | 执行 shell 命令。`timeout`（秒，默认 30、上限 300、0=不限）；`run_in_background`（v0.8.0：脱离执行立即返回任务 id，watch/dev-server/长构建用，输出落 `.ziv/tasks/<id>.log`，`/bg` 或 BgTask 管理）；`working_directory`；stdout/stderr 各限 256 KiB |
| **FileRead** | Read, cat | 只读 | 安全 | 读取文件（带行号、分页）；重复读取未变更文件走 FileStateCache |
| **FileWrite** | Write | 读写 | 不安全 | 写入文件 |
| **FileEdit** | Edit, sed | 读写 | 不安全 | 字符串查找替换编辑 |
| **Glob** | find | 只读 | 安全 | 目录遍历 + 模式匹配；构建/依赖目录整树剪枝，`maxDepth` 默认 10，结果上限 2000 |
| **Grep** | search | 只读 | 安全 | 正则内容搜索（优先 ripgrep，回退内置；后端一次判定，进程内缓存）；30s 超时、500 条截断 |
| **DirTree** | Tree, tree | 只读 | 安全 | **目录结构概览**（v0.9.2）：缩进树形渲染，目录优先字母序；与 Glob 共享剪枝表（node_modules/.git 等整树不进）；`maxDepth` 默认 3、`maxEntries` 默认 400（截断可见）。摸陌生项目的第一步，补 Glob 只会模式匹配的短板 |
| **WebSearch** | — | 只读 | 安全 | 网络搜索（DuckDuckGo 免 key；设 BRAVE_API_KEY 自动切 Brave；SearXNG 可配） |
| **WebFetch** | Fetch | 只读 | 安全 | **v0.8.0**：抓取 URL 转 Markdown（搜索的下一步）；结果上限 40K |
| **TaskCreate** | — | 读写 | 不安全 | 创建任务（`priority` 1-5，默认 3） |
| **TaskList** | — | 只读 | 安全 | 列出所有任务 |
| **TaskUpdate** | — | 读写 | 不安全 | 更新任务状态 |
| **TaskGet** | — | 只读 | 安全 | **v0.8.0**：按 id 查单条全文详情（列表截断描述，Get 给全文） |
| **BgTask** | — | 只读* | 安全 | **v0.8.0**：后台任务自管理——`action`: status（全部或按 `id` 单条）/ output（输出尾部）/ stop（杀进程组，default 模式走审批） |
| **AskUserQuestion** | — | 只读 | 不安全 | 向用户提问（阻塞式，Esc 取消）。带 `options`（2-8 项）时渲染编号列表、按数字选择——选项原文回传模型；无 options 为自由文本行 |
| **ToolSearch** | — | 只读 | 安全 | 按关键词搜索可用工具 |
| **agent**（动态） | — | 读写* | — | 并行子代理派发（默认开启，详见 3 节 agent 小节） |
| **mcp__\<服务器\>__\<工具\>**（动态） | — | 视工具 | — | MCP 桥接工具（连接后自动注册） |

\* BgTask 的 stop 按操作分级走审批；agent 默认只读、`write:true` 全能力。

系统提示词中的**工具清单由注册表动态生成**（v0.9.1 根治漂移）——MCP 桥接/agent 工具上下线，模型看到的清单自动同步，不再与实际注册集脱节。

### 5.4 工具编排与 Hooks

`orchestration.zig` 智能分组：
- `partitionToolCalls()` — 并发安全调用分组；**安全工具真并行**（e 上限线程池，结果按原始调用顺序回收，池故障自动降级串行）
- **不安全工具串行执行**（Bash、FileWrite、FileEdit 等）
- **auto 模式分类器缓存**：LLM 安全判定按 (工具+入参) 进程内缓存，重复 ask 级操作零额外请求

**M6 Hooks**（v0.9.0）——工具调用前后的外部脚本钩子，三个执行口全走（REPL 回合 / 子代理 / /run 直达），顺序恒定：**权限判定 → PreToolUse → 执行 → PostToolUse**：

```json
// settings.json
"hooks": {
  "PreToolUse":  [{"matcher": "Bash",     "command": "./guard.sh"}],
  "PostToolUse": [{"matcher": "FileEdit", "command": "make lint"}]
}
```

- `matcher` 精确匹配工具名；空/省略 = 全部工具
- `command` 经 `/bin/sh -c` 执行，cwd = 当前目录，10s 超时强杀
- stdin 喂 JSON：`{"tool": 名, "input": 原参数}`（Post 另带 `"output"`；载荷超 32K 截尾标记）
- **PreToolUse 退出码**：0 = 放行；**2 = 阻断**（stderr 摘要回给模型，可改道重试）；其他非零 = 非阻断记日志
- PostToolUse 退出码忽略（钩子不许破坏回合）

### 5.5 权限系统

6 种权限模式 + 6 步权限管道（见 3 节）。规则解析器支持 `"Bash(git status)"` 风格：

- `"Bash"` — 匹配所有 Bash 调用；`"Bash(git status)"` — glob 匹配命令；`"Bash(*)"` — 通配
- **链式命令分段匹配**：`cd x && git push --force` 会被 deny `git push*` 命中（任一段命中即拒绝）；allow 则要求**每一段**都被覆盖
- auto 模式分类器：安全白名单（FileRead/Glob/Grep/ToolSearch/TaskList）始终允许，只读自动允许，破坏性自动阻止，灰区交 LLM 分类（缓存）
- 拒绝追踪器：连续自动拒绝超过阈值自动回退提示模式，防死循环

### 5.6 消息压缩（提炼梯子）

上下文压力按**梯子**响应（v0.8.0 对齐 Claude Code 水位）：

| 层级 | 触发 | 行为 |
|------|------|------|
| **不动** | ≤75%（COMPACT_ONSET） | 前缀缓存稳定优先——不折腾 |
| **提炼压缩** | >75%（自动，`auto_deep_compact`）或 `/compact` 手动 | LLM 将较早历史摘要为结构化摘要 + **最近轮原文保留**（双侧折叠）；可带焦点文本引导重点；token 回收量可见（/stats） |
| **φ 截断** | 提炼后仍超 / `auto_deep_compact` 关 / `/compact phi` | 保留 system + 最近 61.8% 消息，最旧丢弃（有损兜底） |

任何压缩失败历史保持原样（可观测、可回退）。压缩触发越少，网关前缀缓存越稳——/stats 的 Cache 行是直接指标。

### 5.7 异步任务系统

| 组件 | 说明 |
|------|------|
| **ThreadPool** | e 控制并发上限的工作线程池 |
| **BoundedMPSC** | 无锁多生产者单消费者队列 (容量 256) |
| **EventBus** | 事件发布/订阅，pi ring buffer 存储 |
| **CronScheduler** | 定时任务；`cron.drainDue()` 在提示符循环顶 + 回合 UI 空闲片排水（马拉松回合不饿死） |

内置定时任务间隔（设计值）：反思 pi×10min ≈ 31.4min · 知识更新 phi×60min ≈ 37.1min · 记忆衰减 e×30min ≈ 81.5min · 健康检查 60s · 资源监控 30s。反思触发每轮查询后内联评估（每 10 轮或 π×10min）。

### 5.8 三层记忆系统

| 层 | 存储 | 用途 |
|----|------|------|
| **工作记忆** | 内存 LRU | 当前会话上下文 |
| **情景记忆** | SQLite (`.ziv/memory.db`) | 跨会话记忆；v0.9.0 内嵌 **sqlite-vec** 做语义 KNN——新记忆入库前与近邻做向量相似度判定，语义重复自动合并（不再同义反复堆库） |
| **语义记忆** | 知识图谱 | 提取的结构化知识（节点 + co_extracted 边，含去重） |

**情景记忆闭环**：
- **提取**：`/quit`、`/clear` 时启发式扫描（中英关键词），φ 浓缩后入库；**v0.9.0 延迟档**：默认退出零 LLM 等待（启发式毫秒完成 + 转录存档，LLM 深度提取下次启动后台补提）；`ZIV_EXIT_EXTRACT_MS>0` 可回到同步等待档（有死线帽）
- **幂等**：id = 内容双 Wyhash，`INSERT OR REPLACE`；语义级另走 vec0 KNN
- **注入**：启动取最近条目，按 0.5×e 衰减 + 0.5×向量余弦混合排序，预算 `memory_budget_tokens`（默认 1200，/config 可调 200-8000）截断后拼入 system prompt
- **查看**：`/memory`

**反思引擎**：会话内维护查询窗口，每 10 轮或 π×10min 触发；**经验回放**（π-均匀采样全史）+ **洞察质量门**（启发式洞察入库前经 LLM 校验，误诊零入库——罐头洞察不污染库）；`/quit` 强制收尾。insights 以 `.feedback` 记忆入库，跨会话生效。退出反思带实测数字（失败率/窗口/跨度）。

### 5.9 运行时检测

7 条规则（内存 sigmoid 压力、API 限速、SQLite 完整性、上下文溢出 φ 阈值、任务健康 1-φ、网络连通、并发饱和）。上下文规则按**当前模型真实上下文窗口**判定；同签名告警去重打印。`/context` 现场跑全部规则并给分级建议（可自动/需确认）；`/diagnose` 用 live 决策链（agent loop 7 阶段真实埋点）定位弱环节。

### 5.10 自诊断引擎

`/diagnose <你的质疑>`：live trace 优先（无查询时静态兜底），SelfDiagnostic 找 confidence < phi 的弱步骤，输出 root cause + 改进建议；喂实测指标（LLM 调用/429/工具错误/压缩次数/缓存命中/上下文水位）。

### 5.11 自主优化研究

`/research <topic>`：φ 生成 3 组查询并发搜索（Brave/DuckDuckGo）→ φ 浓缩筛选 → 兼容性×0.4 + 相关性×0.3 + 复杂度×0.3 加权 → ★ 推荐 + 理由。

### 5.12 操作记录与回滚 (Checkpoint)

- FileWrite/FileEdit 前 `trackEdit()` 自动备份原始文件到 `.ziv/checkpoints/`（SHA256 校验；新文件记"新文件"，回滚时删除）
- `/history` 查操作记录 → `/rewind` 列回滚点 → 预览影响 → 确认恢复（文件 + 对话双重回滚）

### 5.13 MCP（stdio + Streamable HTTP 双传输）

```
/mcp install playwright        # 内置 registry：playwright/filesystem/memory/fetch/sequential-thinking
/mcp add <名> <command...>     # 自定义 stdio 服务器
/mcp add <名> http(s)://…      # HTTP 服务器（自动识别）
/mcp connect <名> / disconnect # 握手 + 工具桥接为 mcp__<名>__<工具>（走同一权限门，默认 ask）
/mcp list / remove
```

- 配置持久化于 `~/.config/ziv/mcp.json`；env 全量继承
- **启动自动连接**（v0.9.0）：配置过的服务器冷启动即握手桥接（短预算 3s，`ZIV_MCP_AUTOSTART_TIMEOUT_MS` 可调；`mcp_autostart: false` 或 `ZIV_MCP_AUTOSTART=0` 关闭）——不用再手敲 `/mcp connect`
- **npx stdio 形态已可用**（2026-11-10 根治）：`/mcp add <名> npx -y <包名>` 直接拉起。旧版两个根因已修——读循环丢弃 peek 残余（>4KB 的 tools/list 响应尾部丢失 → 握手卡死至看门狗超时）+ 深层 spawn 孤儿（SIGKILL 杀不到 npx 的 node 子进程，现按进程组治理）。实测 `@modelcontextprotocol/server-memory` 9 工具全桥接
- **Playwright 接入**（真机已验收）：终端起服务 `npx -y @playwright/mcp@latest --port 18931`，`/mcp add playwright http://localhost:18931/mcp`（注意 `localhost`——服务默认监听 IPv6）

### 5.14 Skill（Claude SKILL.md 兼容）

- 目录：`~/.config/ziv/skills/<名>/SKILL.md`（全局）+ `.ziv/skills/<名>/`（项目级，同名覆盖）
- frontmatter：name / description / when_to_use / **tools**（v0.9.0 起为**强制门**：声明后本回合只许清单内工具；空声明 = 不设限，老 skill 兼容）
- 调用：`/<技能名> [任务参数]`——触发时先打印预览（步数 + 声明工具），正文注入对话，`$ARGUMENTS` 占位替换；`/skills` 列出
- **管理命令族**（`/skill`）：
  - `/skill new <名>`——生成模板到项目级 `.ziv/skills/<名>/SKILL.md`（frontmatter 骨架 + 步骤示例）
  - `/skill show <名>`——查看全文
  - `/skill remove <名>`——确认后删除整个技能目录
  - `/skill reload`——**热重扫**：新增/删除/编辑技能即时生效（重建 system 提示清单并重注入会话，无需重启）
- **失败可见**：SKILL.md 读取失败、frontmatter 无效、缺 description 的目录不再静默跳过——`/skills` 列表带 `⚠ 未加载` 段逐条给出原因

### 5.15 tree-sitter 编辑后语法校验（v0.9.0）

FileEdit/FileWrite 之后自动对产物做语法校验（语言集：**Python / JavaScript / TypeScript / TSX / Java / Zig**，`util/treesitter.zig`）——编辑引入的语法错误当场暴露给模型自愈，不用等编译。不认识的语言静默跳过。语法依赖以源码形式内嵌 `deps/tree-sitter/`，musl 交叉编译恒定 `-O2`。

### 5.16 项目规则 ziv.md（2026-11-11）

ziv 的项目规则 = **`ziv.md` 单一事实源**（锚定根，ziv 可读写）；`AGENTS.md` / `CLAUDE.md` 为外来文件**只读识别**——仅作生成素材。三者**全大小写不敏感**（ziv.md/ZIV.md、agents.md、claude.md 都认）。

| 层 | 路径 | 说明 |
|----|------|------|
| 全局 | `~/.config/ziv/ziv.md` | 个人偏好，纯手写不自动生成，注入在前 |
| 项目 | `<锚定根>/ziv.md` | 项目规则，注入在后（更具体者靠后） |

**行为**：

- ziv.md 存在 → 注入之（独立 ContentBlock，system 块内），忽略外来文件
- ziv.md 缺 + 外来存在 → **自动生成**：外来内容整篇拼接进 `<!-- ziv:external -->` 标记区 + 专属节模板，明示一行（整篇拼接，确定性零丢失，不做 LLM 提炼）
- `/clear` 后规则块保留（规则不是会话状态）；**热重载**：编辑 ziv.md 后下一提示符按 mtime+size 检对自动重注入（`[ziv.md 已重载 · ~N tokens]`）
- 每层独立 4000 tokens 预算，超限 UTF-8 边界截断 + 可见尾注
- `ziv -p`（oneshot）同样注入（尾拼 system 字符串）但**不自动生成**（无头不在用户项目写文件）

**`/agents` 命令族**：`/agents`（状态）/ `init`（手动生成整合）/ `sync`（只刷新标记区内外来内容，**标记区外的专属规则永不被动**；无标记的旧文件备份 ziv.md.bak 后重生）/ `reload`（立即重读注入）。

规则文件进不进 git 自便：团队共享规则建议维护在 AGENTS.md（其他 agent 也认），个人/项目补充写 ziv.md 专属节——sync 标记区保证两边不打架。

---

## 6. 配置说明

### 6.1 配置文件层级

5 层配置源，后者覆盖前者：

```
user_settings    → ~/.config/ziv/settings.json
project_settings → <项目根>/.ziv/settings.json
local_settings   → <项目根>/.ziv/settings.local.json
cli_args         → 命令行参数
session          → 运行时设置
```

（项目级两层的「项目根」= 2.3 节的锚定根——子目录启动共享上级项目的配置。）

**热重载（即时生效）**：每个提示符处校对 settings 文件内容指纹，外部编辑即整包重载并打印 `[settings reloaded | mode: …]`。即时应用：`permission_mode`、`allow/deny/ask_rules`、`api_keys`（provider 缓存失效重建）、`max_tokens`。`system_prompt` 烘焙进会话历史，重载后需 `/clear` 或重启。

### 6.2 配置文件格式

`~/.config/ziv/settings.json`：

```json
{
  "permission_mode": "default",
  "default_model": "gpt-4o",
  "default_backend": null,
  "max_tokens": 16384,
  "output_style": "default",
  "mcp_autostart": true,
  "auto_fix": true,
  "auto_deep_compact": true,
  "agent_loop_limit": 50,
  "memory_budget_tokens": 1200,
  "subagent_concurrency": 4,
  "checkpointing_enabled": true,
  "system_prompt": null,
  "api_keys": {
    "openai": "sk-...",
    "openai_base_url": null,
    "anthropic": "sk-ant-...",
    "anthropic_base_url": null,
    "brave": "BSA-...",
    "ollama_host": "http://localhost:11434"
  },
  "hooks": {
    "PreToolUse":  [{"matcher": "Bash", "command": "./guard.sh"}],
    "PostToolUse": [{"matcher": "FileEdit", "command": "make lint"}]
  },
  "allow_rules": ["Bash(git status)", "Bash(git log)", "FileRead"],
  "deny_rules":  ["Bash(rm -rf /)", "Bash(dd if=/dev/zero)"],
  "ask_rules":   ["Bash(curl *)"]
}
```

#### 配置项说明

| 配置项 | 类型 | 默认值 | 说明 |
|--------|------|--------|------|
| `permission_mode` | string | `"default"` | 权限模式: default/accept_edits/plan/bypass/dont_ask/auto |
| `default_model` | string | `"gpt-4o"` | 默认 LLM 模型 |
| `default_backend` | string | null | 显式后端覆盖（"openai"/"claude"/"ollama"）——自定义模型名（glm-4.6 等）路由到已配网关，压过名字检测 |
| `max_tokens` | integer | `16384` | 单次响应输出上限 (1-128000)。思考型模型的思考 token 计入此预算；耗尽时自动翻倍重试（上限 32768） |
| `output_style` | string | `"default"` | 输出风格：default / **concise**（结果优先：省略开场白/过程叙述/结尾复述）；`/style` 命令或 **Ctrl+T** 快捷键切换，`/config` 菜单可选；非法值回落 default |
| `mcp_autostart` | boolean | `true` | 启动自动连接已配置的 MCP 服务器 |
| `auto_fix` | boolean | `true` | 自动错误恢复（429/超时退避重试、溢出自动压缩）；关 → 错误直接进选择器 |
| `auto_deep_compact` | boolean | `true` | 上下文压力下自动 LLM 提炼压缩（摘要+最近轮原文）；关 → 压力直落 φ 截断 |
| `agent_loop_limit` | integer | `50` | 每回合 LLM 迭代上限（clamp 1..200）；到限预填「继续」 |
| `memory_budget_tokens` | integer | `1200` | 跨会话记忆注入预算（200-8000，/config 可调） |
| `subagent_concurrency` | number | `4` | agent 工具并发 worker（clamp 1..10，1=串行）；写型 dispatch 恒串行不受此值影响 |
| `max_snapshots` | integer | `100` | 最大快照数量 |
| `checkpointing_enabled` | boolean | `true` | 操作记录与检查点 |
| `system_prompt` | string | null | 自定义系统提示词（null 用内置默认） |
| `api_keys.openai` / `openai_base_url` | string | null | OpenAI Key / 兼容网关地址（env：OPENAI_API_KEY / OPENAI_BASE_URL） |
| `api_keys.anthropic` / `anthropic_base_url` | string | null | Anthropic Key / 兼容网关地址（env：ANTHROPIC_API_KEY / ANTHROPIC_BASE_URL） |
| `api_keys.brave` | string | null | Brave Search Key（env：BRAVE_API_KEY） |
| `api_keys.ollama_host` | string | `"http://localhost:11434"` | Ollama 服务地址 |
| `hooks` | object | null | M6 外部钩子（见 5.4；env 来源的 secret 永不落盘） |
| `allow_rules` / `deny_rules` / `ask_rules` | string[] | [] | 权限规则（ask 强制确认，bypass 不豁免；链式命令分段匹配） |

#### 环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `OPENAI_API_KEY` / `OPENAI_BASE_URL` | — | OpenAI 后端凭据/网关 |
| `ANTHROPIC_API_KEY` / `ANTHROPIC_BASE_URL` | — | Anthropic 后端凭据/网关 |
| `BRAVE_API_KEY` | — | Brave 搜索 |
| `ZIV_LLM_TIMEOUT_MS` | 180000 | LLM 请求**空闲**看护狗（距上一字节无数据才算超时；下限 1000） |
| `ZIV_TTFT_TIMEOUT_MS` | 30000 | 首字节预算（预算随请求体伸缩；三连败入选择器；下限 5000） |
| `ZIV_AGENT_TOOL` | 1 | `0`/`false` 关闭 agent 子代理工具 |
| `ZIV_MCP_AUTOSTART` | 1 | `0` 关闭 MCP 启动自动连接 |
| `ZIV_MCP_AUTOSTART_TIMEOUT_MS` | 3000 | 自动连接握手短预算 |
| `ZIV_EXIT_EXTRACT_MS` | 0 | 退出记忆提取档：0 = 延迟档（默认，零 LLM 等待）；>0 = 同步等待死线（ms） |
| `ZIV_TRACE` | 1 | 回合决策链落盘 `.ziv/traces/*.jsonl`；`0` 关闭 |
| `ZIV_LOG` | notice | 日志级别 debug/info/warning（`2>ziv.log` 查看） |
| `ZIV_CRON_SCALE` | 1 | 定时任务时间线压缩倍数（仅测试） |
| `ZIV_DDGO_URL` / `ZIV_BRAVE_URL` / `ZIV_SEARXNG_URL` | — | 搜索后端 URL 覆盖（测试/代理） |

### 6.3 代码中配置

```zig
// OpenAI
const openai_cfg = llm.OpenAIConfig{ .api_key = "sk-...", .model = "gpt-4o" };
var openai = llm.OpenAIProvider.init(allocator, openai_cfg);
const provider = openai.toProvider();

// Ollama (本地)
const ollama_cfg = llm.OllamaConfig{ .model = "llama3.2", .base_url = "http://localhost:11434" };
var ollama = llm.OllamaProvider.init(allocator, ollama_cfg);
const provider = ollama.toProvider();
```

数据库路径（`data/ziv.db`）、定时任务间隔（`task/cron.zig`）、工作记忆容量（`memory/working.zig` max_entries=50）、线程池并发（`e_growth.zig` logistic）均为源码级配置。

---

## 7. 项目结构

### 7.0 目录概览

| 文件/目录 | 说明 |
|---|---|
| `build.zig` | Zig 构建配置（主） |
| `build_full.zig` | Zig 构建配置（完整版） |
| `build.zig.zon` | 包管理依赖声明 |
| `DESIGN.md` | 设计文档（含对账表 v4） |
| `USAGE.md` | 本文件 |
| `TODO.md` | 待办事项 |
| `docs/` | 专题文档（tui-architecture / ziv-project-root / harness-efficiency-plan / config-ux-design / bug-patterns / ziv-roadmap 等） |

### 7.1 源码结构（`src/`）

| 子目录 | 用途 |
|---|---|
| `llm/` | LLM 后端（Claude/OpenAI/Ollama、流式、压缩） |
| `tools/` | 16 内置工具 + 注册器 + 权限 + 编排 + agent 派发 |
| `agent/` | 子代理执行器（subagent）+ -p 一发模式（oneshot） |
| `turn/` | 回合子系统：stream（流式+工具头）/ tools（执行+LastTools）/ history（压缩/计划锚点）/ ask（权限门）/ error_recovery |
| `commands/` | 斜杠命令：dispatch（分发链）/ config_menu / history_cmds |
| `session/` | session_store（sessions.db）/ model_switcher / memory_ops（提取/反思）/ input_history |
| `hooks/` | M6 Pre/PostToolUse 外部钩子 |
| `mcp/` | MCP 客户端（stdio + HTTP） |
| `skills/` | SKILL.md 加载器 + 工具门 |
| `task/` | 线程池 / MPSC / 事件总线 / cron |
| `storage/` | SQLite / 向量存储 |
| `memory/` | 三层记忆 + 反思 + 提取 |
| `knowledge/` | 知识图谱 + 搜索 |
| `runtime/` | 检测规则 / 监控 / 自诊断 / 决策链 |
| `research/` | 优化研究引擎 |
| `checkpoint/` | 文件快照 / 操作日志 / 回滚引擎 |
| `math/` | pi/e/phi 算法 |
| `util/` | 40+ 工具（lineinput 多行编辑器、menu、zivroot 锚定、uwidth utf8proc 宽度、treesitter、turn_clock 遥测、llm_watchdog…） |
| `tests/` | E2E（agent_e2e）+ 集成测试 |
| `config.zig` | 五层配置层级 |
| `repl.zig` | REPL + TUI v2 状态机 |
| `system_prompt.zig` | 系统提示词（输出风格/工具清单动态生成） |

---

## 8. 当前状态与待完成项

### 已完成（关键里程碑）
- 数学核心 / comptime 工具系统 / 多 LLM 后端 / SSE 流式 / SQLite+向量 / 三层记忆 / 反思+提取 / 异步任务 / 运行时检测 / 自诊断 / 6 种权限模式 / 消息压缩 / 五层配置 / checkpoint 回滚（v0.3-v0.5）
- 完整 Agent Loop、工具自动调用、记忆闭环（v0.5-v0.6）
- 事件循环重构、稳定性批次（看护狗/TTFT/Bash 治理/raw 终端）（v0.7）
- 会话恢复、提炼压缩梯子、错误选择器+auto_fix、后台任务、WebFetch、/tasks /last /trace、前缀缓存观测、子代理白名单/fork/max_turns、代码索引 FTS5、/config 重设计、TUI 可读性批次（v0.8.0）
- utf8proc 宽度、sqlite-vec 语义去重、项目根锚定、MCP autostart、Skill 工具门、Hooks、-p 模式、tree-sitter 校验、退出零等待（v0.9.0）
- TUI v2 框架、Concise 风格、全能力子代理、UTF-8 清洗、工具清单动态生成（v0.9.1）

### 已知边界
- `/rewind` 序号/y-N 在管道模式消费后续行——交互模式使用（设计内）
- MCP：npx 由 ziv 原生拉起的 stdio 形态握手不兼容，用 HTTP 方式接入
- Workflow 编排（M5）目前为语法 spike（docs/workflow-spike.md），未产品化

---

## 9. 使用前须知

### 9.1 能用吗？

**能用。** 编译、启动、工具执行、模型切换均正常。不配任何东西也能启动——config 加载对文件不存在做了容错处理。

### 9.2 使用前需要配置什么

什么都不配也能启动。要和 LLM 对话需要至少配一个后端：

| 后端 | 配置方式 | 说明 |
|------|----------|------|
| **Ollama**（最简单） | 本地安装 Ollama，`ollama serve`，`ollama pull llama3.2` | 免费、离线、模型质量一般 |
| **OpenAI** | `export OPENAI_API_KEY=sk-...` 或 `/config` 设置 | 需要 API Key；`OPENAI_BASE_URL` 可指向兼容网关 |
| **Anthropic** | `export ANTHROPIC_API_KEY=sk-ant-...` 或 `/config` 设置 | 需要 API Key；`ANTHROPIC_BASE_URL` 同上 |

自定义网关模型（glm/deepseek 等）：配好对应 base_url + key，`/model glm-4.6` 时选后端，或 settings.json 直接设 `default_backend`。

**不配 API Key 也能用**：`/run` 直接执行工具不需要 LLM，文件读写、搜索、Bash、后台任务等工具都能正常工作。
