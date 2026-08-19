# ABC471E Baseline V2 実装レポート

## 1. 結果概要

`SPEC_abc471e_baseline.md`および`IMPL_REQUEST_abc471e_baseline_v2.md`に従い、Baseline V1の数学アルゴリズムとSPI外部仕様を維持したまま、top側の30-bit modular addを1系統へ時間共有した。

既存Icarus Verilogテスト111項目はすべてPASSした。性能実測値は次のとおりである。

```text
PERF MUL_CLOCKS=60 PRODUCT=263684735
PERF AI_SAMPLES=472 AI_MIN_CLOCKS=130 AI_MAX_CLOCKS=134
SUMMARY TOTAL=111 PASS=111 FAIL=0
```

最大134クロック/Aiは、4MHz SPI / 50MHz FPGAで使用できる約400クロック/Ai以内である。

## 2. 変更ファイル

| ファイル | 変更内容 |
|---|---|
| `IMPL_abc471e_baseline_v2.md` | V1 RTLと旧Post-Synthesis結果を基に、共有modular add、operand選択、保存先、FSM変更、想定性能を実装前に設計 |
| `ffpga/src/main.v` | V1の`add_mod()` 5呼び出しを削除し、FSMで時間共有する単一modular addデータパスと専用状態を実装 |
| `IMPLEMENTATION_REPORT_abc471e_baseline_v2.md` | V2の実装内容、Icarus実測結果、未実施工程を記録 |

次のファイルは変更していない。

- `ffpga/src/spi_target.v`
- `sim/abc471e_baseline_tb.v`
- `firmware/micropython/abc471e_baseline_test.py`
- `reference/`以下の全ファイル
- `ffpga/build/`内のV1由来の旧成果物

## 3. V1の確認結果

作業開始時点の現行`main.v`、`spi_target.v`、Icarus testbench、MicroPython testは、`reference/abc471e_baseline_v1/`内の対応ファイルとSHA-256が一致しており、V1そのものであることを確認した。

V1の`main.v`では、30-bit modular addをfunction `add_mod()`として定義し、次の5か所で呼び出していた。

```text
pair_sum更新
square_sum更新
prefix_sum更新
term_pairの2倍
answerの最終加算
```

各呼び出しは31-bit加算、`MOD`比較、条件付き`MOD`減算を個別展開され得る構造だった。参照専用のV1 Post-Synthesis reportに記録されている主なlocal countは次のとおりである。

```text
cells  = 3492
CARRY4 = 183
FDCE   = 1024
FDPE   = 9
```

これらはV1の旧結果であり、V2の合成結果としては扱っていない。

## 4. 共有modular addの構成

V2では`add_mod()` functionを削除し、top `main`に次の1系統だけを記述した。

```text
mod_add_a[29:0] ─┐
                  ├─ wide sum ─ MOD比較 ─ 条件付きMOD減算 ─ result[29:0]
mod_add_b[29:0] ─┘
```

実装上の主要信号は次のとおりである。

```text
mod_add_a
mod_add_b
mod_add_sum
mod_add_reduced
mod_add_result
```

`mod_add_a`と`mod_add_b`は`calc_state`で選択する組み合わせmux出力であり、共有化専用の30-bit operand保持レジスタは追加していない。全caseに既定値を与え、ラッチを生成しない構成とした。

静的なRTL確認では、`add_mod()`呼び出しは0、topの`mod_add_sum`記述は1、topからの`modular_multiplier`インスタンスは1である。

## 5. operand・保存先とFSM変更

operandとresult destinationは算術FSM状態で次のように指定する。

| 状態 | operand A | operand B | 保存先 |
|---|---|---|---|
| `C_INPUT_PAIR_ADD` | `pair_sum` | `mul_product` | `pair_sum` |
| `C_INPUT_SQUARE_ADD` | `square_sum` | `mul_product` | `square_sum` |
| `C_INPUT_PREFIX_ADD` | `old_prefix` | `x_reg` | `prefix_sum` |
| `C_FINAL_PAIR_DOUBLE` | `mul_product` | `mul_product` | `term_pair` |
| `C_FINAL_ADD` | `term_square` | `term_pair` | `answer` |

1 Aiの処理シーケンスは次のとおりである。

```text
C_INPUT_PAIR_START
  -> C_INPUT_PAIR_WAIT
  -> C_INPUT_PAIR_ADD
  -> C_INPUT_SQUARE_WAIT
  -> C_INPUT_SQUARE_ADD
  -> C_INPUT_PREFIX_ADD
```

`C_INPUT_PAIR_ADD`ではpair加算結果の保存と`x*x`乗算開始を同じクロックで行う。この状態はV1の`C_INPUT_SQUARE_START`が使っていたクロックを兼用する。square加算とprefix加算を直列化したため、1 Aiの実測時間はV1より2クロック増加した。

最終計算では、`C_FINAL_PAIR_DOUBLE`を追加し、ペア項2倍と最終加算を共有データパスで順に行う。

## 6. 維持した数学アルゴリズム

V1と同じ3状態を保持している。

```text
prefix_sum
square_sum
pair_sum
```

入力`x`ごとの更新式も変更していない。

```text
old_prefix = prefix_sum
pair_sum   = pair_sum   + x * old_prefix mod MOD
square_sum = square_sum + x * x          mod MOD
prefix_sum = old_prefix + x              mod MOD
```

`pair_sum`には更新前の`prefix_sum`を使う。テストでは`A=[1,2,3]`について各入力後の値が次になることを再確認した。

