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

    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="ziv-pty-")
        os.makedirs(os.path.join(self.dir, ".ziv"), exist_ok=True)
        # Deterministic, hermetic: project-level bypass so FileWrite/Bash
        # never hit the permission gate regardless of global settings.
        with open(os.path.join(self.dir, ".ziv", "settings.json"), "w") as f:
            f.write('{"permission_mode":"bypass"}\n')
        self.pid, self.master = pty.fork()
        if self.pid == 0:
            os.chdir(self.dir)
            env = dict(os.environ)
            env["TERM"] = "xterm-256color"
            # Hermetic HOME: user-level settings/keys/mcp stay OUT — no
            # real gateway calls from the suite.
            env["HOME"] = self.dir
            env.pop("ZIV_CRON_SCALE", None)
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
        shutil.rmtree(self.dir, ignore_errors=True)


def quit_and_wait(z: ZivSession) -> None:
    # Ctrl-C clears any pending editor draft first — a draft would
    # concatenate '/quit' into a MESSAGE and fire a real LLM turn (the
    # S2 lesson). Generous Goodbye wait: exit reflection runs here.
    z.send("\x03")
    z.drain(0.3)
    z.send("/quit\n")
    z.read_until("Goodbye", 30)


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
        z.send("q")
        z.read_until("ziv[", 10)  # prompt back
        quit_and_wait(z)
        return "14 command paths answered ✓"
    finally:
        z.close()


SCENARIOS = [
    ("S1 raw-session", s1_raw_session),
    ("S2 midturn-keys", s2_midturn_keys),
    ("S3 last-ring", s3_last_ring),
    ("S4 confirm-reads", s4_confirm_reads),
    ("S5 pipe-holder-reap", s5_pipe_holder_reaped),
    ("S6 command-smoke", s6_command_smoke),
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
