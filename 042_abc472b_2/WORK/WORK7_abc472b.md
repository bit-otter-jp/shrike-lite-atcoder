# WORK7_abc472b.md

## 目的

WORK6でABC472Bの原因特定・production修正・実機112/112 PASSまで完了した。

WORK7では実装変更を行わず、

1. 最終productionの実機標準出力をhardware logとして保存する
2. Shrike-Liteとしての最大ケース処理時間を測定する
3. 読者が最終結果を後追いできる証跡を揃える

ことを目的とする。

作業フォルダ:

```text
<workspace>
```

---

# 1. 基準となる最終production

WORK6で確定した最終productionを使用する。

主な基準:

```text
internal clock : 37.5 MHz
SPI            : 4 MHz
CALC           : 3 * (N - 1)
max CALC       : 297 clocks = 7.92 us
hardware test  : 112 / 112 PASS
```

最終production MCU bitstream SHA-256:

```text
4BCBCBC4DBF0B3C678BE398A31710464C509A81A581DBE98D08282A5758F49A4
```

開始時に最低限、

```text
ffpga/build/bitstream/FPGA_bitstream_MCU.bin
bitstream/abc472b.bin
E:\abc472b.bin
```

のhash一致を確認する。

一致しない場合は停止してREPORTする。

---

# 2. production変更禁止

WORK7では機能変更を行わない。

変更しないもの:

```text
ffpga/src/main.v
ffpga/src/spi_target.v
abc472b.ffpga
ffpga/timing-constraints/
firmware/micropython/abc472b_test.py
REF/
bitstream/abc472b.bin
```

WORK6で確定したproductionをそのまま測定対象とする。

必要ならbenchmark専用MicroPythonスクリプトを新規作成してよい。

---

# 3. hardware_logsフォルダと実機Run保存ルール

作業フォルダ直下に、

```text
hardware_logs/
```

を作成する。

WORK7では、**実機をRunしたらPASS / FAILに関係なく、その標準出力を必ず保存する。**

実機Runごとに、

```text
WORK7_SEQ01.log
WORK7_SEQ02.log
WORK7_SEQ03.log
...
```

のように、WORK番号 + 連番SEQで保存する。

ルール:

- 実機で実際に1回Runしたら1つSEQを消費する
- PASSでもFAILでも保存する
- retryした場合も別SEQにする
- 同じファイルへ上書きしない
- Thonny Shellの実出力を要約せず保存する
- 自動化途中の誤Runが発生した場合も、実機が実際に動いたならログとして残す
- 実機を動かしていないGUI操作失敗等はhardware logのSEQを消費しなくてよい

各ログの先頭には、可能なら明確なコメントとして次を付けてよい。

```text
# RUN=WORK7_SEQ01
# PURPOSE=final regression
# BITSTREAM_SHA256=...
# SCRIPT=...
# DATE=...
```

ただし、その後に続く実際の標準出力を改変しない。

REPORT側では、各実機Runについて必ず対応するSEQを記載する。

例:

```text
実機Run : WORK7_SEQ01
目的    : 最終production 112件回帰試験
結果    : PASS=112 FAIL=0
Log     : hardware_logs/WORK7_SEQ01.log
```

つまりWORK7では、

```text
REPORT
  = 結果の解釈・要約

hardware_logs/WORK7_SEQxx.log
  = 実機一次観測

WORK7_SEQxx
  = 両者を結ぶキー
```

として扱う。


最低限、最終実機試験の標準出力はSEQ付き生ログとして保存し、
その最終採用Runと同じ内容を、

```text
hardware_logs/hardware_log_abc472b_final.log
```

としても保存する。

例:

```text
hardware_logs/WORK7_SEQ01.log
hardware_logs/hardware_log_abc472b_final.log
```

後者は記事・公開資料から参照しやすい固定名、
前者は実機Run履歴を一意に追うための一次ログとする。

これは要約ではなく、

**Thonny Shellに出た最終production実機試験の標準出力を、そのまま追跡可能な形で保存する。**

可能なら冒頭に機械生成コメントとして、

```text
# ABC472B final hardware test
# bitstream_sha256=...
# date=...
```

等を追加してよい。

ただし実際のテスト出力を改変しない。

---

# 4. 最終実機試験

WORK5/WORK6で使用した112件runnerを再利用してよい。

最終productionで再度、

```text
PASS=112 FAIL=0 TOTAL=112
```

を確認する。

最優先case:

```text
best_at_first_cut = [100, 1, 1]
expected = 98
raw = 00:00:00:62
```

も確認する。

Thonnyの自動open / F5 / Shell回収はWORK5/WORK6で確立した方法を再利用する。

この最終runのShell出力を、

```text
hardware_logs/hardware_log_abc472b_final.log
```

へ保存する。

---

# 5. Shrike-Lite処理時間測定

記事掲載用に、

**最大ケース N=100 のShrike-Lite実処理時間**

を測定する。

測定回数:

```text
RUNS = 20
```

最低限、次を測定対象に含める。

