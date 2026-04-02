# Claude Code CLI - Ink 终端 UI 框架详解

## 概述

Ink 是一个基于 React 的终端 UI 渲框架，用于构建命令行交互界面。它将 React 的组件化模型和声明式编程引入终端环境。

**位置**: `src/ink/`

---

## 目录结构

```
src/ink/
├── layout/                   # 布局引擎
│   ├── engine.ts             # 布局计算核心
│   ├── geometry.ts           # 几何计算工具
│   ├── node.ts               # 布局节点定义
│   └── yoga.ts               # Yoga 布局引擎绑定
│
├── events/                   # 事件系统
│   ├── dispatcher.ts         # 事件分发器
│   ├── emitter.ts            # 事件发射器
│   ├── event.ts              # 事件基类
│   ├── event-handlers.ts     # 事件处理器
│   ├── focus-event.ts        # 焦点事件
│   ├── input-event.ts        # 输入事件
│   ├── click-event.ts        # 点击事件
│   ├── keyboard-event.ts     # 键盘事件
│   ├── terminal-event.ts     # 终端事件
│   ├── terminal-focus-event.ts
│   └── terminal-focus-state.ts
│
├── hooks/                    # React Hooks
│   ├── use-app.ts            # 应用实例 Hook
│   ├── use-input.ts          # 输入处理 Hook
│   ├── use-stdin.ts          # 标准输入 Hook
│   ├── use-stdout.ts         # 标准输出 Hook
│   ├── use-stderr.ts         # 标准错误 Hook
│   ├── use-focus.ts          # 焦点管理 Hook
│   ├── use-selection.ts      # 文本选择 Hook
│   ├── use-terminal-focus.ts # 终端焦点 Hook
│   ├── use-terminal-viewport.ts
│   ├── use-animation-frame.ts
│   ├── use-declared-cursor.ts
│   ├── use-interval.ts       # 定时器 Hook
│   ├── use-search-highlight.ts
│   ├── use-tab-status.ts
│   └── use-terminal-title.ts
│
├── components/               # React Context 组件
│   ├── AppContext.ts         # 应用上下文
│   ├── StdinContext.ts       # 标准输入上下文
│   ├── CursorDeclarationContext.ts
│   └── ...
│
├── termio/                   # 终端 I/O 处理
│   ├── parser.ts             # 输入解析器
│   ├── tokenizer.ts          # 分词器
│   ├── types.ts              # 类型定义
│   ├── ansi.ts               # ANSI 转义码
│   ├── csi.ts                # CSI (Control Sequence Introducer)
│   ├── osc.ts                # OSC (Operating System Command)
│   ├── sgr.ts                # SGR (Select Graphic Rendition)
│   ├── dec.ts                # DEC 私有模式
│   └── esc.ts                # 转义序列
│
├── renderer.ts               # 主渲染器
├── reconciler.ts             # React 协调器
├── terminal.ts               # 终端接口
├── screen.ts                 # 屏幕管理
├── output.ts                 # 输出处理
├── frame.ts                  # 帧管理
├── dom.ts                    # DOM 操作
├── instances.ts              # 实例管理
├── node-cache.ts             # 节点缓存
├── line-width-cache.ts       # 行宽缓存
│
├── wrap-text.ts              # 文本换行
├── wrap-ansi.ts              # ANSI 换行
├── measure-text.ts           # 文本测量
├── measure-element.ts        # 元素测量
├── string-width.ts           # 字符串宽度计算
├── widest-line.ts            # 最宽行计算
│
├── colorize.ts               # 颜色处理
├── styles.ts                 # 样式定义
├── render-border.ts          # 边框渲染
├── render-node-to-output.ts  # 节点渲染
├── render-to-screen.ts       # 屏幕渲染
│
├── focus.ts                  # 焦点管理
├── selection.ts              # 选择管理
├── hit-test.ts               # 点击测试
│
├── bidi.ts                   # 双向文本支持
├── squash-text-nodes.ts      # 文本节点合并
├── optimizer.ts              # 渲染优化
├── tabstops.ts               # 制表符处理
│
├── log-update.ts             # 日志更新
├── parse-keypress.ts         # 按键解析
└── ...
```

---

## 核心架构

### 1. 渲染流程

