# WORK5_abc472b.md

## 目的

37.5 MHzでTiming PASSしたABC472B bitstreamをShrike-Lite実機へ書き込み、
MicroPythonテストを実行したところ、19ケース中3ケースがFAILした。

今回のWORK5では、すぐにRTLを修正するのではなく、

**実機FAILがどこで発生しているかを切り分ける**

ことを目的とする。

作業フォルダ:

```text
<workspace>
```

---

# 1. 既知の実機結果

37.5 MHz FPGA / SPI 4 MHzでの初回実機結果:

```text
SUMMARY PASS=16 FAIL=3 TOTAL=19 RESULT=FAIL
```

FAILしたケース:

```text
NAME=best_at_first_cut
N=3
BYTES=10
BURSTS=1
RESULT=7573991
EXPECT=98
FAIL

NAME=burst_boundary_259
N=86
BYTES=259
BURSTS=2
RESULT=1737
EXPECT=1001
FAIL

NAME=deterministic_random_100
N=100
BYTES=301
BURSTS=2
RESULT=76912
EXPECT=11636
FAIL
```

一方で、

```text
official samples
N=2
N=100 all one
maximum_total
burst_boundary_256
deterministic_random_86
```

など多数のケースはPASSしている。

---

# 2. 既知の静的確認事項

現在のproduction RTLでは、

```verilog
wire [23:0] current_length = {7'd0, lengths_read_data};
wire [23:0] prefix_after_read = prefix_sum + current_length;
wire [23:0] right_after_read = total_sum - prefix_after_read;

wire [23:0] current_diff =
    (prefix_after_read >= right_after_read)
        ? (prefix_after_read - right_after_read)
        : (right_after_read - prefix_after_read);
```

となっている。

したがって、

**DistRAM格納値は17bitだが、CALCの加算・減算・絶対値計算は24bit**

である。

`best_at_first_cut = [100, 1, 1]`では値自体も非常に小さいため、
17bit減算overflow / mod 2^17を第一原因とは考えない。

またこのケースは、

```text
N=3
入力10byte
1 burst
```

なので、256byteの複数burst境界も関係しない。

---

# 3. 重要方針

WORK5ではまずproduction RTLを変更しない。

変更禁止:

```text
ffpga/src/main.v
ffpga/src/spi_target.v
abc472b.ffpga
ffpga/timing-constraints/
REF/
REPORT_WORK_abc472b.md
REPORT_WORK2_abc472b.md
REPORT_WORK3_abc472b.md
REPORT_WORK4_abc472b.md
```

37.5 MHz Timing PASS済みbitstreamも作り直さない。

今回変更してよいのは主に、

```text
firmware/micropython/
debug_work5/
REPORT_WORK5_abc472b.md
```

とする。

productionの`abc472b_test.py`は可能なら変更せず、
別のdebug用MicroPythonスクリプトを作成する。

---

# 4. 最初に確認するもの

開始時に以下を確認する。

```text
REPORT_WORK4_abc472b.md
ffpga/src/main.v
firmware/micropython/abc472b_test.py
現在実機で使用したabc472b.bin
```

実機で使用したbitstreamが、
WORK4で37.5 MHz Timing PASSした成果物であることを確認する。

不一致がある場合は、その時点で停止して報告する。

---

# 5. 最優先ケース

最初のデバッグ対象は、

```text
best_at_first_cut = [100, 1, 1]
expected = 98
```

とする。

理由:

- N=3
- 10byte
- 1 burst
- 値が小さい
- 期待値計算が単純
- 複数burst境界と無関係

このケースだけで再現できれば、
大規模入力やburst境界の要因を除外できる。

---

# 6. 試験A: 再現性確認

37.5 MHz FPGA / SPI 4 MHzのまま、
`best_at_first_cut`を繰り返し実行する。

最低20回。

可能なら次の2条件を分ける。

## A1

FPGAを最初に1回だけreset / flashし、
同じcaseを20回連続transactionする。

## A2

各caseの前にFPGA resetを行い、
20回実行する。

記録:

```text
RUN
RESULT
EXPECT
PASS / FAIL
```

確認したいこと:

- 毎回同じ誤答になるか
- 誤答値が変動するか
- reset有無で傾向が変わるか
- 前transactionの状態依存があるか

---

# 7. 試験B: SPI入力側 / 回答側の速度分離

今回の通信は、

```text
入力burst
↓
CALC待ち
↓
回答4byte burst
```

と分離されている。

そのため入力側SPI速度と回答側SPI速度を別々に変え、
どちら側で問題が起きているか切り分ける。

production設定:

```text
input  = 4 MHz
answer = 4 MHz
```

debugでは以下4条件を比較する。

```text
B1: input 4 MHz / answer 4 MHz
B2: input 2 MHz / answer 4 MHz
B3: input 4 MHz / answer 2 MHz
B4: input 2 MHz / answer 2 MHz
```

まず`best_at_first_cut`を各条件10回以上実行する。

