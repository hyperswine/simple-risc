# Cache model progress, eviction coverage and CI contracts

Kind: implementation and validation report. Applies to SimpleRisc and its
sibling FP-RISC board runner on 2026-10-28.

The cycle cache model now completes its waiting A2 read when a refill finishes,
updates MRU and permits logical advancement. The previous rule installed data
while retaining `rd(...,false,...)`, permanently holding the read. A required
cold-read completion witness and a deliberately stuck-fill control cover this
regression. Completion is an existential reachability check; it does not assume
that every possible memory schedule eventually completes.

Both cache models now use three tags for two ways. Seeded full-set searches
with opposite MRU values require the third tag to replace either non-MRU way,
preserve the retained line and, in the cycle model, complete the read. The cycle
model also makes cold-set victim equations disjoint and forwards retiring-read
MRU state into the next lookup.

The formal runner validates each named search in source order. Good safety
searches, faulty models and required progress/eviction witnesses each have an
explicit expected outcome. Aggregate result counts cannot hide a violated good
model by cancelling it against a missing negative-control counterexample.
Missing, reordered, incomplete and warning-producing searches fail, and a new
run clears the preceding success report, including when Maude is missing.
Seven gate regressions include actual
Maude mutations for swapped controls, missing refill completion and eviction
of the MRU way.

The transaction model exhausts 432 update-policy states and 702 invalidate-policy
states. The cycle safety searches retain their 16-transition bound and explore
710,033 update-policy states and 631,913 invalidate-policy states. The completion
and cycle eviction witnesses use a 12-transition bound. All 19 individual
search outcomes are checked. These remain abstract models, without an RTL
refinement proof or physical timing claim; see the [formal guide](../formal/README.md).

CI adds a separate `formal-and-rtl` job for model searches, gate regressions,
all 18 cache cases, clock-bridge simulations, fence-monitor controls and
ROM/preset tests. The Haskell job generates fresh IM and IMC pipeline Verilog
and executes the guest scoreboard with a two-way cache, including two fence
epochs and deliberate backend corruption. Logs and reports are uploaded even
when a job fails.

FP-RISC's runner now agrees with SimpleRisc's explicit `cache_ways: 1` and
`cache_line_bits: 12` preset metadata. Complete older manifests that omit both
fields retain their documented one-way geometry. Partial geometry, conflicting
values and unknown settings are rejected. Its regression loads the actual
SimpleRisc producer configuration, so the pinned cross-repository contract is
checked independently of the runner's own constant.

The [evidence manifest](evidence/2026-10-28-formal-cache/manifest.json) records
source hashes, formal searches and local validation results. Generated HDL and
executables remain in ignored `output/`; this change does not generate or
program a new Gowin bitstream.
