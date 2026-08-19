# ABC471E Narrow - SPEC_2

## 1. 文書の役割

この文書は `abc471e_narrow` の第2版外部仕様を定義する。

前版:

```text
SPEC_abc471e_narrow.md
```

変更点は主に **narrow-world に合わせて外部データ幅も縮小すること** である。
数学的な問題定義、MOD世界、エラーの基本方針は維持する。

内部RTL、FSM、演算器構成、scratch共有、係数計算方式は本SPECでは規定しない。

---

## 2. 問題定義

compile-time parameter `WIDTH = W` に対し、次を満たす素数 `MOD` と `N_MAX` を使用する。

```text
0 < MOD < 2^W
1 <= N_MAX < MOD
```

通常のnarrow sweepでは、

```text
MOD   = 2^W 未満の最大素数
N_MAX = MOD - 1
```

とする。

有効入力:

```text
1 <= N <= N_MAX
1 <= K <= N
0 <= Ai < MOD
```

求める値は、

```text
全てのK要素部分集合について
(選んだ要素の総和)^2
を合計した値 mod MOD
```

である。

---

## 3. 外部データ幅

外部のN/K/A/answer幅も `WIDTH` に連動させる。

```text
VALUE_BYTES = ceil(WIDTH / 8)
            = (WIDTH + 7) / 8
```

各値は `VALUE_BYTES` byte の unsigned big-endian とする。

例:

```text
WIDTH=8      VALUE_BYTES=1
WIDTH=9..16  VALUE_BYTES=2
```

前SPECの32bit固定framingは使用しない。

---

## 4. 値の妥当性

受信値はゼロ拡張した整数として解釈する。

有効条件:

```text
N <= N_MAX
K <= N
Ai < MOD
```

を満たさない値はprotocol errorとする。

WIDTHがbyte境界でない場合も、
有効値条件によって上位余剰bitを含む不正値は自然に拒否される。

有効Aiに対する一般的なMOD正規化は要求しない。

---

## 5. SPI基本条件

SPI V3の基本command体系を維持する。

```text
RESET = 0xFF
START = 0xFE
DEBUG = 0xFD
NOP   = 0x00

RESET_ACK = 0x5A
START_ACK = 0xA5
```

baseline SPI clock:

```text
4 MHz
CPOL=0
CPHA=0
```

responseは従来どおり1 byte遅延を持つ。

command byteはcommandを期待しているphaseでのみcommandとして解釈する。

N/K/A payload受信中の `0xFD / 0xFE / 0xFF` はpayload byteとして扱い、
途中でcommandへ化けてはならない。

---

## 6. 入力framing

START後、次の順で受信する。

```text
N
K
A1
A2
...
AN
```

各項目はちょうど `VALUE_BYTES` byte のbig-endian。

例:

```text
WIDTH=8:
    N,K,Ai は各1 byte

WIDTH=10:
    N,K,Ai は各2 byte
```

余分なpayload、途中での不正sequence、無効N/K/Aはsticky protocol errorとする。

---

## 7. 出力framing

計算結果は常に、

```text
0 <= answer < MOD
```

である。

answerは `VALUE_BYTES` byte unsigned big-endianで返す。

STATUSは1 byteのままとする。

したがって正常完了時の論理的なresponse payloadは、

```text
STATUS
answer[VALUE_BYTES]
```

となる。

---

## 8. ERROR

protocol errorはRESETまでstickyとする。

少なくとも次をerror対象とする。

```text
N=0
N>N_MAX
K=0
K>N
Ai>=MOD
N個受信後の余分なpayload
不正sequence
```

RESETでERRORと処理状態を初期化する。

---

## 9. 正しさ

RTLの期待値は、
実装内部のS1/S2式や係数式をそのまま模倣せず、
小規模caseでは問題定義からの独立brute forceで照合する。

境界値を含める。

```text
Ai=0
Ai=MOD-1
K=1
K=N
N=1,K=1
```

---

## 10. WIDTH別の基準設定

少なくとも次を基準設定とする。

```text
WIDTH=8   MOD=251   N_MAX=250
WIDTH=9   MOD=509   N_MAX=508
WIDTH=10  MOD=1021  N_MAX=1020
```

WIDTH=11以上も同じ規則で設定できる。

---

## 11. Shrike-Lite target

target FPGAはShrike-Lite Type=Lとする。

```text
Type=L capacity = 140
```

ただしSPECとしてfitを保証するものではない。

fit判定、Post-Synthesis screening、PNR実施条件はIMPL/WORKで定める。

---

## 12. SPECで規定しない事項

以下は内部実装でありSPECでは規定しない。

```text
S1/S2の保持方法
combination計算方式
inverse / pow方式
multiplier構造
add/sub構造
FSM/state数
microcode使用有無
scratch register共有
operand staging
register file
bit-serial化
演算cycle数
内部counter幅
```

外部contractと数学的正しさを満たす限り変更可能である。
