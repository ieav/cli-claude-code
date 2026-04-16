# Zage — Zig 自学习 Agent 完整实现计划

## Context

用 Zig 构建一个支持多 LLM 后端、具备自动学习能力（记忆+反思+知识库自动更新）的 CLI Agent 工具。新增要求：
- **异步后台并发任务处理**
- **严谨的运行时检测规则**，错误/异常时分析原因并提供解决方案，用户选择如何处理
- **数学常数驱动的核心算法**：π 圆融信息、e 控制增长、φ 浓缩知识

---

## 一、数学常数驱动的核心设计

### 1. π (≈3.14159265358979323846) — 圆融信息

**核心思想：信息循环、轮转、全覆盖**

```
应用场景：
├── 环形记忆缓冲区 (Ring Buffer)
│   └── 用 π 分数旋转索引，确保记忆均匀覆盖
│       index = (base + π_sequence[i]) % capacity
│
├── 向量旋转编码 (RoPE 启发)
│   └── 嵌入向量在存储时做 π/分维度 旋转，增加信息密度
│       rotated[d] = vec[d] * cos(π*d/D) - vec[d+1] * sin(π*d/D)
│
├── 知识图谱周期扫描
│   └── 以 π 为周期定期遍历知识图谱，发现断裂/孤立节点
│       扫描周期 = π × base_interval ≈ 3.14 × 基础间隔
│
└── 经验回放 (Experience Replay)
    └── 按 π-均匀分布采样历史经验用于反思训练
```

**Zig 实现：**
```zig
// src/math/pi_ring.zig
pub fn PiRingBuffer(comptime T: type, comptime capacity: usize) type {
    return struct {
        buffer: [capacity]T,
        head: usize,
        count: usize,
        // π 分数序列用于分散索引，避免聚集
        pi_fracs: [capacity]usize, // 预计算：(π * i / capacity) 的小数部分 × capacity

        const Self = @This();

        pub fn init() Self {
            var buf = Self{
                .buffer = undefined,
                .head = 0,
                .count = 0,
                .pi_fracs = undefined,
            };
            // 用 π 分数生成分散索引
            for (0..capacity) |i| {
                const pi_fraction = @floor(PI * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(capacity)));
                buf.pi_fracs[i] = @intFromFloat(pi_fraction) % capacity;
            }
            return buf;
        }

        pub fn push(self: *Self, item: T) void {
            self.buffer[self.head] = item;
            self.head = (self.head + 1) % capacity;
            if (self.count < capacity) self.count += 1;
        }

        /// 按 π 分散顺序遍历，覆盖更均匀
        pub fn getByPiIndex(self: *Self, logical_index: usize) ?T {
            if (logical_index >= self.count) return null;
            const physical = self.pi_fracs[logical_index];
            return self.buffer[physical];
        }
    };
}
```

### 2. e (≈2.71828182845904523536) — 控制增长极限

**核心思想：自然增长有上限，用 sigmoid/logistic 函数约束一切扩张**

```
应用场景：
├── 资源增长限制
│   └── sigmoid(pressure) = 1/(1 + e^(-pressure)) ∈ (0,1)
│       memory_cap = max_memory × sigmoid(usage_pressure)
│       防止记忆无限膨胀
│
├── 探索-利用衰减
│   └── ε(t) = ε_min + (ε_0 - ε_min) × e^(-k×t)
│       随使用次数增加，探索概率自然衰减
│       新知识获取 vs 已有知识利用的平衡
│
├── 重试退避
│   └── delay = min(base × e^(attempt × ln2), max_delay)
│       等价于指数退避，但以 e 为底更平滑
│
├── 知识衰减
│   └── relevance(t) = initial × e^(-λ × age)
│       知识重要性随时间自然衰减
│       λ 由访问频率动态调整
│
└── 并发任务扩展
    └── max_concurrent = sigmoid(queue_pressure) × hardware_limit
        任务并发数随压力增长但有硬上限
```

**Zig 实现：**
```zig
// src/math/e_growth.zig
pub const E = 2.71828182845904523536;

pub fn sigmoid(x: f64) f64 {
    return 1.0 / (1.0 + @exp(-x));
}

pub fn expDecay(initial: f64, lambda: f64, t: f64) f64 {
    return initial * @exp(-lambda * t);
}

pub fn logisticCap(current: f64, max: f64, growth_rate: f64) f64 {
    // 当 current 接近 max 时，增长自然趋近 0
    const pressure = growth_rate * (current / max - 0.5) * 6.0;
    return max * sigmoid(pressure);
}

pub fn explorationEpsilon(eps_min: f64, eps_0: f64, decay_rate: f64, step: u64) f64 {
    return eps_min + (eps_0 - eps_min) * @exp(-decay_rate * @as(f64, @floatFromInt(step)));
}
```

### 3. φ (≈0.6180339887) — 浓缩知识

**核心思想：用最小信息保留最大价值**

```
应用场景：
├── 知识浓缩比
│   └── 压缩目标 = 原始知识 × φ ≈ 61.8%
│       每次反思循环将知识压缩到原来的 61.8%
│       多次迭代后保留最精华部分
│
├── Fibonacci 哈希
│   └── hash = (key × φ_64) >> (64 - log2(table_size))
│       φ_64 = 11400714819323198549 (64位黄金比)
│       最均匀的哈希分布，用于记忆索引
│
├── 黄金分割搜索
│   └── 用于超参优化（反思频率、记忆容量等）
│       每次排除 φ 比例的搜索空间
│
├── 嵌入维度选择
│   └── 压缩后维度 = 原始维度 × φ
│       例：1536 → 950 维，保留 61.8% 信息量
│
└── 知识图谱剪枝
    └── 边权重 < φ × max_weight 的弱连接被剪除
        保留核心知识结构
```

**Zig 实现：**
```zig
// src/math/phi_condense.zig
pub const PHI: f64 = 0.61803398874989484820;
pub const PHI_64: u64 = 11400714819323198549; // φ × 2^64

/// Fibonacci 哈希 — 最均匀分布
pub fn fibonacciHash(key: u64, table_size_log2: u6) usize {
    return @intCast((key *% PHI_64) >> (64 - table_size_log2));
}

/// 黄金分割搜索 — 找最优值
pub fn goldenSectionSearch(
    f: *const fn (f64) f64,
    a: f64,
    b: f64,
    tolerance: f64,
) f64 {
    const inv_phi = 1.0 / 1.6180339887;
    var lo = a;
    var hi = b;
    var c = hi - inv_phi * (hi - lo);
    var d = lo + inv_phi * (hi - lo);
    while ((hi - lo) > tolerance) {
        if (f(c) < f(d)) {
            hi = d;
        } else {
            lo = c;
        }
        c = hi - inv_phi * (hi - lo);
        d = lo + inv_phi * (hi - lo);
    }
    return (lo + hi) / 2.0;
}

/// 知识浓缩 — 按黄金比压缩
pub fn condensationTarget(original_count: usize) usize {
    return @intFromFloat(@round(@as(f64, @floatFromInt(original_count)) * PHI));
}
```

---

## 二、异步后台并发任务系统

参考 Claude Code 的 Task/BackgroundTask 架构，用 Zig 的 `std.Thread` 实现。

### 架构设计

