# Equalities as LUT trees: a negative result

Kind: core and cache change, measured on the frozen flow at 87 MHz across
the four placements, 2026-11-09. Step 1 of the
[amended proposal](2026-11-09-AMENDED-PROPOSAL.md), carried out on the
RV32IM canon (`6418ad2`) and **withdrawn**: the source is unchanged, this
page and its evidence are what the step produced.

## What was tried

The two paths that miss 87 MHz on the canon end in equality compares that
Gowin maps to ALU carry chains: the 8-bit BTB tag compare (an 8-cell chain
between the table's data output and the fetch pc) and the 5-bit
register-index compares of the hazard check (3-cell chains between the
selected `rd` and `pDBlocked`). A third, found in the same reports, is the
cache's MRU bypass compare of the core's address against the MRU write
index (an 11-cell chain, -0.026 ns at placement 0). The proposal's step 1
was to spell these so synthesis builds a LUT tree instead.

**Spelling matters.** Fifteen spellings of an 8-bit equality were
synthesized alone ([spellings.v](evidence/2026-11-09-equalities-as-luts/spellings.v),
[spellings.txt](evidence/2026-11-09-equalities-as-luts/spellings.txt)):

| Verilog | Cells |
|---|---|
| `a == b` | 7 ALU + 1 LUT3 (the chain) |
| `~\|(a ^ b)` (what Clash emits for `reduceOr (a xor b) == 0`) | 7 ALU + 1 LUT3: re-inferred as the chain |
| `~\|` on two halves kept apart with `syn_keep` | 6 ALU |
| `&(a ~^ b)`, `&(~(a ^ b))`, `(&(~(a ^ b))) == 1'b1` | 5 LUT4, two levels |
| `(~(a ^ b)) == 8'hff` | 7 ALU |
| 5 bits as `&(a ~^ b)` | 3 LUT4 |
| 11 bits as `&(a ~^ b)` | 7 LUT4 |

So the first attempt, `reduceOr`, changed nothing but seven cells (the
netlist census shows the same 56 equality chains plus two) and was
abandoned once synthesized; the measured candidate is the and-reduce form,
`reduceAnd (complement (pack a xor pack b)) == 1` in Clash for the BTB tag
and the six register-index compares, and `&(mru_index ~^ cpu_address[...])`
in `pipeline_cache.v`.

The netlist census confirms the chains went where they were aimed
([netlist-census.txt](evidence/2026-11-09-equalities-as-luts/netlist-census.txt)):
equality (mode 3) ALU cells 443 to 400 in 56 to 50 chains; one 8-cell
chain, six 5-cell chains and one 11-cell chain gone, at +77 LUT4
equivalents of logic (12,684 to 12,761). `cabal test` (74 and 8
properties), the cache benches (`check_cache_mru.py` 5, `check_pipeline_cache.py`
18) and the six Verilator pipeline checks of the CI recipe pass on the
changed RTL ([rtl-checks-and-reduce.txt](evidence/2026-11-09-equalities-as-luts/rtl-checks-and-reduce.txt)):
the change is functionally sound.

## Result

The same flow as the 8 November sweep (synthesis and placement 3 from
`build.sh` at 87 MHz, placer target 96, the `fprisc-81.plan` floorplan,
then placements 0, 1 and 4 with `pnr_only.sh` on that netlist;
[sweep.sh](evidence/2026-11-09-equalities-as-luts/sweep.sh),
[routes.txt](evidence/2026-11-09-equalities-as-luts/routes.txt)):

| Placement | Canon (6418ad2) | Equalities as LUT trees |
|---:|---|---|
| 0 | 86.71 MHz, -0.039 ns, 2 endpoints | 75.91 MHz, **-1.679 ns**, 30 endpoints |
| 1 | 88.30 MHz, +0.169 ns | 76.87 MHz, **-1.514 ns**, 23 endpoints |
| 3 | 87.78 MHz, +0.102 ns | 77.74 MHz, **-1.369 ns**, 17 endpoints |
| 4 | 86.98 MHz, -0.003 ns, 1 endpoint | 85.07 MHz, **-0.261 ns**, 4 endpoints |
| Pass | 2 of 4 | **0 of 4** |

Occupied slices 8,036 to 8,132 before, 8,048 to 8,120 after. The failing
structures are exactly the loops the change touched
([loop-census.txt](evidence/2026-11-09-equalities-as-luts/loop-census.txt)):

| Structure | Canon, worst over the four placements | LUT trees, worst over the four |
|---|---|---|
| BTB tag to fetch pc to BTB address | 7 levels, -0.039 ns | **9 levels**, -1.531 ns (14 of 14 paths fail at three placements) |
| hazard check into `pDBlocked` | 9 to 11 levels, -0.003 ns | **12 to 13 levels**, -1.679 ns |
| fetch pc to fetch pc | 7 levels, +0.42 ns | 9 levels, -1.191 ns |

## Why: the chain was never the cost

The arcs ([arcs.txt](evidence/2026-11-09-equalities-as-luts/arcs.txt))
show what the proposal got wrong. On this fabric a carry chain costs
0.549 ns for its first cell and 0.035 ns for each further cell, and the
carry between cells is routed at zero delay: the 8-cell BTB compare is
**0.79 ns** and the 3-cell register compare 0.62 ns, each with one routed
net in and one out. A two-level LUT tree has the same net in and out plus
one routed net between its levels, and every routed net on these loops is
1.0 to 2.4 ns. In the canon's BTB loop at placement 0 the chain is 0.79 of
the 11.5 ns data path; the LUT-tree version of the same loop at placement 3
is nine LUTs and nine nets, 8.5 ns of routing against the canon's 7.1.

The proposal counted the chain as "a cell per bit" and read Gowin's
"Logic Level: 7" as if the chain were three of them. It is not: Gowin's
level count and its delay model both treat the chain as roughly one slow
cell, which is what it is. The chain's real cost, placement as a column,
is small for 8 cells (two CLS) and the column does not stretch the two nets
around it any more than a LUT would. **An equality up to 11 bits is
cheaper as a chain than as any LUT tree on this part.** The inverse rule
holds for the adders: the 30-cell `aPlusImm` chain on the worst E1-to-D
path is 1.6 ns, which no LUT structure would beat either.

A second data point from the abandoned first attempt: a netlist that
differs from the canon by seven cells, with every chain re-inferred, routed
at placement 3 to -1.140 ns (79.15 MHz) where the canon has +0.102. The
limiting structure was the same fetch-to-BTB loop at the same 7 levels,
with 8.8 ns of routing against 7.1. The canon's 87 MHz placement-3 margin
is a draw, as the loop census said of placement margins generally: any
change to the netlist re-rolls it.

## What this does to the plan

- **Step 1 is withdrawn.** No equality in the core should be rewritten as
  a LUT tree; where Gowin picks a chain it is the right structure. The
  `same` helper and the cache rewrite are not in the tree.
- **The loops' cost is their routed nets, not their cells.** Each of the
  BTB loop's four nets between the chain and the table address is 1.0 to
  2.4 ns; the cells in between (`hit`, the target/pc+4 select, the
  redirect select) are 0.25 to 0.56 ns each. What shortens the loop is
  fewer nets after the compare: `hit` is a 70-fanout net that goes through
  three more LUT levels before the table address. Computing both candidate
  addresses (`btbIndex` of the stored target and of pc + 4) ahead of `hit`
  so the compare's output is the last select, and giving the redirect its
  own stage of the select, would take two nets out of the loop. That is a
  structural change to the fetch stage and needs the guest; it replaces
  step 1 in the plan.
- **Step 2 (hazard inputs a stage earlier) stands**, on the same
  reasoning: it removes the three selection LUTs and their nets before the
  compare, not the compare.
- **The margin method stands.** Four placements at the target clock, judged
  by pass count and worst structure, caught this in one sweep; a single
  placement would have been read as noise either way.

## Evidence

[evidence/2026-11-09-equalities-as-luts/](evidence/2026-11-09-equalities-as-luts/):
`spellings.v` and `spellings.txt` (the fifteen spellings and their cells),
`netlist-census.txt` (equality chains in the three netlists),
`routes.txt` (the nine routes), `loop-census.txt` (per-structure census of
the canon and the candidate at the four placements), `arcs.txt` (the cell
arcs of the worst two paths at canon placements 0 and 4 and candidate
placements 3 and 0), `rtl-checks-and-reduce.txt`, `sweep.sh`. Reports under
`output/tangnano20k/lut-eq-and-20261109/` (the candidate) and
`output/tangnano20k/lut-eq-20261109/` (the abandoned xor-reduce netlist,
placement 3 only).
