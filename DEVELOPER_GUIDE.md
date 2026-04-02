# Claude Code CLI - 开发者指南

## 概述

本文档提供 Claude Code CLI 的开发指南，包括常用工具函数、开发模式和最佳实践。

---

## 项目结构总览

```
claude-code-i-main/
├── src/
│   ├── entrypoints/          # 入口点
│   │   ├── cli.tsx           # CLI 主入口
│   │   ├── init.ts           # 初始化
│   │   ├── mcp.ts            # MCP 服务器
│   │   └── agentSdkTypes.ts  # SDK 类型
│   │
│   ├── main.tsx              # 主应用逻辑
│   ├── setup.ts              # 设置和配置
│   ├── ink.ts                # Ink UI 入口
│   ├── context.ts            # 上下文定义
│   ├── commands.ts           # 命令注册
│   ├── query.ts              # 查询处理
│   ├── tools.ts              # 工具注册
│   ├── Task.ts               # 任务定义
│   ├── Tool.ts               # 工具接口
│   │
│   ├── tools/                # 工具实现 (40+)
│   ├── ink/                  # 终端 UI 框架 (50+)
│   ├── components/           # React 组件 (140+)
│   ├── commands/             # 命令处理 (100+)
│   ├── hooks/                # React Hooks (85+)
│   ├── services/             # 后端服务
│   ├── utils/                # 工具函数 (330+)
│   ├── state/                # 状态管理
│   ├── context/              # React Context
│   ├── types/                # 类型定义
│   ├── bridge/               # 远程控制
│   ├── vim/                  # Vim 模式
│   ├── migrations/           # 数据迁移
│   └── constants/            # 常量定义
│
├── not_used.md               # 未使用代码参考
└── PROJECT_ARCHITECTURE.md   # 架构文档
```

---

## 常用工具函数 (`src/utils/`)

### 1. 文件操作

#### 文件读取 (`utils/file.js`)
```typescript
export async function readFile(path: string): Promise<string>;
export async function readFileIfExists(path: string): Promise<string | null>;
export async function writeFile(path: string, content: string): Promise<void>;
export async function fileExists(path: string): Promise<boolean>;
export async function ensureDir(dir: string): Promise<void>;
```

#### 路径处理 (`utils/paths.ts`)
```typescript
export function resolvePath(path: string, cwd?: string): string;
export function getRelativePath(absolute: string, cwd: string): string;
export function isAbsolutePath(path: string): boolean;
export function normalizePath(path: string): string;
```

### 2. 日志系统

#### 日志工具 (`utils/log.ts`)
```typescript
export function logInfo(message: string, data?: object): void;
export function logError(error: Error | unknown): void;
export function logWarning(message: string, data?: object): void;
export function logDebug(message: string, data?: object): void;
```

#### 诊断日志 (`utils/diagLogs.ts`)
```typescript
export function logForDiagnosticsNoPII(
  level: 'info' | 'warn' | 'error',
  event: string,
  data?: object
): void;
```

### 3. 权限管理

#### 权限检查 (`utils/permissions/permissions.ts`)
```typescript
export async function hasPermissionsToUseTool(
  tool: Tool,
  input: unknown,
  context: ToolUseContext
): Promise<PermissionResult>;

export function checkPermissionRules(
  rules: ToolPermissionRule[],
  toolName: string,
  input: unknown
): PermissionDecision | null;
```

#### 权限规则匹配 (`utils/permissions/ruleMatching.ts`)
```typescript
export function matchRule(
  rule: string,
  toolName: string,
  input: unknown
): boolean;
```

### 4. 进程管理

#### 子进程 (`utils/subprocess.ts`)
```typescript
export async function spawn(
  command: string,
  args: string[],
  options?: SpawnOptions
): Promise<SpawnResult>;

export async function spawnWithProgress(
  command: string,
  args: string[],
  onProgress: (output: string) => void
): Promise<SpawnResult>;
```

