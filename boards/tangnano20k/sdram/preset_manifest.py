#!/usr/bin/env python3
"""Record a fresh fprisc-48 build; incomplete builds never become loadable."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
CONFIG = dict(xlen=32, compressed=True, cpu_mhz=48, memory_mhz=48,
              ram_bytes=8388608, cache_bytes=65536, cache_ways=1,
              cache_line_bits=12, phase_degrees=135,
              placement=2, write_update=True)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inputs():
    paths = list((ROOT / 'src').glob('*.hs'))
    paths += list((ROOT / 'boards/tangnano20k/sdram').glob('*.v'))
    paths += [ROOT / name for name in (
        'cabal.project', 'cabal.project.freeze', 'simple-risc.cabal', 'bin/Clash.hs',
        'boards/tangnano20k/tangnano20k.cst', 'boards/tangnano20k/bootrom/bootrom.hex',
        'boards/tangnano20k/bootrom/bootrom-sdram.hex',
        'boards/tangnano20k/sdram/build.sh', 'boards/tangnano20k/sdram/preset.sh',
        'boards/tangnano20k/sdram/preset_manifest.py',
        'boards/tangnano20k/sdram/io_timing.py',
        'boards/tangnano20k/sdram/io_timing_gw2ar18_qn88.json',
        'boards/tangnano20k/check_gowin_timing.py')]
    return {str(p.relative_to(ROOT)): sha(p) for p in sorted(paths)}


def compute_build_id(input_hashes, config=CONFIG):
    payload = json.dumps({'configuration': config, 'inputs': input_hashes}, sort_keys=True).encode()
    return hashlib.sha256(payload).hexdigest()[:16]


def rom_identity(input_hashes, config=CONFIG):
    return dict(
        protocol='SRID1',
        isa='rv32imc' if config.get('compressed') else 'rv32im',
        cpu_mhz=config['cpu_mhz'],
        mem_mhz=config['memory_mhz'],
        ram_bytes=config['ram_bytes'],
        max_bytes=2097152,
        capabilities='PMXQVHTUICG',
        build_id=compute_build_id(input_hashes, config),
    )


def main():
    action, directory = sys.argv[1:3]
    out = Path(directory).resolve()
    out.mkdir(parents=True, exist_ok=True)
    manifest = out / 'build-manifest.json'
    if action == 'begin':
        # Even missing tools or unreadable source inputs must invalidate an
        # earlier success before the new build's provenance is collected.
        manifest.write_text(json.dumps(dict(preset='fprisc-48', ready=False)) + '\n')
        inp = inputs()
        report = dict(preset='fprisc-48', configuration=CONFIG,
                      rom_identity=rom_identity(inp), ready=False,
                      qualification='internal STA only; SDRAM I/O/PVT unqualified',
                      source_root=str(ROOT), inputs=inp,
                      revision=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                      source_diff_sha256=hashlib.sha256(subprocess.check_output(['git', 'diff', 'HEAD'], cwd=ROOT)).hexdigest(),
                      tools={tool: subprocess.check_output(command, cwd=ROOT, text=True).strip()
                             for tool, command in {'ghc': ['ghc-9.8.2', '--numeric-version'],
                                                   'cabal': ['cabal', '--numeric-version']}.items()})
    elif action == 'finish':
        report = json.loads(manifest.read_text())
        if report['inputs'] != inputs():
            raise SystemExit('preset inputs changed during build; rebuild before loading')
        if 'rom_identity' not in report:
            report['rom_identity'] = rom_identity(report['inputs'])
        # Repeat the gate here so invoking this helper alone cannot mark a
        # failed placement ready. Hash the checked report and final bitstream.
        timing = out / 'impl/pnr/sdram_test.tr'
        subprocess.run([sys.executable, str(ROOT / 'boards/tangnano20k/check_gowin_timing.py'),
                        str(timing), '--freq-mhz', '48'], check=True)
        artifacts = {}
        for name in ('impl/pnr/sdram_test.fs', 'impl/pnr/sdram_test.tr',
                     'pipeline_top.v', 'pll.v', 'clocks.sdc', 'build.tcl'):
            path = out / name
            if not path.stat().st_size:
                raise SystemExit(f'empty build artifact: {path}')
            artifacts[name] = sha(path)
        rtl = Path(sys.argv[3]).resolve()
        report.update(ready=True, artifacts=artifacts,
                      rtl={'path': str(rtl), 'sha256': sha(rtl)})
    else:
        raise SystemExit('expected begin or finish')
    manifest.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
