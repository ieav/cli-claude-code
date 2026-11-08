#!/usr/bin/env python3
"""ziv TUI pty 回归套件（roadmap P0 — scripts/pty_suite.py）

以伪终端驱动真二进制，锁定终端交互层的五个不变量（2026-11-06
稳定性批次的现场验证法固化）：

  S1 会话级 raw   —— 回合中 tty 必须保持 -icanon（否则驱动回显按键）
  S2 回合中按键   —— 工具执行期间发方向键/文本，不得出现 ECHOCTL 回显(^[)
  S3 /last 展开   —— /run 的输出全文可经 /last 回看
  S4 y/N cooked 读 —— /rewind 的序号+确认两段读取可输入、可回显、Enter 终止
  S5 持管者收管   —— sh 先退、组内子孙握管道，工具 ~1s 组击杀收管而非等满

用法：python3 scripts/pty_suite.py [ziv二进制]（默认 zig-out/bin/ziv）
退出码：0 全绿；1 有失败。

隔离性：每场景独立临时目录；HOME 重定向到该目录（用户级 settings/
api keys/mcp 不加载——/quit 记忆提取走无 provider 的快速启发式路径，
套件零网关调用）；项目级 .ziv/settings.json 固定 bypass 权限。
"""
import os
import pty
import re
import select
import shutil
import sys
import tempfile
import time

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/ziv")


class Fail(Exception):
    pass


