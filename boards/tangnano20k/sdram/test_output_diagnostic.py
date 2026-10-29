"""Check the real C workload and reporter against an independent host oracle."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import re

from diagnose_output import expected_output, expected_signature, parse_raw_readback

HERE = Path(__file__).resolve().parent

HARNESS = r'''
#include <stdint.h>
#include <stdio.h>
volatile uint32_t diagnostic_signature[6], diagnostic_data[32768];
void diagnostic_put(uint32_t c) { putchar(c); }
int guest_main(void), reporter_main(void);
int main(void) {
  if (guest_main()) return 1;
  fputs("DONE", stdout);
  if (reporter_main()) return 2;
  fputs("DONE", stdout);
  return 0;
}
'''


@unittest.skipUnless(shutil.which('cc'), 'native C compiler required')
class OutputDiagnosticTests(unittest.TestCase):
    def test_raw_readback_has_exact_count_framing_and_word_values(self):
        self.assertEqual(parse_raw_readback(b'00000002\n11223344\n89abcdef\nEND\n', 2),
                         bytes.fromhex('44332211efcdab89'))
        for bad in [b'00000001\n11223344\nEND\n', b'00000002\n11223344\nEND\n',
                    b'00000002\n11223344\n89abcdeg\nEND\n', b'00000002\n11223344\n89abcdef\n']:
            with self.assertRaises(ValueError):
                parse_raw_readback(bad, 2)

    def test_computation_output_and_retained_signature_for_all_modes(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            harness = out / 'harness.c'
            harness.write_text(HARNESS)
            source = HERE / 'output_diagnostic.c'
            common = ['cc', '-O2', '-std=c11', '-DDIAGNOSTIC_HOST_TEST']
            reporter = out / 'reporter.o'
            subprocess.run([*common, '-DREPORT_SIGNATURE', '-Dmain=reporter_main', '-c', str(source), '-o', str(reporter)], check=True)
            for mode, number in [('silent', 0), ('burst', 1), ('paced', 2)]:
                with self.subTest(mode=mode):
                    guest = out / 'guest.o'
                    executable = out / 'diagnostic'
                    subprocess.run([*common, f'-DOUTPUT_MODE={number}', '-Dmain=guest_main', '-c', str(source), '-o', str(guest)], check=True)
                    subprocess.run(['cc', str(harness), str(guest), str(reporter), '-o', str(executable)], check=True)
                    result = subprocess.run([str(executable)], capture_output=True, check=True, timeout=5)
                    self.assertEqual(result.stdout, expected_output(mode) + expected_signature(mode))


@unittest.skipUnless(shutil.which('riscv64-unknown-elf-gcc'), 'RISC-V compiler required')
class StartupAlignmentTests(unittest.TestCase):
    def test_odd_rodata_cannot_misalign_startup_bss_loop(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            source = out / 'odd.S'
            # With no BSS input section, the old script defined _bss_start
            # immediately after this one-byte rodata and the startup sw trapped.
            source.write_text('.section .text.entry,"ax"\n.globl _start\n_start: nop\n'
                              '.section .rodata\n.byte 1\n')
            elf = out / 'odd.elf'
            subprocess.run(['riscv64-unknown-elf-gcc', '-march=rv32im', '-mabi=ilp32', '-nostdlib',
                            '-T', str(HERE / 'link.ld'), str(source), '-o', str(elf)], check=True, capture_output=True)
            symbols = subprocess.check_output(['riscv64-unknown-elf-nm', str(elf)], text=True)
            bounds = {name: int(address, 16) for address, name in re.findall(r'^([0-9a-f]+)\s+\S\s+(_bss_start|_bss_end)$', symbols, re.M)}
            self.assertEqual(set(bounds), {'_bss_start', '_bss_end'})
            self.assertTrue(all(value % 4 == 0 for value in bounds.values()), bounds)
            self.assertEqual(bounds['_bss_start'], bounds['_bss_end'])


if __name__ == '__main__':
    unittest.main()
