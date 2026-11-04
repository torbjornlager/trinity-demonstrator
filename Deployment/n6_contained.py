"""Launch the contained Linux service, then permanently drop presenter privileges."""
import ctypes
import json
import ipaddress
import os
from pathlib import Path
import secrets
import signal
import socket
import stat
import subprocess
import threading
from n6_egress import Broker


def validate_jail(destination):
    for path in [destination, *destination.rglob('*')]:
        info = path.lstat()
        if (info.st_uid != 0 or info.st_mode & 0o222
                or not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode))):
            raise RuntimeError('query filesystem must be immutable and root-owned')


def serve(server_class, root, owner_hash):
    if os.geteuid() != 0 or not hasattr(socket, 'SO_PEERCRED'):
        raise RuntimeError('contained N6 requires qualified Linux root launcher')
    status = dict(line.split(':', 1) for line in Path('/proc/self/status').read_text().splitlines() if ':' in line)
    expected = sum(1 << bit for bit in (5, 6, 7, 18))  # KILL, SETGID, SETUID, SYS_CHROOT only
    if int(status['CapEff'], 16) != expected or status['NoNewPrivs'].strip() != '1':
        raise RuntimeError('contained N6 requires the exact minimal launch capability set and no-new-privileges')
    if not os.statvfs('/').f_flag & os.ST_RDONLY:
        raise RuntimeError('contained N6 requires a read-only container root')
    temporary = Path('/tmp/n6')
    temporary.mkdir(mode=0o711)
    leases = temporary / 'leases'
    leases.mkdir(mode=0o755)
    jail = root / 'jail-template'
    validate_jail(jail)
    peers = {}
    for n in range(1, 6):
        hostname = f'n{n}.elfenbenstornet.se'
        address = socket.getaddrinfo(hostname, 443, socket.AF_INET, socket.SOCK_STREAM)[0][4][0]
        if not ipaddress.ip_address(address).is_global:
            raise RuntimeError('approved peer resolved to a non-public address')
        peers[hostname] = address
    broker = Broker('\0trinity-n6-egress', peers, leases)
    token = secrets.token_hex(32)
    token_file = temporary / 'controller.token'
    token_file.write_text(token + '\n')
    token_file.chmod(0o600)
    lifetime_read, lifetime_write = os.pipe2(os.O_CLOEXEC)
    environment = {k: os.environ[k] for k in ('LANG', 'LC_ALL', 'LC_CTYPE', 'TZ') if k in os.environ}
    controller = subprocess.Popen([
        '/app/isobase/isobase-node', '--port', '8081', '--auth-token-file', str(token_file),
        '--shared-db', str(root / 'shared_db.pl'), '--query-jail', str(jail),
        '--lease-dir', str(leases), '--parent-fd', str(lifetime_read),
        '--max-queries', '8', '--max-owner-queries', '4', '--max-budget-queries', '6',
        '--require-query-owner', '1', '--require-query-budget', '1',
        '--time-ms', '2000', '--idle-ms', '300000', '--memory-mb', '256', '--total-memory-mb', '512'],
        env=environment, pass_fds=(lifetime_read,), stdout=subprocess.PIPE, text=True)
    os.close(lifetime_read)
    try:
        announcement = controller.stdout.readline()
        if not announcement or json.loads(announcement).get('port') != 8081:
            raise RuntimeError('contained GNU controller failed startup validation')
        os.setgroups([])
        os.setgid(10001)
        os.setuid(10001)
        if os.getuid() != 10001 or os.geteuid() != 10001:
            raise RuntimeError('presenter privilege drop failed')
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.prctl(4, 0, 0, 0, 0):  # PR_SET_DUMPABLE
            raise RuntimeError('presenter dump protection failed')
        server = server_class(('0.0.0.0', 3060), controller, owner_hash, token)
        stopped = threading.Event()
        signal.signal(signal.SIGTERM, lambda *_: stopped.set())
        signal.signal(signal.SIGINT, lambda *_: stopped.set())
        threads = [threading.Thread(target=service.serve_forever, daemon=True) for service in (broker, server)]
        for thread in threads:
            thread.start()
        print('Contained GNU service ready; query workers have no IP sockets or controller credentials.', flush=True)
        while not stopped.wait(.25):
            if controller.poll() is not None:
                raise RuntimeError('contained GNU controller exited')
        server.shutdown()
        server.server_close()
        broker.shutdown()
        broker.server_close()
    finally:
        os.close(lifetime_write)  # Controller observes EOF and kills/reaps every query group.
        controller.wait(timeout=10)
