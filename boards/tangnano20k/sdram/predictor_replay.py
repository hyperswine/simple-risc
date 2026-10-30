#!/usr/bin/env python3
"""Replay a committed control-flow trace through branch-predictor models.

The trace comes from run_perf.py --split --control-trace FILE: one line per
committed branch or jump, "pc word next" in hex, word already expanded from
its compressed form. Instruction sizes come from the image (RAM at
0x80000000), so a call's return address is exact.

The 'current' model mirrors the core's BTB: 8 direct-mapped entries indexed
by pc[4:2] with an 8-bit tag pc[12:5] and a halfword slot bit; a taken branch
or jump installs its target, a mispredicted hit clears the entry, nothing
else predicts taken. Its mispredict counts by kind are checked against the
core's measured redirect kinds before any variant is trusted. It ignores the
one-cycle install delay, straddle refetches and non-control aliases, which
the measured run reports separately.

Variants change one thing at a time: table size, associativity, a return
address stack, two-bit direction counters (the BTB then only supplies the
target), and JAL resolved in decode (its target is in the word).
"""

import argparse
import json
from array import array
from pathlib import Path

RAM = 0x8000_0000

KINDS = ('branch_not_taken', 'branch_taken', 'branch_target', 'jal', 'return', 'jalr')


def load_trace(path):
    pcs, words, nexts = array('I'), array('I'), array('I')
    with open(path) as f:
        for line in f:
            pc, word, nxt = line.split()[:3]
            pcs.append(int(pc, 16))
            words.append(int(word, 16))
            nexts.append(int(nxt, 16))
    return pcs, words, nexts


def sizes_for(pcs, image):
    out = array('B')
    for pc in pcs:
        offset = pc - RAM
        # Outside the image (the boot ROM's jump) every instruction is 32-bit.
        out.append(2 if 0 <= offset < len(image) and (image[offset] & 3) != 3 else 4)
    return out


def replay(pcs, words, nexts, sizes, entries=8, ways=1, ras=0, counters=False,
           jal_in_decode=False, return_by_ras_only=False, train_straddle=False,
           ras_needs_btb=False):
    """Return mispredicts by kind, plus 'jal_decode' redirects resolved early."""
    sets = entries // ways
    index_mask = sets - 1
    # Each set: list of [valid, tag, slot, target, counter]; LRU order (front = newest).
    table = [[] for _ in range(sets)]
    stack = []
    miss = dict.fromkeys(KINDS, 0)
    miss['jal_decode'] = 0
    for i in range(len(pcs)):
        pc, word, nxt, size = pcs[i], words[i], nexts[i], sizes[i]
        opcode = word & 0x7f
        rd = (word >> 7) & 0x1f
        rs1 = (word >> 15) & 0x1f
        link = pc + size
        taken = nxt != link
        # Entries are keyed on the instruction's last halfword, as the core's
        # slot bit is; for a straddling instruction that is in the next word.
        straddle = (pc >> 1) & 1 == 1 and size == 4
        end = pc + size - 2
        word_pc = end >> 2
        index = word_pc & index_mask
        tag = (word_pc >> (sets.bit_length() - 1)) & 0xff
        slot = (end >> 1) & 1
        entries_here = table[index]
        found = None
        for entry in entries_here:
            if entry[1] == tag and entry[2] == slot:
                found = entry
                break
        is_return = opcode == 0x67 and rd == 0 and rs1 in (1, 5)
        is_call = opcode in (0x6f, 0x67) and rd in (1, 5)
        # Prediction.
        if ras and is_return and (not ras_needs_btb or found is not None):
            predicted = stack[-1] if stack else link
        elif found is not None and (not counters or found[4] >= 2):
            predicted = found[3]
        else:
            predicted = link
        if predicted != nxt:
            if opcode == 0x63:
                kind = 'branch_not_taken' if not taken else ('branch_target' if found is not None and predicted != link else 'branch_taken')
            elif opcode == 0x6f:
                kind = 'jal'
            elif is_return:
                kind = 'return'
            else:
                kind = 'jalr'
            if kind == 'jal' and jal_in_decode:
                miss['jal_decode'] += 1
            else:
                miss[kind] += 1
        # Return stack update (a call pushes after a possible pop for co-routines: none here).
        if ras:
            if is_return and stack:
                stack.pop()
            if is_call:
                stack.append(link)
                if len(stack) > ras:
                    stack.pop(0)
        # Table update. The core never installs a 32-bit instruction that
        # starts in a word's upper half (its fetch word holds only half of it).
        if ras and is_return and return_by_ras_only and not ras_needs_btb:
            continue
        if straddle and not train_straddle:
            if found is not None and predicted != nxt:
                entries_here.remove(found)
            continue
        if counters:
            if found is not None:
                found[4] = min(3, found[4] + 1) if taken else max(0, found[4] - 1)
                if taken:
                    found[3] = nxt
                entries_here.remove(found)
                entries_here.insert(0, found)
            elif taken:
                entries_here.insert(0, [True, tag, slot, nxt, 2])
                del entries_here[ways:]
        else:
            if taken:
                if found is not None:
                    found[3] = nxt
                    entries_here.remove(found)
                    entries_here.insert(0, found)
                else:
                    entries_here.insert(0, [True, tag, slot, nxt, 0])
                    del entries_here[ways:]
            elif found is not None and predicted != nxt:
                entries_here.remove(found)
    return miss


