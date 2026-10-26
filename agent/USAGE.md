# Ziv — Zig 自学习 Agent 使用说明

> 一个用 Zig 构建的支持多 LLM 后端、具备自动学习能力（记忆+反思+知识库）的 CLI Agent。
> 核心算法由三大数学常数驱动：**pi** 圆融信息、**e** 控制增长、**phi** 浓缩知识。
> v0.3.0 — 完整 Agent Loop：系统提示词 + 对话历史 + 工具调用循环 + 交互式配置。

---

## 1. 环境要求

| 依赖 | 版本 | 说明 |
|------|------|------|
| Zig | 0.17.0 | 编译器 |
| SQLite3 | amalgamation | 已内置于 `deps/sqlite3/` |
| OpenSSL | 系统 | HTTPS 请求 (macOS 使用 Security.framework) |
| C 编译器 | clang/gcc | SQLite C 编译 |
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

## 3. CLI 使用

启动后进入交互式 REPL：

```
╔══════════════════════════════════════╗
║  Ziv — Zig 自学习 Agent v0.3.0      ║
║  pi 圆融 · e 增长 · phi 浓缩         ║
╚══════════════════════════════════════╝
```

### 内置命令

| 命令 | 说明 |
|------|------|
| `/help`, `/h` | 显示帮助信息 |
| `/quit`, `/q`, `/exit` | 退出 Ziv |
| `/version` | 显示版本号 (v0.3.0) |
| `/stats` | 显示当前会话统计（消息数、token 用量、权限模式、当前模型） |
| `/tools` | 列出所有已注册工具（含安全属性） |
| `/run <ToolName> <json>` | 直接执行工具 |
| **模型 & 配置** | |
| `/model` | 显示当前模型和可用模型列表 |
| `/model <name>` | 切换到指定模型（如 `claude-sonnet-4-6`、`gpt-4o`、`llama3.2`） |
| `/mode` | 切换权限模式 |
| `/config` | 打开交互式配置菜单（API Key、模型、权限等） |
| **对话管理** | |
| `/compact` | 压缩对话历史，释放 token |
| `/clear` | 清空对话，重新开始（别名: `/reset`, `/new`） |
| `/context` | 显示当前上下文/token 用量 |
| `/undo` | 撤销上一轮对话 |
| `/history` | 显示操作历史记录 |
| `/rewind` | 回滚到检查点 |

### 权限模式 (Permission Modes)

Ziv 内置 6 种授权执行模式，通过 `/mode` 命令循环切换：

| 模式 | 提示符 | 说明 |
|------|--------|------|
| **Default** | `ziv>` | 默认模式，危险操作需要用户确认 |
| **Accept Edits** | `ziv[edit]>` | 自动接受文件编辑操作，破坏性操作仍需确认 |
| **Plan** | `ziv[plan]>` | 只读模式，所有写操作被阻止 |
| **Bypass** | `ziv[bypass]>` | 跳过所有权限检查 |
| **Don't Ask** | `ziv[dontask]>` | 自动拒绝所有需要确认的操作 |
| **Auto** | `ziv[auto]>` | 自动分类器决定（预留 LLM 集成） |

切换流程（Shift+Tab 或 `/mode`）：
```
default → accept_edits → plan → bypass → default
```

权限管道 6 步检查：
1. **Deny rules** — 全局拒绝规则
2. **Ask rules** — 必须确认的规则（bypass-immune）
3. **Tool check** — 工具自身权限检查
4. **Safety paths** — 保护路径检测（.git/、系统文件等）
5. **Mode behavior** — 当前模式行为
6. **Allow rules** — 全局允许规则

### 工具执行示例

```bash
# 执行 shell 命令
ziv> /run Bash {"command":"ls -la"}

# 读取文件
ziv> /run FileRead {"path":"/tmp/test.txt"}

# 写入文件
ziv> /run FileWrite {"path":"/tmp/hello.txt","content":"Hello, Ziv!"}

# 文件搜索
ziv> /run Glob {"pattern":"*.zig"}
ziv> /run Glob {"pattern":"src/**/*.ts","path":"/project"}

# 内容搜索
ziv> /run Grep {"pattern":"pub fn","path":"src/"}
ziv> /run Grep {"pattern":"TODO","maxResults":10}

# 文件编辑
ziv> /run FileEdit {"path":"test.txt","old_string":"hello","new_string":"world"}
ziv> /run FileEdit {"path":"test.txt","old_string":"foo","new_string":"bar","replaceAll":true}

# 网络搜索（API 待接入）
ziv> /run WebSearch {"query":"zig programming language"}

# 任务管理
ziv> /run TaskCreate {"subject":"修复 bug #42","description":"修复登录验证问题"}
ziv> /run TaskList {}
ziv> /run TaskUpdate {"taskId":"abc123","status":"completed"}

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
    [1] Bash - rollback_safe: true
    [2] FileEdit - rollback_safe: true
    [3] FileWrite - rollback_safe: false
    [4] Glob - rollback_safe: false
    [5] Grep - rollback_safe: false

# 回滚到检查点
ziv[edit]> /rewind
  Rewind: No checkpoints available yet.
```

