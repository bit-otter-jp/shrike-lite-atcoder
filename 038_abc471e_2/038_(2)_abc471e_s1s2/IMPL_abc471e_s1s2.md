# ABC471E S1/S2 実装設計

## 1. 基準実装の確認

実装の基準には `reference/abc471e_baseline_v2/` を使用する。作業開始時点の次の現行ファイルは、Baseline V2 の対応ファイルと SHA-256 が一致している。

```text
ffpga/src/main.v
ffpga/src/spi_target.v
sim/abc471e_s1s2_tb.v
firmware/micropython/abc471e_s1s2_test.py
```

Baseline V2 RTL は、ストリーム中に次の3状態を保持する。

```text
prefix_sum
square_sum
pair_sum
```

入力処理用に `old_prefix` も保持し、算術FSMは次の順で2回の共有乗算を行う。

```text
C_NORMALIZE
  -> C_INPUT_PAIR_START
  -> C_INPUT_PAIR_WAIT
  -> C_INPUT_PAIR_ADD       x * old_prefix を pair_sum へ加算
  -> C_INPUT_SQUARE_WAIT    上のADD状態で x * x を開始済み
  -> C_INPUT_SQUARE_ADD     x * x を square_sum へ加算
  -> C_INPUT_PREFIX_ADD     x を prefix_sum へ加算
```

V2 のtop側 modular addは、`calc_state`でoperandと保存先を選ぶ1系統へ時間共有済みである。30-bit shift-add modular multiplierもtopから1インスタンスだけで、1 bitを加算相と2倍相の2クロックで処理し、1乗算60クロックである。

組合せ係数は分子・分母の逐次積とFermat逆元を使い、最終段では `coeff_square*square_sum` と `coeff_pair*pair_sum` を計算していた。

Baseline V2 のPost-Synthesis成果物も確認した。`post_synth_results.v` は Yosys 0.59+0 が `main.v` 1～822行と `spi_target.v` をflattenして出力したnetlistであり、`post_synth_report.txt` のtop `main` local countは次のとおりである。

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

IMPL_REQUESTに記録されたV2 PNRは `Type=L Capacity=140 Utilized=571` でfitしていない。本実装ではその結果を受け、数値条件を縮小せず、指定されたS1/S2化だけを行う。

## 2. 保持状態と削除対象

ストリーム中の数学状態を次の2本へ置き換える。

```text
s1 = ΣAi   mod MOD
s2 = ΣAi²  mod MOD
```

V2から削除する30-bitレジスタは次のとおりである。

```text
old_prefix
pair_sum
```

`prefix_sum` は役割を明確にするため `s1`、`square_sum` は `s2` へ改名する。A配列は従来どおり保存しない。

入力ペア項専用の次の状態と経路も削除する。

```text
C_INPUT_PAIR_START
C_INPUT_PAIR_WAIT
C_INPUT_PAIR_ADD

x * old_prefix のoperand選択
pair_sum更新用の共有加算operand・保存先
```

V2の最終ペア項2倍用 `C_FINAL_PAIR_DOUBLE` も不要になる。代わりに、最終段へ `S1²` 乗算、modular subtraction、2つの項の乗算を行う状態を置く。

## 3. S1/S2入力更新シーケンス

32-bit `x_raw` はV2と同じ逐次減算で正規化する。

```text
while x_raw >= MOD:
    x_raw -= MOD
```

正規化後の1要素は次の算術FSMで処理する。

```text
C_NORMALIZE
  -> C_INPUT_SQUARE_START   mul_mod(x_reg, x_reg)を開始
  -> C_INPUT_SQUARE_WAIT    mul_doneを待つ
  -> C_INPUT_S2_ADD         s2 = add_mod(s2, mul_product)
  -> C_INPUT_S1_ADD         s1 = add_mod(s1, x_reg)、入力完了
```

`C_INPUT_S1_ADD`で `input_count` を増やして `x_busy` を下げる。最終要素なら、`K==1` は既存の高速終了へ、それ以外は既存の組合せ係数計算へ進む。

この系列の可変乗算は `x*x` の1回だけである。S1とS2は各更新後も常に `0 <= value < MOD` を保つ。

## 4. 共有modular add/subデータパス