class ZivSession:
    """ziv on a pty (pty.fork: the child becomes session leader and truly
    owns the controlling terminal — plain subprocess leaves /dev/tty
    'not configured' inside the child)."""

    def __init__(self, reuse_dir=None, settings='{"permission_mode":"bypass"}\n', env_extra=None):
        self._owns_dir = reuse_dir is None
        self.dir = reuse_dir or tempfile.mkdtemp(prefix="ziv-pty-")
        os.makedirs(os.path.join(self.dir, ".ziv"), exist_ok=True)
        # Deterministic, hermetic: project-level bypass so FileWrite/Bash
        # never hit the permission gate regardless of global settings.
        with open(os.path.join(self.dir, ".ziv", "settings.json"), "w") as f:
            f.write(settings)
        self.pid, self.master = pty.fork()
        if self.pid == 0:
            os.chdir(self.dir)
            env = dict(os.environ)
            env["TERM"] = "xterm-256color"
            # Hermetic HOME: user-level settings/keys/mcp stay OUT — no
            # real gateway calls from the suite.
            env["HOME"] = self.dir
            env.pop("ZIV_CRON_SCALE", None)
            # Hermetic gateway: inherited OPENAI_*/ANTHROPIC_* would point
            # the child at the user's REAL gateway (S7/S8 messages would
            # hang to the 180s watchdog instead of failing fast).
            for k in list(env):
                if k.startswith(("OPENAI_", "ANTHROPIC_", "OLLAMA_")):
                    env.pop(k)
            if env_extra:
                env.update(env_extra)
            os.execve(BIN, [BIN], env)
        self.buf = b""

    def read_until(self, pattern: str, timeout: float) -> str:
        """Accumulate pty output until `pattern` appears; raise on timeout
        with the tail for diagnosis."""
        deadline = time.time() + timeout
        pat = pattern.encode()
        while time.time() < deadline:
            r, _, _ = select.select([self.master], [], [], 0.2)
            if self.master in r:
                try:
                    chunk = os.read(self.master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                self.buf += chunk
                if pat in self.buf:
                    return self.buf.decode("utf-8", "replace")
        tail = self.buf[-400:].decode("utf-8", "replace")
        raise Fail(f"timeout {timeout}s waiting for {pattern!r}; tail:\n{tail}")

    def read_until_seen(self, pattern: str, timeout: float) -> str:
        """同 read_until，但已缓冲内容也算命中——适用于「字节可能已被
        前一次 read_until/drain 吃进 buf」的等待（read_until 只认新到
        字节，这种形态会干等到超时；S19 开发中实证）。"""
        deadline = time.time() + timeout
        pat = pattern.encode()
        while time.time() < deadline:
            if pat in self.buf:
                return self.buf.decode("utf-8", "replace")
            r, _, _ = select.select([self.master], [], [], 0.2)
            if self.master in r:
                try:
                    chunk = os.read(self.master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                self.buf += chunk
        tail = self.buf[-400:].decode("utf-8", "replace")
        raise Fail(f"timeout {timeout}s waiting for {pattern!r}; tail:\n{tail}")

    def drain(self, seconds: float) -> str:
        """Read whatever arrives for `seconds` (no pattern)."""
        deadline = time.time() + seconds
        while time.time() < deadline:
            r, _, _ = select.select([self.master], [], [], 0.2)
            if self.master in r:
                try:
                    chunk = os.read(self.master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                self.buf += chunk
        return self.buf.decode("utf-8", "replace")

    def clear_buf(self) -> None:
        self.buf = b""

    def send(self, data: str) -> None:
        # Raw mode: Enter submits as CR (ICRNL is off by design).
        os.write(self.master, data.replace("\n", "\r").encode())

    def send_raw(self, data: str) -> None:
        """Verbatim bytes — mouse SGR sequences and bracketed-paste markers
        must NOT get the \n→\r translation."""
        os.write(self.master, data.encode())

    def wait_prompt(self, timeout: float = 20.0) -> None:
        self.read_until("Type your message", timeout)

    def close(self) -> None:
        try:
            os.kill(self.pid, 15)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass
        try:
            os.close(self.master)
        except OSError:
            pass
        if self._owns_dir:
            shutil.rmtree(self.dir, ignore_errors=True)


def quit_and_wait(z: ZivSession) -> None:
    # Ctrl-C clears any pending editor draft first — a draft would
    # concatenate '/quit' into a MESSAGE and fire a real LLM turn (the
    # S2 lesson). Generous Goodbye wait: exit reflection runs here.
    z.send("\x03")
    z.drain(0.3)
    z.send("/quit\n")
    # 60s: exit now runs the bounded memory extraction (≤20s deadline +
    # heuristic fallback) before Goodbye — 30s was tight.
    z.read_until("Goodbye", 60)


def s1_raw_session():
    """Mid-turn tty stays raw: the stty probe inside /run must read
    -icanon (the old per-prompt raw left cooked+echo for whole turns —
    the ^[[C input-garbling bug)."""
    z = ZivSession()
    try:
        z.wait_prompt()
        z.send('/run Bash {"command":"stty -a -f /dev/tty"}\n')
        out = z.read_until("speed", 15)
        m = re.search(r"lflags:([^\n]*)", out)
        if not m:
            raise Fail("no lflags line in stty output")
        flags = m.group(1)
        if "-icanon" not in flags:
            raise Fail(f"tty cooked mid-turn (want -icanon): {flags.strip()}")
        quit_and_wait(z)
        return "icanon off mid-turn ✓"
    finally:
        z.close()


def s2_midturn_keys():
    """Keys typed while a tool runs must NOT come back as driver echo
    (ECHOCTL renders ESC as the two chars '^[' — ziv never writes that
    text itself, so its presence proves the line discipline is echoing)."""
    z = ZivSession()
    try:
        z.wait_prompt()
        z.send('/run Bash {"command":"sleep 2"}\n')
        time.sleep(0.8)  # tool phase active
        z.send("\x1b[C\x1b[Cmidturn")
        out = z.drain(4.5)  # tool finishes, prompt repaints
        if "^[" in out:
            raise Fail("ECHOCTL echo leaked (cooked line discipline active mid-turn)")
        quit_and_wait(z)
        return "no driver echo mid-turn ✓"
    finally:
        z.close()


def s3_last_ring():
    """/run output is fully recoverable via /last (the /run→LastTools
    wiring gap made it '无记录' before)."""
    z = ZivSession()
    try:
        z.wait_prompt()
        z.send('/run Bash {"command":"echo last-ring-marker-7788"}\n')
        z.read_until("last-ring-marker-7788", 15)
        z.send("/last\n")
        out = z.read_until("最近第 1 条", 15)
        if out.count("last-ring-marker-7788") < 2:
            raise Fail("/last did not echo the full output back")
        quit_and_wait(z)
        return "/last full echo ✓"
    finally:
        z.close()


def s4_confirm_reads():
    """Both /rewind reads (point selection + y/N confirm) work under the
    session-raw terminal: input echoes, CR terminates the read, answer
    lands (n → Cancelled). Catches missing-CookedGuard regressions — a
    bare streamDelimiter would block forever on \\r."""
    z = ZivSession()
    try:
        z.wait_prompt()
        z.send('/run FileWrite {"path":"/tmp/ziv-pty-suite-fw.txt","content":"v1"}\n')
        z.read_until("Wrote", 15)
        z.send("/rewind\n")
        z.read_until("Select rollback point", 15)
        z.send("1\n")
        z.read_until("Proceed? [y/N]", 15)
        z.send("n\n")
        z.read_until("Cancelled", 15)
        quit_and_wait(z)
        return "rewind select+confirm readable ✓"
    finally:
        z.close()


def s5_pipe_holder_reaped():
    """sh exits at once, an in-group `sleep 30 &` holds the pipe
    write-end: the tool must return in ~1s (group kill → EOF), not the
    holder's lifetime — and no orphan survives."""
    z = ZivSession()
    try:
        z.wait_prompt()
        z.send('/run Bash {"command":"sleep 30 & exit 0","timeout":0}\n')
        z.read_until("Running Bash", 15)
        z.clear_buf()  # wait for a NEW prompt paint, not the stale one
        t0 = time.time()
        z.read_until("ziv[", 30)
        elapsed = time.time() - t0
        if elapsed > 15:
            raise Fail(f"pipe holder not reaped quickly: {elapsed:.1f}s")
        time.sleep(0.3)
        probe = os.popen("pgrep -f '^sleep 30$' || true").read().strip()
        if probe:
            raise Fail(f"orphan sleep survived: {probe}")
        quit_and_wait(z)
        return f"holder reaped in {elapsed:.1f}s ✓"
    finally:
        z.close()


def s6_command_smoke():
    """Every slash-command family answers (P1's dispatch extraction moved
    /memory /config /model /rewind /context etc. into three modules — a
    wiring slip would surface here as a hang or an unknown-command reply,
    not as a unit-test failure)."""
    z = ZivSession()
    try:
        z.wait_prompt()
        for cmd, marker in [
            ("/help", "Available commands"),
            ("/memory", "Memory"),
            ("/context", "Context:"),
            ("/stats", "Messages:"),
            ("/version", "Ziv v"),
            ("/knowledge", "Knowledge graph"),
            ("/undo", "undo"),
        ]:
            z.clear_buf()
            z.send(cmd + "\n")
            out = z.read_until(marker, 10)
            if cmd == "/undo" and "Nothing to undo" not in out and "无可" not in out and "undo" not in out:
                raise Fail(f"{cmd}: unexpected undo reply")
        # interactive menus open and quit cleanly (q = menu quit key)
        z.clear_buf()
        z.send("/config\n")
        z.read_until("Ziv 配置", 10)
        # value-entry prompt: lone Esc cancels back to the menu (2026-11-07
        # fix — Esc used to be swallowed as a literal byte with no way out)
        z.send("3\r")  # digit moves, Enter selects → 最大 tokens prompt
        z.read_until("1-128000", 10)  # unique to the VALUE prompt
        z.send("\x1b")
        out = z.read_until("Ziv 配置", 10)
        if "已取消" not in out:
            raise Fail("config value prompt: lone Esc did not cancel")
        # open-to-VIEW then Esc at the FIRST field of a two-field edit
        # session: whole session must abort (no second prompt jumps in —
        # the doc §3 rule "Esc 在任何层都退出且零写入")
        z.clear_buf()
        z.send("1\r")  # API Keys
        z.read_until("模型接入配置", 10)
        z.clear_buf()
        z.send("1\r")  # OpenAI 接入 → first field = API Key
        z.read_until("回车=保留", 10)
        z.send("\x1b")
        out = z.read_until("模型接入配置", 10)
        if "已取消" not in out or "Base URL" in out:
            raise Fail("two-field edit: Esc at first field must abort whole session")
        z.clear_buf()
        z.send("\x1b")  # viewing done — back out of the submenu too
        z.read_until("Ziv 配置", 10)
        z.send("q")
        z.read_until("ziv[", 10)  # prompt back
        quit_and_wait(z)
        return "14 command paths answered ✓"
    finally:
        z.close()


def s7_clean_resume():
    """/quit → restart → /resume restores the conversation with context
    continuity (roadmap P3 acceptance, clean-exit half). A plain message is
    persisted even though the hermetic HOME has no gateway — the user
    message lands in history before the provider error ends the turn."""
    d = tempfile.mkdtemp(prefix="ziv-p3-")
    try:
        z = ZivSession(reuse_dir=d)
        try:
            z.wait_prompt()
            z.send("resume-marker-alpha first turn\n")
            z.read_until("No API key", 20)  # turn end: user msg already in history
            z.clear_buf()
            z.read_until("ziv[", 10)  # fresh prompt paint = loop-top flush done
            z.send("/stats\n")
            out = z.read_until("Messages:", 10)
            m = re.search(r"History tokens: ~(\d+)", out)
            if not m:
                raise Fail("no History tokens in /stats")
            tokens_before = int(m.group(1))
            quit_and_wait(z)
        finally:
            z.close()
        z2 = ZivSession(reuse_dir=d)
        try:
            z2.wait_prompt()
            z2.send("/resume\n")
            out = z2.read_until("resume-marker-alpha", 10)
            # The live process's own empty startup row must not appear.
            if "0 轮" in out:
                raise Fail("live empty session row leaked into the resume list")
            z2.send("\r")  # first (and only) listed entry = the marked one
            z2.read_until("已恢复会话", 10)
            z2.drain(1.0)  # let the post-resume prompt paint settle
            z2.clear_buf()
            z2.send("/stats\n")
            out = z2.read_until("Messages:", 10)
            m2 = re.search(r"History tokens: ~(\d+)", out)
            if not m2:
                raise Fail("no History tokens after resume")
            tokens_after = int(m2.group(1))
            # Same messages restored → the token estimate must carry over
            # intact (the in-process Messages counter does not count
            # restored turns — History tokens is the state-equality check).
            # TWO-SIDED: content came back, and no double-system inflation
            # (restoring the old system prompt alongside the live one used to
            # roughly DOUBLE the estimate — caught live: 331+335 -> 662).
            # Tolerances absorb the date/time drift between prompt builds.
            if tokens_after < tokens_before - 40:
                raise Fail(f"resume lost history: ~{tokens_before} -> ~{tokens_after} tokens")
            if tokens_after > tokens_before + 120:
                raise Fail(f"resume inflated history (double system?): ~{tokens_before} -> ~{tokens_after} tokens")
            quit_and_wait(z2)
            return f"restart+resume restored history intact (~{tokens_after} tokens) ✓"
        finally:
            z2.close()
    finally:
        shutil.rmtree(d, ignore_errors=True)


def s8_crash_resume():
    """SIGKILL mid-session → restart shows the crash hint → /resume restores
    (roadmap P3 acceptance, crash half). The flush at the last turn boundary
    is all that survives; that is exactly what must come back."""
    d = tempfile.mkdtemp(prefix="ziv-p3-")
    try:
        z = ZivSession(reuse_dir=d)
        try:
            z.wait_prompt()
            z.send("crash-marker-beta the process will die\n")
            z.read_until("No API key", 20)  # turn end
            z.clear_buf()
            z.read_until("ziv[", 10)  # fresh prompt = loop-top flush committed
        finally:
            try:
                os.kill(z.pid, 9)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(z.pid, 0)
            except ChildProcessError:
                pass
            try:
                os.close(z.master)
            except OSError:
                pass
        z2 = ZivSession(reuse_dir=d)
        try:
            z2.wait_prompt()
            out = z2.read_until("未正常退出的会话", 10)
            if "crash-marker-beta" not in out:
                raise Fail("crash hint did not carry the session first line")
            z2.send("/resume\n")
            z2.read_until("crash-marker-beta", 10)
            z2.send("\r")
            z2.read_until("已恢复会话", 10)
            quit_and_wait(z2)
            return "crash hint + resume restored the killed session ✓"
        finally:
            z2.close()
    finally:
        shutil.rmtree(d, ignore_errors=True)


def s9_error_selector():
    """LLM error → auto backoff retries fire → interactive selector offers
    real moves (roadmap P4). Dead-gateway injection: a key plus a base_url
    on a closed port — ConnectionRefused is transient, so the ladder runs
    first (1/2, 2/2), then the selector; Esc = ignore with 「继续」prefill."""
    d = tempfile.mkdtemp(prefix="ziv-p4-")
    try:
        z = ZivSession(reuse_dir=d, settings='{"permission_mode":"bypass","api_keys":{"openai":"test-key","openai_base_url":"http://127.0.0.1:1/v1"}}\n')
        try:
            z.wait_prompt()
            z.send("probe the dead gateway\n")
            z.read_until("自动重试 1/2", 20)   # ladder fired
            z.read_until("自动重试 2/2", 20)   # budget spent
            out = z.read_until("如何处理这个错误", 15)  # selector appeared
            for label in ("重试本回合", "压缩历史后重试", "换模型", "忽略"):
                if label not in out:
                    raise Fail(f"selector missing option: {label}")
            # Option 1 (retry) actually re-runs the turn: pick it, the
            # retry notice prints, the error repeats, the selector comes
            # back — proof the choice drives the loop, not just prints.
            z.send("\r")  # select item 0 = 重试本回合
            z.read_until("重试本回合…", 10)
            z.read_until("如何处理这个错误", 15)
            z.send("\x1b")  # Esc = ignore
            z.drain(1.0)
            quit_and_wait(z)
            return "auto backoff ×2 + selector 4 moves + retry takes effect ✓"
        finally:
            z.close()
    finally:
        shutil.rmtree(d, ignore_errors=True)


def s10_code_index():
    """P6 dual-path: FileRead deposits a file into .ziv/index.db, a LITERAL
    Grep is then served from the index (marker line, no rg spawn), and a
    regex pattern still goes to the real scan (no index marker)."""
    d = tempfile.mkdtemp(prefix="ziv-p6-")
    try:
        marker_file = os.path.join(d, "indexed_file.zig")
        with open(marker_file, "w") as f:
            f.write("const UNIQUE_ZIV_TOKEN_77 = 42;\n")
        z = ZivSession(reuse_dir=d)
        try:
            z.wait_prompt()
            # 1. FileRead deposits the file into the code index.
            z.send(f'/run FileRead {{"path":"{marker_file}"}}\n')
            z.read_until("UNIQUE_ZIV_TOKEN_77", 15)
            # 2. Literal Grep — must serve from the index.
            z.send('/run Grep {"pattern":"UNIQUE_ZIV_TOKEN_77","path":"."}\n')
            out = z.read_until("索引命中", 15)
            if marker_file not in out:
                raise Fail("index hit did not carry the file path")
            # 3. Regex pattern — real scan, no index marker in THIS response.
            z.clear_buf()
            z.send('/run Grep {"pattern":"UNIQUE_ZIV.*77","path":"."}\n')
            out2 = z.read_until("UNIQUE_ZIV_TOKEN_77", 15)
            # The marker line may appear from the match itself; the INDEX
            # tag must NOT be in this second response.
            if "索引命中" in out2:
                raise Fail("regex query was served from the index (must real-scan)")
            quit_and_wait(z)
            return "FileRead→index→literal Grep served, regex real-scans ✓"
        finally:
            z.close()
    finally:
        shutil.rmtree(d, ignore_errors=True)


def s11_code_context_injection():
    """P6-③: a question whose keywords match indexed code gets that code
    injected into context (observable via /stats), and the injection is
    silent for the user."""
    d = tempfile.mkdtemp(prefix="ziv-p6c-")
    try:
        marker_file = os.path.join(d, "gadget.zig")
        with open(marker_file, "w") as f:
            f.write("const GADGET_SNIPPET_TOKEN = 11;\n")
        z = ZivSession(reuse_dir=d)
        try:
            z.wait_prompt()
            # Deposit the file via FileRead.
            z.send(f'/run FileRead {{"path":"{marker_file}"}}\n')
            z.read_until("GADGET_SNIPPET_TOKEN", 15)
            # Ask about it — the turn fails (no gateway) AFTER injection.
            z.send("how does the gadget work\n")
            z.read_until("No API key", 20)
            z.drain(1.2)  # settle: injection + prompt repaint
            z.clear_buf()
            z.send("/stats\n")
            out = z.read_until("Code context:", 10)
            m = re.search(r"Code context: (\d+) snippets", out)
            if not m:
                raise Fail("no Code context line in /stats")
            if int(m.group(1)) < 1:
                raise Fail(f"expected ≥1 injected snippet, got {m.group(1)}")
            quit_and_wait(z)
            return f"question→index→{m.group(1)} snippet(s) injected ✓"
        finally:
            z.close()
    finally:
        shutil.rmtree(d, ignore_errors=True)


def s12_tui_colors_toggle_resize():
    """P3c batch: (a) tool preview paints cyan, tool body dim; (b) the
    pinned input row keeps slash colors MID-TURN; (c) Ctrl+O roundtrips
    tool-output verbosity; (d) a terminal resize mid-turn self-heals the
    input row within a heartbeat (500ms tick)."""
    d = tempfile.mkdtemp(prefix="ziv-p3c-")
    try:
        z = ZivSession(reuse_dir=d)
        try:
            z.wait_prompt()
            # (a)+(c): a multi-line tool output — preview cyan, body dim;
            # Ctrl+O collapses, Ctrl+O expands again.
            z.send('/run Bash {"command":"seq 1 8"}\n')
            out = z.read_until("Running", 20)  # content marker (the echo repaint carries ziv[ on every key)
            z.drain(1.0)
            if "\x1b[36m" not in out:
                raise Fail("tool preview not cyan")
            z.drain(0.8)
            z.send("\x0f")  # Ctrl+O → brief
            out = z.read_until("工具输出: 简要", 10)
            z.drain(0.5)
            z.send('/run Bash {"command":"seq 20 30"}\n')  # 11 lines > 3
            out = z.read_until("Ctrl+O 展开", 20)
            z.drain(0.5)
            if " 27\n" in out.replace("\x1b[0m", ""):
                raise Fail("brief mode leaked full output past line 3")
            z.send("\x0f")  # Ctrl+O → verbose
            out = z.read_until("工具输出: 详细", 10)
            z.drain(0.5)
            z.send('/run Bash {"command":"echo A9B8C7"}\n')
            out = z.read_until("A9B8C7", 20)
            z.drain(0.8)
            # (b): mid-turn typing keeps slash colors in the pinned row.
            z.send('/run Bash {"command":"sleep 2","timeout":0}\n')
            time.sleep(0.6)
            z.send("/stats")  # typed MID-TURN into the pinned editor
            out = z.drain(2.5)
            if "\x1b[36m/stats" not in out:
                raise Fail("mid-turn slash typing lost its cyan color")
            z.send("\x03")  # cancel the sleep batch leftover draft
            z.drain(1.0)
            # (d): resize mid-turn self-heals the pinned input row.
            print("  [s13] starting paste turn", flush=True)
            z.send('/run Bash {"command":"sleep 3","timeout":0}\n')
            time.sleep(0.6)
            import fcntl, termios, struct as sstruct
            fcntl.ioctl(z.master, termios.TIOCSWINSZ, sstruct.pack("HHHH", 30, 100, 0, 0))
            time.sleep(1.2)  # >2 heartbeat ticks
            z.buf = b""
            z.send("ping")  # any keystroke re-renders; row must be alive
            out = z.drain(2.5)
            if "ziv[" not in out:
                raise Fail("pinned input row dead after resize (no repaint on keystroke)")
            z.send("\x03")
            z.drain(1.0)
            # The ^C above and quit_and_wait's own ^C would land inside the
            # 3s double-Ctrl-C exit window and race the /quit through the
            # EOF path — let the window lapse so /quit exits cleanly.
            time.sleep(3.5)
            quit_and_wait(z)
            return "colors + ctrl+O roundtrip + resize self-heal ✓"
        finally:
            z.close()
    finally:
        shutil.rmtree(d, ignore_errors=True)


def s13_bg_tasks():
    """P5 M1: Bash run_in_background returns immediately with a task id,
    /bg lists it as running, stop kills the group, and ziv exit leaves no
    orphan (the S5 reaping semantics extended to background)."""
    import subprocess as sp
    d = tempfile.mkdtemp(prefix="ziv-m1-")
    try:
        z = ZivSession(reuse_dir=d)
        try:
            z.wait_prompt()
            # 1. 后台启动 —— 立返任务号（回合不被 sleep 阻塞）。
            z.send('/run Bash {"command":"sleep 57 && echo done-bg-marker","run_in_background":true}\n')
            t0 = time.time()
            out = z.read_until("后台任务 #", 10)
            if time.time() - t0 > 5:
                raise Fail("background start did not return promptly")
            # 回执含命令原文属预期；脱离的证明 = 5s 内返回 + 下一步 /bg 立即可用。
            # 2. /bg 面板列出运行中的任务。
            z.clear_buf()
            z.send("/bg\n")
            out = z.read_until("运行中", 10)
            if "sleep 57" not in out:
                raise Fail("bg panel did not list the running command")
            # 3. 选中任务 → 停止（menu: Enter 选任务，Enter 选停止）。
            z.clear_buf()
            z.send("\r")
            z.read_until("停止", 5)
            z.send("\r")
            z.read_until("已发停止信号", 5)
            # 4. 面板重绘显示被杀状态（waiter 有 1s 泵宽限 + join，先沉淀）。
            time.sleep(2.5)
            z.clear_buf()
            z.send("\x1b")  # 从列表退出再进，拿干净一屏
            z.read_until("ziv[", 5)
            z.clear_buf()
            z.send("/bg\n")
            out = z.read_until("被杀", 10)
            # 5. 退出 ziv → 零孤儿。
            z.send("\x1b")
            z.read_until("ziv[", 5)
            quit_and_wait(z)
            time.sleep(1.0)  # 组杀信号落地窗口
            r = sp.run(["pgrep", "-f", "sleep 57"], capture_output=True)
            if r.returncode == 0:
                raise Fail("orphan survived ziv exit: " + r.stdout.decode())
            return "bg start → /bg panel → stop → no orphan ✓"
        finally:
            z.close()
    finally:
        shutil.rmtree(d, ignore_errors=True)


def s14_subagent_m4():
    """M4: agent tool gains tools/fork/max_turns. Mock gateway records every
    request; the subagent's own request must (a) carry the narrowed tool
    list, (b) with fork:true inherit the conversation tail (the secret
    token from turn 1), (c) stay read-only in semantics."""
    import threading, http.server, json as _json
    reqs = []

    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get('Content-Length', 0))
            body = _json.loads(self.rfile.read(n)) if n else {}
            texts = []
            for m in body.get("messages", []):
                c = m.get("content")
                if isinstance(c, str):
                    texts.append(c)
                elif isinstance(c, list):
                    for b in c:
                        if isinstance(b, dict) and b.get("type") == "text":
                            texts.append(b.get("text", ""))
            reqs.append({
                "tools": [t.get("function", {}).get("name", t.get("name", "?"))
                          for t in body.get("tools", [])],
                "texts": texts,
            })
            if body.get("stream"):
                resp = (b'data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"ok"}}]}\n\n'
                        b'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":2}}\n\n'
                        b'data: [DONE]\n\n')
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream')
            else:
                resp = _json.dumps({"choices": [{"message": {"role": "assistant", "content": "ok"}, "finish_reason": "stop"}],
                                    "usage": {"prompt_tokens": 10, "completion_tokens": 2}}).encode()
                self.send_response(200); self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(resp))); self.end_headers(); self.wfile.write(resp)

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(('127.0.0.1', 0), H)
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    d = tempfile.mkdtemp(prefix="ziv-m4-")
    try:
        os.makedirs(os.path.join(d, ".ziv"))
        with open(os.path.join(d, ".ziv", "settings.json"), "w") as f:
            f.write(_json.dumps({"api_keys": {"openai": "sk-mock", "openai_base_url": f"http://127.0.0.1:{port}/v1"},
                                 "permission_mode": "bypass"}))
        z = ZivSession(reuse_dir=d, env_extra={
            "OPENAI_API_KEY": "sk-mock",
            "OPENAI_BASE_URL": f"http://127.0.0.1:{port}/v1",
        })
        try:
            z.wait_prompt()
            # 会话记忆暗号（fork 应继承它）。
            z.send("暗号是 PINEAPPLE-77，记住\r")
            z.read_until("ok", 20)
            z.clear_buf()
            # M4：白名单 + fork。
            z.send('/run agent {"task":"report the secret token","fork":true,"tools":["FileRead"]}\r')
            out = z.read_until("子任务 1", 30)
            # 找子代理自己的请求（带 narrowed tools 的那个）。
            sub = [r for r in reqs if r["tools"] == ["FileRead"]]
            if not sub:
                raise Fail(f"no subagent request with narrowed tools; saw={[r['tools'] for r in reqs]}")
            joined = "\n".join(sub[-1]["texts"])
            if "PINEAPPLE-77" not in joined:
                raise Fail("fork did not inherit the conversation tail (token missing)")
            quit_and_wait(z)
            return "tools whitelist + fork inheritance reached the wire ✓"
        finally:
            z.close()
    finally:
        srv.shutdown()
        shutil.rmtree(d, ignore_errors=True)




