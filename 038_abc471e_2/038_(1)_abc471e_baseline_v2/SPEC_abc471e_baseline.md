# ABC471E FPGA実装仕様 - Baseline

## 目的

AtCoder ABC471E「Sum of Square of Sum」をShrike-Lite上で計算する。

`N`個の値`A1..AN`から`K`個を選び、選んだ値の和の2乗をすべての選び方について合計し、`998244353`で割った余りを回答とする。

Baselineでは、理解しやすい次の3状態方式をそのまま回路化する。

```text
prefix_sum
square_sum
pair_sum
```

各入力`x`について、

```text
pair_sum   += x * prefix_sum
square_sum += x * x
prefix_sum += x
```

を`MOD = 998244353`上で実行する。

**Baselineでは`pair_sum`を削除しない。**

Shrike-Liteへ入らなかった場合も、Codexが勝手に別方式へ変更せず、合成結果を見て次の設計を決める。

---

## Baselineの狙い

確認したいのは次の処理である。

```text
Aiを1個受信
    ↓
最終回答に必要な情報を3状態へ反映
    ↓
Aiそのものは捨てる
    ↓
次のAiへ進む
```

配列`A`全体は保存しない。

Baseline評価後の判断は次の順序とする。

```text
Baselineが入る
    -> 3状態方式を採用

入らない
    -> pair_sumを持たない第二形態を別仕様で検討

第二形態でも入らない
    -> Aiのbit幅やMODを縮小した実験を別仕様で検討
```

---

## 問題の整理

例えば`A,B,C`を選んだ場合、

```text
(A+B+C)^2
= A^2 + B^2 + C^2 + 2AB + 2AC + 2BC
```

となる。

全ての`K`個選択を足し合わせると、ある`Ai^2`は

```text
C(N-1,K-1)
```

回現れる。

異なる2要素`Ai,Aj`を両方含む選び方は

```text
C(N-2,K-2)
```

通りであり、展開では`Ai*Aj`と`Aj*Ai`の2回現れる。

そこで、

```text
square_sum = Σ Ai^2
pair_sum   = Σ(i<j) Ai*Aj
```

とすると、

```text
answer =
    C(N-1,K-1) * square_sum
  + 2 * C(N-2,K-2) * pair_sum
```

となる。

すべて`MOD`で剰余を取る。

---

## ストリーム更新

`x = Ai`を受信する直前に、

```text
prefix_sum = A1 + ... + A(i-1)
```

が保持されている。

したがって、

```text
x * prefix_sum
```

は`x`と過去の全要素とのペア積の総和になる。

更新順序は次のとおり。

```text
old_prefix = prefix_sum

pair_sum   = pair_sum   + x * old_prefix
square_sum = square_sum + x * x
prefix_sum = old_prefix + x
```

すべて`mod MOD`。

**pair_sumには更新前のprefix_sumを使うこと。**

先に`prefix_sum += x`すると`x*x`がpair_sumへ混ざるため不可。

1要素の処理が終われば、その`Ai`を再度読む必要はない。

---

## 数値条件

Baselineでは次を使用する。

```text
MOD   = 998244353
N_MAX = 200000

1 <= K <= N
```

`N`, `K`, `A_i`はSPI上では32bit unsignedで扱う。

`A_i`は受信後に`MOD`へ正規化する。

剰余値は、

```text
0 <= value < MOD < 2^30
```

なので、主要なmod値は30bitで保持する。

32bit入力の正規化は一般的な除算器や`%`回路を使わず、

```text
while x >= MOD:
    x -= MOD
```

の逐次減算でよい。

32bit unsigned範囲なら減算回数は少数回で済む。

---

## 開発方針

既存のSPIテンプレートV3をベースにする。

主な変更対象:

```text
ffpga/src/main.v
firmware/micropython/abc471e_baseline_test.py
```

必要なら、

```text
sim/abc471e_baseline_tb.v
```

を新規作成してよい。

次は原則変更しない。

```text
ffpga/src/spi_target.v
reference/以下
```

