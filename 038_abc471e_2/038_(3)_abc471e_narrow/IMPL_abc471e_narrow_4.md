# ABC471E Narrow - IMPL_4

## 1. 適用文書

Applicable SPEC:

```text
SPEC_abc471e_narrow_3.md
```

Previous IMPL:

```text
IMPL_abc471e_narrow_3.md
```

Previous REPORT:

```text
REPORT_abc471e_narrow_4.md
```

本IMPLは、compact_v3を基準に、

```text
WIDTH=5..9
```

それぞれでShrink-Liteに配置可能なN_MAX境界を探索するための実装方針を定義する。

---

## 2. 前段階から得られた事実

compact_v3 W8 final:

```text
WIDTH=8
MOD=251
N_MAX=250
VALUE_BYTES=1

557 LUT
163 FF
31 CARRY4
```

Icarus:

```text
39/39 PASS
```

実PNR:

```text
Type=L = 165 / 140
MinPlacer failed
design cannot fit
```

したがって、

```text
ceil(LUT/4) <= 140
```

は候補screeningには使えるが、fit判定には使えない。

fit境界は実PNRで確認する。

---

## 3. architecture基準

compact_v3 final architectureを基準とする。

維持する主要方針:

```text
WIDTH連動framing
1個shared modular multiplier
1系統top modular add/sub
単一multiplier launch point
compact arithmetic sequencer
4本のWIDTH-sized shared scratch
S1/S2 streaming
combination/pow/finalでscratch lifetime共有
```

今回、N境界探索のために別architectureへ変更しない。

---

## 4. parameter

単一parameterized RTLで次を扱う。

```text
WIDTH
MOD
N_MAX
VALUE_BYTES = (WIDTH + 7) / 8
COUNT_WIDTH
```

COUNT_WIDTH:

```text
COUNT_WIDTH = max(1, ceil(log2(N_MAX + 1)))
```

実装上は `$clog2` 等を使用してよい。

---

## 5. N_MAX連動の内部幅

N_MAXを縮めた効果が物理回路へ反映されるよう、

```text
N
K
accepted/input count
combination loop count
r/i等のNに由来するcounter/state
```

は、数学上WIDTHが必要な値を除き、可能な範囲でCOUNT_WIDTHへ縮める。

外部VALUE_BYTESのreceive valueは受信・validation後にCOUNT_WIDTHへ取り込む。

N/Kをmodular multiplier operandへ渡す場合はWIDTHへzero-extendする。

---

## 6. fair comparison

各 `(WIDTH, N_MAX)` でarchitectureを手調整しない。

禁止する例:

```text
W7だけ特別なFSM
N_MAX=63だけ専用constant shortcut
特定候補だけ別係数algorithm
候補ごとのmanual state encoding探索
候補ごとのhand cleanup
```

差分はparameterから自動的に生じるものだけとする。

これにより、境界を「同一architectureの問題世界サイズ差」として比較する。

---

## 7. W8再現確認

N_MAX parameter化後、

```text
WIDTH=8
MOD=251
N_MAX=250
```

ではcompact_v3 finalと意味・cycle・resourceが同等であることを最初に確認する。

可能ならPost-Synthesis:

```text
557 LUT / 163 FF / 31 CARRY4
```

を再現する。

source refactor等でprimitive mappingが僅かに変わる場合は、
理由と差を記録する。

大きく変わった場合は探索へ進まず原因を確認する。

---

## 8. WIDTH / MOD探索範囲

今回の対象:

```text
W5: MOD=31
W6: MOD=61
W7: MOD=127
W8: MOD=251
W9: MOD=509
```

各WIDTHで、

```text
1 <= N_MAX <= MOD-1
```

を探索する。

---

## 9. Post-Synthesis screening

ForgeFPGA bundled Yosysの既存flowを使用する。

```text
flatten -noscopeinfo
synth_xilinx -nobram -noiopad -nodsp -abc9
clean
autoname
```

resourceを記録する。

少なくとも:

```text
LUT
FF
CARRY4
MUXF7
MUXF8
ceil(LUT/4)
ceil(FF/8)
```

`ceil(LUT/4) > 140` はType=L fitの必要条件を満たさないため、
その候補はPNR不要のscreening failとしてよい。

`ceil(LUT/4) <= 140` はfitを意味せず、PNR候補にすぎない。

---

## 10. PNR

REPORT_abc471e_narrow_4で確立したForgeFPGA通常GUI flowのautomationを使用してよい。

各候補は専用copy projectで実行し、

```text
RTL
parameter
EDIF
PNR project
log
summary
```

を保存する。

bitstream outputは無効化する。

flash/実機には進まない。

---

## 11. fitの分類

各候補を最低限次で分類する。

### SCREEN_FAIL

```text
ceil(LUT/4) > 140
```

Post-Synthesis必要条件で不可能。

### PLACE_FAIL

Post-Synthesis候補だがMinPlacerが容量・geometry等で失敗。

### PLACE_FIT

minimum placementが成立し、
Type=L capacity 140を超過しない。

### PNR_COMPLETE

placer/routerが正常完了し、
post-route結果が得られる。

primary boundaryは、

```text
最大PLACE_FIT N_MAX
```

とする。

PNR_COMPLETEの最大Nが異なる場合は別途記録する。

---

## 12. timing

今回の主目的は容量境界であり、50 MHz timing closureではない。

既存50 MHz SDCは比較条件として維持する。

各候補で取得可能な、

```text
post-LUT-packing estimate
post-placement
post-route
WNS/TNS
achievable frequency
```

を記録する。

placement未成立時の推定値を最終timingと呼ばない。

timing違反だけを理由にN境界を下げない。

---

## 13. searchの非単調性

Yosys/ABC9/packingはparameter値に対して完全単調とは仮定しない。

特に、

```text
N_MAXを1減らせば必ずLUT/Type=Lが減る
```

とはみなさない。

二分探索だけで「最大」を断定しない。

探索手順と確定条件はWORK_REQUESTで定める。

---

## 14. 成果物配置

新規作業領域例:

```text
boundary_v4/
```

候補例:

```text
boundary_v4/w07/n126/
boundary_v4/w07/n127/   # invalidなら作らない
boundary_v4/w08/n250/
```

各候補にparameterと結果を残す。

---

## 15. 今回行わない設計変更

今回の主目的は境界測定であり、さらに小さくするためのarchitecture探索ではない。

行わない:

```text
新しいcombination algorithm
新しいpow algorithm
multiplier redesign
scratch本数の再探索
state encoding探索
manual candidate-specific cleanup
SPI semantics変更
VALUE_BYTES規則変更
```

必要になった場合は次IMPLへ分離する。
