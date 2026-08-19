# ABC471E FPGA実装仕様 - S1/S2

## 目的

AtCoder ABC471E「Sum of Square of Sum」をShrike-Lite上で計算する。

`N`個の値`A1..AN`から`K`個を選び、選んだ値の和を2乗した値をすべての選び方について合計し、`998244353`で割った余りを回答とする。

本版はBaselineの第二形態として、入力列から次の2状態だけを保持する。

```text
S1 = Σ Ai
S2 = Σ Ai^2
```

Baseline V1/V2で保持していた

```text
pair_sum = Σ(i<j) Ai*Aj
```

は保持しない。

最終段で、

```text
2 * pair_sum = S1^2 - S2
```

を利用してペア項を復元する。

---

## S1/S2版の狙い

Baseline V1/V2では次の3状態を保持した。

```text
prefix_sum
square_sum
pair_sum
```

本版ではこれを、

```text
S1
S2
```

へ縮約する。

入力`Ai`を1個受信するたびに、

```text
S1 += Ai
S2 += Ai^2
```

だけを更新する。

これにより、

- `pair_sum`状態を削除
- `old_prefix`状態を削除
- 入力ごとの`Ai * prefix_sum`乗算を削除
- pair_sum更新用データパスを削除

する。

配列`A`全体は保存しない。

---

## 問題の整理

例えば`A,B,C`を選んだ場合、

```text
(A+B+C)^2
= A^2 + B^2 + C^2
  + 2AB + 2AC + 2BC
```

となる。

全ての`K`個選択を足し合わせると、ある`Ai^2`は、

```text
C(N-1,K-1)
```

回現れる。

異なる2要素`Ai,Aj`を両方含む選び方は、

```text
C(N-2,K-2)
```

通りである。

したがって、

```text
answer =
    C(N-1,K-1) * ΣAi^2
  + C(N-2,K-2) * 2Σ(i<j)AiAj
```

となる。

---

## S1/S2への縮約

次を定義する。

```text
S1 = Σ Ai
S2 = Σ Ai^2
```

`S1^2`を展開すると、

```text
S1^2
= ΣAi^2 + 2Σ(i<j)AiAj
```

なので、

```text
2Σ(i<j)AiAj
= S1^2 - S2
```

である。

よって最終回答は、

```text
coeff_square = C(N-1,K-1)
coeff_pair   = C(N-2,K-2)

pair_twice =
    S1^2 - S2 mod MOD

answer =
    coeff_square * S2
  + coeff_pair * pair_twice
    mod MOD
```

と計算できる。

本版ではこの式を使用する。

さらに別の組合せ恒等式へ変形するなど、追加の数学的最適化は行わない。

---

## ストリーム更新

入力`x = Ai`を受信したら、まず`MOD`へ正規化する。

その後、

```text
product = x * x mod MOD

S2 = S2 + product mod MOD
S1 = S1 + x       mod MOD
```

とする。

1要素の処理が終われば、その`Ai`を再度読む必要はない。

Baseline V1/V2で必要だった、

```text
old_prefix
pair_sum
x * old_prefix
```

は本版では不要である。

---

## 数値条件

```text
MOD   = 998244353
N_MAX = 200000

1 <= K <= N
```

`N`, `K`, `A_i`はSPI上では32bit unsignedとして扱う。

`A_i`は受信後に`MOD`へ正規化する。

主要なmod値は、

```text
0 <= value < MOD < 2^30
```

なので30bitで保持する。

32bit入力の正規化は一般的な除算器や`%`回路を使わず、

```text
while x >= MOD:
    x -= MOD
```

の逐次減算でよい。

---

## 開発方針

SPI Template V3とBaseline V2の外部仕様を維持する。

実装の出発点はBaseline V2とし、S1/S2化に必要な変更だけを行う。

主な変更対象:

```text
ffpga/src/main.v
sim/abc471e_s1s2_tb.v
```

MicroPython側は外部仕様が同じため、原則としてBaselineのテストを流用してよい。

例:

```text
firmware/micropython/abc471e_s1s2_test.py
```

次は原則変更しない。

```text
ffpga/src/spi_target.v
reference/以下
```

