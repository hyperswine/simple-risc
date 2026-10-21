import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import preset_manifest


class PresetManifest(unittest.TestCase):
    def test_failed_begin_invalidates_previous_success(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'build-manifest.json'
            path.write_text('{"ready": true}')
            with patch('sys.argv', ['preset_manifest.py', 'begin', temp]), \
                    patch.object(preset_manifest, 'inputs', side_effect=OSError('unreadable input')):
                with self.assertRaises(OSError):
                    preset_manifest.main()
            self.assertFalse(json.loads(path.read_text())['ready'])

    def test_changed_source_cannot_finish(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'build-manifest.json'
            path.write_text(json.dumps(dict(ready=False, inputs={'core': 'before'})))
            with patch('sys.argv', ['preset_manifest.py', 'finish', temp, 'unused.v']), \
                    patch.object(preset_manifest, 'inputs', return_value={'core': 'after'}):
                with self.assertRaisesRegex(SystemExit, 'inputs changed'):
                    preset_manifest.main()
            self.assertFalse(json.loads(path.read_text())['ready'])


if __name__ == '__main__':
    unittest.main()
