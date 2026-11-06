# ziv TUI 事件循环重构 — 开发计划

> 2026-11-01 立项。目标：把 ziv 的输入/显示层对齐 Claude Code / Codex 的三条缺失原则。
> 版本落点 0.7.0。原则四（Enter=排队 / Esc=中断）语义不变，本计划不动它。

## 进度快照（续作会话从这里接手）

- **Phase 0 ✅**（2026-11-01）：ReadRig 端到端 harness（真 Io + /dev/null + Reader.fixed）+ 5 个行为锁测试。
- **Phase 1 ✅ 核心完成**（2026-11-01，分支 `tui-event-loop`，299/304 测试绿）：
  - `Editor` 常驻：`live_ed` 全局 + 惰性创建（readLine 首调）；`editorDeinit` 收尾；nav/draft 状态入 Editor 字段；`takeLine/clearForNewDraft/releaseSlots` 提交协议
  - `editorLiveKey(r,w)→bool` 生成期按键泵：同一 Editor 全功能编辑（方向键/Home/End/Delete/Ctrl 编辑键、历史 ↑↓）；Enter=排队（`liveQueueSubmit`，复用 queued_msgs）；Shift+Enter=光标处换行；粘贴增量进缓冲；仅 Esc/Ctrl-C 取消
  - 删除：pending 全套 / typeahead / escProbe / escProbeOne / feedLiveByte（约 300 行）
  - `writeInputRow`/区域可见性改读 `liveDraft()`（编辑器缓冲，单行尾巴视图，P3 换全块）
  - `stream_interrupt.waitSlice`：ESC 分类三态（cancel/newline/drop——方向键静默期安全丢弃，P2 由 UI 循环接管后消失）
  - repl.zig：streamCb 的 esc 探测与 .live_input 改走 editorLiveKey + live_spool
  - **P1 未竟（P2 一并处理）**：waitSlice 静默期方向键仍是 drop（非编辑）；多行草稿生成期单行显示
- **Phase 2 ✅ 核心完成**（2026-11-01，299/304 绿）：
  - `StreamJob`（repl.zig，streamComplete 前）：pump 线程跑 `prov.stream`，事件深拷贝（delta dupe / tool_call 三字段+JSON 树 dupeJsonValue）入 `BoundedMPSC(StreamEvent,1024)`；满队 1ms 退避（TCP 背压等价）；`done`/`err` release/acquire 配对；`cancel` 原子标志
  - `streamComplete` UI mini-loop：drain 队列→streamCb（纯事件处理）→ poll stdin 100ms→editorLiveKey（取消则置 cancel）→ 静默 tick；isDone 收尾；线程 spawn 失败退回同步泵
  - provider API：`esc_interrupt: bool` → `cancel_flag: ?*atomic bool`；`StreamEvent.live_input` 删除；streamCb 的 esc 探测门与 esc_probe_r/last_esc_check 字段删除
  - `stream_interrupt.zig`：纯 socket 轮询（ready/tick），stdin/ESC 分类全部删除——**stdin 现在只归 UI 线程，方向键静默期不再丢**（P1 遗留项解决）
  - `time.zig sleepMs` 改 nanosleep（std.time.sleep 在 0.17 没了，惰性编译才暴露）
  - 线程边界：pump 线程只碰 socket/queue/provider；UI 线程独占 stdin/终端/Editor；provider.zig setErrorDetail 全局由 done-acquire 保证可见性
  - **未做**：真机 TTY E2E（本会话无 TTY）；工具执行仍占主线程（Phase 4）