V2のtop側共有modular addを、1個の31-bit add/subコアへ拡張する。共有化専用の30-bit operand保持レジスタやdestinationレジスタは追加しない。

主要信号は次の構成とする。

```text
mod_arith_a[29:0] ----┐
                      +-- 31-bit add/sub -- raw_sum[30:0]
mod_arith_b[29:0] --XOR(op_sub)--┘       + carry-in(op_sub)

raw_sum -- MOD比較/条件付きMOD減算 -- reduced_result
```

加減算コアは次の式で記述する。

```text
b_selected = mod_arith_b XOR {30{mod_arith_sub}}
raw_sum = {1'b0, mod_arith_a}
        + {1'b0, b_selected}
        + mod_arith_sub
```

`mod_arith_sub=0`では通常の加算、`mod_arith_sub=1`では30-bit二の補数減算になる。通常のmodular addではV2と同じく、`raw_sum>=MOD`ならMODを1回減算した結果を使う。

`S1²-S2`では両operandが30-bitの正規化済み値なので、減算結果と `raw_sum[30]` を次のように扱う。

```text
raw_sum[30] == 1:
    borrowなし。raw_sum[29:0]が S1²-S2

raw_sum[30] == 0:
    borrowあり。raw_sum[29:0]は2^30+S1²-S2
    次状態で同じ加算コアへMODを加え、下位30bitを採用
    -> S1²+MOD-S2
```

borrow補正では31-bit和の下位30bitを採ることで2^30のwrapを利用する。補正後の値は0以上MOD未満である。これによりmodular subtraction専用の別30-bit subtract/addデータパスを並置せず、V2の共有加算器をadd/subとして時間共有する。borrowの有無は次状態そのもので表し、保持用フラグは追加しない。

operand、演算モード、保存先は次のとおりである。

| `calc_state` | A | B | mode/result | 保存先 |
|---|---|---|---|---|
| `C_INPUT_S2_ADD` | `s2` | `mul_product` | add_mod | `s2` |
| `C_INPUT_S1_ADD` | `s1` | `x_reg` | add_mod | `s1` |
| `C_FINAL_PAIR_SUB` | `term_pair` | `s2` | raw subtract | `term_pair` |
| `C_FINAL_PAIR_CORRECT` | `term_pair` | `MOD` | raw add/wrap | `term_pair` |
| `C_FINAL_ADD` | `term_square` | `term_pair` | add_mod | `answer` |

`C_FINAL_PAIR_CORRECT`はborrow時だけ通る。

## 5. 共有multiplierの利用順序

`modular_multiplier`モジュールのRTL、30-bit幅、shift-add方式、1乗算60クロックは変更しない。topのインスタンスも1個のまま、全ての可変乗算を逐次実行する。

利用順は次のとおりである。

```text
入力1個ごと:
    x * x

coeff_square:
    numerator * (n-r+i)
    denominator * i
    denominator^(MOD-2) のbinary exponentiation
    numerator * inverse(denominator)

coeff_pair:
    (N-1)^(MOD-2) のbinary exponentiation
    coeff_square * (K-1)
    上の結果 * inverse(N-1)

最終計算:
    s1 * s1
    coeff_square * s2
    coeff_pair * pair_twice
```

一般的な可変 `*`、除算器、`%`回路、2個目のmodular multiplierは追加しない。

## 6. 組合せ係数計算

組合せ係数の数学とFSMはBaseline V2から変更しない。

```text
coeff_square = C(N-1,K-1)
coeff_pair   = C(N-2,K-2)
```

`coeff_square`は `r=min(K-1,N-K)` として分子・分母を逐次積算し、`denominator^(MOD-2)`による逆元を掛ける。`coeff_pair`は次のV2式で求める。

```text
coeff_pair = coeff_square * (K-1) * inverse(N-1) mod MOD
```

`K==1`では係数計算を行わず `answer=s2` とするため、`N=1,K=1`で `inverse(0)`は実行されない。階乗テーブルや別の組合せ恒等式は導入しない。

## 7. 最終計算とscratch共有

最終計算は次の順に行う。