```
                     ┌─────────────────────┐
                     │    TaskScheduler     │
                     │  (调度器主循环)       │
                     └──────┬──────────────┘
                            │
              ┌─────────────┼─────────────┐
              │             │             │
        ┌─────▼─────┐ ┌───▼──────┐ ┌────▼──────┐
        │ ThreadPool │ │ CronTab  │ │ EventBus  │
        │ (工作线程池)│ │(定时任务) │ │ (事件总线) │
        └─────┬─────┘ └───┬──────┘ └────┬──────┘
              │            │             │
     ┌────────┼────────┐   │     ┌──────┼──────┐
     │        │        │   │     │      │      │
  ┌──▼──┐ ┌──▼──┐ ┌──▼──┐ │  ┌──▼──┐ ┌─▼──┐ ┌▼─────┐
  │Ref- │ │Mem  │ │Know-│ │  │Mem- │ │Ref-│ │Error │
  │lect│ │Ext- │ │ledge│ │  │ory  │ │let │ │Diag- │
  │Task│ │ract │ │Fetch│ │  │Store│ │ion │ │nostic│
  └─────┘ └─────┘ └─────┘ │  └─────┘ └────┘ └──────┘
                           │
                     ┌─────▼──────┐
                     │  TaskQueue │
                     │ (MPSC 队列) │
                     └────────────┘
```

### 核心类型定义

```zig
// src/task/scheduler.zig

pub const TaskPriority = enum(u8) {
    critical = 0,   // 用户查询处理
    high = 1,       // 工具执行
    normal = 2,     // 记忆提取
    low = 3,        // 反思、知识更新
    background = 4, // 维护、清理
};

pub const TaskStatus = enum {
    pending,
    running,
    completed,
    failed,
    cancelled,
};

pub const Task = struct {
    id: [16]u8,              // UUID
    name: []const u8,
    priority: TaskPriority,
    status: std.atomic.Value(TaskStatus),
    progress: std.atomic.Value(f64),  // 0.0 - 1.0
    result: ?TaskResult,
    error_info: ?TaskError,
    created_at: i64,
    started_at: ?i64,
    completed_at: ?i64,
    cancel_token: std.atomic.Value(bool),
    retry_count: u32,
    max_retries: u32,
    execute_fn: *const fn (*Task, *TaskContext) anyerror!TaskResult,
    cleanup_fn: ?*const fn (*Task) void,
};

pub const TaskResult = union(enum) {
    memory_extracted: []const MemoryEntry,
    reflection: Reflection,
    knowledge_updated: UpdateSummary,
    web_search: SearchResult,
    void_result: void,
    error_result: TaskError,
};

pub const TaskError = struct {
    code: ErrorCode,
    message: []const u8,
    cause: ?*const TaskError,
    recoverable: bool,
    suggested_actions: []const SuggestedAction,

    pub const ErrorCode = enum {
        network_timeout,
        api_rate_limit,
        api_auth_error,
        llm_context_overflow,
        storage_full,
        storage_corrupt,
        embedding_failed,
        memory_overflow,
        knowledge_conflict,
        tool_execution_failed,
        internal_error,
    };

    pub const SuggestedAction = struct {
        action_type: enum { retry, reconfigure, clear_cache, reduce_scope, ask_user, auto_fix },
        description: []const u8,
        params: ?std.json.Value,
    };
};

pub const TaskContext = struct {
    allocator: std.mem.Allocator,
    db: *storage.Database,
    provider: llm.Provider,
    memory: *memory.MemorySystem,
    knowledge: *knowledge.KnowledgeGraph,
    event_bus: *EventBus,
};
```

### 线程池实现

```zig
// src/task/thread_pool.zig
pub const ThreadPool = struct {
    allocator: std.mem.Allocator,
    threads: []std.Thread,
    task_queue: MPSCQueue(*Task),  // 多生产者单消费者
    active_count: std.atomic.Value(usize),
    max_concurrent: usize,
    shutdown: std.atomic.Value(bool),
    // e-控制的并发上限
    // max_concurrent = @intFromFloat(logisticCap(current_load, hw_threads, 2.0))

    pub fn init(allocator: std.mem.Allocator, max_threads: usize) !ThreadPool {
        // 读取硬件线程数
        const hw_threads = std.Thread.getCpuCount() catch 4;
        const effective = @min(max_threads, hw_threads);
        // ...
    }

    pub fn submit(self: *ThreadPool, task: *Task) !void {
        try self.task_queue.push(task);
        // 通知工作线程
    }

    pub fn cancel(self: *ThreadPool, task_id: [16]u8) bool {
        // 设置 cancel_token，工作线程在检查点检查
    }

    fn workerLoop(self: *ThreadPool) void {
        while (!self.shutdown.load(.monotonic)) {
            if (self.task_queue.pop()) |task| {
                _ = self.active_count.fetchAdd(1, .monotonic);
                defer _ = self.active_count.fetchSub(1, .monotonic);
                self.executeTask(task) catch |err| {
                    self.handleTaskError(task, err);
                };
            } else {
                // 等待通知或超时
                std.time.sleep(1 * std.time.ns_per_ms);
            }
        }
    }

    fn executeTask(self: *ThreadPool, task: *Task) !void {
        // 1. 检查取消
        if (task.cancel_token.load(.monotonic)) {
            task.status.store(.cancelled, .release);
            return;
        }
        // 2. 执行
        task.status.store(.running, .release);
        task.started_at = std.time.milliTimestamp();
        const result = task.execute_fn(task, self.context) catch |err| {
            task.error_info = TaskError.from(err);
            task.status.store(.failed, .release);
            return err;
        };
        task.result = result;
        task.status.store(.completed, .release);
        task.completed_at = std.time.milliTimestamp();
        // 3. 发送事件
        self.context.event_bus.emit(.task_completed, .{ .task_id = task.id });
    }
};
```

### MPSC 无锁队列

```zig
// src/task/mpsc_queue.zig
pub fn MPSCQueue(comptime T: type) type {
    return struct {
        head: std.atomic.Value(?*Node),
        stub: Node,

        const Node = struct {
            data: T,
            next: std.atomic.Value(?*Node),
        };

        const Self = @This();

        pub fn push(self: *Self, item: T) !void {
            const node = try allocator.create(Node);
            node.* = .{ .data = item, .next = null };
            const prev = self.head.swap(node, .acq_rel);
            prev.?.next.store(node, .release);
        }

        pub fn pop(self: *Self) ?T {
            const tail = &self.stub;
            var next = tail.next.load(.acquire);
            if (next == null) return null;
            const data = next.?.data;
            tail.next = next.?.next.load(.acquire);
            // ... 回收 node
            return data;
        }
    };
}
```

### 事件总线

```zig
// src/task/event_bus.zig
pub const EventType = enum {
    task_completed,
    task_failed,
    memory_updated,
    knowledge_updated,
    reflection_produced,
    error_detected,
    resource_warning,
    user_query_start,
    user_query_end,
};

pub const Event = struct {
    event_type: EventType,
    timestamp: i64,
    payload: union(EventType) {
        task_completed: struct { task_id: [16]u8, duration_ms: i64 },
        task_failed: struct { task_id: [16]u8, error: TaskError },
        memory_updated: struct { count: usize },
        knowledge_updated: struct { nodes_added: usize, edges_added: usize },
        reflection_produced: struct { insights_count: usize },
        error_detected: TaskError,
        resource_warning: struct { resource: []const u8, usage_pct: f64 },
        user_query_start: void,
        user_query_end: struct { duration_ms: i64, tool_calls: u32 },
    },
};

pub const EventHandler = *const fn (Event) anyerror!void;

pub const EventBus = struct {
    handlers: std.HashMap(EventType, std.ArrayList(EventHandler), ...),
    event_log: PiRingBuffer(Event, 1024),  // π 环形缓冲存储最近事件

    pub fn subscribe(self: *EventBus, event_type: EventType, handler: EventHandler) !void;
    pub fn emit(self: *EventBus, event_type: EventType, payload: anytype) void;
    pub fn getRecentEvents(self: *EventBus, count: usize) []const Event;
};
```

