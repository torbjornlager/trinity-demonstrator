#!/usr/bin/env python3
"""Assemble browser Prolog payloads using the pinned native SXML schema.

Output must be fresh. No source file or live asset directory is overwritten.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--native-root', required=True, type=Path)
    p.add_argument('--browser-root', required=True, type=Path)
    p.add_argument('--output', required=True, type=Path)
    a = p.parse_args()
    if a.output.exists():
        p.error('output must not exist')
    names = ['shared_db.pl', 'statechart_wasm.pl', 'statechart_wasm_exec.pl',
             'statechart_wasm_model.pl', 'statechart_wasm_runtime.pl', 'sxml_schema.pl']
    sources = {n: (a.native_root if n == 'sxml_schema.pl' else a.browser_root)
               / 'prolog/web_prolog/wasm' / n for n in names}
    for source in sources.values():
        if not source.is_file():
            p.error(f'missing source: {source}')
    a.output.mkdir(parents=True)
    manifest = []
    for name, source in sources.items():
        target = a.output / name
        shutil.copy2(source, target)
        manifest.append(dict(path=name, source=str(source.resolve()),
                             sha256=hashlib.sha256(target.read_bytes()).hexdigest()))
    (a.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Packaged {len(manifest)} browser Prolog files without modifying either source tree')


if __name__ == '__main__':
    main()