```text
C_FINAL_S1_SQUARE_START/WAIT:
    term_pair = mul_mod(s1, s1)       // 一時的にs1_square

C_FINAL_PAIR_SUB:
    term_pair = term_pair - s2        // borrowなし
    またはraw差を保存してCORRECTへ

C_FINAL_PAIR_CORRECT:                 // borrow時のみ
    term_pair = raw_difference + MOD  // 下位30bitを採用

C_FINAL_TERM_SQUARE_START/WAIT:
    term_square = mul_mod(coeff_square, s2)

C_FINAL_TERM_PAIR_START/WAIT:
    term_pair = mul_mod(coeff_pair, term_pair)

C_FINAL_ADD:
    answer = add_mod(term_square, term_pair)
```

既存の `term_pair` の値の寿命は、`s1_square`、`pair_twice`、最終 `term_pair` の順で重ならない。そのため、この1本を上記3用途へ再利用し、専用の `s1_square` と `pair_twice` は追加しない。`term_square`は最終加算まで保持するためV2から維持する。

最終式は要求どおり次のままであり、追加変形しない。

```text
answer = coeff_square * s2
       + coeff_pair * (s1*s1 - s2 mod MOD)
       mod MOD
```

## 8. 想定クロック

V2実測は次のとおりである。

```text
MUL_CLOCKS    = 60
AI_MIN_CLOCKS = 130
AI_MAX_CLOCKS = 134
```

入力処理から1回の60クロック乗算とペア更新経路がなくなる。V2の状態遷移を基にしたS1/S2版の事前見積りは次のとおりである。

```text
MUL_CLOCKS    = 60
AI_MIN_CLOCKS = 約67
AI_MAX_CLOCKS = 約71
```

最小・最大の4クロック差は、最大32-bit unsigned入力に対する0～4回の逐次MOD減算による。正確な値はIcarus testbenchで `x_busy` の立上りから立下りまでを再測定する。見積り最大値は、4MHz SPI / 50MHz FPGAの約400クロック/Aiを十分下回る。

## 9. V2から維持する部分

次はBaseline V2から維持する。

- `MOD=998244353`、`N_MAX=200000`、30-bit modular値
- 32-bit unsigned `N/K/A_i` とbig-endian転送
- SPI Template V3、4MHz基準、1-byte応答遅延
- payload中の予約値をdataとして扱う状態分離
- RESET/START ACK、STATUS + 4-byte answer
- sticky `protocol_error` と既存の全エラー条件
- STATUSポーリング完了境界の `status_loaded` / `tx_byte_active` 対策
- A word完成時のbusy衝突検出と余分payload検出
- 共有modular multiplierの実装と60クロック性能
- 組合せ係数の逐次積、Fermat逆元、binary exponentiation
- `K==1` と `N==1,K==1` の特殊処理
- A配列を保存しないストリーム処理

`ffpga/src/spi_target.v`は変更しない。`reference/`以下にも書き込まない。MicroPythonテストは外部仕様が同一なので、bitstream名だけS1/S2版へ変更する。

## 10. 検証方針

Baseline V2の111項目構成を維持する。外部SPI、異常系、独立な全組み合わせ期待値、ランダム小ケース100件、共有multiplier直接試験はそのまま残す。

V2の3状態途中値試験だけを、`A=[1,2,3]`について次を確認するS1/S2試験へ置換する。

```text
処理後1: s1=1, s2=1
処理後2: s1=3, s2=5
処理後3: s1=6, s2=14

s1*s1-s2 mod MOD = 22
2*(1*2+1*3+2*3) mod MOD = 22
```

Icarusでコンパイル、111項目の結果、`MUL_CLOCKS`、`AI_MIN_CLOCKS`、`AI_MAX_CLOCKS`を記録する。

## 11. 意図的に行わないことと停止点

S1/S2化の効果だけを評価するため、次は行わない。

- MOD、Aのbit幅、N_MAXの縮小
- 組合せ係数の別アルゴリズム化
- 階乗テーブルやA配列のBRAM保存
- modular multiplierの追加または方式変更
- 一般的な可変乗算器、除算器、剰余器の追加
- SPIプロトコル、`spi_target.v`、`reference/`以下の変更
- 面積が大きいという推測に基づく次段階の仕様縮小

RTL実装後はIcarus検証と性能再測定、実装レポート作成までで停止する。ForgeFPGA WorkshopのLint・合成・PNR、bitstream生成、実機flash、実機試験は行わない。