- **Phase 3 ✅**（2026-11-01）：**DECSTBM 滚动区协议**（比行 diff 更简单且更彻底）：
  - `regionApply`：`\x1b[1;{H-2}r` 分屏（1..H-2 转写区滚动，H-1 状态行 + H 输入行**绝对定位钉底**）；`region_h` 缓存做 resize 检测（每次打印/刷状态时比对，变了重设边界）
  - `regionPrintLine`：光标定位到转写区底行打印，区域滚动——**钉底行永不为转写增长清屏重画**（旧协议每行清两行重画两行的闪烁结构性消灭）；region 未挂时纯透传
  - `regionFreeze`：`✓ 完成 · in/out` 汇总**滚入转写**成为末行（D6），再复位区域
  - `force_height` 测试钩子；协议测试重写为 DECSTBM 不变量（分割序列、钉底行不被清、状态/输入行独立重画）
  - 顺带修复：liveQueueSubmit 的"已排队"闪现改由 `paintStatusRow` 绘制（renderPendingLine 只画输入行）
  - **已知取舍**：区域挂起时转写"钉底锚定"（CC 风格——对话短于屏幕时中段留白）；多行草稿生成期仍单行尾巴显示（P3b 全块渲染未做，草稿内容完整、回提示符即全量显示）
- **Phase 4 ✅**（2026-11-01）：工具批次跑 worker 线程（ToolJob + done/err 原子），UI 循环在下持续可用：长 Bash 期间全功能编辑 + 状态行**每 500ms 活钟**（`⚙ 工具 X · 回合 Y.Ys`）。AskUserQuestion 含交互 stdin 读——检测到即走同步回退（避免与 UI 循环抢 fd 0）。Esc 在工具期无效果（工具不可取消），被编辑泵消费不泄漏
- **Phase 5 ✅**（2026-11-01，除发版外）：死代码清扫（stream_at_line_start / escProbe 家族 / pending / typeahead）；USAGE.md 输入章节重写（v0.7.0 全功能在线、编辑键永不取消）；版本 0.7.0；299/304 测试绿、zig fmt 合规（无关文件未动）
- **P3b ✅**（2026-11-01 下午，用户点名）：生成期多行草稿**全块渲染**——`blockRows()` 按软折行算块高（宽字符不拆行、尾部窗口 MAX_LIVE_BLOCK_ROWS=6 + `↟ +N 行`标记），块高变化自动重设 DECSTBM；`writeEditorBlock` 绝对定位逐行绘制（行 0 带 prompt 身份）；行为锁测试 + 真 pty + ReleaseFast 验证。空草稿=1 行的 off-by-one 与起始值 bug 均被测试抓出修正。
- **卡死根因修复**（2026-11-01 晚，keep-alive mock 复现定位）：**P2 的空闲轮询在 headers+body 同 TCP 段到达时饿死**——body 已进连接级缓冲，`resp_reader.bufferedLen()==0`（只看外层 buffer）→ poll 内核 socket（空）→ tick 到 180s 看门狗 = 用户"两分多钟"。真网关秒回必同段，必现。**修法（架构正确化）**：pump 线程回归**阻塞读**（`peekGreedy`，缓冲语义天然正确），取消改为 UI 循环 `shutdown(2)` 已发布的连接 fd（`CompleteOptions.cancel_fd`，看门狗同款技术）；pump 不再需要任何轮询；`stream_interrupt.zig` 整个删除；TTFT 由看门狗子期限覆盖（headers 30s 杀→FirstByteTimeout 重试），Esc 取消映射在 job.err 与 saw_error 两路补齐。
- **排队可见性修复**（同日）：排队消息在**入队瞬间**以品红提交样式 + 暗色 `↳ 已排队` 标记滚入转写（`liveQueueSubmit`）；`queued_echoed`/`last_take_echoed` 标记防注入/自动发送时二次回显。
- **工具批次可取消**（2026-11-04）：P4 的"工具期 Esc 无效果"是最后一条卡死路径——`timeout: 0` 无限 Bash × 不可取消批次 = 回合永久卡住。修法三层：① `util/cancel.tool_batch_cancel` 会话级取消槽（UI 循环 Esc/Ctrl-C 置位，批次前重置）；② bash 看门狗常驻轮询取消（原 `deadline=0` 直接不启看门狗），取消即击杀整进程组，返回"cancelled by user"；③ `orchestration.executeToolCall` 执行前查槽——未启动调用短路为 "cancelled (not run)"，**每个 tool_use 仍有一一对应的 tool_result**（历史 API 合法性不变量），取消/部分结果入历史后回合优雅终止。顺带修复 worker 失败路径 `return e` 留下悬空 tool_use（严格 API 下次请求必 400）→ 补失败结果 + 优雅收回合。`agent` 派发桥接同一取消槽（workerMain 把 tool_batch_cancel 并入协作标志，在飞子代理下轮即停）。
- **T6.4 agent 工具默认开启**（2026-11-04）：P38 停摆复验以可执行 E2E 落地（`tests/agent_e2e.zig`，真 HTTP mock 网关 127.0.0.1）：happy 扇出（2 任务并发、2 round trip、合并报告完整）+ P38 停摆（网关收下请求永不答 → `ZIV_LLM_TIMEOUT_MS=1500` 短看护狗杀连接 → 快速失败重试再失败 → **派发仍限时返回合并报告**）。双绿后默认翻转为 ON（`ZIV_AGENT_TOOL=0` 退出）。
- **验证**：真 pty + HTTP/1.1 keep-alive 同段 mock + ReleaseFast：第一条回复 ✓、✓完成 ✓、排队消息转写可见 ✓、排队计数 ✓、第二请求全链路（5027B→5123B 两轮 REQ/RESP）✓；299/304 单测绿。

