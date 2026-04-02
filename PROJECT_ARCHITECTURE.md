# Claude Code CLI - 项目架构文档

## 项目概述

**Claude Code CLI** 是 Anthropic 官方推出的命令行 AI 助手工具，允许用户在终端中与 Claude AI 进行交互式对话，执行代码编写、文件操作、系统命令等各种软件工程任务。

- **语言**: TypeScript
- **运行时**: Bun
- **源文件数量**: 1332+ TypeScript 文件
- **主要入口点**: `src/entrypoints/cli.tsx`

---

## 核心架构设计

### 1. 分层架构

```
┌─────────────────────────────────────────────────────────────┐
│                    CLI Entry (cli.tsx)                      │
│              命令行参数解析、路由分发                          │
├─────────────────────────────────────────────────────────────┤
│                    Main Application (main.tsx)              │
│              主应用逻辑、会话管理、REPL 循环                    │
├─────────────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │   Ink UI     │  │   Query      │  │    Commands      │  │
│  │  终端渲染引擎  │  │   引擎       │  │    命令系统       │  │
│  └──────────────┘  └──────────────┘  └──────────────────┘  │
├─────────────────────────────────────────────────────────────┤
│                      Tools Layer                            │
│     文件操作 / Shell / 搜索 / MCP / Agent 等工具集           │
├─────────────────────────────────────────────────────────────┤
│                    Services & Utils                         │
│     LSP / MCP / 权限 / 遥测 / 存储 / 网络 等服务              │
└─────────────────────────────────────────────────────────────┘
```

---

## 模块详解

### 1. 入口点模块 (`src/entrypoints/`)

#### 1.1 CLI 入口 (`cli.tsx`)
**位置**: `src/entrypoints/cli.tsx`

**功能**:
- 程序主入口，处理命令行参数
- 快速路径处理（`--version`, `--dump-system-prompt` 等）
- 路由到不同的子命令处理器

**关键路径**:
```typescript
// 版本信息快速输出
if (args[0] === '--version') { console.log(VERSION); return; }

// Bridge 模式（远程控制）
if (args[0] === 'remote-control' || args[0] === 'rc') { ... }

// Daemon 模式（后台服务）
if (args[0] === 'daemon') { ... }

// 后台会话管理
if (args[0] === 'ps' || args[0] === 'logs' || ...) { ... }

// 默认：加载完整 CLI
await cliMain();
```

**特殊模式**:
- `--claude-in-chrome-mcp`: Chrome MCP 服务器模式
- `--chrome-native-host`: Chrome 原生消息主机
- `--computer-use-mcp`: Computer Use MCP 服务器
- `--daemon-worker`: Daemon 工作进程
- `--tmux --worktree`: Tmux worktree 模式

#### 1.2 初始化模块 (`init.ts`)
**位置**: `src/entrypoints/init.ts`

**功能**:
- 配置系统初始化 (`enableConfigs()`)
- 环境变量应用
- 优雅关闭设置
- 遥测初始化
- OAuth 账户信息填充
- 代理和 mTLS 配置
- LSP 管理器清理注册

**关键函数**:
- `init()`: 主初始化函数（memoized）
- `initializeTelemetryAfterTrust()`: 信任确认后初始化遥测

#### 1.3 MCP 服务器 (`mcp.ts`)
**位置**: `src/entrypoints/mcp.ts`

**功能**: 暴露 Claude Code 工具作为 MCP (Model Context Protocol) 服务器

**实现**:
- 使用 `@modelcontextprotocol/sdk` 创建服务器
- 实现 `ListToolsRequestSchema` 和 `CallToolRequestSchema` 处理器
- 将内部工具转换为 MCP 工具格式

#### 1.4 Agent SDK 类型 (`agentSdkTypes.ts`)
**位置**: `src/entrypoints/agentSdkTypes.ts`

**功能**: 提供 SDK 构建者的类型定义和公共 API

**导出**:
- `tool()`: 创建 MCP 工具定义的函数
- `createSdkMcpServer()`: 创建 SDK MCP 服务器
- 核心类型、运行时类型、设置类型

---

### 2. 核心模块 (`src/` 根目录)

#### 2.1 主应用 (`main.tsx`)
**位置**: `src/main.tsx` (803KB，最大的源文件)

**功能**:
- 主 REPL（Read-Eval-Print Loop）循环
- 消息处理和状态管理
- UI 渲染协调
- 工具调用编排

**关键组件**:
- 会话初始化
- 消息队列处理
- 流式响应处理
- 错误恢复机制

#### 2.2 工具基类 (`Tool.ts`)
**位置**: `src/Tool.ts`

