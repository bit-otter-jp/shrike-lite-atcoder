# ABC471E S1/S2 実装レポート

## 1. 結果概要

`SPEC_abc471e_s1s2.md`および`IMPL_REQUEST_abc471e_s1s2.md`に従い、Baseline V2の3状態ストリーム集計をS1/S2の2状態へ変更した。

```text
S1 = ΣAi   mod 998244353
S2 = ΣAi²  mod 998244353
```

V2の `old_prefix`、`pair_sum`、入力ごとの `x*old_prefix` を削除した。最終段では共有multiplierで `S1*S1` を計算し、共有add/subデータパスで `S1²-S2 mod MOD` を復元する。

Icarus Verilogの111項目はすべてPASSした。性能実測値は次のとおりである。

```text
PERF MUL_CLOCKS=60 PRODUCT=263684735
PERF AI_SAMPLES=474 AI_MIN_CLOCKS=67 AI_MAX_CLOCKS=71
SUMMARY TOTAL=111 PASS=111 FAIL=0
```

共有multiplierの60クロックを維持し、1 Aiの処理はV2の130～134クロックから67～71クロックへ短縮した。MOD、bit幅、`N_MAX`、組合せ係数方式、SPI外部仕様は変更していない。

## 2. Baseline V2の確認結果

実装前に `reference/abc471e_baseline_v2/` のSPEC、IMPL、REPORT、RTL、testbench、`post_synth_report.txt`、`post_synth_results.v`を確認した。

作業開始時点の現行 `main.v`、`spi_target.v`、testbench、MicroPython testはBaseline V2の対応ファイルとSHA-256が一致し、現行IMPLとREPORTもBaseline V2文書のコピーだった。

V2 RTLの入力算術FSMは次の2乗算系列だった。

```text
x * old_prefix
pair_sum += product
x * x
square_sum += product
prefix_sum += x
```

top側のmodular addはすでに1系統へ共有され、可変modular multiplierも1インスタンスだった。

V2 Post-Synthesis reportのtop `main` local countは次のとおりである。

```text
cells  = 3401
CARRY4 = 121
FDCE   = 1000
FDPE   = 8
INV    = 140
LUT2   = 409
LUT3   = 173
LUT4   = 535
LUT5   = 582
LUT6   = 433
```

`post_synth_results.v`はYosys 0.59+0によるflatten済みnetlistであり、source属性もV2 `main.v` 1～822行を指していた。IMPL_REQUESTに記録されたV2 PNRは `Type=L Capacity=140 Utilized=571` でfitしていないが、本作業では指定されたS1/S2化だけを行い、数値条件の縮小には進んでいない。

## 3. 変更ファイル

| ファイル | 変更内容 |
|---|---|
| `IMPL_abc471e_s1s2.md` | V2 RTLとPost-Synthesis結果に基づき、削除対象、S1/S2系列、共有add/sub、scratch寿命、想定性能を実装前に設計 |
| `ffpga/src/main.v` | S1/S2ストリーム集計、共有add/sub、`S1²-S2`と新しい最終計算FSMを実装 |
| `sim/abc471e_s1s2_tb.v` | top名をS1/S2版へ変更し、旧3状態試験をS1/S2・pair_twice・borrow補正試験へ置換 |
| `firmware/micropython/abc471e_s1s2_test.py` | 外部仕様と期待値計算を維持し、bitstream名だけ `abc471e_s1s2.bin` へ変更 |
| `IMPLEMENTATION_REPORT_abc471e_s1s2.md` | 実コード、Icarus結果、性能実測、未実施工程を記録 |

次は変更していない。

- `ffpga/src/spi_target.v`
- `abc471e_s1s2.ffpga`
- `ffpga/timing-constraints/atcoder_spi_template_v3.sdc`
- `reference/`以下の全ファイル

## 4. V2から削除・変更した状態

削除した30-bitレジスタは次の2本である。

```text
old_prefix
pair_sum
```

数学状態は次のように改名・縮約した。

```text
prefix_sum -> s1
square_sum -> s2
pair_sum   -> 削除
```

入力のペア積専用だった次の状態も存在しない。

```text
C_INPUT_PAIR_START
C_INPUT_PAIR_WAIT
C_INPUT_PAIR_ADD
```

V2の最終 `2*pair_sum` 用 `C_FINAL_PAIR_DOUBLE` も削除した。静的検索で、S1/S2版 `main.v` に `old_prefix`、`pair_sum`、`prefix_sum`、`square_sum`、`C_INPUT_PAIR*`、`C_FINAL_PAIR_DOUBLE`が残っていないことを確認した。

