# Ziv 待办事项 & 待确认问题

## 待确认问题

### P1: Claude API 实际调用未接入
- **状态**: ✅ 已完成
- **描述**: Claude 后端已实现 (claude.zig)，REPL 已接入 LLM 调用，支持 `/model` 命令运行时切换模型

### P2: SQLite 未集成
- **状态**: ✅ 已完成
- **描述**: deps/sqlite3/ 下已有 amalgamation 文件，build.zig 编译配置完成

### P3: Zig 0.16 API 适配
- **状态**: ✅ 已完成
- **已解决**: build.zig 模块系统、I/O Threaded、ArrayList unmanaged、print 格式、Sha256.init(.{})
- **最新修复**: std.time.milliTimestamp (10 文件 19 处 → util/time.zig nowMillis)、ArrayList.init(allocator) (13 文件 33 处 → .empty)、unused parameter 警告 (3 处)

### P4: util/uuid.zig 中 std.crypto.random 兼容性
- **状态**: 待确认
- **描述**: uuid.zig 使用了 std.crypto.random.bytes()，该 API 在当前 Zig 0.16.0 构建中尚未被触发（uuid 模块存在但测试未实际编译 uuid 函数体）。需要确认实际运行时是否可用。

### P5: checkpoint/file_history.zig 实际备份逻辑
- **状态**: ✅ 已完成
- **描述**: trackEdit() 实现了完整的文件备份（读文件→SHA256→写入备份），restoreSnapshot() 实现了文件恢复和新文件删除。rollback.zig 三个核心方法全部实现。repl.zig 集成了自动备份和 /rewind 文件恢复。

### P6: ripgrep 工具的实际调用
- **状态**: ✅ 已完成
- **描述**: subprocess.zig 的 isAvailable() 修复为 PATH 遍历查找，不再使用 std.testing.allocator。ripgrep 封装（ripgrep.zig）已适配 Zig 0.16 std.Io API。

### P7: config.zig 中的 readFileAlloc API
- **状态**: 需要确认
- **描述**: config.zig 中使用了 std.Io.Dir.readFileAlloc，但 io 参数传递需要确认是否正确

### P8: streamDelimiter 不消费分隔符
- **状态**: ✅ 已完成
- **描述**: Zig 0.16 的 `std.Io.Reader.streamDelimiter` 不消费分隔符，需在每次调用后 `r.toss(1)`。已修复 repl.zig 中全部 15 个调用点。这是导致"执行一条命令就退出"的根因。

### P9: switchModel 悬空指针
- **状态**: ✅ 已完成
- **描述**: switchModel 把 model_name 指向 line_buf 局部变量，下次循环变成悬空指针。改为 model_name_buf[64]u8 内部缓冲区 + modelName() 方法。

### P10: ANTHROPIC_BASE_URL / OPENAI_BASE_URL 未读取
- **状态**: ✅ 已完成
- **描述**: config.zig 新增 anthropic_base_url 和 openai_base_url 字段，从环境变量 ANTHROPIC_BASE_URL / OPENAI_BASE_URL 读取，创建 Provider 时传入自定义 base URL。

### P11: Zig 0.17.0 升级
- **状态**: ✅ 已完成 (2026-10-26)
- **描述**: Homebrew zig 0.16.0 → 0.17.0。修复两类破坏性变更：
  1. `@cImport` 移除 → 新增 `src/storage/sqlite_c.zig` 手写 extern 绑定（13 个符号），database.zig 改 import，调用点微调 3 处；
  2. 数组重复语法 `[_]T{v} ** n` 移除 → `@splat`（file_history / phi_condense ×2 / pi_ring / memoize 共 5 处）。
  build / test 3/3 / REPL 冒烟全过。
- **同日收尾 (2026-10-26)**: `zig fmt` 0.17 已执行（91 文件重排，并自动升级 `@intFromEnum/@enumFromInt` → `@backingInt/@fromBackingInt` 共 12 处，零残留）；版本字符串修正（main.zig banner → v0.3.0、`/version` 改为动态取 `builtin.zig_version_string`、USAGE.md 环境表 → Zig 0.17.0，删除"版本号不一致"已知问题条目）；ZLS 经 zvm 升级至 0.17.0（zls 0.17.0 发布于 2026-10-19，已适配 zig 0.17）。
- **剩余遗留**: `std.fmt.allocPrint`（65 处）0.17 弃用、0.18 移除 → 需迁移至 `Allocator.print`，建议 0.18 发布前一次性处理。

### P12: 测试套件从未真正运行（重大发现）+ T1.1 episodic 参数化
- **状态**: ✅ 已完成 (2026-10-26)
- **发现**: main.zig 的 `pub const xxx = @import(...)` 是懒分析（无引用不执行），test 声明从未被收集——**`zig build test` 自仓库建立以来一直 0 测试空转却报"全绿"**。实证方法：往 integration.zig 现有测试塞必失败断言，套件依然通过。
- **修复 1（测试基础设施）**: main.zig 增加 `test { _ = @import(...) }` 聚合块，首次激活 77 个测试。
- **修复 2（激活暴露的 18 个历史失败）**:
  - 0.17 死代码路径编译错误：ArrayList unmanaged 迁移残留 8 文件（.init→.empty、append/deinit 带 allocator）、dupeZ→dupeSentinel、std.fs.cwd→std.Io.Dir（fs_ops 重写为自带 Io 实例）、@ptrFromInt 对齐检查拒绝 SQLITE_TRANSIENT（-1）→ 改 SQLITE_STATIC 语义、`error` 关键字 enum 标签、std.sort 比较器改值语义、Writer.Allocating 适配
  - 运行时真 bug：SSE 分隔符索引越界（findDoubleNewline 返回位置语义错误）+ drain() 事件字符串所有权泄漏、MPSC deinit 残留 tail 节点泄漏、self_diagnostic root_cause 悬垂指针（指向已释放的 gaps 缓冲）+ 静态字面量 free → bus error、util/time formatIso 有符号整型补零输出 '+' 号（转无符号修复）
  - 测试自身错误：phi_condense 两测试期望自相矛盾（949.28 不可能同时 round 出 618 和 950，按 round 修正为 949）、KnowledgeGraph 硬编码 id 0（AUTOINCREMENT 从 1 起，改用返回值）、DecisionTrace 测试双重 free、researcher.research 依赖真网络标记 SkipZigTest
