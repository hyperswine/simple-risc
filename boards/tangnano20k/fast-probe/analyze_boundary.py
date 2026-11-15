#!/usr/bin/env python3
"""Check whether failed snapshots contain per-bit N / N+1 mixtures.
This is a diagnostic after a failure, never an alternative acceptance rule.
"""
from functools import lru_cache
import json
from pathlib import Path
import sys
from check_board import advance
advance=lru_cache(None)(advance)

source=Path(sys.argv[1])
report={}
for test in json.loads(source.read_text())['tests']:
    if test['frequency_mhz']!=621: continue
    report[str(test['placement'])]=[
        [offset for offset in (-2,-1,0,1,2)
         if all(((int(s['state'],16)>>bit)&1)==((advance(s['steps']+offset)>>bit)&1)
                for s in test['samples'])]
        for bit in range(32)]
print(json.dumps(report,indent=2))
