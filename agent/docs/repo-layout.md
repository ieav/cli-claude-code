# agent/ 仓库目录导览（2026-11-13 建立）

> 一页看懂 agent/ 下每个目录是什么、git 是否跟踪。定位：新人（或隔了
> 几周的自己）打开仓库的第一跳。架构设计见 DESIGN.md，用户用法见
> USAGE.md，各专题见 docs/ 同级文档——本文只讲「东西放在哪」。

## 顶层目录

### 构建与代码

| 路径 | 说明 | git |
|---|---|---|
| `src/` | Zig 源码主体（子模块见下表） | 跟踪 |
| `deps/` | vendored C 依赖源码：`sqlite3`（存储底座）、`sqlite_vec`（向量检索，语义去重/KNN）、`tree-sitter`（语法解析）、`utf8proc`（Unicode 显示宽表） | 跟踪 |
| `build.zig` / `build.zig.zon` / `build_full.zig` | 构建脚本 + 依赖清单 | 跟踪 |
| `zig-out/` | `zig build` 输出：`bin/ziv`（本地开发/pty 测试用的二进制）、`ziv.exe`+`ziv.pdb`（Windows 交叉产物） | **忽略**（例外：`bin/zage`——2026-04-16 首提交遗留的 arm64 二进制，早于 .gitignore 规则，仍被跟踪） |
| `.zig-cache/` | Zig 构建缓存，可随时删（代价是全量重建） | 忽略 |

### 发布

| 路径 | 说明 | git |
|---|---|---|
| `release.sh` | 出包脚本：5 目标交叉编译 → tar.gz/zip/pkg → SHA256SUMS + install.sh/ps1 | 跟踪 |
| `dist/` | release.sh 产物（`ziv-v<版本>/`：5 平台二进制 + 校验和 + 安装脚本）。**保持跟踪但改动放着不管**（见 agent/CLAUDE.md 发版纪律） | 跟踪 |
| `scripts/` | 开发脚本：`pty_suite.py`（23 场景 pty 端到端测试，TUI 行为改动的验收标准）；`__pycache__/` 是 Python 字节码缓存（pty_suite 被 import 时生成，可删可重建） | pty_suite 跟踪；__pycache **未忽略**（会冒 ?? 状态） |

### 运行时数据

| 路径 | 说明 | git |
|---|---|---|
| `.ziv/` | ziv 吃自己狗粮：本项目作为「项目」的存储锚点（见下方内部结构）。机制设计见 docs/ziv-project-root.md | 忽略 |

`.ziv/` 内部（锚定方案的约定布局）：`memory.db`（记忆）/ `sessions.db`（会话）/ `index.db`（代码索引）/ `checkpoints/`（文件历史备份）/ `logs/` / `traces/`（每回合 JSONL）/ `tasks/`（后台任务输出）/ `pending_extract/`（退出延迟提取存档）/ `plan.md` / `input_history/` / `skills/`（项目级）。

### 文档

| 路径 | 说明 |
|---|---|
| `DESIGN.md` | 完整设计文档（含现状对账表：设计承诺 vs 实现、超纲兑现登记） |
| `USAGE.md` | 使用手册（命令 / 工具 / 场景用法） |
| `TODO.md` | 任务清单与路线 |
| `ziv.md` | 项目级 AI 规则块——repl.zig 热加载（每提示符刷新）注入 system prompt |
| `CLAUDE.md` | 本仓给 Claude Code 的规则（dist 产物纪律） |
| `docs/` | 专题文档：`tui-architecture`（TUI 不变量，改动须同步）、`tui-event-loop-plan`、`ziv-roadmap`、`ziv-project-root`（.ziv 锚定）、`windows-port-analysis`、`upgrade-plan`、`bug-patterns`、`config-ux-design`（配置操作规程 v2.1）、`harness-efficiency-plan`、`workflow-spike`、`repo-layout`（本文） |

### 杂物（事实记录，非清理建议）

| 路径 | 说明 | git |
|---|---|---|
| `.playwright-mcp/` | Playwright MCP 插件的一次页面快照（2026-10-27 的 yml） | **跟踪** |
| `data/` | 空目录 | 未跟踪（git 不收空目录） |
| `ziv_stderr.log` | 一次 `ziv -p` 因 MissingApiKey 失败的 stderr 残留 | 忽略 |
| `.DS_Store` | macOS Finder 元数据 | 忽略 |

## src/ 子模块

| 模块 | 职责 |
|---|---|
| `main.zig` / `repl.zig` | 入口（Windows 控制台初始化、VT gate、cleanup 注册）+ REPL 主循环（提示符、回合调度、ziv.md 热加载） |
| `commands/` | 斜杠命令分发 `dispatch.zig` + /config 菜单 `config_menu.zig` + 历史命令 |
| `tools/` | 给 LLM 的工具层（bash、文件读写、后台任务、agent 调度、ask_user、WebFetch…） |
| `turn/` | 单回合执行：流式输出、工具循环、错误恢复 `error_recovery`、ask 门 `ask` |
| `agent/` | oneshot（`-p` 打印模式）+ subagent 子代理 |
| `llm/` | 后端适配（openai / claude / ollama）+ 历史 compaction + 消息模型 |
| `session/` | 会话存储、输入历史、模型切换器 |
| `memory/` | 记忆系统：提取 extraction、注入 injection、情景 episodic、反思 reflection |
| `knowledge/` | 知识图 graph + Web 搜索 search |
| `research/` | optimization_researcher：并发搜方案、排序、兼容性打分（消费 math/） |
| `storage/` | SQLite + 向量底座（`sqlite_c` 绑定、`vector.zig`） |
| `mcp/` | MCP 客户端（config / jsonrpc / http / session / probe） |
| `hooks/` | hooks 系统（pre-block / post-side-effect / matcher） |
| `skills/` | skill 加载 loader + 工具门 gate（`tools:` 声明强制） |
| `rules/` | ziv.md 项目规则块的解析与热加载 |
| `runtime/` | 运行时自诊断：健康检测规则（每条产 CheckResult + 修复建议）、监控 monitor、错误处理、决策追踪 |
| `checkpoint/` | 文件历史 file_history、操作日志 op_log、回滚 rollback |
| `task/` | 并发基建：线程池、mpsc 队列、事件总线 event_bus、cron |
| `math/` | 数学原语：π 环形缓冲、e 增长/sigmoid、φ 浓缩（Fibonacci 哈希 / 黄金分割搜索）——设计三件套的落点 |
| `util/` | 基础设施：termio（终端模式）、lineinput（输入区/region）、menu、cleanup、zivroot（锚点）、env、diff… |
| `tests/` | e2e + 集成测试 |
| `config.zig` / `system_prompt.zig` | 配置三层加载/保存（用户 → 项目 → 本地）+ 系统提示词与输出风格 |