---

## 推奨ディレクトリ

```text
abc471e_s1s2/
│  abc471e_s1s2.ffpga
│  SPEC_abc471e_s1s2.md
│  IMPL_REQUEST_abc471e_s1s2.md
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
│          abc471e_s1s2_test.py
│
├─reference
│  ├─abc471e_baseline_v1
│  ├─abc471e_baseline_v2
│  └─atcoder_spi_template_v3
│
└─sim
       abc471e_s1s2_tb.v
```

実際のフォルダ名は作業環境に合わせてよい。

`reference/`以下は参照専用とする。

---

## SPI基本プロトコル

SPI Template V3を維持する。

| 用途 | 値 |
|---|---:|
| NOP | `0x00` |
| DEBUG | `0xFD` |
| START | `0xFE` |
| RESET | `0xFF` |
| RESET_ACK | `0x5A` |
| START_ACK | `0xA5` |

SPIクロックは4MHzをBaseline値とする。

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

`A_i`は32bit raw byte列で送るため、

```text
0x00
0xFD
0xFE
0xFF
```

が通常データとして現れうる。

payload受信状態ではこれらをコマンドとして解釈しない。

```text
制御待ち状態:
    RESET / START / NOPをコマンドとして解釈

N/K/A payload受信状態:
    全byteをデータとして解釈
```

特にpayload中の`0xFF`でRESETしてはいけない。

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

CS境界を論理的な要素境界として使用しない。

MicroPython側は複数要素をチャンク化して送ってよい。

32bit word完成時に前の`Ai`処理が終わっていなければ、Baselineと同様に`protocol_error`をセットする。

---

## 1要素あたりの時間

SPI 4MHzでは32bit `Ai` 1個の転送は約8us。

50MHz FPGAでは、

```text
約400 clocks / Ai
```

の時間がある。

S1/S2版では入力1個につき必要な可変乗算は、

```text
x * x
```

の1回だけである。

Baseline V1/V2の、

```text
x * old_prefix
```

は不要。

共有modular multiplierが60クロック/乗算であれば、入力処理は400クロック/Ai以内へ十分収めることを目標とする。

---

## 累積状態

初期値:

```text
S1 = 0
S2 = 0
```

常に、

```text
0 <= S1 < MOD
0 <= S2 < MOD
```

を維持する。

`pair_sum`は持たない。

---

## 共有modular multiplier

可変modular multiplierは1個だけ配置する。

Baseline V1/V2の30-bit shift-add modular multiplierを可能な限りそのまま使用する。

想定性能:

```text
1 modular multiplication = 60 clocks
```

用途:

```text
入力:
    x * x

組合せ係数:
    分子・分母の逐次積
    binary exponentiation

最終計算:
    S1 * S1
    coeff_square * S2
    coeff_pair * pair_twice
```

一般的な30bit可変`*`を追加しない。

---

## modular add / sub

modular add:

```text
sum = a + b
if sum >= MOD:
    sum -= MOD
```

modular subtraction:

```text
if a >= b:
    result = a - b
else:
    result = a + MOD - b
```

S1/S2版では最終段で、

```text
pair_twice = S1_squared - S2 mod MOD
```

を計算するため、modular subtractionが必要である。

Baseline V2の共有modular addデータパスを基礎に、必要ならadd/subを同じ算術データパスで共有してよい。

ただし複数の30bit add/sub回路を不用意に複製しない。

具体的な共有方法は`IMPL_abc471e_s1s2.md`で決める。

---

## 1要素の算術手順

`x_raw`受信後:

```text
1. x = x_raw mod MOD

2. product =
       mul_mod(x, x)

3. S2 =
       add_mod(S2, product)

4. S1 =
       add_mod(S1, x)

5. input_count += 1
```

可変乗算は1回だけ。

`input_count == N`で入力処理を終了し、組合せ係数計算へ進む。

---

## 組合せ係数

Baseline V1/V2と同じ2係数を使用する。

```text
coeff_square = C(N-1,K-1)
coeff_pair   = C(N-2,K-2)
```

階乗テーブルは作らない。

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

`r==0`なら`coeff_square=1`。

### coeff_pair

`K==1`なら、

