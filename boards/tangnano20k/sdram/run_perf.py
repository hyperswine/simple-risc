#!/usr/bin/env python3
"""Measure where the SDRAM pipeline's cycles go, in simulation.

Runs a preloaded RV32 image (a raw binary at 0x8000_0000, such as an FP-RISC
Base image) on the generated CPU, the real cache, the optional clock bridge,
the real burst controller and a functional SDRAM pin model (perf_tb.v), and
prints cache-hold counters. Verilator by default; the UART divider is
shortened in a simulation copy of the generated Verilog only.
"""
from pathlib import Path
import argparse
import hashlib
import json
import math
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def sv_safe(text):
    """Rename Verilog identifiers that SystemVerilog reserves.

    Clash emits legal Verilog identifiers that Verilator, parsing as
    SystemVerilog, rejects.
    """
    return re.sub(r'\b(new|byte|bit|logic|int|do|final|type|ref|this|string|unique|priority|break|continue|return|void|shortint|longint|chandle|class|package|import|export|context|bind|alias|const|static|automatic|local|virtual|extends|super|null|inside|dist|solve|before|wait_order|randomize|with|matches|tagged|interface|modport|program|property|sequence|cover|assert|assume|expect|clocking|constraint|covergroup|coverpoint|cross|bins|binsof|illegal_bins|ignore_bins|first_match|throughout|within|intersect|join_any|join_none|forkjoin|struct|union|enum|typedef|packed|var|rand|randc|pure|protected|foreach|endclass|endpackage)\b(?!\s*\()',
                  lambda m: m[1]+'_sv', text)


OBSERVATION_PORTS = ('commit', 'word', 'pc', 'next_pc', 'issue', 'fetch_pc', 'empty', 'redirect')


def require_observations(sources):
    """Refuse ordinary or stale generated tops before compiling a testbench."""
    text = '\n'.join(Path(source).read_text() for source in sources)
    missing = [name for name in OBSERVATION_PORTS
               if not re.search(r'\boutput\s+(?:wire\s+)?(?:\[\d+:\d+\]\s+)?observe_' + name + r'\b', text)]
    if missing:
        raise ValueError('generate SdramPipelineObserved for simulation; missing observation ports: ' + ', '.join(missing))


SLOT_PORTS = ('slot', 'fetch_port_blocked')

# Exclusive issue-slot causes (perf_tb.v NAMED_SLOT_OBSERVATIONS), in display order.
SLOT_CAUSES = (
    ('slot_issue', 'issued into E1'),
    ('slot_load_wait', 'behind a load in M'),
    ('slot_mul_wait', 'behind a multiply in M'),
    ('slot_other_wait', 'behind another M wait'),
    ('slot_port_conflict', 'E2 load blocked by an M store'),
    ('slot_hazard', 'operand hazard in decode'),
    ('slot_restart', 'restart cycle (redirect/handover/fence)'),
    ('slot_frontend_refill', 'front end refilling after restart'),
    ('slot_frontend_other', 'front end empty, other'),
    ('slot_slow', 'outside the pipeline (ROM/trap phases)'),
    ('slot_other', 'unclassified'),
)


def require_slot_observations(sources):
    text = '\n'.join(Path(source).read_text() for source in sources)
    missing = [name for name in SLOT_PORTS
               if not re.search(r'\boutput\s+(?:wire\s+)?(?:\[\d+:\d+\]\s+)?observe_' + name + r'\b', text)]
    if missing:
        raise ValueError('regenerate SdramPipelineObserved; missing stall-breakdown ports: ' + ', '.join(missing))


def stall_breakdown(metrics):
    """Check the slot identity and return (key, label, cycles, percent) rows.

    Every unheld measured cycle carries exactly one cause, so the causes plus
    window_held must equal window_cycles.
    """
    keys = [key for key, _ in SLOT_CAUSES]
    if not set(keys) <= metrics.keys():
        raise ValueError('missing stall-breakdown counters')
    total = sum(metrics[key] for key in keys) + metrics['window_held']
    if total != metrics['window_cycles']:
        raise ValueError(f'slot causes plus held ({total}) differ from window cycles ({metrics["window_cycles"]})')
    cycles = metrics['window_cycles']
    rows = [('window_held', 'cache holds the core', metrics['window_held'])]
    rows += [(key, label, metrics[key]) for key, label in SLOT_CAUSES]
    return [(key, label, value, 100*value/cycles) for key, label, value in rows]


