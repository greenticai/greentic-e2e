#!/usr/bin/env python3
import os
import pty
import re
import select
import subprocess
import sys
import time

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")


def normalize(text: str) -> str:
    return ANSI_RE.sub("", text)


def wait_for(proc, master_fd: int, pattern: str, timeout: float, buf: list[str]) -> bool:
    regex = re.compile(pattern, re.DOTALL)
    if regex.search(normalize("".join(buf))):
        return True
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master_fd], [], [], 0.2)
        if ready:
            try:
                chunk = os.read(master_fd, 4096)
            except OSError:
                chunk = b""
            if chunk:
                text = chunk.decode("utf-8", errors="ignore")
                buf.append(text)
                if regex.search(normalize("".join(buf))):
                    return True
                continue

        if proc.poll() is not None:
            try:
                chunk = os.read(master_fd, 4096)
            except OSError:
                chunk = b""
            if chunk:
                text = chunk.decode("utf-8", errors="ignore")
                buf.append(text)
                if regex.search(normalize("".join(buf))):
                    return True
            return False
    return False


def send_line(master_fd: int, value: str) -> None:
    os.write(master_fd, value.encode("utf-8") + b"\n")


def fail(message: str, buf: list[str]) -> int:
    output = normalize("".join(buf))
    tail = output[-3000:] if len(output) > 3000 else output
    sys.stderr.write(message + "\n")
    sys.stderr.write("--- Wizard output tail ---\n")
    sys.stderr.write(tail + "\n")
    return 1


def main() -> int:
    pack_dir = os.environ["WIZARD_PACK_DIR"]
    bundle_name = os.environ["WIZARD_BUNDLE_NAME"]
    bundle_id = os.environ["WIZARD_BUNDLE_ID"]
    bundle_dir = os.environ["WIZARD_BUNDLE_DIR"]
    emit_file = os.environ["WIZARD_EMIT_FILE"]

    env = os.environ.copy()
    env["NO_COLOR"] = "1"
    env["CLICOLOR"] = "0"

    master_fd, slave_fd = pty.openpty()
    proc = subprocess.Popen(
        ["gtc", "wizard", "--emit-answers", emit_file],
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        env=env,
        close_fds=True,
    )
    os.close(slave_fd)

    buf: list[str] = []

    steps = [
        (r"Greentic Developer Wizard", None, 30),
        (r"Select option:", "2", 30),
        (r"Bundle Wizard", None, 30),
        (r"Select number or value:", "1", 30),
        (r"Bundle name:", bundle_name, 30),
        (r"Bundle id:", bundle_id, 30),
        (r"Output directory.*:", bundle_dir, 30),
        (r"Select number or value:", "1", 30),
        (r"Enter app pack reference or local path:", pack_dir, 30),
        (r"Select number or value:", "1", 30),
        (r"Select number or value:", "1", 30),
        (r"Select number or value:", "4", 30),
        (r"Select number or value:", "4", 30),
        (r"Enable bundle-level assets.*\[false\]:", "n", 30),
        (r"Select number or value:", "3", 30),
    ]

    for pattern, answer, timeout in steps:
        if not wait_for(proc, master_fd, pattern, timeout=timeout, buf=buf):
            proc.kill()
            return fail(f"Timed out waiting for pattern: {pattern}", buf)
        if answer is not None:
            send_line(master_fd, answer)

    if wait_for(proc, master_fd, r"Select option:", timeout=10, buf=buf):
        send_line(master_fd, "0")

    code = proc.wait(timeout=30)
    if code != 0:
        return fail(f"gtc wizard exited with code {code}", buf)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
