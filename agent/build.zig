const std = @import("std");

/// tree-sitter（③ 里程碑 1）：核心 + 六语法全部编进模块。scanner 符号
/// 带语言前缀（现代 tree-sitter 惯例），无链接冲突，无需分静态库。
/// 每语法需要自己的 include 路径（scanner.c include "tree_sitter/parser.h"）。
fn addTreeSitter(b: *std.Build, mod: *std.Build.Module) void {
    // -O2 恒定：tree-sitter 是查表密集型 C，-O0 下 1MB python 解析要 2s
    // （实测 2026-11-08），交互回合不可接受；Zig 侧照旧跟随全局 optimize。
    // -std=gnu11（不是 c11）：核心的 parser.c/tree.c 调 POSIX fdopen()
    // （dot-graph 调试输出），严格 ISO 模式下 musl 头不暴露其声明——
    // macOS/BSD libc 恰好暴露所以本机过、交叉 linux-musl 炸（发版
    // 2026-11-09 实测四缺二）。gnu 模式恒暴露 POSIX/BSD 扩展。
    mod.addCSourceFiles(.{
        .files = &.{
            "deps/tree-sitter/lib/src/lib.c",
            "deps/tree-sitter/python/src/parser.c",
            "deps/tree-sitter/python/src/scanner.c",
            "deps/tree-sitter/javascript/src/parser.c",
            "deps/tree-sitter/javascript/src/scanner.c",
            "deps/tree-sitter/typescript/src/parser.c",
            "deps/tree-sitter/typescript/src/scanner.c",
            "deps/tree-sitter/tsx/src/parser.c",
            "deps/tree-sitter/tsx/src/scanner.c",
            "deps/tree-sitter/java/src/parser.c",
            "deps/tree-sitter/zig/src/parser.c",
        },
        .flags = &.{ "-std=gnu11", "-O2" },
    });
    mod.addIncludePath(b.path("deps/tree-sitter/lib/include"));
    mod.addIncludePath(b.path("deps/tree-sitter/lib/src"));
    inline for (.{ "python", "javascript", "typescript", "tsx", "java", "zig" }) |lang| {
        mod.addIncludePath(b.path("deps/tree-sitter/" ++ lang ++ "/src"));
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // utf8proc C 头的 Zig 绑定（0.17 的 @cImport 已移除——translate-c
    // 是官方替代路径，产物作为普通模块引入）。
    const utf8proc_tc = b.addTranslateC(.{
        .root_source_file = b.path("deps/utf8proc/utf8proc.h"),
        .target = target,
        .optimize = optimize,
    });
    const utf8proc_mod = utf8proc_tc.createModule();

    // tree-sitter api.h 的 Zig 绑定（与 utf8proc 同路径：translate-c）。
    const ts_tc = b.addTranslateC(.{
        .root_source_file = b.path("deps/tree-sitter/lib/include/tree_sitter/api.h"),
        .target = target,
        .optimize = optimize,
    });
    const ts_mod = ts_tc.createModule();

    // Root module with SQLite C source
    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .strip = b.option(bool, "strip", "Strip debug symbols from the binary") orelse false,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_mod.addCSourceFiles(.{
        .files = &.{
                "deps/sqlite3/sqlite3.c",
                "deps/utf8proc/utf8proc.c",
            },
        .flags = &.{
            "-DSQLITE_THREADSAFE=0",
            "-DUTF8PROC_STATIC",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DEFAULT_journal_mode=WAL",
            "-DSQLITE_ENABLE_FTS5",
        },
    });
    root_mod.addIncludePath(b.path("deps/sqlite3"));
    // sqlite-vec：静态链接（-DSQLITE_CORE 不走 load_extension API）。
    root_mod.addCSourceFile(.{
        .file = b.path("deps/sqlite_vec/sqlite-vec.c"),
        .flags = &.{"-DSQLITE_CORE"},
    });
    root_mod.addImport("utf8proc", utf8proc_mod);
    addTreeSitter(b, root_mod);
    root_mod.addImport("treesitter", ts_mod);

    // Main executable
    const exe = b.addExecutable(.{
        .name = "ziv",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    // Run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the zage agent");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addCSourceFiles(.{
        .files = &.{
                "deps/sqlite3/sqlite3.c",
                "deps/utf8proc/utf8proc.c",
            },
        .flags = &.{
            "-DSQLITE_THREADSAFE=0",
            "-DUTF8PROC_STATIC",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DEFAULT_journal_mode=WAL",
            "-DSQLITE_ENABLE_FTS5",
        },
    });
    test_mod.addIncludePath(b.path("deps/sqlite3"));
    test_mod.addCSourceFile(.{
        .file = b.path("deps/sqlite_vec/sqlite-vec.c"),
        .flags = &.{"-DSQLITE_CORE"},
    });
    test_mod.addImport("utf8proc", utf8proc_mod);
    addTreeSitter(b, test_mod);
    test_mod.addImport("treesitter", ts_mod);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
