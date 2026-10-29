# Queue storage and held-effect ownership

This continues the [controlled structural variants](2026-10-30-STRUCTURAL-VARIANTS.md).
The two-entry expanded instruction queue is evaluated independently on top of
the accepted separate-BTB source. Queue payload storage can change only with
an explicit ownership contract; freezing a token while overwriting the payload
it owns is incorrect.

## Array contracts

| State | Ownership and reads | Writes and collision rule | Cancellation and hold |
|---|---|---|---|
| Expanded F queue, two `Fetched` entries | `pFRead`, `pFWrite`, `pFCount`; only the counted entries are owned. The registered head supplies D and RF source indices. | A writes only when the old count is below two. At count one, write differs from read. At count two, a simultaneous pop does not permit a push until the next clock. | Redirect, handover and fence empty the tokens. During a hold, tokens freeze; a physical write into a free slot is invisible and the final value is rewritten on the advance edge. |
| Raw queue, four `Fetched` entries | Modulo-eight read/write counters address four slots. C assembly may read both the head and its successor; the arrival can bypass either read. | An in-flight return writes the current write slot. Queued plus in-flight words never exceed four. A return therefore cannot overwrite an owned word in a legal state; bypassed data may leave an unowned payload behind. | Tokens and in-flight positions freeze with the logical memory port. Cancellation clears ownership and stale returns. A separate implementation must preserve the two-read/arrival-bypass and straddle rules before moving data writes. |
| In-flight fetch metadata, four `Maybe (PC, predicted PC)` entries | Fixed-latency positions determine which returned memory word belongs to which prediction. The external cache has a longer logical return latency than BRAM. | A new entry or bubble shifts in on every logical advance. This is not a single-address queue write; blindly substituting single-port RAM changes its semantics. | All positions freeze on cache hold and are cleared on cancellation. A circular redesign needs explicit age/epoch and latency accounting. |
| D/E1/E2/M payloads | A valid stage token owns its current payload until advance or cancellation. Forwarding and effect creation read those owned values. | Local next-state functions preserve payloads when the stage cannot advance. | These payload registers keep their common hold enable. The free-slot queue rule does not apply to occupied execution stages. |

`Fetched` is 133 bits in the host metadata, so the logical raw/F arrays are
532/266 bits and in-flight metadata is 260 bits. These are packed widths,
not resource predictions: synthesis removes duplicated/constant fields.
The board already uses 38 of 46 BSRAM blocks. A tiny array with asynchronous
head/successor reads is not automatically a profitable block-RAM conversion.

The accepted 48 MHz netlist has 264 direct-Q mapped raw-queue flops (66 per
bank), 264 expanded-queue flops (132 per bank), and 140 in-flight flops. The
raw queue's duplicate/constant fields are already removed. Its four banks
already have separate 66-load enables. These counts use the explicit
`pipeState=Pipe` width-checked binding and direct Q names; merged/renamed
aliases and surrounding control/selection logic are not attributed as array
cost. `array-register-inventory.json` preserves the exact netlist/layout hashes,
field ranges and enable counts. The broader timing/resource comparison,
rather than packed width alone, determines acceptance.

## Expanded queue experiment

In the archived candidate, `expandFetched` is factored out of the logical CPU without changing its
decompression, source-use, raw instruction, size or prediction semantics.
`expandedQueueWrite` uses registered A, count and write index to offer the
expanded payload to two independent `fQueueStorage` banks. No global hold or
fast/slow mode selector reaches their enables. The payload mirror is stripped
from `pipeState` and injected from physical storage into the running machine.

The invariant compares **owned entries**, rather than all storage bytes. A
free slot may contain a newer speculative payload than the reference while
held; it becomes owned only on the edge that also installs the final offered
value. Cancellation discards the ownership tokens, so an early write cannot
resurrect a cancelled instruction. Reset clears storage and tokens together.

The actual-bank Haskell property explores 200 randomized sequences of up to
120 operations with push/pop, arbitrary offered values, holds, cancellation
and synchronous production-domain reset. Offered data may change while held,
which is stronger than the registered-A implementation requires. The finite
Maude model checks the same visible-entry contract with two payload values;
writing the owned slot or failing to install the final write yields a
counterexample. A hold that changes only an unowned slot is reachable, with
a no-hold mutant that cannot reach that witness. These checks specify the
storage contract; they do not prove equivalence of synthesized RTL.
After the timing rejection, the production top is restored to BTB-only. The
experimental bank implementation and expansion helper live in the test-only
`FQueueVariant` module; normal hardware does not instantiate them. The full
candidate source, generated RTL and its original property remain archived.

