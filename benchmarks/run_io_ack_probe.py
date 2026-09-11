#!/usr/bin/env python3
"""Measure native I/O acknowledgement cost; no production nodes are contacted."""
import argparse
import asyncio
import json
import os
from pathlib import Path
import platform
import random
import socket
import time

SOURCE = Path(__file__).with_name("io_ack_probe.pl")


class DelayProxy:
    """FIFO TCP proxy with propagation delay, not a per-packet rate limit."""
    def __init__(self, upstream, rtt_ms):
        self.upstream = upstream
        self.delay = rtt_ms / 2000
        self.bytes = [0, 0]
        self.tasks = set()

    async def start(self):
        self.server = await asyncio.start_server(self.accept, "127.0.0.1", 0)
        return self.server.sockets[0].getsockname()[1]

    async def pump(self, reader, writer, direction):
        queue = asyncio.Queue()

        async def read():
            while data := await reader.read(65536):
                self.bytes[direction] += len(data)
                queue.put_nowait((time.monotonic() + self.delay, data))
            queue.put_nowait((0, None))

        async def write():
            while True:
                due, data = await queue.get()
                if data is None:
                    return
                await asyncio.sleep(max(0, due - time.monotonic()))
                writer.write(data)
                await writer.drain()

        await asyncio.gather(read(), write())

    async def accept(self, reader, writer):
        task = asyncio.current_task()
        self.tasks.add(task)
        upstream_writer = None
        try:
            upstream_reader, upstream_writer = await asyncio.open_connection(
                "127.0.0.1", self.upstream)
            await asyncio.gather(self.pump(reader, upstream_writer, 0),
                                 self.pump(upstream_reader, writer, 1))
        finally:
            writer.close()
            if upstream_writer:
                upstream_writer.close()
            self.tasks.discard(task)

    async def close(self):
        self.server.close()
        await self.server.wait_closed()
        tasks = list(self.tasks)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


async def launch(command):
    return await asyncio.create_subprocess_exec(
        *command, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE)


async def response(proc, timeout=120):
    line = await asyncio.wait_for(proc.stdout.readline(), timeout)
    if not line:
        raise RuntimeError((await proc.stderr.read()).decode())
    return json.loads(line)


async def send(proc, term):
    proc.stdin.write((term + ".\n").encode())
    await proc.stdin.drain()


async def finish(proc):
    if proc.returncode is None:
        await send(proc, "stop")
    _, stderr = await asyncio.wait_for(proc.communicate(), 10)
    if proc.returncode:
        raise RuntimeError(stderr.decode())


async def rss_kib(pid):
    proc = await asyncio.create_subprocess_exec("ps", "-o", "rss=", "-p", str(pid),
                                               stdout=asyncio.subprocess.PIPE)
    return int((await proc.communicate())[0])


async def run_memory(command, count):
    proc = await launch(command + ["memory", str(count)])
    try:
        before = await response(proc)
        baseline = await rss_kib(proc.pid)
        await send(proc, "go")
        after = await response(proc)
        retained = await rss_kib(proc.pid)
        await finish(proc)
        assert before["threads"] == after["threads"]
        return dict(count=count, baseline_rss_kib=baseline, retained_rss_kib=retained,
                    delta_rss_kib=retained-baseline, threads_before=before["threads"],
                    threads_after=after["threads"])
    finally:
        if proc.returncode is None:
            proc.kill()
            await proc.communicate()


async def run_case(command, server, port, rtt, mode, writers, lines, batch):
    proxy = DelayProxy(port, rtt)
    proxy_port = await proxy.start()
    client = None
    try:
        client = await launch(command + ["client", mode,
            f"http://127.0.0.1:{proxy_port}", str(writers), str(lines), str(batch)])
        assert (await response(client))["ready"]
        await send(server, "reset")
        baseline = await response(server)
        wire_start = proxy.bytes.copy()
        await send(client, "go")
        result = await response(client)
        await send(server, "snapshot")
        terminal = await response(server)
        assert terminal["characters"] == lines * 64, terminal
        assert terminal["messages"] == lines // batch, terminal
        assert result["pending_requests"] == 0, result
        result.update(added_rtt_ms=rtt, mode=mode, writers=writers,
                      lines=lines, batch_lines=batch,
                      server_cpu_ms=(terminal["cpu_seconds"]-baseline["cpu_seconds"])*1000,
                      request_bytes=proxy.bytes[0]-wire_start[0],
                      reply_bytes=proxy.bytes[1]-wire_start[1],
                      verified_characters=terminal["characters"])
        await finish(client)
        return result
    finally:
        if client and client.returncode is None:
            client.kill()
            await client.communicate()
        await proxy.close()


async def main(args):
    command = [args.swipl, "-q", "-f", "none", "-s", str(SOURCE),
               "-g", "io_ack_probe:main", "-t", "halt", "--"]
    version = await asyncio.create_subprocess_exec(args.swipl, "--version",
                                                   stdout=asyncio.subprocess.PIPE)
    version_text = (await version.communicate())[0].decode().strip()
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    server = await launch(command + ["server", str(port)])
    result = dict(platform=platform.platform(), swipl=version_text,
                  payload_bytes_per_line=64, clock="wall time",
                  seed=42, rows=[], memory=[])
    try:
        assert (await response(server))["ready"]
        for repetition in range(1, args.repetitions + 1):
            for count in [0, 1000, 10000]:
                row = await run_memory(command, count)
                row["repetition"] = repetition
                result["memory"].append(row)
        cases = [(rtt, mode, writers, batch)
                 for rtt in args.rtts for writers in args.writers
                 for mode, batch in [("async", 1), ("ack", 1), ("ack", 10), ("ack", 100)]]
        rng = random.Random(42)
        for repetition in range(1, args.repetitions + 1):
            rng.shuffle(cases)
            for rtt, mode, writers, batch in cases:
                lines = args.local_lines if rtt == 0 else args.delayed_lines
                row = await run_case(command, server, port, rtt, mode, writers, lines, batch)
                row["repetition"] = repetition
                result["rows"].append(row)
                print(f"{repetition}: RTT+{rtt:g} {mode} writers={writers} "
                      f"batch={batch}: {row['delivered_ms']:.1f} ms", flush=True)
                args.output.write_text(json.dumps(result, indent=2) + "\n")
        await finish(server)
    finally:
        if server.returncode is None:
            server.kill()
            await server.communicate()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swipl", default=os.environ.get("SWIPL", "swipl"))
    parser.add_argument("--rtts", nargs="+", type=float, default=[0, 10, 50])
    parser.add_argument("--writers", nargs="+", type=int, default=[1, 4])
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--local-lines", type=int, default=2000)
    parser.add_argument("--delayed-lines", type=int, default=400)
    parser.add_argument("--output", type=Path,
                        default=SOURCE.with_name("io_ack_probe_results.json"))
    args = parser.parse_args()
    if min(args.rtts) < 0 or min(args.writers) < 1 or args.repetitions < 1:
        parser.error("RTTs must be nonnegative; writers and repetitions positive")
    if any(n < 1 or n % (w * 100) for n in [args.local_lines, args.delayed_lines]
           for w in args.writers):
        parser.error("line counts must be positive multiples of 100 times each writer count")
    asyncio.run(main(args))
