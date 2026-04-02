# Claude Code CLI - 服务层与状态管理详解

## 概述

本文档详细描述 Claude Code CLI 的服务层架构和状态管理系统。

---

## 服务模块 (`src/services/`)

### 1. MCP 服务 (`services/mcp/`)

**MCP (Model Context Protocol)** 是用于 AI 助手与外部工具通信的标准化协议。

**目录结构**:
```
services/mcp/
├── client.ts           # MCP 客户端实现
├── server.ts           # MCP 服务器实现
├── manager.ts          # MCP 服务器管理器
├── types.ts            # 类型定义
├── connection.ts       # 连接管理
├── resources.ts        # 资源管理
└── tools.ts            # 工具注册
```

**核心类型** (`types.ts`):
```typescript
export type MCPServerConnection = {
  name: string;
  status: 'connecting' | 'connected' | 'disconnected' | 'error';
  client: Client;
  transport: Transport;
  tools: MCPTool[];
  resources: ServerResource[];
};

export type MCPTool = {
  name: string;
  description: string;
  inputSchema: JSONSchema;
  outputSchema?: JSONSchema;
};

export type ServerResource = {
  uri: string;
  name: string;
  description?: string;
  mimeType?: string;
};
```

**服务器管理器** (`manager.ts`):
```typescript
export class MCPServerManager {
  private connections: Map<string, MCPServerConnection>;
  
  // 启动 MCP 服务器
  async startServer(config: MCPServerConfig): Promise<MCPServerConnection>;
  
  // 停止服务器
  async stopServer(name: string): Promise<void>;
  
  // 重启服务器
  async restartServer(name: string): Promise<void>;
  
  // 获取所有连接
  getConnections(): MCPServerConnection[];
  
  // 调用工具
  async callTool(
    serverName: string,
    toolName: string,
    args: Record<string, unknown>
  ): Promise<CallToolResult>;
  
  // 读取资源
  async readResource(
    serverName: string,
    uri: string
  ): Promise<ReadResourceResult>;
}
```

---

### 2. LSP 服务 (`services/lsp/`)

**LSP (Language Server Protocol)** 提供代码智能功能。

**目录结构**:
```
services/lsp/
├── manager.ts          # LSP 服务器管理器
├── client.ts           # LSP 客户端
├── types.ts            # 类型定义
├── completion.ts       # 自动补全
├── diagnostics.ts      # 诊断信息
├── definition.ts       # 跳转定义
├── hover.ts            # 悬停信息
└── references.ts       # 引用查找
```

**LSP 管理器** (`manager.ts`):
```typescript
export class LSPServerManager {
  private clients: Map<string, LSPClient>;
  
  // 初始化 LSP 服务器
  async initialize(languageId: string, projectRoot: string): Promise<LSPClient>;
  
  // 获取补全
  async getCompletion(
    filePath: string,
    position: Position
  ): Promise<CompletionItem[]>;
  
  // 获取诊断
  async getDiagnostics(filePath: string): Promise<Diagnostic[]>;
  
  // 跳转定义
  async gotoDefinition(
    filePath: string,
    position: Position
  ): Promise<Location | null>;
  
  // 关闭所有客户端
  async shutdown(): Promise<void>;
}
```

---

### 3. OAuth 服务 (`services/oauth/`)

**目录结构**:
```
services/oauth/
├── client.ts           # OAuth 客户端
├── flow.ts             # OAuth 流程
├── token.ts            # Token 管理
└── storage.ts          # Token 存储
```

**OAuth 客户端** (`client.ts`):
```typescript
export class OAuthClient {
  // 启动登录流程
  async login(): Promise<OAuthTokens>;
  
  // 刷新 Token
  async refreshToken(refreshToken: string): Promise<OAuthTokens>;
  
  // 获取存储的 Token
  getTokens(): OAuthTokens | null;
  
  // 登出
  async logout(): Promise<void>;
}

export type OAuthTokens = {
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
};
```

---

