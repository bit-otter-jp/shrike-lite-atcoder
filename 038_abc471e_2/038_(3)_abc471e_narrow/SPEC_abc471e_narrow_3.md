# ABC471E Narrow - SPEC_3

## 1. 文書の役割

この文書は `abc471e_narrow` の第3版外部仕様を定義する。

前版:

```text
SPEC_abc471e_narrow_2.md
```

SPEC_3では、`WIDTH`だけでなく **N_MAXもcompile-time parameterとして問題世界を縮尺可能**にする。

目的は、Shrike-Lite上でABC471E型の計算を実現できる

```text
(WIDTH, N_MAX)
```

の領域を調べられる外部contractを定義することである。

内部RTL、FSM、演算器、scratch共有、探索アルゴリズム、PNR方法は本SPECでは規定しない。

---

## 2. 問題定義

compile-time parameter:

```text
WIDTH = W
MOD
N_MAX
```

を持つ。

`MOD`はprimeであり、

```text
0 < MOD < 2^WIDTH
```

を満たす。

`N_MAX`は、

```text
1 <= N_MAX < MOD
```

を満たす。

有効入力:

```text
1 <= N <= N_MAX
1 <= K <= N
0 <= Ai < MOD
```

求める値は、

```text
すべてのK要素部分集合について
(選んだ要素の総和)^2
を合計した値 mod MOD
```

である。

---

## 3. WIDTH別MOD

今回の探索対象では、各WIDTHについて

```text
MOD = 2^WIDTH 未満の最大素数
```

を使用する。

基準値:

| WIDTH | MOD | N_MAX上限 |
|---:|---:|---:|
| 5 | 31 | 30 |
| 6 | 61 | 60 |
| 7 | 127 | 126 |
| 8 | 251 | 250 |
| 9 | 509 | 508 |

`N_MAX`は上表の上限以下で任意に縮小できる。

---

## 4. 外部データ幅

外部のN/K/A/answerはWIDTH連動framingとする。

```text
VALUE_BYTES = ceil(WIDTH / 8)
            = (WIDTH + 7) / 8
```

unsigned big-endian。

今回の探索範囲では、

```text
WIDTH=5..8 : VALUE_BYTES=1
WIDTH=9    : VALUE_BYTES=2
```

となる。

N_MAXを小さくしても外部framing幅はWIDTHに従い、N_MAXには連動させない。

---

## 5. 値の妥当性

受信値はunsigned integerとして解釈する。

有効条件:

```text
1 <= N <= N_MAX
1 <= K <= N
0 <= Ai < MOD
```

条件外はprotocol errorとする。

有効Aiに対する一般的なMOD正規化は要求しない。

---

## 6. SPI基本条件

SPI V3のcommand体系を維持する。

```text
RESET = 0xFF
START = 0xFE
DEBUG = 0xFD
NOP   = 0x00

RESET_ACK = 0x5A
START_ACK = 0xA5
```

baseline SPI:

```text
4 MHz
CPOL=0
CPHA=0
```

responseは1 byte遅延を持つ。

command byteはcommand phaseだけでcommandとして解釈する。

N/K/A payload中の `0xFD / 0xFE / 0xFF` はpayload byteとして扱い、
途中でcommandへ化けてはならない。

---

## 7. 入力framing

START後:

```text
N
K
A1
A2
...
AN
```

の順に受信する。

各値は `VALUE_BYTES` byte big-endian。

N_MAX個を超えるA payloadは受理しない。

---

## 8. 出力framing

正常結果:

```text
0 <= answer < MOD
```

answerは `VALUE_BYTES` byte unsigned big-endianで返す。

STATUSは1 byteのままとする。

---

## 9. ERROR

protocol errorはRESETまでsticky。

少なくとも:

```text
N=0
N>N_MAX
K=0
K>N
Ai>=MOD
N個受信後の余分なpayload
不正sequence
```

をerror対象とする。

RESETでERRORと処理状態を初期化する。

---

## 10. 正しさ

小規模caseでは問題定義から独立brute forceで期待値を求める。

最低限:

```text
N=1,K=1
K=1
K=N
Ai=0
Ai=MOD-1
N=N_MAX
```

を含める。

N_MAXを変更した場合は、

```text
N=N_MAX
N=N_MAX+1 error
```

も確認する。

---

## 11. Shrike-Lite target

target:

```text
Shrike-Lite Type=L
Type=L capacity = 140
```

ただし、

```text
fit
placement
route
timing
```

は外部機能仕様ではなく、実装評価事項である。

---

## 12. SPECで規定しない事項

以下は内部実装または探索手順であり、SPECでは規定しない。

```text
COUNT_WIDTH
N/K/counterの内部幅
S1/S2保持方法
combination計算方式
inverse/pow方式
multiplier/add-sub構造
FSM/state encoding
scratch共有
operand staging
N_MAX探索順序
Post-Synthesis screening
PNR自動化
timing closure方針
```

外部contractと数学的正しさを満たす限り変更可能である。
