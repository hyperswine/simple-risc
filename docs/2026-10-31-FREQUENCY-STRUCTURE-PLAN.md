# What holds the clock back: a measurement plan

Kind: plan, 2026-10-31. Follows the predictor work
([RETURN-STACK-AND-STRADDLE](2026-10-30-RETURN-STACK-AND-STRADDLE.md),
[BTB-64](2026-10-30-BTB-64.md), [BTB-128](2026-10-30-BTB-128.md)), which
left the core at IPC 0.355 and passing 60 MHz at every placement, with as
little as 0.07 ns to spare.

## Why

Every timing decision so far has looked at one worst path per build. That
path is the first of many and mostly shows where the placer put the trouble.
Going from 60 MHz to 80-100 MHz needs the whole picture: which structures fail
at those clocks, how far each is from passing, which of them are loops (whose
fix costs IPC), and what each fix is worth in Fmax x IPC.

The 50 paths the 128-entry build reports already spread over three places:
19 end in core pipe registers, 14 in the BTB block RAM and 17 in the cache.

## Items

1. **Path census at 81 and 99 MHz.** Build with the SDC clock at each
   frequency and thousands of reported paths (`SDRAM_CRITICAL_PATHS`). Map every
   failing path's start and end registers to pipeline fields with
   `pipeline-layout` and group them by structure: BTB loop, E2 redirect and
   flush, decode hazard, forwarding, hold enable, return stack, cache, memory.
   Per structure: failing endpoints, worst slack, logic levels, routing share.
2. **What-if builds.** Cut one structure at a time with `set_false_path` and
   rebuild: the Fmax that results is the ceiling once that structure is fixed.
3. **Loops versus feed-forward paths.** Mark failing paths whose end register
   feeds back into their own start. Feed-forward paths take a register stage
   cheaply; loops (BTB to next fetch pc, redirect to flush, hazard to stall,
   the hold enable) cost IPC to break and set the real ceiling.
4. **IPC price of an extra cycle in each loop.** Simulate a two-cycle BTB
   lookup, one more cycle from redirect to fetch, no E2 forwarding, and so on.
   With item 2 this gives Fmax x IPC for each fix. (Each restart cycle costs
   about 3.7% today.)
5. **Core and memory system apart.** Build the core with a stub memory port,
   and the cache plus SDRAM side with a stub core. The clock bridge already
   lets them run at different clocks.
6. **Routing and fill.** Routing is 67-75% of every worst path and slices are
   83-86% used. Report the fan-out of the hold enable, flush and stall nets,
   and rebuild with less logic (no predictor additions, or the boot ROM in
   block RAM) to see what congestion alone costs.
7. **SDRAM on the board.** Read capture fails above 60 MHz. Sweep the read
   phase at 66, 72 and 81 MHz on the board to learn whether faster memory is
   possible, or whether the core must outrun the SDRAM behind the bridge.

Items 1 and 4 come first: a few builds and simulations rank what stands
between 60 and 100 MHz and what each fix costs.

## Results

Recorded in later dated docs as each item is done.