## 0. 三条原则 → ziv 的差距（现状锚点）

| 原则 | Claude Code / Codex | ziv 现状 | 差距根因 |
|---|---|---|---|
| ① UI 线程独占终端，I/O 不在 UI 线程 | Node 事件循环 / Rust UI 线程 + channel | `streamComplete`（repl.zig:1361 起）在主线程同步泵 SSE；工具批 `executeBatches`（repl.zig:1660 附近）也占主线程 | 泵流期间没人收键盘 → 只能靠 escProbe/waitSlice 在流的缝隙里偷字节 |
| ② 输入框常驻、永不下班 | 同一组件同一实例，全程全功能 | `Editor`（lineinput.zig:1022）只在 `readLine` 阻塞调用内存在；生成中是降级 pending 缓冲（append+退格，方向键=取消） | Editor 的生命周期绑定在阻塞函数上 |
| ③ 保留式渲染 + 差量重绘 | Ink reconciler / ratatui buffer diff | 带内光标体操：regionPrintLine = 清两行→上方打印→重画区域（lineinput.zig:707）；RegionWriter 靠约定保持光标锚点 | 屏幕没有"模型"，只有一连串转义序列 |

## 1. 目标架构

```
┌─────────────────────────────────────────────────────┐
│ UI 线程（主线程，唯一终端写者）                        │
│  while true:                                         │
│    poll(stdin, 事件队列, 100ms 定时)                  │
│    键盘 → Editor.key()      （常驻，全功能，永不下班） │
│    流事件 → StreamAgg（正文进转写模型）                │
│    定时 → 状态行（本轮/累计双钟）                      │
│    渲染 → 底部锚定保留区 diff 重绘                     │
├─────────────────────────────────────────────────────┤
│ StreamJob 线程（每回合一个）                          │
│  泵 provider SSE → 事件入队列（有界，满则背压）        │
│  Esc/Ctrl-C = 原子取消标志（不再自己轮询 stdin）       │
├─────────────────────────────────────────────────────┤
│ 工具线程池（现有 executeBatches 池）                  │
│  执行完投递 batch-done 事件，UI 不阻塞                 │
└─────────────────────────────────────────────────────┘

屏幕模型（Ink 式行内渲染，不进备用屏，保留终端回滚）：
  已提交转写行 —— 打印即滚动离场，终端 scrollback 托管
  底部保留区   —— [状态行] + [Editor 渲染块 N 行]，帧间 diff
```

