import unittest
from copy import deepcopy
from itertools import product
from run_perf import parse_metrics
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
