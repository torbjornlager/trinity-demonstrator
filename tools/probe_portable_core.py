#!/usr/bin/env python3
"""Run the portable-core draft on selected engines and existing loopback nodes."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import importlib
import json
from pathlib import Path
import subprocess
import sys
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
CASES = ROOT / "tests/portable-core/cases.json"
MARKER = "portable_core_result="
RPC_SOURCE = (
    "portable_rpc_probe(pair(A,A,_)). "
    "portable_rpc_probe(_) :- throw(portable_rpc_fault(after_page))."
)
RPC_EVENTS = "success([[answer(shared),raised(portable_rpc_fault(after_page))]],false)."
RETAINED_SOURCE = (
    "portable_retained_probe(page). "
    "portable_retained_probe(_) :- throw(portable_rpc_fault(after_page))."
)
RETAINED_GOAL = "portable_retained_probe(X)"


def outcome(read_goal):
    return (
        f"catch((({read_goal}) -> (call(Goal) -> Outcome=success ; Outcome=failure)"
        " ; Outcome=read_failure),"
        "Error, (Error=error(Formal,_) -> Outcome=exception(Formal)"
        " ; Outcome=exception(Error)))"
    )


def engine_probe(name, executable, case):
    goal = case.get("engine_goal", case["goal"])
    source = f"({goal}).\n"
    if name == "wasm":
        command = [executable, str(ROOT / "tests/portable-core/wasm.cjs")]
        quoted_source = json.dumps(source, ensure_ascii=False)
        payload = json.dumps(outcome(f"term_string(Goal, {quoted_source})"))
    else:
        stream = "input" if name == "eclipse" else "user_input"
        query = outcome(f"read_term({stream}, Goal, [])")
        query += f", nl, write('{MARKER}'), writeq(Outcome), nl, halt"
        payload = source
        if name == "swi":
            command = [executable, "-q", "-f", "none", "-g", query, "-t", "halt(2)"]
        elif name == "trealla":
            command = [executable, "-q", "-g", query + "."]
        elif name == "gnu":
            command = [executable, "--quiet", "--query-goal", query]
        else:
            command = [
                "docker", "run", "--rm", "-i", "--pull=never", "--network", "none",
                "--entrypoint", "/eclipse/lib/aarch64_linux/eclipse.exe",
                executable, "-D", "/eclipse", "-e", query,
            ]
    result = subprocess.run(command, input=payload, capture_output=True, text=True, timeout=20)
    for line in result.stdout.splitlines():
        if result.returncode == 0 and line.startswith(MARKER):
            return line.removeprefix(MARKER)
    raise RuntimeError(f"exit {result.returncode}: {(result.stderr or result.stdout)[-700:].strip()}")


def http_probe(baseline, url, case):
    params = {"goal": case["goal"], "format": "prolog", "template": case.get("template", "ok")}
    return baseline.http_request(url, params, 8, None)


def run_target(label, probe, cases, baseline, http=False):
    rows = []
    for case in cases:
        required = "answer" in case and (http or not case.get("engine_diagnostic"))
        row = {"id": case["id"]}
        if not required and "expected" in case:
            row["reference_outcome"] = case["expected"]
        try:
            observed = probe(case)
            row["observation"] = observed
            if http and observed["http_status"] != 200:
                row["status"] = "fail" if required else "diagnostic_error"
            elif required:
                if http:
                    passed = baseline.variant_tokens(observed["body"]) == baseline.variant_tokens(case["answer"])
                else:
                    passed = observed == "success"
                row["status"] = "pass" if passed else "fail"
            else:
                row["status"] = "observed"
        except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
            row.update(status="fail" if required else "diagnostic_error", detail=str(error))
        rows.append(row)
    return label, rows


def node_cases(cases, require_call, require_wire):
    for case in cases:
        if require_call and "node_call_check" in case:
            yield {**case, **case["node_call_check"]}
        elif require_wire and case.get("node_wire_check"):
            yield {**case, "answer": "error(error(representation_error(portable_term),_))."}
        else:
            yield case


def replay_replies(baseline, nodes, cases, results):
    rows = []
    expected = baseline.variant_tokens("success([ok],false).")
    for sender in nodes:
        for case, result in zip(cases, results[sender]):
            if "replay_goal" not in case or result["status"] != "pass":
                continue
            # Only feed back the two response shapes already checked above.
            reply = result["observation"]["body"].strip().removesuffix(".")
            params = {
                "goal": case["replay_goal"],
                "src_text": f"portable_core_reply({reply}).",
                "template": "ok",
                "format": "prolog",
            }
            for receiver, url in nodes.items():
                row = {"id": case["id"], "sender": sender, "receiver": receiver}
                try:
                    observed = baseline.http_request(url, params, 8, None)
                    passed = (observed["http_status"] == 200
                              and baseline.variant_tokens(observed["body"]) == expected)
                    row.update(status="pass" if passed else "fail", observation=observed)
                except (OSError, ValueError) as error:
                    row.update(status="fail", detail=str(error))
                rows.append(row)
    return rows


def rpc_replays(baseline, nodes, limit):
    """Exercise the caller's rpc/3 across two separately listening nodes."""
    rows = []
    expected = baseline.variant_tokens(RPC_EVENTS)
    for caller, url in nodes.items():
        for peer, destination in nodes.items():
            if caller == peer:
                continue
            goal = (
                "findall(Event,catch(("
                f"rpc('{destination}',portable_rpc_probe(Value),"
                f"[src_text('{RPC_SOURCE}'),limit({limit})]),"
                "Value=pair(A,B,C),var(A),var(B),var(C),A==B,A\\==C,"
                "Event=answer(shared)),Error,Event=raised(Error)),Events)"
            )
            row = {"caller": caller, "peer": peer, "limit": limit}
            try:
                observed = baseline.http_request(
                    url, {"goal": goal, "template": "Events", "format": "prolog"}, 8, None
                )
                passed = (observed["http_status"] == 200
                          and baseline.variant_tokens(observed["body"]) == expected)
                row.update(status="pass" if passed else "fail", observation=observed)
            except (OSError, ValueError) as error:
                row.update(status="fail", detail=str(error))
            rows.append(row)
    return rows


