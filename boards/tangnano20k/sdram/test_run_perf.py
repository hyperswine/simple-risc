import unittest
from copy import deepcopy
from itertools import product
from run_perf import parse_metrics, stall_breakdown, SLOT_CAUSES
from benchmark_matrix import check_controls


class PerformanceGate(unittest.TestCase):
    output = ('BEGIN\nanswer\nFPR EXIT 0\n'
              'PERF cycles=100 held=10 fills=3 code_fills=2 held_read_miss=8 held_write_full=2\n'
              'PERF window_cycles=80 window_held=9 window_fills=2 window_writes=4\n')

    def test_accepts_complete_bounded_window(self):
        self.assertEqual(parse_metrics(self.output, 'BEGIN', 'FPR EXIT 0')['window_cycles'], 80)

    def test_rejects_limits_missing_markers_duplicates_and_invalid_counters(self):
        for text in [self.output.replace('BEGIN\n', ''), self.output.replace('FPR EXIT 0', 'FPR EXIT 1'),
                     self.output + 'PERF LIMIT reached\n', self.output + 'FPR EXIT 0\n',
                     self.output.replace('window_cycles=80', 'window_cycles=0'),
                     self.output.replace('window_held=9', 'window_held=90'),
                     self.output + 'PERF cycles=10\n', self.output.replace('code_fills=2', '')]:
            with self.assertRaises(ValueError):
                parse_metrics(text, 'BEGIN', 'FPR EXIT 0')


class StallBreakdown(unittest.TestCase):
    def metrics(self):
        values = {key: 0 for key, _ in SLOT_CAUSES}
        values.update(slot_issue=50, slot_load_wait=12, slot_frontend_refill=9, fetch_port_blocked=7)
        values.update(window_cycles=80, window_held=9, window_pipeline_commits=45)
        return values

    def test_causes_and_holds_cover_every_cycle(self):
        rows = {key: (value, percent) for key, _, value, percent in stall_breakdown(self.metrics())}
        self.assertEqual(rows['slot_issue'], (50, 62.5))
        self.assertAlmostEqual(sum(percent for _, percent in rows.values()), 100.0)

    def test_rejects_gaps_double_counting_and_missing_counters(self):
        for change in [dict(slot_issue=49), dict(slot_hazard=1), dict(window_held=10)]:
            with self.assertRaises(ValueError):
                stall_breakdown({**self.metrics(), **change})
        missing = self.metrics()
        del missing['slot_other']
        with self.assertRaises(ValueError):
            stall_breakdown(missing)


class MatrixControls(unittest.TestCase):
    def cases(self):
        return [dict(predictor=predictor, ways=ways, bridge=bridge, configuration=dict(
            cpu_mhz=72, mem_mhz=54, cdc=True, profile_cpu=True, write_update=1,
            ways=ways, line_bits=12 if ways == 1 else 11, image_sha256='fixed image',
            elf_sha256='fixed elf', generated={predictor: 'fixed generated CPU'},
            inputs={f'/experiment/bridge-{bridge}.v': bridge, '/source/pipeline_cache.v': 'fixed cache'}))
            for predictor, ways, bridge in product(('off', 'on'), (1, 2), ('old', 'new'))]

    def test_accepts_only_controlled_matrix(self):
        check_controls(self.cases())
        for key, value in [('cpu_mhz', 48), ('line_bits', 10), ('image_sha256', 'another image'),
                           ('profile_abi', 'different counter definitions'),
                           ('generated', {'off': 'changed CPU'}),
                           ('inputs', {'/experiment/bridge-old.v': 'old', '/source/pipeline_cache.v': 'changed cache'})]:
            cases = deepcopy(self.cases())
            cases[0]['configuration'][key] = value
            with self.assertRaises(AssertionError):
                check_controls(cases)
        with self.assertRaises(AssertionError):
            check_controls(self.cases()[:-1])


if __name__ == '__main__':
    unittest.main()
