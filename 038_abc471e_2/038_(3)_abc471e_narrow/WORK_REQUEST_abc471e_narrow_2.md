# ABC471E Narrow - WORK_REQUEST_2

## 1. 適用文書

今回の作業は次を正とする。

```text
SPEC:
    SPEC_abc471e_narrow.md

IMPL:
    IMPL_abc471e_narrow_2.md

Reference map:
    REFERENCE_MAP.md

Previous report:
    REPORT_abc471e_narrow.md
```

前段階の、

```text
IMPL_abc471e_narrow.md
WORK_REQUEST_abc471e_narrow.md
REPORT_abc471e_narrow.md
```

は履歴として保持し、書き換えない。

---

## 2. 今回の仕事

WIDTH=8固定で、現行実装の803 LUTがどの機能に使われているかを
差分合成とPost-Synthesis netlist解析で診断する。

今回の目的は、

```text
最適化すること
```

ではなく、

```text
次に何を最適化すべきかを測定で決めること
```

である。

---

## 3. 基準

設定:

```text
WIDTH = 8
MOD   = 251
N_MAX = 250
```

前段階の基準値:

```text
LUT total = 803
FF        = 308
CARRY4    = 35
MUXF7     = 0
MUXF8     = 0

LUT-only screening lower bound = 201
Shrike-Lite Type=L capacity    = 140
```

基準RTLは現在のparameterized `ffpga/src/main.v` をWIDTH=8で構成したものとする。

---

## 4. 保護対象

作業開始時にSHA-256またはtree digestを記録する。

少なくとも:

```text
SPEC_abc471e_narrow.md
IMPL_abc471e_narrow.md
IMPL_abc471e_narrow_2.md
WORK_REQUEST_abc471e_narrow.md
REFERENCE_MAP.md
REPORT_abc471e_narrow.md

ffpga/src/main.v
ffpga/src/spi_target.v
sim/abc471e_narrow_tb.v
tools/
experiments/

S1S2_30BIT_BASELINE
```

今回の診断ではこれらを変更しない。

診断版は `diagnostics/w08/` 以下だけで作成する。

---

## 5. 事前確認

最初に `REPORT_abc471e_narrow.md` のWIDTH=8成果物と、

```text
experiments/w08/
```

の、

```text
config
Icarus log
synth_script
synth.log
post_synth_report
post_synth_results
netlist.edif
resource summary
```

を確認する。

必要なら同じForgeFPGA bundled Yosys flowを再利用する。

前段階でCLI再現性は確認済みなので、
別Yosysや別optionへ切り替えない。

---

## 6. 作成する診断版

最低限、次の3版を作成する。

```text
diagnostics/w08/coefficient_pow_fixed/
diagnostics/w08/input_only/
diagnostics/w08/protocol_only/
```

必要なsource、testbench、build成果物は各診断版内へ置く。

正規root RTLを上書きしない。

---

## 7. 診断A: coefficient_pow_fixed

### 目的

combination + Fermat/pow全体と、
それに付随するoperand MUX / next-state / decodeのaggregate costを測る。

### 数学的範囲

診断用に、

```text
N = 3
K = 2
```

へ限定してよい。

WIDTH=8、MOD=251では、

```text
coeff_square = C(2,1) = 2
coeff_pair   = C(1,0) = 1
```

を固定値として使用できる。

### 残す

```text
SPI/protocol
32bit N/K/A receive
Ai<MOD validation
S1/S2 update
shared multiplier
shared add/sub
S1^2-S2
final 2 weighted products
final add
STATUS/reply
```

### 削除

```text
comb_n / comb_r / comb_i
numerator / denominator
coefficient work state

pow_result / pow_base / pow_exp / pow_context

combination states
pow states

combination/pow専用multiplier launch
関連operand selection/decode
```

### 必須検証

最低限、

```text
N=3,K=2
A=[1,2,3]
```

について独立全組合せ基準値と一致させる。

MOD=251で期待値は、

```text
(1+2)^2 + (1+3)^2 + (2+3)^2
= 50
```

である。

Aだけ異なる複数ケースも追加する。

shared multiplier、shared add/sub、S1/S2、final arithmeticが実動していることを確認する。

