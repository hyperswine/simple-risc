#!/usr/bin/env python3
"""Build a bounded raw-readback diagnostic ROM without overwriting board ROMs."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess

HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True, help='new isolated directory')
    parser.add_argument('--production-control', action='store_true', help='omit the diagnostic macro for byte-for-byte control compilation')
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    for name in ['bootrom.c', 'crt0.S', 'link.ld', 'build_readback_rom.py']:
        shutil.copy2(HERE / name, out / name)
    elf = out / 'readback.elf'
    command = ['riscv64-unknown-elf-gcc', '-DROM_SDRAM',
               *([] if args.production_control else ['-DROM_DIAGNOSTIC_READBACK']),
               '-march=rv32i_zicsr', '-mabi=ilp32', '-Os', '-Wall', '-Wextra', '-ffreestanding', '-fno-builtin',
               '-nostdlib', '-nostartfiles', '-msmall-data-limit=0', '-fno-pic', '-fno-jump-tables',
               '-ffunction-sections', '-Wl,--gc-sections', '-Wl,--no-warn-rwx-segments', '-T', str(out/'link.ld'),
               str(out/'crt0.S'), str(out/'bootrom.c'), '-o', str(elf)]
    subprocess.run(command, check=True, timeout=60)
    binary = out / 'readback.bin'
    subprocess.run(['riscv64-unknown-elf-objcopy', '-O', 'binary', str(elf), str(binary)], check=True)
    image = binary.read_bytes()
    image += b'\0' * (-len(image) % 4)
    if len(image) > 2032:
        raise SystemExit('diagnostic ROM does not fit the original 508-word code region')
    code = image + bytes(2032-len(image))
    digest = hashlib.sha256(code + b':diagnostic-readback').digest()
    words = struct.unpack('<508I', code) + (48, 48, *struct.unpack('>II', digest[:8]))
    (out/'readback.hex').write_text(''.join(f'{word:08x}\n' for word in words))
    (out/'readback.lst').write_bytes(subprocess.check_output(['riscv64-unknown-elf-objdump', '-d', str(elf)]))
    report = dict(ready=True, diagnostic=not args.production_control, code_bytes=len(image), command=command,
                  sources={name: hashlib.sha256((out/name).read_bytes()).hexdigest() for name in
                           ['bootrom.c', 'crt0.S', 'link.ld', 'build_readback_rom.py']},
                  artifacts={name: hashlib.sha256((out/name).read_bytes()).hexdigest() for name in
                             ['readback.bin', 'readback.elf', 'readback.hex', 'readback.lst']})
    (out/'manifest.json').write_text(json.dumps(report, indent=2)+'\n')
    print(f'Built {len(image)} code bytes; diagnostic={report["diagnostic"]}: {out / "readback.hex"}')


if __name__ == '__main__':
    main()
