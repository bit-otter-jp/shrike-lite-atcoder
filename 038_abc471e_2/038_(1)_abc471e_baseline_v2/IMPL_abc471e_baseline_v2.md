# ABC471E Baseline V2 実装設計

## 1. V1確認結果

作業開始時点の`ffpga/src/main.v`、`ffpga/src/spi_target.v`、`sim/abc471e_baseline_tb.v`、`firmware/micropython/abc471e_baseline_test.py`は、`reference/abc471e_baseline_v1/`内の対応ファイルとSHA-256が一致している。

V1の`main.v`では30-bit modular addをVerilog function `add_mod()`として定義し、次の5か所から呼び出している。

```text
pair_sum   + mul_product
square_sum + mul_product
old_prefix + x_reg
mul_product + mul_product
term_square + term_pair
```

function呼び出しごとに、31-bit加算、`MOD`比較、条件付き`MOD`減算の組み合わせ回路が展開され得る構造である。V1のPost-Synthesis reportでは、top `main`のlocal countとして次が記録されている。

```text
cells  = 3492
CARRY4 = 183
FDCE   = 1024
FDPE   = 9
```

可変modular multiplierはすでに1個へ集約され、その内部でも加算相と2倍相が1個の31-bit加算器を時間共有している。V2ではこの乗算器には手を加えず、top側の5個の`add_mod()`呼び出しだけを共有化対象とする。

## 2. 共有modular addデータパス

`main.v`から`add_mod()` functionを削除し、topに次の1系統だけを置く。

```text
mod_add_a[29:0] ─┐
                  ├─ 31-bit加算 ─ MOD比較 ─ MOD減算 ─ mod_add_result[29:0]
mod_add_b[29:0] ─┘
```

式は次のとおりである。

```text
mod_add_sum = {1'b0, mod_add_a} + {1'b0, mod_add_b}

if mod_add_sum >= MOD:
    mod_add_result = mod_add_sum - MOD
else:
    mod_add_result = mod_add_sum
```

`mod_add_a`と`mod_add_b`は保持レジスタにせず、`calc_state`による組み合わせmux出力とする。全分岐に既定値を与えてラッチ生成を防ぐ。これにより、共有化のためだけに30-bitレジスタを2本追加せず、1個の加算・比較・減算データパスへ5用途を接続する。

共有modular multiplier内部の加算器は乗算器アルゴリズムの一部であり、V1のまま維持する。topの共有modular addとは独立だが、V2で追加・複製するものではない。

## 3. operand選択とresult destination

operandと保存先は専用destinationレジスタを追加せず、次の算術FSM状態で一意に指定する。

| `calc_state` | operand A | operand B | 次クロックの保存先 |
|---|---|---|---|
| `C_INPUT_PAIR_ADD` | `pair_sum` | `mul_product` | `pair_sum` |
| `C_INPUT_SQUARE_ADD` | `square_sum` | `mul_product` | `square_sum` |
| `C_INPUT_PREFIX_ADD` | `old_prefix` | `x_reg` | `prefix_sum` |
| `C_FINAL_PAIR_DOUBLE` | `mul_product` | `mul_product` | `term_pair` |
| `C_FINAL_ADD` | `term_square` | `term_pair` | `answer` |

各状態で参照される乗算結果は、共有modular multiplierの`o_product`が次の乗算開始まで保持される既存仕様を利用する。

## 4. 算術FSM変更

入力1個の更新シーケンスを次のように変更する。

```text
C_INPUT_PAIR_START
  -> C_INPUT_PAIR_WAIT
  -> C_INPUT_PAIR_ADD       pair_sumへ共有加算結果を保存し、x*xを開始
  -> C_INPUT_SQUARE_WAIT
  -> C_INPUT_SQUARE_ADD     square_sumへ共有加算結果を保存
  -> C_INPUT_PREFIX_ADD     prefix_sumへ共有加算結果を保存、入力完了
```