**核心类型定义**:

```typescript
type Tool<Input, Output, P> = {
  name: string                    // 工具名称
  aliases?: string[]              // 别名（向后兼容）
  searchHint?: string             // 搜索提示
  inputSchema: Input              // Zod 输入 schema
  outputSchema?: z.ZodType        // 输出 schema
  maxResultSizeChars: number      // 结果最大字符数
  
  // 核心方法
  call(args, context, canUseTool, parentMessage, onProgress): Promise<ToolResult<Output>>
  description(input, options): Promise<string>
  isEnabled(): boolean
  isReadOnly(input): boolean
  isDestructive?(input): boolean
  isConcurrencySafe(input): boolean
  interruptBehavior?(): 'cancel' | 'block'
  
  // 可选方法
  validateInput?(input, context): Promise<ValidationResult>
  backfillObservableInput?(input): void
}
```

**ToolUseContext 结构**:
```typescript
type ToolUseContext = {
  options: {
    commands: Command[]
    tools: Tools
    mainLoopModel: string
    thinkingConfig: ThinkingConfig
    mcpClients: MCPServerConnection[]
    mcpResources: Record<string, ServerResource[]>
    isNonInteractiveSession: boolean
    agentDefinitions: AgentDefinitionsResult
    // ...
  }
  abortController: AbortController
  readFileState: FileStateCache
  getAppState(): AppState
  setAppState(f): void
  messages: Message[]
  // ...
}
```

#### 2.3 任务系统 (`Task.ts`)
**位置**: `src/Task.ts`

**任务类型**:
```typescript
type TaskType =
  | 'local_bash'      // 本地 Shell 命令
  | 'local_agent'     // 本地 Agent
  | 'remote_agent'    // 远程 Agent
  | 'in_process_teammate'  // 进程内队友
  | 'local_workflow'  // 本地工作流
  | 'monitor_mcp'     // MCP 监控
  | 'dream'           // Dream 任务
```

**任务状态**:
```typescript
type TaskStatus = 'pending' | 'running' | 'completed' | 'failed' | 'killed'
```

**关键函数**:
- `generateTaskId(type)`: 生成唯一任务 ID
- `createTaskStateBase()`: 创建任务状态基类
- `isTerminalTaskStatus()`: 检查是否终止状态

#### 2.4 查询引擎 (`QueryEngine.ts`)
**位置**: `src/QueryEngine.ts` (46KB)

**功能**: 处理 AI 查询的核心引擎，包括：
- 消息格式化
- API 调用
- 流式响应处理
- 上下文管理

#### 2.5 命令系统 (`commands.ts`)
**位置**: `src/commands.ts` (25KB)

**功能**: 定义和注册所有可用命令

---

### 3. 工具模块 (`src/tools/`)

工具目录包含 40+ 个独立工具实现：

| 工具目录 | 功能描述 |
|---------|---------|
| `AgentTool/` | 子代理系统，支持启动和管理子 Agent |
| `AskUserQuestionTool/` | 向用户提问的交互工具 |
| `BashTool/` | 执行 Shell 命令 |
| `BriefTool/` | 生成简报 |
| `ConfigTool/` | 配置管理 |
| `EnterPlanModeTool/` | 进入计划模式 |
| `ExitPlanModeTool/` | 退出计划模式 |
| `EnterWorktreeTool/` | 进入 Git Worktree |
| `ExitWorktreeTool/` | 退出 Git Worktree |
| `FileEditTool/` | 文件编辑 |
| `FileReadTool/` | 文件读取 |
| `FileWriteTool/` | 文件写入 |
| `GlobTool/` | 文件模式匹配搜索 |
| `GrepTool/` | 文件内容搜索 |
| `LSPTool/` | LSP 集成 |
| `MCPTool/` | MCP 工具调用 |
| `NotebookEditTool/` | Jupyter Notebook 编辑 |
| `PowerShellTool/` | PowerShell 命令执行 |
| `REPLTool/` | REPL 交互 |
| `ScheduleCronTool/` | 定时任务调度 |
| `SendMessageTool/` | 发送消息给其他 Agent |
| `SkillTool/` | 技能调用 |
| `TaskCreateTool/` | 创建任务 |
| `TaskGetTool/` | 获取任务详情 |
| `TaskListTool/` | 列出任务 |
| `TaskOutputTool/` | 获取任务输出 |
| `TaskStopTool/` | 停止任务 |
| `TaskUpdateTool/` | 更新任务 |
| `TeamCreateTool/` | 创建团队 |
| `TeamDeleteTool/` | 删除团队 |
| `TodoWriteTool/` | Todo 列表管理 |
| `ToolSearchTool/` | 工具搜索 |
| `WebFetchTool/` | 网页获取 |
| `WebSearchTool/` | 网页搜索 |
| `shared/` | 共享工具代码 |
| `testing/` | 测试相关工具 |