- **修复 3（T1.1 本体）**: episodic.zig store/retrieveRecent/touch 全部改 prepared statement（sqlite_c.zig 增补 bind/column API、database.zig 新增 Statement 封装）；retrieveRecent 从空桩变为完整实现（含所有权契约 freeEntries）；注入载荷 `'; DROP TABLE memories;--` 往返测试通过。
- **结果**: **76 pass / 1 skip / 77 total 全绿**；主程序 build + REPL 冒烟正常。

### P13: 测试聚合不传递 + 第二波 0.17 迁移（M2 前置收尾）
- **状态**: ✅ 已完成 (2026-10-26)
- **发现**: P12 的聚合块经 mod.zig 只收集了 77/168 个测试（`_ = @import("x/mod.zig")` 不会传递收集子文件测试——pub const 仍是懒分析）。改为逐文件列出全部 60 个含测试文件后激活 170 个测试，又暴露 40+ 个从未编译/运行的历史问题。
- **修复（0.17 死路径编译错）**: working/reflection/message/extraction/orchestration 的 ArrayList 残留、uuid 的 `std.crypto.random`（改 ChaCha+SplitMix64 种子：时钟^栈地址^调用序号）、thread_pool/monitor 的 `Thread.Condition/Mutex`（移入 std.Io；worker 空闲等待改 nanosleep 轮询，MPSC 本就无锁）、lockfile/tempfile/find_executable 的 `std.fs.cwd`（Io 化重写）、`Target.current`→`builtin.target`、`fmtSliceHexLower`→`{x}` 格式、`eqlCaseInsensitiveASCII`→`ascii.eqlIgnoreCase`、PiRingBuffer 补 `getOldest`、json.Value union `.null` 初始化。
- **修复（运行时真 bug）**: `getStringField/getIntField` 无 union 标签守卫（.null 输入 panic）、`bashIsDestructive` 缺 command 误判破坏性、parseResponse 的 JSON DOM 永不释放（CompleteResponse 增 `dom_arena` + `free()`；repl 侧因 history 引用 DOM 暂不调用，记为已知债）、WorkingMemory.store 改持有防御拷贝（调用方可传字面量）、extraction 移交事实所有权、json_helpers.parse 改返回 `Parsed(Value)`。
- **修复（测试自身错）**: hash 测试抄错 SHA-256 向量（digest[1]=0xf2）、path 扩展名测试要求复合后缀（impl 改首点语义）、tokens 测试按词数但 impl 是 len/4（以 impl 为准）、phi/compaction 两测试对 condensationTarget(100) 期望互斥（61.8 不可能同时 floor 出 62 和 61，统一 floor 语义）、classifier 测试 `.null` 输入无意义（改真实 `rm -rf /` 输入）。
- **结果**: **169 pass / 1 skip / 170 total 全绿**；主程序 build + REPL 冒烟正常。

### P14: M2 记忆闭环（v0.3.x 核心能力）
- **状态**: ✅ 已完成 (2026-10-26)
- **T3.1 会话结束提取**: repl 在 `/quit` 与 `/clear` 前调用 `extractSessionMemories`——遍历 history 的 user/assistant 文本块 → 启发式提取（extraction.zig，含中英关键词：prefer/always/never/不要/总是/喜欢/解决/修复…）→ `MemorySystem.store` 入 SQLite（`.ziv/memory.db`，含 runMigrations）。extraction 层新增同内容去重（一条消息命中多启发式只存一条）。
- **T3.2 重启加载注入**: repl 启动时 `retrieveRecent(20)` → 新增 `memory/injection.zig` 的 `buildMemoryBlock` 拼装注入块，追加为 system message 的第二个 ContentBlock；`[INF] memory: injected N entries` 日志可审计。
- **T3.3 预算截断**: 注入块 token 预算 800（util/tokens 估算），逐条累计、超预算即停、至少保 1 条；name/content 各截 48/200 字符。
- **T3.4 端到端验证**: 自动化测试 3 个（空入参 null / 预算截断含关键词 / 库存-重载-注入闭环）+ 人工两段式验证通过：会话1 存 1 条 → 重启注入 1 条 → 库中记录可查。
- **修复过程中的真 bug**: 初版没跑 `runMigrations()`（表不存在、facade 吞错、"Saved N" 计数虚高假阳性）——已修：migrations 失败则禁用记忆并告警。
- **已知限制（后续迭代）**: ① 注入排序按 recency，相似度检索（向量化）留到 M4/M8；② memory facade 的 store 对 episodic 失败只打 warning 不上报；③ repl 内 CompleteResponse 因 history 引用 DOM 暂不调用 free()（会话级泄漏，P13 已记）。

