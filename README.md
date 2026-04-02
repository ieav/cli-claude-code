# Claude Code CLI - 项目技术文档

> **Claude Code CLI** 是 Anthropic 官方推出的命令行 AI 助手工具，本仓库包含其核心源代码和技术文档。

---

## 📊 项目规模

| 指标 | 数量 |
|------|------|
| TypeScript 源文件 | 1332+ |
| 工具实现 | 40+ |
| UI 组件 | 140+ |
| React Hooks | 85+ |
| 工具函数 | 330+ |
| 服务模块 | 25+ |
| 命令处理器 | 100+ |

---

## 🏗️ 项目整体架构图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              用户命令行输入                                   │
└───────────────────────────────────┬─────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          CLI 入口层 (entrypoints/)                           │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │  cli.tsx    │  │  init.ts    │  │  mcp.ts     │  │  agentSdkTypes.ts   │ │
│  │  命令路由    │  │  初始化     │  │  MCP服务器  │  │  SDK类型定义        │ │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────────────┘ │
└───────────────────────────────────┬─────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           主应用层 (main.tsx)                                │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  REPL 主循环  │  会话管理  │  消息队列  │  工具调用编排  │  错误恢复   │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└───────────────────────────────────┬─────────────────────────────────────────┘
                                    │
          ┌─────────────────────────┼─────────────────────────┐
          │                         │                         │
          ▼                         ▼                         ▼
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Ink UI 框架    │     │   Query 引擎     │     │   Commands 系统  │
│   (src/ink/)    │     │ (QueryEngine.ts) │     │ (commands.ts)   │
│                 │     │                 │     │                 │
│ • React协调器   │     │ • API调用       │     │ • 命令注册表     │
│ • Yoga布局引擎  │     │ • 流式响应      │     │ • 技能系统       │
│ • 事件系统     │     │ • 消息压缩      │     │ • 插件命令       │
│ • 终端I/O      │     │ • 上下文管理    │     │ • MCP命令        │
└────────┬────────┘     └────────┬────────┘     └────────┬────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            工具层 (tools/ + Tool.ts)                         │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         Tool 统一接口                                │   │
│  │  name │ call() │ checkPermissions() │ isReadOnly() │ isEnabled()   │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌──────────┬──────────┬──────────┬──────────┬──────────┬──────────┐      │
│  │ 文件操作  │ Shell执行 │ 搜索查找  │ 网络请求  │ Agent系统 │ 任务管理  │      │
│  ├──────────┼──────────┼──────────┼──────────┼──────────┼──────────┤      │
│  │ Read     │ Bash     │ Grep     │ WebSearch│ Agent    │ TaskCreate│      │
│  │ Write    │PowerShell│ Glob     │ WebFetch │ Skill    │ TaskUpdate│      │
│  │ Edit     │          │          │          │ Team     │ TaskList  │      │
│  │ Notebook │          │          │          │ Message  │ TaskStop  │      │
│  └──────────┴──────────┴──────────┴──────────┴──────────┴──────────┘      │
│                                                                             │
│  ┌──────────┬──────────┬──────────┬──────────┬──────────┐                 │
│  │ MCP工具   │ 计划模式  │ Git工作树 │ 定时任务  │ 交互工具  │                 │
│  ├──────────┼──────────┼──────────┼──────────┼──────────┤                 │
│  │ MCPTool  │EnterPlan │EnterWork │Schedule  │AskQuestion│                │
│  │ MCPResource│ExitPlan │ExitWork  │Cron      │          │                 │
│  │ MCPList  │          │          │          │          │                 │
│  └──────────┴──────────┴──────────┴──────────┴──────────┘                 │
└───────────────────────────────────┬─────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           服务层 (services/)                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │ MCP服务     │  │ LSP服务     │  │ OAuth服务   │  │ 遥测服务            │ │
│  │ (mcp/)      │  │ (lsp/)      │  │ (oauth/)    │  │ (analytics/)       │ │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────────────┘ │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │ 压缩服务    │  │ 工具执行    │  │ 策略限制    │  │ 远程设置            │ │
│  │ (compact/)  │  │ (tools/)    │  │ (policy/)   │  │ (remoteSettings/)   │ │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────────────┘ │
└───────────────────────────────────┬─────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          状态管理层 (state/)                                 │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                          AppState 全局状态                            │  │
│  │  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────────────┐ │  │
│  │  │ messages   │ │ tasks      │ │ settings   │ │ toolPermissionCtx  │ │  │
│  │  │ 消息列表   │ │ 任务状态   │ │ 用户设置   │ │ 工具权限上下文     │ │  │
│  │  └────────────┘ └────────────┘ └────────────┘ └────────────────────┘ │  │
│  │  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────────────┐ │  │
│  │  │ mcp状态    │ │ 插件状态   │ │ 远程控制   │ │ 推测执行状态       │ │  │
│  │  └────────────┘ └────────────┘ └────────────┘ └────────────────────┘ │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  提供 Hooks: useAppState(), useSetAppState(), useAppStateStore()           │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          基础设施层 (utils/ + types/)                        │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │ 文件操作    │  │ Git操作     │  │ 权限管理    │  │ 认证管理            │ │
│  │ (file.js)   │  │ (git.ts)    │  │ (permissions)│ │ (auth.ts)           │ │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────────────┘ │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │ 配置管理    │  │ 会话存储    │  │ Hook系统    │  │ 遥测追踪            │ │
│  │ (config.ts) │  │ (session/)  │  │ (hooks.ts)  │  │ (telemetry/)        │ │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────────────┘ │
│                                                                             │
│  类型定义 (types/): Message, Permission, Tool, Command, Hook, ID           │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 📁 目录结构与文档映射

