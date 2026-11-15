"""Collect the matched vendor reports. Run from any directory after routing."""
import gzip
import hashlib
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / "boards/tangnano20k/sdram"))
import path_census

TRIAL = ROOT / "output/tangnano20k/core-feedback-20261113"
CONTROL = ROOT / "output/tangnano20k/im-sweep-20261108"
path_census.PIPE_STAGE["pFetchIndex"] = "fetch"


def collect(directory, layout):
    area = (directory / "impl/pnr/sdram_test.rpt.txt").read_text()
    resources = {}
    for label in ("Logic", "Register", "CLS", "BSRAM", "DSP"):
        value = re.search(rf"^\s*{label}\s*\|\s*([\d,.]+)/", area, re.M)[1].replace(",", "")
        resources[label] = float(value) if "." in value else int(value)
    log = (directory / "impl/pnr/sdram_test.log").read_text()
    failure = re.search(r"ERROR\s+\(PR0004\).*?([\d,]+) unrouted nets", log)
    if failure:
        return {**resources, "routed": False, "passes": False,
                "unrouted_nets": int(failure[1].replace(",", ""))}
    timing = (directory / "impl/pnr/sdram_test.tr").read_text()
    for clk in ("clk_memory", "clk_sdram"):
        freq = re.search(rf"^\s*\d+\s+{clk}\s+Generated\s+[\d.]+\s+([\d.]+)MHz", timing, re.M)
        assert float(freq[1]) == 48

    core = re.search(r"^\s*\d+\s+clk_core\s+([\d.]+)\(MHz\)\s+([\d.]+)\(MHz\)", timing, re.M)
    assert float(core[1]) == 87
    paths = path_census.parse_report(timing)
    setup = path_census.section(timing, "3.3.1 Setup Analysis Report", "3.3.2 Hold Analysis Report")
    arcs = re.findall(r"Arrival Data Path Delay: \(cell:\s*([\d.]+)[^\n]*\n\s*route:\s*([\d.]+)", setup)
    assert len(arcs) == len(paths) and paths
    for path, (cell, route) in zip(paths, arcs):
        path["cell_ns"], path["route_ns"] = float(cell), float(route)
        for end in ("from", "to"):
            path[end + "_stage"], path[end + "_field"] = path_census.classify(path[end], layout)
    paths.sort(key=lambda path: path["slack"])
    endpoints = {
        kind: int(re.search(rf"<Numbers of {kind} Violated Endpoints>:(\d+)", timing)[1])
        for kind in ("Setup", "Hold")
    }
    pulse = min(map(float, re.findall(r"MPW Summary:\s*Slack:\s*(-?[\d.]+)", timing)))
    fanout = path_census.section(timing, "3.5 High Fanout Nets Report", "3.6 Route Congestions Report")
    nets = re.findall(r"^\s*(\d+)\s+(\S+)\s+(-?[\d.]+)\s+([\d.]+)\s*$", fanout, re.M)
    congestion = path_census.section(timing, "3.6 Route Congestions Report", "3.7 Timing Exceptions Report")
    result = {
        **resources,
        "routed": True,
        "fmax": float(core[2]),
        "endpoints": endpoints,
        "pulse": pulse,
        "passes": not any(endpoints.values()) and pulse >= 0 and paths[0]["slack"] >= 0,
        "worst": paths[0],
        "reported_setup_paths": len(paths),
        "btb": next((p for p in paths if p["from_field"] == p["to_field"] == "btb table RAM"), None),
        "btb_read_address": next((p for p in paths if p["to_field"] == "btb table RAM" and p["end_pin"].startswith("ADB[")), None),
        "hazard": next((p for p in paths if p["to_field"] == "pDBlocked"), None),
        "m_slot_hazard": next((p for p in paths if p["from_field"] == "pMSlot" and p["to_field"] == "pDBlocked"), None),
        "failing_paths": [p for p in paths if p["slack"] < 0],
        "max_core_logic_fanout": max(int(n) for n, name, *_ in nets if name.startswith("core/")),
        "reset_fanout": next(int(n) for n, name, *_ in nets if name == "reset_sync[1]"),
        "max_grid_congestion": max(float(x) for x in re.findall(r"^\s*R\d+C\d+\s+([\d.]+)\s*$", congestion, re.M)),
    }
    return result


def archive(source, dest):
    dest.write_bytes(gzip.compress(source.read_bytes(), compresslevel=6, mtime=0))


def collect_checks(variant, dest):
    run = TRIAL / variant
    profile = "fresh-profile" if variant == "baseline" else "profile"
    measurements = {}
    for label, subdir in (("cpi", "cpi"), ("profile", profile)):
        report = (run / subdir / "results.json").read_bytes()
        result = json.loads(report)
        assert result["passed"]
        metrics = result["metrics"]
        measurements[label] = metrics
        (dest / (label + ".json")).write_bytes(report)
        (dest / (label + ".txt")).write_bytes((run / (subdir + ".log")).read_bytes())
    if variant != "baseline":
        for suite in ("guest", "loader", "reset"):
            report = (run / suite / "results.json").read_bytes()
            assert json.loads(report)["passed"]
            (dest / (suite + ".json")).write_bytes(report)
            (dest / (suite + ".txt")).write_bytes((run / (suite + ".log")).read_bytes())
        host = (run / "host.log").read_bytes()
        assert b"Test suite simple-risc-test: PASS" in host
        archive(run / "host.log", dest / "host.log.gz")
    return measurements


def main():
    results = []
    checks = []
    for variant in ("baseline", "btb", "hazard"):
        synth = CONTROL / "f87-p3" if variant == "baseline" else TRIAL / variant / "p3"
        layout = path_census.load_layout(synth / "layout.json")
        dest = HERE / variant
        dest.mkdir(exist_ok=True)
        (dest / "layout.json").write_bytes((synth / "layout.json").read_bytes())
        netlist = synth / "impl/gwsynthesis/sdram_test.vg"
        (dest / "netlist.sha256").write_text(hashlib.sha256(netlist.read_bytes()).hexdigest() + "\n")
        archive(netlist, dest / "sdram_test.vg.gz")
        (dest / "floorplan.txt").write_bytes((synth / "floorplan.log").read_bytes())
        rtl = CONTROL / "sdram_pipeline_risc.v" if variant == "baseline" else TRIAL / variant / "generated/SdramPipeline.topEntity/sdram_pipeline_risc.v"
        archive(rtl, dest / "sdram_pipeline_risc.v.gz")
        checks.append(collect_checks(variant, dest))
        for place in range(5):
            directory = TRIAL / variant / f"p{place}"
            if variant == "baseline" and place != 2:
                directory = CONTROL / f"f87-p{place}"
            row = collect(directory, layout)
            if row["routed"]:
                row["bitstream_sha256"] = hashlib.sha256((directory / "impl/pnr/sdram_test.bin").read_bytes()).hexdigest()
            results.append({"variant": variant, "placement": place, **row})
            dest_place = dest / f"p{place}"
            dest_place.mkdir(exist_ok=True)
            names = ["impl/pnr/sdram_test.rpt.txt", "impl/pnr/sdram_test.log", "build.tcl", "pins.cst", "clocks.sdc"]
            if row["routed"]:
                names.append("impl/pnr/sdram_test.tr")
            for name in names:
                source = directory / name
                archive(source, dest_place / (source.name + ".gz"))
    (HERE / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    assert checks[0] == checks[1] == checks[2], "workload metrics differ between variants"


if __name__ == "__main__":
    main()
