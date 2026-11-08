# ziv 项目根锚定方案（目录层级识别，2026-11-10）

> 问题（用户报障定位）：一次会话一个目录——从项目根和从子目录打开 ziv，
> 得到两个互不相识的 `.ziv` 库（记忆/会话/索引/检查点全部分裂）。
> 目标：ziv 自己识别层级，不发生错误操作，子目录会话与项目根共享存储。

## 设计（一条规则）

**锚点 = 从 cwd 向上（含自身）找到的第一个已存在 `.ziv` 目录；找不到则
锚在 cwd（现行为，`.ziv` 按需创建）。** 子目录有自己的 `.ziv` 时最近者
胜——显式本地库是合法的覆盖手段。

- **存储共享**：memory.db / sessions.db / index.db / checkpoints /
  logs / traces / tasks / pending_extract / plan.md / input_history /
  skills（项目级）全部挂在锚点下——子目录会话与根会话同一套记忆。
- **cwd 不变**：Bash/工具仍在用户所在目录执行（不 chdir）；会话行的
  cwd 列记录真实 cwd，/resume 展示可区分。
- **路径安全**（不发生错误操作的前提，已核实）：代码索引与检查点存的是
  **绝对路径**（工具 schema 强制）——同一索引被不同 cwd 的会话读写不会
  错位；唯一要求是锚点解析用 realpath 归一（符号链接不分裂）。
- **提示可见**：继承上级存储时启动打印一行
  `⤴ 使用项目存储 <root>/.ziv（记忆/会话/索引共享）`。

## 实现载体

`src/util/zivroot.zig`：启动时 `init(io)` 解析一次（realpath + 逐级向上
探测 `.ziv`，最多到文件系统根）；静态保存锚点；`sub(buf, "memory.db")`
生成锚点相对路径。28 处字面 `.ziv/...` 站点全部改走 zivroot（含
memory_ops 的 PENDING_DIR、skills 的项目根、dispatch 的 plan.md）。

## 明确不做

- 多级叠加（CC 的 CLAUDE.md 是全层级合并）——ziv 只锚最近的，简单且
  覆盖 99% 场景（「同一个项目」通常一个根）。
- 存储迁移（既有分裂库不自动合并）——用户可手工 mv；提示行给出锚点
  路径即是操作指引。

## 验收

1. 单测：`root/.ziv` + `root/sub/` 结构 → 从 sub 解析锚到 root；
   无任何 `.ziv` → 锚在 cwd；sub 自有 `.ziv` → 锚在 sub。
2. pty S15：根目录会话存一条记忆 → 子目录启动 → 提示行出现 +
   /memory 可见根的记忆；/resume 能看到根的会话。
3. 既有 14 场景全绿（锚点 = cwd 时行为零变化）。
