# WORK3_abc472a.md

## 目的

ABC472A の Shrike-Lite 実機テストはすでに全17ケース PASS している。

次に、記事へ掲載するための **AtCoder最大ケース相当の処理時間測定** を
`firmware/micropython/abc472a_test.py` に追加する。

作業フォルダ:

```text
<WORKDIR>
```

---

## 現在の状態

実機テスト結果:

```text
SUMMARY PASS=17 FAIL=0 TOTAL=17 RESULT=PASS
```

以下は確認済み。

- 公式サンプル3件
- 長さ1
- 長さ100
- A-Z全26文字
- 全A
- Aなし
- A複数
- 先頭A
- 末尾A
- 決定的ランダムケース
- SPI先頭dummy
- 1byte応答遅延
- flush
- 連続トランザクション

RTL / Synth / PNR / bitstream生成も完了済み。

---

## 今回の変更対象

原則として、変更するのは以下だけ。

```text
firmware/micropython/abc472a_test.py
REPORT_abc472a.md
```

必要ならMicroPythonファイル内に小さな計測補助関数を追加してよい。

---

## 変更禁止

以下は変更しない。

```text
ffpga/src/main.v
ffpga/src/spi_target.v
abc472a.ffpga
ffpga/build/
REF/
sim/
```

SPI仕様、RTL仕様、bitstreamも変更しない。

---

## 時間測定の目的

AtCoder制約上の最大入力長は100文字。

最大長100文字の入力について、Shrike-Lite実機での1回の問題処理時間を測定する。

測定対象は、

```text
fpga_convert(spi_bus, cs_pin, source)
```

の呼び出し時間とする。

これにより以下を含む。

- RP2040側の入力文字チェック
- ASCII byte列への格納
- SPI 1バースト転送
- dummy / flushを含む応答回収
- 結果byte列の文字列化

以下は含めない。

- FPGA bitstream書き込み
- FPGA reset
- SPI初期化
- テストケース生成
- 期待値生成
- print出力時間

記事では、この測定範囲を明記できるようにする。

---

## MicroPythonでの計測方法

MicroPython標準の、

```python
time.ticks_us()
time.ticks_diff()
```

を使用する。

通常の `time.time()` などは使用しない。

概念:

```python
start = time.ticks_us()
result, dummy_ok = fpga_convert(spi_bus, cs_pin, source)
elapsed_us = time.ticks_diff(time.ticks_us(), start)
```

---

## ベンチマーク条件

正しさテスト17ケースをすべて実行し、全PASSした後にベンチマークを行う。

### 入力

長さ100の英大文字列を使用する。

既存の `length_100_mixed` と同等の、Aを含む混合文字列でよい。

変換内容によって回路処理時間は変わらないため、特別な最悪文字配置を作る必要はない。

### 回数

```text
20回
```

測定する。

その前に1回だけウォームアップ転送を行い、その時間は統計へ含めない。

FPGA reset / flash / SPI再初期化は各runごとに行わない。

同じSPIセッションのまま連続測定する。

---

## 出力

ベンチマーク完了後、少なくとも以下を1行で表示する。

```text
BENCHMARK LEN=100 RUNS=20 MIN_US=... AVG_US=... MAX_US=... RESULT=PASS
```

`AVG_US` は整数でよい。

20回すべてについて、

- dummyが正常
- FPGA結果が期待値と一致

していることを確認する。

1回でも不一致があれば、

```text
RESULT=FAIL
```

とし、全体テストもFAIL扱いにする。

---

## 既存テスト表示

既存の17ケースの表示形式は、可能な限り維持する。

現在の、

```text
NAME=... LEN=... DUMMY_OK=... RX=... EXPECT=... PASS
```

および、

```text
SUMMARY PASS=17 FAIL=0 TOTAL=17 RESULT=PASS
```

を壊さない。

必要なら `SUMMARY` の後に `BENCHMARK` を追加する。

---

## REPORT更新

`REPORT_abc472a.md` に短い実機テスト節を追加する。

記載する内容:

- 実機17ケース PASS
- bitstream書き込み成功
- 最大長100文字を20回測定
- 測定範囲は `fpga_convert()` 呼び出しのみ
- flash / reset / SPI初期化 / print は計測外
- 実測 MIN / AVG / MAX us
- ベンチマーク中も全結果一致

実測値は実際の実機出力が得られるまで推測して書かない。

Codex自身が実機を実行できない場合は、REPORTに測定欄だけ準備し、数値は未記入または「実機測定待ち」とする。

---

## 検証

変更後に最低限以下を実施する。

```text
python -m py_compile firmware/micropython/abc472a_test.py
```

可能なら既存のIcarusテストも再実行してよいが、RTLは変更しないため必須ではない。

MicroPython実機テストは人間側で行う。

---

## 完了条件

- `abc472a_test.py` に最大長100文字の時間測定が追加されている
- `time.ticks_us()` / `time.ticks_diff()` を使用している
- 20回測定＋1回ウォームアップ
- MIN / AVG / MAX を出力する
- ベンチマークでも正しさを確認する
- 既存17ケースのテストを壊していない
- RTL / .ffpga / build / REF を変更していない
- `REPORT_abc472a.md` に実機測定用の記録欄を追加
- Python構文確認PASS

---

## 完了報告

以下を簡潔に報告する。

- 変更ファイル
- 追加した測定方式
- 測定範囲
- ベンチマーク条件
- 構文確認結果
- 実機で人間が次に実行すべきコマンド / 手順