---

## 8. 診断B: input_only

### 目的

combination/pow/finalを除き、

```text
SPI/protocol
+
validation
+
S1/S2 stream datapath
```

のaggregate footprintを測る。

### 残す

```text
RESET/START
N/K/A 32bit framing
validation
counters
sticky error
x*x
S1/S2 update
shared multiplier
shared add
STATUS/reply
```

### 削除

```text
combination
pow
S1*S1
S1^2-S2
coefficient weighted products
final term add
```

### reply

入力処理がoptimizerに消されないよう、
最終S1またはS1/S2由来の動的値を4-byte answerへ返す。

例えば、

```text
answer = zero_extend(S1)
```

でよい。

### 必須検証

複数のA列について、
最終S1/S2が独立計算値と一致すること。

STATUS/reply、sticky error、Ai<MOD validationも確認する。

shared multiplierがx*xに実際に使用されることを確認する。

---

## 9. 診断C: protocol_only

### 目的

算術機能を除去し、

```text
SPI target
top protocol
32bit framing
N/K/A receive
validation
counter
STATUS/reply
```

の固定費を測る。

### 残す

```text
RESET/START
32bit word assembly
N/K/A receive sequencing
N/K validation
Ai<MOD validation
input count
sticky error
STATUS/reply
payload reserved-byte semantics
```

### 削除

```text
S1/S2
shared multiplier
shared add/sub
combination
pow
final calculation
```

### reply

optimizerによる受信経路消滅を避けるため、
受信した動的情報から簡単なanswerを作る。

例:

```text
answer = zero_extend(last_valid_A)
```

または同等の動的値。

### 必須検証

```text
RESET/START
N/K/A receive
Ai=0
Ai=MOD-1
Ai=MOD error
invalid N/K
sticky error
extra payload
STATUS/reply
```

を確認する。

---

## 10. Icarusの考え方

診断版は一般ABC471E実装ではないので、
前段階の全テストをそのまま通す必要はない。

各診断版について、

```text
残した機能が実動する
削除対象が本当に存在しない
protocolがdeadlockしない
dynamic pathがconstant-foldされない
```

ことを確認する診断用testbenchを用意する。

期待値は診断版RTLをそのまま模倣せず、独立計算する。

---

## 11. Post-Synthesis

Icarus PASS後、
各診断版を前段階と同じForgeFPGA bundled Yosys flowでPost-Synthesisする。

同じ条件:

```text
flatten -noscopeinfo
synth_xilinx -nobram -noiopad -nodsp -abc9
clean
autoname
```

tool versionと主要optionを変更しない。

PNRは行わない。

---

## 12. 取得resource

各版で最低限次を記録する。

```text
wires
wire bits
cells

CARRY4
FDCE
FDPE
FF total
INV

LUT2
LUT3
LUT4
LUT5
LUT6
LUT total

MUXF7
MUXF8
LUT+MUXF7+MUXF8
```

Post-Synthesis screeningとして、

```text
ceil(LUT / 4)
ceil(FF / 8)
```

も記録する。

物理Type=L予測値とは呼ばない。

---

## 13. 4版比較

最低限次を同じ表へ載せる。

```text
W08_BASELINE
coefficient_pow_fixed
input_only
protocol_only
```

比較項目:

```text
LUT
FF
CARRY4
MUXF7
MUXF8
LUT+MUXF7+MUXF8
LUT screening lower bound
```

---

## 14. aggregate差分

少なくとも次を計算する。

```text
coefficient+pow aggregate
    = baseline - coefficient_pow_fixed

final aggregate
    = coefficient_pow_fixed - input_only

input arithmetic aggregate
    = input_only - protocol_only
```

`protocol_only` はprotocol/framing/validation baselineとして扱う。

ただしglobal remappingがあるため、
これらを厳密な独立block面積とは呼ばない。

---

## 15. netlist構造解析

各版の `post_synth_results.v` を解析し、
可能な範囲で次を比較する。

### FF / CARRY4

source attributeと接続から、

```text
SPI/protocol
input/counters
multiplier
top add/sub
combination
pow
final
```

へ帰属可能なものを集計する。

### multiplier

