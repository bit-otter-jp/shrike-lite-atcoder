# ABC471E Narrow - IMPL

## 1. 文書の役割

この文書は `abc471e_narrow` の**内部実装方針と内部制約**を定義する。

SPECを満たす方法は複数あり得るが、
本プロジェクトの通常のWIDTH sweepでは本書の設計方針を維持する。

性能や面積が良くなるという理由だけで、
Codexが勝手に別アーキテクチャへ変更してはいけない。

作業手順、実験順序、停止条件、成果物は `WORK_REQUEST` で定義する。

参照先は `REFERENCE_MAP.md` の論理名を使用する。

---

## 2. 基準アーキテクチャ

直接の設計基準は、

```text
S1S2_30BIT_BASELINE
```

とする。

narrow版では30bit S1/S2版の数学構造と制御構造を可能な限り保ち、
主要modular datapathの幅をcompile-time parameter `WIDTH` へ縮小する。

通常のWIDTH sweepでは、
「幅を縮めた効果」を他の最適化と混ぜないことを優先する。

---

## 3. 保持する数学表現

入力ストリームでは次の2状態を保持する。

```text
S1 = Σ Ai mod MOD
S2 = Σ Ai^2 mod MOD
```

入力xごとの概念処理:

```text
product = mul_mod(x, x)

S2 = add_mod(S2, product)
S1 = add_mod(S1, x)
```

配列A全体は保存しない。

`pair_sum` と `old_prefix` は持たない。

最終段では、

```text
pair_twice =
    S1^2 - S2 mod MOD
```

を用いる。

回答:

```text
answer =
    C(N-1,K-1) * S2
  + C(N-2,K-2) * pair_twice
    mod MOD
```

---

## 4. WIDTH parameterization

主要なmodular valueは `WIDTH` bitとする。

対象:

```text
x
S1
S2

numerator
denominator

pow_result
pow_base
pow_exp

coeff_square
coeff_pair
coefficient scratch

shared multiplier operand/result/internal modular state

top modular add/sub operand/result

final term / answer internal value
```

`MOD < 2^WIDTH` を前提とする。

WIDTHはruntime可変ではなくcompile-time configurationとする。

---

## 5. N / K / counter内部幅

SPECにより、

```text
N_MAX < MOD < 2^WIDTH
```

なので、32bit SPI wordとして受信・検証した後の、

```text
N
K
received_count
input_count
comb_n
comb_r
comb_i
```

等は、意味上必要な範囲で `WIDTH` bitへ縮小してよい。

ただしSPI word assembly自体は32bit外部framingに合わせて維持する。

32bitのまま保持する必要がない値を、
比較実験の全WIDTHで理由なく32bit固定しない。

---

## 6. Ai受信境界

SPI上のAiは32bitで受信する。

SPECでは有効入力を、

```text
0 <= Ai < MOD
```

に限定している。

したがって有効Aiについて一般的なmodulo正規化ループは不要。

受信値がMOD未満であることを検証し、
有効なら内部 `WIDTH` bit値として取り込む。

不正Aiはprotocol/error仕様に従う。

---

## 7. shared modular multiplier

可変modular multiplierは1個だけ持つ。

30bit S1/S2版のshift-add modular multiplierを基礎に、
bit幅を `WIDTH` へparameterizeする。

基本方針:

```text
1bit処理あたり2 phase
WIDTH bit全体で概ね 2*WIDTH clocks
```

30bit版の60clock構造との対応を維持する。

用途:

```text
入力:
    x * x

組合せ係数:
    numerator更新
    denominator更新
    Fermat binary exponentiation
    coefficient生成

最終:
    S1 * S1
    coeff_square * S2
    coeff_pair * pair_twice
```

WIDTH sweep中に複数multiplierへ増やさない。

一般的な可変 `*` へ勝手に置き換えない。

---

## 8. shared modular add/sub

top側のmodular add/subは、
30bit S1/S2版の共有構造を基礎に1系統で扱う。

必要機能:

```text
add_mod(a,b)
sub_mod(a,b)
```

主用途:

```text
S2 update
S1 update
S1^2 - S2
final add
```

WIDTH sweep中に、
用途ごとの専用add/sub回路へ勝手に複製しない。

---

## 9. 組合せ係数

通常のWIDTH sweepでは30bit S1/S2版と同じ数学方式を維持する。

```text
coeff_square = C(N-1,K-1)
coeff_pair   = C(N-2,K-2)
```

`coeff_square` は、

