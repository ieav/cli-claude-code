# Claude Code CLI - 工具模块实现详解

## 概述

本文档详细描述 Claude Code CLI 中所有工具的实现逻辑和代码位置。

---

## 工具接口定义

**位置**: `src/Tool.ts`

```typescript
export type Tool<
  Input extends AnyObject = AnyObject,
  Output = unknown,
  P extends ToolProgressData = ToolProgressData
> = {
  // 标识
  name: string                    // 工具名称
  aliases?: string[]              // 别名列表
  searchHint?: string             // 搜索提示（用于 ToolSearch）

  // Schema
  readonly inputSchema: Input     // Zod 输入 schema
  outputSchema?: z.ZodType        // 可选输出 schema
  readonly inputJSONSchema?: ToolInputJSONSchema  // JSON Schema 格式
  
  // 核心方法
  call(args, context, canUseTool, parentMessage, onProgress): Promise<ToolResult<Output>>
  description(input, options): Promise<string>
  
  // 状态检查
  isEnabled(): boolean
  isReadOnly(input): boolean
  isDestructive?(input): boolean
  isConcurrencySafe(input): boolean
  
  // 可选方法
  validateInput?(input, context): Promise<ValidationResult>
  interruptBehavior?(): 'cancel' | 'block'
  isSearchOrReadCommand?(input): { isSearch: boolean; isRead: boolean; isList?: boolean }
  
  // MCP 相关
  isMcp?: boolean
  mcpInfo?: { serverName: string; toolName: string }
  
  // 其他
  maxResultSizeChars: number
  readonly strict?: boolean
  readonly shouldDefer?: boolean
  readonly alwaysLoad?: boolean
}
```

---

## 核心工具实现

### 1. BashTool - Shell 命令执行

**位置**: `src/tools/BashTool/`

**目录结构**:
```
BashTool/
├── index.ts              # 主入口
├── bashTool.ts           # 核心实现
├── bashSession.ts        # 会话管理
├── bashToolProgress.tsx  # 进度显示
├── interruptBash.ts      # 中断处理
└── parseCommand.ts       # 命令解析
```

**核心逻辑**:

```typescript
// bashTool.ts
export const bashTool: Tool<typeof BashToolInputSchema, BashToolResult, BashProgress> = {
  name: 'Bash',
  inputSchema: BashToolInputSchema,
  
  async call(args, context, canUseTool, parentMessage, onProgress) {
    // 1. 验证命令安全性
    // 2. 检查权限
    // 3. 创建子进程执行命令
    // 4. 流式输出进度
    // 5. 返回结果
  },
  
  isReadOnly(input) {
    // 判断是否只读命令（如 ls, cat）
  },
  
  isDestructive(input) {
    // 判断是否破坏性命令（如 rm, dd）
  }
}
```

**输入 Schema**:
```typescript
const BashToolInputSchema = z.object({
  command: z.string().describe('要执行的命令'),
  description: z.string().describe('命令描述'),
  timeout: z.number().optional().describe('超时时间（毫秒）'),
  run_in_background: z.boolean().optional().describe('后台运行')
})
```

---

### 2. FileReadTool - 文件读取

**位置**: `src/tools/FileReadTool/`

**目录结构**:
```
FileReadTool/
├── index.ts
├── fileReadTool.ts
├── readFile.ts
└── readFileLimits.ts
```

**核心实现**:

```typescript
export const fileReadTool: Tool<typeof ReadInputSchema, ReadResult> = {
  name: 'Read',
  inputSchema: ReadInputSchema,
  maxResultSizeChars: Infinity,  // 文件读取不限制大小
  
  async call(args, context, canUseTool, parentMessage, onProgress) {
    // 1. 解析文件路径
    // 2. 检查文件是否存在
    // 3. 读取文件内容
    // 4. 处理图片和 PDF
    // 5. 返回格式化内容
  },
  
  isReadOnly() { return true; },
  
  isSearchOrReadCommand() {
    return { isSearch: false, isRead: true, isList: false };
  }
}
```