```
claude-code-i-main/
│
├── 📄 README.md                    ← 你在这里（总索引）
│
├── 📄 PROJECT_ARCHITECTURE.md      ← [架构文档] 分层架构、模块划分、数据流
│
├── 📄 TOOLS_IMPLEMENTATION.md      ← [工具文档] 40+工具的接口和实现
│
├── 📄 INK_UI_FRAMEWORK.md          ← [UI文档] 终端渲染框架详解
│
├── 📄 SERVICES_AND_STATE.md        ← [服务文档] 服务层和状态管理
│
├── 📄 DEVELOPER_GUIDE.md           ← [开发指南] 工具函数、开发模式、最佳实践
│
└── src/                            ← 源代码目录
    │
    ├── entrypoints/                # 入口点模块
    │   ├── cli.tsx                 # CLI 主入口 → [架构文档 §1]
    │   ├── init.ts                 # 初始化逻辑 → [架构文档 §1]
    │   ├── mcp.ts                  # MCP 服务器 → [架构文档 §1]
    │   └── agentSdkTypes.ts        # SDK 类型 → [架构文档 §1]
    │
    ├── main.tsx                    # 主应用逻辑 → [架构文档 §2]
    ├── Tool.ts                     # 工具接口定义 → [工具文档 §1]
    ├── Task.ts                     # 任务类型定义 → [架构文档 §3]
    ├── QueryEngine.ts              # 查询引擎 → [架构文档 §4]
    ├── commands.ts                 # 命令注册 → [架构文档 §5]
    ├── query.ts                    # 查询循环 → [架构文档 §4]
    ├── context.ts                  # 上下文管理 → [架构文档 §6]
    │
    ├── tools/                      # 工具实现 → [工具文档 §2-§6]
    │   ├── AgentTool/              # 子代理系统 → [工具文档 §4.7]
    │   ├── BashTool/               # Shell 执行 → [工具文档 §4.2]
    │   ├── FileReadTool/           # 文件读取 → [工具文档 §4.1]
    │   ├── FileWriteTool/          # 文件写入 → [工具文档 §4.1]
    │   ├── FileEditTool/           # 文件编辑 → [工具文档 §4.1]
    │   ├── GrepTool/               # 内容搜索 → [工具文档 §4.3]
    │   ├── GlobTool/               # 文件查找 → [工具文档 §4.3]
    │   ├── WebSearchTool/          # 网络搜索 → [工具文档 §4.4]
    │   ├── MCPTool/                # MCP 工具 → [工具文档 §4.8]
    │   ├── TaskCreateTool/         # 任务创建 → [工具文档 §4.5]
    │   ├── SkillTool/              # 技能调用 → [工具文档 §4.6]
    │   └── ... (40+ 工具)
    │
    ├── ink/                        # 终端 UI 框架 → [UI文档]
    │   ├── layout/                 # 布局引擎 → [UI文档 §3]
    │   ├── events/                 # 事件系统 → [UI文档 §4]
    │   ├── hooks/                  # React Hooks → [UI文档 §5]
    │   ├── components/             # Context 组件 → [UI文档 §6]
    │   ├── termio/                 # 终端 I/O → [UI文档 §7]
    │   ├── renderer.ts             # 渲染器 → [UI文档 §8]
    │   └── reconciler.ts           # React 协调器 → [UI文档 §2]
    │
    ├── components/                 # UI 组件 → [开发指南 §4]
    │   ├── design-system/          # 设计系统组件
    │   ├── messages/               # 消息组件
    │   ├── permissions/            # 权限组件
    │   └── ... (140+ 组件)
    │
    ├── hooks/                      # 业务 Hooks → [开发指南 §3]
    │   ├── useAppState.ts          # 状态 Hook
    │   ├── useCanUseTool.ts        # 工具权限 Hook
    │   └── ... (85+ Hooks)
    │
    ├── services/                   # 服务层 → [服务文档 §1-§3]
    │   ├── mcp/                    # MCP 服务 → [服务文档 §1]
    │   ├── lsp/                    # LSP 服务 → [服务文档 §2]
    │   ├── oauth/                  # OAuth 服务 → [服务文档 §3]
    │   ├── compact/                # 压缩服务 → [服务文档 §4]
    │   └── ... (25+ 服务)
    │
    ├── state/                      # 状态管理 → [服务文档 §4]
    │   ├── AppState.ts             # 状态定义 → [服务文档 §4.1]
    │   └── AppStateStore.ts        # Store 实现 → [服务文档 §4.2]
    │
    ├── utils/                      # 工具函数 → [开发指南 §2]
    │   ├── file.js                 # 文件操作
    │   ├── git.ts                  # Git 操作
    │   ├── auth.ts                 # 认证管理
    │   ├── permissions/            # 权限系统
    │   └── ... (330+ 工具)
    │
    ├── types/                      # 类型定义 → [开发指南 §3]
    │   ├── message.ts              # 消息类型
    │   ├── permissions.ts          # 权限类型
    │   └── ... (类型定义)
    │
    ├── commands/                   # 命令处理 → [架构文档 §5]
    │   ├── commit.ts               # Git 提交
    │   ├── review.ts               # 代码审查
    │   └── ... (100+ 命令)
    │
    ├── bridge/                     # 远程控制 → [服务文档 §5]
    │   ├── bridgeMain.ts           # Bridge 主入口
    │   └── ...
    │
    ├── vim/                        # Vim 模式 → [架构文档 §7]
    │   ├── motions.ts              # 移动命令
    │   ├── operators.ts            # 操作符
    │   └── ...
    │
    └── migrations/                 # 数据迁移 → [架构文档 §8]
        └── ... (迁移脚本)
```