### P15: 既有功能闭环验收（M4 前实测审计）
- **状态**: ✅ 已完成 (2026-10-26)
- **验收矩阵**: A 记忆跨会话重复 / B `/rewind` 实测 / C 管道多行 / D `/stats`·`/context`·`/undo`·`/compact` 冒烟。
- **A 发现并修复**: 同一句话跨会话重复入库（`memoryId` 混入时间戳导致同内容 id 不同）→ 改纯内容双 Wyhash id + episodic INSERT 改 `INSERT OR REPLACE`（幂等 upsert，重复提及自动刷新 updated_at，配合 recency 排序合理）。复验：两会话同句 → 库中 1 条、0 重复。
- **B 发现并修复**: `/rewind` 语义为"跳到该操作**之后**"，选最新操作永远无事可回滚 → rollback.zig 增加 `session_start_op_id` 全零哨兵（preview/rollbackTo 对其撤销全部），列表新增 `[0] Session start (undo all file changes)`。复验：FileWrite MODIFIED → /rewind 0 → y → 文件恢复 ORIGINAL。
- **C 洗清**: 管道多行**实测正常**（P8 修 streamDelimiter 时已顺带修好），USAGE §9.3 对应已知问题为陈旧信息，已删除。
- **D 顺带修复**: `/context` 输出 `61.8%%` 双百分号转义错误 → `%`。四命令冒烟均正常。
- **备注**: `/rewind` 的序号选择与 y/N 确认在管道模式下会消费后续输入行——属交互式命令在管道场景的固有行为，不视为缺陷。

### P16: M4 反思接入
- **状态**: ✅ 已完成 (2026-10-26)
- **T4.1 反思触发**: repl 会话内维护"反思窗口"（最近 20 条查询 dupe + 工具/错误计数）；每轮 agent 交换结束调用 `shouldReflect()`（每 10 轮或 π×10min 间隔触发）；`/quit` 时若窗口非空强制触发（on_session_end）。`reflect()` 增加 trigger 参数。
- **T4.2 经验入库**: 反思产出的 insights 以 `.feedback` 类型记忆入库（`INSERT OR REPLACE` 幂等），下一会话自动注入 system prompt——反思经验跨会话生效。`executeAndRecord` 改为返回 `!bool`（是否出错）供错误率计算。
- **T4.3 /memory 命令**: 展示本会话注入条数 + 最近 5 条库存（类型 + 名称）；`/help` 已收录。
- **实测**: 单查询会话 → /quit → `[Reflection] 交互质量良好…` + 提取 1 条；重启注入 2 条（reflection + 提取记忆）；`/memory` 列表正确。
- **触发提示**: 反思窗口计入的是"发给 LLM 的输入"（命令不计）；无 API key 时 LLM 调用失败但查询已入窗，反思照常触发。

### P17: 代码审查（业务链闭环，code-review-skill）
- **状态**: ✅ 已完成 (2026-10-26)，3 项发现全部修复
- **🔴 R1 config UAF（P13 引入的回归）**: `json_helpers.parse` 改返回 `Parsed(Value)` 后，`loadJsonIntoSettings` 把 default_model/api_keys/system_prompt 以**指向解析域的切片**存入 settings，函数返回 DOM 即释放 → use-after-free。修复：全部字段 `allocator.dupe`。实测：临时 settings.json 指定 llama3.2 → 启动后提示符与 /model 正确显示（验证后清理配置，净零）。
- **🔴 R2 回滚哨兵溢出崩溃（P15 引入）**: `rollbackTo` 尾部 `target_idx.? + 1` 对 session_start 哨兵（maxInt）是 usize 溢出 → debug 构建 panic。**P15 验收时输出被截断掩盖了崩溃**（文件恢复≠全链路无恙，局部验证陷阱实证）。修复：`keep_count` 显式分支计算。复验：Restored → (1 restored, 0 errors) → /quit Goodbye 全程无崩。
- **🟡 R3 流式事件泄漏（P13 drain 语义变更未同步调用方）**: drain 改为所有权移交后，claude/openai 的 stream() 只 free 切片不 free 事件字符串 → 每个流式响应泄漏。修复：调用方补齐 event/data/id 三字段释放。
- **链路复核结论**: 记忆链（提取→入库→注入→/memory）、反思链（窗口→触发→入库→跨会话注入）、回滚链（备份→预览→恢复→日志收缩）、配置链（读→解析→dupe→使用）全链绿；测试 170+ 全绿；fmt 0。

### P18: 迭代二（T1.3 权限匹配 / M5 WebSearch / M3 知识浓缩）
- **状态**: ✅ 已完成 (2026-10-26)
- **T1.3 权限规则模式匹配**: 修正两处逻辑——带 pattern 的 deny 规则原先是"无视 pattern 直接拒绝"、allow 规则同样"无视 pattern 直接放行"；现改为 glob 匹配 `command`/`path` 字段（glob_match）：deny pattern 命中才拒、allow pattern 命中才放、不命中继续走管道，无 pattern 保持 blanket 语义。8 用例表驱动测试覆盖 blanket/pattern 命中/未命中/无字段路径。
- **M5 WebSearch 接入**: tools/web_search.zig 从桩接线到 knowledge/search.zig 的真实现；后端选择 BRAVE_API_KEY 有则 Brave、否则 DDG 免 key。**三层深挖修复**（该 HTTP 路径从未运行过）：① `readAlloc` 按定长读 → 改逐块拼接（allocRemaining 对 DDG 缺 chunked terminator 的流报 EndOfStream）；② DDG 响应**不带 Content-Encoding 头但 body 是 gzip** → 魔数嗅探（\x1f\x8b）+ flate.Decompress 透明解压；③ HTML 解析标记 `<a class="result__a"` 与真实页 `<a rel="nofollow" class="result__a"` 属性顺序不符 → 改按 class 匹配。实测 DDG 返回 ziglang.org 真实结果。
- **M3 知识浓缩（最小闭环版）**: ① T1.2 KnowledgeGraph 全参数化（addNode/addEdge prepared，pruneWeakEdges/nodeCount 从"永远返回 0"的桩变真实现，sqlite3_changes/bind_double 补进绑定层）；② φ 浓缩接入提取管线：候选 facts 按重要性排序后只保 condensationTarget(n)（61.8%）；③ e 衰减接入注入排序：decayScore = e^(-age/30天)，30 天 ≈ 36.8%（DESIGN 验证 #6 达成），注入块按新鲜度排序（新增 2 个单测）。
- **验证**: 全量测试绿（含新增 permission 表驱动 ×8、graph 真实现断言、decay 双测）；REPL 实测 WebSearch/提取/φ 过滤路径正常。