## 5. S1/S2ストリーム更新

32-bit `x_raw` の正規化はV2と同じ逐次MOD減算である。一般的な除算器や `%` 回路は使用していない。

正規化後は次の1乗算系列を実行する。

```text
C_INPUT_SQUARE_START
  -> C_INPUT_SQUARE_WAIT    mul_mod(x_reg, x_reg)
  -> C_INPUT_S2_ADD         s2 = add_mod(s2, mul_product)
  -> C_INPUT_S1_ADD         s1 = add_mod(s1, x_reg)
```

`C_INPUT_S1_ADD`で `input_count` を増やし、`x_busy`を下げる。最終入力なら `K==1` の高速終了または既存の組合せ係数計算へ進む。入力1個あたりの可変乗算は `x*x` の1回だけである。

内部値テストでは `A=[1,2,3]` に対し次を確認した。

| 処理後 | `s1` | `s2` |
|---:|---:|---:|
| 1 | 1 | 1 |
| 2 | 3 | 5 |
| 3 | 6 | 14 |

A配列全体は保存していない。

## 6. 共有modular add/sub

V2のtop側共有modular addを、B operandの条件付き反転とcarry-inで加減算する1個の31-bitコアへ拡張した。

```text
b_selected = B XOR {30{sub}}
raw_sum = {1'b0,A} + {1'b0,b_selected} + sub
```

通常加算では従来どおり、`raw_sum>=MOD`ならMODを1回減算する。operand保持用やdestination選択用の30-bitレジスタは追加せず、`calc_state`の組み合わせmuxでoperand、add/sub、reduction有無を選ぶ。

共有する用途は次の5状態である。

| 状態 | 処理 |
|---|---|
| `C_INPUT_S2_ADD` | `s2 + mul_product mod MOD` |
| `C_INPUT_S1_ADD` | `s1 + x_reg mod MOD` |
| `C_FINAL_PAIR_SUB` | `s1_square - s2` のraw 30-bit減算 |
| `C_FINAL_PAIR_CORRECT` | borrow時だけraw差へMODを加算して30-bit wrap |
| `C_FINAL_ADD` | `term_square + term_pair mod MOD` |

subtractionでborrowがなければraw下位30bitをそのまま使う。borrow時のraw値は `2^30+s1_square-s2` なので、次状態で同じコアからMODを加え、下位30bitを採ると `s1_square+MOD-s2` になる。borrowフラグは保持せず、`C_FINAL_PAIR_CORRECT`へ遷移したこと自体で表す。

この補正経路は `A=[MOD-1,1], K=2` で直接検証した。このとき `s1_square=0`、`s2=2`であり、testbenchは次を確認している。

```text
raw difference = 2^30 - 2 = 1073741822
corrected      = MOD - 2  = 998244351
final answer   = 0
```

## 7. S1²-S2と最終scratch

係数計算後の最終FSMは次の順で共有multiplierと共有add/subを使う。

```text
term_pair   = mul_mod(s1, s1)             // s1_square scratch
term_pair   = sub_mod(term_pair, s2)      // pair_twice scratch
term_square = mul_mod(coeff_square, s2)
term_pair   = mul_mod(coeff_pair, term_pair)
answer      = add_mod(term_square, term_pair)
```

`term_pair`の値の寿命は `s1_square`、`pair_twice`、係数付きpair項の順で重ならないため、既存の1本を再利用した。専用の `s1_square`、`pair_twice`レジスタは追加していない。

`A=[1,2,3]`の内部テストでは、最終term計算の直前に `term_pair=22`、すなわち次が成立することを確認した。

```text
S1²-S2 = 6²-14 = 22
2*(1*2+1*3+2*3) = 22
```

## 8. 共有multiplierと組合せ係数

`modular_multiplier`モジュールはBaseline V2から変更していない。30-bit shift-add方式で、加算相と2倍相が内部31-bit adderを共有し、1 bitあたり2クロック、計30 bitで60クロックである。

top `main`の `modular_multiplier u_modular_multiplier` は引き続き1インスタンスだけである。一般的な可変 `*` や2個目のmultiplierは追加していない。

組合せ係数方式もV2のままである。

```text
coeff_square = C(N-1,K-1)
coeff_pair   = C(N-2,K-2)
```

`coeff_square`は分子・分母の逐次積と `denominator^(MOD-2)` のFermat逆元で計算する。`coeff_pair`は次の式と `inverse(N-1)` で計算する。

```text
coeff_pair = coeff_square * (K-1) * inverse(N-1) mod MOD
```