### 定时任务 (Cron)

```zig
// src/task/cron.zig
pub const CronScheduler = struct {
    allocator: std.mem.Allocator,
    tasks: std.ArrayList(ScheduledTask),
    thread: ?std.Thread,
    running: std.atomic.Value(bool),

    const ScheduledTask = struct {
        name: []const u8,
        interval_ms: u64,
        jitter_pct: f64,          // 防止 :00 峰值
        last_run: std.atomic.Value(i64),
        task_fn: *const fn (*TaskContext) anyerror!void,
        enabled: std.atomic.Value(bool),
    };

    // 内置定时任务：
    // 1. 反思任务：每 π × 10 分钟 ≈ 31.4 分钟
    // 2. 知识更新：每 φ × 60 分钟 ≈ 37.1 分钟
    // 3. 记忆衰减：每 e × 30 分钟 ≈ 81.5 分钟
    // 4. 健康检查：每 60 秒
    // 5. 资源监控：每 30 秒
};
```

---

## 三、运行时检测规则

### 检测规则系统

```zig
// src/runtime/rules.zig

pub const RuleSeverity = enum {
    info,
    warning,
    error,
    critical,
};

pub const RuntimeRule = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    severity: RuleSeverity,
    check_fn: *const fn (*RuntimeContext) CheckResult,
    auto_fix_fn: ?*const fn (*RuntimeContext) anyerror!FixResult,
};

pub const CheckResult = union(enum) {
    pass: void,
    fail: struct {
        message: []const u8,
        metric_current: f64,
        metric_threshold: f64,
        suggested_fixes: []const SuggestedFix,
    },
};

pub const SuggestedFix = struct {
    description: []const u8,
    action_type: enum {
        adjust_parameter,
        clear_data,
        restart_service,
        upgrade_dependency,
        user_input_needed,
        auto_fixable,
    },
    auto_fixable: bool,
    fix_params: ?std.json.Value,
};
```

### 内置检测规则

```zig
// src/runtime/builtin_rules.zig

pub const builtin_rules = [_]RuntimeRule{
    // ===== 资源检测 =====
    .{
        .id = "mem_usage_high",
        .name = "内存使用过高",
        .check_fn = struct {
            fn check(ctx: *RuntimeContext) CheckResult {
                const usage = ctx.memory_stats.used_bytes;
                const limit = ctx.memory_stats.limit_bytes;
                const ratio = @as(f64, @floatFromInt(usage)) / @as(f64, @floatFromInt(limit));
                // e 控制阈值：sigmoid(2*(ratio-0.7)) 快速报警
                const pressure = sigmoid(2.0 * (ratio - 0.7));
                if (pressure > 0.8) {
                    const target = condensationTarget(ctx.memory_stats.entry_count);
                    return .{
                        .fail = .{
                            .message = "内存使用率超过阈值",
                            .metric_current = ratio,
                            .metric_threshold = 0.8,
                            .suggested_fixes = &.{
                                .{ .description = "浓缩记忆（φ 压缩）", .action_type = .auto_fixable, .auto_fixable = true },
                                .{ .description = "清理过期记忆", .action_type = .auto_fixable, .auto_fixable = true },
                                .{ .description = "用户手动选择保留/删除", .action_type = .user_input_needed, .auto_fixable = false },
                            },
                        },
                    };
                }
                return .pass;
            }
        }.check,
    },

    // ===== API 检测 =====
    .{
        .id = "api_rate_limit",
        .name = "API 速率限制",
        .check_fn = struct {
            fn check(ctx: *RuntimeContext) CheckResult {
                const recent_calls = ctx.api_stats.calls_last_minute;
                const limit = ctx.api_stats.rate_limit;
                if (recent_calls > limit * 0.8) {
                    return .{
                        .fail = .{
                            .message = "API 调用接近速率限制",
                            .metric_current = @floatFromInt(recent_calls),
                            .metric_threshold = @floatFromInt(limit) * 0.8,
                            .suggested_fixes = &.{
                                .{ .description = "降低后台任务频率", .action_type = .auto_fixable, .auto_fixable = true },
                                .{ .description = "切换到本地模型", .action_type = .adjust_parameter, .auto_fixable = false },
                                .{ .description = "暂停非关键后台任务", .action_type = .auto_fixable, .auto_fixable = true },
                            },
                        },
                    };
                }
                return .pass;
            }
        }.check,
    },

    // ===== 存储检测 =====
    .{
        .id = "storage_corruption",
        .name = "存储完整性",
        .check_fn = struct {
            fn check(ctx: *RuntimeContext) CheckResult {
                const integrity = ctx.db.checkIntegrity() catch {
                    return .{
                        .fail = .{
                            .message = "SQLite 完整性检查失败",
                            .metric_current = 0,
                            .metric_threshold = 1,
                            .suggested_fixes = &.{
                                .{ .description = "自动修复数据库", .action_type = .auto_fixable, .auto_fixable = true },
                                .{ .description = "从备份恢复", .action_type = .user_input_needed, .auto_fixable = false },
                                .{ .description = "重建数据库（丢失历史）", .action_type = .user_input_needed, .auto_fixable = false },
                            },
                        },
                    };
                };
                if (!integrity) return .{ .fail = .{ ... } };
                return .pass;
            }
        }.check,
    },

    // ===== 上下文窗口检测 =====
    .{
        .id = "context_overflow",
        .name = "上下文窗口溢出",
        .check_fn = struct {
            fn check(ctx: *RuntimeContext) CheckResult {
                const token_usage = ctx.session_stats.current_tokens;
                const max_tokens = ctx.session_stats.max_tokens;
                const ratio = @as(f64, @floatFromInt(token_usage)) / @as(f64, @floatFromInt(max_tokens));
                if (ratio > PHI) { // φ 阈值：使用超过 61.8% 时预警
                    return .{
                        .fail = .{
                            .message = "上下文窗口接近上限",
                            .metric_current = ratio,
                            .metric_threshold = PHI,
                            .suggested_fixes = &.{
                                .{ .description = "自动摘要压缩对话", .action_type = .auto_fixable, .auto_fixable = true },
                                .{ .description = "φ 浓缩：保留 61.8% 最重要内容", .action_type = .auto_fixable, .auto_fixable = true },
                                .{ .description = "开始新会话（保留记忆）", .action_type = .user_input_needed, .auto_fixable = false },
                            },
                        },
                    };
                }
                return .pass;
            }
        }.check,
    },

    // ===== 知识一致性 =====
    .{
        .id = "knowledge_conflict",
        .name = "知识冲突检测",
        .check_fn = struct {
            fn check(ctx: *RuntimeContext) CheckResult {
                const conflicts = ctx.knowledge_stats.recent_conflicts;
                if (conflicts > 0) {
                    return .{
                        .fail = .{
                            .message = "发现知识冲突",
                            .metric_current = @floatFromInt(conflicts),
                            .metric_threshold = 0,
                            .suggested_fixes = &.{
                                .{ .description = "展示冲突详情，用户选择保留哪个", .action_type = .user_input_needed, .auto_fixable = false },
                                .{ .description = "自动合并（保留两者，标注来源）", .action_type = .auto_fixable, .auto_fixable = true },
                                .{ .description = "搜索网络验证最新信息", .action_type = .auto_fixable, .auto_fixable = true },
                            },
                        },
                    };
                }
                return .pass;
            }
        }.check,
    },

    // ===== 后台任务健康 =====
    .{
        .id = "task_health",
        .name = "后台任务健康",
        .check_fn = struct {
            fn check(ctx: *RuntimeContext) CheckResult {
                const failed = ctx.task_stats.failed_count;
                const total = ctx.task_stats.total_count;
                if (total > 0) {
                    const fail_rate = @as(f64, @floatFromInt(failed)) / @as(f64, @floatFromInt(total));
                    if (fail_rate > 1.0 - PHI) { // 失败率 > 38.2%
                        return .{
                            .fail = .{
                                .message = "后台任务失败率过高",
                                .metric_current = fail_rate,
                                .metric_threshold = 1.0 - PHI,
                                .suggested_fixes = &.{
                                    .{ .description = "查看失败任务详情", .action_type = .user_input_needed, .auto_fixable = false },
                                    .{ .description = "降低并发数（e 限制）", .action_type = .auto_fixable, .auto_fixable = true },
                                    .{ .description = "增加重试次数", .action_type = .adjust_parameter, .auto_fixable = false },
                                },
                            },
                        };
                    }
                }
                return .pass;
            }
        }.check,
    },

    // ===== 网络连通性 =====
    .{
        .id = "network_connectivity",
        .name = "网络连通性",
        .check_fn = struct {
            fn check(ctx: *RuntimeContext) CheckResult {
                const latency = ctx.network_stats.last_latency_ms;
                const timeout_count = ctx.network_stats.recent_timeouts;
                if (timeout_count > 3) {
                    return .{
                        .fail = .{
                            .message = "网络不稳定，多次超时",
                            .metric_current = @floatFromInt(timeout_count),
                            .metric_threshold = 3,
                            .suggested_fixes = &.{
                                .{ .description = "切换到本地模型（Ollama）", .action_type = .adjust_parameter, .auto_fixable = false },
                                .{ .description = "增加超时时间", .action_type = .adjust_parameter, .auto_fixable = false },
                                .{ .description = "启用离线模式（仅使用缓存记忆）", .action_type = .auto_fixable, .auto_fixable = true },
                            },
                        },
                    };
                }
                return .pass;
            }
        }.check,
    },
};
```