```
┌─────────────────────────────────────────────────────────────┐
│                    React 组件树                              │
│              <Box><Text>Hello</Text></Box>                  │
└───────────────────────────┬─────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│                   Reconciler (协调器)                        │
│           将 React 组件转换为 Fiber 树                        │
└───────────────────────────┬─────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│                   Fiber 树 (虚拟 DOM)                        │
│              内部表示，包含布局属性                            │
└───────────────────────────┬─────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│                Layout Engine (布局引擎)                      │
│           使用 Yoga 计算 Flexbox 布局                        │
└───────────────────────────┬─────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│                   Output String (输出)                       │
│          包含 ANSI 转义码的最终字符串                         │
└───────────────────────────┬─────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│                      Terminal (终端)                         │
│                   显示最终输出                               │
└─────────────────────────────────────────────────────────────┘
```

### 2. 协调器 (Reconciler)

**位置**: `src/ink/reconciler.ts`

协调器负责将 React 组件树转换为内部 Fiber 树，处理组件更新和生命周期。

```typescript
import ReactReconciler from 'react-reconciler';

const reconciler = ReactReconciler({
  // 创建实例
  createInstance(type, props) {
    const node = createDOMNode(type, props);
    return node;
  },

  // 创建文本实例
  createTextInstance(text) {
    return createTextNode(text);
  },

  // 添加子节点
  appendChild(parent, child) {
    parent.appendChild(child);
  },

  // 插入子节点
  insertBefore(parent, child, beforeChild) {
    parent.insertBefore(child, beforeChild);
  },

  // 移除子节点
  removeChild(parent, child) {
    parent.removeChild(child);
  },

  // 提交更新
  commitUpdate(node, updatePayload, type, oldProps, newProps) {
    node.updateProps(newProps);
  },

  // ... 其他配置
});
```

### 3. 布局引擎

**位置**: `src/ink/layout/`