def format_breakdown(rows, metrics):
    lines = ['STALL BREAKDOWN (share of measured cycles)']
    lines += [f'  {label:<42} {value:>13,} {percent:6.2f}%' for _, label, value, percent in rows]
    commits = metrics.get('window_pipeline_commits', 0)
    issued = metrics['slot_issue']
    lines.append(f'  commits {commits:,}  IPC {commits/metrics["window_cycles"]:.3f}  '
                 f'wrong-path issues {issued-commits:,}  fetch port blocked {metrics["fetch_port_blocked"]:,} cycles')
    return '\n'.join(lines)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def parse_metrics(output, start, end):
    lines = output.splitlines()
    if lines.count(start) != 1 or lines.count(end) != 1:
        raise ValueError('benchmark requires exactly one start and successful end marker')
    if lines.index(start) >= lines.index(end) or 'PERF LIMIT reached' in output or 'FPR EXIT 1' in lines:
        raise ValueError('benchmark failed or reached its simulation limit')
    metrics = {}
    for line in lines:
        if line.startswith('PERF '):
            for key, value in re.findall(r'(\w+)=(\d+)', line):
                if key in metrics:
                    raise ValueError(f'duplicate performance counter: {key}')
                metrics[key] = int(value)
    required = {'cycles', 'held', 'fills', 'code_fills', 'window_cycles', 'window_held',
                'window_fills', 'window_writes', 'held_read_miss', 'held_write_full'}
    if not required <= metrics.keys() or metrics['window_cycles'] <= 0:
        raise ValueError('missing counters or empty measurement window')
    if not 0 <= metrics['window_held'] <= metrics['window_cycles'] <= metrics['cycles']:
        raise ValueError('inconsistent performance counters')
    return metrics


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('image', type=Path, help='raw binary loaded at 0x8000_0000')
    p.add_argument('--elf', type=Path, help='ELF for the text end (classifies code fills)')
    p.add_argument('--generated', type=Path,
                   default=ROOT/'output/tangnano20k/sdram-generated/SdramPipeline-1/SdramPipeline.topEntity')
    p.add_argument('--cache-rtl', type=Path, default=HERE/'pipeline_cache.v')
    p.add_argument('--bridge-rtl', type=Path, default=HERE/'clock_bridge.v')
    p.add_argument('--cpu-mhz', type=float, default=72)
    p.add_argument('--mem-mhz', type=float, default=54)
    p.add_argument('--single-clock', action='store_true', help='no bridge; memory runs on the CPU clock')
    p.add_argument('--line-bits', type=int, default=11)
    p.add_argument('--ways', type=int, choices=[1, 2], default=2)
    p.add_argument('--write-update', type=int, choices=[0, 1], default=1)
    p.add_argument('--start', default='DTREE BEGIN train=128 test=64 bins=8 depth=5 minLeaf=2')
    p.add_argument('--end', default='FPR EXIT 0')
    p.add_argument('--limit', type=int, default=800_000_000)
    p.add_argument('--out', type=Path)
    stage = p.add_mutually_exclusive_group()
    stage.add_argument('--build-only', action='store_true')
    stage.add_argument('--validate-only', action='store_true', help='check an existing build without executing it')
    stage.add_argument('--run-only', action='store_true', help='require matching source/configuration and binary hashes')
    p.add_argument('--jobs', type=int, default=2, help='bounded Verilator C++ build parallelism')
    p.add_argument('--timeout', type=float, default=1800, help='wall-clock limit per simulator execution')
    p.add_argument('--profile-cpu', action='store_true', help='count pipeline commits and redirects through named observation ports')
    p.add_argument('--stall-breakdown', action='store_true', help='attribute every cycle to one issue-slot cause (implies --profile-cpu)')
    p.add_argument('--legacy-profile-20261028', action='store_true', help='explicit historical replay of the frozen 2026-10-28 profiling layout')
    a = p.parse_args()
    if (not all(math.isfinite(v) and v > 0 for v in [a.cpu_mhz, a.mem_mhz, a.timeout])
            or a.jobs < 1 or not 7 <= a.line_bits <= 12):
        p.error('clocks, timeout and jobs must be positive; line-bits must be 7..12')
    name = a.out or ROOT/'output/tangnano20k/perf'/(
        f'{a.image.stem}-{"single" if a.single_clock else "cdc"}-c{a.cpu_mhz:g}-m{a.mem_mhz:g}'
        f'-l{a.line_bits}-k{a.ways}-w{a.write_update}-{a.cache_rtl.stem}')
    out = name.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if not a.validate_only:
        (out/'results.json').write_text(json.dumps(dict(passed=False))+'\n')
    sources = sorted(a.generated.glob('*.v'))
    if not sources:
        raise SystemExit(f'no generated Verilog in {a.generated}')
    if a.stall_breakdown:
        if a.legacy_profile_20261028:
            p.error('--stall-breakdown needs the named observation ABI')
        a.profile_cpu = True
    if a.legacy_profile_20261028 and not a.profile_cpu:
        p.error('--legacy-profile-20261028 requires --profile-cpu')
    if a.profile_cpu:
        if a.legacy_profile_20261028:
            text = '\n'.join(source.read_text() for source in sources)
            if not re.search(r'wire\s+\[659:0\]\s+e2Moved\s*;', text) or not re.search(r'wire\s+mCommits\s*;', text):
                raise SystemExit('archived profiling ABI mismatch; use named observations for current CPUs')
        else:
            require_observations(sources)
            if a.stall_breakdown:
                require_slot_observations(sources)
    copied = []
    for source in sources:
        text = source.read_text()
        text, full = re.subn(r"10'd867\b", "10'd31", text)
        text, half = re.subn(r"10'd433\b", "10'd15", text)
        assert full >= 6 and half >= 1, (full, half)
        text = sv_safe(text)
        target = out/source.name
        target.write_text(text)
        copied.append(target)
    (out/'rom.hex').write_text('\n'.join(['800002b7', '00028067']+['00000013']*510)+'\n')
    image = a.image.read_bytes()
    image += b'\0'*(-len(image) % 4)
    (out/'image.hex').write_text('\n'.join(f'{int.from_bytes(image[i:i+4], "little"):08x}'
                                           for i in range(0, len(image), 4))+'\n')
    text_end = 0
    if a.elf:
        sections = subprocess.run(['riscv64-unknown-elf-readelf', '-SW', a.elf],
                                  capture_output=True, text=True, check=True).stdout
        found = re.search(r'\s\.text\s+PROGBITS\s+([0-9a-f]+)\s+[0-9a-f]+\s+([0-9a-f]+)', sections)
        if found:
            text_end = (int(found[1], 16)+int(found[2], 16)-0x8000_0000)//4
    cdc = 0 if a.single_clock else 1
    binary = out/'obj'/'Vperf_tb'
    build = ['verilator', '--binary', '--timing', '-O3', '-Wno-fatal', '-Wno-lint', '-Wno-style',
             '--top-module', 'perf_tb', '--Mdir', out/'obj', '-j', str(a.jobs),
             f'-GROM_FILE="{out}/rom.hex"', f'-GCDC_BRIDGE={cdc}', f'-GCPU_MHZ={a.cpu_mhz}',
             f'-GMEM_MHZ={a.mem_mhz}', f'-GPROFILE_CPU={int(a.profile_cpu)}', f'-GLINE_BITS={a.line_bits}', f'-GWAYS={a.ways}', f'-GWRITE_UPDATE={a.write_update}',
             *(['-DLEGACY_PROFILE_20261028'] if a.legacy_profile_20261028 else []),
             *(['-DNAMED_PIPELINE_OBSERVATIONS'] if a.profile_cpu and not a.legacy_profile_20261028 else []),
             *(['-DNAMED_SLOT_OBSERVATIONS'] if a.stall_breakdown else []),
             *copied, a.cache_rtl.resolve(), a.bridge_rtl.resolve(), HERE/'sdram.v', HERE/'burst_memory.v',
             HERE/'perf_tb.v']
    config = dict(cpu_mhz=a.cpu_mhz, mem_mhz=a.mem_mhz, cdc=bool(cdc),
                  line_bits=a.line_bits, ways=a.ways, write_update=a.write_update,
                  profile_cpu=a.profile_cpu, profile_abi=('legacy-20261028' if a.legacy_profile_20261028 else 'named-v2' if a.stall_breakdown else 'named-v1') if a.profile_cpu else None, image_sha256=sha(a.image),
                  elf_sha256=sha(a.elf) if a.elf else None,
                  generated={str(p.resolve()): sha(p) for p in sources},
                  inputs={str(p.resolve()): sha(p) for p in [a.cache_rtl, a.bridge_rtl,
                          HERE/'perf_tb.v', HERE/'sdram.v', HERE/'burst_memory.v', Path(__file__)]})
    receipt_path = out/'build-manifest.json'
    if a.run_only or a.validate_only:
        receipt = json.loads(receipt_path.read_text())
        if not (receipt.get('ready') is True and receipt.get('configuration') == config
                and binary.is_file() and receipt.get('binary_sha256') == sha(binary)):
            raise SystemExit('simulation binary/source/configuration mismatch; rebuild before running')
    else:
        receipt_path.write_text(json.dumps(dict(ready=False)) + '\n')
        with (out/'build.log').open('w') as f:
            result = subprocess.run([str(x) for x in build], cwd=ROOT, stdout=f,
                                    stderr=subprocess.STDOUT, timeout=600)
        if result.returncode:
            sys.stdout.write((out/'build.log').read_text()[-4000:])
            raise SystemExit('verilator build failed')
        receipt = dict(ready=True, configuration=config, binary_sha256=sha(binary))
        receipt_path.write_text(json.dumps(receipt, indent=2)+'\n')
    if a.validate_only:
        print(f'Validated build: {out}', flush=True)
        return
    if a.build_only:
        print(f'Built: {out}', flush=True)
        return
    report = dict(passed=False, configuration=config, build_manifest_sha256=sha(receipt_path),
                  start=a.start, end=a.end, cycle_limit=a.limit)
    result_path = out/'results.json'
    result_path.write_text(json.dumps(report, indent=2)+'\n')
    command = [str(binary), f'+IMAGE={out}/image.hex', f'+WORDS={len(image)//4}',
               f'+TEXT_END={text_end}', f'+START={a.start}', f'+END={a.end}', f'+LIMIT={a.limit}']
    try:
        with (out/'run.log').open('w') as f:
            process = subprocess.run(command, cwd=out, stdout=f, stderr=subprocess.STDOUT, timeout=a.timeout)
        output = (out/'run.log').read_text()
        if process.returncode:
            raise ValueError(f'simulator exited {process.returncode}; see {out / "run.log"}')
        metrics = parse_metrics(output, a.start, a.end)
        report.update(passed=True, metrics=metrics, measured_us=metrics['window_cycles']/a.cpu_mhz,
                      held_percent=100*metrics['window_held']/metrics['window_cycles'],
                      output_sha256=sha(out/'run.log'))
        if a.stall_breakdown:
            rows = stall_breakdown(metrics)
            report['stall_breakdown'] = {key: dict(cycles=value, percent=round(percent, 4))
                                         for key, _, value, percent in rows}
        print(output, end='', flush=True)
        if a.stall_breakdown:
            print(format_breakdown(rows, metrics), flush=True)
    except BaseException as error:
        report['error'] = str(error)
        raise
    finally:
        result_path.write_text(json.dumps(report, indent=2)+'\n')
    print(f'logs: {out}')


if __name__ == '__main__':
    main()
