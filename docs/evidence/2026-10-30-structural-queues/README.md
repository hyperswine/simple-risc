# Queue and effect-contract evidence

Read [the findings](../../2026-10-30-QUEUE-AND-EFFECT-CONTRACTS.md) and the
[preceding BTB/E2/phase report](../../2026-10-30-STRUCTURAL-VARIANTS.md).
The expanded F-queue candidate is rejected after its routed timing regression;
production Haskell is restored byte-for-byte to the accepted BTB-only source.
The board remains on its verified original 54 MHz image.

- `control-sources.tar.gz` preserves the exact accepted BTB source before
  the queue experiment. Its routed/physical evidence is shared with the prior
  bundle, rather than copied and attributed to this later test fixture.
- `candidate-sources.tar.gz` preserves the expanded-queue source and its
  original actual-bank test. `retained-sources.tar.gz` and
  `source-checkpoint.json` preserve the final production source, test-only
  experimental banks, formal model, eight-owned-store RTL fixture and CI.
- `generated/` contains compressed ordinary and observed IM/IMC candidate
  RTL. Hardware uses ordinary RTL; simulation uses named observation ports.
- `build/` retains the 48 MHz vendor reports/netlist, constraints, PLL, ROM
  and bitstream hash. No rejected candidate was loaded onto the board.
- `simulation/` contains the candidate's frozen classifier and fresh IM,
  IMC and IMC/CDC results, plus final effect checks against the restored
  control. `duplicate_effect.log`, `wrong_path_effect.log` and `corrupt.log`
  must contain their specific rejection diagnostics, not a generic timeout.
- `formal/` contains all 29 individually attributed searches, broken controls
  and non-vacuous hold witnesses. This is finite abstract refinement, not
  synthesized RTL equivalence.
- `physical/final-board-54/` verifies the original 54 MHz image identity and
  all twelve CRC upload/readback probes again after the local experiments.
- `receipts/` contains decision, analysis, mapped array-register inventory,
  complete Haskell/generation/synthesis logs and counter/oracle comparison.
  Final effect counts refer to the eight-owned-store fixture; earlier
  single-store coverage probes are superseded.

The candidate saves 111 CLS, adds 223 logic cells and saves no registers.
Reported Fmax falls 80.779 to 73.965 MHz at fixed 48 MHz settings. All frozen
classifier metrics are unchanged. The rejected implementation remains in
the test-only `FQueueVariant` module, so its ownership contract still runs in
CI. Normal hardware does not instantiate that module.

Replay uses the source archive, tool versions in the preceding bundle, and
the exact configuration in the receipts. Generate each top into a fresh
directory; run `check_pipeline_rtl.py` with explicit output directories.
The eight owned store PCs/addresses must each commit and reach backend
acceptance exactly once, with nonzero held-effect coverage and no poisoned
store. The two real guest mutations must fail. The fixture also covers UART
markers, fence/refetch, eight timer interrupts across misses and Ctrl-C/ROM
restart. Both Verilator and the CI Icarus path are recorded separately.

`array-register-inventory.json` attributes only mapped DFF Q nets named
`pipeState[bit]`, using the exact 3432-bit generated width and explicit
`pipeState=Pipe` layout binding. It counts each Q bit within the recorded
inclusive source-field ranges and groups its CE net. It does not assign
merged/renamed aliases or surrounding LUT logic to a source array.

`manifest.json` hashes every file except itself, plus the shared frozen
guest/oracle and previous evidence. Source checkpoint hashes can be checked
against the retained archive independently of future live edits. Hashes
establish provenance, not correctness. Hosted CI success, a physical run of
this rejected candidate and SDRAM I/O/PVT signoff are not claimed.