| 処理後 | `prefix_sum` | `square_sum` | `pair_sum` |
|---:|---:|---:|---:|
| 1 | 1 | 1 | 0 |
| 2 | 3 | 5 | 2 |
| 3 | 6 | 14 | 11 |

最終回答式もV1から変更していない。

```text
answer = C(N-1,K-1) * square_sum
       + 2 * C(N-2,K-2) * pair_sum
       mod 998244353
```

`pair_sum`削除、`S1^2-S2`方式への変形、MOD・bit幅・`N_MAX`の縮小は行っていない。

## 7. 共有modular multiplierと組合せ係数

V1の`modular_multiplier`モジュールは変更していない。30-bit shift-add方式、加算相と2倍相の内部加算器共有、1 bitあたり2クロックという構成を維持している。

top `main`からのインスタンスは引き続き1個であり、次の全用途で共有している。

- `x * old_prefix`
- `x * x`
- 組合せ係数の分子・分母
- binary exponentiation中のresult更新とbase二乗
- `coeff_square * square_sum`
- `coeff_pair * pair_sum`

Icarusでの直接測定結果はV1と同じ60クロックだった。modular multiplierの追加、アルゴリズム変更、クロック数変更は行っていない。

`coeff_square=C(N-1,K-1)`の分子・分母逐次積とFermat逆元、`coeff_pair=C(N-2,K-2)`の計算式、`K=1`および`N=1,K=1`の特殊処理もV1のまま維持した。

## 8. SPI外部仕様

SPIプロトコル処理は変更していない。

- SPI Template V3
- 32-bit big-endianの`N`、`K`、`A_i`
- 4MHzをBaseline値とする転送
- payload中の`0x00 / 0xFD / 0xFE / 0xFF`をdataとして扱う仕様
- RESET / START ACK
- sticky `protocol_error`
- `0x00 / 0x80 / 0xC0`のSTATUS
- STATUS + 4-byte answer
- 1-byte応答遅延
- STATUSポーリング途中で計算が完了する境界への既存対策

`ffpga/src/spi_target.v`はV1参照版とSHA-256が一致したままである。

```text
C7166CE9076223A2818514EF7FF5CA3F6D322D1B9290484C5084C6AC09CD21EC
```

## 9. Icarus Verilogテスト

実行日は2026-08-17。使用したコマンドは次のとおりである。

```powershell
iverilog -g2012 -Wall -s abc471e_baseline_tb -o "$env:TEMP\abc471e_baseline_v2_compile_check.vvp" ffpga\src\main.v ffpga\src\spi_target.v sim\abc471e_baseline_tb.v
vvp "$env:TEMP\abc471e_baseline_v2_compile_check.vvp"
```

Icarusコンパイルは成功した。明示的な`timescale`がRTLモジュールにないという既存warningは出たが、errorはなかった。

既存testbenchはV1参照版と同一のまま使用した。timeout、期待値計算、テスト件数は変更していない。実行結果は次のとおりである。

```text
PERF MUL_CLOCKS=60 PRODUCT=263684735
PERF AI_SAMPLES=472 AI_MIN_CLOCKS=130 AI_MAX_CLOCKS=134
SUMMARY TOTAL=111 PASS=111 FAIL=0
```

111項目の内訳:

- shared modular multiplierの結果と60クロック確認: 1件
- 3状態途中値および手計算例: 1件
- `N=1,K=1`、`K=1`、`K=N`、mod境界およびpayload中`0xFF`: 4件
- `N<=8`のランダム小ケースと独立な全組み合わせ列挙の比較: 100件
- 不正NとERROR sticky、不正K、`N>N_MAX`と`K=0`、busy衝突、余分なpayload: 5件

## 10. 性能再測定

| 項目 | V1実測 | V2実測 | 差分 |
|---|---:|---:|---:|
| 共有modular multiplier | 60 clocks | 60 clocks | 0 |
| 1 Ai最小 | 128 clocks | 130 clocks | +2 |
| 1 Ai最大 | 132 clocks | 134 clocks | +2 |

AIクロックはtestbenchが`x_busy`の立上りから立下りまでを測定した値で、サンプル数は472である。最小・最大の差はV1と同様に32-bit入力を`MOD`へ正規化する逐次減算回数による。

4MHz SPI / 50MHz FPGAでは32-bit Ai 1個の転送に約400クロックある。V2最大値134クロックはその33.5%で、次のAi word完成まで266クロックの余裕がある。したがってV2の追加直列化後もBaselineのSPIストリーム速度へ追従できる。

## 11. 未変更確認

V1参照版とのSHA-256比較結果は次のとおりである。

| ファイル | V1参照版との一致 | SHA-256 |
|---|---|---|
| `ffpga/src/spi_target.v` | 一致 | `C7166CE9076223A2818514EF7FF5CA3F6D322D1B9290484C5084C6AC09CD21EC` |
| `sim/abc471e_baseline_tb.v` | 一致 | `1EB24E172784014E00ABB7F469C96174732EBAEF806DE4DA230D83CD3870BB34` |
| `firmware/micropython/abc471e_baseline_test.py` | 一致 | `087236B433E2E21E9D280C9C836E6B884FD54FEB256373D1E1709676C0A4E747` |

`reference/`以下には書き込みを行っていない。

## 12. 停止した工程

ユーザー指定の停止条件に従い、次は実施していない。

- ForgeFPGA Workshop Lint
- ForgeFPGA Workshop synthesis
- PNR
- V2 bitstream生成
- 実機flash
- 実機試験

したがって、V2のLC、FF、CARRY、fit可否、timing結果は未取得である。`ffpga/build/`内のファイルはV1からコピーされた旧成果物のままであり、V2の評価値ではない。