### 普通对话 (Agent Loop)

输入非 `/` 开头的文本即为对话消息。Ziv 现在是完整的 Agent：

- 每次请求携带**系统提示词 + 完整对话历史**
- LLM 返回 `tool_use` 时**自动执行工具**并将结果反馈，循环直到完成
- 权限检查集成在工具执行中（`default` 模式下破坏性操作需用户确认）
- Token 使用超过 phi 阈值 (61.8%) 时自动压缩历史

提示符中的 `[N%]` 显示当前上下文使用百分比（类似 Claude HUD）：

```
ziv (gpt-4o) [0%] > 列出当前目录的 zig 文件
  [Processing: "列出当前目录的 zig 文件"]
  [calling tool: Glob]
  [Executing: Glob]
  [Result: src/main.zig, src/repl.zig, src/config.zig...]
  当前目录下有以下 zig 文件：
  1. src/main.zig — 程序入口
  2. src/repl.zig — 交互式 REPL
  ...
  [tokens: in=256 out=128 | stop: end_turn]
```

### 模型切换

Ziv 支持在会话中随时切换 LLM 模型，无需重启：

### 交互式配置 (/config)

通过 `/config` 命令打开交互式配置菜单：

```
ziv> /config

=== Ziv Configuration ===
  1. API Keys
  2. Default model       : gpt-4o
  3. Max tokens          : 4096
  4. Permission mode     : Default
  5. Checkpointing       : on
  6. System prompt       : (default)
  7. Save & Exit
  8. Exit without saving

  Select [1-8]:
```

选择 `1` 进入 API Keys 子菜单，选择 `7` 保存到 `~/.config/ziv/settings.json`。

### 对话管理命令

```bash
# 查看上下文用量
ziv (gpt-4o) [12%] > /context
  Context: 2450 / 128000 tokens (1.9%)
  Messages: 1 system, 5 user, 4 assistant, 2 tool
  Compaction threshold: 79104 tokens (61.8%)
  Session total: 1234 in / 567 out tokens

# 手动压缩历史
ziv (gpt-4o) [45%] > /compact
  Compacted: 15 → 10 messages (~3200 tokens)

# 清空对话
ziv (gpt-4o) [45%] > /clear
  Conversation cleared. Starting fresh.

# 撤销上一轮
ziv (gpt-4o) [12%] > /undo
  Undone: removed 2 message(s). History now has 8 messages.
```

```bash
# 查看当前模型和可用模型列表
ziv (gpt-4o)> /model

  Current model: gpt-4o (OpenAI)

  Available models:
   *  gpt-4o                OpenAI     GPT-4o — OpenAI flagship
      gpt-4o-mini           OpenAI     GPT-4o Mini — fast & cheap
      o3-mini               OpenAI     O3 Mini — reasoning
      claude-opus-4-6       Claude     Claude Opus 4.6 — most capable
      claude-sonnet-4-6     Claude     Claude Sonnet 4.6 — balanced
      claude-haiku-4-5      Claude     Claude Haiku 4.5 — fast
      llama3.2              Ollama     Llama 3.2 — local (Ollama)
      qwen2.5               Ollama     Qwen 2.5 — local (Ollama)
      deepseek-r1           Ollama     DeepSeek R1 — local (Ollama)

  * = current model
  Usage: /model <name>  (e.g. /model claude-sonnet-4-6)

# 切换模型
ziv (gpt-4o)> /model claude-sonnet-4-6
  Switched to claude-sonnet-4-6 (Claude)
ziv (claude-sonnet-4-6)> 你好
```

也支持自定义模型名（自动路由到对应后端）：
```bash
ziv> /model claude-opus-4-6     # → Claude 后端
ziv> /model gpt-4-1106-preview  # → OpenAI 后端
ziv> /model mistral             # → Ollama 后端（本地模型）
```

---

## 4. 架构总览