新しいRTLソースは原則増やさず、Baselineの算術回路は`main.v`へ実装する。

---

## ディレクトリ

```text
abc471e_baseline/
│  abc471e_baseline.ffpga
│  SPEC_abc471e_baseline.md
│
├─bitstream
├─ffpga
│  ├─src
│  │      main.v
│  │      spi_target.v
│  └─timing-constraints
│          atcoder_spi_template_v3.sdc
│
├─firmware
│  └─micropython
│          abc471e_baseline_test.py
│
├─reference
│  │  README.md
│  ├─abc468c
│  └─atcoder_spi_template_v3
│
└─sim
       abc471e_baseline_tb.v
```

`sim/`は必要ならCodexが作成する。

---

## SPI基本プロトコル

SPIテンプレートV3を維持する。

| 用途 | 値 |
|---|---:|
| NOP | `0x00` |
| DEBUG | `0xFD` |
| START | `0xFE` |
| RESET | `0xFF` |
| RESET_ACK | `0x5A` |
| START_ACK | `0xA5` |

SPIクロックは4MHz。

SPI応答は1byte遅延。

基本シーケンス:

```text
RESET
RESET_ACK確認
START
START_ACK確認
SEND_N
SEND_K
SEND_A_STREAM
回答ポーリング
回答受信
```

---

## payload中の予約値

ABC471Eでは32bit値をraw byte列で送るため、

```text
0x00
0xFD
0xFE
0xFF
```

がデータ中に現れうる。

したがって、payload受信中はこれらをコマンドとして解釈しない。

```text
制御待ち状態:
    RESET / START / NOPをコマンドとして解釈

N/K/A payload受信状態:
    すべてのbyteをデータとして解釈
```

特にpayload中の`0xFF`でRESETしてはいけない。

payload受信中に中断したい場合は外部`rst_n`を使用してよい。

`spi_target.v`の変更は不要。

---

## 32bit転送形式

`N`, `K`, `A_i`は32bit big-endian。

```text
byte 0 : value[31:24]
byte 1 : value[23:16]
byte 2 : value[15:8]
byte 3 : value[7:0]
```

送信順:

```text
N
K
A1
A2
...
AN
```

`A_i`ごとの追加コマンドは使わない。

---

## Aストリーム

FPGA側は4byteごとに32bit wordを組み立てる。

CS境界を論理的な要素境界として扱う必要はない。

MicroPython側は複数要素をチャンク化して送ってよい。

例:

```text
16要素 = 64byte
32要素 = 128byte
```

最低限、次を持つ。

```text
rx_word_shift : 32bit
rx_byte_count : 2bit
x_reg         : 現在計算中のAi
x_busy
input_count
```

A受信中に32bit wordが完成したとき、

```text
x_busy == 0
    -> x_regへ渡して処理開始

x_busy == 1
    -> protocol_error
```

とする。

SPI byte assemblyは算術FSMの実行中も進めてよい。

---

## 1要素あたりの時間

SPI 4MHzでは1byte約2us、32bit値は約8us。

50MHz FPGAでは、

```text
約400 clocks / Ai
```

ある。

Baselineでは、

```text
入力値のmod正規化
x * prefix_sum
pair_sum更新
x * x
square_sum更新
prefix_sum更新
```

を可能なら次の32bit word完成までに終える。

ただし初版は面積優先。

400クロックを超える場合は、まず正しさ確認のためMicroPython側にpacingを入れてもよい。

その場合も、勝手に大型並列乗算器へ変更しない。

---

## 累積状態

初期値:

```text
prefix_sum = 0
square_sum = 0
pair_sum   = 0
```

すべて30bitで、

```text
0 <= value < MOD
```

を維持する。

---

## 共有modular multiplier

Baselineでは**可変乗算器は1個**とする。

次の全用途で共有する。

```text
x * prefix_sum
x * x

組合せ係数計算
modular inverse計算

coeff_square * square_sum
coeff_pair * pair_sum
```

30bit級の可変`*`を複数展開しない。

面積優先で逐次型modular multiplierを使う。

---

## 逐次modular multiplier

