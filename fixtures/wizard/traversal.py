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
            # Process exited; one final read attempt.
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
    tail = output[-2000:] if len(output) > 2000 else output
    sys.stderr.write(message + "\n")
    sys.stderr.write("--- Wizard output tail ---\n")
    sys.stderr.write(tail + "\n")
    return 1


def main() -> int:
    pack_id = os.environ["WIZARD_PACK_ID"]
    pack_dir = os.environ["WIZARD_PACK_DIR"]

    env = os.environ.copy()
    env["NO_COLOR"] = "1"
    env["CLICOLOR"] = "0"

    master_fd, slave_fd = pty.openpty()
    proc = subprocess.Popen(
        ["gtc", "wizard", "--debug-router"],
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        env=env,
        close_fds=True,
    )
    os.close(slave_fd)

    buf: list[str] = []

    steps = [
        (r"Router exec: greentic-dev", None),
        (r"Select option:", "1"),
        (r">\s*$", "1"),
        (r"Pack id", None),
        (r">\s*$", pack_id),
        (r"Pack directory", None),
        (r">\s*$", pack_dir),
        (r">\s*$", "M"),
        (r">\s*$", "0"),
        (r"Select option:", "2"),
        (r"Bundle Wizard", None),
        (r"Select number or value:", "0"),
        (r"Select option:", "0"),
    ]

    for pattern, answer in steps:
        if not wait_for(proc, master_fd, pattern, timeout=30, buf=buf):
            proc.kill()
            return fail(f"Timed out waiting for pattern: {pattern}", buf)
        if answer is not None:
            send_line(master_fd, answer)

    code = proc.wait(timeout=20)
    if code != 0:
        return fail(f"gtc wizard exited with code {code}", buf)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