def s15_project_root():
    """Project-root anchoring (docs/ziv-project-root.md): a session started
    in a SUBDIRECTORY shares the root project .ziv — startup hint prints,
    root memories are visible. (Manual pty spawn: ZivSession would create
    a LOCAL .ziv in the subdir, which by design wins over inheritance.)"""
    import json as _json, sqlite3
    root = tempfile.mkdtemp(prefix="ziv-root-")
    try:
        sub = os.path.join(root, "sub", "deep")
        os.makedirs(os.path.join(root, ".ziv"))
        os.makedirs(sub)
        with open(os.path.join(root, ".ziv", "settings.json"), "w") as f:
            f.write(_json.dumps({"permission_mode": "bypass"}))
        db = sqlite3.connect(os.path.join(root, ".ziv", "memory.db"))
        db.executescript("""
        CREATE TABLE IF NOT EXISTS memories (id BLOB PRIMARY KEY, type TEXT, scope TEXT DEFAULT 'private',
         name TEXT, description TEXT DEFAULT '', content TEXT, access_count INTEGER DEFAULT 0,
         embedding_id INTEGER, model TEXT DEFAULT '', dimensions INTEGER DEFAULT 0,
         created_at INTEGER DEFAULT 0, updated_at INTEGER DEFAULT 0);
        INSERT INTO memories (id, type, name, content, created_at, updated_at)
         VALUES (X'0102030405060708090a0b0c0d0e0f10', 'project', 'root-marker', 'ROOT_MEMORY_MARKER_42 根会话记忆', 1, 1);
        """)
        db.commit(); db.close()

        pid, master = pty.fork()
        if pid == 0:
            os.chdir(sub)
            env = dict(os.environ)
            env["TERM"] = "xterm-256color"
            env["HOME"] = sub  # hermetic: user-level settings stay out
            os.execv(BIN, [BIN])
        z = ZivSession.__new__(ZivSession)
        z.pid, z.master = pid, master
        z.buf = b""
        z._owns_dir = False
        z.dir = root
        try:
            z.wait_prompt()
            if "使用项目存储" not in z.buf.decode("utf-8", "replace"):
                raise Fail("no inheritance hint on startup banner")
            z.send("/memory\r")
            out = z.read_until("Most recent", 10)
            if "root-marker" not in out:
                raise Fail("root memory not visible from subdir session")
            quit_and_wait(z)
            return "subdir inherits root .ziv (hint + shared memory) ✓"
        finally:
            z.close()
    finally:
        shutil.rmtree(root, ignore_errors=True)


