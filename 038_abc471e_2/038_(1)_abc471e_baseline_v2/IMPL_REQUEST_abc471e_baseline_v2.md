# ABC471E Baseline V2 実装要求

## 1. 目的

`abc471e_baseline_v1`では、ABC471Eを次の3状態でストリーム処理するBaselineを実装した。

```text
prefix_sum
square_sum
pair_sum
```

各入力`x`について、

```text
pair_sum   += x * old_prefix
square_sum += x * x
prefix_sum += x
```

を`MOD = 998244353`上で実行する。

可変modular multiplierは30-bit逐次型を1個だけ配置し、入力集計、組合せ係数、Fermat逆元、最終回答の全乗算で共有した。

Icarus Verilog検証では次を確認済みである。

```text
SUMMARY TOTAL=111 PASS=111 FAIL=0
PERF MUL_CLOCKS=60
PERF AI_MIN_CLOCKS=128 AI_MAX_CLOCKS=132
```

一方、ForgeFPGA Workshopでの合成後統計は次の結果となった。

```text
Estimated number of LCs: 1473

FDCE 1024
FDPE    9

CARRY4 183
```

PNRでは次のresource over-useにより配置不能となった。

```text
Type=L
Capacity=140
Utilized=577

FATAL ERROR:
The design cannot fit into the current geometry.
```

Baseline V2では、**数学アルゴリズムを変更せず、modular add回路の時間共有によって面積を削減する**。

---

## 2. V1解析結果

V1では可変modular multiplierは1個へ共有済みである。

しかし`main.v`内の`add_mod()`は複数箇所から呼び出しており、合成後は各呼び出し位置へ組み合わせ回路として展開されている。

主な利用箇所は次のとおり。

```text
pair_sum更新
square_sum更新
prefix_sum更新
term_pairの2倍
answerの最終加算
```

`add_mod()`は概念的に、

```text
a + b
↓
MOD以上か比較
↓
必要ならMODを減算
```

を行う30-bit級の組み合わせ回路である。

Post-Synthesis結果では、この周辺に多数のcarry chainが生成されている。

V2ではここを主な削減対象とする。

---

## 3. V2で変更するもの

V2では、複数箇所へ展開されているmodular add処理を、**1個の共有modular addデータパス**へ集約する。

概念的には次の構成とする。

```text
shared_mod_add_a
shared_mod_add_b
        ↓
shared modular adder
        ↓
shared_mod_add_result
        ↓
FSMで指定されたレジスタへ保存
```

operandとresult destinationはFSMで切り替える。

例えば、

```text
pair_sum更新
    ↓
operand = pair_sum, mul_result
    ↓
shared modular add
    ↓
pair_sumへ保存

square_sum更新
    ↓
operand = square_sum, mul_result
    ↓
shared modular add
    ↓
square_sumへ保存

prefix_sum更新
    ↓
operand = old_prefix, x
    ↓
shared modular add
    ↓
prefix_sumへ保存
```

のように、同じmodular add回路を順番に使用する。

---

## 4. 共有modular addの実装方針

V2では`add_mod()`を単に別functionへ移動するだけでは不可とする。

Verilog functionの複数呼び出しによって再び組み合わせ回路が複製されない構成にすること。

共有データパスとして、

```text
operand A
operand B
wide sum
MOD比較
MOD減算
30-bit result
```

を1系統だけ配置する。

実装方法は既存`main.v`に合わせてよい。

必要なら、

```text
mod_add_a
mod_add_b
mod_add_result
mod_add_destination
```

などの信号を設ける。

modular add自体を1クロックまたは複数クロックで処理するかは、面積と既存FSMの構成を見て決めてよい。

ただし、複数の独立した30-bit modular add回路を再び生成しないこと。

---

## 5. 時間方向の扱い

V1では1入力`Ai`の処理時間は、

```text
128～132 clocks
```

だった。

4MHz SPI / 50MHz FPGAでは32-bit `Ai` 1個の転送に約400クロック相当の時間がある。

したがってV2では、modular addを逐次化して入力処理クロックが増えてもよい。

