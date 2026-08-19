# ABC471E Narrow - WORK_REQUEST_3

## 1. 適用文書

Applicable SPEC:

```text
SPEC_abc471e_narrow_2.md
```

Applicable IMPL:

```text
IMPL_abc471e_narrow_3.md
```

Previous REPORT:

```text
REPORT_abc471e_narrow_2.md
```

Reference map:

```text
REFERENCE_MAP.md
```

旧SPEC/IMPL/WORK/REPORTは履歴として保持する。

---

## 2. 目的

WIDTH=8で、
診断結果を反映したcompact architectureをまとめて実装する。

主な変更を個別実験として一つずつ積まず、

```text
WIDTH連動framing
compact arithmetic controller
operand staging
scratch lifetime共有
combination/pow再設計
final再利用
```

を一つの新アーキテクチャとして実装し、
一度Post-Synthesisして効果を見る。

第一目標:

```text
W8 LUT <= 560
```

余裕目標:

```text
W8 LUT <= 520
```

---

## 3. 保護対象

開始時にdigestを取得する。

少なくとも次を変更しない。

```text
SPEC_abc471e_narrow.md
SPEC_abc471e_narrow_2.md

IMPL_abc471e_narrow.md
IMPL_abc471e_narrow_2.md
IMPL_abc471e_narrow_3.md

WORK_REQUEST_abc471e_narrow.md
WORK_REQUEST_abc471e_narrow_2.md

REPORT_abc471e_narrow.md
REPORT_abc471e_narrow_2.md

REFERENCE_MAP.md

ffpga/src/
sim/
tools/
experiments/
diagnostics/

S1S2_30BIT_BASELINE
```

新実装は既存正規RTLを上書きせず、
新しい作業領域へ作成する。

推奨:

```text
compact_v3/
```

---

## 4. 基準値

WIDTH=8旧baseline:

```text
803 LUT
308 FF
35 CARRY4
ceil(LUT/4)=201
```

診断:

```text
coefficient+pow aggregate = 372 LUT
final aggregate           = 68 LUT
input arithmetic aggregate= 160 LUT
protocol baseline         = 203 LUT
```

shared multiplier構造指標:

```text
38 FF
6 CARRY4
38 FF-direct unique LUT
```

これらを比較基準として用いる。

---

## 5. Stage A: compact_v3実装

単一parameterized RTLとして実装する。

最低限parameter:

```text
WIDTH
MOD
N_MAX
VALUE_BYTES
```

W8設定:

```text
WIDTH=8
MOD=251
N_MAX=250
VALUE_BYTES=1
```

実装ではIMPL_3の方針をまとめて反映する。

---

## 6. 必須architecture変更

### 6.1 framing

32bit固定N/K/A/answerを撤去。

```text
VALUE_BYTES = ceil(WIDTH/8)
```

によるbig-endian framingへ変更する。

W8では各値1 byte。

### 6.2 arithmetic controller

旧設計の広いstate/launch構造をそのまま移植しない。

少数のphase/contextで、

```text
input
combination
pow
final
```

を順次実行するcompact sequencerを作る。

### 6.3 operand staging

shared arithmetic engineの入力を少数staging registerへ集約する。

launch source数を旧baselineより明確に減らす。

### 6.4 scratch共有

combination/pow/finalでライフタイムが重ならないtemporaryを共有する。

### 6.5 coefficient/pow

正確な結果を維持する範囲で、
計算順序、state構成、scratch構成、algorithmを再設計してよい。

### 6.6 final

専用演算器を作らず、
同じarith engineとscratchを再利用する。

---

## 7. Icarus検証: W8

W8でまず完全検証する。

少なくとも次を含む。

```text
N=1,K=1
K=1
K=N
A=[1,2,3]
Ai=0
Ai=250
N=0
N=251
K=0
K>N
Ai=251
extra payload
sticky ERROR
RESET recovery
STATUS
1-byte answer
```

command値 `0xFD/0xFE/0xFF` がpayload phaseでcommandへ化けないことも確認する。
W8ではこれらはAiとして無効値なので、
「payloadとして受けた後にAi>=MOD errorになる」ことを確認する。

ランダムsmall caseを最低24件実施し、
問題定義からの独立brute forceと照合する。

---

## 8. performance記録

W8で少なくとも次を測る。

```text
AI_MIN_CLOCKS
AI_MAX_CLOCKS
multiplier clocks
combination clocks
pow clocks
final clocks
N_MAX級の推定total clocks
```