```text
RP2040側の入力値チェック
N / L_i の301byteへのserialize
SPI入力転送
  最大ケースでは256byte + 45byte
CALC_WAIT_US = 10 us
4byte answer read burst
24bit answer組立
```

測定対象外:

```text
shrike.flash()
FPGA hardware reset
SPI object初期化
テストケース生成
print出力
```

productionの`fpga_solve()`相当の1回処理を測定する。

MicroPythonの利用可能な高分解能tick APIを用いる。

---

# 6. benchmark入力

最大ケースとして、N=100で制約内の固定入力を使用する。

既存のproduction test caseのうち、

```text
maximum_total = [100000] * 100
```

を第一候補とする。

ただし処理量はN依存であり値そのものにはほぼ依存しないため、
既存のN=100固定caseを使用してもよい。

使用した入力をREPORTへ明記する。

期待値もtest oracleで確認し、
20回すべて正しいanswerであることを確認する。

---

# 7. benchmark出力形式

記事へそのまま転記しやすい形式で、

```text
BENCHMARK N=100 RUNS=20
MIN_US=...
AVG_US=...
MAX_US=...
RESULT=PASS
```

を出力する。

必要ならMEDIAN_USも追加してよい。

各runの値もhardware logへ残してよい。

benchmarkの標準出力も実機RunとしてSEQ付きで保存する。

例:

```text
hardware_logs/WORK7_SEQ02.log
```

さらに、その最終採用benchmark Runと同じ内容を、

```text
hardware_logs/hardware_log_abc472b_benchmark.log
```

として保存する。

最終実機試験logとbenchmark logを混ぜない。

もしbenchmarkの再実行が必要になった場合は、

```text
WORK7_SEQ03.log
WORK7_SEQ04.log
...
```

と新しいSEQへ進み、失敗した旧Runも削除しない。

---

# 8. benchmark専用スクリプト

productionの、

```text
firmware/micropython/abc472b_test.py
```

は変更しない。

必要なら、

```text
firmware/micropython/abc472b_benchmark.py
```

を新規作成する。

productionの転送処理を再利用・同等化する場合、
ABC472Bの計算そのものをRP2040側へ移さない。

software計算は期待値oracleのみ許可する。

---

# 9. Thonny自動化

WORK5/WORK6で確立した方法を再利用し、

```text
script open
F5
Shell出力回収
log保存
```

をCodexから自動実行する。

可能なら、

1. final 112件test
2. benchmark 20 runs

を人間操作なしで連続して実行する。

Thonny backendがCOM6を保持している状態を前提にし、
他プロセスから同時にCOM6をopenしない。

---

# 10. Eドライブ

今回bitstreamは変更しない。

開始時に、

```text
E:\abc472b.bin
```

が最終production hashと一致することを確認する。

一致していれば再コピー不要。

必要な場合のみ同一production bitstreamを再配置してよい。

format / partition操作や無関係ファイル削除は行わない。

---

# 11. REPORT

WORK7の結果は必ず独立して、

```text
REPORT_WORK7_abc472b.md
```

へ記録する。

他のREPORTへ追記しない。

最低限:

- 最終production hash確認
- WORK7で実施した全実機RunのSEQ一覧
- 各SEQの目的 / 結果 / log path
- hardware log保存先
- final 112件test結果
- 最優先case結果
- benchmark測定条件
- benchmark対象範囲
- N=100入力内容
- RUNS
- MIN / AVG / MAX
- 必要ならMEDIAN
- 全run answer正解確認
- Thonny自動実行結果
- production変更なしの確認
- 作成ファイル
- 未実施項目

を記録する。

---

# 12. 完了条件

以下を満たせば完了。

```text
最終production hash一致
実施した全実機RunをWORK7_SEQxx.logとして保存
REPORTに各RunのSEQ対応を記録
final hardware test 112/112 PASS
hardware_logs/hardware_log_abc472b_final.log 保存
N=100 benchmark 20回すべてPASS
MIN / AVG / MAX取得
hardware_logs/hardware_log_abc472b_benchmark.log 保存
REPORT_WORK7_abc472b.md 作成
production変更なし
```

---

# 13. 停止条件

以下では停止する。

- bitstream hash不一致
- final 112件testでFAIL
- benchmarkでanswer不一致
- Thonny / COM6 / Shrike-Lite接続が復旧不能
- production変更が必要になった

停止しても、

```text
REPORT_WORK7_abc472b.md
```

は必ず作成する。

未確認値を推測で埋めない。

---

# 14. 今回行わないこと

- RTL変更
- SPI V3変更
- PLL / SDC変更
- Synth / PNR
- production bitstream再生成
- AtCoder提出
- Git操作
- 他プロジェクト変更

---

# 15. 完了報告

最後は簡潔に、

- final hardware test結果
- WORK7実機Run SEQ一覧
- hardware logファイル
- benchmark条件
- MIN / AVG / MAX
- benchmark logファイル
- production hash
- production変更なし
- REPORT_WORK7_abc472b.md

を報告する。