```text
coeff_pair = 0
```

とする。

`K>=2`ではBaselineと同じく、

```text
coeff_pair =
    coeff_square
    * (K-1)
    * inverse(N-1)
    mod MOD
```

で求める。

本版では組合せ係数の数学的な追加最適化を行わない。

---

## modular inverse

`MOD=998244353`は素数なので、

```text
inverse(a) = a^(MOD-2) mod MOD
```

を使用する。

binary exponentiationと共有multiplierを使用する。

`N=1,K=1`では`inverse(0)`を実行しない。

---

## 最終回答計算

入力集計と係数計算の完了後、概念的に次を行う。

```text
1. s1_square =
       mul_mod(S1, S1)

2. pair_twice =
       sub_mod(s1_square, S2)

3. term_square =
       mul_mod(coeff_square, S2)

4. term_pair =
       mul_mod(coeff_pair, pair_twice)

5. answer =
       add_mod(term_square, term_pair)
```

`pair_twice`は最終計算用scratchとして扱い、専用レジスタを追加する必要がなければ既存scratchを再利用してよい。

最終回答:

```text
answer =
    C(N-1,K-1) * S2
  + C(N-2,K-2) * (S1^2 - S2)
    mod MOD
```

---

## 特殊ケース

### K=1

1個だけ選ぶ場合、

```text
answer = S2
```

となる。

可能なら係数計算と`S1^2`計算を省略してよい。

### N=1,K=1

```text
answer = A1^2 mod MOD
```

`inverse(0)`を実行しない。

### K=N

全要素を選ぶ方法は1通り。

一般式で、

```text
answer = S1^2 mod MOD
```

と一致することをテストする。

---

## 主要レジスタ

名称は実装に合わせて変更してよい。

最低限の論理状態:

| レジスタ | 幅 | 用途 |
|---|---:|---|
| `n_reg` | 32bit | N |
| `k_reg` | 32bit | K |
| `input_count` | 32bit | 処理済みAi数 |
| `rx_word_shift` | 32bit | 4byte assembly |
| `rx_byte_count` | 2bit | byte位置 |
| `x_raw` | 32bit | 受信Ai |
| `x_reg` | 30bit | Ai mod MOD |
| `s1` | 30bit | ΣAi mod MOD |
| `s2` | 30bit | ΣAi² mod MOD |
| `coeff_square` | 30bit | C(N-1,K-1) |
| `coeff_pair` | 30bit | C(N-2,K-2) |
| `answer` | 30bit | 最終回答 |
| `protocol_error` | 1bit | sticky error |
| `reply_valid` | 1bit | 回答有効 |

次は不要になる。

```text
old_prefix
pair_sum
```

最終計算用scratchや組合せ計算用scratchは既存レジスタを共有してよい。

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

入力処理は、

```text
normalize x
x*x
S2 update
S1 update
```

へ簡略化する。

具体的な状態分割は実装設計で決める。

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

Baselineで修正したSTATUSポーリング境界処理を維持する。

---

## エラー検出

Baselineと同じ外部エラー条件を維持する。

最低限:

```text
N == 0
N > N_MAX
K == 0
K > N

32bit Ai word完成時に前のxがbusy
N個処理後に追加payload受信
想定外状態でpayload受信
```

`protocol_error`はRESETまでsticky。

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

S1
S2

組合せ係数計算状態
modular multiplier状態
modular add/sub状態

coeff_square
coeff_pair
answer

protocol_error
reply_valid
tx_data
```

`pair_sum`や`old_prefix`は存在しない。

---

## MicroPythonテスト

外部SPI仕様と回答はBaselineと同じなので、MicroPython側の通信処理と独立期待値計算は原則そのまま流用できる。

小さいケースでは全組み合わせ列挙で期待値を求める。

```python
from itertools import combinations

def brute_force_expected(a, k, mod=998244353):
    total = 0
    for selected in combinations(a, k):
        s = sum(selected)
        total = (total + s * s) % mod
    return total