目安:

```text
AI_MAX_CLOCKS < 約400 clocks
```

であれば、4MHz SPIストリームへの追従は可能である。

V2では速度より面積削減を優先する。

ただし不必要に遅い構成へ変更する必要はない。

---

## 6. V2で維持する数学

次の数学構造は変更しない。

```text
prefix_sum
square_sum
pair_sum
```

更新式:

```text
old_prefix = prefix_sum

pair_sum =
    pair_sum + x * old_prefix mod MOD

square_sum =
    square_sum + x * x mod MOD

prefix_sum =
    old_prefix + x mod MOD
```

最終回答:

```text
answer =
    C(N-1,K-1) * square_sum
  + 2 * C(N-2,K-2) * pair_sum
    mod MOD
```

`pair_sum`には必ず更新前の`prefix_sum`を使用する。

---

## 7. 維持する定数・外部仕様

次を変更しない。

```text
MOD   = 998244353
N_MAX = 200000
```

入力:

```text
N     : 32-bit
K     : 32-bit
A_i   : 32-bit unsigned
```

SPI転送:

```text
32-bit big-endian
SPI Template V3
4MHzをBaseline値とする
```

回答:

```text
STATUS + 4-byte answer
```

STATUS:

```text
0x00 : 未完了
0x80 : 正常完了
0xC0 : エラー付き完了
```

SPIの1-byte応答遅延も維持する。

---

## 8. 維持する共有modular multiplier

V1の30-bit shift-add modular multiplierを維持する。

```text
1 modular multiplication = 60 clocks
```

用途:

```text
x * old_prefix
x * x

組合せ係数の分子・分母
binary exponentiation
coeff_square * square_sum
coeff_pair * pair_sum
```

V2ではmodular multiplierを追加しない。

既存multiplierのアルゴリズムやクロック数も変更しない。

---

## 9. 維持する組合せ係数計算

`coeff_square`:

```text
C(N-1,K-1)
```

はV1と同様に、

```text
分子の逐次積
分母の逐次積
Fermat逆元
```

で求める。

modular inverse:

```text
a^(MOD-2) mod MOD
```

をbinary exponentiationで計算する。

`coeff_pair`:

```text
C(N-2,K-2)
```

は、

```text
C(N-1,K-1) * (K-1) / (N-1)
```

から求める。

`K=1`および`N=1,K=1`の特殊処理も維持する。

---

## 10. 維持するSPI・protocol処理

次を変更しない。

- `spi_target.v`
- SPI Template V3
- 32-bit word assembler
- payload中の`0x00 / 0xFD / 0xFE / 0xFF`をdataとして扱う仕様
- sticky `protocol_error`
- STATUS + 4-byte回答
- STATUSポーリング競合への既存修正

特に、計算完了がSTATUS poll byteの転送途中に発生した場合でも、ホストへVALID STATUSを実際に返す前に回答byteへ進まないこと。

---

## 11. V2で禁止する変更

V2では次を行わない。

```text
pair_sumを削除する
S1^2-S2方式へ変更する

MODを変更する
A_iのbit幅を縮小する
N_MAXを縮小する

modular multiplierを追加する
modular multiplierの方式を変更する

A配列をBRAMへ保存する
階乗テーブルを作る

SPIプロトコルを変更する
spi_target.vを変更する

reference/以下を変更する
```

V2の目的は、**modular add時間共有の効果を単独で評価すること**である。

まだ面積が大きそうでも、別アルゴリズムへの追加最適化を行わない。

---

## 12. scratch registerの共有

modular add時間共有に直接関係する範囲で、不要になった一時レジスタやscratch registerを整理・共有してよい。

ただし、

```text
大規模なFSM再設計
数学アルゴリズム変更
別方式への最適化
```

は行わない。

V1とV2の差が「modular add時間共有」を中心として比較できる範囲に留める。

---

## 13. 参照資料

作業前に最低限次を確認する。

```text
SPEC_abc471e_baseline.md

reference/abc471e_baseline_v1/
    IMPLEMENTATION_REPORT_abc471e_baseline.md
    ffpga/src/main.v
    ffpga/build/post_synth_report.txt
    ffpga/build/post_synth_results.v
    sim/abc471e_baseline_tb.v
```

