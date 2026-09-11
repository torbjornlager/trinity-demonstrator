#!/usr/bin/env python3
"""Fresh-process SWI engine/thread/actor measurements (macOS or Linux)."""
import argparse
import json
import os
from pathlib import Path
import platform
import select
import subprocess
import time

SOURCE = Path(__file__).with_name("swi_engine_probe.pl")


def marker(proc, expected):
    if not select.select([proc.stdout], [], [], 30)[0]:
        raise TimeoutError(f"waiting for {expected}")
    line = proc.stdout.readline().strip()
    if line != expected:
        raise RuntimeError(f"expected {expected!r}, got {line!r}")


def rss_kib(pid):
    return int(subprocess.check_output(
        ["ps", "-o", "rss=", "-p", str(pid)], text=True).strip())


def memory(command, mode, count):
    proc = subprocess.Popen(command + ["memory", mode, str(count)],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)
    try:
        marker(proc, "baseline")
        before = rss_kib(proc.pid)
        proc.stdin.write("go.\n")
        proc.stdin.flush()
        marker(proc, "ready")
        # The actor readiness message precedes entry into receive by a few
        # instructions. Allow idle workers to settle before sampling RSS.
        time.sleep(0.05)
        after = rss_kib(proc.pid)
        stdout, stderr = proc.communicate("stop.\n", timeout=30)
        if proc.returncode or stdout.strip() or stderr.strip():
            raise RuntimeError(f"probe failed: {proc.returncode}: {stdout}{stderr}")
        return dict(mode=mode, count=count, baseline_rss_kib=before,
                    idle_rss_kib=after, delta_rss_kib=after-before,
                    delta_kib_per_unit=(after-before)/count if count else None)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.communicate()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swipl", default=os.environ.get("SWIPL", "swipl"))
    parser.add_argument("--counts", nargs="+", type=int, default=[0, 10, 100, 250])
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--iterations", type=int, default=5_000_000)
    args = parser.parse_args()
    if min(args.counts) < 0 or args.repetitions < 1 or args.iterations < 1:
        parser.error("counts must be nonnegative; repetitions and iterations positive")
    command = [args.swipl, "-q", "-f", "none", "-s", str(SOURCE),
               "-g", "swi_engine_probe:main", "-t", "halt", "--"]
    result = dict(platform=platform.platform(),
                  swipl=subprocess.check_output([args.swipl, "--version"], text=True).strip(),
                  memory=[], scheduling=[])
    for repetition in range(args.repetitions):
        for mode in ("thread", "actor", "engine"):
            for count in args.counts:
                row = memory(command, mode, count)
                row["repetition"] = repetition + 1
                result["memory"].append(row)
        for mode in ("actor", "engine"):
            run = subprocess.run(command + ["scheduling", mode, str(args.iterations)],
                                 capture_output=True, text=True, timeout=30, check=True)
            if run.stderr.strip():
                raise RuntimeError(run.stderr)
            row = json.loads(run.stdout)
            row["repetition"] = repetition + 1
            result["scheduling"].append(row)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