```
Ziv Agent v0.3.0
├── math/           数学常数核心 (pi, e, phi)
├── llm/            多 LLM 后端 (Claude, OpenAI, Ollama) + 消息压缩
├── tools/          comptime 工具系统 (12 tools) + 权限 + 编排
├── task/           异步任务系统 (线程池, MPSC队列, 事件总线, 定时任务)
├── storage/        持久化层 (SQLite, 向量存储)
├── memory/         三层记忆 (工作记忆, 情景记忆, 反思, 经验提取)
├── knowledge/      知识图谱 + 网络搜索
├── runtime/        运行时检测 + 自诊断 + 错误处理
├── research/       自主优化研究引擎
├── checkpoint/     操作记录 + 文件快照 + 回滚引擎
├── util/           工具库 (30+ 文件: cancel, hash, uuid, format, path...)
├── config.zig      五层配置层级
└── repl.zig        交互式 REPL
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
| **phi** | 知识浓缩 | 每次反思将知识压缩到 61.8% |
| **phi** | Fibonacci 哈希 | 最均匀的哈希分布，用于记忆索引 |
| **phi** | 上下文溢出检测 | 使用率超过 61.8% 时预警 |
| **phi** | 任务失败率检测 | 失败率超过 38.2% (1-phi) 时告警 |
| **phi** | 消息压缩触发 | token 使用超过 max_tokens 的 61.8% 时触发压缩 |

### 5.2 多 LLM 后端

| 后端 | 配置 | 状态 |
|------|------|------|
| **Claude** (Anthropic) | 需要 API Key | 完整实现 (claude-opus-4-6, claude-sonnet-4-6, claude-haiku-4-5) |
| **OpenAI** | 需要 API Key | 完整实现 (GPT-4o 等) |
| **Ollama** (本地) | 需要 Ollama 运行 | 完整实现 (llama3.2 等) |

所有后端通过 comptime vtable 模式统一接口：
- `complete()` — 同步请求
- `stream()` — SSE 流式响应
- `countTokens()` — token 估算
- `supportsToolUse()` / `supportsStreaming()`

运行时通过 `/model` 命令自由切换：

```bash
# 查看当前模型和可用模型
ziv> /model

# 切换到 Claude
ziv> /model claude-sonnet-4-6
  Switched to claude-sonnet-4-6 (Claude)

# 切换到 OpenAI
ziv> /model gpt-4o
  Switched to gpt-4o (OpenAI)

# 切换到本地 Ollama
ziv> /model llama3.2
  Switched to llama3.2 (Ollama)
```

模型名会自动识别后端：`claude-*` → Anthropic, `gpt-*`/`o1-*`/`o3-*` → OpenAI, 其他 → Ollama。

### 5.3 工具系统 (12 Tools)

comptime 泛型注册，零运行时开销。每个工具支持：
- **并发安全检查** (`is_concurrency_safe_fn`) — 输入级别判断
- **破坏性检测** (`is_destructive_fn`) — 输入级别判断
- **输入验证** (`validate_input_fn`)
- **权限检查** (`check_permissions_fn`)
- **别名匹配** (`matchesName`) — 支持多名称查找

#### 工具一览

| 工具 | 别名 | 类型 | 并发安全 | 说明 |
|------|------|------|----------|------|
| **Bash** | Shell, sh | 读写/破坏性 | 不安全 | 执行 shell 命令，自动检测破坏性命令 |
| **FileRead** | Read, cat | 只读 | 安全 | 读取文件（带行号、分页） |
| **FileWrite** | Write | 读写 | 不安全 | 写入文件 |
| **Glob** | find | 只读 | 安全 | 目录遍历 + 模式匹配 (`*.zig`, `src/**/*.ts`) |
| **Grep** | search | 只读 | 安全 | 正则内容搜索（优先 ripgrep，回退内置） |
| **FileEdit** | Edit, sed | 读写 | 不安全 | 字符串查找替换编辑 |
| **WebSearch** | — | 只读 | 安全 | 网络搜索（API 待接入） |
| **TaskCreate** | — | 读写 | 不安全 | 创建任务 |
| **TaskList** | — | 只读 | 安全 | 列出所有任务 |
| **TaskUpdate** | — | 读写 | 不安全 | 更新任务状态 |
| **AskUserQuestion** | — | 只读 | 不安全 | 向用户提问（阻塞式） |
| **ToolSearch** | — | 只读 | 安全 | 按关键词搜索可用工具 |

扩展方式：在 `registry.zig` 的 `default_tools` 数组中添加新的 `ToolDefinition`。

### 5.4 工具编排 (Orchestration)

`orchestration.zig` 实现智能工具调用分组：
- `partitionToolCalls()` — 将并发安全的调用分组在一起
- **安全工具并行执行**（FileRead、Glob、Grep 等）
- **不安全工具串行执行**（Bash、FileWrite、FileEdit 等）

```
输入: [FileRead, FileRead, FileWrite, FileRead]
分组: [safe: FileRead, FileRead] → [unsafe: FileWrite] → [safe: FileRead]
```

### 5.5 权限系统

#### 授权模式

6 种权限模式，通过 `/mode` 命令或 Shift+Tab 循环切换：

| 模式 | 行为 |
|------|------|
| **default** | 危险操作需要确认 |
| **accept_edits** | 自动接受非破坏性文件操作 |
| **plan** | 只读，阻止所有写操作 |
| **bypass** | 跳过所有权限检查 |
| **dont_ask** | 自动拒绝需要确认的操作 |
| **auto** | 分类器自动决定 |

#### 权限管道

```
工具调用请求
  │
  ├── Step 1: Deny rules — 匹配拒绝规则 → 直接拒绝
  ├── Step 2: Ask rules — 匹配确认规则 → 提示用户
  ├── Step 3: Tool check — 工具自身权限函数
  ├── Step 4: Safety paths — 保护路径检测 (.git/, /etc/, etc.)
  ├── Step 5: Mode behavior — 按当前模式决定
  └── Step 6: Allow rules — 匹配允许规则 → 放行
