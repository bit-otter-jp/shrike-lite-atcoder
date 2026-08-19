# ABC471E S1/S2 面積診断 実行要求

## 1. 目的

`abc471e_s1s2` の現行実装について、面積支配要因を差分合成で切り分ける。

現在の解析では、S1/S2版は次の結果となっている。

```text
Post-Synthesis:
cells      = 3340
CARRY4     = 121
FDCE       = 940
FDPE       = 8
LUT2       = 482
LUT3       = 142
LUT4       = 608
LUT5       = 449
LUT6       = 440
MUXF7      = 10

LUT total       = 2121
LUT + MUXF7     = 2131

PNR:
Type=L Capacity=140 Utilized=561
CLB LUT site = 2114
theoretical minimum = 529 CLB
```

`AREA_ANALYSIS_abc471e_s1s2.md` では、

- S1/S2化で減った主成分はFF 60bit
- LUT+MUXF7は実質不変
- shared multiplier単体は最大要因ではない
- combination + Fermat/pow は337bitの状態を持つ
- wide next-state / control / operand MUX網が大きい
- 次の診断として `pow_fixed` と `coefficient_pow_fixed` の差分合成が最も情報量が多い

と判断している。

本要求では、この2つの診断版を同じ作業場所で作成し、
Icarus検証を行ったうえで、まず現行ForgeFPGA synthesis flowをCLIから安全かつ再現可能に実行できるか確認する。

CLI再現性が確認できた場合のみ、同一条件で2診断版をPost-Synthesisまで自動実行して差分を測定する。

CLI再現性を確認できない場合は、推測で合成を実行せず、確認できた事実・不足条件・ユーザーがForgeFPGA Workshopから手動合成するために必要な状態をREPORTへ記録して停止する。

今回は本番RTLの最適化ではない。

---

## 2. 重要な原則

現在の正規S1/S2版は一切変更しない。

変更禁止:

```text
ffpga/src/main.v
ffpga/src/spi_target.v
sim/abc471e_s1s2_tb.v
firmware/
SPEC_abc471e_s1s2.md
IMPL_abc471e_s1s2.md
IMPL_REQUEST_abc471e_s1s2.md
IMPLEMENTATION_REPORT_abc471e_s1s2.md
AREA_ANALYSIS_abc471e_s1s2.md
reference/
ffpga/build/
hardware_logs/
```

作業前後で主要ファイルのSHA-256を確認し、
正規版が不変であることをREPORTへ記録する。

診断版は `diagnostics/` 以下だけで作成する。

---

## 3. 作業ディレクトリ

プロジェクトrootに次を作成する。

```text
diagnostics/
├─pow_fixed/
└─coefficient_pow_fixed/
```

各診断版は、現在のS1/S2版から必要最小限のファイルだけをコピーし、
独立してIcarusおよびPost-Synthesisできる構成とする。

過去の `reference/` を再帰コピーしない。

診断版内に必要なら `ffpga/src/`、`sim/`、`build/` 等を作成してよい。

---

## 4. 共通条件

次は両診断版で維持する。

```text
MOD = 998244353
N_MAX = 200000

30-bit modular datapath
S1/S2入力集計
shared modular multiplier
top shared modular add/sub

SPI Template V3
32-bit big-endian N/K/A
STATUS + 4-byte answer
sticky protocol_error
1-byte response delay
```

本番版の数学・外部仕様を一般ケースで完全維持する必要はない。

診断版は `N=3, K=2` に限定してよい。

目的は、該当機能を外したときに
Post-SynthesisのLUT / FF / CARRY4がどれだけ減るかを測ることである。

目的外の最適化は行わない。

---

# 5. 診断ケースA: pow_fixed

## 5.1 目的

Fermat inverse / binary exponentiation部分だけを除去する。

これにより、

```text
pow_result
pow_base
pow_exp
pow_context

pow用FSM
pow用decode
pow用multiplier launch
pow関連next-state MUX
pow operand source
```

を削除したときのaggregate costを測定する。

