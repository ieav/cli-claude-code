# ziv Harness 效率批次（P5）— 计划与落地记录

> 源起：2026-11-08 与 CC/Codex 官方工具面的差距分析——ziv 缺的不是工具
> 种类，是「**不阻塞**」（后台执行）与「**不打断**」（前缀/缓存稳定）。
> 本批次为该分析的 MVP 落地（M1/M2/M3），P1 及以后见 §5。

## 1. 批次范围（MVP）

| 模块 | 内容 | 状态 |
|---|---|---|
| M1 后台任务 | Bash `run_in_background` + `/bg` 面板 + 零孤儿退出 | ✅ |
| M2 WebFetch | URL→Markdown（512 KiB 帽 / 30K 字符预算 / 透明解压） | ✅ |
| M3 前缀稳定 | φ 起始阈值 61.8%→75% + 摘要温度 0 + `/stats` 观测 | ✅ |

## 2. 落地要点与设计偏差（As-Built）

- **M1**：捕获语义与前台 Bash 对齐（内存 ≤256 KiB 帽），任务结束时一次
  性落盘 `.ziv/tasks/<id>.log`——不做逐块落盘（省掉流式文件写复杂度；
  代价：kill -9 ziv 时日志丢失，可接受）。8 槽环形，全满拒绝并提示。
  - **命名偏差**：`/tasks` 已被 TaskCreate 待办占用 → 后台任务面板用 **`/bg`**。
  - 生命周期**跟会话**：ziv 退出 → cleanup 钩子杀全部任务进程组
    （S5 收割语义推广，pty S13 断言零孤儿）。
  - 锁：std.Thread.Mutex 在 0.17 已移除——沿 provider.zig 的原子自旋锁惯例。
- **M2**：转换器手写流式（A10 矩阵 4.85 vs C 库绑定 3.50，零新依赖）；
  `response.reader()` 只许调用一次（断言），解压沿 knowledge/search 的
  魔法字节嗅探（有服务器不带 Content-Encoding 也发 gzip）。
  - **超时偏差**：计划写 8s 硬超时；实际 std.http.Client 高层路径无逐
    请求 deadline，且 CC 语义为 5 分钟宽限——ziv 同样不做人为硬限，
    尺寸帽（512 KiB）+ 传输错误自然浮出。
  - 权限与 WebSearch 同级（is_read_only，ziv 既有口径）；要收紧加
    `WebFetch` deny/ask 规则（规则模式可匹配 URL 内容）。
- **M3**：阈值上移后触发频次约降 40%，emergency 92% 梯子与收敛不变量
  测试原样兜底；摘要调用温度归 0；`applyHybridLayout` 字节确定性有
  单测锁定。`/stats` 新增 `Compaction: N passes, ~M tokens reclaimed`。

## 3. 验收（全部已过）

- 单测 357 pass / 5 skip / 0 fail（新增：html_md ×4、bg_tasks、
  budgetLine、applyHybridLayout 确定性；梯子矩阵更新至 75% 起点）
- pty 13/13（新增 **S13**：后台立返 → /bg 列表 → 停止 → 被杀状态 →
  退出零孤儿）
- WebFetch 真网：example.com（gzip）→ MD 可读；404 → `HTTP 404` 报错行

## 4. 防回退锚点

- S13 锁定后台三 invariant：立返不阻塞、面板可停、退出零孤儿
- 收敛不变量测试锁定 75% 起点不撑爆（12 轮压测 <4200 tokens）
- ToolRegistry count = 13（WebFetch 入册）

## 5. 后续迭代（触发条件）

- **M3.1 cached_tokens 观测**（2026-11-09 计划外补入，源于 M3 验证需求）：
  provider 解析 `prompt_tokens_details.cached_tokens` → 累计 → `/stats`
  显示命中率——M3 的效果从「感觉」变「数字」。实测网关自动前缀缓存
  存在（同前缀第二次调用 1984/2019 tokens 命中）。
- **P1**：M4 子代理深度（原触发「M1 稳定一迭代」，2026-11-09 用户提前
  启动）——**已完成**：`agent` 工具新增 `tools`（白名单，只能收窄）/
  `fork`（继承会话尾部 ≤16K tokens，只读借用）/ `max_turns`（1-10）。
  **后台化明确延期**：需要异步结果回送基建（回合循环同步等待工具返
  回），M5 Workflow 基建落地时一并做——并行 fan-out 已覆盖效率收益。
- **M7 `-p` 非交互**——**已完成**（2026-11-08）：`ziv -p "提示"` 一发即
  走（复用 subagent 无头循环，正式 system prompt + 用户权限规则 +
  agent_loop_limit；stdin 管道模式；退出码区分成败；S16 验收）。
- **M6 Hooks（Pre/PostToolUse 简版）**——**已完成**（2026-11-08）：
  settings.json `hooks.PreToolUse/PostToolUse`，matcher 精确/空=全部，
  /bin/sh -c + 10s 超时 + exit 2 阻断；三个工具执行口统一
  （orchestration 波次 / subagent 无头 / /run 直达）。S17 验收。
- **③ tree-sitter 里程碑 1（编辑后语法校验）**——**已完成**（2026-11-08）：
  vendor 核心 + 六语法（py/js/ts/tsx/java/zig，deps/tree-sitter/）；
  FileEdit/FileWrite 落盘后重解析，首错（ERROR/MISSING）附警告行，
  模型当场自纠。里程碑 2（符号级索引进 FTS5 旁路）、3（按需语法加载）
  待排。S18 验收。
- **M5 Workflow 脚本化**——**spike 已出**（2026-11-08，docs/workflow-spike.md）：
  原触发条件（≥2 个重复性多 agent 流程）未变，语法定稿等真实用例喂
  参数；实现仍候触发。
- **条件触发**：元诊断置信度——诊断结论进入自动消费链路（自动触发/
  喂给恢复决策）时才值得上；当前 /diagnose 人读报告，溯源行+
  [实测] 行已承担该职责（2026-11-10 用户裁定跳过）
- 持续不做：沙箱、LSP、多端、云任务（单人维护成本错配）