```

#### 规则解析器 (rule_parser.zig)

支持 `"Bash(git status)"` 风格的规则语法：
- `"Bash"` — 匹配所有 Bash 调用
- `"Bash(git status)"` — 匹配包含 "git status" 的 Bash 调用
- `"Bash(*)"` — 通配符匹配

#### 自动分类器 (classifier.zig)

auto 模式下的工具分类：
- 安全工具白名单（FileRead, Glob, Grep, ToolSearch, TaskList）始终允许
- 只读工具自动允许
- 破坏性操作自动阻止
- 预留 LLM 集成接口

#### 拒绝追踪器 (denial_tracker.zig)

防止自动拒绝循环：连续拒绝超过阈值时自动回退到提示模式。

### 5.6 消息压缩 (Compaction)

`llm/compaction.zig` 使用 phi 阈值触发上下文压缩：

| 策略 | 说明 |
|------|------|
| **summarize** | 将旧消息发给 LLM 生成摘要 |
| **phi_condense** | 保留最近 61.8% 的消息，丢弃最旧的 |
| **hybrid** | phi-condense + 摘要被丢弃的消息 |

触发条件：当前 token 使用量 > max_tokens x phi (61.8%)

### 5.7 异步任务系统

| 组件 | 说明 |
|------|------|
| **ThreadPool** | e 控制并发上限的工作线程池 |
| **BoundedMPSC** | 无锁多生产者单消费者队列 (容量 256) |
| **EventBus** | 事件发布/订阅，pi ring buffer 存储 |
| **CronScheduler** | 定时任务，pi/phi/e 周期 |

内置定时任务间隔：
- 反思任务：pi x 10 min ≈ 31.4 min
- 知识更新：phi x 60 min ≈ 37.1 min
- 记忆衰减：e x 30 min ≈ 81.5 min
- 健康检查：60 秒
- 资源监控：30 秒

### 5.8 三层记忆系统

| 层 | 存储 | 用途 |
|----|------|------|
| **工作记忆** | 内存 LRU | 当前会话上下文 |
| **情景记忆** | SQLite | 历史交互记录 |
| **语义记忆** | 知识图谱 | 提取的结构化知识 |

附加子系统：
- **反思引擎** — 定期分析交互质量，生成改进建议
- **经验提取** — 从对话中提取事实（用户偏好、错误解决方案、技术事实）
- **phi 浓缩** — 每次浓缩保留 61.8% 最重要的知识

### 5.9 运行时检测 (8 条规则)

| 规则 | 阈值 | 说明 |
|------|------|------|
| 内存使用 | sigmoid(2*(ratio-0.7)) > 0.8 | e 控制压力 |
| API 限速 | 调用率 > 80% | 速率保护 |
| 存储完整性 | SQLite integrity_check | 数据安全 |
| 上下文溢出 | token 使用 > phi (61.8%) | phi 预警 |
| 任务健康 | 失败率 > 1-phi (38.2%) | phi 阈值 |
| 网络连通 | 超时 > 3 次 | 连接稳定性 |
| 并发压力 | 使用率 > 90% | 资源饱和 |
| 决策质量 | 上下文 > 95% | 紧急浓缩 |

### 5.10 自诊断引擎

当用户质疑结果时，Ziv 会：
1. 回溯决策链（7 个阶段：记忆检索 → 上下文组装 → 工具选择 → 工具执行 → LLM 生成 → 后处理 → 反思触发）
2. 找到 confidence < phi 的弱步骤
3. 生成诊断报告（问题定位 + 原因分析 + 改进建议）

### 5.11 自主优化研究

当用户要求"优化"、"寻找最佳方案"时：
1. 用 LLM 生成搜索关键词
2. 并发搜索多个引擎（Brave/SearXNG/DuckDuckGo）
3. phi 浓缩筛选 top 61.8% 方案
4. 兼容性评分 + 复杂度评估
5. 生成方案对比报告，供用户选择

### 5.12 操作记录与回滚 (Checkpoint)

`src/checkpoint/` 提供完整的操作审计和文件回滚：

| 组件 | 文件 | 说明 |
|------|------|------|
| **FileHistory** | file_history.zig | SHA256 文件快照备份 + 恢复（trackEdit + restoreSnapshot） |
| **OperationLog** | op_log.zig | 每次工具调用的操作记录引擎 |
| **RollbackEngine** | rollback.zig | 完整回滚执行器（listRollbackPoints + previewRollback + rollbackTo） |

**工作流程：**

1. 执行 FileWrite/FileEdit 前，`trackEdit()` 自动备份原始文件到 `.ziv/checkpoints/`
2. 如果文件不存在（新建），记录为"新文件"（rollback 时会删除）
3. `/history` 查看所有操作记录
4. `/rewind` 列出回滚点 → 预览影响 → 确认后恢复文件

**备份内容：** SHA256 哈希校验 + 文件内容备份，内容未变化时跳过备份。

**回滚过程：** 反向遍历操作日志（最新优先），从每个快照恢复文件。

---

## 6. 配置说明

### 6.1 配置文件层级

Ziv 支持 5 层配置源，后者覆盖前者：

```
优先级（从低到高）：
  user_settings    → ~/.config/ziv/settings.json
  project_settings → .ziv/settings.json
  local_settings   → .ziv/settings.local.json
  cli_args         → 命令行参数
  session          → 运行时设置