---

### 4. Ink 终端 UI 框架 (`src/ink/`)

Ink 是一个基于 React 的终端 UI 渲染框架，用于构建交互式 CLI 界面。

#### 4.1 目录结构

```
src/ink/
├── layout/           # 布局引擎
│   ├── engine.ts     # 布局计算引擎
│   ├── geometry.ts   # 几何计算
│   ├── node.ts       # 布局节点
│   └── yoga.ts       # Yoga 布局绑定
├── events/           # 事件系统
│   ├── dispatcher.ts # 事件分发器
│   ├── emitter.ts    # 事件发射器
│   ├── focus-event.ts
│   ├── input-event.ts
│   ├── click-event.ts
│   ├── keyboard-event.ts
│   └── terminal-event.ts
├── hooks/            # React Hooks
│   ├── use-app.ts
│   ├── use-input.ts
│   ├── use-stdin.ts
│   ├── use-selection.ts
│   ├── use-terminal-focus.ts
│   └── ...
├── components/       # React 组件
│   ├── AppContext.ts
│   ├── StdinContext.ts
│   └── CursorDeclarationContext.ts
├── termio/           # 终端 I/O
│   ├── parser.ts     # 输入解析
│   ├── tokenizer.ts  # 分词器
│   ├── ansi.ts       # ANSI 转义码
│   ├── csi.ts        # CSI 序列
│   ├── osc.ts        # OSC 序列
│   └── sgr.ts        # SGR 参数
├── renderer.ts       # 主渲染器
├── reconciler.ts     # React 协调器
├── terminal.ts       # 终端接口
├── screen.ts         # 屏幕管理
└── ...
```

#### 4.2 核心功能

**渲染流程**:
1. React 组件树 → Reconciler
2. 布局计算 (Yoga)
3. 输出字符串生成
4. 终端渲染

**事件处理**:
- 键盘输入
- 鼠标点击
- 终端焦点
- 选择文本

**关键 Hooks**:
- `useApp()`: 获取应用实例
- `useInput()`: 处理键盘输入
- `useStdin()`: 访问标准输入
- `useSelection()`: 文本选择
- `useTerminalFocus()`: 终端焦点状态

---

### 5. 状态管理 (`src/state/`)

```
src/state/
├── AppState.js       # 应用状态存储
└── AppStateStore.js  # 状态管理器
```

**AppState 结构**:
- 消息列表
- 任务状态
- UI 状态
- 权限状态

---

### 6. 服务模块 (`src/services/`)

提供各种后端服务：

| 目录 | 功能 |
|------|------|
| `analytics/` | 分析和事件日志 |
| `lsp/` | 语言服务器协议 |
| `mcp/` | 模型上下文协议 |
| `oauth/` | OAuth 认证 |
| `policyLimits/` | 策略限制 |
| `remoteManagedSettings/` | 远程设置管理 |

---

### 7. Bridge 模块 (`src/bridge/`)

远程控制和同步功能：

```
src/bridge/
├── bridgeMain.ts         # Bridge 主入口
├── bridgeEnabled.ts      # 启用状态检查
├── remoteBridgeCore.ts   # 核心桥接逻辑
├── replBridge.ts         # REPL 桥接
├── sessionRunner.ts      # 会话运行器
├── trustedDevice.ts      # 受信任设备
├── types.ts              # 类型定义
└── ...
```

**功能**:
- 远程控制模式
- 会话同步
- 设备信任管理

---

### 8. 组件模块 (`src/components/`)

140+ 个 React 组件，用于构建终端 UI：

**主要组件类型**:
- 布局组件（Box, Flex, Grid）
- 输入组件（TextInput, Select, Checkbox）
- 显示组件（Text, Spinner, ProgressBar）
- 对话框组件（Dialog, Modal, Alert）
- 消息组件（MessageList, MessageBubble）

---

### 9. 命令处理 (`src/commands/`)

100+ 个命令处理文件：

```
src/commands/
├── review.ts         # 代码审查
├── commit.ts         # Git 提交
├── config.ts         # 配置命令
├── init.ts           # 初始化
├── mcp.ts            # MCP 命令
├── update.ts         # 更新命令
├── permissions.ts    # 权限管理
└── ...
```

---

### 10. Hooks 模块 (`src/hooks/`)

85+ 个自定义 React Hooks：