### P19: 迭代三（M6 Task 打通 / M7 编排并行 / M8 自诊断+研究接入）
- **状态**: ✅ 已完成 (2026-10-26)
- **M6 Task 工具打通**: 新增 `tools/task_store.zig`（进程级会话任务存储：pending/in_progress/completed 状态机、render、φ 无关的朴素计数）+ TaskCreate/TaskList/TaskUpdate 三工具从无状态假实现接线到真存储。REPL 实测：创建→更新→列表全链路 ✓；含存储生命周期与三工具端到端集成测试。
- **M7 编排真并行**: `executeBatches` 的并发安全批从"串行假装并行"改为真线程池并行——每调用一个 ParallelCall 上下文提交到 e 上限线程池，自旋等待全部完成，**按原始调用顺序回收结果**；池初始化失败降级串行（语义不变）。途中激活两个从未编译的死路径 bug：`TaskStatus` 枚举缺显式 tag（atomic.Value 要求）、workerLoop 传 allocator 值而非指针、`c.timespec` 字段名（.sec/.nsec 而非 tv_sec/tv_nsec）。4 路并行 FileRead 实测保序 ✓。
- **M8 自诊断 + 研究引擎 REPL 接入**:
  - `/research <topic>`: OptimizationResearcher + 真 WebSearch——φ 生成 3 组查询、并发搜源、30 候选精选、★ 推荐标记 + 理由（DESIGN 第十章"自主优化研究"首次真实闭环，实测 2.8s 3 源 4 方案）。
  - `/diagnose <concern>`: 用真实会话统计构造轻量决策链（记忆注入置信 / 工具错误率置信 / 生成置信）→ SelfDiagnostic 找低于 φ 的薄弱环节 → 输出 root cause + 建议。实测与记忆系统真实联动：注入 2 条时"0 gaps（最弱 0.80）"；清空记忆库后"1 gap，root cause: memory_retrieval 置信 0.30 < φ → 建议扩大检索范围"。
  - 修复 self_diagnostic 的悬垂隐患：owned_gaps 曾浅拷贝已释放的 description 指针（新增 DiagnosisReport.free + 深拷贝）；修复 DecisionTrace query 所有权契约踩坑（init 接收堆分配，repl 侧 dupe）。
- **验证**: 178 pass / 1 skip / 179 total 全绿；REPL 实测 TaskCreate/Update/List、4 路并行编排、/research 真网络、/diagnose 双场景（有/无记忆）全通过；/help 已收录新命令。

### P20: 三项技术债清偿（缺陷修复轮）
- **状态**: ✅ 已完成 (2026-10-26)
- **DOM 泄漏（每 LLM 响应漏一块）**: agent loop 在把 assistant 响应放进 history 前改为**深拷贝** content blocks（`cloneContentBlocks`：text/thinking 字符串、tool_use 的 id/name 与 **json.Value 整树递归拷贝**、tool_result 字符串），随后立即 `response.free(allocator)` 释放 DOM arena；tool_use 提取循环改从 history 的 owned 拷贝迭代（响应已释放）。泄漏从"每次 LLM 调用"降为"会话级持有"（与 history 生命周期一致，进程退出回收）。新增深拷贝单测（testing.allocator 零泄漏 + 嵌套 JSON 树存活断言）；repl.zig 首次纳入测试聚合。
- **facade 吞错**: `MemorySystem.store` 对 episodic 失败从"打印 warning 后假装成功"改为"记录并**上抛错误**"——调用方（extractSessionMemories/runReflection）原有的 catch 计数逻辑随之恢复真实（彻底杜绝 P15 式"Saved N 虚高"假阳性）。
- **allocPrint 迁移（65 处 → 0）**: `std.fmt.allocPrint(alloc, fmt, args)` 全量改 `alloc.print(fmt, args)`（0.17 正道、0.18 前置要求），含 7 处跨行形态手工处理。`std.fmt.allocPrint` 在 src 中已绝迹。
- **验证**: build/test 全绿（含新增深拷贝测试）、REPL 冒烟正常；深拷贝的运行时路径待下次真实 LLM 对话自然覆盖（本机 Ollama 未运行，单测已覆盖同等逻辑）。

### P21: 三个空转骨架接线（agent loop 并行 / 知识图谱写入 / 真实决策链）
- **状态**: ✅ 已完成 (2026-10-26)
- **① M7 并行接入 agent loop**: 工具执行重构为两阶段——阶段 1 串行完成权限门（deny/ask 交互照旧产出错误 result）+ trackEdit 备份 + 收集 `PreparedCall`；阶段 2 整批交给 `partitionToolCalls → executeBatches`：并发安全工具（FileRead/Glob/Grep/WebSearch/TaskList…）在 e 上限线程池**真并行**，非安全工具串行，结果按原序回收（`finishToolCall`：打印/截断/op_log/入 history）。`executeAndRecord` 拆分为 PreparedCall + finishToolCall。/run 命令路径不受影响。
- **② 知识图谱（semantic 层）启用**: `extractSessionMemories` 在 φ 过滤后的每条事实入库同时 `addNode(entity=记忆名, .concept, source=fact_type)`，同会话节点间连 `co_extracted` 边（weight=φ）；新增 `recentNodes` 查询 API（prepared）与 `/knowledge` 命令（节点总数 + 最近 5 条）。实测：提取 1 条 → `/knowledge` 显示 `#1 [concept] 我 prefer 用 zig 写 agent (from user_preference)`。
- **③ 真实决策链**: agent loop 内逐步埋点——每条用户查询新建 `DecisionTrace`（live），记录 memory_retrieval（注入置信）、llm_generation（按 output_tokens/content 置信，reasoning=stop_reason）、tool_execution（批内错误率置信）；`/diagnose` 优先用 live 链（输出标注 "live agent-loop trace, N steps"），无查询时静态 3 步构造作兜底。实测：查询因无 key 失败 → /diagnose 显示 1 步 live 链并正确诊断记忆薄弱。
- **验证**: 全量测试绿、REPL 冒烟（/run Bash、/knowledge、live /diagnose、提取→图谱）全过。