概念的にはshift-add方式でよい。

入力:

```text
lhs < MOD
rhs < MOD
```

処理:

```text
acc = 0
a = lhs
b = rhs

for 30bit:
    if b[0]:
        acc = (acc + a) mod MOD

    a = (a + a) mod MOD
    b >>= 1
```

modは比較と加減算で行う。

一般的な乗算器、除算器、剰余演算器は作らない。

面積を減らすため、

```text
acc + a
a + a
```

で同じ31bit級加算器を時間共有してよい。

その場合、1乗算が約60クロックでもよい。

---

## modular add / sub

`a,b < MOD`の場合、

```text
sum = a + b
if sum >= MOD:
    sum -= MOD
```

とする。

2倍も乗算器を使わず、

```text
x2 = x + x
if x2 >= MOD:
    x2 -= MOD
```

で求める。

必要なmodular subtractionは、

```text
if a >= b:
    result = a - b
else:
    result = a + MOD - b
```

でよい。

---

## 1要素の算術手順

`x_raw`受信後:

```text
1. x = x_raw mod MOD

2. old_prefix = prefix_sum

3. product = mul_mod(x, old_prefix)

4. pair_sum =
       add_mod(pair_sum, product)

5. product = mul_mod(x, x)

6. square_sum =
       add_mod(square_sum, product)

7. prefix_sum =
       add_mod(old_prefix, x)

8. input_count += 1
```

乗算器は1個だけ使う。

`old_prefix`はpair_sum更新まで保持する。

`input_count == N`で入力処理を終了し、係数計算へ進む。

---

## 組合せ係数

必要な係数:

```text
coeff_square = C(N-1,K-1)
coeff_pair   = C(N-2,K-2)
```

階乗テーブルをBRAMへ保存しない。

### coeff_square

```text
n = N - 1
r = K - 1
r = min(r, n-r)

numerator   = 1
denominator = 1

for i = 1..r:
    numerator =
        mul_mod(numerator, n-r+i)

    denominator =
        mul_mod(denominator, i)

inv_denominator =
    pow_mod(denominator, MOD-2)

coeff_square =
    mul_mod(numerator, inv_denominator)
```

`r==0`なら、

```text
coeff_square = 1
```

とする。

`n-r+i`, `i`は`N_MAX < MOD`なので、そのまま30bitのmod値として扱える。

---

## modular inverse

`MOD=998244353`は素数なので、0でない`a`に対し、

```text
a^(-1) = a^(MOD-2) mod MOD
```

を使う。

binary exponentiation:

```text
result = 1
base = a
exp = MOD - 2

while exp != 0:
    if exp[0]:
        result = mul_mod(result, base)

    base = mul_mod(base, base)
    exp >>= 1
```

ここでも同じ共有multiplierを使う。

---

## coeff_pair

`K==1`なら、

```text
coeff_pair = 0
```

とする。

`K>=2`では、

```text
C(N-2,K-2)
=
C(N-1,K-1) * (K-1) / (N-1)
```

を利用する。

```text
inv_n_minus_1 =
    pow_mod(N-1, MOD-2)

coeff_pair =
    coeff_square
    * (K-1)
    * inv_n_minus_1
    mod MOD
```

`N=1,K=1`では`N-1`のinverseを求めない。

---

## 最終回答

```text
term_square =
    mul_mod(coeff_square, square_sum)

term_pair =
    mul_mod(coeff_pair, pair_sum)

term_pair =
    add_mod(term_pair, term_pair)

answer =
    add_mod(term_square, term_pair)
```

`answer`は30bit residue。

出力では32bitにゼロ拡張する。

---

## 特殊ケース

### K=1

ペア項は存在しない。

```text
coeff_square = 1
coeff_pair   = 0
answer       = square_sum
```

係数計算を省略してよい。

### N=1,K=1

```text
answer = A1^2 mod MOD
```

`inverse(0)`を実行しない。

### K=N

一般式で正しく計算できることをテストする。

---

## 主要レジスタ

名称は実装に合わせて変更してよい。