**支持的文件类型**:
- 文本文件（自动检测编码）
- 图片（PNG, JPG 等）
- PDF 文档
- Jupyter Notebook (.ipynb)

---

### 3. FileWriteTool - 文件写入

**位置**: `src/tools/FileWriteTool/`

**核心实现**:

```typescript
export const fileWriteTool: Tool<typeof WriteInputSchema, WriteResult> = {
  name: 'Write',
  inputSchema: WriteInputSchema,
  
  async call(args, context, canUseTool, parentMessage, onProgress) {
    // 1. 检查文件是否存在（需要先读取）
    // 2. 权限检查
    // 3. 写入文件
    // 4. 返回结果
  },
  
  isReadOnly() { return false; },
  isDestructive() { return true; }  // 覆盖写入
}
```

**安全机制**:
- 必须先使用 Read 工具读取文件
- 防止意外覆盖

---

### 4. FileEditTool - 文件编辑

**位置**: `src/tools/FileEditTool/`

**核心实现**:

```typescript
export const fileEditTool: Tool<typeof EditInputSchema, EditResult> = {
  name: 'Edit',
  inputSchema: EditInputSchema,
  
  async call(args, context, canUseTool, parentMessage, onProgress) {
    // 1. 读取原文件
    // 2. 查找 old_string
    // 3. 替换为 new_string
    // 4. 写回文件
  }
}
```

**编辑模式**:
- 精确字符串替换
- `replace_all`: 替换所有匹配

---

### 5. GlobTool - 文件模式匹配

**位置**: `src/tools/GlobTool/`

**核心实现**:

```typescript
export const globTool: Tool<typeof GlobInputSchema, GlobResult> = {
  name: 'Glob',
  
  async call(args, context, canUseTool, parentMessage, onProgress) {
    // 使用 fast-glob 库进行模式匹配
    // 支持标准 glob 模式：**/*.js, src/**/*.ts
  },
  
  isReadOnly() { return true; },
  isSearchOrReadCommand() {
    return { isSearch: true, isRead: false, isList: true };
  }
}
```

---

### 6. GrepTool - 内容搜索

**位置**: `src/tools/GrepTool/`

**核心实现**:

```typescript
export const grepTool: Tool<typeof GrepInputSchema, GrepResult> = {
  name: 'Grep',
  
  async call(args, context, canUseTool, parentMessage, onProgress) {
    // 使用 ripgrep 进行高效搜索
    // 支持正则表达式
    // 支持多种输出模式
  },
  
  isSearchOrReadCommand() {
    return { isSearch: true, isRead: false };
  }
}
```

**输出模式**:
- `content`: 显示匹配行
- `files_with_matches`: 只显示文件名
- `count`: 显示匹配数量

---

### 7. AgentTool - 子代理系统

**位置**: `src/tools/AgentTool/`

**目录结构**:
```
AgentTool/
├── index.ts
├── agentTool.ts
├── built-in/             # 内置 Agent 类型
│   ├── general-purpose.ts
│   ├── explore.ts
│   ├── plan.ts
│   └── ...
├── loadAgentsDir.ts      # 加载自定义 Agent
├── forkSubagent.ts       # Fork 子代理
└── createSubagentContext.ts  # 创建子代理上下文
```

**Agent 类型**:
```typescript
type AgentType = 
  | 'general-purpose'   // 通用代理
  | 'explore'          // 代码探索
  | 'plan'             // 规划代理
  | 'statusline-setup' // 状态栏设置
  | 'claude-code-guide' // Claude Code 指南
```

**核心实现**:

```typescript
export const agentTool: Tool<typeof AgentInputSchema, AgentResult> = {
  name: 'Agent',
  
  async call(args, context, canUseTool, parentMessage, onProgress) {
    // 1. 加载 Agent 定义
    // 2. 创建子代理上下文
    // 3. 启动子代理
    // 4. 监控进度
    // 5. 收集结果
  }
}
```