```

bitstream名・表示名だけS1/S2版へ変更してよい。

---

## 必須テスト

Baselineで使用した外部テストを維持する。

最低限:

```text
N=1,K=1
K=1
K=N
手計算例
mod境界
payload中0xFF
ランダム小ケース
不正N/K
ERROR sticky
busy衝突
余分なpayload
STATUSポーリング境界
```

ランダム小ケースは独立な全組み合わせ列挙と比較する。

---

## S1/S2の途中確認

シミュレーションでは内部状態も確認する。

```text
A = [1,2,3]
```

の場合:

```text
初期:
S1 = 0
S2 = 0

1処理後:
S1 = 1
S2 = 1

2処理後:
S1 = 3
S2 = 5

3処理後:
S1 = 6
S2 = 14
```

最終的に、

```text
S1^2 - S2
= 36 - 14
= 22
```

となる。

これは、

```text
2 * (1*2 + 1*3 + 2*3)
= 22
```

と一致する。

Baselineの`pair_sum`内部値テストは、このS1/S2テストへ置き換える。

---

## Icarus Verilogテスト

S1/S2版用testbenchを作成またはBaseline testbenchから更新する。

既存の外部入出力・異常系テストを削除しない。

Baselineで111項目だった構成を基本として、3状態途中値テストをS1/S2途中値テストへ置き換え、同程度の独立検証を維持する。

テスト件数が変わる場合は理由をREPORTへ記録する。

---

## 性能記録

最低限次を測定する。

```text
共有modular multiplierの1乗算クロック
1 Aiあたりの処理クロック
```

Baseline V2:

```text
MUL_CLOCKS = 60
AI_MIN_CLOCKS = 130
AI_MAX_CLOCKS = 134
```

S1/S2版では入力ごとの乗算が2回から1回へ減るため、Ai処理クロックの短縮を期待する。

ただし本版の主目的は面積削減であり、速度短縮そのものを完了条件とはしない。

---

## 合成後に見る項目

ForgeFPGA Workshopで最低限次を記録する。

```text
CARRY4
FDCE
FDPE
LUT2
LUT3
LUT4
LUT5
LUT6

Estimated number of LCs

PNR:
Type=L Capacity / Utilized
LUT usage
FF usage

WNS
Achievable Frequency
```

Baseline V2との比較を行う。

---

## S1/S2版で行わないこと

Codexは勝手に次を行わない。

```text
MODを変更
Aiを16bit化
N_MAXを縮小

組合せ係数の別アルゴリズム化
階乗テーブルをBRAMへ作成
A配列をBRAMへ保存

複数modular multiplierを作成
一般的な除算器・剰余器を作成

SPIプロトコルを変更
spi_target.vを変更
reference/以下を変更
```

S1/S2版でもShrike-Liteへ入らない場合は、その結果を報告して止める。

数値条件の縮小は次段階の別実験とする。

---

## Codex実装後の報告

最低限次を記録する。

```text
変更ファイル一覧

S1/S2更新の実装位置
pair_sum / old_prefixを削除したこと

modular multiplier方式
1乗算あたりのクロック
1 Aiあたりのクロック

S1^2-S2の実装方法

組合せ係数計算方式

Icarus結果
ランダムテスト数
protocol test結果

spi_target.v未変更
reference/以下未変更

ForgeFPGA Workshop未実施
実機flash未実施
```

---

## 完了条件

Codex側のソフトウェア完了条件:

```text
VerilogがIcarusでコンパイル可能

SPI Template V3の外部仕様を維持

N,K,Aを32bitで受信

A全体を保存しない

S1 = ΣAi
S2 = ΣAi²

の2状態を逐次更新

pair_sumを保持しない
old_prefixを保持しない

入力1個あたり可変乗算はx*xの1回

共有modular multiplierは1個

C(N-1,K-1)を計算
C(N-2,K-2)を計算

S1²-S2で2*pair_sum相当を復元

STATUS + 4byteで回答

小ケースの全組み合わせ基準値と一致
ランダム小ケースPASS
protocol/error test PASS

spi_target.v未変更
reference/以下未変更
```

その後、ユーザーがForgeFPGA WorkshopでLint、合成、PNRを行う。

S1/S2版がShrike-Liteへ収まること自体はCodex側の完了条件ではない。

入らなかった場合も有効な実験結果とする。
