#!/usr/bin/env python3
"""Run the shared error cases against disposable native node fixtures."""

import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
from tempfile import TemporaryDirectory
from time import monotonic, sleep
from urllib.error import URLError
from urllib.request import urlopen


def wait_for(check):
    deadline = monotonic() + 15
    while monotonic() < deadline:
        if check():
            return
        sleep(0.1)
    raise RuntimeError("Error contract fixture did not start")


def ready(url):
    try:
        with urlopen(url + "/node_info", timeout=1) as response:
            return response.status == 200
    except (OSError, URLError):
        return False


def swipl_fixture(stack, native, profile, scratch):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    log = stack.enter_context((scratch / (profile + ".log")).open("w"))
    loader = native / "prolog" / "web_prolog.pl"
    process = subprocess.Popen([
        os.environ.get("SWIPL", "swipl"), "-f", "none", "-q", "-s", str(loader),
        "-g", f"node:node({port},[profile({profile}),auth(open)]),thread_get_message(stop)",
    ], stdout=log, stderr=log)
    stack.callback(process.wait, 10)
    stack.callback(process.terminate)
    url = f"http://127.0.0.1:{port}"
    wait_for(lambda: ready(url))
    return url


def container(stack, *args):
    name = subprocess.check_output(["docker", "run", "-d", *args], text=True).strip()
    stack.callback(subprocess.run, ["docker", "rm", "-f", name], stdout=subprocess.DEVNULL)
    return name


def suite(command, root, name, url, profile, label, report):
    result = subprocess.run([
        *command, f"{root}/runner/baseline.py", "--manifest", f"{root}/cases/{name}.json",
        "--url", url, "--profile", profile, "--candidate", label, "--report", str(report),
    ], text=True, capture_output=True, timeout=90)
    lines = result.stdout.splitlines()
    counts = json.loads(lines[-1]) if lines and lines[-1].startswith("{") else {}
    if result.returncode or not counts.get("pass") or counts.get("unsupported"):
        # Keep actual responses and fixture logs out of hosted CI output.
        failed = [line.split()[1] for line in lines if line.startswith(("FAIL ", "UNSUPPORTED "))]
        raise RuntimeError(f"{label} {name} failed: {', '.join(failed) or 'incomplete suite'}")
    print(f"{label} {name} passed", flush=True)


def check_swi_and_trealla(args, scratch):
    with ExitStack() as stack:
        swi = swipl_fixture(stack, args.swi, "actor", scratch)
        relation = swipl_fixture(stack, args.swi, "relation", scratch)
        name = container(stack, "-p", "127.0.0.1::3060", "--entrypoint", "/opt/trealla/tpl",
                         args.trealla_image, "-g",
                         "use_module(web_prolog),web_prolog_node(3060,[profile(actor),auth(open)]),thread_get_message(stop)")
        binding = subprocess.check_output(["docker", "port", name, "3060/tcp"], text=True).strip()
        trealla = "http://" + binding
        wait_for(lambda: ready(trealla))
        for label, url in [("SWI", swi), ("Trealla", trealla)]:
            suite([sys.executable], args.conformance, "error-contract-0.1", url, "actor", label,
                  scratch / (label + "-http.json"))
            suite([sys.executable], args.conformance, "actor-error-contract-0.1",
                  url.replace("http:", "ws:", 1) + "/ws", "actor", label, scratch / (label + "-ws.json"))
        suite([sys.executable], args.conformance, "relation-error-admission-0.1",
              relation, "relation", "SWI RELATION", scratch / "relation.json")


def check_gnu(args, scratch):
    with ExitStack() as stack:
        name = container(stack, "--network", "none", "--entrypoint", "/app/isobase/isobase-node",
                         args.gnu_image, "--auth", "open", "--port", "8081")
        check = ["docker", "exec", name, "python3", "-c",
                 "import socket; socket.create_connection(('127.0.0.1',8081),1).close()"]
        wait_for(lambda: subprocess.run(check, capture_output=True).returncode == 0)
        root = "/tmp/error-conformance"
        subprocess.run(["docker", "exec", name, "mkdir", "-p", root], check=True)
        for directory in ("runner", "cases"):
            subprocess.run(["docker", "cp", str(args.conformance / directory), f"{name}:{root}/"], check=True)
        manifest = json.loads((args.conformance / "cases/error-contract-0.1.json").read_text())
        # The missing procedure is covered by the separate N6 admission case.
        manifest["cases"] = [case for case in manifest["cases"] if case["id"] != "ER-007"]
        selection = scratch / "gnu-error-contract.json"
        selection.write_text(json.dumps(manifest))
        selection.chmod(0o644)
        subprocess.run(["docker", "cp", str(selection), f"{name}:{root}/cases/"], check=True)
        subprocess.run(["docker", "exec", "--user", "0", name, "chmod", "-R", "a+rX", root], check=True)
        command = ["docker", "exec", name, "python3"]
        url = "http://127.0.0.1:8081"
        suite(command, root, "gnu-error-contract", url, "isobase", "GNU Prolog", "/tmp/errors.json")
        suite(command, root, "isobase-error-admission-0.1", url, "isobase", "GNU Prolog ISOBASE",
              "/tmp/admission.json")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swi", type=Path, required=True)
    parser.add_argument("--conformance", type=Path, required=True)
    parser.add_argument("--trealla-image", required=True)
    parser.add_argument("--gnu-image", required=True)
    args = parser.parse_args()
    with TemporaryDirectory(prefix="native-error-contract-") as directory:
        scratch = Path(directory)
        check_swi_and_trealla(args, scratch)
        check_gnu(args, scratch)


if __name__ == "__main__":
    main()