### 运行时监控器

```zig
// src/runtime/monitor.zig
pub const RuntimeMonitor = struct {
    allocator: std.mem.Allocator,
    rules: []const RuntimeRule,
    context: RuntimeContext,
    event_bus: *EventBus,
    check_interval_ms: u64,
    thread: ?std.Thread,
    running: std.atomic.Value(bool),

    pub fn start(self: *RuntimeMonitor) !void {
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, monitorLoop, .{self});
    }

    fn monitorLoop(self: *RuntimeMonitor) void {
        while (self.running.load(.monotonic)) {
            var failures = std.ArrayList(CheckResult.Fail).init(self.allocator);
            defer failures.deinit();

            for (self.rules) |rule| {
                const result = rule.check_fn(&self.context);
                switch (result) {
                    .pass => {},
                    .fail => |info| {
                        // 1. 发送事件
                        self.event_bus.emit(.error_detected, .{
                            .rule_id = rule.id,
                            .severity = rule.severity,
                            .message = info.message,
                        });

                        // 2. 尝试自动修复
                        if (rule.auto_fix_fn) |fix_fn| {
                            if (info.suggested_fixes.len > 0) {
                                for (info.suggested_fixes) |fix| {
                                    if (fix.auto_fixable) {
                                        const fix_result = fix_fn(&self.context) catch continue;
                                        self.event_bus.emit(.resource_warning, .{
                                            .resource = rule.name,
                                            .usage_pct = 0,
                                        });
                                        break;
                                    }
                                }
                            }
                        }

                        // 3. 需要用户介入的 → 通过 EventBus 通知 REPL
                        try failures.append(info);
                    },
                }
            }

            // 如果有需要用户介入的问题，通过 event_bus 发给 REPL
            if (failures.items.len > 0) {
                self.event_bus.emit(.user_intervention_needed, .{
                    .issues = failures.items,
                });
            }

            std.time.sleep(self.check_interval_ms * std.time.ns_per_ms);
        }
    }
};
```

---

## 四、错误处理与用户反馈

### 错误反馈流程

```
错误发生
  │
  ├── 分类（ErrorCode）
  │     ├── 可恢复（网络超时、速率限制）→ 自动重试（e 指数退避）
  │     ├── 可自修复（内存过高、上下文溢出）→ 自动修复（φ 浓缩）
  │     └── 需用户介入 → 进入反馈流程
  │
  ├── 分析原因
  │     ├── 搜索本地知识库
  │     └── 搜索网络（可选）
  │
  ├── 生成报告
  │     ├── 错误描述（用户可理解的语言）
  │     ├── 根因分析
  │     └── 解决方案列表（1-4个选项）
  │
  └── 用户选择
        ├── 选项1（推荐）→ 执行
        ├── 选项2 → 执行
        ├── 选项3 → 执行
        └── 自定义输入 → 灵活处理
```

### REPL 中的错误反馈交互

```zig
// src/repl/error_handler.zig

pub fn handleTaskError(repl: *Repl, task: *Task, err: TaskError) !void {
    // 1. 打印错误信息（带颜色）
    repl.printErrorBanner(err.code, err.message);

    // 2. 分析原因
    const analysis = analyzeError(repl, &err);

    // 3. 展示分析结果
    repl.printAnalysis(analysis);

    // 4. 展示解决方案选项
    const options = mergeOptions(err.suggested_actions, analysis.suggested_actions);

    // 5. 让用户选择
    const choice = repl.promptChoice(
        "如何处理？",
        options,
        .{ .allow_custom = true, .allow_skip = true },
    );

    // 6. 执行用户选择
    switch (choice) {
        .option_0 => try repl.executeAutoFix(options[0]),
        .option_1 => try repl.executeAutoFix(options[1]),
        .custom => |input| try repl.executeCustomFix(input),
        .skip => {}, // 用户跳过
    }
}

fn analyzeError(repl: *Repl, err: *const TaskError) ErrorAnalysis {
    var analysis = ErrorAnalysis{
        .root_cause = "未知",
        .similar_past = &.{},
        .suggested_actions = &.{},
    };

    // 搜索历史记忆中相似错误
    const similar = repl.memory.retrieve(err.message, 3) catch &.{};
    analysis.similar_past = similar;

    // 如果有历史记录，参考之前的解决方案
    if (similar.len > 0) {
        analysis.root_cause = "之前遇到过类似问题";
        analysis.suggested_actions = extractPreviousFixes(similar);
    }

    // 对常见错误给出具体分析
    switch (err.code) {
        .api_rate_limit => {
            analysis.root_cause = "API 调用频率超过限制";
        },
        .llm_context_overflow => {
            analysis.root_cause = "对话内容超过模型上下文窗口";
        },
        .network_timeout => {
            analysis.root_cause = "网络连接超时，可能是网络不稳定或服务端过载";
        },
        else => {},
    }

    return analysis;
}
```