### 关键决策（已定）

- **D1 不进 alternate screen**：Claude Code 也是行内渲染；用户要终端回滚能力。保留区只管屏幕底部可见部分。
- **D2 Editor 单实例常驻**：`run()` 持有一个 `Editor`，两个状态共用——idle（Enter=提交）与 generating（Enter=排队，沿用现有队列语义：≤4 条、轮间注入、回合末自动发送）。
- **D3 括号粘贴全程开启**：进程启动 push `?2004h`、退出 pop。粘贴=原子事件，含 ESC 字节的粘贴不再可能杀回合。粘贴折叠 pill 机制照搬现有实现。
- **D4 取消只认 Esc/Ctrl-C**：方向键/Home/End 等编辑键永远进 Editor，不再有"按错键杀回合"。
- **D5 RegionWriter（ow）保留，后端换血**：业务代码继续 `print(ow, …)`；drain 从"regionPrintLine 光标体操"改为"转写模型追加 + 请求重绘"。本次会话改的全部调用点零改动。
- **D6 in/out 回显保留**：回合末 `✓ 完成 · in N → out M · X.Xs` 从"冻结状态行"改为"追加转写行"，位置仍在转写末尾、下个 prompt 之前。信息一字不丢。
- **D7 非 TTY 路径字节级不变**：管道/脚本模式走旧 readLine 逻辑，现有测试锁死。
- **D8 权限 y/N 与 askUser 保持 cooked 模态读**：工具轮内短暂"借走"终端，状态行明示"等待用户确认"。后期再考虑编辑器化。

## 2. 分阶段计划（每阶段独立编译绿 + 测试过）

### Phase 0 — 护栏（0.5h）
- 为 Editor 现有关键行为补特征测试：多行提交、粘贴 pill 展开、历史回溯、Esc 撤回预填、非 TTY readLine 字节兼容。
- 验收：`zig build test` 全绿；这些测试在后续阶段全程不许改断言（只许改调用方式）。

### Phase 1 — Editor 常驻化（约 1 天）｜原则②
- `Editor` 从 `readLine` 内部构造改为 `run()` 持有；新增 `editor.key(byte)` 单键入口（把 readLine 主循环体拆成可从外部喂数的函数）。
- 回合期间键盘不再走 escProbe→pending，直接进同一个 Editor。
- 删除：`pending_buf/pending_len/pendingDisplay/pendingAppend/pendingBackspace/feedLiveByte/writeInputRow/pendingMergeIntoTypeahead/typeahead 合并路径`（约 200 行）。
- Enter 语义按回合状态分派；排队提交复用现有 `queued_msgs`。
- 键盘源此时仍来自 streamComplete 的轮询缝隙（Phase 2 才换源），但编辑能力已全程在线。
- 验收：生成中可移动光标/删中间字/粘贴 pill/翻历史；方向键不再取消；295+ 测试绿。

### Phase 2 — 网络泵下沉（约 1 天）｜原则①
- 新增 `StreamJob`：std.Thread 跑 provider 流读取，事件经有界 MPSC 队列（满=背压）回 UI 线程；`streamComplete` 主体改为"启动 job + 事件循环收尾"。
- UI 线程主循环：poll(stdin, queue 有数据标志, 100ms)——stdin 全程归 UI。
- 取消机制：原子标志。`waitSlice` 删掉 stdin 分支，只看 socket + 取消标志；claude/openai 的 pre-headers 等待同样只看标志。
- 删除：escProbe 的 stdin 轮询职责、stream_interrupt 的 stdin 监视、providers 里所有键盘回显回调（`live_input` 事件）。
- 约束：同一时刻仅一个 StreamJob（回合天然串行）；job 必须先 join 才允许 provider 切换/释放（ModelSwitcher 生命周期规则写注释）。
- 验收：网关静默 30s 期间可完整编辑输入（光标/粘贴/历史）；Esc 在任意阶段 200ms 内生效；TTFT/看门狗行为不回归。

