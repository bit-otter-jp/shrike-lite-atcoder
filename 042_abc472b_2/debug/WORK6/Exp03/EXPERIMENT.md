# Exp03: one wait clock at the DistRAM/CALC boundary

## Hypothesis

Exp01 proved that the input assembler, the exact 128x17 inferred DistRAM, its
basic synchronous readback, and `total_sum` are correct on hardware. Exp02 and
Exp02b could not be placed because their observation circuitry exceeded the
geometry, so they did not test the CALC hypothesis.

This experiment keeps the production datapath and normal four-byte answer
protocol, but inserts one state clock between `CALC_READ` and
`CALC_EVALUATE`. It uses an unused encoding in the existing 3-bit state
register and adds no telemetry registers. If the production failures disappear,
the decisive variable is the physical DistRAM-read-to-CALC evaluation boundary.

Expected CALC clocks are `3 * (N - 1)`; at 37.5 MHz and N=100 this is 7.92 us,
within the existing 10 us firmware wait.

## Result

- Icarus: all 524 cases PASS; `best_at_first_cut` returned 98
- Synth: PASS, `RAM64X1D x34`, 641 cells
- PNR/Timing: PASS at 37.5 MHz; WNS +0.502 ns, TNS 0,
  achievable frequency 38.220 MHz
- Resource: 137/140 CLBs; 272 distributed-memory LUT5s
- MCU bitstream SHA-256:
  `8CFA9033E7200EF046CB9DAADB1D94B5BCDAF9602D3368A8CD3983FE3A020CF1`
- E-drive copy, `shrike.flash()`, Thonny F5, and Shell capture: all automated
- Hardware: `PASS=112 FAIL=0 TOTAL=112`; every dummy byte was zero
- Priority-case raw response: `00:00:00:62` under reset/no-reset and all four
  2/4 MHz input/answer SPI combinations

## Interpretation

Adding only an extra settle clock at the physical DistRAM-read-to-CALC boundary
removed all 92 failures seen with the baseline. This is the decisive experiment
used for the production fix.