---

## 📚 文档详情

### 1. [PROJECT_ARCHITECTURE.md](./PROJECT_ARCHITECTURE.md) - 项目架构文档

**内容结构**:
```
PROJECT_ARCHITECTURE.md
├── 1. 项目概述
├── 2. 核心架构设计
│   ├── 2.1 分层架构图
│   └── 2.2 模块详解
├── 3. 入口点模块 (entrypoints/)
│   ├── 3.1 CLI 入口 (cli.tsx)
│   ├── 3.2 初始化模块 (init.ts)
│   ├── 3.3 MCP 服务器 (mcp.ts)
│   └── 3.4 Agent SDK 类型 (agentSdkTypes.ts)
├── 4. 核心模块 (src/ 根目录)
│   ├── 4.1 主应用 (main.tsx)
│   ├── 4.2 工具基类 (Tool.ts)
│   ├── 4.3 任务系统 (Task.ts)
│   ├── 4.4 查询引擎 (QueryEngine.ts)
│   └── 4.5 命令系统 (commands.ts)
├── 5. 工具模块概述 (tools/)
├── 6. Ink 终端 UI 框架简介
├── 7. 数据流和配置系统
├── 8. 权限系统设计
└── 9. MCP 集成说明
```

**适合读者**: 想要了解项目整体架构和模块划分的开发者

---

### 2. [TOOLS_IMPLEMENTATION.md](./TOOLS_IMPLEMENTATION.md) - 工具实现文档