### 4. 分析服务 (`services/analytics/`)

**目录结构**:
```
services/analytics/
├── firstPartyEventLogger.ts  # 1P 事件日志
├── growthbook.ts             # GrowthBook 集成
├── metrics.ts                # 指标收集
└── reporter.ts               # 数据上报
```

**事件日志** (`firstPartyEventLogger.ts`):
```typescript
export function initialize1PEventLogging(): void;
export function logEvent(event: AnalyticsEvent): void;
export function reinitialize1PEventLoggingIfConfigChanged(): void;

export type AnalyticsEvent = {
  name: string;
  properties: Record<string, unknown>;
  timestamp: number;
};
```

**GrowthBook** (`growthbook.ts`):
```typescript
// 特性标志和 A/B 测试
export class GrowthBookService {
  // 初始化
  async initialize(): Promise<void>;
  
  // 检查特性是否启用
  isFeatureEnabled(featureKey: string): boolean;
  
  // 获取特性值
  getFeatureValue<T>(featureKey: string, defaultValue: T): T;
  
  // 刷新特性标志
  async refresh(): Promise<void>;
  
  // 注册刷新回调
  onRefresh(callback: () => void): void;
}
```

---

### 5. 策略限制服务 (`services/policyLimits/`)

**目录结构**:
```
services/policyLimits/
├── index.ts            # 主入口
├── fetcher.ts          # 策略获取
├── validator.ts        # 策略验证
└── types.ts            # 类型定义
```

**策略限制** (`index.ts`):
```typescript
export function isPolicyAllowed(action: PolicyAction): boolean;
export function waitForPolicyLimitsToLoad(): Promise<void>;
export function initializePolicyLimitsLoadingPromise(): void;

export type PolicyAction =
  | 'allow_remote_control'
  | 'allow_background_agents'
  | 'allow_web_search'
  | 'allow_file_write'
  // ... 更多策略
```

---

### 6. 远程设置服务 (`services/remoteManagedSettings/`)

**目录结构**:
```
services/remoteManagedSettings/
├── index.ts            # 主入口
├── fetcher.ts          # 设置获取
├── merger.ts           # 设置合并
└── types.ts            # 类型定义
```

**功能**:
- 从远程服务器获取组织级设置
- 与本地设置合并
- 支持实时更新

---

## 状态管理 (`src/state/`)

### 1. AppState 定义

**位置**: `src/state/AppState.ts`

```typescript
export type AppState = {
  // 任务状态
  tasks: Map<string, TaskState>;
  
  // UI 状态
  ui: {
    activeTab: string;
    focusedElement: string | null;
    modalStack: ModalState[];
  };
  
  // 消息状态
  messages: {
    list: Message[];
    pendingAttachments: Attachment[];
  };
  
  // 权限状态
  permissions: {
    mode: PermissionMode;
    decisions: Map<string, PermissionDecision>;
  };
  
  // 工具状态
  tools: {
    inProgressToolUseIDs: Set<string>;
    hasInterruptibleToolInProgress: boolean;
  };
  
  // 其他状态
  conversationId: string | null;
  responseLength: number;
  // ...
};
```

### 2. AppStateStore

**位置**: `src/state/AppStateStore.js`

```typescript
export class AppStateStore {
  private state: AppState;
  private listeners: Set<StateListener>;
  
  // 获取状态
  getState(): AppState;
  
  // 设置状态
  setState(updater: (prev: AppState) => AppState): void;
  
  // 订阅状态变化
  subscribe(listener: StateListener): () => void;
  
  // 批量更新
  batch(updates: StateUpdate[]): void;
}

export type StateListener = (state: AppState, prevState: AppState) => void;
```

### 3. 状态更新模式

**不可变更新**:
```typescript
// 使用 immer 风格的不可变更新
setAppState(prev => ({
  ...prev,
  tasks: new Map(prev.tasks).set(taskId, newTaskState),
}));
```

