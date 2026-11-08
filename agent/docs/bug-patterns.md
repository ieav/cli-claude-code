# Ziv 缺陷模式库

> 条目格式见根目录 Claude skill `bugfix`。判别信号写前面——让未来的陌生现象能检索到。

### [双源状态分裂] 运行时状态与持久化配置各持一份，写一侧不同步另一侧

**判别信号**：UI 显示配置已改（菜单回显/文件已保存），但行为不变，重启后才生效——"配置生效慢"几乎都是这个
**触发条件**：门面读局部变量 A（如 `current_mode`），修改入口写结构体字段 B（如 `settings.permission_mode`），两者仅在启动时初始化关联
**机制**：ziv 权限门读 `current_mode`，`/config` 菜单只写 `settings.permission_mode`；甚至有一行"同步"代码同步的也是门面不读的第三个变量（`settings = switcher.settings`，死代码伪装成修复）
**排查动作**：`rg -n '<生效变量>'` 找所有读取点，逐个比对写入点覆盖的变量名——同名归一后才算闭环
**不变量（L3）**：**生效路径只允许一个事实源**。ziv 的做法：所有变更入口（/config、热重载）落地后立即 `current_mode = switcher.settings.permission_mode` 归一；更彻底的做法是权限门直接读 switcher.settings，消灭影子变量
**命中次数**：1（2026-10-28 /config 权限模式不生效）

### [配置仅启动加载] 长驻进程读一次配置文件，外部编辑永不生效

**判别信号**：用户抱怨"改了配置要重启才生效/生效慢"；进程无 crash 无报错
**机制**：`loadSettings` 只在 REPL 启动调用一次；用户预期是"文件即接口"
**修复模式**：每轮主循环开头做**内容指纹**（比 mtime 稳，touch 不误触发）比对，变化即重载 + 同步运行时状态 + 使受影响缓存失效（ziv：api key 变更 → deinit 对应 provider 缓存）。自身保存入口必须刷新基线，否则自我保存会被误判为外部编辑
**注意**：重载只覆盖"每轮现读"的字段；烘焙进会话历史的（system_prompt）需显式重建
**命中次数**：1（2026-10-28 settings.json 热重载缺失）

### [辅助任务内联阻塞] 低优先级后台任务在交互主路径上同步执行

**判别信号**：用户感知"偶尔随机卡顿"——不是每轮都慢，而是周期性慢（每 N 轮/每 X 分钟）
**机制**：反思引擎每 10 轮在回合末内联调一次 LLM `complete()`（无超时），窗口再小也付整次网络往返
**修复模式**：① 有意义性门控（窗口 < 3 条查询直接走启发式，跳过 LLM）② 耗时显性化（`[Reflection 320ms]`），把"神秘卡顿"变成"可见成本"，用户可归因
**护栏思路**：交互主路径上的任何网络调用必须带耗时输出——将来加 CI 检查：repl 主循环内新增 `complete(` 必须伴随计时打印
**命中次数**：1（2026-10-28 harness 偶发卡顿）

### [单行重绘假设] TUI 重绘只清光标所在物理行，内容却可能折行占多行

**判别信号**：输入超宽后每敲一键，屏幕上多出一整份"提示符+整行内容"的拷贝，指数式刷屏（用户贴屏的长文本重复几十次）
**机制**：`render()` 用 `\r\x1b[2K` 只清除光标当前物理行，但 prompt+内容超过终端宽度时自动折行占 N 行；下次重绘时光标停在末行，清除只覆盖末行 → 其余 N-1 行残留，新内容再往下溢出一份。光标定位 `\x1b[nD`（按列数后退）在多行布局下也失去意义（大多数终端在行首截断）
**排查动作**：数症状里的重复次数 ≈ 击键次数，即"每次重绘泄漏一份"——直接查重绘函数对终端宽度的使用
**修复模式**：块化渲染——记录上次绘制占用的物理行数与光标停靠行（`last_rows`/`park_row`），重绘前用 CUD（`\x1b[B`，不滚屏）逐行清除整块；内容按显示宽度软折行（宽字符不跨行拆）；光标按 (行,列) 单元定位。**不变量：render() 之外任何移动光标的输出（搜索行、Ctrl-C 提示）必须把块状态清零**，否则下次清除锚点错位
**护栏思路**：所有单行 UI（反向搜索行等）输出前必须按终端宽度裁剪——任何 autowrap 都是这个爆炸的起点
**命中次数**：1（2026-10-29 超宽输入刷屏）；同根因预防修复：反向搜索行裁剪

