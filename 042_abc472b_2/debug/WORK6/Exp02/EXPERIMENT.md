# Exp02: production CALC read trace

## Hypothesis

Exp01 proved that input assembly, DistRAM write/readback, and total are correct.
Exp02 keeps the production CALC datapath and captures only the two RAM values
actually consumed by CALC for `[100, 1, 1]`.

The 19-byte response contains one dummy byte followed by:

```text
A6 02 N | observed_read0 | observed_read1 | total | final_prefix | answer
```

Expected values are `100, 1, 102, 101, 98`.

## Result

- Icarus: `EXP02_SIM_PASS`
- Synth: PASS, `RAM64X1D x34`, 731 cells
- PNR: did not complete within 723.9 seconds; no PNR result or bitstream
- E-drive copy, flash, and hardware test: not performed

## Interpretation

The full-value trace added 34 observation FFs and a wider response mux. Since
the build did not reach a placed design, this experiment is inconclusive and
does not reject the CALC-boundary hypothesis.
