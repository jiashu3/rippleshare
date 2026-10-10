"""RippleShare's ephemeral SSH helper. Python 3.8+, standard library only.

Executed through SSH stdin or `python3 -c`; never installed as a service.
Request and response bodies are JSON. stdout is reserved for the protocol.
"""
import base64
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import ctypes


def move_exclusive(source, destination):
    """Publish atomically without ever replacing an existing destination."""
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform.startswith('linux'):
        result = libc.renameat2(-100, os.fsencode(source), -100, os.fsencode(destination), 1)
    elif sys.platform == 'darwin':
        result = libc.renamex_np(os.fsencode(source), os.fsencode(destination), 4)
    else:
        raise RuntimeError('Atomic publishing currently supports Linux and macOS servers')
    if result != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), destination)


def absolute(value):
    if not isinstance(value, str) or not value.startswith('/') or '\0' in value:
        raise ValueError('An absolute path is required')
    return os.path.normpath(value)


def leaf(value):
    if not isinstance(value, str) or value in ('', '.', '..') or '/' in value or '\0' in value:
        raise ValueError('Invalid file name')
    return value


def exists(path):
    return os.path.lexists(path)


def stage_path(parent, token):
    parent = absolute(parent)
    if not re.fullmatch(r'[a-fA-F0-9-]{36}', token):
        raise ValueError('Invalid task identifier')
    return os.path.join(parent, '.rippleshare-' + token.lower())


def checked_stage(request):
    path = stage_path(request['parent'], request['token'])
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError('Unsafe staging directory')
    marker = os.path.join(path, 'owner.json')
    if os.path.islink(marker):
        raise ValueError('Unsafe staging marker')
    with open(marker, encoding='utf-8') as f:
        if json.load(f) != {'token': request['token'].lower(), 'name': leaf(request['name'])}:
            raise ValueError('Staging directory belongs to another task')
    payload = os.path.join(path, 'payload')
    if os.path.islink(payload) or not os.path.isdir(payload):
        raise ValueError('Unsafe payload directory')
    return path


def check_tree(path):
    """Reject devices/FIFOs/sockets; preserve links without following them."""
    info = os.lstat(path)
    if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode)):
        raise ValueError('Special files are not supported: ' + path)
    size = info.st_size if stat.S_ISREG(info.st_mode) else 0
    count = 1
    if stat.S_ISDIR(info.st_mode):
        with os.scandir(path) as it:
            for child in it:
                child_count, child_size = check_tree(child.path)
                count += child_count
                size += child_size
    return count, size


def dispatch(r):
    op = r['op']
    if op == 'probe':
        rsync = shutil.which('rsync')
        if not rsync:
            raise RuntimeError('This server needs rsync 3 or newer')
        version = subprocess.check_output([rsync, '--version'], text=True).splitlines()[0]
        if not re.search(r'version\s+[3-9]\.', version):
            raise RuntimeError('This server needs rsync 3 or newer: ' + version)
        return {'home': os.path.expanduser('~'), 'rsync': version, 'python': sys.version.split()[0]}
    if op == 'list':
        path = absolute(r['path'])
        result = []
        with os.scandir(path) as it:
            for entry in it:
                try:
                    s = entry.stat(follow_symlinks=False)
                    result.append({'name': entry.name, 'path': entry.path,
                                   'isDirectory': stat.S_ISDIR(s.st_mode),
                                   'isSymlink': stat.S_ISLNK(s.st_mode),
                                   'size': s.st_size, 'modified': s.st_mtime})
                except FileNotFoundError:
                    continue
        return {'path': path, 'entries': result}
    if op == 'mkdir':
        path = os.path.join(absolute(r['parent']), leaf(r['name']))
        os.mkdir(path)
        return {'path': path}
    if op == 'rename':
        source = absolute(r['path'])
        target = os.path.join(os.path.dirname(source), leaf(r['name']))
        if exists(target):
            raise FileExistsError('Destination already exists')
        move_exclusive(source, target)
        return {'path': target}
    if op == 'inspect':
        path = absolute(r['path'])
        if path == '/':
            raise ValueError('Select a file or folder, not the entire filesystem')
        count, size = check_tree(path)
        return {'count': count, 'bytes': size}
    if op == 'stage':
        parent = absolute(r['parent'])
        name = leaf(r['name'])
        if exists(os.path.join(parent, name)):
            raise FileExistsError('Destination already exists. Choose another folder or name.')
        path = stage_path(parent, r['token'])
        if not exists(path):
            os.mkdir(path, 0o700)
            with open(os.path.join(path, 'owner.json'), 'x', encoding='utf-8') as f:
                json.dump({'token': r['token'].lower(), 'name': name}, f)
            os.mkdir(os.path.join(path, 'payload'), 0o700)
        checked_stage(r)
        free = shutil.disk_usage(parent).free
        if free < int(r.get('requiredBytes', 0)):
            raise OSError('Not enough free disk space at destination')
        return {'path': os.path.join(path, 'payload'), 'freeBytes': free}
    if op == 'finish':
        path = checked_stage(r)
        payload = os.path.join(path, 'payload')
        names = os.listdir(payload)
        if names != [leaf(r['name'])]:
            raise ValueError('Unexpected staging contents')
        source = os.path.join(payload, r['name'])
        target = os.path.join(absolute(r['parent']), r['name'])
        if exists(target):
            raise FileExistsError('Destination appeared during transfer; staged files retained')
        move_exclusive(source, target)
        os.rmdir(payload)
        os.unlink(os.path.join(path, 'owner.json'))
        os.rmdir(path)
        return {'path': target}
    if op == 'discard':
        path = stage_path(r['parent'], r['token'])
        if exists(path):
            checked_stage(r)
            shutil.rmtree(path)
        return {'removed': True}
    raise ValueError('Unknown operation')


def main():
    try:
        request = json.loads(base64.b64decode(sys.argv[1], validate=True))
        print(json.dumps({'ok': True, 'value': dispatch(request)}, ensure_ascii=True))
    except Exception as e:
        print(json.dumps({'ok': False, 'error': str(e)}, ensure_ascii=True))
        sys.exit(1)


if __name__ == '__main__':
    main()