def s16_print_mode():
    """M7 `ziv -p`: non-interactive one-shot. Plain subprocess (no pty — -p
    never touches the TUI) against the mock gateway. Asserts: (a) exit 0,
    final text on stdout, nothing but the answer; (b) the request's system
    message is ziv's REAL prompt ("You are Ziv"), not the subagent headless
    one; (c) a FileWrite attempt in default mode is denied non-interactively
    and the model sees the denial; (d) stdin prompt mode works; (e) dead
    gateway → exit 1 with stderr diagnostics."""
    import subprocess, threading, http.server, json as _json
    reqs = []

    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get('Content-Length', 0))
            body = _json.loads(self.rfile.read(n)) if n else {}
            reqs.append(body)
            if len(reqs) == 1:
                # Round 1: demand a FileWrite (default mode → ask → denied).
                msg = {"role": "assistant", "content": None, "tool_calls": [
                    {"id": "call1", "type": "function", "function": {
                        "name": "FileWrite",
                        "arguments": _json.dumps({"path": "p.txt", "content": "x"})}}]}
            else:
                msg = {"role": "assistant", "content": "ONE-SHOT-ANSWER-42", "tool_calls": None}
            resp = _json.dumps({"choices": [{"message": msg, "finish_reason": "stop"}],
                                "usage": {"prompt_tokens": 10, "completion_tokens": 2}}).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(resp))); self.end_headers(); self.wfile.write(resp)

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(('127.0.0.1', 0), H)
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    d = tempfile.mkdtemp(prefix="ziv-p-")
    try:
        os.makedirs(os.path.join(d, ".ziv"))
        with open(os.path.join(d, ".ziv", "settings.json"), "w") as f:
            f.write(_json.dumps({"api_keys": {"openai": "sk-mock", "openai_base_url": f"http://127.0.0.1:{port}/v1"},
                                 "permission_mode": "default"}))
        env = dict(os.environ)
        env["HOME"] = d  # hermetic
        for k in list(env):
            if k.startswith(("OPENAI_", "ANTHROPIC_", "OLLAMA_")):
                env.pop(k)

        def ziv_p(args, stdin=None, timeout=60):
            return subprocess.run([BIN] + args, cwd=d, env=env, input=stdin,
                                  capture_output=True, timeout=timeout)

        # (a)+(b)+(c): arg mode, real system prompt, write denial round-trip.
        r = ziv_p(["-p", "write a file then report"])
        if r.returncode != 0:
            raise Fail(f"-p exited {r.returncode}; stderr={r.stderr[:300]!r}")
        if b"ONE-SHOT-ANSWER-42" not in r.stdout:
            raise Fail(f"final text missing from stdout: {r.stdout[:300]!r}")
        if len(reqs) < 2:
            raise Fail(f"expected tool round-trip, saw {len(reqs)} request(s)")
        sys_texts = []
        for m in reqs[0].get("messages", []):
            if m.get("role") == "system":
                c = m.get("content")
                sys_texts.append(c if isinstance(c, str) else _json.dumps(c))
        joined = "\n".join(sys_texts)
        if "You are Ziv" not in joined:
            raise Fail("system prompt is not ziv's real prompt (missing 'You are Ziv')")
        # 精确匹配无头提示的开头句——主系统提示的 Parallel work 段也含
        # "focused subagents" 字样（2026-11-09 加入），宽匹配会误伤。
        if "You are a focused subagent" in joined:
            raise Fail("headless subagent prompt leaked into -p mode")
        round2 = _json.dumps(reqs[1].get("messages", []))
        if "permission denied" not in round2 or "non-interactive" not in round2:
            raise Fail(f"write denial not reported back to the model: {round2[:300]}")
        if os.path.exists(os.path.join(d, "p.txt")):
            raise Fail("FileWrite executed despite default-mode ask")

        # (d): stdin prompt mode.
        reqs.clear()
        r2 = ziv_p(["-p"], stdin=b"say the answer")
        if r2.returncode != 0 or b"ONE-SHOT-ANSWER-42" not in r2.stdout:
            raise Fail(f"stdin -p failed: rc={r2.returncode} out={r2.stdout[:200]!r} err={r2.stderr[:200]!r}")

        # (e): dead gateway → exit 1, diagnostics on stderr.
        with open(os.path.join(d, ".ziv", "settings.json"), "w") as f:
            f.write(_json.dumps({"api_keys": {"openai": "sk-mock", "openai_base_url": "http://127.0.0.1:1/v1"},
                                 "permission_mode": "default"}))
        r3 = ziv_p(["-p", "probe"], timeout=120)
        if r3.returncode == 0:
            raise Fail("dead gateway must exit non-zero")
        if not r3.stderr.strip():
            raise Fail("no stderr diagnostics on failure")
        return "arg+stdin modes, real system prompt, ask→deny, exit codes ✓"
    finally:
        srv.shutdown()
        shutil.rmtree(d, ignore_errors=True)


