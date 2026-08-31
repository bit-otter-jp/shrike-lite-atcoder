# Exp02b: compact CALC flags

Exp02 could not complete PNR after adding full-value trace registers and a
19-byte mux. Exp02b keeps the production response width and stores candidate 0
checks in the existing `answer` register. Candidate 1 appends its checks and a
`0xD2` marker.

For `[100,1,1]`, the expected 24-bit response is `D2 FF FF`.

Candidate 0 flag bits, LSB to MSB:

1. read=100
2. total=102
3. prefix_before=0
4. prefix_after=100
5. right=2
6. diff=98
7. best_before=0xFFFFFF
8. best_after=98

Candidate 1 flag bits use read=1, total=102, prefix_before=100,
prefix_after=101, right=1, diff=100, best_before=98, best_after=98.

## Result

- Icarus: `EXP02B_RAW=00:d2:ff:ff`, `EXP02B_SIM_PASS`
- Synth: PASS, `RAM64X1D x34`, 669 cells
- PNR: FAIL. ForgeFPGA displayed
  `FATAL ERROR: The design cannot fit into the current geometry.` and
  `PnR failed`; the run was stopped without waiting for timeout
- No bitstream, E-drive copy, flash, or hardware result exists

## Interpretation

This is an observation-circuit area/geometry failure, not a failed telemetry
comparison and not a rejection of the CALC hypothesis.
