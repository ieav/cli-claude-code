# M5 Workflow 脚本化 — 语法 spike（2026-11-08）

> 状态：**设计稿，未实现**。原触发条件（出现 ≥2 个重复性多 agent 流程）
> 未变；本 spike 把「到时候直接开工」的前置问题先答掉。实现排期等真实
> 用例来喂参数——没有用例的语法细节全是猜。

## 1. 已有资产（workflow 不是从零建）

| 资产 | 位置 | 对 workflow 的意义 |
|---|---|---|
| 无头 agent 循环 | `src/agent/subagent.zig`（M7 起 oneshot 也复用） | 一个 step = 一次 `subagent.run(cfg)`，引擎免费 |
| 并行 fan-out | `agent` 工具（1-3 并发、tools 白名单、fork 继承） | 并行 step 组的语义已经在线上跑过（S14） |
| 回合内阻塞模型 | repl 主循环同步等工具返回 | **约束**：workflow 只能是「一个工具调用」——整个流程在 `execute` 里跑完，不做异步回送（那需要 M4 后台化基建，仍延期） |
| JSON 解析/序列化 | json_helpers | 语法载体的零成本选择 |

## 2. 语法载体（A10 加权矩阵）

| 方案 | 熟悉度 .25 | 生态 .20 | 维护 .20 | 表达力 .15 | 速度 .10 | 锁定 .10 | 总分 |
|---|---|---|---|---|---|---|---|
| **JSON（.ziv/workflows/\*.json）** | 4 | 4 | 5 | 3 | 5 | 5 | **4.30** ✅ |
| YAML | 4 | 5 | 2（新依赖） | 3 | 3 | 4 | 3.50 |
| 自研 DSL | 2 | 1 | 2 | 5 | 2 | 2 | 2.15 |

**结论：JSON。** ziv 全栈 JSON（settings/sessions/MCP 配置），零新依赖；
表达力弱（无注释）用 `description` 字段补。DSL 等 ≥3 个真实工作流把
共性榨出来再评估——现在上是猜。

## 3. 提议语法（v0 草案，等用例定稿）

```json
{
  "name": "review-changes",
  "description": "三路并行审查 + 汇总（示例：假想中的重复流程）",
  "steps": [
    {
      "id": "triage",
      "task": "列出本次改动的文件并归类（bug/feature/refactor）",
      "tools": ["Bash", "Glob", "FileRead"],
      "fork": true,
      "max_turns": 3
    },
    {
      "id": "review",
      "parallel": [
        { "id": "bugs",     "task": "审查 ${triage} 结果中的 bug 类改动，找逻辑漏洞", "fork": true },
        { "id": "quality",  "task": "审查代码质量与简化机会", "fork": true },
        { "id": "tests",    "task": "评估测试覆盖缺口", "fork": true }
      ]
    },
    {
      "id": "summary",
      "task": "合并三路审查结果为一份按严重度排序的清单",
      "fork": true,
      "max_turns": 2
    }
  ]
}
```

语义要点（v0 全部沿用现有引擎语义，不发明新机制）：
- **step = subagent.run**：`task`/`tools`/`fork`/`max_turns` 直通
  SubagentConfig；只读 + ask 拒绝不变。
- **`${id}` 引用**：上一步 summary 文本内插进 task（唯一的数据流原语；
  不做变量树/条件/循环——用例证明需要再加）。
- **`parallel` 组**：组内并发跑（上限沿用 subagent_concurrency），全部
  完成才进下一步。
- **失败语义**：step 失败（err/超限）→ 默认整流程停，输出已完成的
  汇总；`"on_fail": "continue"` 可选跳过。
- **入口**：`/wf <name>`（人手）+ `workflow` 工具（模型可调，默认不
  注册，settings 开关放开）。

## 4. 明确不做（v0）

- 条件分支/循环/变量运算——LLM 在 step 内部就是「控制流」，脚本层
  再造一门语言是过度设计。
- 断点续跑/缓存——流程分钟级，重跑比简历便宜。
- 异步/后台执行——等 M4 后台化基建（不变）。

## 5. 实现估算（触发后）

| 件 | PERT E |
|---|---|
| workflow JSON 加载 + schema 校验 | 0.3 天 |
| 执行器（顺序/parallel 组/`${id}` 内插） | 0.7 天 |
| `/wf` 命令 + `workflow` 工具门 | 0.3 天 |
| pty 场景（S19：双路 parallel + 汇总断言） | 0.3 天 |
| **合计** | **~1.6 天**（SD 0.4） |

## 6. 触发判定（何时开工）

手工信号：同一 fan-out 模式（≥2 agent + 汇总）在一周内手工重复 ≥2 次
且参数只换不变形。到数即按本草案开工；草案与实际用例冲突时，用例赢。
