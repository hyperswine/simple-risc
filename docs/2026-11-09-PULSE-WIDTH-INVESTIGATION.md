# Minimum pulse width: clock constraints versus timing model

The 216 MHz failure is driven by Gowin's combination of slow and fast clock-path delays, not an incorrect generated-clock frequency. Automatic PLL clock derivation reproduces the failure. This isolates the calculation; it does not establish that ignoring it is safe. At 621 MHz a separate failure remains even with both edges evaluated at the slow corner.

## Controlled runs

Gowin V1.9.12.04, GW2AR-LV18QN88C8/I7. Frozen synthesized board LFSR netlists from the fast-Clash experiments, placement 0, same original mapping/routing options. The documented Tcl flow offers synthesis and PNR, not a standalone STA flow, so these are reroutes. For the decisive baseline/slow-only/output-primary comparison, both routed `.bin` and `.db` files are byte-identical (hashes in evidence). Fast-only and no-groups routes differ; do not treat their data-path timing as a fixed-route comparison.

| Clock | Constraint/model diagnostic | Worst pulse slack ns |
|---|---|---:|
| 216 MHz | Original generated clock, default slow setup / fast hold | -1.195 |
| 216 MHz | Automatic PLL-derived clock | -1.195 |
| 216 MHz | Remove asynchronous clock grouping | -1.195 |
| 216 MHz | Slow setup and slow hold | +1.312 |
| 216 MHz | Fast setup and fast hold | +1.313 |
| 216 MHz | Primary clock directly on PLL output | +0.552 |
| 621 MHz | Original generated clock (previous report) | -2.704 |
| 621 MHz | Slow setup and slow hold | -0.198 |

The automatic clock is correctly 216 MHz with a 2.315 ns half-period. The generic probe parser initially rejected its different clock name; the report itself completed and supplies the result above. Removing grouping also exposes cross-domain setup/hold violations and is not a proposed CDC change. Moving the generated-clock source to the PLL CLKIN pin, with or without explicit master, was rejected by Gowin; both error logs are retained, and neither is counted as a measurement.

## Where the negative width comes from

At 216 MHz the default report computes the low pulse as:

```
Half-period                    2.315 ns
Late PLL / clock-network       5.329 + 2.274 ns
Early PLL / clock-network      3.583 + 1.511 ns
Actual width                   2.315 - (5.329-3.583) - (2.274-1.511)
                            ~= -0.195 ns (rounded report values)
Required cell width            1.000 ns
Slack                         -1.195 ns
```

With slow/slow, PLL delays are both 5.329 ns; network delays are 2.274/2.271 ns. Almost all of the 2.51 ns penalty disappears, leaving a 2.312 ns pulse. Fast/fast likewise leaves only about 0.002 ns of edge asymmetry. Defining a primary clock at the PLL output removes the PLL contribution alone: the reported width becomes 1.552 ns, with the clock-network corner spread remaining. It is a diagnostic cut of the modeled clock path, not a fix to adopt.

[Gowin's timing guide, SUG940](https://cdn.gowinsemi.com.cn/SUG940E.pdf), sections 4.2.4 and 5.6, documents width as early arrival minus late arrival, and separate operating models for setup and hold. These experiments show that the pulse calculation also follows those model selections. The apparent common-clock pessimism is therefore strongly supported experimentally. Whether this cross-corner treatment is intentional, or a vendor defect requiring a corrected model, remains a vendor question. No production SDC or operating corner has been relaxed.

At 621 MHz, even slow/slow gives only 0.802 ns against a 1.000 ns cell requirement. Removing cross-corner pessimism cannot establish signoff there. A nominal 50% waveform alone reaches 1 ns at 500 MHz, before edge asymmetry or jitter. Previous successful board runs above that frequency demonstrate operation on one board under those conditions, not guaranteed pulse-width compliance.

## Guard and baseline

`boards/tangnano20k/check_gowin_timing.py` now requires reported nonnegative minimum-pulse-width slack as well as setup/hold. Missing pulse details fail closed. Validation accepted the canonical fprisc-84 report (+2.455 ns pulse slack), rejected the 216 MHz probe despite passing setup/hold, and rejected a report with pulse details removed. The existing 84 MHz core remains passing under this guard. No board programming was needed for this investigation.

## Evidence and next action

[Evidence](evidence/2026-11-09-pulse-width/) includes all nine trial directories, errors, constraints, Tcl, original frozen netlists compressed, full timing reports and routed-artifact hashes. `results.json` normalizes pulse results independently of clock names. The three Python files record the exact diagnostic drivers and original workspace paths; generated output remains under `output/tangnano20k/pulse-width-20261109`.

The next useful step is a vendor reproducer asking whether MPW should compare opposite edges at a single PVT corner, how clock-path correlation is handled, and whether the 1 ns flip-flop requirement is correct for this device/speed grade. Request a supported signoff procedure or fixed release; do not replace slow/fast signoff with the diagnostic same-corner settings. For further hardware ceiling work, separate functional frequency measurements from timing signoff and retain the CE-stop boundary findings from the fast-probe report.