def kind_counts(pcs, words, nexts, sizes):
    counts = dict(branch=0, branch_taken=0, jal=0, call=0, return_=0, jalr=0)
    for i in range(len(pcs)):
        word = words[i]
        opcode, rd, rs1 = word & 0x7f, (word >> 7) & 0x1f, (word >> 15) & 0x1f
        if opcode == 0x63:
            counts['branch'] += 1
            counts['branch_taken'] += nexts[i] != pcs[i] + sizes[i]
        elif opcode == 0x6f:
            counts['jal'] += 1
        elif rd == 0 and rs1 in (1, 5):
            counts['return_'] += 1
        else:
            counts['jalr'] += 1
        counts['call'] += opcode in (0x6f, 0x67) and rd in (1, 5)
    return counts


VARIANTS = [
    # Each step adds one thing to the step before it.
    ('A current: 8 entries', dict()),
    ('B A + 8-deep return stack (returns not in the BTB)', dict(ras=8, return_by_ras_only=True)),
    ('C B + straddling instructions installed', dict(ras=8, return_by_ras_only=True, train_straddle=True)),
    ('D C at 16 entries', dict(entries=16, ras=8, return_by_ras_only=True, train_straddle=True)),
    ('E C at 32 entries', dict(entries=32, ras=8, return_by_ras_only=True, train_straddle=True)),
    ('F C at 64 entries', dict(entries=64, ras=8, return_by_ras_only=True, train_straddle=True)),
    ('G F + 2-bit counters', dict(entries=64, ras=8, return_by_ras_only=True, train_straddle=True, counters=True)),
    ('H G at 256 entries', dict(entries=256, ras=8, return_by_ras_only=True, train_straddle=True, counters=True)),
    # One change at a time from A, for comparison.
    ('A at 16 entries', dict(entries=16)),
    ('A at 64 entries', dict(entries=64)),
    ('A, 8 entries 2-way', dict(entries=8, ways=2)),
    ('A + straddling instructions installed', dict(train_straddle=True)),
    ('A + 4-deep return stack', dict(ras=4, return_by_ras_only=True)),
    # Buildable: a return is recognised only through its own BTB entry.
    ('R1 A + 8-deep return stack, returns found through the BTB', dict(ras=8, ras_needs_btb=True)),
    ('R2 R1 + straddling instructions keyed on their last word', dict(ras=8, ras_needs_btb=True, train_straddle=True)),
    ('R3 R2 at 16 entries', dict(entries=16, ras=8, ras_needs_btb=True, train_straddle=True)),
    ('R4 R2 at 32 entries', dict(entries=32, ras=8, ras_needs_btb=True, train_straddle=True)),
    ('R5 R2 at 64 entries', dict(entries=64, ras=8, ras_needs_btb=True, train_straddle=True)),
]


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('trace', type=Path)
    p.add_argument('image', type=Path, help='the guest image loaded at 0x80000000')
    p.add_argument('--results', type=Path, help='run_perf results.json with redirect_kinds, to check the current model')
    p.add_argument('--json', type=Path, help='write the table here')
    a = p.parse_args()
    pcs, words, nexts = load_trace(a.trace)
    image = a.image.read_bytes()
    sizes = sizes_for(pcs, image)
    counts = kind_counts(pcs, words, nexts, sizes)
    print(f'{len(pcs):,} committed control instructions: ' + ', '.join(f'{k.rstrip("_")} {v:,}' for k, v in counts.items()))
    rows = []
    for label, options in VARIANTS:
        miss = replay(pcs, words, nexts, sizes, **options)
        total = sum(v for k, v in miss.items() if k != 'jal_decode')
        rows.append(dict(variant=label, options=options, mispredicts=total, **miss))
        print(f'{label:<56} {total:>10,}  ' + ' '.join(f'{k}={v:,}' for k, v in miss.items() if v))
    if a.results:
        measured = json.loads(a.results.read_text())['redirect_kinds']
        print('measured redirect kinds: ' + ', '.join(f'{k}: {v:,}' for k, v in measured.items()))
    if a.json:
        a.json.write_text(json.dumps(dict(counts=counts, variants=rows), indent=2) + '\n')


if __name__ == '__main__':
    main()
