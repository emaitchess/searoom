#!/usr/bin/env python3
"""Assert that `searoom watch` ends at a line boundary and returns 128 + signal.

    Scripts/check-watch-signal.py <path to the Searoom executable>

The unit tests inject a signal double, so they cannot see the production
monitor being left unwired: 0.5.1 shipped with `NoSignals()` as the default and
`watch` was killed by SIGINT instead of finishing its line and exiting 130.

A shell cannot catch that regression either. Bash reports 130 for a process
killed by SIGINT and for one that exits 130, so only the raw wait status tells
the two apart, which is why this check is Python rather than a line in the
workflow.
"""
import json
import os
import signal
import subprocess
import sys
import tempfile

EXECUTABLE = sys.argv[1] if len(sys.argv) > 1 else sys.exit("usage: check-watch-signal.py <executable>")
FAILURES = []

for sig, name in [(signal.SIGINT, "SIGINT"), (signal.SIGTERM, "SIGTERM")]:
    expected = 128 + sig
    with tempfile.TemporaryDirectory() as work:
        # The command has to be reached as `searoom`, which is also how anyone
        # installing it gets there.
        link = os.path.join(work, "searoom")
        os.symlink(os.path.abspath(EXECUTABLE), link)
        output = os.path.join(work, "watch.jsonl")
        with open(output, "w") as stdout:
            process = subprocess.Popen([link, "watch", "--interval", "1"], stdout=stdout)
            try:
                process.wait(timeout=4)
            except subprocess.TimeoutExpired:
                pass
            else:
                FAILURES.append(f"{name}: watch exited on its own before the signal")
                continue
            os.kill(process.pid, sig)
            _, status = os.waitpid(process.pid, 0)

        if os.WIFSIGNALED(status):
            FAILURES.append(
                f"{name}: watch was killed by signal {os.WTERMSIG(status)}; "
                f"the signal monitor is not installed, so the line-boundary "
                f"guarantee and exit code {expected} do not hold"
            )
            continue
        code = os.WEXITSTATUS(status)
        if code != expected:
            FAILURES.append(f"{name}: watch exited {code}, expected {expected}")
            continue

        lines = [line for line in open(output) if line.strip()]
        if not lines:
            FAILURES.append(f"{name}: watch emitted nothing before the signal")
            continue
        try:
            for line in lines:
                json.loads(line)
        except json.JSONDecodeError as error:
            FAILURES.append(f"{name}: watch was cut mid-document: {error}")
            continue
        print(f"{name}: exit {code}, {len(lines)} complete lines")

for failure in FAILURES:
    print(f"::error::{failure}", file=sys.stderr)
sys.exit(1 if FAILURES else 0)