### 错误输出示例

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 ⚠  错误：API 速率限制
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Claude API 调用已达速率上限（60次/分钟）

 📊 分析：
   · 当前调用：52次/分钟
   · 限制：60次/分钟
   · 后台任务占用：38次/分钟

 💡 历史经验：
   · 上次遇到此问题时，暂停后台任务解决了

 🔧 如何处理？
   [1] 暂停非关键后台任务（推荐）
       → 自动暂停反思和知识更新任务
   [2] 切换到本地模型 (Ollama)
       → 需要已安装 Ollama
   [3] 降低后台任务频率
       → 当前 30s/次 → 调整为 60s/次
   [4] 自定义...

 输入选择 (1-4): _
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 五、更新后的项目结构

```
zage/
├── build.zig / build.zig.zon
├── src/
│   ├── main.zig
│   ├── repl.zig
│   ├── config.zig
│   │
│   ├── math/                          # 数学常数模块
│   │   ├── constants.zig              # π, e, φ 常量定义
│   │   ├── pi_ring.zig                # π 环形缓冲区
│   │   ├── e_growth.zig               # e 增长控制 (sigmoid, decay)
│   │   └── phi_condense.zig           # φ 知识浓缩 (Fibonacci hash, golden search)
│   │
│   ├── llm/                           # LLM 多模型层
│   │   ├── provider.zig / claude.zig / openai.zig / ollama.zig
│   │   ├── message.zig / streaming.zig / tool_call.zig / token.zig
│   │
│   ├── memory/                        # 三层记忆系统
│   │   ├── memory.zig / working.zig / episodic.zig / semantic.zig
│   │   ├── reflection.zig / extraction.zig / types.zig
│   │
│   ├── knowledge/                     # 知识库
│   │   ├── graph.zig / search.zig / extractor.zig / updater.zig
│   │
│   ├── embedding/                     # 向量嵌入
│   │   ├── embedder.zig / api_embedder.zig / local_embedder.zig / store.zig
│   │
│   ├── tools/                         # 工具系统
│   │   ├── registry.zig / bash.zig / file_read.zig / file_write.zig
│   │   ├── file_edit.zig / glob.zig / grep.zig
│   │   ├── web_search.zig / web_fetch.zig / memory_tool.zig
│   │
│   ├── task/                          # 异步任务系统 [新增]
│   │   ├── scheduler.zig              # 任务调度器
│   │   ├── thread_pool.zig            # 线程池
│   │   ├── mpsc_queue.zig             # 无锁 MPSC 队列
│   │   ├── event_bus.zig              # 事件总线
│   │   ├── cron.zig                   # 定时任务
│   │   └── task_types.zig             # 任务类型定义
│   │
│   ├── runtime/                       # 运行时检测 [新增]
│   │   ├── monitor.zig                # 运行时监控器
│   │   ├── rules.zig                  # 检测规则接口
│   │   ├── builtin_rules.zig          # 内置检测规则
│   │   ├── diagnostics.zig            # 诊断信息收集
│   │   └── fix_engine.zig             # 自动修复引擎
│   │
│   ├── repl/                          # REPL 增强 [新增]
│   │   ├── error_handler.zig          # 错误反馈交互
│   │   ├── progress_reporter.zig      # 后台任务进度展示
│   │   └── choice_prompt.zig          # 用户选择提示器
│   │
│   ├── storage/
│   │   ├── database.zig / vector.zig / migrations.zig / json_store.zig
│   │
│   ├── http/
│   │   ├── client.zig / sse.zig / tls.zig
│   │
│   ├── cli/
│   │   ├── args.zig / terminal.zig / prompt.zig / output.zig / spinner.zig
│   │
│   └── util/
│       ├── arena.zig / json_helpers.zig / hash.zig / time.zig / uuid.zig
│
├── data/
│   ├── migrations/                    # SQL 迁移
│   │   ├── 001_init.sql
│   │   ├── 002_vectors.sql
│   │   ├── 003_knowledge.sql
│   │   ├── 004_memories.sql
│   │   └── 005_runtime_rules.sql      # 运行时规则存储
│   └── prompts/
│       ├── system.md
│       ├── reflection.md
│       ├── extraction.md
│       └── error_analysis.md          # 错误分析提示词
│
└── deps/
    └── sqlite3/
```

---

## 六、更新后的分阶段实施

### Phase 1: 基础 + 数学核心（1-2 周）
- 项目骨架、build.zig、SQLite
- **数学模块**：`constants.zig`, `pi_ring.zig`, `e_growth.zig`, `phi_condense.zig`
- Claude API 流式调用 + SSE
- 基础 REPL

### Phase 2: 工具系统（1 周）
- comptime ToolRegistry
- Bash、FileRead、FileWrite

### Phase 3: 异步任务系统（1-2 周）[新增]
- MPSC 无锁队列
- 线程池（e 控制并发上限）
- 事件总线（π 环形缓冲）
- 定时任务（π/φ/e 周期）

### Phase 4: 持久化 + 记忆（1-2 周）
- SQLite 存储对话历史
- 三层记忆系统
- 向量存储 + 余弦相似度

### Phase 5: 运行时检测 + 错误反馈（1-2 周）[新增]
- 检测规则框架
- 内置规则（7条）
- 错误分析 + 用户选择交互
- 自动修复引擎

### Phase 6: 反思 + 知识浓缩（1-2 周）
- 反思引擎（π 周期触发）
- 经验提取
- φ 知识浓缩算法
- e 控制知识衰减

### Phase 7: 多模型 + 网络搜索（1 周）
- OpenAI / Ollama 后端
- 网络搜索 + 知识图谱

### Phase 8: 打磨（1-2 周）
- 高级 REPL、更多工具
- 跨平台测试
- 性能优化

---

## 七、自诊断引擎 — 用户质疑时排查自身逻辑

### 核心思想

当用户说"为什么这样做"、"这个结果不对"、"你漏了什么"时，agent 不是简单重新执行，而是**回溯自身决策链**，逐步排查哪一步有欠缺，然后把分析结果反馈给用户。

### 决策链记录 (Decision Trace)

每次用户查询的处理过程中，agent 记录完整的决策链：

```zig
// src/runtime/decision_trace.zig

pub const DecisionStep = struct {
    step_id: u32,
    phase: DecisionPhase,
    timestamp: i64,
    input: []const u8,           // 这一步的输入
    output: []const u8,          // 这一步的输出
    reasoning: []const u8,       // 为什么做这个决定
    confidence: f64,             // 置信度 0-1
    duration_ms: i64,
    alternatives: []const Alternative,  // 被排除的其他选项
    dependencies: []const u32,   // 依赖的上游步骤 ID
};

pub const DecisionPhase = enum {
    memory_retrieval,    // 记忆检索阶段
    context_assembly,    // 上下文组装阶段
    tool_selection,      // 工具选择阶段
    tool_execution,      // 工具执行阶段
    llm_generation,      // LLM 生成阶段
    response_postprocess,// 响应后处理阶段
    reflection_trigger,  // 反思触发阶段
};

pub const Alternative = struct {
    description: []const u8,
    why_excluded: []const u8,
};

pub const DecisionTrace = struct {
    allocator: std.mem.Allocator,
    query: []const u8,
    steps: std.ArrayList(DecisionStep),
    started_at: i64,
    completed_at: ?i64,

    pub fn addStep(self: *DecisionTrace, step: DecisionStep) !void;
    pub fn getFullChain(self: *DecisionTrace) []const DecisionStep;
    pub fn getStepByPhase(self: *DecisionTrace, phase: DecisionPhase) ?*DecisionStep;

    /// 回溯分析：从最终结果逆向检查每个环节
    pub fn diagnose(self: *DecisionTrace, user_concern: []const u8) !DiagnosisReport;
};
```

