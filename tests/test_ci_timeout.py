"""Exercise real timeout cleanup without starting a node or touching runtimes."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
import ci_timeout


class CITimeout(unittest.TestCase):
    def test_terminating_watchdog_also_kills_its_detached_child(self):
        with tempfile.TemporaryDirectory() as d:
            marker=Path(d)/'child.pid'
            command=('import os,signal,time;from pathlib import Path;'
                     'signal.signal(signal.SIGTERM,signal.SIG_IGN);'
                     'Path('+repr(str(marker))+').write_text(str(os.getpid()));time.sleep(30)')
            watchdog=subprocess.Popen([sys.executable,str(Path(ci_timeout.__file__)),
                                       '30','--',sys.executable,'-c',command])
            try:
                deadline=time.monotonic()+5
                while not marker.exists() and time.monotonic()<deadline:
                    time.sleep(0.02)
                self.assertTrue(marker.exists(),'child did not start')
                pid=int(marker.read_text())
                watchdog.terminate()
                self.assertEqual(watchdog.wait(timeout=3),128+signal.SIGTERM)
                status=subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True)
                self.assertTrue(status.returncode!=0 or status.stdout.strip().startswith('Z'),status.stdout)
            finally:
                if watchdog.poll() is None:
                    watchdog.kill()
                    watchdog.wait()
                if marker.exists():
                    try:os.kill(int(marker.read_text()),signal.SIGKILL)
                    except ProcessLookupError:pass

    def test_success_and_original_failure_status(self):
        for code in (0,7):
            self.assertEqual(ci_timeout.run([sys.executable,'-c',f'raise SystemExit({code})'],2),code)

    def test_resistant_command_is_killed(self):
        self.assertEqual(ci_timeout.run([sys.executable,'-c',
            'import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(30)'],
            0.3,grace=0.1),124)

    def test_child_is_killed_even_when_group_leader_exits_on_term(self):
        with tempfile.TemporaryDirectory() as d:
            marker=Path(d)/'child.pid'
            child=('import os,signal,time;from pathlib import Path;'
                   'signal.signal(signal.SIGTERM,signal.SIG_IGN);'
                   'Path('+repr(str(marker))+').write_text(str(os.getpid()));time.sleep(30)')
            leader=('import subprocess,sys,time;'
                    'subprocess.Popen([sys.executable,"-c",'+repr(child)+']);time.sleep(30)')
            pid=None
            try:
                self.assertEqual(ci_timeout.run([sys.executable,'-c',leader],2,grace=0.1),124)
                pid=int(marker.read_text())
                # An unreaped zombie has terminated and cannot contaminate a tier.
                status=subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True)
                self.assertTrue(status.returncode!=0 or status.stdout.strip().startswith('Z'),status.stdout)
            finally:
                if pid is None and marker.exists():pid=int(marker.read_text())
                if pid:
                    try:os.kill(pid,signal.SIGKILL)
                    except ProcessLookupError:pass


if __name__=='__main__':unittest.main()