| レジスタ | 幅 | 用途 |
|---|---:|---|
| `n_reg` | 32bit | N |
| `k_reg` | 32bit | K |
| `input_count` | 32bit | 処理済みAi数 |
| `rx_word_shift` | 32bit | 4byte assembly |
| `rx_byte_count` | 2bit | byte位置 |
| `x_raw` | 32bit | 受信Ai |
| `x_reg` | 30bit | Ai mod MOD |
| `old_prefix` | 30bit | 更新前prefix |
| `prefix_sum` | 30bit | ΣAi |
| `square_sum` | 30bit | ΣAi^2 |
| `pair_sum` | 30bit | Σ(i<j)AiAj |
| `coeff_square` | 30bit | C(N-1,K-1) |
| `coeff_pair` | 30bit | C(N-2,K-2) |
| `answer` | 30bit | 回答 |
| `protocol_error` | 1bit | sticky error |
| `reply_valid` | 1bit | 回答有効 |

modular multiplier用レジスタは追加してよい。

---

## FSMの大分類

概念的には、

```text
WAIT_START
RECEIVE_N
RECEIVE_K
STREAM_A
COEFF_CALC
FINAL_CALC
SEND_REPLY
```

を持つ。

modular multiplierとpow処理は小FSMとして分離してよい。

不要な大規模抽象化は行わない。

---

## 回答フォーマット

STATUS 1byte + ANSWER 4byte。

```text
byte 0 : STATUS
byte 1 : answer[31:24]
byte 2 : answer[23:16]
byte 3 : answer[15:8]
byte 4 : answer[7:0]
```

STATUS:

```text
bit 7   : VALID
bit 6   : ERROR
bit 5:0 : 0
```

代表値:

```text
0x00 : 未完了
0x80 : 正常完了
0xC0 : エラー付き完了
```

RP2040側はNOPでSTATUSをポーリングし、VALID後にNOPを送って4byte回答を取得する。

SPIの1byte応答遅延を考慮する。

---

## エラー検出

最低限、

```text
N == 0
N > N_MAX
K == 0
K > N

32bit Ai word完成時に前のxがbusy
N個処理後に追加payload受信
想定外状態でpayload受信
想定外状態で制御byte受信
```

を検出する。

`protocol_error`はRESETまでsticky。

入力値は原問題側で保証されるため、エラー回路は過度に複雑化しない。

---

## RESET

RESETまたは外部`rst_n`で少なくとも次を初期化する。

```text
state

n_reg
k_reg
input_count

word assembler
x処理状態

prefix_sum
square_sum
pair_sum

組合せ係数計算状態
modular multiplier状態

coeff_square
coeff_pair
answer

protocol_error
reply_valid
tx_data
```

RESET_ACKはSPIテンプレートV3に合わせる。

---

## MicroPythonテスト

`abc471e_baseline_test.py`では、

```text
RESET
RESET_ACK
START
START_ACK
SEND_N
SEND_K
SEND_A_STREAM
STATUS polling
ANSWER受信
期待値比較
```

を行う。

---

## 独立した期待値計算

小さいケースではFPGA側の式をそのまま複製せず、Pythonで組み合わせを実際に列挙する。

```python
from itertools import combinations

def brute_force_expected(a, k, mod=998244353):
    total = 0
    for selected in combinations(a, k):
        s = sum(selected)
        total = (total + s * s) % mod
    return total
```

これを基準値とする。

大きいケースではPythonの`math.comb()`等を使った別方式を追加してよい。

---

## 必須テスト

最低限、

```text
N=1,K=1
K=1
K=N
```

を含める。

手計算例:

```text
A = [1,2,3]
K = 2

[1,2] -> 9
[1,3] -> 16
[2,3] -> 25

EXPECT = 50
```

ランダム小ケースは、

```text
N <= 8程度
1 <= K <= N
```

で多数生成し、全組み合わせ列挙と比較する。

算術回路ストレス用として、原問題の有効入力とは別に、

```text
MOD-1
MOD
MOD+1
2*MOD
2^32-1
```

も試してよい。

---