```

### 6.2 配置文件格式

`~/.config/ziv/settings.json` 或 `.ziv/settings.json`：

```json
{
  "permission_mode": "default",
  "default_model": "gpt-4o",
  "max_tokens": 4096,
  "checkpointing_enabled": true,
  "system_prompt": "You are a helpful coding assistant...",
  "api_keys": {
    "openai": "sk-...",
    "anthropic": "sk-ant-...",
    "brave": "BSA-..."
  },
  "allow_rules": [
    "Bash(git status)",
    "Bash(git log)",
    "FileRead"
  ],
  "deny_rules": [
    "Bash(rm -rf /)",
    "Bash(dd if=/dev/zero)"
  ]
}
```

#### 配置项说明

| 配置项 | 类型 | 默认值 | 说明 |
|--------|------|--------|------|
| `permission_mode` | string | `"default"` | 权限模式: default/accept_edits/plan/bypass/dont_ask/auto |
| `default_model` | string | `"gpt-4o"` | 默认 LLM 模型 |
| `max_tokens` | integer | `4096` | 最大 token 数 (1-128000) |
| `max_snapshots` | integer | `100` | 最大快照数量 |
| `checkpointing_enabled` | boolean | `true` | 是否启用操作记录和检查点 |
| `system_prompt` | string | null | 自定义系统提示词（null 则使用内置默认） |
| `api_keys.openai` | string | null | OpenAI API Key（也支持 OPENAI_API_KEY 环境变量） |
| `api_keys.openai_base_url` | string | null | OpenAI API 自定义地址（也支持 OPENAI_BASE_URL 环境变量） |
| `api_keys.anthropic` | string | null | Anthropic API Key（也支持 ANTHROPIC_API_KEY 环境变量） |
| `api_keys.anthropic_base_url` | string | null | Anthropic API 自定义地址（也支持 ANTHROPIC_BASE_URL 环境变量） |
| `api_keys.brave` | string | null | Brave Search API Key（也支持 BRAVE_API_KEY 环境变量） |
| `api_keys.ollama_host` | string | `"http://localhost:11434"` | Ollama 服务地址 |
| `allow_rules` | string[] | [] | 允许规则列表 |
| `deny_rules` | string[] | [] | 拒绝规则列表 |

### 6.3 代码中配置

#### LLM 后端配置

在代码中创建 Provider 实例：

```zig
// OpenAI
const openai_cfg = llm.OpenAIConfig{
    .api_key = "sk-...",
    .model = "gpt-4o",
};
var openai = llm.OpenAIProvider.init(allocator, openai_cfg);
const provider = openai.toProvider();

