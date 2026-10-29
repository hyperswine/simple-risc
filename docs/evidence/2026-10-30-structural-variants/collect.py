#!/usr/bin/env python3
"""Collect the local structural-variant checkpoint without changing its outputs.

Requires the original output/tangnano20k/structural-next-20261030 tree. Large
bitstreams are identified by hash; generated executables/object caches are
omitted. Running this on a later checkout creates a different source checkpoint.
"""
from pathlib import Path
import difflib
import gzip
import hashlib
import io
import json
import shutil
import subprocess
import tarfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT = ROOT / "output/tangnano20k/structural-next-20261030"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def copy(source, target):
    target = HERE / target
    target.parent.mkdir(parents=True, exist_ok=True)
    if source.suffix in {".v", ".vg", ".hex", ".elf", ".bin", ".html", ".tr", ".lst"}:
        target = target.with_name(target.name + ".gz")
        target.write_bytes(gzip.compress(source.read_bytes(), mtime=0))
    else:
        shutil.copyfile(source, target)


def source_archive(target, files):
    content = io.BytesIO()
    with tarfile.open(fileobj=content, mode="w") as archive:
        for source, name in sorted(files, key=lambda pair: pair[1]):
            info = tarfile.TarInfo(name)
            payload = source.read_bytes()
            info.size = len(payload)
            info.mode = 0o644
            info.mtime = 0
            archive.addfile(info, io.BytesIO(payload))
    (HERE / target).write_bytes(gzip.compress(content.getvalue(), mtime=0))


def files_below(folder):
    return [p for p in folder.rglob("*") if p.is_file() and "__pycache__" not in p.parts]