`combination` の逐次計算自体は残す。

残すもの:

```text
comb_n
comb_r
comb_i
numerator
denominator
coeff_square
coeff_pair
coeff_pair_work
```

## 5.2 固定inverse

診断入力は、

```text
N = 3
K = 2
```

に限定する。

この場合、

```text
inverse(1) = 1
inverse(2) mod 998244353 = 499122177
```

を固定値として使用する。

一般N/Kで正しい必要はない。

## 5.3 pow_fixedで残す算術

combination逐次積は実際に実行する。

`numerator`、`denominator`、`comb_i`、`comb_factor` の更新は残す。

ただしinverse計算に入る代わりに固定inverseを使用して係数計算を続行する。

shared multiplierは引き続き使用する。

---

# 6. 診断ケースB: coefficient_pow_fixed

## 6.1 目的

combination計算 + Fermat/pow全体を除去する。

これにより、

```text
combination storage
pow storage
combination FSM
pow FSM
operand selection
next-state logic
decode
```

を含むaggregate costを測定する。

## 6.2 固定係数

診断入力:

```text
N = 3
K = 2
```

では、

```text
coeff_square = C(2,1) = 2
coeff_pair   = C(1,0) = 1
```

なので、これらを固定値として使用する。

## 6.3 削除対象

少なくとも次を削除する。

```text
comb_n
comb_r
comb_i
numerator
denominator
coeff_pair_work

pow_result
pow_base
pow_exp
pow_context

combination専用FSM状態
pow専用FSM状態

combination/pow専用multiplier launch
それら専用operand selection/decode
```

`coeff_square` / `coeff_pair` をレジスタとして残す必要がなければ、
定数として直接使用してよい。

ただし、診断とは無関係な最終算術をconstant-foldさせないこと。

---

# 7. 両診断版で必ず残す最終計算

S1/S2入力集計と最終計算は残す。

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

shared modular multiplierを実際に使うこと。

shared modular add/subを実際に使うこと。

optimizerにより最終算術全体がconstant化されないようにすること。

A入力は実際のSPI入力から受信し、
S1/S2を実際に更新する。

---

# 8. Icarus診断テスト

既存111項目をそのまま通す必要はない。

診断版は一般N/Kで正しくないため、
診断用の最小テストを用意する。

最低限:

```text
RESET
RESET_ACK

START
START_ACK

N = 3
K = 2

A = [1,2,3]

S1/S2更新
STATUS polling
4-byte answer

RESULT = 50
```

期待値:

```text
(1+2)^2 = 9
(1+3)^2 = 16
(2+3)^2 = 25

9 + 16 + 25 = 50
```

さらに可能なら、Aだけ異なる2～3ケースを追加する。

例:

```text
A=[0,0,0]
A=[1,1,1]
A=[MOD-1,1,0]
```

期待値は独立計算で求めること。

診断版で確認したいのは、

```text
S1/S2 datapathが生きている
shared multiplierが生きている
shared add/subが生きている
STATUS/replyがdeadlockしない
```

ことである。

---

# 9. CLI synthesis再現性確認とPost-Synthesis

## 9.1 まずCLI再現性を確認する

Icarus PASS後、診断版の合成を直ちに開始しない。

最初に、現在の正規S1/S2版で使用されたForgeFPGA synthesis環境について、
CLIから同じPost-Synthesis結果を再現できるか調査する。

確認対象:

```text
ffpga/build/synth_script.ys
ffpga/build/post_synth_report.txt
ffpga/build/post_synth_results.v
ffpga/build/netlist.edif
ForgeFPGA Workshopのインストール先
ForgeFPGA付属Yosys/ABC9等の実行ファイル
必要なlibrary path
必要なenvironment variable
必要なcommand-line option
top module
source file list
constraint / synthesis option
```

既存の正規S1/S2版 `ffpga/build/` は変更しない。

CLI調査のために一時ファイルが必要な場合は、
`diagnostics/` 以下またはOSの一時領域だけを使用する。

## 9.2 CLI再現性の成立条件

