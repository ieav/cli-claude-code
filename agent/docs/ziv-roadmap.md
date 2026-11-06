# ziv 补齐路线图（2026-11-06 制定）

> 背景：2026-11-06 稳定性批次（14 项修复，`bdf9d47`..`6109b56`）后的对账结论——
> harness 侧已达设计水位，差距集中在：结构（repl 巨石）、上下文、会话恢复、
> 自学习深度、检索、生态。本图把「4 项建议 + 7 项缺点 + 4 项未兑现设计」
> 合并为 9 个工作项、7 个 Phase，含验收标准与代码锚点。

## 条目合并对照

| 原条目 | 归入 |
|---|---|
| 建议1 DESIGN 对账 | P1 |
| 建议2 / 缺点2 拆 repl.zig | P1 |
| 建议3 / 缺点5 pty 测试自动化 | P0 |
| 建议4 / 缺点1 / 设计D1(RoPE) / D2(回放+图谱扫描) | P5 |
| 缺点3 / 设计D4(hybrid 压缩) | P2 |
| 缺点4 RAG/索引 | P6 |
| 缺点6 会话恢复 | P3 |
| 缺点7 生态 | P7 |
| 设计D3(自动修复+交互错误) | P4 |

## 总原则

1. **安全网先于结构，结构先于功能**：先有 pty 回归网，才敢拆 7000 行巨石；拆完再做功能
2. 每个 Phase 有**可判定的验收**，完成即提交，不留长活分支
3. 行为零变化的纯重构（P1）与行为新增（P2+）分开提交

---

## Phase 0：安全网 — TUI pty 测试自动化（0.5–1 天）

**问题**：TUI 交互层（终端模式、并发写、cooked/raw 切换）今天靠手工 pty 探针验证，
输入层每次改动都在赌。单测 325 个盖不住这一层。

**内容**：`scripts/pty_suite.py`——场景化伪终端回归套件（今天 /tmp/pty_probe.py 的泛化）：

| 场景 | 断言 |
|---|---|
| S1 raw 会话 | `/run Bash stty -a -f /dev/tty` 输出含 `-icanon -echo`（会话级 raw） |
| S2 回合中按键 | `sleep 2` 期间发 `\x1b[C` + 文本，输出**不含** `^[[C` 回显 |
| S3 /last 展开 | `/run echo` → `/last` 输出全文（含 /run 路径） |
| S4 y/N cooked 读 | FileWrite 产生检查点 → `/rewind` → `Proceed? [y/N]` 发 `n\r` → `Cancelled`（Enter 可终止、有回显） |
| S5 退出清场 | 挂起中 `/quit` → 子进程组全灭（`pgrep` 断言） |

**验收**：`python3 scripts/pty_suite.py zig-out/bin/ziv` 全绿；写入 USAGE 测试节。
**依赖**：无。**这是所有后续 Phase 的前置。**

---

## Phase 1：结构 — repl.zig 拆分 + DESIGN v2（2–3 天）

**问题**：repl.zig 7002 行，回合状态机/流式聚合/工具批次/斜杠命令/交互读取全部内联——
今天 4 处 CookedGuard 漏 2 处、liveQueueSubmit 漏锁，都是巨石上下文过长的直接代价。

**拆分方案**（行为零变化，纯移动 + 最小接口）：

```
src/repl.zig        ≤2000 行：REPL 主循环、命令分发、会话装配
src/turn/mod.zig    回合状态机（TurnClock 已在 util/turn_clock.zig，补齐状态封装）
src/turn/stream.zig StreamJob + StreamAgg + streamCb（现 repl.zig 3700-4100 区域）
src/turn/tools.zig  ToolJob/executeBatches 接线/finishToolCall/printToolBody（现 4400-4700 区域）
src/turn/ask.zig    AskUserCtx/askUserExecute/permissionGate/CookedGuard 读取件
src/commands.zig    斜杠命令表（现 760-1300 区域的分发链）
```

**DESIGN v2 对账**：DESIGN.md 头部加「现状对账表」——已兑现/超额/未兑现三项，
未兑现项（RoPE、经验回放、π 图谱扫描、自动修复引擎）标注指向本路线图 Phase。

**验收**：repl.zig ≤2000 行；325 单测 + pty 套件全绿；`git diff` 审查确认无逻辑变化。

---

## Phase 2：上下文管理 — hybrid 压缩 + 工具结果瘦身（2–3 天）

**问题**：φ 截断（丢最旧）+ LLM 摘要两档太原始；644K token 回合真实发生过；
无智能选材。设计 D4（hybrid）一直占位未实现。

**内容**：
1. **hybrid 压缩**（补 `llm/compaction.zig` 的 `.hybrid`）：旧段 LLM 摘要 +
   最近 K 轮**原文保留** + 工具结果降级（见 2）三段式——摘要不再是全有全无
2. **工具结果瘦身**：>4KiB 的 tool_result 在**历史**中替换为头部 1KiB +
   `[截断，完整输出 N 字节]`（显示层今天已全文；历史层瘦身省的是 token）
3. **压缩可观测**：压缩前后 token 数进 trace（已有）+ 状态行提示

**验收**：构造 20 轮长对话，hybrid 后保留最近 5 轮原文且总 token < 40%；
单测锁定三段边界；agent_e2e 补一条 hybrid 用例。

---

## Phase 3：会话恢复（2 天）

**问题**：对话历史随进程走，/quit 或崩溃即失——只剩记忆提取和 trace。

