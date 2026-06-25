#!/usr/bin/env python3
"""Guard the frozen shared statechart microstep algorithm.

The desktop and SWI-WASM executors intentionally have different drivers and
runtime integrations.  From select_transitions/2 onward they share the
transition-selection and entry/exit algorithm.  This check removes only the
documented host-specific differences (debug output and desktop invoked-actor
shutdown) before comparing that shared region byte-for-byte.
"""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
DESKTOP = ROOT / "prolog/web_prolog/statechart_exec.pl"
WASM = ROOT / "prolog/web_prolog/wasm/statechart_wasm_exec.pl"
RUNTIME_DESKTOP = ROOT / "prolog/web_prolog/statechart_runtime.pl"
RUNTIME_WASM = ROOT / "prolog/web_prolog/wasm/statechart_wasm_runtime.pl"
MARKER = "select_transitions(Event, EnabledTransitions) :-"
RUNTIME_MARKER = "ordered_add(State, States, NewStates) :-"


def shared_region(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    _, marker, region = text.partition(MARKER)
    if not marker:
        raise ValueError(f"shared-region marker missing in {path}")
    return marker + region


def runtime_shared_region(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    _, marker, region = text.partition(RUNTIME_MARKER)
    if not marker:
        raise ValueError(f"runtime shared-region marker missing in {path}")
    # Invocation is intentionally host-specific: desktop starts actors while
    # WASM defers <spawn>.  Everything before it is frozen shared helper code.
    before_invoke, invoke_marker, _ = region.partition("invoke(State) :-")
    if not invoke_marker:
        # The WASM no-op uses an ignored variable in its head.
        before_invoke, invoke_marker, _ = region.partition("invoke(_State) :-")
    if not invoke_marker:
        raise ValueError(f"runtime invocation marker missing in {path}")
    region = before_invoke
    return marker + region


def normalise(text: str, desktop: bool) -> str:
    text = text.replace("statechart_wasm_exec", "statechart_exec")
    text = text.replace("statechart_wasm", "statechart_actor")

    # Documentation belongs to the host-facing modules and is allowed to
    # differ; the executable clauses below are the frozen contract.
    text = re.sub(r"(?ms)^%![\s\S]*?(?=^[a-z_][A-Za-z0-9_]*\(|\Z)", "", text)

    # Invoked-actor shutdown on state exit is host-specific: the desktop
    # exits the child actor (forall(invoked, exit(Pid, stop))); the WASM port
    # cancels the browser worker via the bridge and consumes the record
    # (forall(retract(invoked), cancel_invoked_child(Pid))).  Strip the
    # cancellation forall, in either form, from both sides so the shared exit
    # algorithm is compared without it.
    text = re.sub(r"\n\s*forall\((?:retract\()?statechart_actor:invoked\(State, Pid\)[^\n]*\),", "", text)

    if desktop:
        # Desktop-only diagnostics.  The WASM port has no debug stream.
        text = re.sub(r",\n\s*debug\([\s\S]*?\]\)\.", ".", text)

    lines = [line.rstrip() for line in text.splitlines()]
    return "\n".join(
        line for line in lines
        if line.strip() and not line.lstrip().startswith("%")
    ) + "\n"


def main() -> int:
    desktop = normalise(shared_region(DESKTOP), desktop=True)
    wasm = normalise(shared_region(WASM), desktop=False)
    import difflib
    checks = [
        ("shared microstep algorithm", desktop, wasm, DESKTOP, WASM),
        ("shared runtime helpers",
         normalise(runtime_shared_region(RUNTIME_DESKTOP), desktop=True),
         normalise(runtime_shared_region(RUNTIME_WASM), desktop=False),
         RUNTIME_DESKTOP, RUNTIME_WASM),
    ]
    failed = False
    for label, left, right, left_path, right_path in checks:
        if left == right:
            print(f"statechart WASM {label}: PASS")
            continue
        failed = True
        print(f"statechart WASM {label}: FAIL", file=sys.stderr)
        sys.stderr.writelines(difflib.unified_diff(
            left.splitlines(keepends=True), right.splitlines(keepends=True),
            fromfile=str(left_path), tofile=str(right_path)
        ))
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
