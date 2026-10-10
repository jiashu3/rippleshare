import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import uuid
import sys

sys.dont_write_bytecode = True

HELPER = Path(__file__).resolve().parents[1] / 'Sources/RippleCore/Resources/remote.py'
spec = importlib.util.spec_from_file_location('remote', HELPER)
remote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote)


class RemoteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='rippleshare-test-')
        self.root = Path(self.temp.name)
        self.r = {'parent': str(self.root), 'name': "中文 ' folder", 'token': str(uuid.uuid4())}

    def tearDown(self):
        self.temp.cleanup()

    def call(self, op, **kwargs):
        return remote.dispatch(dict(self.r, op=op, **kwargs))

    def test_list_hidden_unicode_and_symlink(self):
        (self.root / '.env').write_text('fixture, not credentials')
        (self.root / '中文 folder').mkdir()
        (self.root / 'link').symlink_to('/does/not/exist')
        result = self.call('list', path=str(self.root))
        entries = {e['name']: e for e in result['entries']}
        self.assertEqual(len(entries), 3)
        self.assertTrue(entries['link']['isSymlink'])
        self.assertTrue(entries['中文 folder']['isDirectory'])

    def test_invalid_paths(self):
        for path in ['relative', 'x\0', None]:
            with self.assertRaises(ValueError): remote.absolute(path)
        for name in ['', '.', '..', 'a/b', 'a\0b']:
            with self.assertRaises(ValueError): remote.leaf(name)

    def test_stage_resume_finish(self):
        stage = Path(self.call('stage')['path'])
        self.assertEqual(self.call('stage')['path'], str(stage))
        (stage / self.r['name']).mkdir()
        (stage / self.r['name'] / '.hidden').write_text('keep')
        self.call('finish')
        self.assertEqual((self.root / self.r['name'] / '.hidden').read_text(), 'keep')
        self.assertFalse(stage.parent.exists())

    def test_finish_never_replaces_existing_empty_folder(self):
        stage = Path(self.call('stage')['path'])
        (stage / self.r['name']).mkdir()
        target = self.root / self.r['name']
        target.mkdir()
        with self.assertRaises(FileExistsError): self.call('finish')
        self.assertTrue((stage / self.r['name']).exists())

    def test_atomic_move_no_clobber_even_without_precheck(self):
        source = self.root / 'source'; source.mkdir()
        target = self.root / 'target'; target.mkdir()
        with self.assertRaises(FileExistsError): remote.move_exclusive(str(source), str(target))
        self.assertTrue(source.is_dir())

    def test_stage_rejects_symlink_and_preserves_target(self):
        victim = self.root / 'victim'; victim.mkdir()
        sentinel = victim / 'keep'; sentinel.write_text('safe')
        Path(remote.stage_path(str(self.root), self.r['token'])).symlink_to(victim)
        with self.assertRaises(ValueError): self.call('stage')
        with self.assertRaises(ValueError): self.call('discard')
        self.assertEqual(sentinel.read_text(), 'safe')

    def test_payload_symlink_rejected(self):
        stage = Path(self.call('stage')['path'])
        stage.rmdir(); stage.symlink_to(self.root)
        with self.assertRaises(ValueError): self.call('finish')
        with self.assertRaises(ValueError): self.call('discard')

    def test_stage_wrong_owner_marker(self):
        stage = Path(self.call('stage')['path'])
        (stage.parent / 'owner.json').write_text('{}')
        with self.assertRaises(ValueError): self.call('discard')

    def test_discard_removes_only_owned_stage(self):
        (self.root / 'keep').write_text('safe')
        stage = Path(self.call('stage')['path'])
        (stage / 'partial').write_text('partial')
        self.call('discard')
        self.assertFalse(stage.parent.exists())
        self.assertTrue((self.root / 'keep').exists())
        self.call('discard')

    def test_special_file_rejected(self):
        os.mkfifo(self.root / 'fifo')
        with self.assertRaises(ValueError): self.call('inspect', path=str(self.root))

    def test_inspection_does_not_follow_links(self):
        (self.root / 'file').write_bytes(b'12345')
        (self.root / 'loop').symlink_to(self.root)
        result = self.call('inspect', path=str(self.root))
        self.assertEqual(result, {'count': 3, 'bytes': 5})

    def test_no_space(self):
        with self.assertRaises(OSError): self.call('stage', requiredBytes=2**100)

    def test_rename_conflict_and_unusual_name(self):
        (self.root / 'source').write_text('hello')
        (self.root / 'exists').write_text('keep')
        with self.assertRaises(FileExistsError): self.call('rename', path=str(self.root / 'source'), name='exists')
        name = "中文 ; $(no-command) ' \n.txt"
        self.call('rename', path=str(self.root / 'source'), name=name)
        self.assertEqual((self.root / name).read_text(), 'hello')


@unittest.skipUnless(shutil.which('rsync'), 'rsync required')
class RsyncTests(unittest.TestCase):
    def test_directory_roundtrip_and_checksum_detects_same_size_mutation(self):
        with tempfile.TemporaryDirectory(prefix='rippleshare-rsync-') as tmp:
            root = Path(tmp); source = root / "project ' 中文"; target = root / 'target'
            source.mkdir(); target.mkdir()
            (source / '.hidden').write_bytes(b'abcd')
            (source / 'empty').mkdir()
            (source / 'link').symlink_to('.hidden')
            for i in range(180): (source / f'file-{i}').write_text(f'item {i}')
            common = ['rsync', '-rltp', '--checksum', '--protect-args']
            subprocess.run(common + ['--partial', '--delete-delay', '--', str(source), str(target) + '/'], check=True, capture_output=True)
            verify = common + ['--dry-run', '--delete', '--itemize-changes', '--out-format=%i %n%L', '--', str(source), str(target) + '/']
            self.assertEqual(subprocess.check_output(verify), b'')
            self.assertTrue((target / source.name / 'empty').is_dir())
            self.assertTrue((target / source.name / 'link').is_symlink())
            dest = target / source.name / '.hidden'
            stamp = dest.stat().st_mtime_ns
            dest.write_bytes(b'xxxx'); os.utime(dest, ns=(stamp, stamp))
            self.assertNotEqual(subprocess.check_output(verify), b'')
            subprocess.run(common + ['--partial', '--delete-delay', '--', str(source), str(target) + '/'], check=True, capture_output=True)
            self.assertEqual(subprocess.check_output(verify), b'')
            (source / 'file-1').unlink()
            self.assertIn(b'deleting', subprocess.check_output(verify))


if __name__ == '__main__':
    unittest.main()