MicroPython上でSPI baudrateを入力burstと回答burstの間に変更する方法は、
現在使用中のMicroPython `machine.SPI`で正規に可能な方法を使用する。

`SPI.init()`等が利用できる場合はそれを使う。
利用できない場合はSPI objectを安全に再生成してよい。

推測によるレジスタ直接操作は行わない。

---

# 8. raw MISO byteも記録する

回答を整数へ組み立てる前に、
4byte responseをrawで記録する。

期待:

```text
rx[0] = dummy 0x00
rx[1] = answer[23:16]
rx[2] = answer[15:8]
rx[3] = answer[7:0]
```

`best_at_first_cut`の期待値98なら、

```text
answer = 0x000062

expected raw:
00 00 00 62
```

である。

各試験で、

```text
RAW_RX=xx xx xx xx
RESULT=...
```

を記録する。

これにより、

- FPGA内部answer自体が壊れている
- answerは正しいがMISO送信が壊れている
- byte alignmentが崩れている

可能性の切り分け材料にする。

---

# 9. 試験C: 代表FAIL / PASSケースへ展開

試験Bで傾向が確認できたら、
以下へ同じ条件を適用する。

FAIL代表:

```text
best_at_first_cut
burst_boundary_259
deterministic_random_100
```

PASS代表:

```text
official_sample_1
best_at_last_cut
burst_boundary_256
n100_all_one
deterministic_random_86
```

必要以上に全19ケースを何十回も実行しなくてよい。

---

# 10. 判定の目安

## B2だけ改善する場合

```text
input 2 MHz / answer 4 MHz
```

で改善し、

```text
input 4 MHz / answer 2 MHz
```

で改善しない場合、

**MOSI受信 / SCK同期 / rx_data_strobe側のタイミング**

を強く疑う。

## B3だけ改善する場合

```text
input 4 MHz / answer 2 MHz
```

で改善する場合、

**MISO返信 / tx_data取り込み / 1byte遅延返信側**

を強く疑う。

## B4でのみ改善する場合

SPI V3全体と37.5 MHz内部clock間の
CDC margin不足を強く疑う。

## 2 MHzでもFAILする場合

単純なSPI速度依存だけでは説明できない。

その場合は、

- DistRAM write/read
- CALC FSM
- 実機上の内部値
- transaction state

の観測が必要になる可能性がある。

ただしWORK5では、
**勝手にproduction RTLへdebug回路を追加しない。**

この場合は一度停止し、
次WORKでdebug RTL / telemetry方法を決める。

---

# 11. 追加の静的確認

実機試験と並行して、
production RTLを読み直し、少なくとも以下を確認する。

- `received_length`の3byte組立
- 24bit -> 17bit格納時の切り出し
- `total_sum`
- final L_i writeとCALC開始の順序
- 同期DistRAM readの1clock latency
- `prefix_after_read`
- `right_after_read`
- `current_diff`
- `best_after_evaluate`
- 最終answer latch
- ANSWER_READYのbyte sequence
- 次transactionへのreset/re-arm

Icarusでは524ケースPASSしているため、
シミュレーションでのみ成立する前提や、
実機primitive / CDCで差が出る箇所を重点的に見る。

---

# 12. Icarusについて

production RTLは変更しないので、
既存524ケースを無条件に再実行する必要はない。

ただし静的確認中に疑わしい箇所を見つけた場合は、
対象を狙った追加testbenchを`debug_work5/`へ作ってよい。

既存simを壊さない。

---

# 13. Thonny自動操作も試す

今回のWORK5では、可能ならMicroPython debugスクリプトを作るだけでなく、

**CodexからThonnyを自動操作し、Shrike-Lite実機試験そのものも自動実行する。**

目的は今回のABC472Bだけでなく、
今後のShrike-Lite実機debugで再利用できる操作経路を確認することにある。

最低限、自動化を試す対象:

```text
Thonny起動 / 既存起動状態の検出
MicroPython interpreter / 接続状態の確認
debugスクリプトを開く
必要ならdebug条件・test caseを変更
保存
Run
Shell出力の取得
次条件へ変更
再Run
結果ログ保存
```

特に、

```text
A1 / A2
B1 / B2 / B3 / B4
代表FAIL / PASS case
繰り返し回数
```

を、人間が毎回GUI操作しなくても切り替えて連続実行できる形を目標とする。

## 推奨するdebugスクリプト構造

Thonny上で毎回ソースコード本文を書き換えなくてもよいように、
`abc472b_debug_work5.py`は可能なら先頭付近の設定だけで動作を切り替えられるようにする。

例:

```python
MODE = "B2"
CASE_NAME = "best_at_first_cut"
RUNS = 20
RESET_EACH_RUN = False
```

または同等の小さな設定構造とする。

CodexがThonny上でこの設定部分だけを変更し、

```text
保存
Run
Shell結果回収
次設定
```

を繰り返せるようにする。

さらに良い方法として、
1回の起動でA1/A2/B1～B4を自動走査できるdebug runnerを作れる場合は、
そちらを優先してよい。

ただし、

