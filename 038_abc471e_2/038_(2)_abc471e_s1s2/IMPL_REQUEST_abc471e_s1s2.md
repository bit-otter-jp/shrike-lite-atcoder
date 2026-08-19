# ABC471E S1/S2 実装要求

## 1. 目的

Baseline V1/V2では、

```text
prefix_sum
square_sum
pair_sum
```

の3状態を保持してABC471Eをストリーム処理した。

V1はIcarus 111項目PASS後に合成したが、Shrike-Liteへ収まらなかった。

V2では30-bit modular addを1系統へ時間共有し、Icarusでは次を確認した。

```text
PERF MUL_CLOCKS=60
PERF AI_MIN_CLOCKS=130
PERF AI_MAX_CLOCKS=134
SUMMARY TOTAL=111 PASS=111 FAIL=0
```

V2のPost-Synthesis結果:

```text
CARRY4 = 121
FDCE   = 1000
FDPE   = 8
```

V1の`CARRY4=183`からは減少したが、PNRは次の結果だった。

```text
Type=L
Capacity=140
Utilized=571

Usage of Logic CLBs = 407.9%
Usage of LUTs       = 385.2%
Usage of FF         = 157.1%

FATAL ERROR:
The design cannot fit into the current geometry.
```

V1の`Type=L Utilized=577`からほとんど改善していない。

したがって、局所的なmodular add共有だけでは面積不足を解消できないと判断する。

本版では数学表現そのものをS1/S2へ縮約する。

---

## 2. 実験目的

今回確認するのは、

```text
3状態:
prefix_sum
square_sum
pair_sum

        ↓

2状態:
S1 = ΣAi
S2 = ΣAi²
```

へ変更したときの効果である。

次の恒等式を使う。

```text
S1² = S2 + 2Σ(i<j)AiAj

2Σ(i<j)AiAj
= S1² - S2
```

これにより`pair_sum`を入力ストリーム中に保持しない。

V2からの主な削減対象:

```text
pair_sum 30bit
old_prefix 30bit

x * old_prefix の入力毎の乗算

pair_sum更新用FSM/operand選択/保存経路
```

---

## 3. 基準実装

実装の基準はBaseline V2とする。

最低限次を参照する。

```text
reference/abc471e_baseline_v2/
    SPEC / IMPL / REPORT
    ffpga/src/main.v
    ffpga/build/post_synth_report.txt
    ffpga/build/post_synth_results.v
    sim testbench
```

Baseline V1も比較用資料として参照してよい。

`reference/`以下は参照専用とし、変更しない。

---

## 4. 変更する数学

入力ストリームで保持する状態を、

```text
S1
S2
```

の2本とする。

入力`x`ごとの処理:

```text
x = x_raw mod MOD

product = mul_mod(x, x)

S2 = add_mod(S2, product)
S1 = add_mod(S1, x)
```

次は削除する。

```text
old_prefix
pair_sum
mul_mod(x, old_prefix)
pair_sum更新
```

最終段で、

```text
s1_square =
    mul_mod(S1, S1)

pair_twice =
    sub_mod(s1_square, S2)
```

を求める。

---

## 5. 最終回答

組合せ係数はBaselineと同じ。

```text
coeff_square = C(N-1,K-1)
coeff_pair   = C(N-2,K-2)
```

回答:

```text
answer =
    coeff_square * S2
  + coeff_pair * (S1² - S2)
    mod MOD
```

具体的には、

```text
s1_square =
    mul_mod(S1, S1)

pair_twice =
    sub_mod(s1_square, S2)

term_square =
    mul_mod(coeff_square, S2)

term_pair =
    mul_mod(coeff_pair, pair_twice)

answer =
    add_mod(term_square, term_pair)
```

とする。

本版ではこれ以上の式変形を行わない。

---

## 6. 維持するもの

次はBaseline V2から維持する。