## 已完成事项

### Phase 1: 增强工具接口 ✅
- [x] 扩展 ToolDefinition 支持并发安全、权限检查、输入验证
- [x] ValidationResult / PermissionDecision 类型
- [x] matchesName 别名匹配
- [x] findByName 别名查找
- [x] 更新 Bash/FileRead/FileWrite 工具行为函数

### Phase 2: 授权执行模式 ✅
- [x] auth_mode.zig — 6种执行模式 + 权限管道
- [x] rule_parser.zig — 权限规则解析
- [x] classifier.zig — 自动分类器接口（预留）
- [x] denial_tracker.zig — 拒绝追踪

### Phase 3: 工具编排 ✅
- [x] orchestration.zig — 分区/并行/串行执行

### Phase 4: 新增工具集 ✅
- [x] Glob — 目录遍历+模式匹配
- [x] Grep — ripgrep/内置搜索
- [x] FileEdit — 字符串替换编辑
- [x] WebSearch — 网络搜索（API待接入）
- [x] TaskCreate/List/Update — 任务管理
- [x] AskUserQuestion — 向用户提问
- [x] ToolSearch — 工具搜索
- [x] 所有工具注册到 default_tools（共12个工具）

### Phase 5: 消息压缩 ✅
- [x] compaction.zig — φ阈值触发 + LLM摘要策略

### Phase 6: 配置层级 ✅
- [x] config.zig — User/Project/Local/CLI/Session 五层配置

### Phase 7: 完整工具类 ✅
- [x] 30+ util 文件：cancel, shell_quote, hash, uuid, log, format, string_utils, path, platform, env, system_dirs, json_helpers, tokens, time, file_cache, binary_check, find_executable, sanitization, subprocess, cleanup, tempfile, diff, fs_ops, lockfile, semver, memoize, glob_match, ripgrep, http_client

### Phase 8: 操作记录与回滚 ✅
- [x] file_history.zig — SHA256 文件快照备份 + 恢复 + 新文件删除追踪
- [x] op_log.zig — 操作记录引擎
- [x] rollback.zig — 回滚执行器（完整实现：listRollbackPoints + previewRollback + rollbackTo）
- [x] repl.zig 集成 — executeAndRecord 自动备份 + /rewind 真正恢复文件
- [x] hash.zig — 修复 Sha256.init(.{}) 适配 Zig 0.16
- [x] subprocess.zig — 修复 isAvailable() 使用 PATH 遍历而非 std.testing.allocator

### Phase 9: Agent 循环集成 ✅
- [x] REPL 增强：/mode, /history, /rewind, /stats 命令
- [x] 权限模式指示器
- [x] 操作日志集成
- [x] 工具信息展示增强（显示安全属性）

### Phase 10: 完整 Agent Loop ✅
- [x] 系统提示词 (system_prompt.zig + Settings 字段)
- [x] 对话历史保持 (ArrayList 消息累积)
- [x] 工具调用循环 (tool_use → 权限检查 → 执行 → 结果回传 → 循环)
- [x] 消息压缩接入 (phi 阈值自动压缩 + /compact 手动触发)
- [x] 交互式配置菜单 (/config — 两级菜单、API key 掩码显示、持久化保存)
- [x] API key 环境变量回退 (OPENAI_API_KEY, ANTHROPIC_API_KEY, BRAVE_API_KEY)
- [x] 配置持久化 (saveSettings 写入 ~/.config/ziv/settings.json)
- [x] 对话管理命令 (/compact, /clear, /context, /undo)
- [x] Token 用量追踪 (session 级 input/output 统计)
- [x] /help 和 /stats 命令更新

### 新增待办

### 原有完成项
- [x] 数学核心 (π/e/φ)
- [x] Comptime ToolRegistry
- [x] OpenAI/Ollama/Claude 三后端完整实现
- [x] SSE 流式解析
- [x] 三层记忆系统框架
- [x] 反思引擎
- [x] 运行时检测规则
- [x] 自诊断引擎
- [x] 知识图谱
- [x] 优化研究引擎
- [x] REPL 基础功能
- [x] Zig 0.16 API 全面适配 (ArrayList, http.Client, json, Io)
- [x] 运行时模型切换 (/model <name>)
- [x] 多后端 Provider 工厂 + 自动路由
- [x] env.zig Zig 0.16 兼容修复

## 新增待办

### N1: 工具调用循环 (tool_use → execute → feed back)
- **状态**: ✅ 已完成 (Phase 10)
- **描述**: 完整 agent loop 已实现：检测 stop_reason == .tool_use → 提取 tool_use blocks → 权限检查 → 执行工具 → 结果回传 → 循环直到 end_turn

### N2: 流式输出优化
- **状态**: ✅ 已完成
- **描述**: OpenAI/Claude/Ollama 三个后端的 stream() 函数已改为增量式读取（readSliceShort 循环），边读边解析 SSE/JSON 事件，实时触发回调。不再缓冲完整 body。

