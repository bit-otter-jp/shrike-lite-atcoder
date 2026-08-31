# Exp01: shadow FF vs DistRAM readback

## Hypothesis

The production failure occurs before or at the DistRAM boundary. Capture the
three assembled lengths in shadow FFs while writing the same values into the
same 128x17 inferred memory, then return both sets without running CALC.

## Telemetry response

The response burst is 27 bytes: one V3 dummy byte followed by 26 payload bytes.

```text
00 | A6 01 N COUNT BYTE_INDEX |
shadow0[17] shadow1[17] shadow2[17] |
ram0[17] ram1[17] ram2[17] |
total[24]
```

For `[100, 1, 1]`, both shadow and RAM must be `100, 1, 1`, and total must be
102. If shadow is correct and RAM differs, the fault is at the physical RAM
write/read boundary. If both are correct, the next experiment will isolate CALC.

## Result

- Icarus: `EXP01_SIM_PASS RUNS=2`
- Synth: `RAM64X1D x34`; the full 128x17 DistRAM mapping was preserved
- PNR/Timing: PASS at 37.5 MHz, WNS +12.216 ns, TNS 0
- Resource: 110/140 CLBs; 272 distributed-memory LUT5s
- MCU bitstream SHA-256:
  `A96E351B17939D9FCD74B03714EEF5EAC7DCDA365EA551D36E0DFA2D95ACAFC1`
- E-drive copy and `shrike.flash()`: automated successfully
- Hardware: 20/20 PASS (10 continuous runs and 10 reset-each runs)
- Every run reported `N=3`, `COUNT=3`, `BYTE_INDEX=0`,
  `SHADOW=100,1,1`, `RAM=100,1,1`, and `TOTAL=102`

## Interpretation

Input assembly, DistRAM write, basic synchronous DistRAM readback, and
`total_sum` are correct on hardware. The production fault is downstream, at
the DistRAM/CALC boundary or in CALC itself.