---

### 8. WebSearchTool - 网页搜索

**位置**: `src/tools/WebSearchTool/`

**核心实现**:

```typescript
export const webSearchTool: Tool<typeof WebSearchInputSchema, WebSearchResult> = {
  name: 'WebSearch',
  
  async call(args, context, canUseTool, parentMessage, onProgress) {
    // 调用搜索 API
    // 格式化搜索结果
    // 包含来源引用
  }
}
```

---

### 9. WebFetchTool - 网页获取

**位置**: `src/tools/WebFetchTool/`

**功能**: 获取并解析网页内容

---

### 10. MCPTool - MCP 工具调用

**位置**: `src/tools/MCPTool/`

**核心实现**:

```typescript
export const mcpTool: Tool<typeof MCPInputSchema, MCPResult> = {
  name: 'mcp__{{server}}__{{tool}}',
  isMcp: true,
  
  async call(args, context, canUseTool, parentMessage, onProgress) {
    // 1. 获取 MCP 客户端连接
    // 2. 调用远程工具
    // 3. 处理响应
  }
}
```

---

### 11. TaskCreateTool / TaskUpdateTool / TaskListTool - 任务管理

**位置**: `src/tools/TaskCreateTool/`, `src/tools/TaskUpdateTool/`, `src/tools/TaskListTool/`

**任务类型**:
```typescript
type TaskType =
  | 'local_bash'        // 本地 Shell 任务
  | 'local_agent'       // 本地 Agent 任务
  | 'remote_agent'      // 远程 Agent 任务
  | 'in_process_teammate' // 进程内队友
  | 'local_workflow'    // 本地工作流
  | 'monitor_mcp'       // MCP 监控
  | 'dream'             // Dream 任务
```

**任务状态**:
```typescript
type TaskStatus = 'pending' | 'running' | 'completed' | 'failed' | 'killed'
```

---

### 12. SkillTool - 技能调用

**位置**: `src/tools/SkillTool/`

**功能**: 调用预定义的技能（如 `/commit`, `/review-pr`）

---

### 13. AskUserQuestionTool - 用户交互

**位置**: `src/tools/AskUserQuestionTool/`

**核心实现**:

```typescript
export const askUserQuestionTool: Tool<typeof AskInputSchema, AskResult> = {
  name: 'AskUserQuestion',
  
  async call(args, context, canUseTool, parentMessage, onProgress) {
    // 1. 显示问题
    // 2. 提供选项
    // 3. 等待用户响应
    // 4. 返回选择结果
  },
  
  requiresUserInteraction() { return true; }
}
```

---

### 14. EnterPlanModeTool / ExitPlanModeTool - 计划模式

**位置**: `src/tools/EnterPlanModeTool/`, `src/tools/ExitPlanModeTool/`

**功能**: 进入/退出计划模式，用于复杂任务的规划阶段

---

### 15. NotebookEditTool - Jupyter Notebook 编辑

**位置**: `src/tools/NotebookEditTool/`

**功能**: 编辑 Jupyter Notebook 的单元格

**编辑模式**:
- `replace`: 替换单元格内容
- `insert`: 插入新单元格
- `delete`: 删除单元格

---

### 16. ScheduleCronTool - 定时任务

**位置**: `src/tools/ScheduleCronTool/`

**功能**: 创建和管理定时任务

**Cron 格式**: 5 字段 cron 表达式（分钟 小时 日 月 星期）

---

### 17. LSPTool - 语言服务器协议

**位置**: `src/tools/LSPTool/`

**功能**: 与 LSP 服务器交互，提供代码智能

---

### 18. TodoWriteTool - Todo 列表

**位置**: `src/tools/TodoWriteTool/`

**功能**: 管理 Todo 列表（已弃用，建议使用 Task 系统）

---