単に `yosys -s synth_script.ys` が起動するだけでは再現性確認済みとしない。

少なくとも、

- ForgeFPGA Workshopと同じbundled toolを使用している
- 同じscript / source / library / optionを使用している
- 正規S1/S2版を別の一時build領域でCLI合成し、
  既存Post-Synthesis結果と主要primitive countが一致する

ことを確認する。

比較対象:

```text
cells      = 3340
CARRY4     = 121
FDCE       = 940
FDPE       = 8
LUT2       = 482
LUT3       = 142
LUT4       = 608
LUT5       = 449
LUT6       = 440
MUXF7      = 10
LUT total  = 2121
```

完全一致しない場合は、その差がtool version、option、library、source条件等で説明できない限り
「CLI再現性確認済み」としない。

## 9.3 CLI再現性を確認できた場合

CLI再現性を確認できた場合のみ、

```text
diagnostics/pow_fixed
diagnostics/coefficient_pow_fixed
```

の2版を、確認済みの同一CLI flowでPost-Synthesisまで実行する。

Post-Synthesisは、この条件を満たした場合のみ必須とする。

各診断版について最低限次を取得する。

```text
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
LUT + MUXF7
```

可能なら、

```text
wire count
wire bit count
```

も記録する。

## 9.4 CLI再現性を確認できない場合

CLI再現性を確認できない場合は、無理に合成しない。

特に次を禁止する。

```text
system PATH上の別Yosysで代用
推測したlibrary pathで強行
不明なoptionを省略して「同条件」と扱う
既存ffpga/build/を上書きして試す
GUI操作を自動化して無理に実行する
```

この場合は、

1. どこまで確認できたか
2. 何が不足してCLI再現できないか
3. 既存GUI flowとCLI候補の差
4. 診断版がForgeFPGA Workshopから手動合成できる状態になっているか
5. ユーザーが次に行う最小操作

を `DIAGNOSTIC_AREA_REPORT_abc471e_s1s2.md` に記録する。

Post-Synthesis数値を推測で補わない。

# 10. PNRは行わない

今回はPNRを実行しない。

理由:

- Post-Synthesis差分が今回の第一目的
- GUI/Bitstream途中FAIL時のPNR log保存が不安定
- PNRは必要な診断版だけ後でユーザーがForgeFPGA Workshopから実行する

したがってCodexは `placer`、PNR、bitstreamへ進まない。

Post-Synthesisまでで停止する。

---

# 11. 比較表

最終REPORTでは次の3列を比較する。

```text
S1/S2 original
pow_fixed
coefficient_pow_fixed
```

最低限:

| item | original | pow_fixed | coefficient+pow fixed |
|---|---:|---:|---:|
| cells | 3340 | ? | ? |
| CARRY4 | 121 | ? | ? |
| FF | 948 | ? | ? |
| LUT2 | 482 | ? | ? |
| LUT3 | 142 | ? | ? |
| LUT4 | 608 | ? | ? |
| LUT5 | 449 | ? | ? |
| LUT6 | 440 | ? | ? |
| LUT total | 2121 | ? | ? |
| MUXF7 | 10 | ? | ? |
| LUT+MUXF7 | 2131 | ? | ? |

---

# 12. aggregate cost

次を計算する。

```text
pow aggregate cost
    = original - pow_fixed

combination aggregate cost
    = pow_fixed - coefficient_pow_fixed

combination + pow aggregate cost
    = original - coefficient_pow_fixed
```

ここでいうaggregate costは、

```text
対象block内部
+
対象block削除によりoptimizerが消した
operand MUX
next-state logic
decode
control
```

を含む。

「module単体面積」とは呼ばない。

---

# 13. 判断したいこと

診断結果から次を回答する。