**debug runner内でFPGAのABC472B計算をsoftware代行してはいけない。**

期待値計算はtest oracleとしてのみ許可する。

## Thonny UI automationの方針

ForgeFPGA Workshopと同様に、
まずOS/UI Automation等で正規GUI要素を機械的に操作できるか確認する。

可能なら、

- Editor
- Run
- Stop/Restart backend
- Shell
- 保存
- ファイル選択

など必要な要素を自動操作する。

座標クリックへ進む場合も人間操作へ切り替えず、
Codexによる自動操作の範囲で行う。

ただしUI状態が不安定で誤操作の危険がある場合は停止する。

## Shell出力

各runのShell出力を可能な範囲で機械的に回収し、

```text
debug_work5/logs/
```

等へ保存する。

最低限、

```text
case
mode
input SPI MHz
answer SPI MHz
reset condition
run number
RAW_RX
RESULT
EXPECT
PASS/FAIL
```

が後から追えるようにする。

Thonny Shellから直接安定取得できない場合は、
debugスクリプト自身が識別しやすい1行形式でprintし、
CodexがShell表示を取得しやすくする。

## 成功判定

Thonny自動化成功とは最低限、

1. CodexがdebugスクリプトをThonnyで実行
2. Shell結果を取得
3. test条件を変更
4. 再実行
5. 次のShell結果を取得

を人間操作なしで連続して行えたこととする。

可能ならA1/A2/B1～B4まで連続実行する。

## 自動化できなかった場合

Thonny自動操作ができない場合でも、
production RTLは変更しない。

次をREPORTへ残す。

- どこまで自動操作できたか
- 失敗したGUI操作
- UI Automationで見えた要素
- 座標操作を試したか
- 自動化不能の理由
- 人間が実行できるdebugスクリプト

Thonny自動化失敗そのものは、
ABC472Bデバッグの原因とは扱わない。

---

# 14. 実機実行できない場合

Codex環境からShrike-Lite実機テストを直接実行できない場合は、

```text
firmware/micropython/abc472b_debug_work5.py
```

などのdebug専用スクリプトを作成する。

そのスクリプトで、

- A1 / A2
- B1～B4
- raw MISO byte
- 代表case

を一括または選択実行できるようにする。

人間がThonnyから実行できる状態にして停止する。

この場合も`REPORT_WORK5_abc472b.md`を作成し、

```text
実機実行待ち
```

であることを明記する。

---

# 15. REPORT_WORK5_abc472b.md

このWORKの結果は必ず、

```text
REPORT_WORK5_abc472b.md
```

へ記録する。

他のWORKのREPORTへ追記しない。

必須内容:

- WORK5の目的
- 初回実機FAIL 3件
- `best_at_first_cut`を最優先にした理由
- 17bit overflow説を除外した静的根拠
- A1 / A2結果
- B1～B4結果
- raw MISO byte
- 代表FAIL / PASSケース結果
- 静的RTL確認結果
- 現時点で最も疑わしい箇所
- まだ断定できない事項
- 作成したdebugファイル
- Thonny自動操作の可否と実行範囲
- Thonnyから回収したログ
- production変更有無
- 次に必要な作業
- 未実施項目

---

# 16. 停止条件

以下では停止する。

- 使用bitstreamがWORK4成果物と一致しない
- 実機アクセス不能
- Thonny自動操作が不安定で誤操作の危険がある（この場合は自動操作だけ停止し、debug script準備へ切り替える）
- SPI速度を安全に分離設定できない
- 2 MHzでもFAILし、内部観測が必要
- production RTL変更が必要になった
- debug telemetry回路が必要になった
- 原因候補が複数残り、追加仕様判断が必要

停止しても、

**REPORT作成と最終報告は必ず行う。**

未確認値を推測で埋めない。

---

# 17. 今回行わないこと

- production RTL修正
- SPI V3 RTL修正
- PLL変更
- SDC変更
- 新しいproduction bitstream生成
- pipeline化
- AtCoder提出
- Git操作

---

# 完了条件

以下のいずれかで完了。

## 原因領域を切り分けられた場合

- A1 / A2実施
- B1～B4実施
- raw MISO取得
- 代表case確認
- 原因領域を入力SPI / 出力SPI / 全体CDC / CALC側のいずれかへ十分絞り込み
- `REPORT_WORK5_abc472b.md`作成

## 実機実行待ちの場合

- debug MicroPythonスクリプト作成
- production未変更
- `REPORT_WORK5_abc472b.md`作成
- 人間が実行すべき手順を明記

## 内部debug RTLが必要と判明した場合

- production未変更
- なぜ内部観測が必要か整理
- `REPORT_WORK5_abc472b.md`作成
- 次WORKへ引き継ぐ観測候補を列挙

---

# 完了報告

簡潔に以下を報告する。

- reproductionの有無
- A1 / A2結果
- B1～B4結果
- raw MISOの特徴
- どの領域が最も疑わしいか
- production変更有無
- 作成ファイル
- `REPORT_WORK5_abc472b.md`
- 次に必要な作業