**内容**：
1. `.ziv/sessions.db`（SQLite）：每轮结束原子追加消息（复用 storage/database.zig）
2. `/resume` 命令：列出最近会话（时间/轮数/首句）→ 恢复 history + 权限模式 + 模型
3. 崩溃恢复：启动时检测未正常关闭的会话提示恢复

**验收**：/quit → 重启 → /resume 恢复完整对话（含工具结果块），续问上下文连续；
杀进程后恢复路径同样成立。

---

## Phase 4：交互补完 — 错误选择器 + 首批自动修复（1–2 天）

**问题**：设计 §五「用户选择如何处理」只做了单向展示（分类+编号建议），无交互。

**内容**：
1. LLM/工具错误后出**交互选择器**（复用 menu.zig 按键循环 + CookedGuard）：
   `[1] 重试 [2] 自动压缩后继续 [3] 换模型 [4] 忽略`
2. 首批 auto-fix 动作实装：429→退避重试、ContextOverflow→自动 /compact、
   NetworkTimeout→指数退避重试（TTFT 已有，统一收口）
3. `/config` 挂「自动修复策略」开关

**验收**：注入 mock 错误（agent_e2e 模式）出选择器且选项真实生效。

---

## Phase 5：自学习深化（3–5 天，设计 D1+D2 的真身）

**问题**：「自学习」名实差距——关键词提取、罐头洞察、64 维词袋向量。

**内容**：
1. **RoPE 旋转编码**（设计 §一原案）：嵌入存储时按维度旋转
   `rot[d] = vec[d]*cos(πd/D) − vec[d+1]*sin(πd/D)`——纯数学改造，零依赖，
   替换 `memory/episodic.zig` 的 hash 词袋；先离线对比检索质量再切换
2. **经验回放**：反思触发时从查询窗口全史 π-均匀采样（非仅最近 20 条），
   `memory/reflection.zig` 的窗口装配改为环形采样
3. **π 周期图谱扫描**：cron 挂 `knowledge/graph.zig` 的孤立节点/断边检测，
   报告进 /knowledge
4. **洞察质量门**：启发式洞察入库前，provider 可达时经一次 LLM 校验
   （expected_stop 治标的下一步：防误诊入库）

**验收**：新旧嵌入检索对比（人工抽检 20 条记忆命中相关性）；误诊洞察零入库
（回归：今天的事例场景）；图谱扫描报告可见。

---

## Phase 6：检索层 — 代码索引（3–4 天）

**问题**：工具是 glob/grep 裸搜，大仓库每次问答全量扫，无索引无沉淀。

**内容**：
1. `.ziv/index.db`：SQLite FTS5 文件内容索引；FileRead 成功结果沉淀入索引
2. Grep 双路：索引命中优先 → rg 实扫兜底（结果回写索引）
3. 上下文注入改为**按当前问题相关性检索**代码片段（与记忆注入同一管线）

**验收**：同一大仓库问答任务，第二次工具调用次数明显下降（trace 对比）；
索引过期策略（mtime）单测。

---

## Phase 7：生态（按需独立排，各 2–4 天）

1. **MCP stdio 深层 spawn**：修复 npx 系握手（PTY 中转或 env 注入方案）
2. **子代理 DAG**：agent 工具 tasks 支持依赖声明（`depends_on`），拓扑序执行
3. **多模态**：图片输入（Claude/OpenAI vision），FileRead 图片 → base64 内容块

---

## 执行顺序与当前状态

```
P0(安全网) → P1(结构) → P2(上下文) → P3(恢复) ∥ P4(交互) → P5(自学习) → P6(检索) → P7(生态)
   ↑ 今天可开始
```

| Phase | 状态 |
|---|---|
| P0 | ✅ 完成（2026-11-06，`scripts/pty_suite.py` 五场景全绿 + 旧二进制红灯验证；用法 `python3 scripts/pty_suite.py zig-out/bin/ziv`） |
| P1 | ✅ 完成（2026-11-06，`5119177`..`18bbe9b` 共 9 步）：repl.zig 7103 → **1835 行**（验收 ≤2000 达成）。拆出 turn/{stream,ask,tools,history}、session/{memory_ops,model_switcher,input_history}、commands/{config_menu,history_cmds,dispatch}；终局为 ReplCtx（37 字段指针联动 run() 状态）+ dispatchSlash（622 行命令树函数化，四态 outcome 驱动循环）。每步双判据（325 pass / 5 skip 基线一致 + pty 五场景全绿）+ 纯度脚本校验 |
| P2 | ✅ 完成（2026-11-06，`de3fd07`）：hybrid 三段式（老段 LLM 摘要 + 最近 5 轮原文 + 工具结果瘦身）落地 llm/compaction.zig + turn/history.zig；/compact 升级 hybrid、自动路径 phi+slim；验收三条全过（20 轮单测 <40% token、hybridSplit 边界锁定、agent_e2e mock 网关全链路）。套件 329 pass / 5 skip + pty 六场景（P1 收官补 S6 命令走查） |
| P3–P7 | 待开始 |

> P0 红灯基线：修复前二进制（会话 raw 改造前）在 S1/S3 失败——套件对终端
> 模式回归有判别力。注意 S5「会话退出清场」原设计场景在无 LLM 的 pty 环境
> 下不可构造（/run 同步执行挂起时主循环读不到 /quit），已降级为「持管者
> 收管」端到端；真退出清场待 P1 拆分后经 mock agent-loop 通路补。
