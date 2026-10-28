# Executable Maude safety models

These models are small, deliberate abstractions for exploring safety properties
with Maude's exhaustive state search. They complement the Haskell differential
tests and generated-RTL simulations; they are not yet a proof that the Verilog
implements these abstractions.

Run all searches and require every negative control to produce a counterexample:

```sh
python3 formal/check_formal.py
```

Logs go to `output/formal/`. The runner fails on Maude warnings, unexpected
search counts, a violated good model, or a negative control that finds no bug.

## Cache coherence

`cache_coherence.maude` models one set with two tags, three values, two ways,
MRU replacement, and both write-update and write-invalidate policies.
Architectural memory changes immediately on each accepted store. Reads,
writes, hits, misses, and replacement can interleave arbitrarily at transaction
boundaries.

The safety predicate rejects:

- a valid cached line whose value differs from current architectural memory;
- two valid ways containing the same tag.

The good write-update search exhausts 63 states and the write-invalidate search
126 states without a violation. `badWay1` suppresses a Way 1 store update and
produces a stale cached-line counterexample.

The transaction abstraction is supplemented by the cycle-stepped model below.
It still does not cover same-address BSRAM collisions, SDRAM clock crossing, or
metastability.

## Cycle-stepped two-way cache

`cache_cycle.maude` models one set, two tags, two values, two ways, a request
slot, A1/A2, a two-entry posted-write queue, and a four-beat refill backend.
Read misses hold the logical pipeline while writes and refill beats continue.
Architectural read data includes older queued stores; backing memory catches up
only when a queued write completes.

The safety predicate rejects:

- cached data that disagrees with architectural memory, including queued stores;
- duplicate tags in the two ways;
- a refill outstanding to a line with a queued store;
- a backend write that does not match the queue head.

Both good policies explore 59,530 states to a bound of 16 control transitions
without a violation. `badWay1` starts with a valid Way-1 line and isolates a
missed store update. `noDrain` permits a refill beneath an older queued store.
Both produce counterexamples.

This is a bounded, cycle-stepped **control abstraction**, not an unbounded or
cycle-exact RTL proof. A line has one abstract value even though refill
completion is checked over four beats; byte masks, simultaneous nonblocking
assignments, BSRAM read-during-write behavior, and forwarding are left to RTL
simulation. Memory need not eventually complete: the searches establish safety
within the bound, not liveness.

## Instruction-fence safety

`instruction_fence.maude` models self-modifying stores plus current, prefetch,
target, and next instruction buffers. Buffered instructions may be stale before
a fence. `FENCE.I` must discard all four buffers and order subsequent fetches
after older stores; a post-fence stale buffer violates safety.

The good model exhausts 2,824 states without a violation. `noFlush` marks the
fence ordered but retains buffers and produces a stale-instruction
counterexample. This frontend model assumes the coherent unified memory/cache
checked above. It does not model ordinary `FENCE` ordering for an external
master, which the current single-master core does not provide.

## Branch-prediction safety

`branch_prediction.maude` allows a correct or aliased/wrong prediction, a
younger speculative store, branch resolution, a compressed-straddle refetch
bubble, and in-order commit. Its safety predicate rejects:

- commit of a store fetched on the wrong path;
- architectural retirement of the zero-size refetch bubble.

Both good searches exhaust four states without a violation. Removing wrong-path
flush produces a bad store commit; retiring the bubble produces a retirement
counterexample. This is an architectural-safety model, not a model of BTB hit
rate or timing.

## RTL-mirrored assertions

`boards/tangnano20k/sdram/pipeline_cache.v` contains simulation-only immediate
assertions over the actual RTL. They check queue count/pointer agreement, stable
request/A1/A2 state during holds, no refill under a same-line queued store, no
unexpected or duplicate refill beats, complete four-beat completion, and no
duplicate tag installed in both ways. They supplement rather than replace the
independent read/write reference scoreboard.

Run them with:

```sh
python3 boards/tangnano20k/sdram/check_pipeline_cache.py
python3 boards/tangnano20k/sdram/check_fence_assertion.py
```

All 18 cache cases pass. Three assertion-specific negative controls remove
same-line draining, complete a refill after three beats, and duplicate a beat.

`pipeline_fence_assertions.v` adds a CPU-level `FENCE.I` epoch monitor to the
executing-guest testbench. After a fence commits, it requires all pre-fence
pipeline valid/queue state to be empty, a new memory fetch at the fence's
sequential PC, and that PC on the first subsequent commit. Its unit tests cover
a clean epoch, reject a stale commit before refetch, and reject retained
pipeline state even when a matching-PC fetch occurs. Both compressed and
uncompressed two-way executing-guest configurations verify two fence epochs and
retain their deliberate corrupt-backend rejection.

The CPU monitor is simulation-only and depends on current generated-RTL field
names and bit positions; those connections must be revalidated when Clash output
changes. It checks the exercised fence epochs, not all possible programs or a
formal refinement between Maude and RTL.

## Useful next models

1. **Refine data and edge semantics.** Represent four independent words and
   byte lanes, then combine request advancement, queue push/pop, and backend
   events into exact clock-edge steps. Add refill-forwarding and BSRAM collision
   mutants, or discharge those properties directly over RTL with SMT.
2. **Compressed frontend refinement.** Model halfword PCs, a two-word fetch
   FIFO, BTB index/tag/slot metadata, E2 resolution, redirects, and `minstret`.
   Compare committed architectural traces with a sequential RV32IMC reference,
   including traps, interrupts, and `FENCE.I`. Exhaust small programs with
   deliberate BTB aliases and straddling instructions.
3. **Measure before expanding.** Increase tags, values, queue depth, bound, and
   program length only after recording state growth. Use temporal properties for
   eventual refill/completion only with an explicit fair-memory assumption.

A manually translated Maude model and mirrored simulation assertions improve
confidence but do not establish complete Verilog correctness or physical timing.