### N3: API Key 环境变量支持
- **状态**: ✅ 已完成 (Phase 10)
- **描述**: config.zig 现在支持 OPENAI_API_KEY / ANTHROPIC_API_KEY / BRAVE_API_KEY 环境变量作为 fallback

### N4: config 加载崩溃修复
- **状态**: ✅ 已完成
- **描述**: config.zig 的 loadJsonIntoSettings 使用 `catch return`，settings.json 不存在时不会崩溃，返回默认 Settings

### N6: 运行日志集成
- **状态**: ✅ 已完成
- **描述**: util/log.zig 修复了 Zig 0.16 兼容性（使用 util/time.zig 替代 std.time.milliTimestamp，使用 std.debug.print 替代旧 Io.File API）。在 repl.zig、file_history.zig、openai.zig、claude.zig 的关键路径加入日志：LLM 调用/错误、工具执行/失败、模型切换、备份写入失败、快照恢复。
- **查看方式**: `./zig-out/bin/ziv 2>ziv.log`

### N6b: checkpoint 目录自动创建
- **状态**: ✅ 已完成
- **描述**: file_history.zig 新增 dir_ensured 标志，首次 trackEdit 时调用 std.Io.Dir.cwd().createDirPath(io, ...) 自动创建 .ziv/checkpoints 目录。

### P22: 增强清单清空（流式实时化 / 429 / 五项增强 / 跨平台 / zvm）
- **状态**: ✅ 已完成 (2026-10-27)
- **流式输出实时化（原"待核实"项的完整解法）**: 悬案核实结论=REPL 从未消费 stream()（用 complete 非流式）。彻底修复：① `Provider.stream` 增加 ctx 参数（vtable+三后端）；② REPL 改流式调用，text delta **实时打印** + 聚合 tool_use/usage 为 REPL 自有响应（无 DOM arena、免深拷贝）；③ 根因修复——三后端读循环 `readSliceShort` 等 4KiB 缓冲凑满导致整响应攒批，改 `peekGreedy(1)` 增量消费。**mock 实测**：慢速 SSE 服务器 5 块（0~1.62s 分发），ziv 输出 +0.39/+0.79/+1.20/+1.60/+2.01s 逐块跟随（恒定 0.39s 传播延迟）。
- **WebSearch 429 退避**: 429 → `error.RateLimited` → search() 退避 1s 重试一次；后端 URL 可经 `ZIV_DDGO_URL`/`ZIV_BRAVE_URL`/`ZIV_SEARXNG_URL` 覆盖（mock 可测）。实测：mock 首发 429 再 200（gzip DDG 页）→ 退避后成功返回结果。
- **五项增强**: ① 注入向量相似度——新增 `util/embedding.zig`（64 维 hash 词袋、L2 归一），注入排序 = 0.5×e 衰减 + 0.5×与最新记忆余弦（预计算分数，比较器零分配）；② 决策链 7 阶段全埋点（补 context_assembly / tool_selection / response_postprocess / reflection_trigger 四步）；③ 反思 LLM 增强（provider 可达时 LLM 一句总结替代启发式 insights，启发式兜底与质量分来源不变）；④ 语义层 fact→entity 类型映射（technology/code_pattern/organization/custom/concept）；⑤ auto 模式接 LLM 分类器——ask 级操作交 LLMClassifier 判 allow/block（失败降级 allow），实测 mock LLM 回 ALLOW → /run Bash 直通。
- **顺带修复**: `current_mode` 硬编码 `.default` 从不读配置（permission_mode 配置形同虚设）→ 改读 `settings.permission_mode`。
- **③ 平台与工具链**: `zig build -Dtarget=x86_64-linux-musl` 与 `aarch64-linux-musl` 交叉编译全过（静态 ELF）；zvm 0.8.17 → 0.9.4。Linux 运行时留待实机（musl 静态链接兼容面广）。
- **验证**: 全量测试绿；mock 实测三场景（流式逐块、429 退避、auto 分类）全过；REPL 冒烟正常。

### P23: /config 与 /model 交互式改造（方向键菜单）
- **状态**: ✅ 已完成 (2026-10-27)
- **新增 `util/menu.zig`**: 通用方向键菜单引擎——raw 终端模式（termios；非 TTY 管道自动降级逐字节读，可脚本化测试）、↑↓/vim jk 移动、Enter 确认、q/Esc 取消、数字 1-9 跳转、ANSI 重绘（❯ 高亮）。
- **/config 重写**: 主菜单（API Keys/默认模型/最大 tokens/权限模式/检查点/系统提示词/退出）全部方向键导航；权限模式与模型子菜单也是 select；**每项修改立即自动保存** settings.json（autoSaveSettings）；API Keys 子菜单菜单化+掩码显示。
- **/model 交互式**: 无参 `/model` 弹模型选择菜单（9 个已知模型+当前●标记+取消），Enter 运行时切换并保存 default_model；`/model <name>` 命令式保留。
- **实测（管道注入 ESC 序列）**: `/config ↓ Enter ↓ Enter` → 默认模型切 claude-sonnet-4-6 → settings.json 自动落盘 ✓；`/model ↓ Enter` → 已选+key 缺失正确提示 ✓。测试配置已净零清理。