#### 进程清理 (`utils/cleanupRegistry.ts`)
```typescript
export function registerCleanup(cleanup: CleanupFn): void;
export async function runCleanups(): Promise<void>;
```

### 5. Git 操作

#### Git 工具 (`utils/git/`)
```typescript
export async function getGitStatus(cwd: string): Promise<GitStatus>;
export async function getGitDiff(cwd: string): Promise<string>;
export async function gitCommit(cwd: string, message: string): Promise<void>;
export async function gitBranch(cwd: string): Promise<string>;
```

### 6. 网络请求

#### HTTP 请求 (`utils/http.ts`)
```typescript
export async function fetch(url: string, options?: FetchOptions): Promise<Response>;
export async function fetchJSON<T>(url: string): Promise<T>;
```

#### 代理配置 (`utils/proxy.ts`)
```typescript
export function configureGlobalAgents(): void;
export function getProxySettings(): ProxySettings | null;
```

### 7. 遥测

#### 遥测工具 (`utils/telemetry/`)
```typescript
export async function initializeTelemetry(): Promise<Meter | null>;
export function getTelemetryAttributes(): Attributes;
export function recordMetric(name: string, value: number, attrs?: Attributes): void;
```

### 8. 系统检测

#### 环境检测 (`utils/envDynamic.ts`)
```typescript
export function detectJetBrains(): Promise<boolean>;
export function detectVSCode(): boolean;
export function isWindows(): boolean;
export function isMac(): boolean;
export function isLinux(): boolean;
```

#### 终端能力 (`utils/terminalCapabilities.ts`)
```typescript
export function supportsColors(): boolean;
export function supportsHyperlinks(): boolean;
export function supportsTrueColor(): boolean;
export function getTerminalSize(): { columns: number; rows: number };
```

---

## 类型定义参考 (`src/types/`)

### 1. 消息类型 (`types/message.ts`)

```typescript
export type Message =
  | UserMessage
  | AssistantMessage
  | SystemMessage
  | ProgressMessage
  | AttachmentMessage;

export type UserMessage = {
  role: 'user';
  content: Content[];
  timestamp: number;
};

export type AssistantMessage = {
  role: 'assistant';
  content: Content[];
  toolUseResults?: ToolUseResult[];
};

export type SystemMessage = {
  role: 'system';
  content: string;
  type?: 'local_command' | 'default';
};
```

### 2. 工具类型 (`types/tools.ts`)

```typescript
export type ToolProgressData =
  | { type: 'bash_progress'; output: string; exitCode: number | null }
  | { type: 'agent_progress'; status: string; output?: string }
  | { type: 'mcp_progress'; serverName: string; status: string }
  | { type: 'web_search_progress'; results: SearchResult[] }
  | { type: 'task_output_progress'; taskId: string; output: string };

export type ToolUseResult = {
  toolUseId: string;
  status: 'success' | 'error';
  content: string | ContentBlock[];
};
```

### 3. 权限类型 (`types/permissions.ts`)

```typescript
export type PermissionMode = 'default' | 'accept' | 'plan' | 'auto';

export type PermissionDecision = 'allow' | 'deny' | 'ask';

export type PermissionResult =
  | { decision: 'allow'; reason: string }
  | { decision: 'deny'; reason: string }
  | { decision: 'ask'; reason: string };
```

### 4. ID 类型 (`types/ids.ts`)

```typescript
export type SessionId = string & { readonly brand: unique symbol };
export type AgentId = string & { readonly brand: unique symbol };
export type ToolUseId = string & { readonly brand: unique symbol };
export type TaskId = string & { readonly brand: unique symbol };
```

---

## 开发模式

### 1. 工具开发

**创建新工具的步骤**:

1. 创建工具目录 `src/tools/MyTool/`
2. 定义输入 Schema
3. 实现工具接口
4. 注册工具

