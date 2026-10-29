"""Exercise structural evidence extraction against committed vendor reports."""
from collections import Counter
import gzip
import json
from pathlib import Path
import tempfile
import unittest

from analyze_implementation import analyze, setup_details, attribute_fields
from run_perf import require_observations

ROOT = Path(__file__).resolve().parents[3]
EVIDENCE = ROOT / 'docs/evidence/2026-10-28-control-area/mru-ram'


class StructuralEvidenceTests(unittest.TestCase):
    def test_physical_endpoint_pins_are_preserved(self):
        paths = setup_details((EVIDENCE / 'sdram_test.tr').read_text())
        self.assertEqual(len(paths), 25)
        self.assertEqual(Counter(p['endpoint_pin'] for p in paths)['CE'], 14)
        self.assertEqual(paths[0]['endpoint'], 'cache/entry_mru_s0/D')
        self.assertEqual(paths[0]['route_ns'], 12.917)
        self.assertTrue(all(p['hops'][0]['kind'] == 'tC2Q' for p in paths))
        self.assertTrue(any(p['endpoint_pin'].startswith('B[') for p in paths))

    def test_netlist_enables_and_fractional_dsp_cost(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            netlist = tmp / 'netlist.v'
            netlist.write_bytes(gzip.decompress((EVIDENCE / 'sdram_test.vg.gz').read_bytes()))
            utilization = tmp / 'utilization.txt'
            text = (EVIDENCE / 'sdram_test.rpt.txt').read_text()
            # Gowin reports half-DSP use after the multiplier restructuring.
            import re
            text, count = re.subn(r'(DSP\s*\|\s*)3/24', r'\g<1>3.5/24', text)
            self.assertEqual(count, 1)
            utilization.write_text(text)
            report = analyze(netlist, EVIDENCE / 'sdram_test.tr', utilization)
            self.assertEqual(report['resources']['DSP']['used'], 3.5)
            enables = report['synthesized_modules']['sdram_pipeline_risc']['clock_enable_nets']
            self.assertGreater(sum(e['register_loads'] for e in enables), 1000)
            self.assertTrue(report['detailed_setup_paths'][0]['hops'][-1]['cell'])

    def test_missing_data_statistics_are_refused(self):
        text = (EVIDENCE / 'sdram_test.tr').read_text()
        with self.assertRaisesRegex(ValueError, 'statistics'):
            setup_details(text.replace('Arrival Data Path Delay:', 'Removed statistics:'))

    def test_ordinary_top_cannot_silently_supply_observations(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'top.v'
            path.write_text('module top(output clk); endmodule\n')
            with self.assertRaisesRegex(ValueError, 'missing observation ports'):
                require_observations([path])

    def test_source_attribution_requires_matching_generated_width(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            generated, layout = tmp / 'cpu.v', tmp / 'layout.json'
            generated.write_text('reg [31:0] payload = 0;\n')
            layout.write_text(json.dumps([dict(type='Example', bits=32,
                fields=[dict(name='control', low=0, high=0), dict(name='data', low=1, high=31)])]))
            hop = dict(cell=dict(ports=dict(Q='payload[0]')))
            report = dict(detailed_setup_paths=[dict(hops=[hop, hop])])
            attribute_fields(report, generated, layout, ['payload=Example'])
            self.assertEqual(report['detailed_setup_paths'][0]['source_field']['field'], 'control')
            generated.write_text('reg [30:0] payload = 0;\n')
            with self.assertRaisesRegex(ValueError, 'width mismatch'):
                attribute_fields(report, generated, layout, ['payload=Example'])


if __name__ == '__main__':
    unittest.main()
