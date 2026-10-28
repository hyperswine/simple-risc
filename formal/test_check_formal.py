"""The formal gate must attribute every result and reject swapped controls."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

from check_formal import validate_searches


def search(name, result):
    return f'search in TEST : {name} =>* S such that bad(S) .\n{result}\nstates: 2\n'


class FormalGate(unittest.TestCase):
    def test_missing_maude_invalidates_previous_success(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            (out / 'results.json').write_text('{"complete": true}')
            result = subprocess.run([sys.executable, str(Path(__file__).with_name('check_formal.py')),
                                     '--out', temp], env={**os.environ, 'PATH': ''},
                                    capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            report = json.loads((out / 'results.json').read_text())
            self.assertFalse(report['complete'])
            self.assertIn('Maude is required', report['error'])

    def test_rejects_swapped_outcomes_with_identical_totals(self):
        expected = [('good', 'safe'), ('bad', 'counterexample')]
        good = search('good', 'No solution.') + search('bad', 'Solution 1 (state 1)')
        self.assertEqual(len(validate_searches(good, expected)), 2)
        swapped = search('good', 'Solution 1 (state 1)') + search('bad', 'No solution.')
        with self.assertRaisesRegex(AssertionError, 'good: expected safe'):
            validate_searches(swapped, expected)

    def test_rejects_missing_reordered_warning_and_incomplete_searches(self):
        expected = [('good', 'safe'), ('bad', 'counterexample')]
        good = search('good', 'No solution.')
        bad = search('bad', 'Solution 1 (state 1)')
        for output in (good, bad + good, good + bad + '\nWarning: parse failure',
                       good + search('bad', ''), good + bad + bad):
            with self.assertRaises(AssertionError):
                validate_searches(output, expected)

    def test_progress_requires_a_witness(self):
        expected = [('progress', 'witness'), ('stuck', 'unreachable')]
        validate_searches(search('progress', 'Solution 1 (state 1)') +
                          search('stuck', 'No solution.'), expected)
        with self.assertRaisesRegex(AssertionError, 'expected witness'):
            validate_searches(search('progress', 'No solution.') +
                              search('stuck', 'No solution.'), expected)

    @unittest.skipUnless(shutil.which('maude'), 'Maude required')
    def test_real_model_rejects_swapped_good_and_negative_control(self):
        model = Path(__file__).with_name('cache_coherence.maude')
        text = model.read_text()
        text = text.replace('w0, update, good) .', 'w0, update, SWAP) .', 1)
        text = text.replace('w0, update, badWay1) .', 'w0, update, good) .', 1)
        text = text.replace('w0, update, SWAP) .', 'w0, update, badWay1) .', 1)
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / model.name
            path.write_text(text)
            runner = Path(temp) / 'check_formal.py'
            shutil.copyfile(model.with_name('check_formal.py'), runner)
            out = Path(temp) / 'results'
            out.mkdir()
            (out / 'results.json').write_text('{"complete": true}')
            result = subprocess.run([sys.executable, str(runner), '--models', model.name,
                                     '--out', str(out)],
                                    capture_output=True, text=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            report = json.loads((out / 'results.json').read_text())
            self.assertFalse(report['complete'])
            self.assertIn('initialUpdate: expected safe', report['error'])
            self.assertIn('Solution 1', (out / (model.name + '.log')).read_text())

    @unittest.skipUnless(shutil.which('maude'), 'Maude required')
    def test_third_tag_witness_rejects_eviction_of_the_mru_way(self):
        model = Path(__file__).with_name('cache_coherence.maude')
        definitions = model.read_text().split('endm')[0] + 'endm\n'
        self.assertEqual(definitions.count('else if R == w0 then'), 1)
        mutant = definitions.replace('else if R == w0 then', 'else if R == w1 then')
        query = ('search [1,1] in CACHE-COHERENCE : initialEviction0 =>* S:State '
                 'such that evictedWay1(S:State) .\n')
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'wrong-victim.maude'
            path.write_text(mutant + query)
            result = subprocess.run(['maude', '-no-banner', str(path)],
                                    capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        with self.assertRaisesRegex(AssertionError, 'initialEviction0: expected witness'):
            validate_searches(result.stdout + result.stderr, [('initialEviction0', 'witness')])

    @unittest.skipUnless(shutil.which('maude'), 'Maude required')
    def test_real_refill_completion_mutant_cannot_pass_progress_check(self):
        model = Path(__file__).with_name('cache_cycle.maude')
        # Keep only the real model's cold-read witness; no expensive safety search
        # is necessary to detect the original missing-completion bug.
        definitions = model.read_text().split('endm')[0] + 'endm\n'
        old = 'if F == stuckFill then rd(T,false,W) else rd(T,true,W) fi'
        self.assertIn(old, definitions)
        mutant = definitions.replace(old, 'rd(T,false,W)')
        query = 'search [1,12] in CACHE-CYCLE : initialRead =>* S:State such that readCompleted(S:State) .\n'
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'stuck.maude'
            path.write_text(mutant + query)
            result = subprocess.run(['maude', '-no-banner', str(path)],
                                    capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        with self.assertRaisesRegex(AssertionError, 'initialRead: expected witness'):
            validate_searches(result.stdout + result.stderr, [('initialRead', 'witness')])


if __name__ == '__main__':
    unittest.main()
