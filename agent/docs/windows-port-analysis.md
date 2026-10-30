# Windows 支持可行性分析（2026-10-30，仅分析未实施）

> 状态：**已记录，暂不动**。本文是评估快照，动工前按 L1→L5 顺序出实施计划。

## 一、现状盘点

### 已跨平台（无需改动）

| 项 | 证据 |
|---|---|
| 语言/编译 | Zig 0.17 原生支持 `x86_64-windows-gnu` 交叉编译 |
| SQLite | amalgamation（`deps/sqlite3/sqlite3.c`）windows-gnu 直接可编 |
| HTTP/LLM 客户端 | `util/http_client.zig` 用 `std.http.Client`，std 自带 Windows 实现 |
| 线程池 | `task/thread_pool.zig` 用 `std.Thread` |
| HOME 兼容 | `util/env.zig` 已 `HOME orelse USERPROFILE` |
| 平台占位 | `util/platform.zig` 有 `windows => "cmd.exe"` 分支（当前无消费方） |

### POSIX 专属依赖（全部要动）

| 层 | 依赖 | 锚点 | Windows 对应物 |
|---|---|---|---|
| 终端 raw 模式 | `termios`/`tcgetattr`/`tcsetattr`/ISIG/ICRNL | `util/menu.zig:81-93` | `SetConsoleMode`（`ENABLE_VIRTUAL_TERMINAL_INPUT` 等） |
| 就绪轮询 | `std.c.poll`（escProbe/tryTakeCsi/菜单超时 6+ 处） | `util/lineinput.zig:496,505,525,577,588`、`menu.zig:49` | `WaitForSingleObject` + `GetNumberOfConsoleInputEvents` |
| 终端宽度 | `ioctl TIOCGWINSZ` | `lineinput.zig:89-90` | `GetConsoleScreenBufferInfo` |
| 信号恢复 | `sigaction` INT/TERM + SIGTSTP 挂起 | `menu.zig:119-143` | `SetConsoleCtrlHandler`；Ctrl-Z 挂起移除（无作业控制） |
| 跨进程文件锁 | `std.c.flock` | `repl.zig:3044,3053` | `LockFileEx` |
| 时钟 | `std.posix.system.clock_gettime` | `util/time.zig:13` | `GetSystemTimeAsFileTime` / QPC |
| Shell 执行 | 硬编码 `/bin/sh -c` | `util/subprocess.zig:29`、`tools/bash.zig:29` | 见决策① |
| Shell 引用 | POSIX 单引号转义 | `util/shell_quote.zig` | cmd/PowerShell 语法重写 |
| 可执行查找 | 无 `.exe/.bat/.cmd`、PATH 用 `:` | `util/find_executable.zig` | 后缀枚举 + `;` 分隔 |
| 目录约定 | XDG 三件套 | `util/system_dirs.zig:8-28` | `%APPDATA%`/`%LOCALAPPDATA%` |
| /tmp 硬编码 | 仅测试代码 | `storage/database.zig:314` 等 5 处 | `std.testing.tmpDir` |
| 发版 | 4 个 POSIX target + pkg/deb/install.sh | `release.sh:26-30` | 加 windows-gnu → `ziv.exe` + zip + `install.ps1` |

## 二、实施分层（依赖顺序）

1. **L1 终端 I/O 抽象层（大头，3-5 天）**：RawGuard/poll/termWidth 收拢为 `termio` 抽象（posix/_windows 两后端）。新输入功能（kitty 协议、bracketed paste、CSI 解析）是纯字节流逻辑天然跨平台；需处理 conhost 的 ANSI 开关（`ENABLE_VIRTUAL_TERMINAL_PROCESSING`）与 UTF-8 代码页（`SetConsoleCP(65001)`）。**核心风险**：Windows 控制台是事件流不是字节流，escProbe 的 5ms 竞态窗口语义需重验证。
2. **L2 Shell/工具层（2-3 天）**：platform.zig shell 抽象接线；bash 工具超时 kill 换 Job Object（无进程组）；rg.exe 查找。
3. **L3 路径/锁/时钟（1-2 天）**：system_dirs Windows 分支、flock→LockFileEx、clock、路径分隔符审计。
4. **L4 发版/CI（1-2 天）**：release.sh 加 target（mac 上交叉编译直接产出 exe，无需 Windows 机器）；install.ps1；可选 GitHub Actions windows runner 跑测试。
5. **L5 测试修整（1-2 天）**：/tmp 替换、POSIX 专属用例跳过。

**总计约 2 周出可用 beta。**

## 三、待拍板决策

1. **Shell 策略**：PowerShell（推荐，现代默认，工具文档需改写）/ cmd.exe（最简但弱）/ 强制 git-bash（POSIX 语义保留但门槛高）/ WSL（等于不支持原生）
2. **最低终端要求**：仅 Windows Terminal（省 conhost 兼容工作）vs 兼容老 conhost
3. **ABI**：windows-gnu（zig 一键交叉编译，推荐）vs MSVC

**推荐组合**：PowerShell + 仅 Windows Terminal + windows-gnu。
