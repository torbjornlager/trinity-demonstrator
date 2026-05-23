#!/usr/bin/env python3
from __future__ import annotations

from collections import defaultdict
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs" / "DEPENDENCY_GRAPH.md"
ARTIFACT_DIR = ROOT / "docs" / "generated" / "dependency_graph"
USE_MODULE_RE = re.compile(r":-\s*use_module\s*\(", re.MULTILINE)
EXCLUDED_PARTS = {".git", ".claude", "Tau-Prolog", "node_modules", "__pycache__"}


def project_files() -> list[Path]:
    files = []
    for path in ROOT.rglob("*.pl"):
        if any(part in EXCLUDED_PARTS for part in path.parts):
            continue
        files.append(path)
    return sorted(files)


def unquote(term: str) -> str:
    term = term.strip()
    if len(term) >= 2 and term[0] == "'" and term[-1] == "'":
        return term[1:-1].replace("''", "'")
    if len(term) >= 2 and term[0] == '"' and term[-1] == '"':
        return term[1:-1]
    return term


def split_first_arg(args_text: str) -> str:
    depth = 0
    quote = None
    i = 0
    while i < len(args_text):
        ch = args_text[i]
        if quote == "'":
            if ch == "'":
                if i + 1 < len(args_text) and args_text[i + 1] == "'":
                    i += 2
                    continue
                quote = None
            i += 1
            continue
        if quote == '"':
            if ch == '"':
                quote = None
            i += 1
            continue
        if ch in "'\"":
            quote = ch
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            return args_text[:i].strip()
        i += 1
    return args_text.strip()


def extract_use_module_args(text: str) -> list[str]:
    args_list = []
    for match in USE_MODULE_RE.finditer(text):
        start = match.end() - 1
        depth = 0
        quote = None
        i = start
        while i < len(text):
            ch = text[i]
            if quote == "'":
                if ch == "'":
                    if i + 1 < len(text) and text[i + 1] == "'":
                        i += 2
                        continue
                    quote = None
                i += 1
                continue
            if quote == '"':
                if ch == '"':
                    quote = None
                i += 1
                continue
            if ch in "'\"":
                quote = ch
            elif ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    args_list.append(text[start + 1:i])
                    break
            i += 1
    return args_list


def resolve_local_import(source: Path, raw_spec: str) -> Path | None:
    spec = raw_spec.strip()
    if not spec or spec.startswith("library("):
        return None

    candidates: list[Path] = []

    if spec[0] in "'\"":
        value = unquote(spec)
        path = Path(value)
        if path.is_absolute():
            candidates.append(path)
        else:
            candidates.append((source.parent / path).resolve())
            candidates.append((ROOT / path).resolve())
            if path.suffix != ".pl":
                candidates.append((source.parent / path).with_suffix(".pl").resolve())
                candidates.append((ROOT / path).with_suffix(".pl").resolve())
    else:
        path = Path(spec)
        if "/" in spec or spec.startswith(".") or path.suffix == ".pl":
            candidates.append((source.parent / path).resolve())
            candidates.append((ROOT / path).resolve())
            if path.suffix != ".pl":
                candidates.append((source.parent / path).with_suffix(".pl").resolve())
                candidates.append((ROOT / path).with_suffix(".pl").resolve())
        else:
            candidates.append((source.parent / f"{spec}.pl").resolve())
            candidates.append((ROOT / f"{spec}.pl").resolve())

    seen = set()
    for candidate in candidates:
        if candidate in seen:
            continue
        seen.add(candidate)
        if candidate.exists():
            try:
                candidate.relative_to(ROOT)
            except ValueError:
                continue
            return candidate
    return None


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def link_rel(path: Path) -> str:
    import os
    return os.path.relpath(path, OUTPUT.parent).replace(os.sep, "/")


def slugify(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def dot_escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"')


def build_dot(title: str, edges: list[tuple[str, str]]) -> str:
    nodes = sorted({item for edge in edges for item in edge})
    ids = {node: f"n{index}" for index, node in enumerate(nodes)}
    lines = [
        "digraph dependency_graph {",
        '  graph [rankdir=TB, labelloc=t, labeljust=l, fontsize=20, fontname="Helvetica", overlap=false, splines=true, nodesep=0.28, ranksep=0.55, pad=0.2];',
        '  node [shape=box, style="rounded", color="#666666", fontname="Helvetica", fontsize=11, margin="0.08,0.05"];',
        '  edge [color="#555555", arrowsize=0.7, penwidth=1.0];',
        f'  label="{dot_escape(title)}";',
    ]
    for node in nodes:
        lines.append(f'  {ids[node]} [label="{dot_escape(node)}"];')
    for source, target in edges:
        lines.append(f"  {ids[source]} -> {ids[target]};")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def reset_artifact_dir() -> None:
    ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)
    for pattern in ("*.dot", "*.svg"):
        for path in ARTIFACT_DIR.glob(pattern):
            path.unlink()


