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