### [输出协议反噬输入编码] push 终端增强协议改变了既有按键的字节流

**判别信号**：开启某终端协议（kitty keyboard/modifyOtherKeys/鼠标上报）后，**没有直接关系的既有快捷键**集体失效——功能越基础越先被发现（Ctrl-C 退出），实际受害面是一整类（所有 ctrl+letter）
**机制**：kitty 协议 disambiguate（`CSI >1u`）开启后，终端把 Esc、alt+key、**ctrl+key** 全部改用 `CSI u` 编码（规范原文："ctrl+c will no longer generate SIGINT, but instead be delivered as a CSI u escape code"）。程序只为了 Shift+Enter（`13;2u`）push 协议，却没兼容它对其余键的重编码——Ctrl-C 变 `CSI 99;5u` 落进 unknown-sequence 的 `.ignore`
**排查动作**：push 协议后按协议规范核对**每一个既有键绑定**的新编码路径，而不是只测新功能；规范文档比终端实测更快给出全量清单
**修复模式**：反向映射层——`ctrlLetterByte()` 把 `CSI 97..122;5u` 还原为 C0 字节（码点-96），经 `injected` 字段**注入主循环原有分发路径**（单一事实源，零逻辑复制）。两个隐蔽配套点：① 双击检测窗口会被 CSI 引导字节（0x1b）在循环头重置——快照 `prev_cc` 在注入前恢复；② 搜索模式等"不能阻塞读下一字节"的上下文里，Esc 后面的 `[27u` 尾巴要用非阻塞 poll 吞掉并路由，否则被当文本插入
**护栏思路**：**启用任何改变输入编码的协议 = 同时接管全量按键翻译**；pty 测试若不解析协议输出序列，测的是"程序逻辑"而非"真实终端行为"——回归测试必须包含"按协议规范发 CSI u 序列"的伪终端场景
**命中次数**：1（2026-10-29 kitty 协议 push 后 Ctrl-C 退出失效，ctrl+letter 全量受害）

### [悬垂类型擦除指针] 值类型 toProvider() 返回指向自身栈帧的指针

**判别信号**：跨线程/延迟使用某 provider/接口对象时随机 Segfault（0xAAAAAAAA 地址=Debug 毒化），同代码主线程立即使用却"正常"——**不是并发问题，是栈帧生命周期**
**机制**：`var p = ProviderImpl.init(...); return p.toProvider();` —— 类型擦除指针指向栈上 `p`，函数返回即悬垂。主线程恰好快用完没踩坏；子线程/延迟路径必炸
**修复模式**：调用方持有存储——`ProviderStorage` union（按 backend 分支）由调用方分配并存活整个使用期，`makeProviderInto(ctx, io, &storage)` 返回的指针绑在存储上。**判别口诀：任何 `toProvider`/类型擦除返回前，问一句"被指对象活多久"**
**命中次数**：3 处（ziv 反思后台、子代理派发、探针误判连环——它曾是"并发挂死"的头号假凶）

### [资源生命周期 < 功能承诺边界] raw mode 只在提示符窗口持有，回合中编辑器裸奔在 cooked+echo 上