### P24: 模型接入三连修 + 行编辑器（用户实测反馈驱动）
- **状态**: ✅ 已完成 (2026-10-27)
- **🔴 自定义模型名首字符丢失**: promptCustomModel 返回**栈缓冲切片**（悬垂），/model 路径 allocPrint 前栈被覆写（glm-5.3 → " lm-5.3"）。修复：函数内 dupe 后返回堆串（日志实测 model=glm-5.3 完整）。
- **🔴 default_backend 劫持已知模型**（自查发现）: pin 后选 claude-*/表内模型也被发往网关。路由改四层优先级：表内 > 可识别前缀 > 显式 override（仅未识别名）> Ollama 兜底；四情形单测覆盖。
- **✨ 配置接入时自动拉取模型列表**: 新增 fetchGatewayModels（OpenAI 兼容 GET /models Bearer；Anthropic GET /v1/models x-api-key；Ollama GET /api/tags）+ offerGatewayModels（列出→选择→自动设 default_model/backend→切换→保存）。mock 实测：配 key+URL →"发现 3 个模型"→选 glm-4.5-air→对话真发网关（FETCHED_MODEL_OK）→落盘 ✓。
- **✨ 主输入行编辑器**（util/lineinput.zig）: raw 模式下方向键 ←→ 移动光标（UTF-8 按字符步进、CJK 双宽光标定位）、↑↓ 翻输入历史（相邻去重、上限滚动）、Backspace/Delete/Home/End、Ctrl-C 清行、Ctrl-D 空行退出；管道自动降级旧读法（全部既有脚本行为不变）。原主循环 streamDelimiter 替换。
- **/model 新增"自定义…"入口**: 与 /config 共享 promptCustomModel（含后端询问），网关模型免进 /config。
- **验证**: 187 测试全绿（新增路由优先级 + 编辑器缓冲操作 + 宽度计算）；管道回归（多命令/菜单/工具/记忆提取）全通过。

### P25: 接入链闭环复查（code-review）
- **状态**: ✅ 已完成 (2026-10-27)
- **🟡 Ollama Host 配置链两处断裂（已修）**: ①改 host 后 ollama_provider 缓存（init 时固化 base_url）不清理——当前会话仍连旧地址；②Ollama Host 未接模型自动拉取（OpenAI/Anthropic 有）。修复：case 3 清 provider 缓存 + offerGatewayModels(.ollama)，本机已装模型也能菜单直选。
- **🟢 登记不改**: fetchGatewayModels 的 JSON DOM 为 parseFromSliceLeaky 会话级泄漏（低频操作、量小）；promptCustomModel 返回堆串与 default_model 双重 dupe 小泄漏；menu.readLine（配置子输入）仍为 cooked 行读（无编辑器，主输入行已修）；lineinput draft 上限 1024 截断。
- **链路复核结论**: A 接入配置链（菜单→落盘→缓存清理→拉取→选择→路由→HTTP）、B 自定义路由链（四层优先级→switchModel→getProvider）、C 行编辑器链（TTY raw/管道 fallback→命令分发→历史）全部闭环；嵌套 raw 进出（行编辑器→菜单→readLine）恢复顺序正确。

### P26: 配置持久化复查（用户报告配置丢失）
- **状态**: ✅ 已完成 (2026-10-27)
- **诊断**: 实测当前版本保存→落盘→重启读回**全链正常**（key/URL/掩码显示验证）。用户遇到的丢失为历史版本存量伤害：P23 之前 saveSettings 不序列化 base_url，且旧版本存在全量洗写窗口（某次启动读到无 key 的内存状态后 autoSave 覆盖文件），用户文件中 anthropic_base_url 被洗即为证据。当前代码已无此问题。
- **🟡 /mode 持久化漏网（已修）**: 权限模式切换仅改运行时变量，重启回落配置值。现 /mode 切换即同步 settings.permission_mode + saveSettings（实测 accept_edits/plan 均落盘）。
- **配置自动保存全覆盖盘点**: default_model ✓ max_tokens ✓ permission_mode(本次补) ✓ checkpointing ✓ system_prompt ✓ api_keys 全家(含 base_url) ✓ default_backend ✓ default_backend(P23) ✓ —— /config 所有项改动即存；TaskStore 为会话级设计内不持久化。

### P27: 🔴 配置丢失真根因修复 + pin 崩溃（用户真机报障）
- **状态**: ✅ 已完成 (2026-10-27)
- **🔴 load 侧不解析 base_url（配置丢失真根因）**: P23 只修了 save 序列化，loadJsonIntoSettings 一直没读 openai_base_url/anthropic_base_url——保存成功但**重启读不回**，下次 autoSave 重写文件时该行消失。这就是用户"每次重新打开都要重新配置"的真正原因。已补 load 解析，重启实测 base_url 存活。用户被洗掉的 anthropic_base_url 已恢复。
- **🔴 switchModel alias 崩溃**: 网关 pin 流程 `switchModel(modelName())` 自切自 → @memcpy(buf, buf) 同源 panic（真机实测崩溃栈）。修复：名字未变时跳过拷贝，只重设 backend。崩溃场景复现通过（pin 分支正常走完）。
- **🟡 saveSettings key/URL 无 JSON 转义**: key 含引号会写坏文件，下次 load 静默丢全部配置。新增 writeJsonStringField 转义（5 种字符）。
- **今日六笔提交（b709c74→f513945）链路复查**: A 接入配置链（含本次 load 修复后真正闭环）/ B 自定义路由链 / C 行编辑器链 / D Ollama host 链（P25 修）/ E /mode 持久化（P26 修）/ F pin 流程（本次修）——全部闭环。