def retained_probe(baseline, url, transport, observed):
    def check_page(event, more):
        observed.append(event)
        baseline.actor.require(
            event.get("type") == "success" and event.get("pid") == pid
            and event.get("data") == [{"X": "page"}]
            and event.get("more") is more, repr(event)
        )

    def check_error(event):
        observed.append(event)
        fault = baseline.variant_tokens("portable_rpc_fault(after_page)")
        payloads = (event.get(key, "") for key in ("term", "details", "data"))
        baseline.actor.require(
            event.get("type") == "error" and event.get("pid") == pid
            and any(isinstance(value, str) and baseline.variant_tokens(value) == fault
                    for value in payloads), repr(event)
        )

    if transport == "ws":
        actor = baseline.actor
        ws_url = urlsplit(url)._replace(scheme="ws", path="/ws").geturl()
        candidate = actor.Candidate(ws_url, "actor", 8, None, None, False, ())
        with actor.Harness(candidate) as harness:
            pid = harness.spawn_shell(f"[session(true),src_text('{RETAINED_SOURCE}')]")
            try:
                harness.call(RETAINED_GOAL, "[limit(2)]")
                check_page(harness.recv(), True)
                harness.next()
                check_error(harness.recv())
                harness.call(RETAINED_GOAL + ",!")
                check_page(harness.recv(), False)
            finally:
                harness.halt()
    else:
        post = importlib.import_module("prompt_http").post
        event = post(url, "spawn", {"options": "[session(true)]", "src_text": RETAINED_SOURCE})
        baseline.actor.require(event.get("type") == "spawned", repr(event))
        pid = event["pid"]
        fields = {"pid": pid, "format": "json"}
        try:
            check_page(post(url, "call", {**fields, "goal": RETAINED_GOAL, "limit": 2}), True)
            check_error(post(url, "next", fields))
            check_page(post(url, "call", {**fields, "goal": RETAINED_GOAL + ",!"}), False)
        finally:
            event = post(url, "halt", fields)
            baseline.actor.require(event.get("type") == "halted", repr(event))


