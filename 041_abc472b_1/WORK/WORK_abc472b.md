# WORK_abc472b.md

## 目的

AtCoder Beginner Contest 472 B「Break a Stick」を Shrike-Lite へ実装する。

問題:
https://atcoder.jp/contests/abc472/tasks/abc472_b

作業フォルダ:

```text
D:\my_ws\_scratch\abc472b
```

このフォルダ内だけで作業すること。

---

## 問題概要

棒は `N` 個の部分に分かれており、各部分の長さは

```text
L_1, L_2, ..., L_N
```

である。

`N-1` 箇所の切れ込みのどこか1箇所で折ったとき、
左右2本の棒の長さの差の絶対値の最小値を求める。

制約:

```text
2 <= N <= 100
1 <= L_i <= 100000
```

最大合計長:

```text
100 * 100000 = 10000000
```

---

# 実装方針

## FPGA側で保持する情報

各 `L_i` は最大100000なので17bitで保持できる。

```text
L_i : 17bit
100個 : 1700bit
```

全長は最大10000000なので24bitで保持できる。

```text
total_sum : 24bit
```

FPGA側では入力中に、

```text
lengths[index] = L_i
total_sum += L_i
```

として全長と各部分長を保持する。

文字列全体など、問題に不要なデータは保持しない。

---

## 入力終了後に逐次処理

全長は最後の `L_i` を受信するまで確定しない。

そのため、入力受信中に最終回答を決定しようとせず、
全入力受信後に切れ目を順番に評価する。

概念:

```text
prefix = 0
best = INF

for i = 0 .. N-2:
    prefix += lengths[i]

    left  = prefix
    right = total_sum - prefix

    diff = abs(left - right)
    best = min(best, diff)
```

FPGAでは切れ目を順番に評価する逐次FSMとする。

DistRAMのread latencyは `REF/abc468b` の実装に合わせる。
1候補 / clockに無理に固定せず、自然なread / evaluateパイプラインにする。

候補数そのものは最大99個なので、必要クロック数は
DistRAMのread latencyを含めて実装後にREPORTへ記録する。

99個の比較器を並列配置するような実装は行わない。

---

## ビット幅

原則として以下を使用する。

```text
N / index  : 7bit程度
L_i        : 17bit
total_sum  : 24bit
prefix     : 24bit
left/right : 24bit
diff       : 24bit
best       : 24bit
answer     : 24bit
```

`abs(2*prefix-total)` のように不要に中間ビット幅を増やす必要はない。

```text
left >= right ? left-right : right-left
```

の比較＋減算でよい。

---

# メモリ

`L_i` 100個は **DistRAMへ格納する方針** とする。

必要容量は、

```text
100 × 17bit = 1700bit
```

である。

`REF/abc468b` にある既存のDistRAM実装を最初に確認し、
ForgeFPGA / YosysでDistRAMとして推論される記述方法、read / writeタイミング、
アドレスの扱いを参考にすること。

ABC472Bでは、ABC468Bとデータ幅・深さが異なるため、
REFのコードを機械的にコピーするのではなく、DistRAM利用の記述パターンを参考にして
`100 × 17bit` 相当の格納領域を実装する。

不必要に1700bitをFF配列へ展開しない。

Phase 1ではSynth / PNRはまだ行わないため、
Icarusで機能を確認する。
Phase 2のSynth / PNRで、実際にDistRAMへ推論されたかを必ず確認する。

---

# SPI

既存の Shrike-Lite SPIテンプレートV3を使用する。

条件:

```text
SPI clock : 4 MHz
CPOL      : 0
CPHA      : 0
8bit / MSB first
MISO応答  : 1byte遅延
```

`spi_target.v` は変更禁止。

REFにある実際のV3版をそのまま使用する。

---

# REF

作業開始時に、作業フォルダの `REF` を最初に確認すること。

想定:

```text
REF/
├─ abc468b/
├─ abc472a/
└─ template_spi_v3/
```

各REFは開発時にはフォルダごと置いてよい。
必要ファイルの選別はここでは行わず、Codexが読み取り専用で必要箇所を参照する。
公開前に別WORKで整理する。

参照目的:

```text
REF/abc468b/
    DistRAMのRTL記述、read / writeタイミング、メモリ推論の参考

REF/abc472a/
    最新のSPI V3利用方法、MicroPythonの再利用memoryview、
    try/finallyによるCS復帰、Icarus統合テスト、REPORT形式の参考

REF/template_spi_v3/
    SPI V3回路・制約の正本
```