現在の`ffpga/build/`はv1からコピーされた旧成果物である。

V2 RTL変更後の合成結果ではないため、V2の評価結果として扱わないこと。

`reference/`以下は参照専用である。

---

## 14. テスト要求

V1のIcarus Verilogテスト111項目をすべて維持する。

期待結果:

```text
SUMMARY TOTAL=111 PASS=111 FAIL=0
```

最低限次を再確認する。

```text
手計算例
3状態途中値

N=1,K=1
K=1
K=N

mod境界
payload中0xFF

ランダム小ケース100件
独立な全組み合わせ列挙との比較

RESET / START
STATUS + 4-byte回答

不正N/K
ERROR sticky
busy衝突
余分なpayload
STATUSポーリング境界
```

V2のレイテンシ変更に合わせてtestbenchを修正してよい。

ただし、

```text
テスト項目を削除しない
timeoutを不当に緩めてFAILを隠さない
期待値計算をRTLと同じ方式へ変更しない
```

こと。

---

## 15. 性能測定

Icarusテストでは次を再測定する。

```text
PERF MUL_CLOCKS
PERF AI_MIN_CLOCKS
PERF AI_MAX_CLOCKS
```

期待:

```text
MUL_CLOCKS = 60
```

`AI_MIN/MAX_CLOCKS`はV1より増えてよい。

4MHz SPI / 50MHz FPGAの約400クロック/Ai以内かを報告する。

---

## 16. MicroPython側

```text
firmware/micropython/abc471e_baseline_test.py
```

の外部仕様と期待値計算はV1と同じとする。

V2は内部回路だけの変更なので、原則変更しない。

bitstreamファイル名など、V2運用上必要な最小限の変更だけは行ってよい。

---

## 17. 作成する設計資料

実装前に、

```text
IMPL_abc471e_baseline_v2.md
```

を作成する。

内容は本要求書をそのまま繰り返すのではなく、実際のV1 RTLとPost-Synthesis結果を確認したうえで、V2の具体的な設計を記述する。

最低限次を含める。

```text
V1の面積増加原因の確認

共有modular addの具体的構成

operand選択方法
result destination選択方法

FSMの変更点

追加・削除する主要レジスタ

1 Aiあたりの想定クロック

V1から変更しない部分

意図的に行わない最適化
```

IMPL作成後、その内容に従って実装する。

---

## 18. 実装レポート

実装・Icarus検証完了後、

```text
IMPLEMENTATION_REPORT_abc471e_baseline_v2.md
```

をV2の実結果で更新する。

最低限次を記録する。

```text
変更ファイル一覧

V1からの変更点

共有modular addの構成

FSM変更内容

3状態方式を維持したこと

共有modular multiplierを変更していないこと

Icarusテスト結果

PERF MUL_CLOCKS
PERF AI_MIN_CLOCKS
PERF AI_MAX_CLOCKS

spi_target.v未変更

reference/以下未変更

ForgeFPGA Workshop合成未実施

実機試験未実施
```

---

## 19. Codex側の停止条件

Codex側では次まで行う。

```text
V1解析

IMPL_abc471e_baseline_v2.md作成

V2 RTL実装

必要なtestbench修正

Icarus全111項目PASS確認

性能再測定

IMPLEMENTATION_REPORT_abc471e_baseline_v2.md更新
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

ForgeFPGA Workshopによるリソース評価はユーザーが行う。

---

## 20. V2の評価目的

V2の評価では、V1との比較により次を確認する。

```text
modular addを時間共有すると、
同じ数学・同じ外部仕様のまま
どこまでLC / FF / CARRY資源を削減できるか
```

V2がShrike-Liteへ収まること自体はCodex側の完了条件ではない。

V2でも収まらなかった場合、その結果を次の設計判断材料とする。

その場合もV2実装中に、

```text
pair_sum削除
数式変形
MOD縮小
bit幅縮小
```

へ進まないこと。