def retained_checks(baseline, nodes, retained):
    rows = []
    for label, transport in retained.items():
        row = {"node": label, "transport": transport, "observations": []}
        try:
            retained_probe(baseline, nodes[label], transport, row["observations"])
            row["status"] = "pass"
        except (OSError, ValueError, AssertionError, baseline.actor.ProtocolError) as error:
            row.update(status="fail", detail=str(error))
        rows.append(row)
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for engine in ("swi", "trealla", "gnu"):
        parser.add_argument(f"--{engine}", metavar="EXECUTABLE")
    parser.add_argument("--wasm", metavar="NODE_EXECUTABLE")
    parser.add_argument("--eclipse", metavar="LOCAL_DOCKER_IMAGE")
    parser.add_argument("--http", action="append", default=[], metavar="NAME=URL")
    parser.add_argument("--require-node-call", action="store_true",
                        help="gate the Web Prolog meta-call cases on every selected HTTP node")
    parser.add_argument("--require-wire-rejection", action="append", default=[], metavar="NAME",
                        help="gate rejection on a selected HTTP node whose engine exposes the excluded values")
    parser.add_argument("--require-rpc", action="store_true",
                        help="check cross-node rpc/3 for every ordered pair of distinct HTTP nodes")
    parser.add_argument("--retained-http", action="append", default=[], metavar="NAME")
    parser.add_argument("--retained-ws", action="append", default=[], metavar="NAME")
    parser.add_argument("--release-gate", action="store_true",
                        help="require the full HTTP, RPC and retained matrix on swi, trealla, gnu and eclipse")
    parser.add_argument("--conformance-root", type=Path, default=ROOT.parent / "trinity-conformance")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()

    targets = []
    nodes = {}
    baseline = None
    if args.http:
        sys.path.insert(0, str(args.conformance_root / "runner"))
        baseline = importlib.import_module("baseline")
    for name in ("swi", "trealla", "gnu", "eclipse", "wasm"):
        if executable := getattr(args, name):
            targets.append((f"{name}-engine", lambda case, n=name, e=executable: engine_probe(n, e, case), False))
    for entry in args.http:
        name, separator, url = entry.partition("=")
        try:
            origin = urlsplit(url)
            port = origin.port
        except ValueError:
            parser.error("--http expects NAME=http://127.0.0.1:PORT")
        if (not separator or not name or origin.scheme != "http"
                or origin.hostname not in {"127.0.0.1", "localhost", "::1"}
                or origin.username or origin.password or origin.path not in {"", "/"}
                or origin.query or origin.fragment or not port):
            parser.error("--http expects NAME=http://127.0.0.1:PORT")
        host = "[::1]" if origin.hostname == "::1" else origin.hostname
        url = f"http://{host}:{port}"
        targets.append((f"{name}-http", lambda case, u=url: http_probe(baseline, u, case), True))
        nodes[f"{name}-http"] = url
    if not targets or len({label for label, _, _ in targets}) != len(targets):
        parser.error("select at least one target and give each HTTP target a unique name")
    if args.release_gate:
        if set(nodes) != {"swi-http", "trealla-http", "gnu-http", "eclipse-http"}:
            parser.error("--release-gate requires the four HTTP targets swi, trealla, gnu and eclipse")
        args.require_node_call = args.require_rpc = True
        args.require_wire_rejection.append("swi")
        args.retained_http.append("eclipse")
        args.retained_ws.extend(("swi", "trealla"))
    wire_targets = {f"{name}-http" for name in args.require_wire_rejection}
    if wire_targets - nodes.keys() or (args.require_node_call and not nodes):
        parser.error("required node checks must refer to selected HTTP nodes")
    if args.require_rpc and (len(nodes) < 2 or len(set(nodes.values())) != len(nodes)):
        parser.error("--require-rpc needs at least two HTTP nodes with distinct endpoints")
    retained_targets = {f"{name}-http": "http" for name in args.retained_http}
    if set(args.retained_http) & set(args.retained_ws):
        parser.error("select one retained transport per node")
    retained_targets.update({f"{name}-http": "ws" for name in args.retained_ws})
    if retained_targets.keys() - nodes.keys():
        parser.error("retained checks must refer to selected HTTP nodes")

    pack = json.loads(CASES.read_text())
    with ThreadPoolExecutor(max_workers=len(targets)) as executor:
        jobs = [
            executor.submit(run_target, label, probe,
                            node_cases(pack["cases"], args.require_node_call and http,
                                       label in wire_targets), baseline, http)
            for label, probe, http in targets
        ]
        results = dict(job.result() for job in jobs)
    replay = replay_replies(baseline, nodes, pack["cases"], results) if nodes else []
    rpc = [row for limit in (1, 2) for row in rpc_replays(baseline, nodes, limit)] if args.require_rpc else []
    retained = retained_checks(baseline, nodes, retained_targets)
    data = {"suite": pack["suite"], "results": results, "replay": replay}
    if args.require_rpc:
        data["rpc"] = rpc
    if retained:
        data["retained"] = retained
    report = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    if args.report:
        args.report.write_text(report)
    else:
        print(report, end="")
    for label, rows in results.items():
        counts = {status: sum(row["status"] == status for row in rows)
                  for status in ("pass", "fail", "observed", "diagnostic_error")}
        print(label, counts, file=sys.stderr)
    if replay:
        print(f"HTTP replay {sum(row['status'] == 'pass' for row in replay)}/{len(replay)} passed",
              file=sys.stderr)
    if rpc:
        print(f"Cross-node RPC {sum(row['status'] == 'pass' for row in rpc)}/{len(rpc)} passed",
              file=sys.stderr)
    if retained:
        print(f"Retained sessions {sum(row['status'] == 'pass' for row in retained)}/{len(retained)} passed",
              file=sys.stderr)
    return any(row["status"] in {"fail", "diagnostic_error"}
               for rows in [*results.values(), replay, rpc, retained] for row in rows)


if __name__ == "__main__":
    raise SystemExit(main())