SPI V3の実体は `REF/template_spi_v3` を優先する。
DistRAM実装は `REF/abc468b` を優先して確認する。

REFは読み取り専用。
変更しない。

Web検索からSPIテンプレートを再構築しない。
実物REFがある場合は必ずREFを使用する。

---

# SPI入力フォーマット

RP2040からFPGAへ送る論理入力は、

```text
byte 0       : N
byte 1..3    : L_1
byte 4..6    : L_2
...
```

とする。

各 `L_i` は24bit big-endianで送る。

例:

```text
L_i = 100000 = 0x0186A0

01 86 A0
```

内部では17bitへ格納する。

24bit転送にする理由は、
17bit独自パッキングを導入せず、通信仕様とRTLを単純にするためである。

最大論理入力長:

```text
1 + 100*3 = 301 bytes
```

---

## 複数SPIバースト

SPI V3の実際の1バースト上限はREFで確認すること。

最大301byteが1バースト上限を超える場合、
RP2040側で複数バーストへ分割する。

重要:

**CSがHighになっても、ABC472Bの入力受信状態はリセットしない。**

FPGA側は、

```text
N受信
↓
L_iを3byteずつ受信
↓
必要ならCS Highをまたいで続行
↓
N個受信完了
```

という1つの論理入力として扱う。

バースト境界は通信都合であり、問題入力の境界ではない。

REFで上限が256byteなら、

```text
N=85 : 1 + 85*3 = 256byte
N=86 : 259byte
```

となるため、N=85 / 86は境界テストに含める。

---

# 計算開始

`N` 個すべての `L_i` を受信したら、

```text
RECEIVE
  ↓
CALC
```

へ遷移する。

CALCでは最大 `N-1` 候補を1つずつ処理する。

DistRAMのread latencyを含むため、
最大ケースの正確な内部クロック数は実装後に測定・確認してREPORTへ記録する。

候補数は最大99個なので、数clock / 候補であっても十分小さい。

---

# 回答取得

回答は24bitなので3byteで返す。

入力受信と計算完了後、
RP2040は別のSPI read burstで回答を回収する。

基本形:

```text
MOSI: dummy dummy dummy dummy
MISO: dummy ans[23:16] ans[15:8] ans[7:0]
```

SPIの1byte遅延を利用する。

FPGA側は結果read burstの受信byteごとに、

```text
1byte目受信後 -> answer MSBを次返信へ
2byte目受信後 -> answer MIDを次返信へ
3byte目受信後 -> answer LSBを次返信へ
```

とする。

回答の3byte送信完了後、次の問題入力を受けられる初期状態へ戻る。

---

## 計算完了待ち

最大計算時間は短い見込みだが、DistRAMのread latencyを含む正確な値は実装後に確定する。

RP2040側では、入力送信完了後に短い明示的な待ち時間を入れてから回答read burstを行う。

初期値として、

```text
time.sleep_us(10)
```

程度を使用してよい。

ただし、

- 50MHz内部クロック
- 最大99候補
- DistRAM read latency
- SPI同期遅延

に対して十分な余裕があることをREPORTへ記載する。

不要に長いms単位の待ちは入れない。

もしREFの既存プロトコルに、
より自然で簡単な完了確認方法がある場合は、
RTLを複雑化しない範囲でそちらを採用してよい。

その場合は、実装前に理由を短く記録すること。

---

# RP2040側

RP2040側は以下のみ担当する。

- `N` と `L_i` の入力
- `L_i` を24bit big-endianへシリアライズ
- V3上限に合わせてSPI burstを分割
- 必要な短い計算完了待ち
- 24bit回答の受信
- 標準出力相当の表示
- テスト制御

RP2040側で以下を行ってはいけない。

- 累積和を作ってFPGAへ渡す
- 切れ目ごとの差を計算
- 最小値を計算
- `L_i` を並べ替える
- FPGAの代わりにABC472Bを解く

期待値計算はテストオラクル内だけでよい。

---

# MicroPython

ABC472Aの実装を参考に、

- 再利用 `bytearray`
- 再利用 `memoryview`
- `try/finally` でCSを必ずHighへ戻す

を維持する。

最大入力301byteを扱える送信バッファを用意する。

V3の1バースト上限に合わせ、
`memoryview` sliceで複数burstへ分割する。

無駄なバッファ再生成を避ける。

---

# 主な実装対象

最低限:

