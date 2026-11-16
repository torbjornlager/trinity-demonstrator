#!/usr/bin/env python3
"""Assemble an N7 adapter image context without changing running services."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(release, output, adapter_source=None):
    manifest = json.loads((release / 'manifest.json').read_text())
    # Validate the packaged inputs that enter the image, including wheels.
    selected = ('experiments/eclipse-clp/', 'shell/', 'Deployment/', 'examples/', 'wheels/')
    inputs = {name: value for name, value in manifest['files'].items()
              if name.startswith(selected)}
    actual = {str(path.relative_to(release))
              for directory in selected for path in (release / directory).rglob('*')
              if path.is_file()}
    if actual != set(inputs):
        raise ValueError('Packaged N7 input file inventory differs')
    for name, expected in inputs.items():
        if not isinstance(expected, str) or digest(release / name) != expected:
            raise ValueError('Packaged N7 input differs: ' + name)
    output.mkdir(mode=0o700)
    for directory in selected:
        shutil.copytree(release / directory, output / directory,
                        ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    for path in output.rglob('*'):
        path.chmod(0o700 if path.is_dir() else 0o600)
    overlay = {}
    if adapter_source is not None:
        target = output / 'experiments/eclipse-clp/isotope_http.py'
        shutil.copyfile(adapter_source, target)
        overlay[str(target.relative_to(output))] = digest(target)
    record = dict(parent_release=str(release), parent_manifest_sha256=digest(release / 'manifest.json'),
                  engine_image=manifest['image_id'], adapter_overlay=overlay,
                  files={str(p.relative_to(output)): digest(p) for p in output.rglob('*') if p.is_file()})
    (output / 'container-inputs.json').write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    print('Prepared N7 image inputs:', output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--adapter-source', type=Path,
                        help='explicit adapter-only source overlay; engine bytes remain packaged')
    args = parser.parse_args()
    prepare(args.release.resolve(), args.output.resolve(), args.adapter_source)