**批量更新**:
```typescript
// 批量更新多个状态
store.batch([
  { path: 'tasks.id1.status', value: 'completed' },
  { path: 'tasks.id2.status', value: 'running' },
]);
```

### 4. 默认 AppState

**位置**: `src/state/AppStateStore.js`

```typescript
export function getDefaultAppState(): AppState {
  return {
    tasks: new Map(),
    ui: {
      activeTab: 'chat',
      focusedElement: null,
      modalStack: [],
    },
    messages: {
      list: [],
      pendingAttachments: [],
    },
    permissions: {
      mode: 'default',
      decisions: new Map(),
    },
    tools: {
      inProgressToolUseIDs: new Set(),
      hasInterruptibleToolInProgress: false,
    },
    conversationId: null,
    responseLength: 0,
  };
}
```

---

## 上下文系统 (`src/context/`)

### 1. 通知上下文

**位置**: `src/context/notifications.ts`

```typescript
export type Notification = {
  id: string;
  type: 'info' | 'warning' | 'error' | 'success';
  title: string;
  message: string;
  timestamp: number;
  actions?: NotificationAction[];
};

export type NotificationContext = {
  notifications: Notification[];
  addNotification: (notif: Omit<Notification, 'id' | 'timestamp'>) => void;
  removeNotification: (id: string) => void;
  clearNotifications: () => void;
};
```

### 2. 配置上下文

**位置**: `src/context/config.ts`

```typescript
export type ConfigContext = {
  settings: Settings;
  updateSettings: (updates: Partial<Settings>) => void;
  resetSettings: () => void;
};
```

### 3. 主题上下文

**位置**: `src/context/theme.ts`

```typescript
export type ThemeContext = {
  theme: Theme;
  themeName: ThemeName;
  setTheme: (name: ThemeName) => void;
};

export type Theme = {
  colors: {
    primary: string;
    secondary: string;
    background: string;
    text: string;
    // ...
  };
  fonts: {
    main: string;
    mono: string;
  };
};
```

---

## 权限系统

### 权限模式

```typescript
export type PermissionMode =
  | 'default'     // 默认：需要确认
  | 'accept'      // 自动接受
  | 'plan'        // 计划模式
  | 'auto';       // 自动模式
```

### 权限规则

**位置**: `src/types/permissions.ts`

```typescript
export type ToolPermissionRule = {
  rule: string;           // 规则模式（如 "Bash(npm install*)"）
  behavior: 'allow' | 'deny' | 'ask';
  source: 'settings' | 'session' | 'hooks';
  timestamp: number;
};

export type ToolPermissionRulesBySource = {
  hooks?: Map<string, ToolPermissionRule>;
  settings?: Map<string, ToolPermissionRule>;
  session?: Map<string, ToolPermissionRule>;
};
```

### 权限检查流程

**位置**: `src/utils/permissions/`

```
工具调用
    ↓
1. validateInput() - 输入验证
    ↓
2. 检查 alwaysDenyRules
    ├── 匹配 → 拒绝
    └── 不匹配 ↓
3. 检查 alwaysAllowRules
    ├── 匹配 → 允许
    └── 不匹配 ↓
4. 检查 alwaysAskRules
    ├── 匹配 → 询问用户
    └── 不匹配 ↓
5. 根据 PermissionMode 决定
    ├── 'accept' → 允许
    ├── 'plan' → 允许（只读）
    └── 'default' → 询问用户
```

### 权限对话框

```typescript
export type PermissionDialogResult = {
  decision: 'allow' | 'deny';
  remember?: boolean;
  scope?: 'session' | 'always';
};
```

---

## 任务系统

### 任务类型

**位置**: `src/Task.ts`

```typescript
export type TaskType =
  | 'local_bash'          // 本地 Shell 命令
  | 'local_agent'         // 本地 Agent
  | 'remote_agent'        // 远程 Agent
  | 'in_process_teammate' // 进程内队友
  | 'local_workflow'      // 本地工作流
  | 'monitor_mcp'         // MCP 监控
  | 'dream';              // Dream 任务
```