```text
本体FF
本体CARRY4
FF直前LUT
浅いcone
launch state数
unique LHS source
unique RHS source
```

を比較する。

### next-state

```text
top FF直前unique LUT/MUX driver
MUXF7/F8
high-fanout control
```

を比較する。

LUT sourceがmapping libraryへ失われている場合、
無理なRTL行別配賦は行わない。

---

## 16. 必要なら追加診断を1本だけ許可

上記3版の結果だけでは、

```text
shared multiplier本体
```

が主要因かどうか判断できない場合に限り、
追加で1つの診断版を作成してよい。

例:

```text
input_multiplier_dummy
```

ただし作成前にREPORT内で、

```text
何を分離するためか
どの比較で判断するか
```

を明示する。

診断版を無制限に増殖させない。

最適化案の実装には進まない。

---

## 17. 判断したいこと

REPORTでは最低限次へ回答する。

1. WIDTH=8の803 LUTのうち、combination+powを外すと何LUT減るか。
2. final calculationをさらに外すと何LUT減るか。
3. input S1/S2 arithmeticを外すと何LUT減るか。
4. protocol/framing/validationだけで何LUT残るか。
5. shared multiplier本体は8bit時に何LUT/FF/CARRY4程度か。
6. top shared add/subは8bit時にどの程度か。
7. 803 LUTの主因は算術本体か、control/MUXか、protocolか。
8. 560 LUT以下へ243 LUT以上削る現実的な候補はどこか。
9. 140 Type=Lへ詰めるには局所修正で足りそうか、architecture変更が必要か。
10. 次のIMPL_3で最優先に変更すべき構造は何か。

根拠を、

```text
直接確認
強い推定
仮説
```

に分ける。

---

## 18. 成果ドキュメント

主成果物:

```text
REPORT_abc471e_narrow_2.md
```

成果ドキュメントは `REPORT_` prefixを使用する。

最低限の構成:

```text
1. Executive Summary
2. 目的
3. W08 baseline
4. 診断版一覧
5. Icarus結果
6. Post-Synthesis比較
7. aggregate差分
8. multiplier解析
9. add/sub解析
10. next-state / MUX / control解析
11. 803 LUTの構成に関する結論
12. 560 LUTへ向けた削減候補ランキング
13. IMPL_3への提案
14. 未実施事項・不確実性
15. 保護対象未変更確認
16. 停止点
```

---

## 19. 禁止事項

今回は次を行わない。

```text
SPEC変更
正規IMPL変更
REFERENCE_MAP変更
正規RTL変更
前段REPORT変更
experiments/w08..w16変更
30bit参照元変更

WIDTH=7以下
WIDTH=9以上の追加作業

bit-serial化
microcode化
scratch全面共有
register file化
multiplier/add-sub統合
係数アルゴリズム変更
SPI簡略化
32bit framing変更

PNR
placer
timing analysis
bitstream
実機flash
実機試験

140 Type=Lへ向けた最適化実装
自動architecture探索
```

診断結果から良い案が見えても、
今回は実装せずREPORTへ記録して停止する。

---

## 20. 保護対象確認

終了時に開始時digestと比較し、
少なくとも次の不変を確認する。

```text
SPEC_abc471e_narrow.md
IMPL_abc471e_narrow.md
IMPL_abc471e_narrow_2.md
WORK_REQUEST_abc471e_narrow.md
REFERENCE_MAP.md
REPORT_abc471e_narrow.md

ffpga/src/
sim/
tools/
experiments/

30bit参照元
```

診断版と `REPORT_abc471e_narrow_2.md` だけが新規成果物となることを基本とする。

---

## 21. 停止条件

次を完了したら停止する。

```text
W08 baseline確認

coefficient_pow_fixed:
    Icarus
    Post-Synthesis

input_only:
    Icarus
    Post-Synthesis

protocol_only:
    Icarus
    Post-Synthesis

必要なら追加診断1本

4版以上のresource比較
aggregate差分
netlist構造解析
560 LUTへ向けた候補整理

REPORT_abc471e_narrow_2.md作成
保護対象未変更確認
```

PNR、実機、IMPL_3作成、最適化実装には進まない。