布局引擎使用 [Yoga](https://yogalayout.com/)（Facebook 的跨平台布局引擎）进行 Flexbox 布局计算。

#### engine.ts - 布局计算核心

```typescript
export class LayoutEngine {
  private yogaNode: Yoga.Node;

  calculate(rootNode: LayoutNode): LayoutResult {
    // 1. 构建 Yoga 节点树
    const yogaRoot = this.buildYogaTree(rootNode);

    // 2. 计算布局
    yogaRoot.calculateLayout(
      availableWidth,
      availableHeight,
      Yoga.DIRECTION_LTR
    );

    // 3. 提取计算结果
    return this.extractLayout(yogaRoot);
  }

  private buildYogaTree(node: LayoutNode): Yoga.Node {
    const yogaNode = Yoga.Node.create();

    // 设置 Flexbox 属性
    if (node.style.flexDirection) {
      yogaNode.setFlexDirection(mapFlexDirection(node.style.flexDirection));
    }
    if (node.style.padding) {
      yogaNode.setPadding(Yoga.EDGE_ALL, node.style.padding);
    }
    // ... 更多属性

    // 递归处理子节点
    for (const child of node.children) {
      yogaNode.insertChild(this.buildYogaTree(child), yogaNode.getChildCount());
    }

    return yogaNode;
  }
}
```

#### geometry.ts - 几何类型

```typescript
export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface Point {
  x: number;
  y: number;
}

export interface Size {
  width: number;
  height: number;
}

export interface Edges {
  top: number;
  right: number;
  bottom: number;
  left: number;
}
```

#### node.ts - 布局节点

```typescript
export interface LayoutNode {
  type: string;
  props: NodeProps;
  style: Style;
  children: LayoutNode[];
  layout?: LayoutResult;
}

export interface NodeProps {
  width?: number | string;
  height?: number | string;
  minWidth?: number;
  minHeight?: number;
  maxWidth?: number;
  maxHeight?: number;
  padding?: number | Edges;
  margin?: number | Edges;
  flexDirection?: 'row' | 'column' | 'row-reverse' | 'column-reverse';
  justifyContent?: 'flex-start' | 'center' | 'flex-end' | 'space-between' | 'space-around';
  alignItems?: 'flex-start' | 'center' | 'flex-end' | 'stretch';
  flexWrap?: 'nowrap' | 'wrap' | 'wrap-reverse';
  flexGrow?: number;
  flexShrink?: number;
  flexBasis?: number | string;
  // ...
}
```

---

## 事件系统

**位置**: `src/ink/events/`

### 事件类型

#### 1. 键盘事件 (keyboard-event.ts)

```typescript
export class KeyboardEvent extends Event {
  readonly type = 'keyboard';

  constructor(
    public key: string,
    public modifiers: KeyModifiers
  ) {
    super();
  }

  get shift() { return this.modifiers.shift; }
  get ctrl() { return this.modifiers.ctrl; }
  get alt() { return this.modifiers.alt; }
  get meta() { return this.modifiers.meta; }
}

export interface KeyModifiers {
  shift: boolean;
  ctrl: boolean;
  alt: boolean;
  meta: boolean;
}
```

#### 2. 点击事件 (click-event.ts)

```typescript
export class ClickEvent extends Event {
  readonly type = 'click';

  constructor(
    public x: number,
    public y: number,
    public button: MouseButton,
    public modifiers: KeyModifiers
  ) {
    super();
  }
}

export type MouseButton = 'left' | 'right' | 'middle' | 'wheel';
```

#### 3. 焦点事件 (focus-event.ts)

```typescript
export class FocusEvent extends Event {
  readonly type: 'focus' | 'blur';

  constructor(
    public target: FiberNode,
    public relatedTarget?: FiberNode
  ) {
    super();
  }
}
```

#### 4. 输入事件 (input-event.ts)

```typescript
export class InputEvent extends Event {
  readonly type = 'input';

  constructor(public data: string) {
    super();
  }
}
```

#### 5. 终端事件 (terminal-event.ts)

```typescript
export class TerminalResizeEvent extends Event {
  readonly type = 'terminal_resize';

  constructor(
    public columns: number,
    public rows: number
  ) {
    super();
  }
}
```

### 事件分发器 (dispatcher.ts)

```typescript
export class EventDispatcher {
  private listeners: Map<string, Set<EventListener>> = new Map();

  addEventListener(type: string, listener: EventListener): void {
    if (!this.listeners.has(type)) {
      this.listeners.set(type, new Set());
    }
    this.listeners.get(type)!.add(listener);
  }

  removeEventListener(type: string, listener: EventListener): void {
    this.listeners.get(type)?.delete(listener);
  }

  dispatchEvent(event: Event): boolean {
    const listeners = this.listeners.get(event.type);
    if (!listeners) return true;

    for (const listener of listeners) {
      listener(event);
    }
    return true;
  }
}
```

---

## React Hooks

### 1. useApp

**位置**: `src/ink/hooks/use-app.ts`

```typescript
export function useApp(): AppInstance {
  const app = useContext(AppContext);
  return app;
}

export interface AppInstance {
  // 退出应用
  exit(errorCode?: number): void;

  // 等待退出
  waitUntilExit(): Promise<void>;

  // 内部状态
  readonly stdin: NodeJS.ReadStream;
  readonly stdout: NodeJS.WriteStream;
  readonly stderr: NodeJS.WriteStream;
}
```

**使用示例**:
```tsx
const App = () => {
  const { exit } = useApp();

  useInput((input) => {
    if (input === 'q') {
      exit(0);
    }
  });

  return <Text>Press Q to exit</Text>;
};
```

### 2. useInput

**位置**: `src/ink/hooks/use-input.ts`

```typescript
export function useInput(
  handler: InputHandler,
  options?: UseInputOptions
): void {
  const { stdin } = useStdin();
  const isActive = options?.isActive ?? true;

  useEffect(() => {
    if (!isActive) return;

    const onInput = (data: Buffer) => {
      const { input, key } = parseKeypress(data.toString());
      handler(input, key);
    };

    stdin.on('data', onInput);
    return () => stdin.off('data', onInput);
  }, [handler, isActive, stdin]);
}

export interface Key {
  upArrow: boolean;
  downArrow: boolean;
  leftArrow: boolean;
  rightArrow: boolean;
  return: boolean;
  escape: boolean;
  ctrl: boolean;
  shift: boolean;
  meta: boolean;
  tab: boolean;
  backspace: boolean;
  delete: boolean;
  pageUp: boolean;
  pageDown: boolean;
  home: boolean;
  end: boolean;
}
```

**使用示例**:
```tsx
const InputDemo = () => {
  const [position, setPosition] = useState({ x: 0, y: 0 });

  useInput((input, key) => {
    if (key.upArrow) setPosition(p => ({ ...p, y: p.y - 1 }));
    if (key.downArrow) setPosition(p => ({ ...p, y: p.y + 1 }));
    if (key.leftArrow) setPosition(p => ({ ...p, x: p.x - 1 }));
    if (key.rightArrow) setPosition(p => ({ ...p, x: p.x + 1 }));
  });

  return <Text>Position: ({position.x}, {position.y})</Text>;
};
```

### 3. useFocus

**位置**: `src/ink/hooks/use-focus.ts`

```typescript
export function useFocus(options?: UseFocusOptions): UseFocusResult {
  const { isFocused, focus, blur } = useFocusContext();
  const autoFocus = options?.autoFocus ?? false;
  const isActive = options?.isActive ?? true;

  useEffect(() => {
    if (autoFocus && isActive) {
      focus();
    }
  }, [autoFocus, isActive]);

  return { isFocused, focus, blur };
}

export interface UseFocusOptions {
  autoFocus?: boolean;
  isActive?: boolean;
}

export interface UseFocusResult {
  isFocused: boolean;
  focus: () => void;
  blur: () => void;
}
```

**使用示例**:
```tsx
const FocusableItem = ({ label }: { label: string }) => {
  const { isFocused } = useFocus();

  return (
    <Box borderStyle={isFocused ? 'single' : undefined}>
      <Text color={isFocused ? 'green' : 'white'}>{label}</Text>
    </Box>
  );
};
```

### 4. useStdin / useStdout / useStderr

**位置**: `src/ink/hooks/use-stdin.ts`

```typescript
export function useStdin(): StdinContextValue {
  return useContext(StdinContext);
}

export interface StdinContextValue {
  stdin: NodeJS.ReadStream;
  setRawMode: (mode: boolean) => void;
  isRawModeSupported: boolean;
}

export function useStdout(): StdoutContextValue {
  return useContext(StdoutContext);
}

export interface StdoutContextValue {
  stdout: NodeJS.WriteStream;
  write: (data: string) => void;
}
```

### 5. useSelection

**位置**: `src/ink/hooks/use-selection.ts`

```typescript
export function useSelection(): UseSelectionResult {
  const [selection, setSelection] = useState<Selection | null>(null);

  // 处理鼠标选择事件
  // ...

  return {
    selection,
    setSelection,
    clearSelection: () => setSelection(null),
  };
}
```

### 6. useTerminalFocus

**位置**: `src/ink/hooks/use-terminal-focus.ts`

```typescript
export function useTerminalFocus(): { isFocused: boolean } {
  const [isFocused, setIsFocused] = useState(true);

  useEffect(() => {
    // 监听终端焦点事件
    const onFocus = () => setIsFocused(true);
    const onBlur = () => setIsFocused(false);

    // ... 绑定事件

    return () => {
      // 清理事件监听
    };
  }, []);

  return { isFocused };
}
```

### 7. useAnimationFrame

**位置**: `src/ink/hooks/use-animation-frame.ts`

```typescript
export function useAnimationFrame(
  callback: () => void,
  options?: UseAnimationFrameOptions
): void {
  const isActive = options?.isActive ?? true;

  useEffect(() => {
    if (!isActive) return;

    let frameId: number;
    const loop = () => {
      callback();
      frameId = requestAnimationFrame(loop);
    };

    frameId = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(frameId);
  }, [callback, isActive]);
}
```

### 8. useInterval

**位置**: `src/ink/hooks/use-interval.ts`

```typescript
export function useInterval(
  callback: () => void,
  delay: number | null,
  options?: UseIntervalOptions
): void {
  const isActive = options?.isActive ?? true;

  useEffect(() => {
    if (delay === null || !isActive) return;

    const id = setInterval(callback, delay);
    return () => clearInterval(id);
  }, [callback, delay, isActive]);
}
```

---

## 终端 I/O 处理

**位置**: `src/ink/termio/`

### 解析器 (parser.ts)

```typescript
export class TerminalParser {
  parse(data: string): ParsedSequence[] {
    const sequences: ParsedSequence[] = [];
    let i = 0;

    while (i < data.length) {
      if (data[i] === '\x1b') {
        // 解析转义序列
        const result = this.parseEscape(data, i);
        sequences.push(result.sequence);
        i = result.newIndex;
      } else {
        // 普通字符
        sequences.push({ type: 'text', value: data[i] });
        i++;
      }
    }

    return sequences;
  }
}
```

### ANSI 转义码 (ansi.ts)

```typescript
export const ANSI = {
  // 控制字符
  ESC: '\x1b',
  BEL: '\x07',
  BS: '\x08',
  HT: '\x09',
  LF: '\x0a',
  VT: '\x0b',
  FF: '\x0c',
  CR: '\x0d',

  // CSI 序列
  CSI: '\x1b[',

  // OSC 序列
  OSC: '\x1b]',

  // DCS 序列
  DCS: '\x1bP',

  // ST (String Terminator)
  ST: '\x1b\\',
};

// 光标控制
export const CURSOR = {
  UP: (n = 1) => `${ANSI.CSI}${n}A`,
  DOWN: (n = 1) => `${ANSI.CSI}${n}B`,
  FORWARD: (n = 1) => `${ANSI.CSI}${n}C`,
  BACK: (n = 1) => `${ANSI.CSI}${n}D`,
  POSITION: (row, col) => `${ANSI.CSI}${row};${col}H`,
  SAVE: `${ANSI.CSI}s`,
  RESTORE: `${ANSI.CSI}u`,
};

// 清屏
export const CLEAR = {
  SCREEN: `${ANSI.CSI}2J`,
  LINE: `${ANSI.CSI}2K`,
  LINE_FROM_CURSOR: `${ANSI.CSI}0K`,
  LINE_TO_CURSOR: `${ANSI.CSI}1K`,
};
```

### SGR (Select Graphic Rendition)

```typescript
// SGR 参数用于设置文本样式
export const SGR = {
  RESET: 0,
  BOLD: 1,
  DIM: 2,
  ITALIC: 3,
  UNDERLINE: 4,
  BLINK: 5,
  REVERSE: 7,
  HIDDEN: 8,
  STRIKETHROUGH: 9,

  // 前景色 (30-37, 38, 39)
  FG_BLACK: 30,
  FG_RED: 31,
  FG_GREEN: 32,
  FG_YELLOW: 33,
  FG_BLUE: 34,
  FG_MAGENTA: 35,
  FG_CYAN: 36,
  FG_WHITE: 37,
  FG_DEFAULT: 39,

  // 背景色 (40-47, 48, 49)
  BG_BLACK: 40,
  BG_RED: 41,
  BG_GREEN: 42,
  // ...
};

// 构建样式字符串
export function sgr(...codes: number[]): string {
  return `${ANSI.CSI}${codes.join(';')}m`;
}
```

---

## 文本处理

### 文本换行 (wrap-text.ts)

```typescript
export function wrapText(
  text: string,
  width: number,
  options?: WrapOptions
): string[] {
  const {
    trim = true,
    wordWrap = true,
    hard = false,
  } = options ?? {};

  // 处理 ANSI 转义码
  const visibleText = stripAnsi(text);

  // 计算换行
  const lines: string[] = [];

  // ... 换行算法

  return lines;
}
```

### 字符串宽度 (string-width.ts)

```typescript
export function stringWidth(text: string): number {
  // 计算字符串的显示宽度
  // 考虑宽字符（中文、emoji）
  // 忽略 ANSI 转义码

  let width = 0;
  const stripped = stripAnsi(text);

  for (const char of stripped) {
    const codePoint = char.codePointAt(0) ?? 0;

    if (isFullWidth(codePoint)) {
      width += 2;
    } else if (!isCombining(codePoint)) {
      width += 1;
    }
  }

  return width;
}

function isFullWidth(codePoint: number): boolean {
  // CJK 字符范围
  // Emoji 等
  return (
    (codePoint >= 0x1100 && codePoint <= 0x115F) ||
    (codePoint >= 0x2329 && codePoint <= 0x232A) ||
    // ... 更多范围
  );
}
```

---

## 渲染器

### 主渲染器 (renderer.ts)

```typescript
export class Renderer {
  private nodeCache: NodeCache;
  private lineWidthCache: LineWidthCache;
  private optimizer: RenderOptimizer;

  render(node: FiberNode): string {
    // 1. 计算布局
    const layout = this.calculateLayout(node);

    // 2. 生成输出
    const output = this.renderNode(node, layout);

    // 3. 优化差异
    const diff = this.optimizer.diff(output, this.lastOutput);

    // 4. 缓存当前输出
    this.lastOutput = output;

    return diff;
  }
}
```

### 节点渲染 (render-node-to-output.ts)

```typescript
export function renderNodeToOutput(
  node: FiberNode,
  options: RenderOptions
): OutputBuffer {
  const buffer = new OutputBuffer(options.width, options.height);

  switch (node.type) {
    case 'box':
      renderBox(buffer, node);
      break;
    case 'text':
      renderText(buffer, node);
      break;
    // ...
  }

  return buffer;
}
```

---

## 优化机制

### 节点缓存 (node-cache.ts)

```typescript
export class NodeCache {
  private cache: Map<string, CachedNode> = new Map();
  private maxSize: number;

  get(id: string): CachedNode | null {
    return this.cache.get(id) ?? null;
  }

  set(id: string, node: CachedNode): void {
    if (this.cache.size >= this.maxSize) {
      // LRU 淘汰
      const firstKey = this.cache.keys().next().value;
      this.cache.delete(firstKey);
    }
    this.cache.set(id, node);
  }
}
```

### 渲染优化 (optimizer.ts)

```typescript
export class RenderOptimizer {
  // 差异检测
  diff(newOutput: string, oldOutput: string): string {
    // 只输出变化的部分
    // 使用 ANSI 光标定位最小化更新
  }
}
```

---

## 使用示例

### 基本应用

```tsx
import React from 'react';
import { render, Box, Text } from 'ink';

const App = () => (
  <Box flexDirection="column" padding={1}>
    <Text color="green" bold>
      Hello, World!
    </Text>
    <Text dimColor>
      Press any key to continue
    </Text>
  </Box>
);

render(<App />);
```

### 带输入处理

```tsx
import React, { useState } from 'react';
import { render, Box, Text, useInput, useApp } from 'ink';

const Counter = () => {
  const [count, setCount] = useState(0);
  const { exit } = useApp();

  useInput((input, key) => {
    if (input === '+') setCount(c => c + 1);
    if (input === '-') setCount(c => c - 1);
    if (key.escape) exit(0);
  });

  return (
    <Box>
      <Text>Count: {count}</Text>
      <Text dimColor> (+/- to change, ESC to exit)</Text>
    </Box>
  );
};

render(<Counter />);
```

### 焦点管理

```tsx
import React from 'react';
import { render, Box, Text, useFocus, useInput } from 'ink';

const MenuItem = ({ label }: { label: string }) => {
  const { isFocused } = useFocus();

  return (
    <Box
      borderStyle={isFocused ? 'single' : undefined}
      borderColor={isFocused ? 'cyan' : undefined}
    >
      <Text
        color={isFocused ? 'cyan' : 'white'}
        bold={isFocused}
      >
        {isFocused ? '❯ ' : '  '}{label}
      </Text>
    </Box>
  );
};

const Menu = () => {
  const [selectedIndex, setSelectedIndex] = useState(0);

  useInput((input, key) => {
    if (key.upArrow) setSelectedIndex(i => Math.max(0, i - 1));
    if (key.downArrow) setSelectedIndex(i => Math.min(2, i + 1));
  });

  return (
    <Box flexDirection="column">
      <MenuItem label="Option 1" />
      <MenuItem label="Option 2" />
      <MenuItem label="Option 3" />
    </Box>
  );
};

render(<Menu />);
```

---

## 总结

Ink 终端 UI 框架的核心特性：

1. **React 模型**: 完整的 React 组件和 Hooks 支持
2. **Flexbox 布局**: 使用 Yoga 引擎进行布局计算
3. **事件系统**: 键盘、鼠标、焦点等完整事件处理
4. **终端适配**: ANSI 转义码、宽字符、双向文本
5. **性能优化**: 节点缓存、增量渲染
6. **TypeScript**: 完整的类型定义

这个框架使得在终端中构建复杂的交互式 UI 成为可能，同时保持了 React 的声明式开发体验。