binary exponentiationを含む全可変乗算は同じmultiplierへ逐次投入する。`K==1`では `answer=s2` とし、`N=1,K=1`で `inverse(0)`を実行しない既存処理も維持した。

## 9. SPI外部仕様とエラー処理

SPIプロトコル処理はBaseline V2から変更していない。

- SPI Template V3
- 32-bit big-endianの`N`、`K`、`A_i`
- 4MHzをBaseline値とする転送
- RESET/STARTと1-byte遅延ACK
- payload中の`0x00 / 0xFD / 0xFE / 0xFF`をdataとして扱う仕様
- STATUS `0x00 / 0x80 / 0xC0` + 4-byte answer
- sticky `protocol_error`
- STATUSポーリング途中の完了境界対策
- 不正N/K、busy word、余分payloadの検出

現行 `ffpga/src/spi_target.v` はBaseline V2参照版とSHA-256が一致する。

```text
C7166CE9076223A2818514EF7FF5CA3F6D322D1B9290484C5084C6AC09CD21EC
```

## 10. Icarus Verilog検証

実行日は2026-08-17。使用したコマンドは次のとおりである。

```powershell
$out = Join-Path $env:TEMP 'abc471e_s1s2.vvp'
iverilog -g2012 -Wall -s abc471e_s1s2_tb -o $out ffpga/src/main.v ffpga/src/spi_target.v sim/abc471e_s1s2_tb.v
vvp $out
```

コンパイルと実行は成功した。RTLモジュールに明示的なtimescaleがないという既存warningだけがあり、errorはなかった。

最終実行結果:

```text
PERF MUL_CLOCKS=60 PRODUCT=263684735
PERF AI_SAMPLES=474 AI_MIN_CLOCKS=67 AI_MAX_CLOCKS=71
SUMMARY TOTAL=111 PASS=111 FAIL=0
```

111項目の内訳:

- shared modular multiplierの積と60クロック: 1件
- S1/S2途中値、`S1²-S2=22`、borrow補正、手計算回答: 1件
- `N=1,K=1`、`K=1`、`K=N`、mod境界とpayload中`0xFF`: 4件
- `N<=8`のランダム小ケースと独立な全組み合わせ列挙の比較: 100件
- 不正NとERROR sticky、不正K、`N>N_MAX`と`K=0`、busy衝突、余分payload: 5件

Baselineの外部・異常系試験は削除していない。総数111も維持した。内部状態1件の中にborrow補正用の追加SPIケースを入れたため、AI性能サンプル数はV2の472から474へ増えている。

## 11. 性能再測定

| 項目 | Baseline V2 | S1/S2 | 差分 |
|---|---:|---:|---:|
| 共有modular multiplier | 60 clocks | 60 clocks | 0 |
| 1 Ai最小 | 130 clocks | 67 clocks | -63 |
| 1 Ai最大 | 134 clocks | 71 clocks | -63 |

AIクロックはtestbenchが `x_busy` の立上りから立下りまでを測定した値で、S1/S2版のサンプル数は474である。最小・最大の4クロック差は、32-bit入力をMODへ正規化する逐次減算回数による。

最大71クロックはV2最大134クロックの約53.0%である。4MHz SPI / 50MHz FPGAでは32-bit Aiの転送に約400クロックあり、S1/S2版は最大値でもその17.75%を使用し、次のword完成まで約329クロックの余裕がある。

## 12. 仕様維持と未変更確認

次の数値・方式は変更していない。

```text
MOD   = 998244353
N_MAX = 200000
A_i   = 32-bit unsigned
mod値 = 30-bit
```

また、次も行っていない。

- 組合せ係数の別アルゴリズム化
- 階乗テーブルまたはA配列の保存
- multiplierの複数化
- 一般的な可変乗算器、除算器、`%`回路の追加
- SPI仕様変更
- `spi_target.v`変更
- `reference/`以下への書き込み
- 面積推測を理由とするMOD・bit幅・N_MAXの縮小

## 13. 停止した工程

ユーザー指定の停止条件に従い、次は実施していない。

- ForgeFPGA Workshop Lint
- ForgeFPGA Workshop synthesis
- PNR
- bitstream生成
- 実機flash
- 実機試験

したがってS1/S2版のCARRY4、FDCE、FDPE、LUT、LC、fit可否、WNS、Achievable Frequencyは未取得である。本レポートのPost-Synthesis値は比較基準として確認したBaseline V2の値であり、S1/S2版の合成結果ではない。

要求されたCodex側の作業は、具体設計、RTL・テスト実装、Icarus検証、性能再測定、本レポート作成までで停止した。次段階の数値条件縮小には進んでいない。