**内容结构**:
```
TOOLS_IMPLEMENTATION.md
├── 1. 工具接口定义 (Tool.ts)
│   ├── 1.1 必需方法
│   ├── 1.2 可选方法
│   └── 1.3 UI 渲染方法
├── 2. 核心工具实现
│   ├── 2.1 BashTool - Shell 命令执行
│   ├── 2.2 FileReadTool - 文件读取
│   ├── 2.3 FileWriteTool - 文件写入
│   ├── 2.4 FileEditTool - 文件编辑
│   ├── 2.5 GlobTool - 文件模式匹配
│   ├── 2.6 GrepTool - 内容搜索
│   ├── 2.7 AgentTool - 子代理系统
│   ├── 2.8 WebSearchTool - 网页搜索
│   ├── 2.9 WebFetchTool - 网页获取
│   ├── 2.10 MCPTool - MCP 工具调用
│   ├── 2.11 Task 系列 - 任务管理
│   ├── 2.12 SkillTool - 技能调用
│   ├── 2.13 AskUserQuestionTool - 用户交互
│   ├── 2.14 EnterPlanModeTool - 计划模式
│   ├── 2.15 NotebookEditTool - Notebook 编辑
│   ├── 2.16 ScheduleCronTool - 定时任务
│   ├── 2.17 LSPTool - 语言服务器
│   ├── 2.18 TodoWriteTool - Todo 列表
│   ├── 2.19 TeamCreateTool/DeleteTool - 团队管理
│   └── 2.20 EnterWorktreeTool/ExitWorktreeTool
├── 3. 工具权限系统
│   ├── 3.1 权限检查流程
│   └── 3.2 权限规则类型
├── 4. 工具注册和发现
├── 5. 工具进度报告
└── 6. 工具结果处理
```

**适合读者**: 想要开发新工具或理解现有工具实现的开发者

---

### 3. [INK_UI_FRAMEWORK.md](./INK_UI_FRAMEWORK.md) - 终端 UI 框架文档

**内容结构**:
```
INK_UI_FRAMEWORK.md
├── 1. 目录结构
├── 2. 核心架构
│   ├── 2.1 渲染流程图
│   ├── 2.2 协调器 (Reconciler)
│   └── 2.3 布局引擎 (Layout Engine)
├── 3. 事件系统 (events/)
│   ├── 3.1 事件类型
│   │   ├── KeyboardEvent
│   │   ├── ClickEvent
│   │   ├── FocusEvent
│   │   ├── InputEvent
│   │   └── TerminalEvent
│   └── 3.2 事件分发器
├── 4. React Hooks (hooks/)
│   ├── 4.1 useApp
│   ├── 4.2 useInput
│   ├── 4.3 useStdin/Stdout/Stderr
│   ├── 4.4 useFocus
│   ├── 4.5 useSelection
│   ├── 4.6 useTerminalFocus
│   ├── 4.7 useAnimationFrame
│   └── 4.8 useInterval
├── 5. 终端 I/O 处理 (termio/)
│   ├── 5.1 解析器 (Parser)
│   ├── 5.2 ANSI 转义码
│   ├── 5.3 CSI 序列
│   └── 5.4 SGR 参数
├── 6. 文本处理
│   ├── 6.1 文本换行
│   ├── 6.2 字符串宽度
│   └── 6.3 双向文本
├── 7. 渲染器
│   ├── 7.1 主渲染器
│   ├── 7.2 节点渲染
│   └── 7.3 屏幕渲染
├── 8. 焦点管理
├── 9. 选择管理
├── 10. 优化机制
└── 11. 使用示例
```

**适合读者**: 想要开发或修改终端 UI 的开发者

---

### 4. [SERVICES_AND_STATE.md](./SERVICES_AND_STATE.md) - 服务与状态文档

**内容结构**:
```
SERVICES_AND_STATE.md
├── 1. 服务模块 (services/)
│   ├── 1.1 MCP 服务 (mcp/)
│   │   ├── 客户端实现
│   │   ├── 服务器管理器
│   │   └── 类型定义
│   ├── 1.2 LSP 服务 (lsp/)
│   ├── 1.3 OAuth 服务 (oauth/)
│   ├── 1.4 分析服务 (analytics/)
│   ├── 1.5 策略限制服务 (policyLimits/)
│   └── 1.6 远程设置服务 (remoteManagedSettings/)
├── 2. 状态管理 (state/)
│   ├── 2.1 AppState 定义
│   ├── 2.2 AppStateStore
│   ├── 2.3 状态更新模式
│   └── 2.4 默认 AppState
├── 3. 上下文系统 (context/)
│   ├── 3.1 通知上下文
│   ├── 3.2 配置上下文
│   └── 3.3 主题上下文
├── 4. 权限系统
│   ├── 4.1 权限模式
│   ├── 4.2 权限规则
│   ├── 4.3 权限检查流程
│   └── 4.4 权限对话框
├── 5. 任务系统
│   ├── 5.1 任务类型
│   ├── 5.2 任务状态
│   └── 5.3 任务状态定义
├── 6. 数据持久化
│   ├── 6.1 配置存储
│   ├── 6.2 任务输出存储
│   └── 6.3 消息历史
└── 7. Hook 系统
    ├── 7.1 PreToolUse / PostToolUse
    └── 7.2 Hook 执行流程
```