**示例**:
```typescript
// src/tools/MyTool/index.ts
import { z } from 'zod';
import { Tool, ToolResult } from '../../Tool.js';

const MyToolInputSchema = z.object({
  input: z.string().describe('输入参数'),
  option: z.boolean().optional().describe('可选参数'),
});

export const myTool: Tool<typeof MyToolInputSchema, { result: string }> = {
  name: 'MyTool',
  inputSchema: MyToolInputSchema,
  maxResultSizeChars: 100000,
  
  async call(args, context, canUseTool, parentMessage, onProgress) {
    // 1. 验证输入
    // 2. 检查权限
    // 3. 执行逻辑
    // 4. 返回结果
    return {
      data: { result: 'Done' }
    };
  },
  
  async description(input, options) {
    return `执行 MyTool: ${input.input}`;
  },
  
  isEnabled() { return true; },
  isReadOnly(input) { return false; },
  isConcurrencySafe(input) { return false; },
};
```

**注册工具** (`src/tools.ts`):
```typescript
import { myTool } from './tools/MyTool/index.js';

export function getTools(context: ToolPermissionContext): Tools {
  return [
    // ... 其他工具
    myTool,
  ];
}
```

### 2. 命令开发

**创建新命令**:

```typescript
// src/commands/myCommand.ts
import { Command } from '../commands.js';

export const myCommand: Command = {
  name: 'my-command',
  description: '我的命令',
  
  async action(args, context) {
    // 命令逻辑
  },
  
  // 可选：子命令
  subcommands?: {
    'sub': subCommand,
  },
};
```

**注册命令** (`src/commands.ts`):
```typescript
import { myCommand } from './commands/myCommand.js';

export const commands: Command[] = [
  // ... 其他命令
  myCommand,
];
```

### 3. Hook 开发

**配置 Hook** (在 `settings.json`):
```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "echo 'Tool: {{tool_name}}'"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": "eslint {{tool_input.file_path}}"
          }
        ]
      }
    ]
  }
}
```

### 4. MCP 服务器开发

**配置 MCP 服务器**:
```json
{
  "mcpServers": {
    "my-server": {
      "command": "node",
      "args": ["path/to/server.js"],
      "env": {
        "API_KEY": "xxx"
      }
    }
  }
}
```

---

## React 组件开发

### 1. 基本组件

```tsx
// src/components/MyComponent.tsx
import React from 'react';
import { Box, Text } from 'ink';
import { useAppState } from '../hooks/useAppState.js';

export const MyComponent: React.FC = () => {
  const { state, setState } = useAppState();
  
  return (
    <Box flexDirection="column">
      <Text>Hello, World!</Text>
    </Box>
  );
};
```

### 2. 带输入处理的组件

```tsx
import React, { useState } from 'react';
import { Box, Text, useInput } from 'ink';

export const InputComponent: React.FC = () => {
  const [value, setValue] = useState('');
  
  useInput((input, key) => {
    if (key.return) {
      // 处理提交
    } else if (key.backspace || key.delete) {
      setValue(prev => prev.slice(0, -1));
    } else {
      setValue(prev => prev + input);
    }
  });
  
  return (
    <Box>
      <Text>{value}</Text>
      <Text dimColor>█</Text>
    </Box>
  );
};
```

### 3. 带焦点的组件

```tsx
import React from 'react';
import { Box, Text, useFocus } from 'ink';

export const FocusableItem: React.FC<{ label: string }> = ({ label }) => {
  const { isFocused } = useFocus();
  
  return (
    <Box
      borderStyle={isFocused ? 'single' : undefined}
      borderColor={isFocused ? 'green' : undefined}
    >
      <Text color={isFocused ? 'green' : 'white'}>{label}</Text>
    </Box>
  );
};
```

---

## 测试

### 1. 单元测试

```typescript
// __tests__/utils/myFunction.test.ts
import { describe, it, expect } from 'bun:test';
import { myFunction } from '../../src/utils/myFunction.js';

describe('myFunction', () => {
  it('should return expected result', () => {
    expect(myFunction('input')).toBe('expected');
  });
});
```