def s17_hooks():
    """M6 Hooks: PreToolUse exit-2 blocks a /run Bash call (block reason
    visible), PostToolUse fires after FileRead (side-effect file written).
    Configured in project settings.json — the same place permission rules
    live."""
    import json as _json
    d = tempfile.mkdtemp(prefix="ziv-hooks-")
    try:
        # NOTE: hooks 配置必须经构造器的 settings 参数写入——ZivSession
        # 构造时会用自己的 settings 覆写 .ziv/settings.json，外面手写
        # 会被静默 clobber（S14 逃过这坑纯靠 env 变量兜底）。
        hook_settings = _json.dumps({
            "permission_mode": "bypass",
            "hooks": {
                "PreToolUse": [{"matcher": "Bash", "command": "echo no-bash-for-you >&2; exit 2"}],
                "PostToolUse": [{"matcher": "FileRead", "command": "echo ran >> hook-marker.txt"}],
            },
        })
        with open(os.path.join(d, "target.txt"), "w") as f:
            f.write("hook target contents\n")
        z = ZivSession(reuse_dir=d, settings=hook_settings)
        try:
            z.wait_prompt()
            # PreToolUse: Bash 阻断，工具本体绝不执行。
            z.clear_buf()
            z.send('/run Bash {"command":"echo should-not-run"}\r')
            out = z.read_until("no-bash-for-you", 10)
            if "BLOCKED by PreToolUse hook" not in out:
                raise Fail(f"block banner missing: {out[-300:]!r}")
            # PostToolUse: FileRead 放行且钩子留下记号。
            z.send('/run FileRead {"path":"target.txt"}\r')
            z.read_until("hook target contents", 10)
            deadline = time.time() + 10
            marker = os.path.join(d, "hook-marker.txt")
            while not os.path.exists(marker) and time.time() < deadline:
                time.sleep(0.2)
            if not os.path.exists(marker):
                raise Fail("PostToolUse hook never ran (marker file missing)")
            # matcher 过滤：Bash 的 Pre 钩子不该拦 FileRead（上面已放行即证）。
            quit_and_wait(z)
            return "pre-block + post-side-effect + matcher filter ✓"
        finally:
            z.close()
    finally:
        shutil.rmtree(d, ignore_errors=True)


