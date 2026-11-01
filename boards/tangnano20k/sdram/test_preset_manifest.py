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

    def test_preset_rejects_diagnostic_rom_override(self):
        env = os.environ.copy()
        env.update(SDRAM_PRESET='fprisc-48', SDRAM_ROM_FILE='/tmp/diagnostic.hex')
        result = subprocess.run(['bash', '-c', 'source "$1"', 'bash', str(PRESET)],
                                env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SDRAM_ROM_FILE is incompatible', result.stderr)


    def source_preset(self, **settings):
        env = {k: v for k, v in os.environ.items() if not k.startswith('SDRAM_')}
        env.update(settings)
        return subprocess.run(
            ['bash', '-c', 'source "$1"; for n in SDRAM_CPU_FREQ_MHZ SDRAM_FREQ_MHZ SDRAM_CACHE_WAYS '
             'SDRAM_CACHE_LINE_BITS SDRAM_PLACE_OPTION SDRAM_TARGET_MHZ SDRAM_MAP_OPTION SDRAM_ROUTE_OPTION '
             'SDRAM_ROUTE_MAXFAN; do printf "%s=%s\\n" "$n" "${!n:-}"; done', 'bash', str(PRESET)],
            env=env, capture_output=True, text=True)

    def test_preset_72_pins_its_clocks_geometry_and_options(self):
        result = self.source_preset(SDRAM_PRESET='fprisc-72')
        self.assertEqual(result.returncode, 0, result.stderr)
        settings = dict(line.split('=', 1) for line in result.stdout.split())
        self.assertEqual(settings, dict(SDRAM_CPU_FREQ_MHZ='72', SDRAM_FREQ_MHZ='48', SDRAM_CACHE_WAYS='2',
                                        SDRAM_CACHE_LINE_BITS='11', SDRAM_PLACE_OPTION='0',
                                        SDRAM_TARGET_MHZ='79', SDRAM_MAP_OPTION='3', SDRAM_ROUTE_OPTION='1',
                                        SDRAM_ROUTE_MAXFAN='8'))
        config = preset_manifest.PRESETS['fprisc-72']
        self.assertEqual((config['cpu_mhz'], config['memory_mhz'], config['cache_ways'], config['cache_line_bits'],
                          config['placement'], config['placer_target_mhz']), (72, 48, 2, 11, 0, 79))

    def test_preset_72_refuses_conflicts_and_what_if_constraints(self):
        for name, value, message in [('SDRAM_CPU_FREQ_MHZ', '96', 'requires SDRAM_CPU_FREQ_MHZ=72'),
                                     ('SDRAM_CACHE_WAYS', '1', 'requires SDRAM_CACHE_WAYS=2'),
                                     ('SDRAM_EXTRA_SDC', '/tmp/cut.sdc', 'SDRAM_EXTRA_SDC is incompatible')]:
            result = self.source_preset(SDRAM_PRESET='fprisc-72', **{name: value})
            self.assertNotEqual(result.returncode, 0, name)
            self.assertIn(message, result.stderr)

    def test_preset_48_still_refuses_build_options(self):
        result = self.source_preset(SDRAM_PRESET='fprisc-48', SDRAM_ROUTE_MAXFAN='8')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SDRAM_ROUTE_MAXFAN is incompatible', result.stderr)

    def test_unknown_preset_is_refused(self):
        result = self.source_preset(SDRAM_PRESET='fprisc-99')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unknown SDRAM_PRESET', result.stderr)

    def test_preset_72_identity_and_timing_gate_use_its_clocks(self):
        inp = {'src/SimpleRisc.hs': '1111'}
        identity = preset_manifest.rom_identity(inp, preset_manifest.CONFIG_72)
        self.assertEqual((identity['cpu_mhz'], identity['mem_mhz']), (72, 48))
        self.assertNotEqual(identity['build_id'], preset_manifest.rom_identity(inp)['build_id'])
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            (out / 'build-manifest.json').write_text(json.dumps(dict(preset='fprisc-72', ready=False, inputs=inp)))
            for name in ('impl/pnr/sdram_test.fs', 'impl/pnr/sdram_test.tr', 'pipeline_top.v', 'pll.v',
                         'clocks.sdc', 'build.tcl', 'rtl.v'):
                (out / name).parent.mkdir(parents=True, exist_ok=True)
                (out / name).write_text('x')
            with patch.dict(os.environ, SDRAM_PRESET='fprisc-72'), \
                    patch('sys.argv', ['preset_manifest.py', 'finish', temp, str(out / 'rtl.v')]), \
                    patch.object(preset_manifest, 'inputs', return_value=inp), \
                    patch.object(preset_manifest.subprocess, 'run') as gate:
                preset_manifest.main()
            command = gate.call_args.args[0]
            self.assertEqual(command[-4:], ['--freq-mhz', '72', '--memory-freq-mhz', '48'])
            report = json.loads((out / 'build-manifest.json').read_text())
            self.assertTrue(report['ready'])
            self.assertEqual(report['rom_identity']['cpu_mhz'], 72)

    def test_finish_refuses_a_manifest_from_the_other_preset(self):
        with tempfile.TemporaryDirectory() as temp:
            (Path(temp) / 'build-manifest.json').write_text(json.dumps(dict(preset='fprisc-48', ready=False, inputs={})))
            with patch.dict(os.environ, SDRAM_PRESET='fprisc-72'), \
                    patch('sys.argv', ['preset_manifest.py', 'finish', temp, 'unused.v']):
                with self.assertRaisesRegex(SystemExit, 'records fprisc-48'):
                    preset_manifest.main()


if __name__ == '__main__':
    unittest.main()
