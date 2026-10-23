#!/usr/bin/env python3
"""Create a local native-only rehearsal; never mutate the source repository.

A full, independent clone preserves original commit IDs and the historical T5
peer. The destination must not exist. No network repository is created/pushed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PEER = '2b5eae7ad4118e88f4aec77c513b6204dbf3b69e'
PREPARED = ['prolog/web_prolog/statechart_actor.pl',
            'tests/tiers/behaviours/statechart_actor_tests.pl']


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()


def native_path(path):
    return (path in ['.gitignore', 'LICENSE', 'ATTRIBUTION.md', 'DEVIATIONS.md',
                     'pack.pl', 'load.pl', 'README.md', 'CLAUDE.md',
                     'tools/test.sh', 'tools/generate_dependency_graph.py']
            or path.startswith(('tests/tiers/', 'tests/test_statecharts/', 'docs/'))
            or path == 'prolog/web_prolog.pl'
            or (path.startswith('prolog/web_prolog/')
                and ('/wasm/' not in path or path.endswith('/wasm/sxml_schema.pl'))))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--destination', required=True, type=Path)
    p.add_argument('--report-dir', required=True, type=Path)
    args = p.parse_args()
    dst = args.destination.resolve()
    if dst.exists():
        p.error('destination must not exist; no existing checkout will be replaced')
    revision = git(ROOT, 'rev-parse', 'HEAD')
    assert git(ROOT, 'rev-parse', 'demonstrator-peer^{commit}') == PEER
    tracked = git(ROOT, 'ls-files').splitlines()
    before = {f: digest(ROOT / f) for f in tracked}
    subprocess.run(['git', 'clone', '--no-hardlinks', '--no-local', str(ROOT), str(dst)], check=True)
    # Archive all source refs, including remote-tracking research branches, so
    # removing the publishing remote cannot leave their history unreachable.
    refs = git(ROOT, 'for-each-ref', '--format=%(refname)').splitlines()
    git(dst, 'fetch', '--no-tags', str(ROOT),
        *[f'+{ref}:refs/archive/trinity-demonstrator/{ref[5:]}' for ref in refs])
    # The only clone source is the local repository, not a network URL.
    git(dst, 'remote', 'remove', 'origin')
    assert git(dst, 'rev-parse', 'HEAD') == revision
    assert git(dst, 'rev-parse', 'demonstrator-peer^{commit}') == PEER
    for name in PREPARED:
        shutil.copy2(ROOT / name, dst / name)
    git(dst, 'add', '--', *PREPARED)
    if git(dst, 'diff', '--cached', '--name-only'):
        git(dst, 'commit', '-m', 'Resolve statechart example helpers against an explicit asset root')
    prepared_revision = git(dst, 'rev-parse', 'HEAD')
    retained = [f for f in tracked if native_path(f)]
    excluded = [f for f in tracked if not native_path(f)]
    for offset in range(0, len(excluded), 100):
        git(dst, 'rm', '--', *excluded[offset:offset + 100])
    git(dst, 'commit', '-m', 'Extract native SWI package working tree while retaining full source history')
    extraction_revision = git(dst, 'rev-parse', 'HEAD')
    for name in ['README.md', 'CLAUDE.md']:
        text = (ROOT / 'tools/swi_repository_templates' / name).read_text()
        (dst / name).write_text(text.replace('@SOURCE_REVISION@', revision))
    runner = dst / 'tools/test.sh'
    text = runner.read_text().replace('SELECT="$*"', '\n'.join([
        'SELECT="$*"',
        '# Native checkout default; external content and legacy-layout gates stay explicit.',
        'if [ -z "$SELECT" ]; then',
        '    SELECT="LINT T0 T1_NATIVE T2 T3_NATIVE T4_NATIVE T5"', 'fi']))
    runner.write_text(text)
    for name in ['docs/SWI_NODE_EXTRACTION_MAP.md', 'prolog/web_prolog/README.md']:
        shutil.copy2(ROOT / name, dst / name)
    git(dst, 'add', '--', 'README.md', 'CLAUDE.md', 'tools/test.sh',
        'docs/SWI_NODE_EXTRACTION_MAP.md', 'prolog/web_prolog/README.md')
    git(dst, 'commit', '-m', 'Document native rehearsal and select standalone native test gates by default')
    packaging_revision = git(dst, 'rev-parse', 'HEAD')
    # This is a copy/extraction commit, with no edits to retained content.
    assert not git(dst, 'diff', prepared_revision, extraction_revision, '--', *retained)
    assert {f: digest(ROOT / f) for f in tracked} == before
    inventory = [dict(path=f, sha256=before[f], native_working_tree=f in retained,
                      preserved_in_original=True, preserved_in_history=True) for f in tracked]
    out = args.report_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    (out / 'inventory.json').write_text(json.dumps(inventory, indent=2) + '\n')
    record = dict(source=str(ROOT), source_revision=revision, destination=str(dst),
                  prepared_revision=prepared_revision, extraction_revision=extraction_revision,
                  packaging_revision=packaging_revision,
                  historical_peer=PEER, original_tracked_files=len(tracked),
                  retained=len(retained), historical_only=len(excluded),
                  source_files_unchanged=True, remote_configured=False, archived_source_refs=refs,
                  history_strategy='full independent clone; original commit IDs and tags retained')
    (out / 'extraction.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    main()