1. Fermat/powを除去するとLUTはいくつ減るか。
2. FFはいくつ減るか。
3. CARRY4はいくつ減るか。
4. combination逐次計算をさらに外すと追加でどれだけ減るか。
5. `combination + pow` が現在の最大面積要因という仮説は支持されるか。
6. `combination + pow` を全部外しても、140 CLB相当へ依然遠いか。
7. その場合、残りの主要LUT要因は何と考えられるか。
8. 30-bit wide datapath自体を縮小する必要性は強まったか。
9. 16bit化・8bit化した場合に、どのblockへ面積効果が波及しそうか。
10. 次にPNRする価値が最も高い診断版はどちらか。

数値根拠と推定を分ける。

---

# 14. 追加解析

Post-Synthesis結果が得られたら、
必要に応じて各診断版の`post_synth_results.v`も解析する。

特に確認したいもの:

```text
multiplier operand launch state数
multiplier LHS/RHS unique source数
top FF直前next-state LUT数
CARRY4内訳
pow/combination削除後のwide operand MUX縮小
MUXF7の残存数
```

元の `AREA_ANALYSIS_abc471e_s1s2.md` と同じ方法で比較可能な範囲を調べる。

解析のために本番ファイルを変更しない。

---

# 15. 結果ファイル

プロジェクトrootへ、

```text
DIAGNOSTIC_AREA_REPORT_abc471e_s1s2.md
```

を作成する。

最低限次の構成とする。

```text
1. Executive Summary
2. 実験目的
3. 元S1/S2の基準値

4. pow_fixed
   - 削除したもの
   - 残したもの
   - 固定inverse
   - Icarus結果
   - Post-Synthesis結果

5. coefficient_pow_fixed
   - 削除したもの
   - 残したもの
   - 固定係数
   - Icarus結果
   - Post-Synthesis結果

6. 3版比較表

7. aggregate cost
   - pow
   - combination
   - combination + pow

8. operand MUX / next-state変化
9. 仮説への回答
10. 次にPNRする価値がある版
11. 30bit幅縮小への示唆
12. 未実施事項・不確実性
13. 元S1/S2ファイル未変更確認
```

---

# 16. 元ファイル未変更確認

作業終了時に、少なくとも次が作業前から不変であることを確認する。

```text
ffpga/src/main.v
ffpga/src/spi_target.v
sim/abc471e_s1s2_tb.v
SPEC_abc471e_s1s2.md
IMPL_abc471e_s1s2.md
IMPL_REQUEST_abc471e_s1s2.md
IMPLEMENTATION_REPORT_abc471e_s1s2.md
AREA_ANALYSIS_abc471e_s1s2.md
reference/以下
ffpga/build/既存成果物
```

ハッシュ一致または同等の方法で確認し、
REPORTへ記録する。

---

# 17. 禁止事項

今回は次を行わない。

```text
本番S1/S2 RTL変更
本番testbench変更
本番firmware変更

16bit化
8bit化
MOD変更
N_MAX変更
Ai制約変更

組合せ係数の新アルゴリズム実装
scratch最適化
controller再設計
operand MUX再設計

PNR
bitstream生成
実機flash
実機試験

reference変更
```

診断結果から次段階が明らかでも、
今回は実装へ進まない。

---

# 18. 停止条件

まず以下を完了する。

```text
diagnostics/pow_fixed 作成
Icarus PASS

diagnostics/coefficient_pow_fixed 作成
Icarus PASS

ForgeFPGA synthesisのCLI再現性確認
```

CLI再現性を確認できた場合:

```text
正規S1/S2版のCLI再合成結果が既存Post-Synthesis結果と整合
pow_fixed Post-Synthesis完了
coefficient_pow_fixed Post-Synthesis完了
3版比較
aggregate cost算出
DIAGNOSTIC_AREA_REPORT_abc471e_s1s2.md 作成
元S1/S2版未変更確認
```

CLI再現性を確認できない場合:

```text
無理に合成しない
CLI調査結果と不足条件をREPORTへ記録
2診断版が手動合成可能な状態であることを確認
DIAGNOSTIC_AREA_REPORT_abc471e_s1s2.md 作成
元S1/S2版未変更確認
```

いずれの場合もPNR・bitstream・実機には進まない。
