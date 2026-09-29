#!/usr/bin/env python3
"""Record a command's terminal session as an asciicast v2 file.

The recording runs the command on a pseudo-terminal so that programs which
only emit ANSI progress to a terminal behave as they do for a person. Output
chunks are stored with the wall-clock offset at which they were produced.

Usage: record_cast.py OUTPUT.cast COLUMNS ROWS COMMAND [ARGUMENT ...]
"""

import errno
import fcntl
import json
import os
import pty
import select
import signal
import struct
import sys
import termios
import time


def set_size(fd, columns, rows):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))


def record(output_path, columns, rows, argv):
    pid, master = pty.fork()
    if pid == 0:
        os.environ["COLUMNS"] = str(columns)
        os.environ["LINES"] = str(rows)
        os.environ["TERM"] = "xterm-256color"
        os.execvp(argv[0], argv)
        os._exit(127)

    set_size(master, columns, rows)
    started = time.time()
    events = []

    while True:
        try:
            ready, _, _ = select.select([master], [], [], 1.0)
        except InterruptedError:
            continue
        if master in ready:
            try:
                chunk = os.read(master, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            events.append(
                [round(time.time() - started, 6), "o", chunk.decode("utf-8", "replace")]
            )
        else:
            done, _ = os.waitpid(pid, os.WNOHANG)
            if done == pid:
                break

    os.close(master)
    try:
        _, status = os.waitpid(pid, 0)
    except ChildProcessError:
        status = 0
    exit_code = os.waitstatus_to_exitcode(status) if status else 0

    header = {
        "version": 2,
        "width": columns,
        "height": rows,
        "timestamp": int(started),
        "env": {"TERM": "xterm-256color", "SHELL": ""},
    }
    with open(output_path, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(header, separators=(",", ":")) + "\n")
        for event in events:
            handle.write(json.dumps(event, separators=(",", ":")) + "\n")

    duration = events[-1][0] if events else 0.0
    print(
        f"recorded {len(events)} events, {duration:.2f}s -> {output_path}",
        file=sys.stderr,
    )
    return exit_code


if __name__ == "__main__":
    if len(sys.argv) < 5:
        print(__doc__, file=sys.stderr)
        raise SystemExit(2)
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    raise SystemExit(
        record(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4:])
    )
