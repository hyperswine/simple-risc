import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import preset_manifest


PRESET = Path(__file__).with_name('preset.sh')


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

    def test_rom_identity_and_build_id_are_deterministic(self):
        inp_a = {'src/SimpleRisc.hs': '1111', 'boards/tangnano20k/bootrom/bootrom-sdram.hex': '2222'}
        inp_b = {'src/SimpleRisc.hs': '1111', 'boards/tangnano20k/bootrom/bootrom-sdram.hex': '3333'}
        id_a1 = preset_manifest.rom_identity(inp_a)
        id_a2 = preset_manifest.rom_identity(dict(reversed(list(inp_a.items()))))
        id_b = preset_manifest.rom_identity(inp_b)
        self.assertEqual(id_a1, id_a2)
        self.assertEqual(id_a1['protocol'], 'SRID1')
        self.assertEqual(id_a1['isa'], 'rv32imc')
        self.assertEqual(id_a1['cpu_mhz'], 48)
        self.assertEqual(id_a1['mem_mhz'], 48)
        self.assertEqual(id_a1['ram_bytes'], 8388608)
        self.assertEqual(id_a1['max_bytes'], 2097152)
        self.assertEqual(id_a1['capabilities'], 'PMXQVHTUICG')
        self.assertEqual(preset_manifest.CONFIG['cache_ways'], 1)
        self.assertEqual(preset_manifest.CONFIG['cache_line_bits'], 12)
        self.assertEqual(len(id_a1['build_id']), 16)
        self.assertNotEqual(id_a1['build_id'], id_b['build_id'])

    def test_preset_pins_validated_one_way_geometry(self):
        env = os.environ.copy()
        env['SDRAM_PRESET'] = 'fprisc-48'
        env.pop('SDRAM_CACHE_WAYS', None)
        result = subprocess.run(
            ['bash', '-c', 'source "$1"; printf "%s %s\\n" "$SDRAM_CACHE_WAYS" "$SDRAM_CACHE_LINE_BITS"',
             'bash', str(PRESET)],
            env=env, capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout.strip(), '1 12')

    def test_preset_rejects_conflicting_associativity(self):
        env = os.environ.copy()
        env.update(SDRAM_PRESET='fprisc-48', SDRAM_CACHE_WAYS='2')
        result = subprocess.run(['bash', '-c', 'source "$1"', 'bash', str(PRESET)],
                                env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('requires SDRAM_CACHE_WAYS=1', result.stderr)


if __name__ == '__main__':
    unittest.main()