`C_INPUT_PAIR_ADD`はV1の`C_INPUT_SQUARE_START`が使っていた1クロックを兼用し、`pair_sum`保存と次の乗算開始を同じクロックで行う。したがってpair加算共有化では余分なクロックを増やさない。square加算とprefix加算を順番に行うため、V1より1 Aiあたり2クロック増える想定である。

最終回答は次のように変更する。

```text
C_FINAL_PAIR_WAIT
  -> C_FINAL_PAIR_DOUBLE    2*term_pairを共有加算器で生成・保存
  -> C_FINAL_ADD            term_square+term_pairを共有加算器で生成・保存
  -> C_PUBLISH
```

V1で`C_FINAL_PAIR_WAIT`中に直接行っていた2倍処理を独立状態にするため、最終回答計算はV1より1クロック増える想定である。

## 5. 追加・削除する主要信号

追加するもの:

- `mod_add_a[29:0]`: FSMで選択する組み合わせoperand
- `mod_add_b[29:0]`: FSMで選択する組み合わせoperand
- `mod_add_sum[30:0]`: 単一のwide sum
- `mod_add_reduced[30:0]`: 単一の条件付きMOD減算結果
- `mod_add_result[29:0]`: FSMが保存する剰余値
- 共有加算の逐次実行に必要な算術FSM状態

削除するもの:

- `add_mod()` functionとその5呼び出し
- `C_INPUT_SQUARE_START`（役割を`C_INPUT_PAIR_ADD`へ統合）

共有化専用の新規オペランド保持レジスタおよびdestinationレジスタは追加しない。既存scratch registerは数学処理とSPI境界を変えないため、そのほかは維持する。

## 6. 想定クロック

V1実測は次のとおりである。

```text
MUL_CLOCKS    = 60
AI_MIN_CLOCKS = 128
AI_MAX_CLOCKS = 132
```

V2では共有modular multiplierを変更せず、1 Aiあたり共有加算状態を2クロック追加するため、想定値は次のとおりである。

```text
MUL_CLOCKS    = 60
AI_MIN_CLOCKS = 130程度
AI_MAX_CLOCKS = 134程度
```

実際の値はIcarusテストで再測定する。想定最大値は4MHz SPI / 50MHz FPGAの約400クロック/Aiを十分下回る。

## 7. V1から変更しない部分

次はV1のまま維持する。

- `prefix_sum`、`square_sum`、`pair_sum`の3状態と更新式
- 更新前`prefix_sum`を`old_prefix`としてpair項へ使う順序
- `MOD=998244353`、`N_MAX=200000`、各データ幅
- 30-bit shift-add modular multiplier 1個と60クロックのアルゴリズム
- 組合せ係数、Fermat逆元、binary exponentiation
- `K=1`および`N=1,K=1`の特殊処理
- SPI Template V3、32-bit big-endian、1-byte応答遅延
- payload中予約値のdata扱い、sticky error、STATUS応答競合修正
- MicroPython側の外部仕様と期待値計算

`ffpga/src/spi_target.v`および`reference/`以下は変更しない。

## 8. 意図的に行わない最適化

V2ではmodular add時間共有の効果を単独で比較できるよう、次を行わない。

- `pair_sum`の削除または数式変形
- MOD、Aのbit幅、N_MAXの縮小
- modular multiplierの追加、方式変更、クロック数変更
- A配列または階乗テーブルの保存
- 大規模なFSM再設計
- SPIプロトコルまたは`spi_target.v`の変更
- modular add共有化以外を主目的とした追加面積最適化

## 9. 検証方針と停止点

RTL変更後、既存Icarusテスト111項目を削除せず再実行する。テストベンチの性能期待値だけをV2実測に合わせて更新し、次を記録する。

```text
SUMMARY TOTAL=111 PASS=111 FAIL=0
PERF MUL_CLOCKS
PERF AI_MIN_CLOCKS
PERF AI_MAX_CLOCKS
```

ForgeFPGA WorkshopのLint、合成、PNR、bitstream生成および実機試験は実施しない。
