# ABC471E Baseline 実装レポート

## 1. 概要

`SPEC_abc471e_baseline.md`に従い、ABC471E「Sum of Square of Sum」をSPIストリーム入力で計算するBaseline RTLを実装した。

実装はSPI Template V3の構造を維持し、配列`A`全体を保存せず、次の3状態を逐次更新する方式とした。

```text
prefix_sum
square_sum
pair_sum
```

可変modular multiplierは30-bit逐次型を1個だけ配置し、入力集計、組合せ係数、Fermat逆元、最終回答の全乗算で共有している。

## 2. 変更ファイル

| ファイル | 内容 |
|---|---|
| `ffpga/src/main.v` | SPIプロトコルFSM、入力word組立て、3状態更新、組合せ係数、逆元、最終回答、共有modular multiplierを実装 |
| `firmware/micropython/abc471e_baseline_test.py` | 32-bit big-endian転送、Aストリーム送信、STATUSポーリング、4-byte回答受信、独立期待値計算を実装 |
| `sim/abc471e_baseline_tb.v` | Icarus Verilog用SPI・算術・プロトコル・性能テストを新規作成 |
| `IMPLEMENTATION_REPORT_abc471e_baseline.md` | 本レポートを新規作成 |

`ffpga/src/spi_target.v`は変更していない。`reference/`以下も変更していない。

## 3. RTL全体構成

`ffpga/src/main.v`は、主に次の部分で構成した。

- SPI Template V3の`spi_target`インスタンス
- SPIプロトコルFSM
  - `P_WAIT_START`
  - `P_WAIT_START_ACK`
  - `P_RECEIVE_N`
  - `P_RECEIVE_K`
  - `P_STREAM_A`
  - `P_WAIT_RESULT`
  - `P_SEND_REPLY`
- 算術FSM
  - 入力値のmod正規化
  - 3状態更新
  - 組合せ係数計算
  - binary exponentiationによる逆元計算
  - 最終回答計算
- 共有30-bit逐次modular multiplier 1個

SPI byte組立てと算術FSMは独立して進行する。Aの32-bit word完成時に`x_busy`を確認し、空いていれば現在値として受理し、busy中ならstickyな`protocol_error`を設定してエラー応答へ移る。

## 4. 3状態のストリーム更新

受信した32-bit unsigned値は、`MOD = 998244353`以上の間、定数`MOD`を逐次減算して30-bit residueへ正規化する。

正規化後、更新前の`prefix_sum`を`old_prefix`へ保存し、共有乗算器を順に使用して次を実行する。

```text
pair_sum   = pair_sum   + x * old_prefix mod MOD
square_sum = square_sum + x * x          mod MOD
prefix_sum = old_prefix + x              mod MOD
```

`pair_sum`には更新前の`prefix_sum`を使用しており、`x*x`がpair項へ混入しない順序になっている。処理後は`input_count`を増加し、入力値そのものは保持しない。

テストベンチでは`A=[1,2,3]`について、各入力後の状態が次の値になることを確認した。

| 処理後 | `prefix_sum` | `square_sum` | `pair_sum` |
|---:|---:|---:|---:|
| 初期 | 0 | 0 | 0 |
| 1 | 1 | 1 | 0 |
| 2 | 3 | 5 | 2 |
| 3 | 6 | 14 | 11 |

## 5. 共有30-bit shift-add modular multiplier

`main.v`内に`modular_multiplier`モジュールを定義し、topの`main`から1個だけインスタンスしている。合成対象RTLでは可変乗算用の`*`演算子を使用していない。

各bitについて次の2相を実行する。

1. multiplierのLSBが1なら`acc + addend`をmodular加算する。
2. `addend + addend`をmodular加算し、multiplierを右シフトする。

この2相で1個の31-bit加算器を時間共有し、30 bitを処理するため、1乗算は実測60クロックである。

共有乗算器は次の全用途に使用している。

- `x * old_prefix`
- `x * x`
- 組合せ係数の分子・分母
- binary exponentiation中のresult更新とbase二乗
- `coeff_square * square_sum`
- `coeff_pair * pair_sum`

## 6. 組合せ係数とFermat逆元

次の係数を計算する。

```text
coeff_square = C(N-1, K-1)
coeff_pair   = C(N-2, K-2)
```

`coeff_square`は、`n=N-1`、`r=min(K-1,n-(K-1))`として、階乗テーブルを持たずに分子と分母を逐次積算する。

```text
numerator   = product(n-r+i), i=1..r
denominator = product(i),     i=1..r
coeff_square = numerator * inverse(denominator) mod MOD
```

逆元は`MOD`が素数であることを利用し、同じ共有乗算器によるbinary exponentiationで次を求める。

```text
inverse(a) = a^(MOD-2) mod MOD
```

`K>=2`の`coeff_pair`は次の関係を使う。

