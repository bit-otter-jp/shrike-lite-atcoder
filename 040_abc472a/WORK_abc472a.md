# WORK_abc472a.md

## 目的

AtCoder Beginner Contest 472 A「A」を Shrike-Lite へ実装する。

問題:
https://atcoder.jp/contests/abc472/tasks/abc472_a

作業フォルダ:

```text
<WORKDIR>
```

このフォルダ内だけで作業すること。

---

## 問題概要

英大文字からなる文字列 `S` が与えられる。

各文字について、

```text
'A' なら 'A'
それ以外なら '.'
```

へ置き換えて出力する。

制約:

```text
1 <= |S| <= 100
S は英大文字 A-Z のみ
```

---

## 実装方針

Shrike-Lite の FPGA 側では、文字列全体を保存しない。

**1文字受信するごとに1文字変換するストリーム処理**とする。

FPGA側の変換規則:

```text
0x41 ('A') -> 0x41 ('A')
その他      -> 0x2E ('.')
```

基本回路は8bit比較と選択のみでよい。

概念的には、

```verilog
assign converted_byte =
    (input_byte == 8'h41) ? 8'h41 : 8'h2E;
```

相当の処理とする。

---

## SPI

既存の Shrike-Lite SPIテンプレートV3を使用する。

条件:

```text
SPI clock : 4 MHz
CPOL      : 0
CPHA      : 0
MISO応答  : 1 byte遅延
```

SPIテンプレートV3の既存仕様は変更しない。

`spi_target.v` は変更禁止。

今回の処理では1byte遅延をそのままストリームとして利用する。

概念:

```text
送信        受信

文字0   ->  dummy
文字1   ->  結果0
文字2   ->  結果1
文字3   ->  結果2
...
flush   ->  最終結果
```

FPGA内部に回答文字列全体を保存するバッファは作らない。

---

## RP2040側

RP2040側は以下のみ担当する。

- 標準入力相当の文字列を用意
- ASCII byte列としてFPGAへ送る
- FPGAから返ったbyte列を受信
- 結果文字列として表示
- テスト制御

ABC472Aの文字判定そのものをRP2040側で代行してはいけない。

---

## 参照実装

可能なら、直前の ABC471A Shrike-Lite 実装をひな形として利用する。

読み取り専用の参照資料は以下を使用し、REF配下は変更しない。

```text
REF/abc471a
REF/spi_template_v3/spi_target.v
REF/spi_template_v3/atcoder_spi_template_v3.sdc
```

特に以下を参考にする。

- SPIテンプレートV3の利用方法
- `main.v` の構成
- MicroPython側テストの構成
- Icarus Verilog テストの構成
- REPORTの書き方

ただし、ABC472Aでは入力/出力がストリーム型なので、ABC471AのSTATUS/ANSWER形式を機械的に流用する必要はない。

今回の問題に自然な最小構成にすること。

---

## 主な実装対象

最低限、以下を作成・更新する。

```text
ffpga/src/main.v
firmware/micropython/abc472a_test.py
```

必要に応じて以下を追加してよい。

```text
sim/
tests/
tools/
REPORT_abc472a.md
```

作業に必要な参照ファイルをコピーする場合も、この作業フォルダ配下へ置くこと。

---

## 禁止事項

以下は禁止。

- `spi_target.v` の変更
- SPIテンプレートV3の仕様変更
- 文字列全体をFPGA内部に保存する実装
- RP2040側で問題の判定処理を代行
- 必要のない大規模FSM
- 問題に不要な先読み、並列化、複雑なプロトコル追加
- 作業フォルダ外の既存プロジェクトを変更

---

## テスト

### 1. 文字変換

英大文字26文字すべてを確認する。

期待値:

```text
A    -> A
B-Z  -> .
```

### 2. 文字列テスト

少なくとも以下を確認する。

- 公式サンプル
- 長さ1
- 長さ100
- 全文字 `A`
- `A` を含まない文字列
- `A` を複数含む文字列
- 先頭だけ `A`
- 末尾だけ `A`
- ランダム文字列

### 3. 通信テスト

以下を確認する。

- SPI 1byte応答遅延が正しく扱われる
- 最初のdummy byteを結果として扱わない
- flushで最後の文字を回収できる
- 連続した複数トランザクションで前回結果が混入しない
- 長さ1と長さ100の境界で正常動作する

### 4. Icarus

RTL単体またはSPIを含むシミュレーションで、上記ケースを自動検証する。

可能ならランダムケースも追加する。

---

## 今回まだ行わないこと

今回はまず以下まで行う。

```text
RTL実装
Icarusテスト
MicroPython側テストコード作成
REPORT作成
```

以下は人間側で後から行うので、勝手に実施しなくてよい。

```text
ForgeFPGA Workshopでの合成
bitstream生成
Shrike-Liteへの書き込み
実機テスト
AtCoderへの提出
```

---

## REPORT

作業完了時に `REPORT_abc472a.md` を作成し、簡潔に以下を記録する。

- 実装したファイル
- FPGA側の処理構造
- SPI通信シーケンス
- 1byte遅延の扱い
- テスト内容
- テスト結果
- 論理クロック/byte処理の考え方
- 既知の制約
- 未実施項目

不要な長文説明は避ける。

---

## 完了条件

以下をすべて満たしたら完了。

- 1文字受信ごとのストリーム変換になっている
- FPGA内部に文字列全体を保存していない
- `spi_target.v` を変更していない
- A-Z全26文字の変換テストPASS
- 公式例・境界・ランダムテストPASS
- SPI 1byte遅延を含む通信テストPASS
- 連続トランザクションPASS
- MicroPythonテストコード作成済み
- `REPORT_abc472a.md` 作成済み