**适合读者**: 想要理解后端服务和状态管理的开发者

---

### 5. [DEVELOPER_GUIDE.md](./DEVELOPER_GUIDE.md) - 开发者指南

**内容结构**:
```
DEVELOPER_GUIDE.md
├── 1. 项目结构总览
├── 2. 常用工具函数 (utils/)
│   ├── 2.1 文件操作
│   ├── 2.2 日志系统
│   ├── 2.3 权限管理
│   ├── 2.4 进程管理
│   ├── 2.5 Git 操作
│   ├── 2.6 网络请求
│   ├── 2.7 遥测
│   └── 2.8 系统检测
├── 3. 类型定义参考 (types/)
│   ├── 3.1 消息类型
│   ├── 3.2 工具类型
│   ├── 3.3 权限类型
│   └── 3.4 ID 类型
├── 4. 开发模式
│   ├── 4.1 工具开发（创建新工具）
│   ├── 4.2 命令开发
│   ├── 4.3 Hook 开发
│   └── 4.4 MCP 服务器开发
├── 5. React 组件开发
│   ├── 5.1 基本组件
│   ├── 5.2 带输入处理的组件
│   └── 5.3 带焦点的组件
├── 6. 测试
│   ├── 6.1 单元测试
│   └── 6.2 工具测试
├── 7. 调试技巧
├── 8. 性能优化
├── 9. 安全最佳实践
├── 10. 常见问题
└── 11. 贡献指南
```

**适合读者**: 想要参与项目开发的贡献者

---

## 🔗 文档关联图

```
                    ┌─────────────────────────────────────┐
                    │           README.md                 │
                    │         (总索引/导航)               │
                    └──────────────┬──────────────────────┘
                                   │
         ┌─────────────────────────┼─────────────────────────┐
         │                         │                         │
         ▼                         ▼                         ▼
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│ PROJECT_        │     │ TOOLS_          │     │ INK_UI_         │
│ ARCHITECTURE.md │     │ IMPLEMENTATION  │     │ FRAMEWORK.md    │
│                 │     │ .md             │     │                 │
│ 架构总览        │────▶│ 工具实现详情    │     │ UI框架详情      │
│ 模块划分        │     │                 │     │                 │
│ 数据流          │     │ 依赖:           │     │ 依赖:           │
│                 │     │ • Tool.ts       │     │ • reconciler.ts │
│ 引用:           │     │ • tools/        │     │ • layout/       │
│ • main.tsx      │     │ • services/mcp  │     │ • events/       │
│ • entrypoints/  │     │                 │     │ • hooks/        │
└────────┬────────┘     └────────┬────────┘     └────────┬────────┘
         │                       │                       │
         │                       │                       │
         │         ┌─────────────┴─────────────┐         │
         │         │                           │         │
         │         ▼                           ▼         │
         │  ┌─────────────────┐     ┌─────────────────┐  │
         │  │ SERVICES_AND_   │     │ DEVELOPER_      │  │
         │  │ STATE.md        │     │ GUIDE.md        │  │
         │  │                 │     │                 │  │
         │  │ 服务层实现      │     │ 开发指南        │◀─┘
         │  │ 状态管理        │     │ 工具函数        │
         │  │ 权限系统        │     │ 最佳实践        │
         │  │                 │     │                 │
         │  │ 依赖:           │     │ 引用:           │
         │  │ • state/        │     │ • utils/        │
         │  │ • services/     │     │ • types/        │
         │  │ • context/      │     │ • hooks/        │
         │  └────────┬────────┘     └─────────────────┘
         │           │
         └───────────┴───────────────────────────────────┐
                                                         │
                    ┌────────────────────────────────────┘
                    │
                    ▼
         ┌─────────────────────────────────────┐
         │          源代码 (src/)              │
         │                                     │
         │  entrypoints/  tools/  ink/         │
         │  services/     state/  utils/       │
         │  components/   hooks/   types/      │
         └─────────────────────────────────────┘
```