def main():
    assert OUT.is_dir(), OUT
    # Original control and rejected source are independent of the live checkout.
    source_archive("control-sources.tar.gz", [(p, str(p.relative_to(OUT / "control"))) for p in files_below(OUT / "control")])
    source_archive("e2-sources.tar.gz", [(p, "src/" + str(p.relative_to(OUT / "e2/source"))) for p in files_below(OUT / "e2/source")])
    source_archive("combined-sources.tar.gz", [(p, "src/" + str(p.relative_to(OUT / "btb/source-e2-plus-btb"))) for p in files_below(OUT / "btb/source-e2-plus-btb")])
    current = []
    for folder in ["src", "test", "tools", "formal", "boards/tangnano20k", ".github"]:
        current.extend((p, str(p.relative_to(ROOT))) for p in files_below(ROOT / folder))
    for name in ["simple-risc.cabal", "cabal.project", "cabal.project.freeze", "docs/2026-10-30-STRUCTURAL-EXPERIMENTS.md", "docs/2026-10-30-STRUCTURAL-VARIANTS.md"]:
        current.append((ROOT / name, name))
    source_archive("retained-sources.tar.gz", current)
    write_json(HERE / "source-checkpoint.json", {name: sha(p) for p, name in current})
    for variant in ["e2", "btb-only"]:
        before = (OUT / "control/src/SdramPipeline.hs").read_text().splitlines(True)
        after = (OUT / "e2/source/SdramPipeline.hs" if variant == "e2" else ROOT / "src/SdramPipeline.hs").read_text().splitlines(True)
        diff = list(difflib.unified_diff(before, after, fromfile="control/src/SdramPipeline.hs", tofile=variant + "/src/SdramPipeline.hs"))
        if variant == "e2":
            for name in ["SimpleRisc.hs", "SimpleRisc/Types.hs"]:
                diff.extend(difflib.unified_diff((OUT / "control/src" / name).read_text().splitlines(True), (OUT / "e2/source" / name).read_text().splitlines(True), fromfile="control/src/" + name, tofile="e2/src/" + name))
        (HERE / (variant + ".diff")).write_text("".join(diff))

    # Top-level receipts, orchestration and exact console logs.
    for p in OUT.iterdir():
        if p.is_file() and p.suffix in {".json", ".log", ".py", ".sh", ".err"}:
            copy(p, "receipts/" + p.name)
    copy(ROOT / "docs/evidence/2026-10-30-structural/tool-versions.json", "tool-versions.json")
    for p in files_below(OUT / "formal"):
        copy(p, "formal/" + str(p.relative_to(OUT / "formal")))

    # Physical diagnostics include raw bytes, original per-run runner/protocol
    # snapshots and exact guest images, not just a success summary.
    physical = [p for p in OUT.iterdir() if p.is_dir() and (p.name.endswith("-probe") or p.name.endswith("-restore54") or p.name in {"phase112-zero", "phase112-ones", "btb48-diagnostic", "btb60-diagnostic", "btb60-raw"})]
    for folder in physical:
        for p in files_below(folder):
            copy(p, "physical/" + str(p.relative_to(OUT)))
    for folder in ["readback-rom", "rom-control"]:
        for p in files_below(OUT / folder):
            copy(p, "rom/" + str(p.relative_to(OUT)))

    builds = ["e2/hardware-48", "btb-only/hardware-48", "btb-only/hardware-60-p112", "raw-48", "raw-60", "raw-60-p112"]
    build_names = {"build.tcl", "clocks.sdc", "pins.cst", "pll.v", "pipeline_top.v", "memory.v", "sdram-io-model.json", "bootrom-sdram.hex", "sdram_test.vg", "sdram_test_syn.rpt.html", "sdram_test_syn_resource.html", "sdram_test_syn_rsc.xml", "sdram_test_tr_content.html", "sdram_test.tr", "sdram_test.rpt.txt", "sdram_test.log"}
    for folder in builds:
        for p in files_below(OUT / folder):
            if p.name in build_names:
                copy(p, "builds/" + folder + "/" + str(p.relative_to(OUT / folder)))
        image = OUT / folder / "impl/pnr/sdram_test.fs"
        write_json(HERE / "builds" / folder / "bitstream.json", {"sha256": sha(image), "bytes": image.stat().st_size, "original_path": str(image.relative_to(ROOT))})

    # Keep RTL and measured run receipts, omit Verilator objects/executables.
    for variant in ["e2", "btb", "btb-only"]:
        for generated in ["generated", "generated-im"]:
            folder = OUT / variant / generated
            if folder.exists():
                for p in folder.rglob("*.v"):
                    copy(p, "generated/" + str(p.relative_to(OUT)))
        for run in ["perf", "rtl-im", "rtl-imc", "rtl-imc-cdc", "raw-im", "raw-imc"]:
            folder = OUT / variant / run
            if folder.exists():
                for p in files_below(folder):
                    if "obj" not in p.relative_to(folder).parts and (p.suffix in {".json", ".log", ".hex", ".bin", ".elf", ".S", ".ld"}):
                        copy(p, "simulation/" + str(p.relative_to(OUT)))
    for name in ["raw-rtl-control", "pins60-exact-p135-tac11", "pins60-exact-p112.5-tac11"]:
        for p in files_below(OUT / name):
            if "obj" not in p.relative_to(OUT / name).parts and p.suffix in {".json", ".log", ".hex", ".bin", ".elf", ".S", ".ld"}:
                copy(p, "simulation/" + str(p.relative_to(OUT)))
    shared = {}
    for name in ["base.bin.gz", "base.elf.gz", "dtree-oracle.py"]:
        p = ROOT / "docs/evidence/2026-10-28-controlled-benchmark" / name
        shared[str(p.relative_to(ROOT))] = sha(p)
    artifacts = {str(p.relative_to(HERE)): sha(p) for p in files_below(HERE) if p != HERE / "manifest.json"}
    write_json(HERE / "manifest.json", {"base_revision": "44fcaf0ef95d01433a299bac5a19ec20db6b9c86", "git_status": subprocess.check_output(["git", "status", "--short", "--branch"], cwd=ROOT, text=True), "artifacts": artifacts, "shared_inputs": shared, "source_checkpoint": "source-checkpoint.json", "scope": "Local structural-variant checkpoint; hosted CI and full SDRAM I/O/PVT signoff are not claimed."})
    print(f"Collected {len(artifacts)} artifacts, {len(current)} source files")


if __name__ == "__main__":
    main()