```text
n = N-1
r = K-1
r = min(r, n-r)

numerator   = Π(n-r+i)
denominator = Πi

inv_denominator =
    denominator^(MOD-2) mod MOD

coeff_square =
    numerator * inv_denominator mod MOD
```

で求める。

`K>=2` の `coeff_pair` は、

```text
coeff_pair =
    coeff_square
    * (K-1)
    * inverse(N-1)
    mod MOD
```

を基礎とする。

逆元はFermat:

```text
inverse(a) = a^(MOD-2) mod MOD
```

binary exponentiationとshared multiplierを使用する。

SPECの `N_MAX < MOD` により、
有効ケースでは係数計算に必要な1..Nの値が0 mod MODにならない。

---

## 10. 特殊ケース

少なくとも次は正しく扱う。

```text
K=1
N=1,K=1
K=N
```

`N=1,K=1` で `inverse(0)` を実行しない。

特殊ケースを利用して不要計算を省略してよいが、
WIDTHごとに異なる専用アーキテクチャを作らない。

---

## 11. 外部SPI境界

`spi_target.v` は `S1S2_30BIT_BASELINE` と同じものを原則そのまま使用する。

外部32bit framing、STATUS、1-byte response delay、
payload中予約値の扱いを維持する。

WIDTH sweepのためにSPI protocolを変更しない。

---

## 12. ソース構造

WIDTHごとに独立したRTLを手コピーして増殖させない。

基本は1つのparameterized RTLを使用する。

例:

```text
ffpga/src/main.v
ffpga/src/spi_target.v
```

WIDTH/MOD/N_MAXの切替は、
parameter、localparam、生成config、または小さなwrapper等で行ってよい。

ただし各実験点で、
実際に合成されたWIDTH/MOD/N_MAXを成果物から追跡できるようにする。

---

## 13. 比較実験の公平性

通常のWIDTH sweepでは、WIDTH以外の構造差を最小化する。

特に、あるWIDTHだけで次を行わない。

```text
bit-serial ALUへの全面変更
scratch registerの極端なlifetime共有
係数アルゴリズム変更
multiplier方式変更
FSMの全面再設計
SPI簡略化
定数係数化
テスト対象に合わせたspecial case回路
```

合成器自身のmapping差は許容する。

---

## 14. WIDTH sweep中に行わない最適化

次は、通常のWIDTH sweepでは禁止する。

```text
手段を問わない面積最適化
複数案の自動探索
bit-serial化
microcode化
register file化
係数計算方式の変更
外部から係数を供給
MODを実装都合だけで小さくする
N_MAXをWORK_REQUEST指定より小さくする
SPI framing変更
```

これらを試す場合は、
別の `WORK_REQUEST` で明示的に許可し、
必要ならIMPLを更新または派生IMPLを作成してから実施する。

---

## 15. 合成基準

Post-Synthesisは、

```text
FORGE_SYNTH_CLI_REFERENCE
```

で再現確認済みのForgeFPGA bundled Yosys flowを基準とする。

WIDTH間比較ではtool versionと主要synthesis optionを統一する。

合成条件を変更して面積を改善した場合は、
WIDTH効果と混同しないよう別実験として扱う。

---

## 16. 検証方針

Icarusでは各WIDTHについて少なくとも、

```text
RESET / START
N/K/A 32bit framing
S1/S2更新
K=1
N=1,K=1
K=N
Ai=0
Ai=MOD-1
不正N/K
Ai>=MOD
ERROR sticky
STATUS polling
4-byte answer
```

を確認する。

小さいNのランダムケースは、
問題定義から独立な全組合せ列挙と比較する。

shared multiplierが実際に使用されることも確認する。

---

## 17. 性能の考え方

WIDTHを狭めることでmultiplierの1演算clockも短くなることを期待する。

ただしnarrowプロジェクトの第一目的は面積スケーリングの観測であり、
性能最大化は通常のWIDTH sweepの目的ではない。

SPI 4MHzで入力が供給される外部条件に対して十分な場合、
より高速にするためだけの並列化は行わない。

---

## 18. IMPL変更原則

本IMPLは通常のWIDTH sweep用の内部設計方針である。

後に、

```text
あるWIDTHを何としても140 Type=Lへ詰める
```

等の別目的へ移る場合は、
WORK_REQUESTだけで内部設計を黙って破壊しない。

アーキテクチャ変更が必要なら、

```text
IMPLを更新する
または
派生IMPLを新規作成する
```

のいずれかを先に行い、
何を変更可能にしたかを明示する。