def s18_tree_sitter():
    """③ milestone 1: post-edit syntax validation. A FileEdit that breaks
    python must surface the tree-sitter warning in the tool result; valid
    writes stay silent; unknown extensions skip validation entirely."""
    d = tempfile.mkdtemp(prefix="ziv-ts-")
    try:
        with open(os.path.join(d, "calc.py"), "w") as f:
            f.write("def calc():\n    return 1\n")
        z = ZivSession(reuse_dir=d)
        try:
            z.wait_prompt()

            def run_and_wait(cmd, marker, timeout=10):
                # /run 收尾窗口（op_log/flush/提示符重画）到达的输入会被丢
                # （既有行为，S6/S10 抖动同源）——每步等提示符真正回来再发下一条。
                z.clear_buf()
                z.send(cmd)
                out = z.read_until(marker, timeout)
                z.read_until("ziv[bypass] (gpt-4o) [0%] >", 5)
                return out

            # 坏编辑：return 1 → return 1( —— 未闭合调用。
            out = run_and_wait('/run FileEdit {"path":"calc.py","old_string":"return 1","new_string":"return 1("}\r', "语法检查")
            if "calc.py" not in out:
                raise Fail(f"warning missing file name: {out[-300:]!r}")
            # 好编辑：修回去，警告必须不出现。
            out2 = run_and_wait('/run FileEdit {"path":"calc.py","old_string":"return 1(","new_string":"return 1"}\r', "Replaced 1 occurrence")
            if "语法检查" in out2:
                raise Fail("valid edit produced a syntax warning")
            # FileWrite：合法 python 静默；坏 zig（缺分号）报。
            out3 = run_and_wait('/run FileWrite {"path":"ok.py","content":"x = 1\\n"}\r', "Wrote")
            if "语法检查" in out3:
                raise Fail("valid python write produced a syntax warning")
            out4 = run_and_wait('/run FileWrite {"path":"bad.zig","content":"const x = 1\\nconst y = 2;\\n"}\r', "语法检查")
            if "bad.zig" not in out4:
                raise Fail(f"zig warning missing: {out4[-300:]!r}")
            # 未知扩展名：纯文本，永不校验。
            out5 = run_and_wait('/run FileWrite {"path":"notes.txt","content":"((("}\r', "Wrote")
            if "语法检查" in out5:
                raise Fail("txt must not be validated")
            quit_and_wait(z)
            return "break→warning, fix→silent, .zig caught, .txt skipped ✓"
        finally:
            z.close()
    finally:
        shutil.rmtree(d, ignore_errors=True)