### Phase 3 — 保留式渲染（约 1-1.5 天）｜原则③
- 新 Renderer：
  - `transcriptAppend(styled_line)` —— 提交即滚出保留区（一次性打印）。
  - 底部保留区 = 状态行 + Editor 渲染行集合；每帧重算，与上一帧做行级 diff，只输出变更行的 `\r\x1b[2K` + 重写（不用整屏 clear）。
  - SIGWINCH / 每帧 winsize 轮询：宽度变化触发全量重绘。
- RegionWriter.drain 后端换成 `transcriptAppend`（调用点零改动，D5）。
- 回合末：`✓ 完成 · in N → out M · X.Xs` 追加为转写行（D6）。
- 删除：`regionBegin/regionEnd/regionFreeze/regionPrintLine/regionStatus/clearPendingRegion/drawRegionRows/renderPendingLine/stream_at_line_start` 光标体操全套（约 250 行）。
- 验收：长回复期间底部两行不再闪烁（diff 只动变化行）；resize 后布局正确；转写内容零丢失（对照 Phase 0 特征测试）。

### Phase 4 — 工具异步化（约 0.5 天）｜原则①收尾
- `executeBatches` 改为投递 batch-done 事件，UI 循环期间工具跑在池上；长 Bash 期间输入区全功能 + 状态行实时跳秒（现有 P2 静态状态升级为活钟）。
- 权限 ask 路径按 D8 保持模态。
- 验收：60s Bash 运行中可打字/编辑/排队；工具状态行显示工具名+经过时间。

### Phase 5 — 清理与发版（约 0.5 天）
- 全库 grep 死代码（pending/typeahead/region 残留引用）；USAGE.md/DESIGN.md 输入章节重写；版本 0.7.0。
- 全量测试 + 真实网关回合（慢响应/工具/生成中编辑/排队/中断各一遍）。
- dist 产物：按仓库纪律，发版前向用户确认。

## 3. 删除清单汇总（"不能用直接删"）

| 删除项 | 行数约 | 替代 |
|---|---|---|
| pending 输入全套（lineinput） | ~200 | 常驻 Editor |
| typeahead 合并路径 | ~30 | Editor 连续存在，无需交接 |
| escProbe stdin / waitSlice stdin / pre-headers 键盘监视 | ~120 | UI 主循环收键盘 + 取消标志 |
| region 光标体操 API | ~250 | 保留区 diff 渲染 |
| `live_input` 流事件 | ~20 | 不再需要（UI 直接得键） |

**保留**：Editor 主体与渲染算法、粘贴 pill、Ctrl-R 搜索、历史、排队语义（queued_msgs/轮间注入/自动发送）、TTFT/看门狗、RegionWriter 调用点、`✓ 完成 · in/out` 回显、非 TTY readLine、双钟状态行。

## 4. 风险与对策

| 风险 | 对策 |
|---|---|
| provider/StreamJob 生命周期竞争（切换模型时 job 还在跑） | 回合串行 + join 后才允许 switcher 变更；switcher 操作只在 UI 线程 |
| 有界队列死锁（UI 阻塞在权限 y/N 时 job 塞满） | 权限询问期间 job 继续入队 → 满则 job 阻塞在 push（SSE 自带 TCP 背压，无害）；队列容量 512 |
| 行级 diff 在宽字符/emoji 边界的列计算 | 复用现有 strWidth/charWidth；diff 按行整体比对（不做半行 diff），规避列级陷阱 |
| SIGWINCH 与打印竞争 | winsize 每帧轮询（ioctl 便宜），不装信号处理器 |
| 回归范围大 | Phase 0 特征测试锁行为；每阶段独立绿；分支上做（tui-event-loop） |

## 5. 提交策略

按用户 git 纪律：每阶段一个完整提交（阶段=问题单位，文件集完整、可独立 checkout 编译），共 5-6 个提交；不混入 dist 产物。