### 2. 工具测试

```typescript
// __tests__/tools/MyTool.test.ts
import { describe, it, expect, mock } from 'bun:test';
import { myTool } from '../../src/tools/MyTool/index.js';
import { createMockContext } from '../helpers.js';

describe('MyTool', () => {
  it('should execute correctly', async () => {
    const context = createMockContext();
    const result = await myTool.call(
      { input: 'test' },
      context,
      mock(() => ({ decision: 'allow' })),
      createMockMessage(),
      undefined
    );
    
    expect(result.data.result).toBe('Done');
  });
});
```

---

## 调试技巧

### 1. 启用调试日志

```bash
# 启用调试输出
DEBUG=1 claude

# 启用详细输出
claude --verbose

# 启用遥测调试
CLAUDE_DEBUG_TELEMETRY=1 claude
```

### 2. 日志文件

日志位置: `~/.claude/logs/`

```bash
# 查看最新日志
tail -f ~/.claude/logs/$(date +%Y-%m-%d).log
```

### 3. 状态检查

```bash
# 检查配置
claude config list

# 检查 MCP 服务器状态
claude mcp list

# 检查权限设置
claude permissions show
```

---

## 性能优化

### 1. 懒加载

```typescript
// 使用动态导入延迟加载大模块
const heavyModule = await import('./heavyModule.js');
```

### 2. 缓存

```typescript
// 使用 LRU 缓存
import { LRUCache } from 'lru-cache';

const cache = new LRUCache<string, Data>({
  max: 100,
  ttl: 1000 * 60 * 5, // 5 分钟
});
```

### 3. 批量操作

```typescript
// 批量更新状态
store.batch([
  { path: 'a.b', value: 1 },
  { path: 'c.d', value: 2 },
]);
```

---

## 安全最佳实践

### 1. 输入验证

```typescript
// 始终验证用户输入
const schema = z.object({
  path: z.string().max(1024),
  content: z.string().max(10_000_000),
});
```

### 2. 路径安全

```typescript
// 验证路径在允许的目录内
import { isPathAllowed } from '../utils/permissions/filesystem.js';

if (!isPathAllowed(path, allowedDirs)) {
  throw new Error('Path not allowed');
}
```

### 3. 命令注入防护

```typescript
// 避免直接拼接命令
// 错误
const cmd = `echo ${userInput}`;

// 正确
import { escapeShellArg } from '../utils/shell.js';
const cmd = `echo ${escapeShellArg(userInput)}`;
```

---

## 常见问题

### 1. 模块加载失败

**问题**: `Cannot find module 'xxx'`

**解决**:
```bash
# 检查模块是否存在
bun install
```

### 2. 权限问题

**问题**: 工具调用被拒绝

**解决**:
```bash
# 检查权限设置
claude permissions show

# 重置权限
claude permissions reset
```

### 3. MCP 连接失败

**问题**: MCP 服务器无法连接

**解决**:
```bash
# 检查 MCP 配置
claude mcp list

# 重启 MCP 服务器
claude mcp restart <server-name>
```

---

## 贡献指南

### 代码风格

- 使用 TypeScript
- 遵循 ESLint 规则
- 保持函数简洁
- 添加类型注解

### 提交规范

```
type(scope): description

[optional body]

[optional footer]
```

类型:
- `feat`: 新功能
- `fix`: Bug 修复
- `docs`: 文档更新
- `refactor`: 重构
- `test`: 测试
- `chore`: 构建/工具

---

## 总结

本指南涵盖了 Claude Code CLI 开发的主要方面：

1. **项目结构**: 了解代码组织
2. **工具函数**: 常用工具和模式
3. **类型系统**: TypeScript 类型定义
4. **开发模式**: 如何扩展功能
5. **测试**: 确保代码质量
6. **调试**: 问题排查技巧
7. **安全**: 最佳实践
8. **贡献**: 如何参与开发