### 诊断流程

```
用户提出质疑："为什么没考虑到 X？"
  │
  ├── 1. 接收质疑，记录到 DecisionTrace
  │
  ├── 2. 回溯决策链
  │     ├── Phase: memory_retrieval
  │     │   └── "检索到的记忆是否包含 X 相关信息？"
  │     │       ├── 是 → 为什么没用到？→ 检查 context_assembly
  │     │       └── 否 → 为什么没检索到？
  │     │           ├── 嵌入向量偏差？→ 检查 embedding
  │     │           ├── 知识库缺失？→ 检查 knowledge
  │     │           └── 查询理解偏差？→ 检查 llm_generation
  │     │
  │     ├── Phase: context_assembly
  │     │   └── "system prompt 中是否注入了相关信息？"
  │     │
  │     ├── Phase: tool_selection
  │     │   └── "是否选择了正确的工具？"
  │     │
  │     ├── Phase: tool_execution
  │     │   └── "工具执行结果是否正确？"
  │     │
  │     └── Phase: llm_generation
  │         └── "LLM 回答是否利用了所有上下文？"
  │
  ├── 3. 定位薄弱环节
  │     ├── 找到 confidence 最低的步骤
  │     ├── 找到被排除但可能更优的 Alternative
  │     └── 检查每一步的 input/output 是否有信息丢失
  │
  ├── 4. 生成诊断报告
  │     ├── 问题定位（哪一步出了问题）
  │     ├── 原因分析（为什么出错）
  │     ├── 影响范围（后续哪些步骤受影响）
  │     └── 改进建议（下次如何避免）
  │
  └── 5. 反馈用户 + 学习
        ├── 展示诊断报告
        ├── 将此案例存入反思记忆
        └── 更新后续行为的策略权重
```

### Zig 实现

```zig
// src/runtime/self_diagnostic.zig

pub const DiagnosisReport = struct {
    user_concern: []const u8,
    identified_gaps: []const LogicGap,
    root_cause: ?*const LogicGap,
    improvement_suggestions: []const ImprovementSuggestion,
    trace_summary: TraceSummary,
};

pub const LogicGap = struct {
    step_id: u32,
    phase: DecisionPhase,
    gap_type: GapType,
    description: []const u8,        // 用户可理解的语言
    technical_detail: []const u8,   // 技术细节
    severity: f64,                  // 0-1, φ 阈值过滤

    pub const GapType = enum {
        missing_information,   // 缺少关键信息
        wrong_decision,        // 做了错误的选择
        skipped_step,          // 跳过了必要步骤
        insufficient_depth,    // 分析不够深入
        context_lost,          // 上下文信息丢失
        tool_misuse,           // 工具使用不当
        memory_miss,           // 记忆检索遗漏
    };
};

pub const ImprovementSuggestion = struct {
    for_phase: DecisionPhase,
    suggestion: []const u8,
    auto_applicable: bool,          // 能否自动应用
    impact_score: f64,              // 预计影响程度
};

pub const SelfDiagnostic = struct {
    allocator: std.mem.Allocator,
    provider: llm.Provider,
    memory: *memory.MemorySystem,
    knowledge: *knowledge.KnowledgeGraph,

    /// 核心方法：用户质疑 → 诊断 → 反馈
    pub fn diagnose(
        self: *SelfDiagnostic,
        trace: *DecisionTrace,
        user_concern: []const u8,
    ) !DiagnosisReport {
        var gaps = std.ArrayList(LogicGap).init(self.allocator);

        // Step 1: 逐步回溯，检查每个阶段
        for (trace.steps.items) |step| {
            const gap = self.analyzeStep(step, user_concern) catch |err| {
                // 单步分析失败不影响整体诊断
                _ = err;
                continue;
            };
            if (gap) |g| {
                try gaps.append(g);
            }
        }

        // Step 2: 找到根因（severity 最高的 gap）
        var root_cause: ?*const LogicGap = null;
        var max_severity: f64 = 0;
        for (gaps.items) |*g| {
            if (g.severity > max_severity) {
                max_severity = g.severity;
                root_cause = g;
            }
        }

        // Step 3: 用 LLM 做深度分析（如果自动分析不够）
        var suggestions = std.ArrayList(ImprovementSuggestion).init(self.allocator);
        if (gaps.items.len > 0) {
            const llm_analysis = try self.deepAnalyzeWithLLM(trace, gaps.items, user_concern);
            defer self.allocator.free(llm_analysis);
            // 解析 LLM 返回的改进建议...
            try suggestions.append(.{
                .for_phase = root_cause.?.phase,
                .suggestion = llm_analysis,
                .auto_applicable = false,
                .impact_score = 0.8,
            });
        }

        // Step 4: 构建报告
        return DiagnosisReport{
            .user_concern = user_concern,
            .identified_gaps = gaps.items,
            .root_cause = root_cause,
            .improvement_suggestions = suggestions.items,
            .trace_summary = self.summarizeTrace(trace),
        };
    }

    fn analyzeStep(self: *SelfDiagnostic, step: DecisionStep, concern: []const u8) !?LogicGap {
        _ = self;
        // 检查标准：
        // 1. 置信度低于 φ 阈值 → 可能有遗漏
        if (step.confidence < PHI) {
            return LogicGap{
                .step_id = step.step_id,
                .phase = step.phase,
                .gap_type = .insufficient_depth,
                .description = "此步骤置信度偏低",
                .technical_detail = step.reasoning,
                .severity = 1.0 - step.confidence,
            };
        }
        // 2. 输出中缺少用户关注的关键信息
        // 3. 被排除的替代方案可能更优
        // ... 更多检查规则
        return null;
    }

    /// 将诊断结果存入反思记忆，改善未来行为
    pub fn learnFromDiagnosis(
        self: *SelfDiagnostic,
        report: *const DiagnosisReport,
    ) !void {
        // 存入反思记忆
        try self.memory.store(.{
            .mem_type = .feedback,
            .name = "self_diagnostic",
            .content = try self.formatDiagnosisForMemory(report),
        });
    }
};
```

### REPL 中的诊断交互示例

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 🔍 自诊断报告
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 您的疑问："为什么没有考虑到并发安全性？"

 📋 决策链回溯（6步）：
   [1] memory_retrieval  ✓ 检索到 3 条相关记忆
   [2] context_assembly  ⚠ 置信度 0.52（低于 φ=0.618）
       → 原因：检索到的记忆未包含并发相关内容
       → 被排除的选项："搜索项目中的锁/互斥使用模式"
   [3] tool_selection    ✓ 选择了 Bash 工具
   [4] tool_execution    ✓ 执行成功
   [5] llm_generation    ⚠ LLM 未提及并发安全
       → 原因：上下文中缺少并发相关信息
   [6] post_process      ✓ 正常完成

 🎯 根因定位：
   Phase 2 (context_assembly) — 信息不完整
   · 检索记忆时遗漏了并发安全相关条目
   · 排除了本应执行的代码搜索步骤

 💡 改进建议：
   [1] 下次遇到类似问题时，自动执行代码模式搜索（自动应用）
   [2] 在记忆中加入并发安全相关知识（需要您确认）
   [3] 增加工具调用前的自动检查（自动应用）

 选择操作：
   [A] 接受所有改进建议
   [B] 选择性应用
   [C] 让我说明更多细节
   [D] 跳过

 输入选择: _
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 八、自主优化研究 — 上网学习最优方案

