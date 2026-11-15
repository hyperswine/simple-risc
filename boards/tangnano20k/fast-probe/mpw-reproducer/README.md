# GW2AR minimum pulse width reproducer

Tested with Gowin V1.9.12.04, GW2AR-LV18QN88C8/I7. No board required.
The design is a 32-bit LFSR, observation registers, a reset synchronizer and
216 MHz PLL from the 27 MHz input. It uses 17 logic units and 66 registers.

Run with Python 3 and a licensed Gowin installation:

```
python3 run.py --ide /path/to/Gowin/IDE --out /new/output/directory
```

The included frozen `probe.vg` is routed twice at placement 0. Sources are
included for inspection. No synthesis tool or Clash installation is required.
On macOS the default IDE path is already configured. No programming commands
are executed. The script records each license retry separately.

Observed results:

| Model | Minimum pulse slack | Actual width | Required width |
|---|---:|---:|---:|
| Default slow setup / fast hold | -1.195 ns | -0.195 ns | 1.000 ns |
| Slow setup / slow hold diagnostic | +1.312 ns | 2.312 ns | 1.000 ns |

The routed `.bin` and `.db` hashes match between the two cases. Both use a
216 MHz, 50% generated clock. The default report subtracts 3.583 ns early PLL
latency from 5.329 ns late PLL latency, and 1.511 ns early network latency from
2.274 ns late network latency. In slow/slow the PLL latency cancels and the
network edge asymmetry is only approximately 0.003 ns.

Questions for Gowin support:

1. Is combining opposite edges from different global PVT corners intentional
   for minimum pulse width? How is shared PLL/network path correlation handled?
2. Should pulse width instead be checked at each PVT corner independently,
   while retaining slow/fast models for setup and hold?
3. Is the reported 1.000 ns register pulse-width requirement correct for this
   part and speed grade? How should it be reconciled with the PLL's higher
   supported output frequencies when clocking fabric registers?
4. Is there a supported constraint, analysis procedure, or software update that
   addresses this without hiding genuine setup, hold, or pulse violations?

The slow/slow case is diagnostic only, not a proposed signoff workaround.
This package is prepared locally and has not been sent to support.