### 任务状态

```typescript
export type TaskStatus =
  | 'pending'    // 等待中
  | 'running'    // 运行中
  | 'completed'  // 已完成
  | 'failed'     // 失败
  | 'killed';    // 已终止

export function isTerminalTaskStatus(status: TaskStatus): boolean {
  return status === 'completed' || status === 'failed' || status === 'killed';
}
```

### 任务状态定义

**位置**: `src/tasks/`

```
src/tasks/
├── LocalShellTask/      # Shell 命令任务
├── LocalAgentTask/      # 本地 Agent 任务
├── RemoteAgentTask/     # 远程 Agent 任务
├── InProcessTeammateTask/  # 进程内队友
├── DreamTask/           # Dream 任务
└── ...
```

**LocalShellTask** 状态:
```typescript
export type LocalShellTaskState = TaskStateBase & {
  type: 'local_bash';
  command: string;
  pid?: number;
  exitCode?: number;
  output: string;
};
```

**LocalAgentTask** 状态:
```typescript
export type LocalAgentTaskState = TaskStateBase & {
  type: 'local_agent';
  agentType: string;
  prompt: string;
  model: string;
  messages: Message[];
};
```

---

## 数据持久化

### 1. 配置存储

**位置**: `~/.claude/`

```
~/.claude/
├── settings.json        # 全局设置
├── credentials.json     # 认证凭据
├── projects/            # 项目级设置
│   └── <project-hash>/
│       └── settings.json
└── sessions/            # 会话数据
    └── <session-id>/
        ├── messages.json
        └── state.json
```

### 2. 任务输出存储

**位置**: `src/utils/task/diskOutput.ts`

```typescript
export function getTaskOutputPath(taskId: string): string {
  // 返回任务输出文件路径
  // 存储在临时目录
}

export async function writeTaskOutput(
  taskId: string,
  output: string,
  offset: number
): Promise<number> {
  // 追加写入任务输出
}

export async function readTaskOutput(
  taskId: string,
  offset?: number
): Promise<string> {
  // 读取任务输出
}
```

### 3. 消息历史

**位置**: `src/history.ts`

```typescript
export class MessageHistory {
  // 保存消息
  async saveMessages(sessionId: string, messages: Message[]): Promise<void>;
  
  // 加载消息
  async loadMessages(sessionId: string): Promise<Message[]>;
  
  // 列出会话
  async listSessions(): Promise<SessionInfo[]>;
  
  // 删除会话
  async deleteSession(sessionId: string): Promise<void>;
}
```

---

## Hook 系统

### PreToolUse / PostToolUse Hooks

**位置**: `src/types/hooks.ts`

```typescript
export type HookType = 'PreToolUse' | 'PostToolUse' | 'Notification' | 'Stop';

export type HookConfig = {
  type: HookType;
  command: string;
  timeout?: number;
  matchers?: HookMatcher[];
};

export type HookResult = {
  status: 'success' | 'error' | 'timeout';
  output?: string;
  modifiedInput?: Record<string, unknown>;
  decision?: 'approve' | 'reject' | 'ask';
};
```

### Hook 执行流程

```
工具调用
    ↓
1. 匹配 PreToolUse Hooks
    ↓
2. 执行 Hook 命令
    ├── approve → 继续执行
    ├── reject → 返回错误
    ├── ask → 询问用户
    └── error → 记录并继续
    ↓
3. 执行工具
    ↓
4. 匹配 PostToolUse Hooks
    ↓
5. 执行 Hook 命令
```

---

## 总结

Claude Code CLI 的服务层和状态管理特点：

1. **模块化服务**: 每个服务独立封装
2. **MCP/LSP 支持**: 标准协议集成
3. **集中式状态**: 统一的 AppState 管理
4. **权限系统**: 细粒度的访问控制
5. **任务系统**: 异步任务管理
6. **Hook 系统**: 可扩展的钩子机制
7. **数据持久化**: 配置和会话存储