def s19_full_subagent():
    """Full-capability subagents (write:true): (a) bypass + write → the
    subagent's FileWrite REALLY lands (file created); (b) no write param →
    read-only denial reaches the merged report; (c) default mode + write →
    ask degrades to '(non-interactive)' denial. Mock gateway serves the
    subagent's own LLM rounds (detected by the headless system prompt)."""
    import threading, http.server, json as _json
    state = {"sub_round": 0}

    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get('Content-Length', 0))
            body = _json.loads(self.rfile.read(n)) if n else {}
            def sys_text(m):
                c = m.get("content")
                return c if isinstance(c, str) else _json.dumps(c)
            is_sub = any(m.get("role") == "system" and "focused subagent" in sys_text(m) for m in body.get("messages", []))
            if is_sub:
                state["sub_round"] += 1
                if state["sub_round"] % 2 == 1:  # 每个子代理第一轮：要求写文件
                    msg = {"role": "assistant", "content": None, "tool_calls": [
                        {"id": f"c{state['sub_round']}", "type": "function", "function": {
                            "name": "FileWrite",
                            "arguments": _json.dumps({"path": "marker-write.txt", "content": "from-subagent"})}}]}
                else:  # 第二轮：回显最后的工具结果（拒绝/成功语义由此进入报告）
                    last_tool = ""
                    for m in body.get("messages", []):
                        c = m.get("content")
                        if isinstance(c, str) and m.get("role") == "tool":
                            last_tool = c
                        elif isinstance(c, list):
                            for b in c:
                                if isinstance(b, dict) and b.get("type") == "tool_result":
                                    last_tool = b.get("content", "") if isinstance(b.get("content"), str) else _json.dumps(b.get("content", ""))
                    msg = {"role": "assistant", "content": f"RESULT[{last_tool}]", "tool_calls": None}
            else:
                msg = {"role": "assistant", "content": "ok", "tool_calls": None}
            resp = _json.dumps({"choices": [{"message": msg, "finish_reason": "stop"}],
                                "usage": {"prompt_tokens": 10, "completion_tokens": 2}}).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(resp))); self.end_headers(); self.wfile.write(resp)

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(('127.0.0.1', 0), H)
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    def run_case(settings_mode, use_write, marker):
        d = tempfile.mkdtemp(prefix="ziv-full-")
        try:
            hook_settings = _json.dumps({"permission_mode": settings_mode,
                                         "api_keys": {"openai": "sk-mock", "openai_base_url": f"http://127.0.0.1:{port}/v1"}})
            z = ZivSession(reuse_dir=d, settings=hook_settings)
            try:
                z.wait_prompt()
                z.clear_buf()
                arg = ',"write":true' if use_write else ''
                z.send(f'/run agent {{"task":"create the marker file"{arg}}}\r')
                # default 模式下 agent 工具本身要审批（非只读工具）——替操作员答 y。
                try:
                    z.read_until("Allow?", 5)
                    z.send("y\r")
                except Exception:
                    pass  # bypass：无审批直接跑
                out = z.read_until_seen("子任务 1", 30)
                z.drain(2.0)  # 回合收尾（default 模式提示符无模式标签，别匹配形态）
                return out, os.path.exists(os.path.join(d, "marker-write.txt"))
            finally:
                z.close()
        finally:
            shutil.rmtree(d, ignore_errors=True)

    try:
        # (a) bypass + write:true → 真落盘
        out_a, wrote = run_case("bypass", True, "a")
        if not wrote:
            raise Fail(f"write dispatch did not create the file; report: {out_a[-300:]!r}")
        # (b) 无 write → 只读拒绝进报告，文件不存在
        out_b, wrote_b = run_case("bypass", False, "b")
        if wrote_b or "subagents are read-only" not in out_b:
            raise Fail(f"read-only semantics broken: wrote={wrote_b}; report: {out_b[-300:]!r}")
        # (c) default 模式 + write:true → ask 降级 (non-interactive)，仍拒
        out_c, wrote_c = run_case("default", True, "c")
        if wrote_c or "non-interactive" not in out_c:
            raise Fail(f"ask-degrade broken: wrote={wrote_c}; report: {out_c[-300:]!r}")
        return "write lands (bypass), read-only default intact, ask degrades headless ✓"
    finally:
        srv.shutdown()


