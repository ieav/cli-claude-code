# ziv TUI 架构——状态机、写者与不变量（v2，2026-11-09）

> 源起：用户四项诉求——①输入区独立成区 ②命令退出后无残留 ③显示控制
> 有框架逻辑 ④信息呈现像 CC 一样有条理。此前四类事故（"uit" 事件、
> S6 抖动、/resume 吞输入、历史 diff-preview 类）同属一族：屏幕没有
> 统一仲裁。本文是修复的完整逻辑模型。

## 1. 现状模型（问题所在）

**屏幕状态（隐式，无状态机）**：
- `TURN`：region 武装（DECSTBM 1..split；状态行+输入块 pinned 底部；
  transcript 相对流打印）——已有协议，健壮
- `IDLE`：region 解除，输入=流内普通提示符行——**输入区无边界、
  与输出混流**
- `MODAL`：菜单/面板（menu.select × 10 处调用）——RawGuard + 流内
  自绘，**不知道 region 存在**；退出画 `[取消]/已选` 后各自了结

**写者四家**：
| 写者 | 通道 | 状态约束 |
|---|---|---|
| 编辑器块 | lineinput pinned 绘制 | 仅 TURN（v2: IDLE 也合法）|
| region 协议 | regionBegin/Status/PrintLine | 仅 TURN |
| 菜单 | 直接写流内 | 仅 MODAL（但无进出协议）|
| 散装 print | RegionWriter `ow`（回合中）/ `w`（机制调用）| 已收口（P0-b）|

**缺陷机制（事故 → 缺失的不变量）**：
| 事故 | 缺失不变量 |
|---|---|
| "uit" 事件（菜单退出后 /quit 前缀被吃）| MODAL 退出 ≠ 规范 IDLE 态（编辑器/缓冲各自恢复，无仲裁）|
| S6 抖动（配置菜单 Esc 后会话未中止）| 同上 |
| /resume 吞输入 | 回合收尾 → IDLE 的转移窗口无规范重画 |
| 输入区与输出混流 | IDLE 态没有输入区协议 |

## 2. 目标状态机（v2）

```
        readLine 进入
   ┌──────────────────────┐
   │ IDLE（region 武装）    │◄──────────────┐
   │  meta: hint 行        │               │
   │  输入块 pinned 底部    │               │ modalExit()
   └──────┬───────────────┘               │
   用户发消息│        菜单/面板打开          │
   ┌──────▼───────┐   ┌────────────────┐  │
   │ TURN          │   │ MODAL          │──┘
   │  meta: 状态行  │   │ region 解除    │
   │  同一输入块     │   │ 菜单流内自绘    │
   └──────┬───────┘   └────────────────┘
   回合完 │ regionFreeze（摘要入流）→ IDLE
```

**唯一新增协议：MODAL 生命周期**
- `modalEnter()`：region 解除（regionEnd）——菜单回到流内绘制（现行为）
- `modalExit()`：清流位置以下（`\x1b[J`）→ 重 arm region → 输入块规范
  重画。**不变量：任何 MODAL 退出后，屏幕 == IDLE 规范态**（无残留、
  编辑器状态归位）

**不变量清单**：
1. IDLE 与 TURN 输入块是同一协议、同一绘制函数（只是 meta 行内容不同）
2. MODAL 存在期间 region 必解除；退出必经 modalExit（收口在 menu.select
   本身，10 个调用点自动覆盖）
3. 屏幕任何时刻只有一个写者家族活跃（状态决定）
4. 工具调用块统一 `⏺ Name(args)` 头 + dim 体 + 折叠（printToolBody）

## 3. 实现拆解（依赖序）

| 步 | 内容 | 风险网 |
|---|---|---|
| B | modalEnter/modalExit 进 menu.select | S6/S13/S20（菜单场景）|
| A | readLine 即 arm（IDLE 常驻）+ meta 行空闲文案=hint | S1/S2/S3/S12 全套 |
| C | /run 工具头统一 `⏺ Name(args)`（对齐 stream.zig）| S10/S18 |
| D | S22 场景：菜单进出后屏幕==规范态（字节断言）| 新增 |

## 4. 遗留已知项（不在本批）

- /resume 吞输入：疑在收尾窗口类，B 落地后复测（modalExit 同族收口）
- 编辑器每键全行重画风暴：性能观感问题，非正确性——后续单独优化
