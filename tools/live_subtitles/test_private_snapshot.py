import gzip
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from service import snapshot


class PrivateSnapshotTests(unittest.TestCase):
    def test_backend_uses_local_verified_snapshots_after_anonymous_access_closes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)/'channel-catalog'
            (root/'snapshots').mkdir(parents=True)
            data = {'schemaVersion': 1, 'version': 'test', 'channels': []}
            body = gzip.compress(json.dumps(data).encode())
            digest = hashlib.sha256(body).hexdigest()
            (root/'manifest.json').write_text(json.dumps({'sha256': digest}))
            (root/'snapshots'/(digest+'.json.gz')).write_bytes(body)
            with patch.dict(os.environ, BOBTV_SUBTITLE_SNAPSHOT_ROOT=directory), \
                    patch('service.public_read', side_effect=AssertionError('unexpected network')):
                self.assertEqual(snapshot('channel-catalog'), data)
                (root/'snapshots'/(digest+'.json.gz')).write_bytes(b'changed')
                with self.assertRaisesRegex(ValueError, 'local_snapshot_checksum'):
                    snapshot('channel-catalog')


if __name__ == '__main__':
    unittest.main()