// Ollama (本地)
const ollama_cfg = llm.OllamaConfig{
    .model = "llama3.2",
    .base_url = "http://localhost:11434",
};
var ollama = llm.OllamaProvider.init(allocator, ollama_cfg);
const provider = ollama.toProvider();
```

#### 数据库路径

默认使用当前目录的 `data/ziv.db`。修改 `Database.init()` 的路径参数即可。

#### 定时任务间隔

在 `task/cron.zig` 中修改常量：

```zig
pub const REFLECTION_INTERVAL = @intFromFloat(PI * 10.0 * 60.0 * 1000.0); // ~31.4 min
pub const KNOWLEDGE_UPDATE_INTERVAL = @intFromFloat(PHI * 60.0 * 60.0 * 1000.0); // ~37.1 min
pub const MEMORY_DECAY_INTERVAL = @intFromFloat(E * 30.0 * 60.0 * 1000.0); // ~81.5 min
```

#### 工作记忆容量

在 `memory/working.zig` 的 `init()` 中修改 `max_entries` 参数（默认 50）。

#### 线程池并发上限

由 `e_growth.zig` 的 `effectiveConcurrency()` 自动根据 CPU 核心数计算，使用 logistic 函数限制。

---

## 7. 项目结构

### 7.0 目录概览

#### 顶层文件
- 这是 agent/ 目录的结构概览

| 文件/目录 | 说明 |
|---|---|
| `build.zig` | Zig 构建配置（主） |
| `build_full.zig` | Zig 构建配置（完整版） |
| `build.zig.zon` | Zig 包管理依赖声明 |
| `DESIGN.md` | 设计文档 |
| `TODO.md` | 待办事项 |
| `USAGE.md` | 使用说明 |

#### `src/` — 源代码

| 子目录 | 用途 |
|---|---|
| `llm/` | LLM 后端集成（Claude、OpenAI、Ollama、流式处理、消息压缩/compaction） |
| `tools/` | 工具实现（bash、文件读写编辑、glob、grep、web搜索、任务管理、工具注册、权限控制等） |
| `memory/` | 记忆系统（情景记忆、工作记忆、反思、提取、类型定义） |
| `knowledge/` | 知识图谱（图结构、搜索） |
| `checkpoint/` | 检查点/回滚机制（文件历史、操作日志） |
| `storage/` | 存储层（SQLite 数据库、向量存储） |
| `runtime/` | 运行时（规则引擎、错误处理、监控、自诊断） |
| `task/` | 任务调度（cron、事件总线、线程池、消息队列） |
| `math/` | 数学工具（常量、phi/pi/e 相关算法） |
| `util/` | 工具函数（路径、HTTP、JSON、日志、子进程、ripgrep 封装、token 计数等） |
| `research/` | 研究模块（优化研究器） |
| `config.zig` | 配置管理 |
| `main.zig` | 程序入口 |
| `repl.zig` | REPL 交互循环 |
| `system_prompt.zig` | 系统提示词构建 |

#### 其他目录

| 目录 | 说明 |
|---|---|
| `data/` | 数据文件（`prompts/` 提示词模板、`migrations/` 数据库迁移） |
| `deps/` | 第三方依赖（`sqlite3`） |
| `.zig-cache/` | Zig 编译缓存 |
| `zig-out/` | 构建输出（编译产物 `bin/ziv`） |

### 7.1 详细结构树

```
agent/
├── build.zig              # 构建配置
├── build.zig.zon          # 包元数据
├── build_full.zig         # 完整构建配置
├── DESIGN.md              # 完整设计文档
├── USAGE.md               # 本文件
├── TODO.md                # 待办事项
├── deps/
│   └── sqlite3/           # SQLite amalgamation
├── data/
│   └── migrations/        # SQL 迁移脚本
└── src/
    ├── main.zig           # 入口 + 自检
    ├── repl.zig           # 交互式 REPL（v0.3.0 — 完整 Agent Loop）
    ├── config.zig         # 五层配置层级 + saveSettings + env 回退
    ├── system_prompt.zig  # 默认系统提示词
    │
    ├── math/              # 数学常数模块
    │   ├── mod.zig        # 模块导出
    │   ├── constants.zig  # pi, e, phi 定义
    │   ├── pi_ring.zig    # pi 环形缓冲区
    │   ├── e_growth.zig   # e 增长控制
    │   └── phi_condense.zig # phi 知识浓缩
    │
    ├── llm/               # LLM 多模型层
    │   ├── mod.zig        # 模块导出 + 模型工厂 + 后端检测
    │   ├── provider.zig   # 统一接口 + vtable
    │   ├── message.zig    # 消息序列化
    │   ├── streaming.zig  # SSE 解析器
    │   ├── openai.zig     # OpenAI 后端
    │   ├── ollama.zig     # Ollama 后端
    │   ├── claude.zig     # Claude/Anthropic 后端 (NEW)
    │   └── compaction.zig # 消息压缩（phi 阈值触发）
    │
    ├── tools/             # 工具系统
    │   ├── mod.zig        # 模块导出（12 工具）
    │   ├── registry.zig   # comptime 注册器 + 增强接口
    │   ├── orchestration.zig  # 工具编排（并行/串行）（NEW）
    │   ├── auth_mode.zig  # 6 种授权模式 + 权限管道（NEW）
    │   ├── rule_parser.zig    # 权限规则解析器（NEW）
    │   ├── classifier.zig     # 自动模式分类器（NEW）
    │   ├── denial_tracker.zig # 拒绝追踪器（NEW）
    │   ├── bash.zig       # Shell 执行
    │   ├── file_read.zig  # 文件读取
    │   ├── file_write.zig # 文件写入
    │   ├── glob.zig       # 目录遍历 + 模式匹配（NEW）
    │   ├── grep.zig       # ripgrep/内置搜索（NEW）
    │   ├── file_edit.zig  # 字符串替换编辑（NEW）
    │   ├── web_search.zig # 网络搜索（NEW）
    │   ├── task_create.zig    # 创建任务（NEW）
    │   ├── task_list.zig  # 列出任务（NEW）
    │   ├── task_update.zig    # 更新任务（NEW）
    │   ├── ask_user.zig   # 向用户提问（NEW）
    │   └── tool_search.zig    # 工具搜索（NEW）
    │
    ├── task/              # 异步任务
    │   ├── mod.zig        # 模块导出
    │   ├── thread_pool.zig
    │   ├── mpsc_queue.zig
    │   ├── event_bus.zig
    │   └── cron.zig
    │
    ├── storage/           # 持久化
    │   ├── mod.zig        # 模块导出
    │   ├── database.zig   # SQLite 封装
    │   └── vector.zig     # 向量存储
    │
    ├── memory/            # 记忆系统
    │   ├── mod.zig        # 模块导出
    │   ├── types.zig      # 记忆类型定义
    │   ├── working.zig    # 工作记忆
    │   ├── episodic.zig   # 情景记忆
    │   ├── memory.zig     # 记忆协调器
    │   ├── reflection.zig # 反思引擎
    │   └── extraction.zig # 经验提取
    │
    ├── knowledge/         # 知识库
    │   ├── mod.zig        # 模块导出
    │   ├── graph.zig      # 知识图谱
    │   └── search.zig     # 网络搜索
    │
    ├── runtime/           # 运行时
    │   ├── decision_trace.zig  # 决策链记录
    │   ├── rules.zig      # 检测规则接口
    │   ├── builtin_rules.zig   # 8 条内置规则
    │   ├── monitor.zig    # 运行时监控器
    │   ├── self_diagnostic.zig # 自诊断引擎
    │   └── error_handler.zig   # 错误反馈
    │
    ├── research/
    │   └── optimization_researcher.zig # 优化研究引擎
    │
    ├── checkpoint/        # 操作记录与回滚（NEW）
    │   ├── mod.zig        # 模块导出
    │   ├── file_history.zig  # 文件快照备份
    │   ├── op_log.zig     # 操作记录引擎
    │   └── rollback.zig   # 回滚引擎
    │
    └── util/              # 工具库（NEW, 30+ 文件）
        ├── mod.zig            # 模块导出
        ├── cancel.zig         # CancelToken, ChildCancelToken, CombinedCancelToken
        ├── shell_quote.zig    # quoteForShell, parseShellCommand, buildCommand
        ├── hash.zig           # sha256, fingerprint, fnv1a
        ├── uuid.zig           # v4, shortId
        ├── log.zig            # 结构化日志
        ├── format.zig         # bytes, tokens, cost, duration, percent 格式化
        ├── string_utils.zig   # startsWith, endsWith, contains, truncate, indent
        ├── path.zig           # extension, stem, normalize, join, isInsidePath, relative
        ├── platform.zig       # OS/Arch 检测
        ├── env.zig            # get, getOr, getInt, getBool, homeDir, editor
        ├── system_dirs.zig    # XDG config/data/cache 目录
        ├── json_helpers.zig   # getString, getInt, getFloat, getBool, parse, serialize
        ├── tokens.zig         # estimateTokens, TokenBudget (phi 阈值)
        ├── time.zig           # nowSeconds, nowMillis, formatIso, sleepMs
        ├── file_cache.zig     # PiRingBuffer LRU 文件缓存
        ├── binary_check.zig   # isBinary, hasBinaryExtension
        ├── find_executable.zig # findExecutable, commandExists
        ├── sanitization.zig   # sanitizeFilePath, isProtectedPath, isGitPath, detectInjection
        ├── subprocess.zig     # exec, execShell, execQuiet
        ├── cleanup.zig        # register, runAll shutdown handlers
        ├── tempfile.zig       # create, createDir, writeAll
        ├── diff.zig           # computeDiff, stats
        ├── fs_ops.zig         # fileExists, dirExists, ensureDir, readFileAlloc, writeFile...
        ├── lockfile.zig       # 文件互斥锁
        ├── semver.zig         # Version parse/compare
        ├── memoize.zig        # MemoCache 泛型缓存
        ├── glob_match.zig     # match, matchPath (** 支持)
        ├── ripgrep.zig        # search via rg/grep
        └── http_client.zig    # HTTP GET with retry