def render_section_graph(title: str, edges: list[tuple[str, str]]) -> tuple[Path, Path, int, int]:
    slug = slugify(title)
    dot_path = ARTIFACT_DIR / f"{slug}.dot"
    svg_path = ARTIFACT_DIR / f"{slug}.svg"
    dot_text = build_dot(title, edges)
    dot_path.write_text(dot_text, encoding="utf-8")
    subprocess.run(["dot", "-Tsvg", str(dot_path), "-o", str(svg_path)], check=True)
    node_count = len({item for edge in edges for item in edge})
    edge_count = len(edges)
    return dot_path, svg_path, node_count, edge_count


def imports_table(edges_by_source: dict[str, set[str]]) -> list[str]:
    lines = [
        "## Source To Local Imports",
        "",
        "| Source | Local imports |",
        "| --- | --- |",
    ]
    for source in sorted(edges_by_source):
        imports = sorted(edges_by_source[source])
        rendered = ", ".join(f"`{item}`" for item in imports) if imports else "-"
        lines.append(f"| `{source}` | {rendered} |")
    lines.append("")
    return lines


def section_groups(all_edges: list[tuple[str, str]]) -> list[tuple[str, list[tuple[str, str]]]]:
    root_sources = {source for source, _ in all_edges if "/" not in source}
    node_sources = {
        source
        for source, _ in all_edges
        if source == "node.pl"
        or source.startswith("node_")
        or source in {
            "actor.pl",
            "actor_io_support.pl",
            "toplevel_actor.pl",
            "pid_utils.pl",
            "dollar_expansion.pl",
            "node_client.pl",
            "statechart_actor.pl",
        }
    }
    statechart_sources = {source for source, _ in all_edges if source.startswith("statechart")}

    return [
        ("All Local Module Dependencies", all_edges),
        ("Root Modules", [edge for edge in all_edges if edge[0] in root_sources]),
        ("Node Runtime And Session Modules", [edge for edge in all_edges if edge[0] in node_sources]),
        ("Statechart Modules", [edge for edge in all_edges if edge[0] in statechart_sources]),
        ("Deployment Modules", [edge for edge in all_edges if edge[0].startswith("Deployment/")]),
        ("Tests", [edge for edge in all_edges if edge[0].startswith("tests/")]),
        ("Examples", [edge for edge in all_edges if edge[0].startswith("examples/")]),
        ("PoC Libraries", [edge for edge in all_edges if edge[0].startswith("poc-libraries/")]),
    ]


def graph_sections(all_edges: list[tuple[str, str]]) -> list[str]:
    lines: list[str] = []
    for title, edges in section_groups(all_edges):
        unique_edges = sorted(set(edges))
        if not unique_edges:
            continue
        dot_path, svg_path, node_count, edge_count = render_section_graph(title, unique_edges)
        dot_rel = link_rel(dot_path)
        svg_rel = link_rel(svg_path)
        lines.extend([
            f"## {title}",
            "",
            f"- Nodes: `{node_count}`",
            f"- Edges: `{edge_count}`",
            "",
            f"![{title}]({svg_rel})",
            "",
            f"[Open SVG]({svg_rel}) | [DOT source]({dot_rel})",
            "",
        ])
    return lines


def main() -> None:
    files = project_files()
    edges: set[tuple[str, str]] = set()
    edges_by_source: dict[str, set[str]] = defaultdict(set)

    for source in files:
        text = source.read_text(encoding="utf-8")
        source_rel = rel(source)
        edges_by_source.setdefault(source_rel, set())
        for args_text in extract_use_module_args(text):
            first_arg = split_first_arg(args_text)
            target = resolve_local_import(source, first_arg)
            if target is None:
                continue
            target_rel = rel(target)
            if target_rel == source_rel:
                continue
            edges.add((source_rel, target_rel))
            edges_by_source[source_rel].add(target_rel)

    all_edges = sorted(edges)
    reset_artifact_dir()

    lines = [
        "<!-- Generated by tools/generate_dependency_graph.py; do not edit by hand. -->",
        "# Dependency Graph",
        "",
        "This file is generated from local `use_module/1-2` directives in this repository.",
        "It tracks project-internal module dependencies only and intentionally omits SWI",
        "library imports, dynamic loading, and runtime-only relationships.",
        "",
        "Static graph images are rendered with Graphviz `dot` and stored in",
        "`docs/generated/dependency_graph/`.",
        "",
        "Regenerate with:",
        "",
        "```bash",
        "python3 tools/generate_dependency_graph.py",
        "```",
        "",
        "## Summary",
        "",
        f"- Prolog files scanned: `{len(files)}`",
        f"- Local dependency edges found: `{len(all_edges)}`",
        "- Source basis: static `use_module/1-2` directives only",
        "- Renderer: Graphviz `dot` -> SVG",
        "",
    ]
    lines.extend(graph_sections(all_edges))
    lines.extend(imports_table(edges_by_source))
    lines.extend([
        "## Notes",
        "",
        "- This artifact is generated. Edit the generator, not this file.",
        "- A missing edge here does not prove the absence of a runtime dependency.",
        "  Predicates loaded via `load_*` options, `consult/1`, or remote node mechanisms",
        "  are outside the scope of this graph.",
        "- Local import resolution first tries paths relative to the importing file and then",
        "  falls back to the repository root.",
        "",
    ])
    OUTPUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {OUTPUT}")
    print(f"wrote artifacts to {ARTIFACT_DIR}")


if __name__ == "__main__":
    main()