**判别信号**：TUI 输入区出现 **caret 记法字面文本**（`^[[C`、`^R`）——这是 tty 驱动 ECHOCTL 回显的特征，程序自己写 ESC 字节到终端只会被当转义序列吃掉、显示不出 `^[`。看到 caret 记法 = 驱动在回显 = 程序没在 raw 模式 = **查 termios 生命周期，别查按键解析代码**
**机制**：raw mode 由 `readLine()` 内的 RawGuard 进入、return 时恢复——所有权锚在"读一行"上。而事件循环承诺"回合期间输入框全功能在线"（v0.7.0），编辑器跨过了这个生命周期边界：整个回合 tty 是 cooked+echo，tty 驱动与 TUI 抢键盘职责——驱动实时回显（控制键 caret 记法）、行缓冲不交付（编辑器按不到键）、行编辑吃掉 0x7f/Ctrl-R。中文正常（驱动透传多字节）加剧了"部分键坏部分键好"的迷惑性
**排查动作**：ziv 运行中另开终端 `stty -a -f /dev/ttysNNN`——`icanon echo echoctl` 即实锤；pty 复现用 `pty.fork()`（subprocess 继承不到控制终端，`/dev/tty` 会报 not configured）
**修复模式**：**所有权上移**——repl.run 持会话级唯一 RawGuard（defer 恢复 + 信号兜底归最外层 guard，嵌套 guard 不得覆写信号恢复槽）；readLine 只做 tty 检测不再碰 termios；回合中的 y/N 确认读取用 CookedGuard（ICANON+ECHO+ICRNL）临时回 cooked——raw 下 Enter 是 `\r`，streamDelimiter 等 `\n` 会永久阻塞且用户盲打
**不变量（L3）**：任何"承诺跨阶段可交互"的输入功能，其依赖的终端模式必须覆盖同一时间窗——功能承诺的边界 ≥ 资源持有的边界，否则中间的缝就是两个编辑器打架的战场
**护栏思路**：新增任何 stdin 读取点前先问"此刻谁持有 termios"；pty 回归测试探针（`/run Bash {"command":"stty -a -f /dev/tty"}` 断言 `-icanon -echo`）
**命中次数**：1（2026-11-06 回合中输入区乱码 ^[[C/^R，用户两轮上报；同日终端写互斥锁是相邻但独立的机制——输出交错 vs 输入回显）

### [机制] history 内容块塞字符串字面量 → 延迟到 free 才炸 bus error

**判别信号**：测试在清理 defer 处 bus error（地址落在 rodata 段、
memsetSmallPowerOf2 栈帧），业务断言全绿；地址低 12 位跨运行稳定
**触发条件**：测试夹具（或任何代码路径）把 `.{ .text = "LITERAL" }`、
`.tool_use_id = "t0"` 这类**字面量**直接塞进 `llm.ContentBlock`——
history 的所有权纪律是"块内一切字符串堆分配"，freeContentBlocks
无差别 free，字面量指针不是堆 → 崩
**机制**：崩溃点（free/defer）与污染点（构造）相距整个测试体，
栈帧指向 freeContentBlocks 而非夹具——方向性极强地误导排查
**排查动作**：见 `.text =>`/`.tool_result` free 崩溃先查夹具里
所有 ContentBlock 字面量；`rg '\.text = "' 测试代码`
**不变量（L3）**：进 history 的 ContentBlock 字符串一律
`try alloc.dupe(u8, ...)`——2026-11-06 P2 验收测试连踩两次
（"SYSTEM" 与 "t0"）
**命中次数**：2（2026-11-06 P2 单测夹具、P2 e2e 夹具）

### [鼠标上报劫持框选] TUI 启用 SGR 鼠标上报后终端原生选择复制失效

**判别信号**：用户反馈"界面里不能鼠标选中复制文本了"——终端应用一启动，拖拽变成无选区/乱反应
**触发条件**：输出 `\x1b[?1000h\x1b[?1006h`（SGR 鼠标上报）后，终端把点击/拖拽事件发给应用，不再做原生文本选择；macOS Terminal.app 无 Shift 拖拽旁路，用户彻底失去复制能力
**机制**：鼠标上报协议与原生选择互斥——这是协议语义，不是终端 bug
**修复模式**：**TUI 默认永不启用鼠标上报**（P4c 已整体回退，git 历史留档）；点击类交互用键盘等价物（Ctrl+O 折叠展开、/last 查全文）替代。若未来确需鼠标，必须默认关 + 配置显式开启，并在开启时提示复制路径
**不变量（L3）**：ziv 会话生命周期内 stdout 不得出现 `?1000h`/`?1006h`；ESC 序列吞除逻辑保留（防外部工具残留状态注入垃圾字节）
**命中次数**：1（2026-11-07 P4c 上线当天用户报障，回退于同日）

### [pty 时序] /run 收尾窗口到达的输入被静默丢弃

**判别信号**：脚本/pty 驱动 ziv 时，前一条 /run 的输出已出现、紧跟发
的下一条命令毫无回显（进程活着、文件没写）——像「命令被吞了」
**触发条件**：/run 打印完输出后到提示符完全重画之间（op_log 落盘 +
flush + 区域协议重排）有一个输入不读窗口；bulk 输入整段丢失
**机制**：read_until 匹配到输出片段 ≠ 回合真正结束；编辑器在窗口内
不消费输入
**排查动作**：脚本侧每步 /run 之后先 `read_until(提示符)` 再发下一条
（pty_suite S18 的 run_and_wait 即此纪律）；别先怀疑 ziv 功能坏了
**不变量（L3）**：pty 套件里任何「输出匹配后立即发下一条」的写法都是
未来抖动（S6/S10 历史抖动同源）；新场景一律 run_and_wait 模式
**命中次数**：1（2026-11-08 S18 开发中连续复现 3 次）→ 已在套件固化

### [C 交叉编译] 严格 -std=c 隐藏 POSIX 声明——本机绿、musl 炸

**判别信号**：`call to undeclared function 'fdopen'`（或任意 POSIX 函数）
+ `incompatible integer to pointer conversion ... FILE *`——只在交叉
linux-musl 报，macOS 本机构建/测试全绿
**触发条件**：vendored C 依赖带 `-std=c11` 这类严格 ISO 标志，而代码
调 POSIX/BSD 扩展（fdopen/kill/…）；macOS libc 头宽松暴露这些符号，
musl/glibc 在严格 ISO 下按标准隐藏
**机制**：-std=cNN 请求纯 ISO 环境 → libc 头按 `_POSIX_C_SOURCE` 等
feature macro 裁剪；BSD（macOS）不裁剪 → 平台间行为分裂
**排查动作**：报错函数名查 man 页所属标准（fdopen=POSIX）；看 build
里给该 C 源的 -std 标志
**不变量（L3）**：vendored C 一律 `-std=gnu11`（或按需
`-D_POSIX_C_SOURCE=200809L`）；**新增 C 依赖落地时必须跑一次四目标
交叉构建**（release.sh 的构建段），本机绿不算数
**护栏（L4）**：候选——发版脚本前移为 CI/预提交检查（四目标
zig build ~4 分钟并行）
**命中次数**：1（2026-11-09 tree-sitter 入库次日发版炸）→ 不变量已落
build.zig 注释

### [Zig 所有权] ToolResult.output 静态字面量 → free 只读段 → 迟到的段错误

**判别信号**：进程 SIGSEGV 崩在与毛病无关的位置（实测崩在 utf8proc 宽
度计算），故障地址解出来是被复用内存里的普通字符串（本例 "approved"）；
且 defer/cleanup 全没跑（后台进程成孤儿）
**触发条件**：工具 execute 的参数校验分支 `return .{ .output = "字面量" }`
——output 进 history 后被 freeContentBlocks 无差别 free，静态指针 =
分配器元数据损坏，崩点随机漂移在后续任意分配
**机制**：history 的所有权纪律是"块内一切字符串堆分配"；字面量在
.rodata 段，free 它是 UB（macOS 上常静默腐蚀，偶发段错误）
**排查动作**：崩溃报告故障地址按 ASCII 反解；`rg '\.output = "' src/`
扫存量
**不变量（L3）**：工具的一切返回 output 一律 `alloc.dupe`（OOM 兜底
error.OutOfMemory 或空串——free() 对零长 no-op 是唯一豁免）
**护栏（L4）**：registry.zig 的 guard 测试扫 src/tools + src/turn 源码，
新写字面量输出直接挂 `zig build test`
**命中次数**：1 次用户实崩（2026-11-09 v0.9.0 多 agent 场景）+ 存量
36 处同类（含 2 天前新写的 bg_task 5 处——证明人工纪律挡不住再生）
→ 已上护栏