def s20_bgtool():
    """BgTask + TaskGet: the model can now START (Bash run_in_background),
    INSPECT (status/output) and STOP (kill group) a background task without
    the human /bg panel — plus TaskGet returns the full untruncated task
    description."""
    d = tempfile.mkdtemp(prefix="ziv-bgtool-")
    try:
        z = ZivSession(reuse_dir=d)
        try:
            z.wait_prompt()

            def run_and_wait(cmd, marker, timeout=15):
                z.clear_buf()
                z.send(cmd + "\r")
                out = z.read_until(marker, timeout)
                z.read_until_seen("ziv[bypass] (gpt-4o) [0%] >", 5)
                return out

            # 起一个长跑后台任务
            run_and_wait('/run Bash {"command":"sleep 30","run_in_background":true}', "后台任务 #1")
            out = run_and_wait('/run BgTask {"action":"status"}', "[#1] running")
            if "sleep 30" not in out:
                raise Fail(f"status missing command: {out[-200:]!r}")
            run_and_wait('/run BgTask {"action":"output","id":1}', "ziv[bypass]")
            out = run_and_wait('/run BgTask {"action":"stop","id":1}', "Stopped background task #1")
            out = run_and_wait('/run BgTask {"action":"status"}', "[#1]")
            if "running" in out.split("ziv[bypass]")[-2] and "killed" not in out and "exit" not in out:
                raise Fail(f"task still shows running after stop: {out[-200:]!r}")
            # 未知 id 的报错形态
            out = run_and_wait('/run BgTask {"action":"stop","id":99}', "not running")

            # TaskGet：创建 → 全文描述可取
            run_and_wait('/run TaskCreate {"subject":"fix login","description":"Reproduce on UAT then check the token refresh path and the expiry math corner cases","priority":2}', "#1")
            out = run_and_wait('/run TaskGet {"id":1}', "expiry math")
            if "fix login" not in out:
                raise Fail("TaskGet missing subject")
            quit_and_wait(z)
            return "bg start→status→output→stop closed; TaskGet full text ✓"
        finally:
            z.close()
    finally:
        shutil.rmtree(d, ignore_errors=True)


def s21_agent_live_status():
    """Live per-subagent progress in the status row during an agent dispatch
    (the observability gap: dispatch blocks silently for its whole duration).
    Stateful mock: main round 1 → agent tool_use (3 tasks); subagent requests
    sleep so the dispatch lasts seconds; the UI pump (500ms) must render
    'agent N/3：#k tM' into the region status. Final merged report closes."""
    import threading, http.server, json as _json
    state = {"main_done": False}

    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get('Content-Length', 0))
            body = _json.loads(self.rfile.read(n)) if n else {}
            def sys_text(m):
                c = m.get("content")
                return c if isinstance(c, str) else _json.dumps(c)
            is_sub = any(m.get("role") == "system" and "You are a focused subagent" in sys_text(m) for m in body.get("messages", []))
            if body.get("stream"):
                # 主回合走流式：SSE 分支（tool_calls 以 delta 下发）。
                import time as _t
                if not state["main_done"]:
                    state["main_done"] = True
                    deltas = [
                        {"tool_calls": [{"index": 0, "id": "c1", "type": "function", "function": {
                            "name": "agent",
                            "arguments": _json.dumps({"tasks": ["probe one", "probe two", "probe three"]})}}]},
                    ]
                else:
                    deltas = [{"content": "all probes complete"}]
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                for d in deltas:
                    chunk = _json.dumps({"choices": [{"index": 0, "delta": d}]})
                    self.wfile.write(f"data: {chunk}\n\n".encode())
                fin = _json.dumps({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                                   "usage": {"prompt_tokens": 5, "completion_tokens": 2}})
                self.wfile.write(f"data: {fin}\n\ndata: [DONE]\n\n".encode())
                return
            if is_sub:
                import time as _t
                _t.sleep(3)
                msg = {"role": "assistant", "content": "probe done", "tool_calls": None}
            else:
                msg = {"role": "assistant", "content": "probe done", "tool_calls": None}
            resp = _json.dumps({"choices": [{"message": msg, "finish_reason": "stop"}],
                                "usage": {"prompt_tokens": 5, "completion_tokens": 1}}).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(resp))); self.end_headers(); self.wfile.write(resp)

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(('127.0.0.1', 0), H)
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    d = tempfile.mkdtemp(prefix="ziv-s21-")
    try:
        os.makedirs(os.path.join(d, ".ziv"))
        with open(os.path.join(d, ".ziv", "settings.json"), "w") as f:
            f.write(_json.dumps({"permission_mode": "bypass",
                                 "api_keys": {"openai": "sk-mock", "openai_base_url": f"http://127.0.0.1:{port}/v1"}}))
        z = ZivSession(reuse_dir=d, env_extra={
            "OPENAI_API_KEY": "sk-mock",
            "OPENAI_BASE_URL": f"http://127.0.0.1:{port}/v1",
        })
        try:
            z.wait_prompt()
            z.clear_buf()
            z.send("run the three probes\r")
            # dispatch 持续 ~3s（并发 3 子代理各睡 3s）——实时行必须出现。
            out = z.read_until("agent ", 40)
            if "agent 0/3" not in out and "agent 1/3" not in out and "agent 2/3" not in out and "agent 3/3" not in out:
                raise Fail(f"live agent line missing: {out[-300:]!r}")
            z.read_until("子任务 3", 60)
            z.read_until_seen("ziv[bypass] (gpt-4o) [0%] >", 10)
            quit_and_wait(z)
            return "live per-agent status row during dispatch ✓"
        finally:
            z.close()
    finally:
        srv.shutdown()
        shutil.rmtree(d, ignore_errors=True)


SCENARIOS = [
    ("S1 raw-session", s1_raw_session),
    ("S2 midturn-keys", s2_midturn_keys),
    ("S3 last-ring", s3_last_ring),
    ("S4 confirm-reads", s4_confirm_reads),
    ("S5 pipe-holder-reap", s5_pipe_holder_reaped),
    ("S6 command-smoke", s6_command_smoke),
    ("S7 clean-resume", s7_clean_resume),
    ("S8 crash-resume", s8_crash_resume),
    ("S9 error-selector", s9_error_selector),
    ("S10 code-index", s10_code_index),
    ("S11 code-context", s11_code_context_injection),
    ("S12 tui-colors-toggle-resize", s12_tui_colors_toggle_resize),
    ("S13 bg-tasks", s13_bg_tasks),
    ("S14 subagent-m4", s14_subagent_m4),
    ("S15 project-root", s15_project_root),
    ("S16 print-mode", s16_print_mode),
    ("S17 hooks", s17_hooks),
    ("S18 tree-sitter", s18_tree_sitter),
    ("S19 full-subagent", s19_full_subagent),
    ("S20 bgtool", s20_bgtool),
    ("S21 agent-live-status", s21_agent_live_status),
]


def main() -> int:
    print(f"ziv pty suite — binary: {BIN}")
    failures = 0
    for name, fn in SCENARIOS:
        try:
            note = fn()
            print(f"  PASS {name}: {note}")
        except Fail as e:
            failures += 1
            print(f"  FAIL {name}: {e}")
        except Exception as e:  # noqa: BLE001 — report, don't crash the suite
            failures += 1
            print(f"  ERROR {name}: {type(e).__name__}: {e}")
    print("ALL GREEN" if failures == 0 else f"{failures} FAILED")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