### 19. TeamCreateTool / TeamDeleteTool - 团队管理

**位置**: `src/tools/TeamCreateTool/`, `src/tools/TeamDeleteTool/`

**功能**: 创建和删除多 Agent 团队

---

### 20. EnterWorktreeTool / ExitWorktreeTool - Git Worktree

**位置**: `src/tools/EnterWorktreeTool/`, `src/tools/ExitWorktreeTool/`

**功能**: 管理 Git Worktree 隔离工作环境

---

## 工具权限系统

### 权限检查流程

```
工具调用请求
    ↓
validateInput() - 输入验证
    ↓
canUseTool() - 权限检查
    ↓
[自动允许?]
    ├── 是 → 执行工具
    └── 否 → 显示权限对话框
              ↓
         用户决定
              ↓
    [允许] → 执行并记录规则
    [拒绝] → 返回错误
```

### 权限规则类型

```typescript
type ToolPermissionRulesBySource = {
  hooks?: Map<string, ToolPermissionRule>      // Hook 规则
  settings?: Map<string, ToolPermissionRule>   // 设置规则
  session?: Map<string, ToolPermissionRule>    // 会话规则
}
```

---

## 工具注册和发现

### 工具注册

**位置**: `src/tools.ts`

```typescript
export function getTools(
  toolPermissionContext: ToolPermissionContext
): Tools {
  return [
    bashTool,
    fileReadTool,
    fileWriteTool,
    fileEditTool,
    globTool,
    grepTool,
    agentTool,
    webSearchTool,
    webFetchTool,
    mcpTool,
    // ... 更多工具
  ].filter(tool => tool.isEnabled());
}
```

### 工具发现

**ToolSearchTool** 用于搜索可用工具：

```typescript
export const toolSearchTool: Tool<typeof SearchInputSchema, SearchResult> = {
  name: 'ToolSearch',
  
  async call(args, context, canUseTool, parentMessage, onProgress) {
    // 1. 解析搜索查询
    // 2. 匹配工具名称、描述、searchHint
    // 3. 返回匹配的工具列表
  }
}
```

---

## 工具进度报告

### 进度类型

```typescript
type ToolProgressData =
  | BashProgress          // Shell 命令进度
  | AgentToolProgress     // Agent 进度
  | MCPProgress           // MCP 工具进度
  | WebSearchProgress     // 搜索进度
  | TaskOutputProgress    // 任务输出进度
  | SkillToolProgress     // 技能进度
  | REPLToolProgress      // REPL 进度
```

### 进度回调

```typescript
type ToolCallProgress<P> = (progress: ToolProgress<P>) => void;

// 使用示例
onProgress({
  toolUseID: 'tool_123',
  data: {
    type: 'bash_progress',
    output: 'Command output...',
    exitCode: null
  }
});
```

---

## 工具结果处理

### 结果类型

```typescript
type ToolResult<T> = {
  data: T;                    // 结果数据
  newMessages?: Message[];    // 新消息（用于添加到对话）
  contextModifier?: (context) => context;  // 上下文修改器
  mcpMeta?: {                 // MCP 元数据
    _meta?: Record<string, unknown>;
    structuredContent?: Record<string, unknown>;
  };
}
```

### 结果大小限制

```typescript
// 工具结果超过 maxResultSizeChars 时
if (result.length > tool.maxResultSizeChars) {
  // 1. 保存到临时文件
  // 2. 返回文件路径 + 预览
}
```

---

## 总结

Claude Code CLI 的工具系统设计特点：

1. **统一接口**: 所有工具实现相同的 `Tool` 接口
2. **权限控制**: 细粒度的权限检查和管理
3. **进度报告**: 实时的进度反馈机制
4. **并发安全**: 支持并发执行的工具标记
5. **可扩展性**: 易于添加新工具
6. **MCP 集成**: 支持外部 MCP 工具
7. **结果管理**: 自动处理大结果的持久化