```text
MOD = 998244353
N_MAX = 200000

32-bit unsigned A入力
32-bit big-endian SPI

SPI Template V3
STATUS + 4-byte answer
1-byte応答遅延

sticky protocol_error
STATUSポーリング競合対策

30-bit shift-add modular multiplier 1個
1乗算60クロック

組合せ係数の逐次積
Fermat逆元
binary exponentiation
```

`spi_target.v`は変更しない。

---

## 7. modular add/subデータパス

Baseline V2ではtop側のmodular addを1系統へ共有した。

S1/S2版でも、30-bit add/sub回路を不用意に複製しない。

最終段で、

```text
S1² - S2 mod MOD
```

が必要になるため、共有算術データパスをadd/subへ拡張してよい。

ただし実装要求段階では具体回路を固定しない。

CodexはV2 RTLとPost-Synthesis結果を確認し、

```text
operand選択
add/sub選択
result保存先
FSM状態
必要scratch
```

を設計して`IMPL_abc471e_s1s2.md`へ記述する。

共有化のためだけに大きなoperand保持レジスタを追加しないこと。

---

## 8. レジスタ削減

S1/S2化によって少なくとも次を削除する。

```text
pair_sum
old_prefix
```

また、pair_sum更新専用の制御状態・選択経路も削除する。

最終計算の、

```text
s1_square
pair_twice
term_square
term_pair
```

はすべて専用30bitレジスタを新設する必要はない。

寿命が重ならない値は既存scratch registerを共有してよい。

ただし、可読性を失うほど無理なレジスタ共有を要求しない。

IMPLで実際のlifetimeを確認して決める。

---

## 9. 入力処理性能

V2では、

```text
x * old_prefix
x * x
```

の2乗算が必要だった。

S1/S2版では、

```text
x * x
```

だけになる。

したがって1 Aiの処理クロックはV2の、

```text
130～134 clocks
```

より短くなることを期待する。

ただし主目的は面積削減である。

4MHz SPI / 50MHz FPGAの、

```text
約400 clocks / Ai
```

以内であれば性能上は十分とする。

---

## 10. 組合せ係数

Baseline V2の方式を変更しない。

```text
coeff_square =
    C(N-1,K-1)

coeff_pair =
    C(N-2,K-2)
```

`coeff_square`は分子・分母の逐次積とFermat逆元で計算する。

`coeff_pair`は、

```text
coeff_square * (K-1) / (N-1)
```

から求める。

本版では、

```text
Pascalの恒等式による別係数化
係数計算方式の変更
階乗テーブル
```

などへ進まない。

S1/S2化の効果を単独で評価するためである。

---

## 11. 特殊ケース

Baselineと同じ入力範囲を扱う。

### K=1

```text
answer = S2
```

としてよい。

### N=1,K=1

`inverse(0)`を実行しない。

### K=N

最終結果が、

```text
S1² mod MOD
```

と一致することを確認する。

---

## 12. テストベンチ

Baseline V2 testbenchを基礎にする。

外部SPI・異常系・ランダム比較は維持する。

V2の内部3状態確認、

```text
prefix_sum
square_sum
pair_sum
```

はS1/S2確認へ置き換える。

`A=[1,2,3]`:

```text
初期:
S1=0
S2=0

1処理後:
S1=1
S2=1

2処理後:
S1=3
S2=5

3処理後:
S1=6
S2=14
```

さらに、

```text
S1²-S2 = 22
```

を確認する。

これは、

```text
2*(1*2+1*3+2*3)=22
```

と一致する。

---

## 13. 既存111項目との関係

Baseline V2は111項目PASSしている。

S1/S2版では、

- 外部入出力テスト
- protocol/errorテスト
- ランダム小ケース100件
- modular multiplier 60クロック確認

を維持する。

3状態内部値テストだけはS1/S2内部値テストへ置換する。

可能なら総数111を維持する。

テスト件数が変わる場合は理由をREPORTへ記録する。

