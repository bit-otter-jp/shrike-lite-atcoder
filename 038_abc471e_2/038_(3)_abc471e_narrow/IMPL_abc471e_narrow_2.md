# ABC471E Narrow - IMPL_2

## 1. 文書の役割

この文書は `abc471e_narrow` の第2段階における**内部実装方針と内部制約**を定義する。

適用SPEC:

```text
SPEC_abc471e_narrow.md
```

前段階の実装方針:

```text
IMPL_abc471e_narrow.md
```

前段階の実測結果:

```text
REPORT_abc471e_narrow.md
```

本書は、WIDTH sweep完了後に行う **WIDTH=8固定の面積診断** を対象とする。

SPECは変更しない。

---

## 2. 前段階から得られた事実

前段階では単一のparameterized RTLを使用し、WIDTH=8..16を同一アーキテクチャ・同一ForgeFPGA bundled Yosys flowで評価した。

WIDTH=8の設定:

```text
WIDTH = 8
MOD   = 251
N_MAX = 250
```

WIDTH=8 Post-Synthesis:

```text
LUT total = 803
FF        = 308
CARRY4    = 35
MUXF7     = 0
MUXF8     = 0

LUT-only screening lower bound =
    ceil(803 / 4)
    = 201
```

Shrike-Lite:

```text
Type=L capacity = 140
```

したがって、WIDTHを8bitまで縮小しても、
現在の通常アーキテクチャはPost-Synthesis screening時点で140 Type=Lへ届かない。

FF側は余裕があり、現段階の第一支配要因はLUTである。

---

## 3. 第2段階の目的

第2段階では、WIDTHをさらに狭くする前に、

```text
WIDTH=8で残る803 LUTは何に使われているのか
```

を差分合成とnetlist解析で切り分ける。

目的は最適化そのものではない。

今回の結果を使って、次段階で、

```text
どの内部構造を変更する価値があるか
```

を判断する。

---

## 4. 正規8bit実装の扱い

現在のparameterized RTLをWIDTH=8で構成したものを、
第2段階の正規診断基準とする。

論理名:

```text
W08_BASELINE
```

設定:

```text
WIDTH = 8
MOD   = 251
N_MAX = 250
```

基準値:

```text
LUT total = 803
FF        = 308
CARRY4    = 35
```

正規RTLは診断対象であり、変更しない。

診断版は正規RTLとは別の作業領域へ作成する。

---

## 5. 機能ブロックの概念分類

WIDTH=8実装を、面積診断上次の機能群として扱う。

### A. SPI target

```text
spi_target.v
SPI shift
SS/SCK handling
1-byte response delay
```

### B. top protocol / framing

```text
RESET / START / NOP
32bit word assembly
N/K/A receive sequencing
STATUS / reply
sticky protocol_error
payload / command state
```

### C. input validation / counters

```text
N validation
K validation
Ai < MOD validation
received_count
input_count
N/K state
```

### D. S1/S2 stream datapath

```text
x
x*x
S1 update
S2 update
shared multiplier use
shared add use
```

### E. shared modular multiplier

```text
operand interface
shift-add body
acc/addend/multiplier
mod compare/reduction
busy/done control
```

### F. top shared modular add/sub

```text
add_mod
sub_mod
MOD compare/reduction
borrow correction
result routing
```

### G. combination coefficient calculation

```text
comb_n
comb_r
comb_i
numerator
denominator
coeff_square
coeff_pair
coeff scratch
combination FSM
```

### H. Fermat / pow

```text
pow_result
pow_base
pow_exp
pow_context
pow FSM
shared multiplier operand routing
```

### I. final calculation

```text
S1*S1
S1^2-S2
coeff_square*S2
coeff_pair*pair_twice
final add
term/answer state
```

### J. global control / next-state / operand MUX

上記各機能を接続する、

```text
state decode
register enable
next-state selection
shared multiplier operand selection
shared add/sub operand/result selection
high-fanout control
```

を含む。

この分類は概念分類であり、flatten/ABC9後のLUTへ一対一対応するとは仮定しない。

---

## 6. 診断版の原則

診断版は、特定機能を除去したときに合成器が消す、

```text
対象block内部
+
operand MUX
next-state logic
decode
control
周辺constant propagation
ABC9 remapping
```

を含む **aggregate cost** を測るためのものとする。

したがって、

```text
baseline - diagnostic
```

を「そのmodule単体面積」と呼ばない。

---

## 7. 診断版とSPECの関係

診断版は面積測定専用であり、
一般入力に対するSPEC準拠実装である必要はない。

例えば係数を固定する診断版や回答を簡略化する診断版を許可する。

ただし、

```text
診断対象ではない回路まで不用意にconstant-foldされる
```

ことを避ける。

残すと定めたdatapathは、可能な範囲で実入力・動的値を通して実動させる。

正規 `W08_BASELINE` だけが機能比較の基準である。

---

