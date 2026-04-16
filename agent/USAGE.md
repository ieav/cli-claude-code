# Ziv — Zig 自学习 Agent 使用说明

> 一个用 Zig 构建的支持多 LLM 后端、具备自动学习能力（记忆+反思+知识库）的 CLI Agent。
> 核心算法由三大数学常数驱动：**pi** 圆融信息、**e** 控制增长、**phi** 浓缩知识。

---

## 1. 环境要求

| 依赖 | 版本 | 说明 |
|------|------|------|
| Zig | 0.16.0 | 编译器 |
| SQLite3 | amalgamation | 已内置于 `deps/sqlite3/` |
| OpenSSL | 系统 | HTTPS 请求 (macOS 使用 Security.framework) |
| C 编译器 | clang/gcc | SQLite C 编译 |

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
║  Ziv — Zig 自学习 Agent v0.1.0      ║
║  pi 圆融 · e 增长 · phi 浓缩         ║
╚══════════════════════════════════════╝
```

### 内置命令

| 命令 | 说明 |
|------|------|
| `/help`, `/h` | 显示帮助信息 |
| `/quit`, `/q`, `/exit` | 退出 Ziv |
| `/version` | 显示版本号 |
| `/stats` | 显示当前会话统计 |
| `/tools` | 列出所有已注册工具 |
| `/run <ToolName> <json>` | 直接执行工具 |

### 工具执行示例

```bash
# 执行 shell 命令
ziv> /run Bash {"command":"ls -la"}

# 读取文件
ziv> /run FileRead {"path":"/tmp/test.txt"}

# 写入文件
ziv> /run FileWrite {"path":"/tmp/hello.txt","content":"Hello, Ziv!"}
```

### 普通对话

输入非 `/` 开头的文本即为对话消息（需 LLM 接入后生效）：

```
ziv> 你好，请帮我分析一下这个项目的结构
  [Processing: "你好，请帮我分析一下这个项目的结构"]
  Agent: I received your message. LLM integration coming next.
```

---

## 4. 架构总览

```
Ziv Agent
├── math/           数学常数核心 (pi, e, phi)
├── llm/            多 LLM 后端 (Claude, OpenAI, Ollama)
├── tools/          comptime 工具系统 (Bash, FileRead, FileWrite)
├── task/           异步任务系统 (线程池, MPSC队列, 事件总线, 定时任务)
├── storage/        持久化层 (SQLite, 向量存储)
├── memory/         三层记忆 (工作记忆, 情景记忆, 反思, 经验提取)
├── knowledge/      知识图谱 + 网络搜索
├── runtime/        运行时检测 + 自诊断 + 错误处理
├── research/       自主优化研究引擎
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

### 5.2 多 LLM 后端

| 后端 | 配置 | 状态 |
|------|------|------|
| **Claude** (Anthropic) | 需要 API Key | 框架就绪，需接入真实 HTTP 调用 |
| **OpenAI** | 需要 API Key | 完整实现 (GPT-4o 等) |
| **Ollama** (本地) | 需要 Ollama 运行 | 完整实现 (llama3.2 等) |

所有后端通过 comptime vtable 模式统一接口：
- `complete()` — 同步请求
- `stream()` — SSE 流式响应
- `countTokens()` — token 估算
- `supportsToolUse()` / `supportsStreaming()`

### 5.3 工具系统

comptime 泛型注册，零运行时开销：

| 工具 | 类型 | 说明 |
|------|------|------|
| **Bash** | 读写/破坏性 | 执行 shell 命令 |
| **FileRead** | 只读 | 读取文件（带行号） |
| **FileWrite** | 读写 | 写入文件 |

扩展方式：在 `registry.zig` 的 `default_tools` 数组中添加新的 `ToolDefinition`。

### 5.4 异步任务系统

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

### 5.5 三层记忆系统

| 层 | 存储 | 用途 |
|----|------|------|
| **工作记忆** | 内存 LRU | 当前会话上下文 |
| **情景记忆** | SQLite | 历史交互记录 |
| **语义记忆** | 知识图谱 | 提取的结构化知识 |

附加子系统：
- **反思引擎** — 定期分析交互质量，生成改进建议
- **经验提取** — 从对话中提取事实（用户偏好、错误解决方案、技术事实）
- **phi 浓缩** — 每次浓缩保留 61.8% 最重要的知识

### 5.6 运行时检测 (8 条规则)

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

### 5.7 自诊断引擎

当用户质疑结果时，Ziv 会：
1. 回溯决策链（7 个阶段：记忆检索 → 上下文组装 → 工具选择 → 工具执行 → LLM 生成 → 后处理 → 反思触发）
2. 找到 confidence < phi 的弱步骤
3. 生成诊断报告（问题定位 + 原因分析 + 改进建议）