期待値は引き続き独立な全組み合わせ列挙を使用する。

RTLのS1/S2式をPythonへそのまま複製して基準値にしない。

---

## 14. MicroPython

SPI外部仕様は変わらないため、Baseline V2のMicroPythonテストを流用してよい。

変更は原則として、

```text
bitstream名
表示名
```

などS1/S2版の識別に必要な範囲だけとする。

期待値計算方式は変更しない。

---

## 15. 実装前に作成する資料

まず、

```text
IMPL_abc471e_s1s2.md
```

を作成する。

これは本要求書のコピーではなく、実際のBaseline V2 RTLとPost-Synthesis結果を確認した具体設計書とする。

最低限次を含める。

```text
V2から削除するstate/register/FSM

S1/S2更新シーケンス

共有multiplierの利用順序

shared modular add/subの具体構成

S1²-S2の計算方法

最終計算scratchの共有方針

1 Aiあたりの想定クロック

V2から維持する部分

意図的に行わない追加最適化
```

IMPL作成後、その方針に従ってRTLを変更する。

---

## 16. 禁止事項

次を行わない。

```text
MOD変更
Ai bit幅縮小
N_MAX縮小

組合せ係数の別アルゴリズム化
階乗テーブル追加
A配列保存

複数modular multiplier追加
一般的な可変乗算器追加
一般的な除算器・%回路追加

SPIプロトコル変更
spi_target.v変更

reference/以下変更
```

また、

```text
まだ入らなさそう
```

という推測だけを理由に、数値条件の縮小へ進まない。

S1/S2版の合成結果を取得してから次を判断する。

---

## 17. 実装後の検証

Icarus Verilogで最低限次を確認する。

```text
コンパイル成功

S1/S2途中値
S1²-S2

N=1,K=1
K=1
K=N

mod境界
payload中0xFF

ランダム小ケース100件
独立な全組み合わせ列挙との一致

RESET / START
STATUS + 4-byte answer

不正N/K
ERROR sticky
busy衝突
余分payload
STATUS poll境界
```

性能:

```text
PERF MUL_CLOCKS
PERF AI_MIN_CLOCKS
PERF AI_MAX_CLOCKS
```

`MUL_CLOCKS=60`を維持すること。

---

## 18. IMPLEMENTATION_REPORT

実装・Icarus検証完了後、

```text
IMPLEMENTATION_REPORT_abc471e_s1s2.md
```

を作成する。

最低限次を記録する。

```text
変更ファイル一覧

V2から削除したstate/register/FSM

S1/S2更新の実装

S1²-S2の実装

共有modular add/sub構成

共有multiplierを維持したこと

組合せ係数方式を維持したこと

Icarusテスト結果

PERF MUL_CLOCKS
PERF AI_MIN_CLOCKS
PERF AI_MAX_CLOCKS

spi_target.v未変更

reference/以下未変更

ForgeFPGA Workshop未実施

実機試験未実施
```

---

## 19. Codex側の停止条件

Codex側では次まで行う。

```text
Baseline V2解析

IMPL_abc471e_s1s2.md作成

S1/S2 RTL実装

必要なtestbench更新

Icarus検証

性能再測定

IMPLEMENTATION_REPORT_abc471e_s1s2.md作成
```

次は行わない。

```text
ForgeFPGA Workshop Lint
ForgeFPGA Workshop synthesis
PNR
bitstream生成
実機flash
実機試験
```

ForgeFPGA Workshopによる評価はユーザーが行う。

---

## 20. 評価目的

S1/S2版では、Baseline V2との比較により、

```text
pair_sumを保持せず
入力毎のx*prefix_sumも削除したとき、
LC / FF / CARRY / LUTがどこまで減るか
```

を確認する。

Shrike-Liteへ収まること自体はCodex側の完了条件ではない。

収まらなかった場合も、その結果を記録して停止する。

数値条件やMODを縮小する実験は、その後の別段階とする。