## 8. 診断版の配置

診断版はroot正規RTLを変更せず、例えば次へ置く。

```text
diagnostics/w08/
```

その下に目的別の独立診断版を置く。

過去のproject/referenceを再帰コピーしない。

必要な正規ファイルだけをコピーし、
参照元はread-onlyとする。

---

## 9. 診断の基本系列

第2段階では、できるだけ**入れ子状に機能を外す**。

概念的には、

```text
D0 W08_BASELINE
    全機能

D1 COEFF_POW_FIXED
    combination + pow を除去
    input S1/S2 + final + protocol は残す

D2 INPUT_ONLY
    final計算も除去
    SPI/protocol + input S1/S2更新を残す

D3 PROTOCOL_ONLY
    S1/S2算術も除去
    SPI/protocol/framing/validation/replyを残す
```

とする。

この系列により、

```text
D0 - D1
    combination + pow aggregate

D1 - D2
    final calculation aggregate

D2 - D3
    input S1/S2 arithmetic aggregate

D3
    protocol / framing / validation baseline
```

を観測する。

共有blockとglobal remappingがあるため、差分は厳密な加法分解ではない。

---

## 10. COEFF_POW_FIXED方針

WIDTH=8、MOD=251、N_MAX=250を維持する。

診断用にN/Kを限定し、係数を固定してよい。

削除対象:

```text
combination state
numerator / denominator
comb_n / comb_r / comb_i
coeff work state

pow_result / pow_base / pow_exp / pow_context
pow states

combination/pow専用multiplier launch
関連operand selection / decode
```

残す:

```text
SPI/protocol
N/K/A receive
Ai validation
S1/S2 update
shared multiplier
shared add/sub
final S1^2-S2
final coefficient-weighted terms
answer/reply
```

係数は診断ケースに対応する定数を使用してよい。

A入力、S1、S2、final arithmeticは動的に維持する。

---

## 11. INPUT_ONLY方針

目的は、

```text
SPI/protocol
+
input validation
+
S1/S2 stream update
```

のaggregate footprintを観測すること。

残す:

```text
RESET/START
32bit N/K/A receive
validation
sticky error
x*x
S1/S2 update
shared multiplier
shared add
STATUS/reply
```

除去:

```text
combination
pow
final S1^2-S2
final coefficient multiplication
final term add
```

回答フィールドは診断用に、
動的なS1/S2から作る値を返してよい。

例えばS1またはS1/S2由来checksumを返し、
入力datapathがoptimizerにより消えないようにする。

---

## 12. PROTOCOL_ONLY方針

目的は、

```text
SPI target
top protocol
32bit framing
validation
counter
STATUS/reply
```

のbaseline footprintを観測すること。

S1/S2算術、shared multiplier、shared add/sub、
combination、pow、final calculationは除去してよい。

ただし入力wordの受信・N/K/A個数管理・Ai<MOD検証・sticky errorは残す。

replyは受信した動的情報から作る簡単な値を使用し、
受信経路全体がoptimizerにより消えないようにする。

---

## 13. shared multiplierの追加解析

W08_BASELINEおよび各診断版のPost-Synthesis netlistを使用し、

```text
multiplier本体
multiplier operand interface
launch state数
unique LHS/RHS source数
CARRY4
FF
浅いLUT cone
```

を可能な範囲で調査する。

source attributeがmapping libraryへ失われたLUTを、
無理にRTL行へ配賦しない。

直接確認、強い推定、仮説を区別する。

---

## 14. top add/subの追加解析

可能な範囲で、

```text
CARRY4
MUXF7
MUXF8
MOD comparator fanout
raw/reduced result selection
FF直前logic
```

を調査する。

WIDTH=8では30bit版より構造が小さいため、
残存固定費の比率を見る。

---

## 15. global next-state / MUX解析

各版で、

```text
top FF数
FF直前unique combinational driver
multiplier operand source数
high-fanout control
MUXF7/F8
```

を比較する。

特に、

```text
算術幅は8bitなのに
state/control/MUXがどの程度残っているか
```

を重視する。

---

## 16. 今回行わない内部変更

第2段階では正規アーキテクチャを最適化しない。

禁止:

```text
bit-serial ALU化
microcode化
scratch register全面共有
register file導入
multiplier/add-sub統合
係数アルゴリズム変更
SPI protocol簡略化
32bit framing変更
状態符号化の最適化
hand optimization
WIDTH=7以下への変更
```

これらは診断結果を見た後の次段階で検討する。

---

## 17. IMPL_2の停止境界

本IMPL_2は、

```text
WIDTH=8の残存803 LUTの構成を理解する
```

ところまでを対象とする。

140 Type=Lへ詰めるための新アーキテクチャは本書では定義しない。

診断結果から新しい設計方針へ進む場合は、

```text
IMPL_abc471e_narrow_3.md
```

等を新規作成し、
その後に対応する新しいWORK_REQUESTを作成する。