## External effects during holds and cancellation

The generated RTL fixture already checks masked stores, self-modifying code,
fence/refetch epochs, eight timer interrupts across misses, Ctrl-C during a
long hold, restart through ROM, and exact UART markers `P` then `R`. Unexpected
or duplicated UART markers fail. Counters must count physical held clocks
while retirement remains bounded. Named observation ports make these checks
independent of the packed Clash layout.

The extended fixture adds eight owned stores with unique PCs/addresses and a
younger store after a taken jump. It separately counts:

- Architectural commit at each owned PC, qualified by logical advance.
- Backend acceptance of each owned memory write, where an identical replay
  would be observable even though final RAM remains unchanged.
- Held clocks at an owned PC or request, required to be nonzero.
- Any backend acceptance of the cancelled store, required to remain zero.

The fixture first fills the four-entry write queue with eight ordinary stores.
Coverage counts holds at an owned PC or while its owned request is stalled
in the cache's logical port; the count must be nonzero. This covers both
pipeline freeze and delayed write acceptance without requiring them to occur
in the same physical cycle.

The normal guest must produce exactly one commit and one accepted store per
owned PC/address, with the exact payload and mask. The checker runs two real guest
mutations: replacing padding with a duplicate store and replacing the skip
jump with a NOP. The effect monitor must reject them specifically. Mutation
patching preserves surrounding halfwords for straddling RV32C instructions.
The existing corrupted-read-beat control must also fail at its expected stage.

These tests establish the exercised paths and their coverage counts. They
are not exhaustive interrupt/reset interleaving proofs or an ISA compliance
certificate. The separate abstract models, Haskell properties, fresh RTL and
physical board evidence retain their distinct scopes.

## Routed result and decision

| Fixed 48 MHz / phase 135° | Logic | Registers | CLS | BSRAM | Reported Fmax, MHz | Setup slack, ns |
|---|---:|---:|---:|---:|---:|---:|
| Accepted BTB-only control | 14,426 | 5,308 | 8,508 | 38 | 80.779 | +8.454 |
| Separate expanded queue | 14,649 | 5,308 | 8,397 | 38 | 73.965 | +7.313 |

DSP use remains 3.5. There are no setup/hold endpoint violations at 48 MHz.
The candidate saves 111 CLS but adds 223 logic cells, saves no registers and
reduces reported Fmax by 8.44%. It is rejected as the default. The worst
reported path is again a CE endpoint, from the synchronized memory reset
through four logic levels: 1.865 ns cell delay and 11.388 ns route delay, with
a 4,143-load source. Leading endpoint counts are 14 CE / 11 D. Separating this
small array has moved the limiting path rather than providing a timing win.

This is one controlled route, not a seed distribution. It does not establish
that every queue split or alternate RAM implementation is worse. It does
provide a reason to prioritize the measured fetch/BTB next-PC D cone over
blindly splitting another small array. The candidate is not programmed onto
the board because it fails the timing/resource acceptance tradeoff. The
original 54 MHz board image remains installed.

## Validation result

All 68 processor and 8 support properties pass after the production source
is restored. The six Maude models pass 29 individually attributed searches,
including both storage models' broken controls and hold witnesses. The
candidate's full IM, IMC and IMC/CDC generated-RTL guest checks pass; each
rejects corrupt data, an identical duplicate store and the wrong-path store.
The restored BTB-only IMC control passes the same final fixture. Owned-effect
hold coverage is 108 clocks for the IM candidate, 125 for the IMC candidate
and BTB control, and 191 for the IMC/CDC candidate. These are the final
eight-owned-store fixture counts, superseding earlier single-store probes.
The restored BTB-only IM control also passes the Icarus CI simulator path,
including all three specific negative controls and 108 held-effect clocks.

The candidate's frozen classifier passes the independent oracle and every
metric equals the BTB-only control, including 145,460,221 measured-window
cycles, 8,450,881 held cycles, 260,094 fills, 39,517,185 pipeline commits and
5,364,322 redirects. There is no same-clock throughput gain. Source, RTL,
reports and positive/negative receipts are in the
[queue evidence bundle](evidence/2026-10-30-structural-queues/README.md).
Hosted CI and new physical acceptance of this rejected candidate are not
claimed. The new effect controls run automatically in the existing CI guest
checks; the experimental bank property and new Maude model are also in CI.