---

## 🚀 快速开始

### 按角色查找文档

| 角色 | 推荐阅读顺序 |
|------|-------------|
| **新开发者** | README → PROJECT_ARCHITECTURE → DEVELOPER_GUIDE |
| **工具开发者** | PROJECT_ARCHITECTURE → TOOLS_IMPLEMENTATION → DEVELOPER_GUIDE |
| **UI 开发者** | PROJECT_ARCHITECTURE → INK_UI_FRAMEWORK → DEVELOPER_GUIDE |
| **后端开发者** | PROJECT_ARCHITECTURE → SERVICES_AND_STATE → DEVELOPER_GUIDE |
| **架构师** | README → PROJECT_ARCHITECTURE → 所有文档 |

### 按任务查找文档

| 任务 | 文档 | 章节 |
|------|------|------|
| 添加新工具 | TOOLS_IMPLEMENTATION | §1 工具接口定义 |
| 理解渲染流程 | INK_UI_FRAMEWORK | §2 核心架构 |
| 配置权限规则 | SERVICES_AND_STATE | §4 权限系统 |
| 集成 MCP | TOOLS_IMPLEMENTATION | §2.10 MCPTool |
| 管理任务状态 | SERVICES_AND_STATE | §5 任务系统 |
| 处理用户输入 | INK_UI_FRAMEWORK | §4 React Hooks |
| 配置 Hook | DEVELOPER_GUIDE | §4.3 Hook 开发 |
| 调试问题 | DEVELOPER_GUIDE | §7 调试技巧 |

---

## 📋 核心概念速查

### 工具 (Tool)
```typescript
type Tool<Input, Output, Progress> = {
  name: string;
  inputSchema: ZodSchema;
  call(args, context, canUseTool, parentMessage, onProgress): Promise<ToolResult<Output>>;
  isEnabled(): boolean;
  isReadOnly(input): boolean;
  checkPermissions(input, context): Promise<PermissionResult>;
  // ...
}
```
详见: [TOOLS_IMPLEMENTATION.md §1](./TOOLS_IMPLEMENTATION.md#1-工具接口定义)

### 任务 (Task)
```typescript
type TaskType = 
  | 'local_bash'      // Shell 命令
  | 'local_agent'     // 本地 Agent
  | 'remote_agent'    // 远程 Agent
  | 'in_process_teammate'
  | 'local_workflow'
  | 'dream';

type TaskStatus = 'pending' | 'running' | 'completed' | 'failed' | 'killed';
```
详见: [SERVICES_AND_STATE.md §5](./SERVICES_AND_STATE.md#5-任务系统)

### 权限模式
```typescript
type PermissionMode = 
  | 'default'   // 需要确认
  | 'accept'    // 自动接受
  | 'plan'      // 计划模式
  | 'auto';     // 自动模式
```
详见: [SERVICES_AND_STATE.md §4](./SERVICES_AND_STATE.md#4-权限系统)

### 消息类型
```typescript
type Message = 
  | UserMessage         // 用户消息
  | AssistantMessage    // 助手消息
  | SystemMessage       // 系统消息
  | ProgressMessage     // 进度消息
  | AttachmentMessage;  // 附件消息
```
详见: [DEVELOPER_GUIDE.md §3.1](./DEVELOPER_GUIDE.md#3-类型定义参考)

---

## 🔧 技术栈

| 类别 | 技术 |
|------|------|
| 运行时 | Bun / Node.js |
| 语言 | TypeScript |
| UI 框架 | React + Ink |
| 状态管理 | 自定义 Store + React Context |
| API | @anthropic-ai/sdk |
| 验证 | Zod |
| 布局 | Yoga (Flexbox) |
| 工具 | lodash-es, chalk |

---

## 📖 扩展阅读

- [MCP (Model Context Protocol) 规范](https://modelcontextprotocol.io/)
- [LSP (Language Server Protocol) 规范](https://microsoft.github.io/language-server-protocol/)
- [React 文档](https://react.dev/)
- [Yoga 布局引擎](https://yogalayout.com/)
- [Ink 终端 UI](https://github.com/vadimdemedes/ink)

---

## 📌 版本信息

- **文档版本**: 1.0.0
- **生成日期**: 2026-04-02
- **项目版本**: 见 `MACRO.VERSION`

---

*本文档由 Claude Code 自动生成*
