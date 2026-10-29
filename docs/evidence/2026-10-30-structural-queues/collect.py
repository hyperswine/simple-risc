#!/usr/bin/env python3
"""Freeze the local queue/effect checkpoint; requires its original output tree."""
from pathlib import Path
import gzip
import hashlib
import io
import json
import shutil
import subprocess
import tarfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT = ROOT / "output/tangnano20k/structural-queues-20261030"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def files(folder):
    return [p for p in folder.rglob("*") if p.is_file() and "__pycache__" not in p.parts]


def archive(name, entries):
    content = io.BytesIO()
    with tarfile.open(fileobj=content, mode="w") as t:
        for p, label in sorted(entries, key=lambda item: item[1]):
            info = tarfile.TarInfo(label)
            data = p.read_bytes()
            info.mode, info.size, info.mtime = 0o644, len(data), 0
            t.addfile(info, io.BytesIO(data))
    (HERE / name).write_bytes(gzip.compress(content.getvalue(), mtime=0))


def copy(p, name):
    target = HERE / name
    target.parent.mkdir(parents=True, exist_ok=True)
    if p.suffix in {".v", ".vg", ".html", ".tr", ".hex", ".bin", ".elf"}:
        target.with_name(target.name + ".gz").write_bytes(gzip.compress(p.read_bytes(), mtime=0))
    else:
        shutil.copyfile(p, target)


def main():
    archive("control-sources.tar.gz", [(p, str(p.relative_to(OUT / "control"))) for p in files(OUT / "control")])
    archive("candidate-sources.tar.gz", [(p, "src/" + str(p.relative_to(OUT / "fqueue/source"))) for p in files(OUT / "fqueue/source")] + [(OUT / "fqueue/test-SimpleRisc.hs", "test/SimpleRisc.hs")])
    current = []
    for folder in ["src", "test", "tools", "formal", "boards/tangnano20k", ".github"]:
        current.extend((p, str(p.relative_to(ROOT))) for p in files(ROOT / folder))
    for name in ["simple-risc.cabal", "cabal.project", "cabal.project.freeze", "docs/2026-10-29-HOLD-ENABLE-AND-MRU-LOOKUP.md", "docs/2026-10-30-STRUCTURAL-BASELINE.md", "docs/2026-10-30-STRUCTURAL-VARIANTS.md", "docs/2026-10-30-STRUCTURAL-EXPERIMENTS.md", "docs/2026-10-30-QUEUE-AND-EFFECT-CONTRACTS.md"]:
        current.append((ROOT / name, name))
    archive("retained-sources.tar.gz", current)
    write_json(HERE / "source-checkpoint.json", {name: sha(p) for p, name in current})
    for p in OUT.iterdir():
        if p.is_file() and p.suffix in {".log", ".json", ".py"}:
            copy(p, "receipts/" + p.name)
    for p in files(OUT / "formal"):
        copy(p, "formal/" + str(p.relative_to(OUT / "formal")))
    board = OUT / "final-board-54"
    assert json.loads((board / "results.json").read_text())["passed"]
    for p in files(board):
        copy(p, "physical/final-board-54/" + str(p.relative_to(board)))
    for folder in ["fqueue/perf", "fqueue/rtl-im", "fqueue/rtl-imc", "fqueue/rtl-imc-cdc", "control-rtl-imc", "control-rtl-im-iverilog"]:
        receipt = json.loads((OUT / folder / "results.json").read_text())
        assert receipt["passed"], folder
        for p in files(OUT / folder):
            if "obj" not in p.relative_to(OUT / folder).parts and p.suffix in {".log", ".json", ".hex", ".bin", ".elf", ".S", ".ld"}:
                copy(p, "simulation/" + str(p.relative_to(OUT)))
    for folder in ["fqueue/generated", "fqueue/generated-im"]:
        for p in (OUT / folder).rglob("*.v"):
            copy(p, "generated/" + str(p.relative_to(OUT)))
    names = {"build.tcl", "clocks.sdc", "pins.cst", "pll.v", "pipeline_top.v", "memory.v", "sdram-io-model.json", "bootrom-sdram.hex", "sdram_test.vg", "sdram_test_syn.rpt.html", "sdram_test_syn_resource.html", "sdram_test_syn_rsc.xml", "sdram_test_tr_content.html", "sdram_test.tr", "sdram_test.rpt.txt", "sdram_test.log"}
    build = OUT / "fqueue/hardware-48"
    for p in files(build):
        if p.name in names:
            copy(p, "build/" + str(p.relative_to(build)))
    image = build / "impl/pnr/sdram_test.fs"
    write_json(HERE / "build/bitstream.json", {"sha256": sha(image), "bytes": image.stat().st_size, "programmed": False})
    shared = {}
    for name in ["docs/evidence/2026-10-30-structural-variants/manifest.json", "docs/evidence/2026-10-30-structural-variants/builds/btb-only/hardware-48/bitstream.json", "docs/evidence/2026-10-28-controlled-benchmark/base.bin.gz", "docs/evidence/2026-10-28-controlled-benchmark/base.elf.gz", "docs/evidence/2026-10-28-controlled-benchmark/dtree-oracle.py"]:
        shared[name] = sha(ROOT / name)
    write_json(HERE / "manifest.json", {"artifacts": {str(p.relative_to(HERE)): sha(p) for p in files(HERE) if p != HERE / "manifest.json"}, "shared_inputs": shared, "source_checkpoint": "source-checkpoint.json", "git_status": subprocess.check_output(["git", "status", "--short", "--branch"], cwd=ROOT, text=True), "scope": "Queue candidate rejected, source restored, local contract evidence; no hosted CI or new physical acceptance."})
    print("Queue evidence collected")


if __name__ == "__main__":
    main()
