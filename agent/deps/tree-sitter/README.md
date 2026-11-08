# deps/tree-sitter — vendored C sources

tree-sitter（MIT）核心 + 六个语法的 parser，服务于编辑后语法校验
（docs/harness-efficiency-plan.md 之外的 ③ 里程碑 1，2026-11-08 vendor）。

| 目录 | 来源（shallow clone, 2026-11-08） | 说明 |
|---|---|---|
| `lib/` | github.com/tree-sitter/tree-sitter | 核心；`lib/src/lib.c` 伞形包含全部 .c |
| `python/` | github.com/tree-sitter/tree-sitter-python | parser.c + scanner.c |
| `javascript/` | github.com/tree-sitter/tree-sitter-javascript | parser.c + scanner.c |
| `typescript/` | github.com/tree-sitter/tree-sitter-typescript（typescript/） | parser.c + scanner.c |
| `tsx/` | github.com/tree-sitter/tree-sitter-typescript（tsx/） | parser.c + scanner.c |
| `java/` | github.com/tree-sitter/tree-sitter-java | 仅 parser.c（无外部 scanner） |
| `zig/` | github.com/maxxnino/tree-sitter-zig | 仅 parser.c |

各目录保留上游 LICENSE。升级方式：浅克隆对应仓库 → 覆盖 `src/` 下的
parser.c / scanner.c / tree_sitter/parser.h（核心覆盖 `lib/`）。

构建接入见 build.zig（`addTreeSitter`）：所有源编进 root/test 模块，无需
分库——现代 tree-sitter 的 scanner 符号带语言前缀
（`tree_sitter_<lang>_external_scanner_*`），无链接冲突。

体积注记：六语法合计约 31MB 源码（TypeScript 双语法最大，各 8MB+）；
编译进二进制的增量见发版产物（预期 +1-2MB，实际以 strip 后为准）。
