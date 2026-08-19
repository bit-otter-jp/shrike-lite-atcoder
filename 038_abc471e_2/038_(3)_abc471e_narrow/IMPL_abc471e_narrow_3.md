# ABC471E Narrow - IMPL_3

## 1. 適用文書

Applicable SPEC:

```text
SPEC_abc471e_narrow_2.md
```

Previous IMPL:

```text
IMPL_abc471e_narrow_2.md
```

Previous REPORT:

```text
REPORT_abc471e_narrow_2.md
```

本IMPLは、WIDTH=8で観測された803 LUTを、
局所修正ではなく **compact architectureとしてまとめて再設計する** 方針を定義する。

---

## 2. 診断から得た設計判断

WIDTH=8 baseline:

```text
803 LUT / 308 FF / 35 CARRY4
```

診断aggregate:

```text
combination + pow          372 LUT
final                       68 LUT
input S1/S2 arithmetic     160 LUT
protocol/framing            203 LUT
```

shared multiplier本体は3つの算術系診断で、

```text
38 FF
6 CARRY4
FF直前38 unique LUT
```

と不変だった。

したがってIMPL_3では、
multiplier本体の微小最適化より先に、

```text
combination / pow / control
operand routing
scratch lifetime
外部framing
```

をまとめて縮小する。

---

## 3. 第一目標

まずWIDTH=8で、

```text
Post-Synthesis LUT <= 560
```

を必須screening目標とする。

これは、

```text
ceil(LUT/4) <= 140
```

の必要条件にすぎず、PNR fit保証ではない。

余裕目標:

```text
LUT <= 520
```

560ぎりぎりより、9bit/10bitへ拡張できるheadroomを重視する。

---

## 4. parameterized design

compact architectureも単一parameterized RTLとする。

主要parameter:

```text
WIDTH
MOD
N_MAX
VALUE_BYTES = (WIDTH + 7) / 8
```

WIDTH別に手書きコピーを作らない。

設計方針は少なくともWIDTH=8..16で成立する形にする。

---

## 5. WIDTH連動framing

32bit固定word assemblyを撤去する。

N/K/A/answerは、

```text
VALUE_BYTES
```

だけ受信・送信する。

内部receive registerも原則として、

```text
VALUE_BYTES*8
```

を超えて持たない。

受信完了後はWIDTH bitへ取り込む。

STATUS、command、ACKは1 byteのまま。

---

## 6. compact arithmetic controller

旧設計の多数の専用stateと、
各stateからshared multiplier/add-subへ直接operandを多重化する構造をやめる。

原則として、

```text
small phase
small context
operand staging
result destination/context
```

で算術engineを駆動する。

目的は、

```text
launch source数
operand MUX幅
next-state cone
register enable decode
high-fanout control
```

をまとめて減らすことである。

---

## 7. operand staging

shared arithmetic engineへ入るoperandは、
多数のregisterから直接巨大MUXで選択しない。

例えば、

```text
op_a
op_b
arith_context
```

の少数staging registerへ一度集約してから起動する。

resultも可能なら、

```text
result
result_context
```

の少数経路へ集約する。

具体的なregister数は合成結果で決めてよい。

---

## 8. scratch lifetime共有

次の値は同時に必要かを解析し、
ライフタイムが重ならないものは同じscratchへ置いてよい。

候補:

```text
numerator
denominator
combination temporary
pow_result
pow_base
pow temporary
coeff_square
coeff_pair
pair_twice
term
final temporary
```

用途別に専用registerを常設しない。

値の意味より、

```text
同時に生きているか
```

を優先して物理registerを割り当てる。

---

## 9. combination / pow

combinationとFermat exponentiationを
別々の大きなFSMとして持つことを必須としない。

次を許可する。

```text
共通反復sequencer
小さなphase/contextへの統合
scratch共有
coefficient計算順序の変更
inverse計算順序の変更
係数algorithmの変更
```

ただし数学的結果はSPEC_2と一致すること。

MODがprime、N_MAX<MODという条件を利用してよい。

---

## 10. multiplier / add-sub

原則として演算資源は共有する。

現在の1個shared modular multiplier、
1系統top modular add/subを出発点とする。

ただし、より小さくなることを合成で確認できる場合は、

```text
multiplierとadd/subの内部共有
bit-serial化
共通carry datapath化
```

等を許可する。

Verilogのgeneric `*` に任せて複数乗算器を生成する方向は採用しない。

面積を第一目的とする。

---

## 11. input stream

配列Aは保存しない。

ストリーム中に必要な数学状態は基本的に、

```text
S1 = ΣAi mod MOD
S2 = ΣAi^2 mod MOD
```

とする。

S1/S2式そのものは有効な縮約なので維持する。

ただしS1/S2更新のcontrollerやscratch配置は変更してよい。

---

## 12. final calculation

final専用の大きなstate/register群を常設しない。

combination/pow後に空いたscratchと同じarith sequencerを再利用する。

finalがshared multiplier/add-subを再利用することを優先し、
final専用演算器を追加しない。

---

## 13. protocol側の最適化

SPEC_2により、
32bit固定framingは不要になった。

protocol側では、

```text
VALUE_BYTES counter
compact receive register
WIDTH-sized N/K/A
WIDTH-sized answer
```

を使用する。

command decode、sticky error、STATUS semanticsは維持する。

SPI target本体を不必要に書き換えないが、
SPEC_2の可変payload長へ対応するためのtop側変更は行う。

---

## 14. cycle方針

今回の第一評価軸は面積である。

旧設計よりcycle数が増えることを許可する。

ただし、

```text
MUL_CLOCKS
AI processing clocks
coefficient clocks
pow clocks
total clocks
```

を測定しREPORTへ残す。

極端な低速化を隠さない。

---

## 15. synthesis-guided iteration

同じIMPL_3方針の範囲内で、
Post-Synthesis結果を見ながら複数回のcleanupを行ってよい。

例:

```text
state統合
dead register除去
operand source削減
scratch再割当
比較器/補正経路共有
counter幅削減
```

各意味のあるcheckpointはresource値を記録する。

SPEC変更や別アルゴリズム世界へ逸脱しない。

---

## 16. WIDTH拡張

まずWIDTH=8を成立させる。

WIDTH=8で十分な余裕が得られた場合、
同じRTLをWIDTH=9、WIDTH=10へ広げる。

目安:

```text
W8 LUT <= 520:
    W9/W10を評価する価値が高い

W8 LUT 521..560:
    W9を優先して評価

W8 LUT > 560:
    まずW8を再検討
```

これはPost-Synthesis screening運用上の目安でありSPECではない。

---

## 17. PNR

IMPL_3ではPNRを自動的に実行しない。

Post-Synthesisで候補が得られたら、
PNRは次のWORKで独立して実施する。

---

## 18. 成功の意味

IMPL_3の成功は、

```text
正しさを維持しながら
compact architectureで
W8のLUTを560以下へ下げる
```

ことである。

520以下なら、9bit/10bitへの拡張余地がある好結果とみなす。

「140 Type=Lへfitした」とは、
PNR成功まで言わない。