### 核心思想

当用户说"优化一下"、"添加 XX 功能"、"有没有更好的方案"时，agent 不是仅凭自身知识回答，而是**主动上网搜索当前世界的最优解**，然后和用户沟通确认。

### 优化研究工作流

```
用户提出优化/添加需求
  │
  ├── 1. 理解需求
  │     ├── 解析用户意图（优化什么？添加什么？）
  │     ├── 检查本地知识库是否有相关方案
  │     └── 评估自身现有能力的差距
  │
  ├── 2. 制定研究计划
  │     ├── 生成搜索关键词
  │     ├── 确定搜索范围（论文、GitHub、博客、文档）
  │     └── 使用 φ 分配搜索优先级（先搜最重要的方向）
  │
  ├── 3. 执行网络搜索（后台并发）
  │     ├── 并行搜索多个关键词
  │     ├── 抓取相关页面内容
  │     ├── 提取关键信息和方案
  │     └── e 控制搜索深度（防止无限扩展）
  │
  ├── 4. 整合分析
  │     ├── 比较各方案的优劣
  │     ├── φ 浓缩：筛选出 top-φ 比例的最优方案
  │     ├── 评估与现有系统的兼容性
  │     └── 生成方案对比报告
  │
  ├── 5. 与用户沟通
  │     ├── 展示当前世界最优方案
  │     ├── 说明每个方案的优缺点
  │     ├── 给出推荐（附理由）
  │     └── 用户选择 → 执行
  │
  └── 6. 学习存储
        ├── 将选中的方案存入知识图谱
        ├── 被拒绝的方案也记录（避免重复搜索）
        └── 更新相关记忆权重
```

### Zig 实现

```zig
// src/research/optimization_researcher.zig

pub const ResearchRequest = struct {
    user_query: []const u8,           // 原始用户请求
    intent: ResearchIntent,
    scope: ResearchScope,
    max_search_depth: u32,            // e 控制的搜索深度上限
    time_budget_ms: u64,              // 搜索时间预算

    pub const ResearchIntent = enum {
        optimize_existing,             // 优化现有功能
        add_new_feature,              // 添加新功能
        find_best_practice,           // 寻找最佳实践
        compare_approaches,           // 比较不同方案
        solve_problem,                // 解决特定问题
    };

    pub const ResearchScope = enum {
        academic_papers,               // 论文 (arXiv, etc.)
        open_source_projects,          // 开源项目 (GitHub)
        technical_blogs,               // 技术博客
        documentation,                 // 官方文档
        all,                           // 全部
    };
};

pub const ResearchResult = struct {
    query: []const u8,
    sources_searched: u32,
    candidates_found: u32,
    top_solutions: []const Solution,
    recommendation: *const Solution,
    reasoning: []const u8,
    search_duration_ms: i64,
};

pub const Solution = struct {
    id: u32,
    name: []const u8,
    source_url: []const u8,
    source_type: enum { paper, github, blog, docs, community },
    description: []const u8,
    pros: []const []const u8,
    cons: []const []const u8,
    compatibility_score: f64,         // 与现有系统的兼容性 0-1
    complexity: enum { low, medium, high },
    references: []const []const u8,
};

pub const OptimizationResearcher = struct {
    allocator: std.mem.Allocator,
    provider: llm.Provider,
    memory: *memory.MemorySystem,
    knowledge: *knowledge.KnowledgeGraph,
    web_search: *knowledge.WebSearch,
    thread_pool: *task.ThreadPool,

    /// 核心入口：用户需求 → 网络研究 → 方案推荐
    pub fn research(
        self: *OptimizationResearcher,
        request: ResearchRequest,
    ) !ResearchResult {
        // 1. 先检查本地知识库
        const local_knowledge = try self.knowledge.search(request.user_query, 5);
        defer self.allocator.free(local_knowledge);

        // 2. 用 LLM 生成搜索关键词
        const search_queries = try self.generateSearchQueries(request, local_knowledge);
        defer {
            for (search_queries) |q| self.allocator.free(q);
            self.allocator.free(search_queries);
        }

        // 3. 并发搜索（后台线程池）
        var search_tasks = std.ArrayList(*task.Task).init(self.allocator);
        for (search_queries) |query| {
            const search_task = try self.createSearchTask(query, request.scope);
            try self.thread_pool.submit(search_task);
            try search_tasks.append(search_task);
        }

        // 4. 等待所有搜索完成（e 控制超时）
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(request.time_budget_ms));
        for (search_tasks.items) |t| {
            while (t.status.load(.monotonic) == .running) {
                if (std.time.milliTimestamp() > deadline) {
                    t.cancel_token.store(true, .release);
                    break;
                }
                std.time.sleep(10 * std.time.ns_per_ms);
            }
        }

        // 5. 收集搜索结果
        var all_results = std.ArrayList(SearchResult).init(self.allocator);
        for (search_tasks.items) |t| {
            if (t.result) |r| {
                if (r == .web_search) {
                    try all_results.appendSlice(r.web_search);
                }
            }
        }

        // 6. φ 浓缩：筛选 top 方案
        const candidates = all_results.items;
        const top_count = condensationTarget(candidates.len);
        const top_solutions = try self.rankAndSelect(candidates, top_count);

        // 7. 用 LLM 生成对比分析和推荐
        const analysis = try self.analyzeSolutions(request, top_solutions);

        // 8. 构建结果
        return ResearchResult{
            .query = request.user_query,
            .sources_searched = @intCast(search_queries.len),
            .candidates_found = @intCast(candidates.len),
            .top_solutions = top_solutions,
            .recommendation = &top_solutions[0],
            .reasoning = analysis,
            .search_duration_ms = std.time.milliTimestamp() - deadline + @as(i64, @intCast(request.time_budget_ms)),
        };
    }

    /// 展示研究结果并与用户沟通
    pub fn presentToUser(
        self: *OptimizationResearcher,
        result: *const ResearchResult,
        repl: *Repl,
    ) !void {
        // 1. 展示概要
        try repl.printResearchSummary(result);

        // 2. 展示每个方案的优缺点
        for (result.top_solutions, 0..) |solution, i| {
            try repl.printSolution(@intCast(i + 1), &solution);
        }

        // 3. 展示推荐及理由
        try repl.printRecommendation(result.recommendation, result.reasoning);

        // 4. 让用户选择
        const choice = try repl.promptChoice(
            "选择要采用的方案",
            self.buildChoiceOptions(result.top_solutions),
            .{ .allow_custom = true, .allow_skip = true },
        );

        // 5. 根据选择行动
        switch (choice) {
            .option_0 => |i| {
                const chosen = result.top_solutions[i];
                // 存入知识图谱
                try self.knowledge.addFromResearch(chosen);
                // 存入记忆
                try self.memory.store(.{
                    .mem_type = .project,
                    .name = "optimization_choice",
                    .content = chosen.description,
                });
                try repl.printInfo("已记录选择，将按此方案执行");
            },
            .custom => |input| {
                // 用户自定义方案
                try self.knowledge.addCustomSolution(input);
            },
            .skip => {
                // 用户不满意，记录被拒方案避免重复
                try self.memory.store(.{
                    .mem_type = .feedback,
                    .name = "rejected_solutions",
                    .content = "用户拒绝了这些方案",
                });
            },
        }
    }
};
```

