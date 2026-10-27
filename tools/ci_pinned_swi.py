#!/usr/bin/env python3
"""Run the pinned CI boundary locally or in Actions; never fetch or install."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
from pinned_swi import ROOT, PIN, validate
from setup_swi import check


def checkout_outputs():
    pin = json.loads(PIN.read_text())
    match = re.fullmatch(r'https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\.git', pin['repository'])
    if not match or not re.fullmatch(r'[0-9a-f]{40}', pin['revision']):
        raise ValueError('dependency manifest must specify a GitHub repository and full commit SHA')
    return dict(repository=match[1], revision=pin['revision'])


def plan(native, wasm, swipl):
    # Native tiers run independently: do not preload the complete node into
    # processes whose assertions require higher layers to be absent.
    rows = [('origin-audit', ROOT,
             [swipl, '-f', 'none', '-q', '-s', str(ROOT/'load.pl'),
              '-g',
              'pinned_swi_bootstrap:check_origins,forall(module_property(M,file(F)),format("~q ~q~n",[M,F]))',
              '-t', 'halt'])]
    for tier in ['LINT', 'T0', 'T1_NATIVE', 'T2', 'T3_NATIVE', 'T4_NATIVE', 'T5',
                 'T1_INTEGRATION', 'T3_INTEGRATION', 'T4_INTEGRATION']:
        rows.append((tier, native, ['bash', 'tools/test.sh', tier]))
    for tier in ['LINT', 'T0', 'T1', 'T2', 'T3', 'T4', 'T5', 'SERVICE_TEXT', 'MODEL', 'MODEL_SXML', 'JEV']:
        rows.append(('demonstrator-'+tier, ROOT, ['bash', 'tools/test.sh', tier]))
    rows += [
        ('default-startup-regressions', ROOT, [sys.executable, 'tests/test_default_swi_startup.py']),
        ('pin-regressions', ROOT, [sys.executable, 'tests/test_pinned_swi_dependency.py']),
        ('ci-runner-regressions', ROOT, [sys.executable, 'tests/test_ci_pinned_swi.py']),
        ('packaging-regressions', ROOT, [sys.executable, 'tests/test_swi_extraction_tools.py']),
        ('watchdog-regressions', ROOT, [sys.executable, 'tests/test_ci_timeout.py']),
        ('fetch-regressions', ROOT, [sys.executable, 'tests/test_fetch_swi.py']),
        ('browser-equivalence', ROOT, [sys.executable, 'tools/check_statechart_wasm_equivalence.py',
                                     '--native-root', str(native), '--wasm-dir', str(wasm)]),
        ('WASM', ROOT, ['bash', 'tools/test.sh', 'WASM']),
    ]
    return rows


def run_one(label, cwd, command, env, output, timeout=360):
    start = time.monotonic()
    with (output/(label+'.log')).open('w') as log:
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            code = 124
    return dict(label=label, cwd=str(cwd), command=command, exit_code=code,
                seconds=round(time.monotonic()-start, 3), watchdog_seconds=timeout)


def run_checks(rows, env, output):
    results = []
    for label, cwd, command in rows:
        print('START', label, flush=True)
        results.append(run_one(label, cwd, command, env, output))
        (output/'results.json').write_text(json.dumps(results, indent=2)+'\n')
        print('DONE', label, results[-1]['exit_code'], flush=True)
    return int(any(row['exit_code'] != 0 for row in results))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--github-outputs', type=Path)
    parser.add_argument('--native-root', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--swipl', default=os.environ.get('SWIPL', 'swipl'))
    args = parser.parse_args()
    try:
        outputs = checkout_outputs()
        if args.github_outputs:
            with args.github_outputs.open('a') as out:
                for key, value in outputs.items():
                    out.write(f'{key}={value}\n')
            return 0
        if args.native_root is None or args.output is None:
            raise ValueError('--native-root and --output are required')
        native = args.native_root.resolve(strict=True)
        record = validate(native)  # fail before executing any test on a wrong pin
        output = args.output.resolve()
        output.mkdir(parents=True, exist_ok=False)  # never replace prior evidence/setup
        swipl = shutil.which(args.swipl)
        if not swipl:
            raise ValueError('SWI executable not found: '+args.swipl)
        env = dict(os.environ)
        for key in ['SWI_HOME_DIR', 'SWIPL_HOME_DIR', 'WP_CONFIG_FILE',
                    'TRINITY_PINNED_SWI_ROOT', 'WP_ASSET_ROOT', 'WP_WASM_SOURCE_DIR']:
            env.pop(key, None)
        state = output/'native-swi.json'
        with (output/'setup.log').open('w') as setup_log:
            subprocess.run([sys.executable, str(ROOT/'tools/setup_swi.py'), '--native-root',
                            str(native), '--state-file', str(state)], check=True, env=env,
                           stdout=setup_log)
        setup = check(state)
        env.update(WP_NATIVE_MODE='pinned', WP_NATIVE_STATE=str(state),
                   WP_ASSET_ROOT=str(ROOT), WP_WASM_SOURCE_DIR=setup['wasm_root'],
                   PINNED_SWI_TEST_ROOT=str(native), STARTUP_TEST_SWIPL=swipl, SWIPL=swipl)
        record.update(swipl=swipl, swipl_version=subprocess.check_output([swipl, '--version'], text=True).strip(),
                      demonstrator_revision=subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip())
        (output/'provenance.json').write_text(json.dumps(record, indent=2)+'\n')
        return run_checks(plan(native, Path(setup['wasm_root']), swipl), env, output)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print('pinned SWI CI:', error, file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
