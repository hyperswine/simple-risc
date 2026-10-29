#!/usr/bin/env python3
"""Separate verified upload, computation, sustained output and paced readback.

Uses one open UART descriptor throughout. Does not program the FPGA. Pass the
actual loaded bitstream path to record its hash, and use the matching clock.
The signature reporter is a second guest; it reads memory left by the first.
It still relies on the UART, so a missing reporter response is inconclusive.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE.parent))
import rom_protocol as rp


def reference():
    data, x, mask = [], 0x12345678, 0xffffffff
    for i in range(32768):
        x ^= (x << 13) & mask
        x ^= x >> 17
        x ^= (x << 5) & mask
        data.append(x ^ ((i * 0x9e3779b9) & mask))
    digest = 0x13579bdf
    for i in range(32768):
        digest = ((((digest << 5) | (digest >> 27)) & mask) ^ data[(i * 17) & 32767]) + 0x7f4a7c15
        digest &= mask
    return digest


def expected_signature(mode):
    digest = reference()
    values = [0x53545231, digest, digest ^ 0xffffffff, 32768, 0 if mode == 'silent' else 4096, 2]
    return ('SIGNATURE ' + ' '.join(f'{n:08x}' for n in values) + '\nDONE').encode()


def expected_output(mode):
    return (b'' if mode == 'silent' else bytes(33 + (i * 17) % 90 for i in range(4096))) + b'DONE'


def run_guest(transport, image, timeout):
    # CRC verification is separate from any guest computation/output claim.
    rp.upload_image_u(transport, image, timeout=timeout)
    initial = rp.start_guarded(transport)
    return initial + (b'' if initial.endswith(b'DONE') else transport.read_until(lambda b: b.endswith(b'DONE'), timeout))


def build(out):
    images = {}
    for name, define in [('silent', '-DOUTPUT_MODE=0'), ('burst', '-DOUTPUT_MODE=1'),
                         ('paced', '-DOUTPUT_MODE=2'), ('reporter', '-DREPORT_SIGNATURE')]:
        elf = out / f'{name}.elf'
        command = ['riscv64-unknown-elf-gcc', '-march=rv32im_zicsr', '-mabi=ilp32', '-mcmodel=medany',
                   '-O2', '-Wall', '-Wextra', '-ffreestanding', '-fno-builtin', '-nostdlib', '-nostartfiles',
                   '-Wl,--no-warn-rwx-segments', define, '-T', str(HERE / 'link.ld'),
                   str(HERE.parent / 'c/crt0.S'), str(HERE / 'output_diagnostic.c'), '-o', str(elf)]
        subprocess.run(command, check=True, capture_output=True, timeout=60)
        binary = elf.with_suffix('.bin')
        subprocess.run(['riscv64-unknown-elf-objcopy', '-O', 'binary', str(elf), str(binary)], check=True)
        images[name] = binary.read_bytes()
    return images


def probe_uploads(transport, timeout):
    """Never execute these bytes. Separate receive CRC from memory readback."""
    cases = []
    for words in (1, 16, 128, 512):
        for pattern in ('zero', 'ones', 'sequence'):
            image = bytes(0 if pattern == 'zero' else 255 if pattern == 'ones' else (i * 73 + 19) % 256
                          for i in range(words * 4))
            case = dict(words=words, pattern=pattern, readbacks=[], receive_crc_verified=False)
            try:
                crc = rp.upload_image_u(transport, image, verify_readback=False, retries=0, timeout=timeout)
                case.update(receive_crc_verified=True, expected_crc=f'{crc:08x}')
                for _ in range(3):
                    transport.write(b'C')
                    reply = transport.read_until(lambda b: b'\n' in b, timeout)
                    case['readbacks'].append(reply.decode('ascii', 'backslashreplace').strip())
                case['passed'] = all(reply == case['expected_crc'] for reply in case['readbacks'])
            except Exception as error:
                case.update(passed=False, error=dict(type=type(error).__name__, message=str(error)))
                transport.write(b'\x03')
                transport.drain()
            print(f'upload-only {words} words {pattern}: receive CRC={case["receive_crc_verified"]}, memory CRC={case["passed"]}', flush=True)
            cases.append(case)
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True, help='new output directory; never overwrites evidence')
    parser.add_argument('--build-only', action='store_true')
    parser.add_argument('--uploads-only', action='store_true', help='do not execute guests; compare receive CRC to three memory readback CRCs')
    parser.add_argument('--port', default='/dev/cu.usbserial-20250303171')
    parser.add_argument('--freq-mhz', type=float, default=48)
    parser.add_argument('--bitstream', type=Path, help='path to the image already programmed into SRAM')
    parser.add_argument('--repeat', type=int, default=3)
    parser.add_argument('--timeout', type=float, default=30)
    args = parser.parse_args()
    if args.repeat < 1 or args.timeout <= 0:
        parser.error('repeat and timeout must be positive')
    baud = rp.baud_for_mhz(args.freq_mhz)
    if not args.build_only and not args.bitstream:
        parser.error('physical diagnostics require --bitstream for image provenance')
    args.out.mkdir(parents=True, exist_ok=False)
    for source in (Path(__file__), HERE / 'output_diagnostic.c', HERE / 'link.ld', HERE.parent / 'c/crt0.S', HERE.parent / 'rom_protocol.py'):
        (args.out / source.name).write_bytes(source.read_bytes())
    images = {} if args.uploads_only else build(args.out)
    report = dict(passed=False, cpu_mhz=args.freq_mhz, baud=baud, cases=[],
                  bitstream_sha256=hashlib.sha256(args.bitstream.read_bytes()).hexdigest() if args.bitstream else None,
                  images={name: hashlib.sha256(data).hexdigest() for name, data in images.items()},
                  source_sha256=hashlib.sha256((HERE / 'output_diagnostic.c').read_bytes()).hexdigest(),
                  linker_sha256=hashlib.sha256((HERE / 'link.ld').read_bytes()).hexdigest(),
                  runner_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  reference_digest=reference())
    result = args.out / 'results.json'
    if args.build_only:
        report['build_only'] = True
        result.write_text(json.dumps(report, indent=2) + '\n')
        print(f'Built four diagnostic guests; reference digest {reference():08x}')
        return
    fd = os.open(args.port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    transport = rp.FdTransport(fd)
    try:
        rp.set_fd_baud(fd, baud)
        ident = rp.query_identity(transport, expected_mhz=args.freq_mhz)
        rp.check_compatibility(ident, expected_cpu_mhz=round(args.freq_mhz), required_caps='UICG')
        report['identity'] = ident.raw
        if args.uploads_only:
            report['upload_probes'] = probe_uploads(transport, args.timeout)
            report['passed'] = all(case['passed'] for case in report['upload_probes'])
            report['phase'] = 'upload probes complete; no guest executed'
            if not report['passed']:
                raise SystemExit('Upload/readback CRC differences recorded; no guest executed.')
            return
        for repetition in range(1, args.repeat + 1):
            for mode in ('silent', 'burst', 'paced'):
                name = f'{mode}-{repetition}'
                report['phase'] = name + ': workload upload/run'
                actual = run_guest(transport, images[mode], args.timeout)
                (args.out / f'{name}.uart.bin').write_bytes(actual)
                # Uploading the small reporter replaces the old code, but
                # leaves the high-address signature intact. It reads each
                # word and paces every output byte beyond one physical frame.
                report['phase'] = name + ': signature reporter upload/run'
                signature = run_guest(transport, images['reporter'], args.timeout)
                (args.out / f'{name}.signature.bin').write_bytes(signature)
                case = dict(mode=mode, repetition=repetition, output_bytes=len(actual),
                            output_matches=actual == expected_output(mode),
                            signature_matches=signature == expected_signature(mode),
                            upload_crc_verified=True)
                report['cases'].append(case)
                result.write_text(json.dumps(report, indent=2) + '\n')
                print(f'{name}: output={case["output_matches"]}, independent guest signature={case["signature_matches"]}', flush=True)
        report['passed'] = all(c['output_matches'] and c['signature_matches'] for c in report['cases'])
        report['phase'] = 'complete'
    except Exception as error:
        report['error'] = dict(type=type(error).__name__, message=str(error))
        raise
    finally:
        # Stop any timed-out guest and let serial traffic settle before close.
        transport.write(b'\x03')
        transport.drain()
        os.close(fd)
        result.write_text(json.dumps(report, indent=2) + '\n')
    if not report['passed']:
        raise SystemExit('Diagnostic differences recorded; do not qualify this image.')


if __name__ == '__main__':
    main()
