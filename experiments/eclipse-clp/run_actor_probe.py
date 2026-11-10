#!/usr/bin/env python3
"""Start the loopback actor services, run the probes, and collect diagnostics."""

import argparse
from pathlib import Path
import signal
import socket
import subprocess
import sys
from tempfile import TemporaryDirectory
from time import monotonic, sleep

HERE = Path(__file__).resolve().parent
HOST = "127.0.0.1"


def check_ports():
    for port in (8094, 8095, 8096):
        with socket.socket() as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                sock.bind((HOST, port))
            except OSError as error:
                raise RuntimeError(f"Cannot use {HOST}:{port}. Stop any earlier probe server "
                                   f"on that port and retry. {error}") from error


def wait_ready(process, port):
    deadline = monotonic() + 15
    while monotonic() < deadline:
        if process.poll() is not None:
            break
        try:
            with socket.create_connection((HOST, port), timeout=0.2):
                return
        except OSError:
            sleep(0.05)
    raise RuntimeError(f"Probe service on {HOST}:{port} did not start")


def stop(process):
    if process.poll() is None:
        process.send_signal(signal.SIGINT)
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime_dir", type=Path)
    parser.add_argument("--swi-loader", type=Path,
                        default=HERE.parents[2] / "swi-prolog-node" / "load.pl")
    parser.add_argument("--prompt-probe", action="append", default=[], metavar="SELECTOR",
                        help="run a directional prompt probe; use a PID-only SWI loader for legacy "
                             "selectors and a prompt-aware loader for correlated selectors")
    args = parser.parse_args()
    loader = args.swi_loader.resolve()
    if not loader.is_file():
        parser.error(f"SWI-Prolog loader not found at {loader}")
    try:
        check_ports()
    except RuntimeError as error:
        parser.exit(1, f"{error}\n")

    swi = ["swipl", "-q", "-s", str(loader), "-s"]
    services = [
        (8094, "ECLiPSe adapter", [sys.executable, str(HERE / "isotope_http.py"),
                                  str(args.runtime_dir.resolve()), "--port", "8094"]),
        (8096, "WebSocket gateway", [*swi, str(HERE / "actor_probe_gateway.pl")]),
    ]
    with TemporaryDirectory(prefix="eclipse-actor-probe-") as directory:
        processes = []
        try:
            for port, name, command in services:
                log = Path(directory) / f"{port}.log"
                with log.open("wb") as output:
                    process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT)
                processes.append((process, name, log))
                wait_ready(process, port)
            probe_args = (["--prompt-probes", *args.prompt_probe]
                          if args.prompt_probe else ["--remote-spawn"])
            subprocess.run([*swi, str(HERE / "probe_actor_pingpong.pl"), "--", *probe_args],
                           timeout=max(30, 12 * len(args.prompt_probe)), check=True)
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            print(f"Actor probe failed: {error}", file=sys.stderr)
            for _, name, log in processes:
                print(f"\n{name}\n{log.read_text(errors='replace')}", file=sys.stderr)
            return 1
        finally:
            for process, _, _ in reversed(processes):
                stop(process)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
