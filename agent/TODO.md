# Zage 待办事项 & 待确认问题

## 待确认问题

### P1: Claude API 实际调用未接入
- **状态**: 待办
- **描述**: REPL 能启动但还不能真正和 LLM 对话，用户输入后只返回占位文本
- **依赖**: provider.zig + streaming.zig 已写好，需要接上真实 HTTP 调用
- **需要**: API Key 配置加载 + std.http.Client POST 请求 + SSE 流解析串联
- **影响**: Phase 2 工具系统可用 mock provider 测试，但真实使用需要此功能

### P2: SQLite 未集成
- **状态**: 待办
- **描述**: build_full.zig 已写好 SQLite 编译配置，但未下载 amalgamation 文件
- **需要**: 下载 sqlite3.c/sqlite3.h 到 deps/sqlite3/
- **影响**: Phase 4 记忆系统依赖此功能

### P3: Zig 0.16 API 适配
- **状态**: 部分完成
- **已解决**: build.zig 模块系统、I/O Threaded、ArrayList unmanaged、print 格式
- **遗留**: 部分模块（memory.zig, knowledge.zig 等）中的代码仍用旧 API 写法，实现时需逐个适配

## 待办事项

### Phase 2: 工具系统 ✅
- [x] comptime ToolRegistry 泛型
- [x] Bash 工具 (std.process.run)
- [x] FileRead 工具 (Io.Dir.readFileAlloc)
- [x] FileWrite 工具 (Io.Dir.writeFile)
- [ ] DiagnoseTool (Phase 5)
- [ ] ResearchTool (Phase 7) ✅
- [ ] 工具调用循环（需 LLM 接入后实现）

### Phase 3: 异步任务系统
- [ ] MPSC 无锁队列
- [ ] 线程池
- [ ] 事件总线
- [ ] 定时任务

### Phase 4: 持久化 + 记忆
- [ ] 下载 SQLite amalgamation
- [ ] 数据库封装
- [ ] 三层记忆系统
- [ ] 向量存储

### Phase 5: 运行时检测 + 自诊断
- [ ] 检测规则框架
- [ ] 内置规则
- [ ] SelfDiagnostic 引擎
- [ ] 错误反馈交互

### Phase 6: 反思 + 知识浓缩
- [ ] 反思引擎
- [ ] 经验提取
- [ ] phi 浓缩算法

### Phase 7: 多模型 + 网络搜索 + 优化研究 ✅
- [x] OpenAI/Ollama 后端
- [x] 网络搜索 API (Brave/SearXNG/DuckDuckGo HTTP client)
- [x] OptimizationResearcher (并发搜索 + φ 精选 + 方案对比 + 兼容性评分)
- [x] 知识图谱