**主要 Hooks**:
- `useCanUseTool`: 工具权限检查
- `useMessages`: 消息管理
- `useAppState`: 应用状态
- `useTheme`: 主题管理
- `useKeybindings`: 快捷键

---

### 11. 工具函数 (`src/utils/`)

330+ 个工具文件：

**主要类别**:
- 文件操作
- 权限管理
- 遥测
- Git 操作
- 网络请求
- 日志
- 配置
- 系统检测

---

### 12. Vim 模式 (`src/vim/`)

```
src/vim/
├── motions.ts        # 移动命令
├── operators.ts      # 操作符
├── transitions.ts    # 状态转换
├── textObjects.ts    # 文本对象
└── types.ts          # 类型定义
```

**支持功能**:
- 基本 Vim 移动（h, j, k, l, w, b, e）
- 操作符（d, c, y）
- 文本对象（iw, aw, i", a"）

---

### 13. 数据迁移 (`src/migrations/`)

配置和数据迁移脚本：

```
src/migrations/
├── migrateBypassPermissionsAcceptedToSettings.ts
├── migrateLegacyOpusToCurrent.ts
├── migrateOpusToOpus1m.ts
├── migrateSonnet45ToSonnet46.ts
├── migrateAutoUpdatesToSettings.ts
└── ...
```

---

### 14. 类型定义 (`src/types/`)

核心类型定义：

```
src/types/
├── message.ts        # 消息类型
├── permissions.ts    # 权限类型
├── tools.ts          # 工具类型
├── hooks.ts          # Hook 类型
├── ids.ts            # ID 类型
└── utils.ts          # 工具类型
```

---

## 关键设计模式

### 1. 工具模式 (Tool Pattern)
每个工具实现统一的 `Tool` 接口，支持：
- 输入验证
- 权限检查
- 进度报告
- 并发安全

### 2. 命令模式 (Command Pattern)
命令通过 `commands.ts` 注册，支持：
- 命令发现
- 参数解析
- 帮助生成

### 3. React 组件模式
UI 使用 React + Ink 构建：
- 函数组件
- Hooks
- Context

### 4. 事件驱动模式
- 终端事件
- 工具事件
- 状态变更事件

### 5. 插件模式
- MCP 服务器
- 自定义工具
- Hook 系统

---

## 数据流

```
用户输入
    ↓
CLI 入口 (cli.tsx)
    ↓
命令解析 → 路由到处理器
    ↓
主循环 (main.tsx)
    ↓
消息处理 → AI API 调用
    ↓
工具调用 (Tool.call)
    ↓
权限检查 → 执行 → 结果
    ↓
UI 更新 (Ink 渲染)
    ↓
输出给用户
```

---

## 配置系统

**配置文件位置**:
- `~/.claude/settings.json` - 全局设置
- `.claude/settings.json` - 项目设置
- `CLAUDE.md` - 项目指令

**配置类型**:
- 权限设置
- MCP 服务器配置
- 工具配置
- UI 偏好

---

## 权限系统

**权限模式**:
- `default`: 默认模式，需要确认
- `accept`: 自动接受
- `plan`: 计划模式

**权限规则**:
- `alwaysAllowRules`: 始终允许
- `alwaysDenyRules`: 始终拒绝
- `alwaysAskRules`: 始终询问

---

## MCP 集成

**MCP (Model Context Protocol)** 是用于 AI 助手与外部工具通信的协议。

**支持功能**:
- 工具发现
- 工具调用
- 资源访问
- 服务器管理

**配置示例**:
```json
{
  "mcpServers": {
    "server-name": {
      "command": "path/to/server",
      "args": ["--arg1"]
    }
  }
}
```

---

## 遥测系统

**遥测数据**:
- 使用统计
- 错误报告
- 性能指标

**实现**:
- OpenTelemetry 集成
- 1P 事件日志
- 增长实验（GrowthBook）

---

## 构建和运行

**开发环境要求**:
- Bun 运行时
- TypeScript

**入口点**:
- `src/entrypoints/cli.tsx` - CLI 主入口
- `src/main.tsx` - 应用主逻辑

---

## 总结

Claude Code CLI 是一个功能丰富的命令行 AI 助手，采用模块化架构设计：

1. **分层架构**: 清晰的关注点分离
2. **工具系统**: 可扩展的工具接口
3. **终端 UI**: 基于 React 的现代化界面
4. **权限管理**: 细粒度的权限控制
5. **MCP 集成**: 标准化的工具协议支持
6. **状态管理**: 集中式的应用状态

该架构支持灵活扩展，便于添加新工具、命令和功能。