### P28: 全量多 agent 代码审查（4 agent 并行，46 项发现）
- **状态**: 🔴 大部分已修 (2026-10-27)，1 项大工程转功能开发
- **审查规模**: 4 个并行 agent 覆盖 llm/tools/memory+storage+checkpoint/repl+runtime+task+config，共 🔴16 / 🟡21 / 🟢9
- **已修复（🔴×11 + 🟡×2）**:
  - memory 3 红（P28 前段）：快照 key 泄漏 / 备份失败静默丢文件 / 搜索 JSON 树泄漏（Brave+SearXNG 两处改 parseFromSlice+defer deinit）
  - streaming.zig Claude 流式 usage `.float` 对 `.integer` union panic → switch 兼容
  - orchestration defer 顺序 UAF：pool.deinit 移至最先注册（LIFO 最后执行），确保 join 先于 free(tasks/ctxs)
  - lineinput draft 缓冲 1024→4096（与编辑缓冲一致，防长行按↑越界）
  - /model 自定义模型 + MissingApiKey 时 KNOWN_MODELS[picked] 越界 → effectiveBackend 兜底
  - classifier fail-open → fail-closed（分类器故障回退 block 而非静默放行）
  - openai 流式请求补 stream_options.include_usage（官方 API 才发 usage；智谱本来就发）
  - /clear /compact /undo maybeCompact 五处消息移除全部改为 freeMessage 释放 content（此前每次压缩/清空/撤销整块泄漏）
  - saveSettings default_model/default_backend/ollama_host 补 JSON 转义（与其他字段对称）
- **🔴 转功能开发（最大发现）**: **工具声明从未发送**——全 llm 层无一处写 "tools" 字段，buildRequestBody 只发 messages；agent loop 依赖的 stop_reason==.tool_use 从未发生（用户一直用 /run 手动执行掩盖了此缺口）。配套缺口：流式 tool_calls 解析（openai items[0]/空参数/分片丢弃、Claude content_block_start+input_json_delta 未处理、ollama 工具回路断裂）。这是「让 LLM 自动调用工具」的完整功能，涉及三后端请求构造+流式解析，工作量 1.5~2 天，列为下一任务
- **已登记未修（🟡×7 + 🟢×9）**: ollama parseChatResponse 无 arena / 流错误吞成 EOF / 每事件 leaky 三种所有权制度 / 1MiB 栈缓冲线程溢出风险 / compaction.zig 桩 / ask 规则无实现 / accept_edits 放行任意 Bash / pattern "cd x && git push" 绕过 / bash+grep 工具输出泄漏 / env 密钥静默落盘 / 管道超长行 EOF / effectiveConcurrency(0,·)恒=1（并行名存实亡，同时掩盖 MPSC 单消费缺陷）/ MPSC 多消费者不安全 / task_store global() 竞态（被串行批掩盖）/ findWeakSteps+event_bus+monitor+cron 死代码 / max_snapshots+allow_rules 配置对称缺口
- **验证**: 187 测试全绿；配置 JSON 落盘合法性实测 ✓；/run+权限门+/model 自定义切换冒烟 ✓

## P29（2026-10-27）4-agent 审查遗留项清零 + 工具调用闭环落地

三笔提交：
- **65fe4d7 工具调用闭环（P28 最大遗留，功能开发）**：
  - `provider.ToolSpec` + `CompleteOptions.tools`；registry 导出 `default_tool_specs`（12 工具）
  - openai：请求体铺平（assistant tool_use→`tool_calls`、tool_result→独立 `role:"tool"` 消息）+ tools 声明 + `stream_options.include_usage`；`OpenAIStreamState` 按 index 累积分片 arguments、finish_reason/[DONE] 时逐个发射 `.tool_call`（旧解析只取 items[0]、id 缺失 panic、arguments 全丢）；parseResponse 加固 + id 合成
  - Claude：tools 以 `{name,description,input_schema}` 发送；`ClaudeStreamState`（content_block_start tool_use + input_json_delta + thinking_delta + message_start/delta usage 合并 + message_stop）
  - ollama：tools（OpenAI 式）；tool_use→message.tool_calls（对象 arguments）、tool_result→`role:"tool"`+tool_name（id→name 映射表）；parseChatResponse 响应 arena 化 + 唯一 `ot_N` id + stop_reason=tool_use；流式行发射完整 tool_calls
  - repl agent loop 带 `.tools`；classifier 释放 complete() arena；删幻影 TaskGet
  - **e2e 已验证**：mock 网关 → 分片流式 tool_call 解析 → 权限门 y 确认 → 真实 FileRead → `role:"tool"` 回传 → 二轮最终回答
- **bd2d41d 权限加固+流错误+泄漏+竞态（13 项）**：链式命令分段匹配（deny 任一段命中；allow 全段覆盖且禁用整体短路，`git status*` 不再放行 `git status && rm -rf /x`）；ask 规则全链路实现（config 读写/checkToolPermission Step 1b/bypass 免疫）；accept_edits 不再放行 Bash；危险命令表扩充；门应答缓冲 Allocating 化；管道超长行截断+排水；规则列表读写对称（jq 校验）；**env 密钥不再被 autoSave 落盘**（复现 ANTHROPIC_BASE_URL 泄漏后修复：EnvSourced 标记）；三后端流中断→`.error_occurred`；sendRequest 1MiB 栈→64KiB；bash 释放+stderr；grep 释放；TaskStore 锁+竞态修复 global；findWeakSteps 返回索引；删 compactMessages 桩
- **67162e8 并行真化+泄漏+UTF-8+信号安全**：effectiveConcurrency 0→hw/2（此前恒 1，并行名存实亡）；finishToolCall//run 错误 output 泄漏；StreamAgg 错误路径工具串释放；/run arena；est_ctx 每轮刷新；RawGuard SIGINT 恢复 termios；op_id uuid 化；memoryId 掺 mem_type；注入截断退到 UTF-8 边界；bind 返回码上抛；graph addNode 实体去重；EventBus 所有权契约；删 registry.getByName

测试：187→196（195 pass / 1 skip / 0 fail），e2e 双跑 PASS。

**仍未做（显式遗留）**：
- monitor/cron/event_bus 运行时接线（编译进二进制但 repl 不启动——属新功能接入非缺陷，另立任务）
- config 五层加载覆盖时旧字符串泄漏（启动期 4 次小分配、会话级生命周期，接受不改；如要改需 owned 标记位）
- reflection 所有权文档（runReflection 内部全 dupe，无泄漏，仅缺注释）
