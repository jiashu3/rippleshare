"""Opt-in Linux loopback integration test; creates only temporary test data.

Run as a user allowed to start a test sshd (CI: sudo python3 tests/ssh_integration.py).
Never reads or modifies the user's SSH keys, config, known_hosts, or production files.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import pwd
import shlex
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import uuid

SCRIPT = (Path(__file__).resolve().parents[1] / 'Sources/RippleCore/Resources/remote.py').read_text()


def run():
    with tempfile.TemporaryDirectory(prefix='rippleshare-ssh-') as tmp:
        root = Path(tmp)
        for name in ('host', 'client'):
            subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(root / name)], check=True)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
        username = pwd.getpwuid(os.getuid()).pw_name
        config = root / 'sshd_config'
        config.write_text(f'''ListenAddress 127.0.0.1
Port {port}
HostKey {root / 'host'}
PidFile {root / 'sshd.pid'}
AuthorizedKeysFile {root / 'client.pub'}
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
UsePAM no
AllowUsers {username}
LogLevel ERROR
''')
        log = open(root / 'sshd.log', 'w+')
        daemon = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(config)], stdout=log, stderr=log)
        try:
            for _ in range(60):
                if daemon.poll() is not None:
                    log.seek(0); raise RuntimeError(log.read())
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=0.1): break
                except OSError: time.sleep(0.1)
            key = (root / 'host.pub').read_text().split()
            known = root / 'known_hosts'
            known.write_text(f'[127.0.0.1]:{port} {key[0]} {key[1]}\n')
            ssh = ['/usr/bin/ssh', '-F', '/dev/null', '-T', '-p', str(port), '-i', str(root / 'client'),
                   '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes',
                   '-o', f'UserKnownHostsFile={known}', '-o', 'GlobalKnownHostsFile=/dev/null']
            destination = f'{username}@127.0.0.1'

            def request(value):
                encoded = base64.b64encode(json.dumps(value).encode()).decode()
                result = subprocess.run(ssh + [destination, 'python3 -c ' + shlex.quote(SCRIPT) + ' ' + shlex.quote(encoded)],
                                        text=True, capture_output=True, timeout=60)
                if result.returncode: raise RuntimeError(result.stdout + result.stderr)
                reply = json.loads(result.stdout)
                assert reply['ok'], reply
                return reply['value']

            print('SSH helper probe:', request({'op': 'probe'}), flush=True)
            source = root / "project ' 中文 $(literal)"; source.mkdir()
            (source / '.hidden').write_bytes(b'keep hidden')
            (source / 'empty').mkdir()
            (source / 'link').symlink_to('.hidden')
            (source / 'large.bin').write_bytes(os.urandom(8 * 1024 * 1024))
            for i in range(300): (source / f'file-{i}.txt').write_text(f'fixture {i}')
            target = root / 'remote destination'; target.mkdir()
            task = {'parent': str(target), 'name': source.name, 'token': str(uuid.uuid4())}
            payload = request(dict(task, op='stage'))['path']
            common = ['rsync', '-rltp', '--checksum', '--protect-args', '--timeout=10', '--rsh=' + shlex.join(ssh)]
            ends = ['--', str(source), destination + ':' + payload + '/']
            partial = '--partial-dir=.rippleshare-partial-' + task['token']
            process = subprocess.Popen(common + ['--partial', partial, '--delete-delay', '--bwlimit=512'] + ends,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            time.sleep(2)
            assert process.poll() is None, 'transfer completed before cancellation could be tested'
            os.killpg(process.pid, signal.SIGTERM); process.wait(timeout=15)
            time.sleep(0.2)
            assert not (target / source.name).exists(), 'unfinished destination exposed'
            assert list(Path(payload).rglob('.rippleshare-partial-*')), 'no retained partial data'
            subprocess.run(common + ['--partial', partial, '--delete-delay'] + ends, check=True, capture_output=True, timeout=60)
            verify = common + ['--dry-run', '--delete', '--itemize-changes', '--out-format=%i %n%L'] + ends
            assert subprocess.check_output(verify, timeout=60) == b''
            request(dict(task, op='finish'))
            final = target / source.name
            assert final.is_dir() and not Path(payload).parent.exists()
            assert hashlib.sha256((source / 'large.bin').read_bytes()).digest() == hashlib.sha256((final / 'large.bin').read_bytes()).digest()
            assert (final / 'link').is_symlink() and (final / 'empty').is_dir()
            downloads = root / 'downloads'; downloads.mkdir()
            subprocess.run(common + ['--partial', '--', destination + ':' + str(final), str(downloads) + '/'], check=True, capture_output=True, timeout=60)
            assert hashlib.sha256((source / 'large.bin').read_bytes()).digest() == hashlib.sha256((downloads / source.name / 'large.bin').read_bytes()).digest()
            assert len(list(final.iterdir())) == len(list((downloads / source.name).iterdir()))
            print('PASS: SSH upload, interrupted transfer, retained partial data, retry, checksum verification, atomic publish, download; 300 small files + 8 MiB file + symlinks + hidden/empty entries.', flush=True)
        finally:
            daemon.terminate()
            try: daemon.wait(timeout=5)
            except subprocess.TimeoutExpired: daemon.kill(); daemon.wait()
            log.close()


if __name__ == '__main__':
    run()
