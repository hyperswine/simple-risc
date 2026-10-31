"""Root causes of a path census (path_census.py --json): failing endpoints per
cause at 96, 84 and 72 MHz, and the Fmax left as causes are removed in order.
The estimate ignores re-placement and sees only the paths the report lists."""
import json, collections, sys
d=json.load(open(sys.argv[1])); P=10.4167
paths=d['detail']
def cause(p):
    f=p['from']; ce=p['end_pin']=='CE'
    if 'machine_0_2076_' in f: return 'hold enable via cpuInRom (Ctrl-C break)'
    if 'machine_0_11015_' in f: return 'cpuFast fast/slow select'
    if f.startswith('core/machine_0_'): return 'other machine state (phase, interrupt, muldiv)'
    if p['from_stage']=='cache' or p['to_stage']=='cache' or p['to_stage']=='mem': return 'cache'
    if p['to_stage'] in ('fetch','btb','A','F') or p['from_stage'] in ('fetch','btb','A'): return 'front end (fetch, BTB, A, F)'
    if p['to_field'].startswith('M.') or p['to_stage']=='M': return 'into M'
    if p['to_stage'] in ('E1','E2','D') or p['from_stage'] in ('D','E1','E2'): return 'decode/execute'
    return 'other: '+p['structure']
groups=collections.defaultdict(list)
for p in paths: groups[cause(p)].append(p)
print(f"{'cause':48} {'fail@96':>7} {'fail@84':>7} {'fail@72':>7} {'worst':>7} {'Fmax':>6}")
order=sorted(groups, key=lambda g:min(p['slack'] for p in groups[g]))
for g in order:
    xs=groups[g]; w=min(p['slack'] for p in xs)
    n=lambda t: len({p['to'] for p in xs if p['slack']<t})
    print(f"{g:48} {n(0):7} {n(P-1000/84):7} {n(P-1000/72):7} {w:7.3f} {1000/(P-w):6.1f}")
print('\nremoving causes in order (estimate, no re-placement):')
left=set(order)
for g in order:
    left.discard(g)
    rest=[p for c in left for p in groups[c]]
    if not rest:
        print(f"  without {g:46} -> no reported path left")
        break
    w=min(p['slack'] for p in rest)
    print(f"  without {g:46} -> worst {w:7.3f}  Fmax {1000/(P-w):6.1f}")