### REPL 中的研究交互示例

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 🔬 优化研究：向量搜索性能
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 用户需求："向量搜索太慢了，优化一下"

 📊 研究概况：
   · 搜索关键词：3 个（并行搜索）
   · 找到候选方案：12 个
   · φ 精选：展示 top 8 个（≈ 12 × 0.618）

 🏆 当前世界最优方案：

 ── 方案 1 [推荐] ──────────────────────────
  HNSW (Hierarchical Navigable Small World)
  来源：arXiv 1603.09320 / FAISS / hnswlib

  优点：
   · 查询复杂度 O(log n)，比暴力搜索快 100x+
   · 支持增量插入，适合动态知识库
   · C 库可用，Zig 通过 C FFI 集成简单

  缺点：
   · 内存占用比 IVF 高约 2x
   · 构建索引较慢

  兼容性：★★★★★ (95%)
  复杂度：中等

 ── 方案 2 ──────────────────────────────────
  Product Quantization (PQ) 向量压缩
  来源：FAISS / Pinecone

  优点：
   · 压缩比 4-100x，减少内存占用
   · 适合大规模（>1M 向量）

  缺点：
   · 有损压缩，精度下降 5-15%
   · 实现复杂度高

  兼容性：★★★★☆ (80%)
  复杂度：高

 ── 方案 3 ──────────────────────────────────
  改进现有暴力搜索 + SIMD 优化

  优点：
   · 改动最小，风险最低
   · 利用 Zig 的 SIMD 可以提升 4-8x

  缺点：
   · 仍然是 O(n)，规模大了还是慢

  兼容性：★★★★★★ (100%)
  复杂度：低

 💡 推荐方案 1 (HNSW)：
   在 1 万向量规模下，查询从 ~50ms 降到 ~1ms
   通过 hnswlib C 库集成，预计改动 ~5 个文件

 🔧 选择操作：
   [1] 采用方案 1 — HNSW（推荐）
   [2] 采用方案 2 — PQ 压缩
   [3] 采用方案 3 — SIMD 优化（最安全）
   [4] 方案 1+3 组合（先 SIMD 过渡，后续 HNSW）
   [5] 我有其他想法...

 输入选择: _
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 九、整合到已有架构的映射

新增的两个模块直接融入已有架构，不引入新的子系统：

```
已有模块                     新增能力融入位置
─────────────────────────────────────────────────────────
记忆系统 (memory/)     ←──  自诊断结果存入反思记忆
                           优化研究记录存入知识记忆
                           用户拒绝的方案也记录

知识图谱 (knowledge/)  ←──  优化方案存入知识节点
                           方案对比关系存入知识边
                           搜索到的外部资源存入 reference

反思引擎 (reflection/) ←──  自诊断触发反思
                           用户反馈驱动反思改进
                           方案采纳/拒绝更新策略权重

运行时检测 (runtime/)  ←──  新增规则：decision_quality
                           检测决策链中 confidence < φ 的步骤
                           检测长时间未优化的模块

事件总线 (event_bus)   ←──  新增事件类型：
                           .user_concern_raised
                           .diagnosis_completed
                           .research_started
                           .research_completed
                           .solution_selected
                           .solution_rejected

定时任务 (cron/)       ←──  新增定时任务：
                           自诊断回顾（每 π×60 分钟）
                           模块优化检查（每 φ×120 分钟）

工具系统 (tools/)      ←──  新增工具：
                           diagnose_tool（用户主动触发诊断）
                           research_tool（用户主动触发研究）

错误处理 (error/)      ←──  自诊断融入错误分析流程
                           错误发生后自动触发决策链回溯
```

### 新增文件清单

```
src/
├── runtime/
│   ├── decision_trace.zig       # 决策链记录（新增）
│   └── self_diagnostic.zig      # 自诊断引擎（新增）
├── research/
│   └── optimization_researcher.zig  # 优化研究引擎（新增）
└── tools/
    ├── diagnose_tool.zig        # 诊断工具（新增）
    └── research_tool.zig        # 研究工具（新增）
```

---

## 十、更新后的完整分阶段实施

### Phase 1: 基础 + 数学核心（1-2 周）
- 项目骨架、build.zig、SQLite
- 数学模块：constants, pi_ring, e_growth, phi_condense
- Claude API 流式调用 + SSE
- 基础 REPL + **DecisionTrace 记录框架**

### Phase 2: 工具系统（1 周）
- comptime ToolRegistry
- Bash、FileRead、FileWrite、**DiagnoseTool、ResearchTool**

### Phase 3: 异步任务系统（1-2 周）
- MPSC 无锁队列
- 线程池（e 控制并发上限）
- 事件总线（π 环形缓冲）+ 新增事件类型
- 定时任务（π/φ/e 周期）

### Phase 4: 持久化 + 记忆（1-2 周）
- SQLite 存储对话历史 + 决策链
- 三层记忆系统
- 向量存储 + 余弦相似度

### Phase 5: 运行时检测 + 自诊断 + 错误反馈（1-2 周）
- 检测规则框架 + 内置规则（7+1 条，含 decision_quality）
- **SelfDiagnostic 自诊断引擎**
- **DecisionTrace 回溯分析**
- 错误分析 + 用户选择交互
- 自动修复引擎

### Phase 6: 反思 + 知识浓缩（1-2 周）
- 反思引擎（π 周期触发）
- 经验提取（含自诊断结果提取）
- φ 知识浓缩算法
- e 控制知识衰减

### Phase 7: 多模型 + 网络搜索 + 优化研究（1-2 周）
- OpenAI / Ollama 后端
- 网络搜索 API
- **OptimizationResearcher 优化研究引擎**
- **并发网络搜索 + φ 精选 + 方案对比**
- 知识图谱

### Phase 8: 打磨（1-2 周）
- 高级 REPL、更多工具
- 完善自诊断交互展示
- 完善优化研究交互展示
- 跨平台测试

---

## 十一、验证方式

1. **数学模块**：单元测试 π 环形缓冲的均匀覆盖、sigmoid 输出 ∈(0,1)、Fibonacci 哈希分布
2. **异步任务**：提交 10 个后台任务，确认并发执行且不超过 e 控制的上限
3. **运行时检测**：模拟 API 超时，确认监控器检测到并提示用户选择
4. **错误反馈**：触发上下文溢出，确认展示分析 + 3+ 解决方案选项
5. **φ 浓缩**：1000 条记忆经过 3 次浓缩后 ≈ 1000 × 0.618³ ≈ 236 条
6. **e 衰减**：30 天未访问的知识重要性应衰减到 initial × e^(-1) ≈ 36.8%
7. **自诊断**：故意让 agent 遗漏一步，用户质疑后确认能回溯定位到薄弱环节
8. **优化研究**：说"优化向量搜索"，确认 agent 并发搜索 3+ 关键词，展示 φ 精选方案对比