## 3状態の途中確認

可能ならシミュレーションで途中状態も確認する。

```text
A = [1,2,3]
```

の場合、

```text
初期:
prefix_sum = 0
square_sum = 0
pair_sum = 0

1処理後:
prefix_sum = 1
square_sum = 1
pair_sum = 0

2処理後:
prefix_sum = 3
square_sum = 5
pair_sum = 2

3処理後:
prefix_sum = 6
square_sum = 14
pair_sum = 11
```

`pair_sum=1*2+1*3+2*3=11`。

---

## Icarus Verilogテスト

必要なら`sim/abc471e_baseline_tb.v`を作成する。

最低限、

```text
SPI RESET / START
32bit N/K受信
32bit Ai受信
payload中0xFFがRESET扱いされない
3状態更新
K=1
K=N
mod境界
STATUS + 4byte回答
ERROR sticky
```

を確認する。

---

## 実機ログ

MicroPythonテストでは少なくとも、

```text
NAME
N
K
RESULT
EXPECT
VALID
ERROR
PASS
TIME_US
POLL_COUNT
RESET_ACK_RX
START_ACK_RX
```

を表示する。

大規模配列では全入力をログへ出さない。

---

## 性能記録

Baselineでは可能なら次を報告する。

```text
共有modular multiplierの1乗算クロック
1 Aiあたりの処理クロック
組合せ係数計算クロック
最終計算クロック
```

4MHz SPIで32bit/Aiなので理想転送時間は約8us/Ai。

`N=200000`では入力転送だけで約1.6秒相当になるため、通信時間も観測対象とする。

Baselineの最初の実機テストで最大ケースを必須とはしない。

---

## 合成後に見る項目

ForgeFPGA Workshopで、

```text
CLB LUT
FF
CLB
BRAM
PLL
WNS
Achievable Frequency
```

を記録する。

特に、

```text
共有modular multiplierの面積
mod比較・加減算回路の面積
50MHz制約を満たすか
```

を見る。

---

## Baselineで行わないこと

Codexは勝手に次を行わない。

```text
pair_sumを削除
prefix_sum^2-square_sum方式へ変更

MODを変更
Aiを16bit化
N_MAXを縮小

複数modular multiplierを作成
階乗テーブルをBRAMへ作成
A配列をBRAMへ保存
```

Baselineが重ければ、その事実を報告して止める。

---

## Codex実装後の報告

最低限、

```text
変更ファイル一覧

3状態更新の実装位置

modular multiplier方式
1乗算あたりのクロック
1 Aiあたりのクロック

組合せ係数計算方式
K=1/N=1特殊処理

Icarus結果
ランダムテスト数
protocol test結果

spi_target.vを変更したか
reference/以下を変更していないか

実機flashは行っていないこと
```

を報告する。

ForgeFPGA WorkshopをCodex環境から実行できない場合は、合成を行わずその旨だけ報告する。

---

## 完了条件

ソフトウェア側Baseline完了条件:

```text
VerilogがIcarusでコンパイル可能

SPI Template V3のRESET/STARTが動作

N,K,Aを32bitで受信
payload中の予約値をdataとして扱える

A全体を保存しない

prefix_sum
square_sum
pair_sum

の3状態を逐次更新

可変modular multiplierは1個
入力処理・係数計算・最終計算で共有

MOD = 998244353

C(N-1,K-1)を計算
C(N-2,K-2)を計算
K=1/N=1を正しく処理

STATUS + 4byteで回答

小ケースの全組み合わせ基準値と一致
ランダム小ケースPASS
protocol/error test PASS

spi_target.vは原則変更なし
reference/以下変更なし
```

その後ユーザーがForgeFPGA Workshopで合成する。

Baseline評価は次のどちらでも完了とする。

```text
A:
正しさ確認
+ 合成可能
+ 実機PASS

B:
正しさ確認
+ 合成したがリソースまたはTiming上の理由で実装困難
+ 結果を記録
```

Bも有効な実験結果とする。

第二形態への変更は、このBaseline評価後に別仕様として行う。