```text
ffpga/src/main.v
ffpga/src/spi_target.v
firmware/micropython/abc472b_test.py
sim/tb_abc472b.v
sim/run_iverilog.ps1
REPORT_WORK_abc472b.md
```

`spi_target.v` はREFのV3版と同内容で配置し、編集しない。

必要なら小さな補助ファイルを追加してよい。

---

# 禁止事項

- `spi_target.v` の変更
- SPI V3仕様の変更
- RP2040側でABC472Bを解く
- 99候補の完全並列比較
- 不要な17bit独自SPIパッキング
- 入力順序の変更
- 作業フォルダ外の変更
- REFの変更
- Web情報だけからV3を再構築
- Synth / PNR / bitstream生成
- Shrike-Lite実機書き込み
- 実機テスト
- AtCoder提出

Phase 1ではRTL / Icarus / MicroPythonテストコード / REPORTまで。

---

# テスト

## 公式サンプル

公式3例を確認する。

```text
4
5 2 3 8
=> 2
```

```text
7
31 41 59 26 53 58 97
=> 51
```

```text
10
67011 35764 33042 24098 63738 98760 17199 68579 21812 45408
=> 28105
```

---

## 境界

最低限:

- N=2
- N=100
- L_i=1
- L_i=100000
- 答え=0になるケース
- 最適切れ目が先頭
- 最適切れ目が末尾
- 複数の切れ目で同じ最小値
- 合計長最大10000000
- 24bit回答
- 連続トランザクション

---

## SPIバースト境界

REFのV3上限に応じて、
1バーストに収まる最大点と、
そこを1つ超えるケースを必ず確認する。

上限256byteなら:

```text
N=85  -> 256byte
N=86  -> 259byte
N=100 -> 301byte
```

を確認する。

複数CS区間に分かれても入力状態が壊れないこと。

---

## ランダム

Python等で期待値を計算し、
決定的seedのランダムケースを十分数生成する。

少なくとも数百ケース程度をIcarusで確認する。

期待値生成はテスト専用とし、
productionのMicroPython処理へ流用しない。

---

## 内部処理

Icarusで可能なら以下も確認する。

- N個受信前にCALCへ入らない
- N個受信後にCALC開始
- 候補数はN-1
- 先頭/末尾以外を切れ目として扱わない
- total_sum / prefix / diffでoverflowしない
- answer readの1byte遅延
- answer 3byteのbyte order
- answer読出し後に次入力へ戻る
- 複数問題を連続実行して前回状態が混入しない

---

# REPORT

このWORKの実行結果は、独立した

```text
REPORT_WORK_abc472b.md
```

へ記録する。

他のWORKのREPORTへ追記しない。

停止条件や作業中断条件に該当した場合も、
REPORT作成と最終報告は必ず実施する。
その場合は、停止時点までに確認できた事実、停止理由、
生成済み成果物、変更ファイル、未実施項目を記録し、
未確認の結果を推測で補わない。

簡潔に以下を記録する。

- 実装ファイル
- 内部ビット幅
- `L_i` のDistRAM保持方法
- DistRAM read / writeタイミング
- SPI入力フォーマット
- 複数burstの扱い
- CALC FSM
- 最大論理クロック
- 回答取得シーケンス
- テスト内容
- テスト結果
- 既知の制約
- 未実施項目

特に、

```text
入力受信後、最大N-1候補を逐次処理
```

であることを明記する。

---

# 完了条件

- REFを最初に確認済み
- V3 `spi_target.v` を変更していない
- `L_i` を17bitでDistRAM内部保持
- total/prefix/diff/answerが安全な幅
- 最大100個を保持できる
- 入力301byteをV3上限に応じて正しく分割
- CS境界をまたいでも入力状態を維持
- 全入力後に逐次CALC
- 最大99候補
- 24bit回答を正しく返す
- 公式3例PASS
- 境界ケースPASS
- バースト境界PASS
- ランダム数百ケースPASS
- 連続トランザクションPASS
- MicroPython構文確認PASS
- `REPORT_WORK_abc472b.md` 作成済み
- Synth / PNR / bitstream / 実機は未実施

---

# 完了報告

完了後、簡潔に以下を報告する。

- 変更ファイル
- 採用したSPIフレーミング
- V3の実際の1バースト上限
- `L_i` のDistRAM保持方法
- CALCの論理クロック数（DistRAM read latency込み）
- Icarusテスト件数 / PASS結果
- MicroPython構文確認
- 未実施項目

Synth / PNRへ進む前に一度停止すること。