```

---

## 8. 当前状态与待完成项

### 已完成
- [x] 数学核心 (pi/e/phi 全部实现+测试)
- [x] comptime 工具系统 (12 工具)
- [x] 增强工具接口 (并发安全、破坏性检测、输入验证、权限检查、别名)
- [x] 工具编排 (并行/串行分组执行)
- [x] 多 LLM 后端 (Claude, OpenAI, Ollama 全部完整实现)
- [x] SSE 流式解析器
- [x] SQLite 持久化 + 数据库迁移
- [x] 向量存储 + 余弦相似度
- [x] 三层记忆系统框架
- [x] 反思引擎 + 经验提取
- [x] 异步任务系统 (线程池, MPSC, 事件总线, 定时任务)
- [x] 运行时检测 (8 条规则)
- [x] 自诊断引擎 + 决策链
- [x] 错误处理与用户反馈
- [x] 网络搜索 (Brave/SearXNG/DuckDuckGo)
- [x] 自主优化研究引擎
- [x] 6 种授权执行模式 + 权限管道
- [x] 规则解析器 + 自动分类器 + 拒绝追踪器
- [x] 消息压缩 (phi 阈值触发)
- [x] 五层配置层级
- [x] 操作记录引擎 + 文件快照 + 完整回滚逻辑（trackEdit/restoreSnapshot/rollbackTo）
- [x] 30+ 工具库 (util/)
- [x] **v0.3.0 — 完整 Agent Loop**
- [x] 系统提示词 (system_prompt.zig)
- [x] 对话历史保持 (多轮上下文)
- [x] 工具调用循环 (tool_use → 权限检查 → 执行 → 结果回传)
- [x] 压缩接入 (自动 + /compact 手动)
- [x] 交互式配置菜单 (/config)
- [x] API Key 环境变量回退 (OPENAI_API_KEY, ANTHROPIC_API_KEY, BRAVE_API_KEY, OPENAI_BASE_URL, ANTHROPIC_BASE_URL)
- [x] 配置持久化保存
- [x] 对话管理命令 (/compact, /clear, /context, /undo)
- [x] Token 用量追踪
- [x] 运行时模型切换 (/model <name>)
- [x] LLM Provider 工厂 + 自动后端检测

### 待完成
- [x] EpisodicStore 参数化查询 (防 SQL 注入) — prepared statement + 注入往返测试
- [ ] KnowledgeGraph 参数化查询
- [x] MPSC Queue pop() 完整实现 (deinit 残留 tail 泄漏已修)
- [ ] 流式输出优化 (边读边解析 SSE)
- [ ] 跨平台测试
- [ ] Checkpoint 目录自动创建（首次 trackEdit 时 .ziv/checkpoints 可能不存在）
- [ ] 自动分类器 LLM 集成
- [ ] WebSearch API 接入
- [ ] 运行日志集成（util/log.zig 已实现但未在各模块调用）

---

## 9. 使用前须知

### 9.1 能用吗？

**能用。** 编译、启动、工具执行、模型切换均正常。不配任何东西也能启动——config 加载对文件不存在做了容错处理。

### 9.2 使用前需要配置什么

什么都不配也能启动。要和 LLM 对话需要至少配一个后端：

| 后端 | 配置方式 | 说明 |
|------|----------|------|
| **Ollama**（最简单） | 本地安装 Ollama，运行 `ollama serve`，再 `ollama pull llama3.2` | 免费、离线、模型质量一般 |
| **OpenAI** | `export OPENAI_API_KEY=sk-...` 或 `/config` 设置 | 需要 API Key |
| **Anthropic** | `export ANTHROPIC_API_KEY=sk-ant-...` 或 `/config` 设置 | 需要 API Key |

也可以在 `~/.config/ziv/settings.json` 中写入配置：

```json
{
  "default_model": "llama3.2",
  "api_keys": {
    "openai": "sk-...",
    "anthropic": "sk-ant-..."
  }
}
```

**不配 API Key 也能用**：`/run` 直接执行工具不需要 LLM，文件读写、搜索、Bash 等工具都能正常工作。

### 9.3 当前已知问题

| 问题 | 影响 | 严重度 | 临时解决 |
|------|------|--------|----------|
| `.ziv/checkpoints/` 不会自动创建 | 备份静默失败，`/rewind` 无效 | 中 | 手动执行 `mkdir -p .ziv/checkpoints` |
| WebSearch API 未接入 | `/run WebSearch` 不可用 | 低 | 使用 `/run Bash {"command":"curl ..."}` 替代 |
| 流式输出非实时 | LLM 回复要等全部生成完才显示 | 低 | 暂无 |
| uuid 模块未验证 | 影响记忆系统（框架阶段未实际调用） | 低 | 暂无 |
| config 加载无崩溃保护 | settings.json 不存在时已容错（catch return），但格式错误时可能异常 | 低 | 确保 JSON 格式正确 |