### 5.8 自主优化研究

当用户要求"优化"、"寻找最佳方案"时：
1. 用 LLM 生成搜索关键词
2. 并发搜索多个引擎（Brave/SearXNG/DuckDuckGo）
3. phi 浓缩筛选 top 61.8% 方案
4. 兼容性评分 + 复杂度评估
5. 生成方案对比报告，供用户选择

---

## 6. 项目结构

```
agent/
├── build.zig              # 构建配置
├── build.zig.zon          # 包元数据
├── DESIGN.md              # 完整设计文档
├── USAGE.md               # 本文件
├── deps/
│   └── sqlite3/           # SQLite amalgamation
├── data/
│   └── migrations/        # SQL 迁移脚本
└── src/
    ├── main.zig           # 入口 + 自检
    ├── repl.zig           # 交互式 REPL
    ├── math/              # 数学常数模块
    │   ├── constants.zig  # pi, e, phi 定义
    │   ├── pi_ring.zig    # pi 环形缓冲区
    │   ├── e_growth.zig   # e 增长控制
    │   └── phi_condense.zig # phi 知识浓缩
    ├── llm/               # LLM 多模型层
    │   ├── provider.zig   # 统一接口 + vtable
    │   ├── message.zig    # 消息序列化
    │   ├── streaming.zig  # SSE 解析器
    │   ├── openai.zig     # OpenAI 后端
    │   └── ollama.zig     # Ollama 后端
    ├── tools/             # 工具系统
    │   ├── registry.zig   # comptime 注册器
    │   ├── bash.zig       # Shell 执行
    │   ├── file_read.zig  # 文件读取
    │   └── file_write.zig # 文件写入
    ├── task/              # 异步任务
    │   ├── thread_pool.zig
    │   ├── mpsc_queue.zig
    │   ├── event_bus.zig
    │   └── cron.zig
    ├── storage/           # 持久化
    │   ├── database.zig   # SQLite 封装
    │   └── vector.zig     # 向量存储
    ├── memory/            # 记忆系统
    │   ├── types.zig      # 记忆类型定义
    │   ├── working.zig    # 工作记忆
    │   ├── episodic.zig   # 情景记忆
    │   ├── memory.zig     # 记忆协调器
    │   ├── reflection.zig # 反思引擎
    │   └── extraction.zig # 经验提取
    ├── knowledge/         # 知识库
    │   ├── graph.zig      # 知识图谱
    │   └── search.zig     # 网络搜索
    ├── runtime/           # 运行时
    │   ├── decision_trace.zig  # 决策链记录
    │   ├── rules.zig      # 检测规则接口
    │   ├── builtin_rules.zig   # 8 条内置规则
    │   ├── monitor.zig    # 运行时监控器
    │   ├── self_diagnostic.zig # 自诊断引擎
    │   └── error_handler.zig   # 错误反馈
    └── research/
        └── optimization_researcher.zig # 优化研究引擎
```

---

## 7. 当前状态与待完成项

### 已完成
- [x] 数学核心 (pi/e/phi 全部实现+测试)
- [x] comptime 工具系统 (Bash, FileRead, FileWrite)
- [x] 多 LLM 后端框架 (OpenAI, Ollama 完整实现)
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
- [x] REPL 交互界面

### 待完成
- [ ] Claude API 真实 HTTP 调用接入
- [ ] API Key 配置文件加载
- [ ] EpisodicStore 参数化查询 (防 SQL 注入)
- [ ] KnowledgeGraph 参数化查询
- [ ] MPSC Queue pop() 完整实现
- [ ] 工具调用循环 (需 LLM 接入)
- [ ] 高级 REPL (进度展示、错误交互)
- [ ] 跨平台测试

---

## 8. 配置说明

当前版本暂无独立配置文件，相关配置通过代码修改：

### LLM 后端配置

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

### 数据库路径

默认使用当前目录的 `data/ziv.db`。修改 `Database.init()` 的路径参数即可。

### 定时任务间隔

在 `task/cron.zig` 中修改常量：

```zig
pub const REFLECTION_INTERVAL = @intFromFloat(PI * 10.0 * 60.0 * 1000.0); // ~31.4 min
pub const KNOWLEDGE_UPDATE_INTERVAL = @intFromFloat(PHI * 60.0 * 60.0 * 1000.0); // ~37.1 min
pub const MEMORY_DECAY_INTERVAL = @intFromFloat(E * 30.0 * 60.0 * 1000.0); // ~81.5 min
```

### 工作记忆容量

在 `memory/working.zig` 的 `init()` 中修改 `max_entries` 参数（默认 50）。

### 线程池并发上限

由 `e_growth.zig` 的 `effectiveConcurrency()` 自动根据 CPU 核心数计算，使用 logistic 函数限制。