面積優先なので旧設計より遅くてもFAILとはしない。

ただし異常な低速化はREPORTで明示する。

---

## 9. Post-Synthesis: W8

Icarus PASS後、
前段と同じForgeFPGA bundled Yosysを使用する。

基本flow:

```text
flatten -noscopeinfo
synth_xilinx -nobram -noiopad -nodsp -abc9
clean
autoname
```

tool versionと主要optionを記録する。

取得:

```text
wires
bits
cells
CARRY4
FF
LUT2..LUT6
LUT total
MUXF7
MUXF8
ceil(LUT/4)
ceil(FF/8)
```

旧W8 baselineと比較する。

---

## 10. synthesis-guided cleanup

初回compact_v3が560 LUTを超えた場合、
IMPL_3の範囲内でsynthesis-guided cleanupを行ってよい。

優先順:

```text
1. operand source / result destination削減
2. state / phase統合
3. scratch lifetime再割当
4. duplicate compare/correction削減
5. counter/register幅確認
6. protocol receive/reply register確認
```

意味のあるcheckpointごとに、

```text
LUT
FF
CARRY4
launch source数
top FF direct driver数
```

を保存する。

明確な改善余地がなくなったら、
560未達でも無理に別architectureへ飛ばずREPORTして停止する。

---

## 11. W9/W10 gate

W8 final resultに応じて次へ進む。

### W8 <= 520 LUT

同じRTLで、

```text
W9:
    MOD=509
    N_MAX=508
    VALUE_BYTES=2

W10:
    MOD=1021
    N_MAX=1020
    VALUE_BYTES=2
```

をIcarus + Post-Synthesisする。

### W8 = 521..560 LUT

W9だけをIcarus + Post-Synthesisする。

W9結果を見てW10はREPORT内の次候補とし、
このWORKでは必須にしない。

### W8 > 560 LUT

W9/W10へ進まない。

まずW8結果をREPORTする。

---

## 12. W9/W10追加検証

実施する場合は、
可変2-byte framingを重点確認する。

少なくとも、

```text
big-endian 2-byte N/K/A
answer 2-byte
Ai=MOD-1
Ai=MOD error
low byteがFD/FE/FFの有効値
sticky ERROR
STATUS
random brute force
```

を確認する。

payload途中の `FD/FE/FF` をcommandとして解釈してはならない。

---

## 13. netlist構造比較

compact_v3 final版で、
可能な範囲で旧baselineと次を比較する。

```text
multiplier FF/CARRY4
launch sites
unique LHS/RHS source
top FF direct LUT/MUX driver
top protocol/control FF
最大fanout指標
MUXF7/F8
```

目的は、

```text
372 LUT aggregateの原因だったcontrol/MUXが
実際に縮んだか
```

を確認すること。

過剰なRTL行別LUT帰属は行わない。

---

## 14. 判断基準

REPORTでは少なくとも次へ回答する。

1. compact_v3のW8 LUT/FF/CARRY4はいくつか。
2. 803 LUTから何%減ったか。
3. 560 LUT以下へ到達したか。
4. 520 LUT以下の余裕目標へ到達したか。
5. WIDTH連動framing後のprotocol/controlはどこまで縮んだか。
6. combination/pow/controlのdriver/source数はどこまで減ったか。
7. cycle数はどの程度増減したか。
8. W9/W10を実施したか、その結果は何か。
9. 次はPNR候補か、さらにarchitecture変更が必要か。

---

## 15. 成果物

主成果物:

```text
REPORT_abc471e_narrow_3.md
```

新規実装・ログ・合成物は、

```text
compact_v3/
```

以下へ保存する。

可能ならresource checkpointをCSV/JSONでも残す。

---

## 16. 禁止事項

今回行わない。

```text
旧SPEC/IMPL/WORK/REPORTの上書き
REFERENCE_MAP変更
既存ffpga/src変更
既存diagnostics変更
30bit参照元変更

PNR
placer
timing closure
bitstream
実機flash
実機試験
```

Post-Synthesis候補が得られても、
PNRは次WORKへ分離する。

---

## 17. 停止条件

最低限、

```text
compact_v3 W8実装
W8 Icarus PASS
W8 Post-Synthesis
必要ならIMPL_3内cleanup
resource/netlist比較
REPORT_abc471e_narrow_3.md
保護対象digest一致
```

まで完了する。

W8の余裕に応じて、
Section 11のgateに従いW9/W10を追加する。

最後に停止し、
PNRには進まない。