```text
coeff_pair = coeff_square * (K-1) * inverse(N-1) mod MOD
```

`K=1`では`coeff_square=1`、`coeff_pair=0`として係数・逆元計算を省略する。したがって`N=1,K=1`で`inverse(0)`は実行しない。

最終回答は共有乗算器とmodular加算で次のとおり計算する。

```text
answer = coeff_square * square_sum
       + 2 * coeff_pair * pair_sum
       mod MOD
```

## 7. SPI payloadとSTATUS応答

`N`、`K`、`A_i`は32-bit big-endianで4 byteずつ組み立てる。`P_RECEIVE_N`、`P_RECEIVE_K`、`P_STREAM_A`では全byteをpayloadとして扱うため、payload中の`0x00`、`0xFD`、`0xFE`、`0xFF`をコマンドとして解釈しない。

RESETは制御待ち状態でのみコマンドとして認識する。AストリームはCS境界を要素境界として使用せず、連続burstを受信できる。

回答は次の5 byte形式で返す。

```text
STATUS, answer[31:24], answer[23:16], answer[15:8], answer[7:0]
```

STATUSは未完了`0x00`、正常完了`0x80`、エラー付き完了`0xC0`である。SPIの1-byte応答遅延に合わせ、ホストがNOPでVALID STATUSを受信した後、続く4個のNOPに対して回答byteを順に返す。

`protocol_error`はRESETまでstickyとした。テスト対象には不正なN/K、busy中のA word完成、N個受信後の余分なpayloadを含めた。

## 8. 実装中に発見・修正した問題

### STATUSポーリング競合

計算完了がSTATUSポーリング用NOPの転送途中に発生する場合、送信シフタには未完了STATUSの`0x00`が既にロードされている一方、NOP受信完了時には`reply_valid`が1になっていることがあった。

当初はNOP受信時点の`reply_valid`だけで回答送信へ進めていたため、ホストへVALID STATUSを実際には返していないのに先頭回答byteへ進み、回答byteがSTATUSとして観測される競合が発生した。

修正では`spi_target`の`o_tx_data_hold`を接続し、`tx_byte_active`と`status_loaded`で、そのSPI byteにVALID STATUSが実際にロードされたかを記録した。`P_WAIT_RESULT`から`P_SEND_REPLY`へ進む条件を`reply_valid && status_loaded`とし、計算完了が転送途中だった場合は`0x80`または`0xC0`を次のpoll用に保持するようにした。

この修正に`spi_target.v`自体の変更は不要だった。

## 9. Icarus Verilogテスト結果

確認時に使用したコマンドは次のとおり。

```powershell
iverilog -g2012 -Wall -s abc471e_baseline_tb -o $env:TEMP\abc471e_baseline_report_check.vvp ffpga\src\main.v ffpga\src\spi_target.v sim\abc471e_baseline_tb.v
vvp $env:TEMP\abc471e_baseline_report_check.vvp
```

結果:

```text
PERF MUL_CLOCKS=60 PRODUCT=263684735
PERF AI_SAMPLES=472 AI_MIN_CLOCKS=128 AI_MAX_CLOCKS=132
SUMMARY TOTAL=111 PASS=111 FAIL=0
```

111項目の内訳は次のとおり。

- 共有modular multiplierの結果と60クロック確認: 1件
- 3状態途中値および手計算例: 1件
- `N=1,K=1`、`K=1`、`K=N`、mod境界およびpayload中`0xFF`: 4件
- `N<=8`のランダム小ケースを独立な全組み合わせ列挙と比較: 100件
- 不正NとERROR sticky、不正K、`N>N_MAX`と`K=0`、busy衝突、余分なpayload: 5件

合計111件すべてPASSした。

## 10. 性能測定

| 項目 | 実測結果 |
|---|---:|
| 共有modular multiplier 1乗算 | 60クロック |
| 1 Aiの処理 | 128～132クロック |

1 Aiの値は`x_busy`の立上りから立下りまでをテストベンチで計測した。差は32-bit入力を`MOD`へ正規化する逐次減算回数による。

仕様上の50MHz FPGA、4MHz SPIでは32-bit Ai 1個の転送間隔は約400クロックであり、測定した最大132クロックはこの間隔内である。

## 11. 仕様からの逸脱と未実施項目

確認した範囲で、Baseline方式に関する仕様からの意図的な逸脱はない。

- `pair_sum`を削除していない。
- `MOD=998244353`、`N_MAX=200000`を維持している。
- 主要なmod値は30-bitで保持している。
- 可変modular multiplierは1個だけである。
- A配列および階乗テーブルを保存していない。
- `ffpga/src/spi_target.v`は未変更である。
- `reference/`以下は未変更である。

ForgeFPGA Workshopでの合成は実施していない。そのため、LUT、FF、CLB、BRAM、WNS、Achievable Frequencyの結果は未取得である。実機への書き込みおよび実機試験も実施していない。
