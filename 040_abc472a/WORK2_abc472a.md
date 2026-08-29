# WORK2_abc472a.md

## 目的

ABC472A の ForgeFPGA Workshop 用プロジェクトを作成し、Synth / PNR まで完了させる。

作業フォルダ:

```text
<WORKDIR>
```

参照資料:

```text
<WORKDIR>/REF/abc471a
```

REF 配下は読み取り専用とし、変更しないこと。

---

## 背景

ABC472A の RTL実装・Icarusテスト・MicroPythonテストコード・REPORT はすでに完成している。

現在の主な実装ファイル:

```text
ffpga/src/main.v
ffpga/src/spi_target.v
```

次の作業として、ForgeFPGA Workshop で Synth / PNR を行い、後から人間がForgeFPGA Workshopを開いて Resource Report / Timing Summary などを確認・記事用スクリーンショット撮影できる状態まで準備する。

REF の ABC471A フォルダには、前回実際に使用した ForgeFPGA Workshop プロジェクトがある。

これをひな形として ABC472A 用プロジェクトを作成する。

---

## プロジェクト構成

REF の実プロジェクト構成を優先する。

ABC471A の実プロジェクトでは `.ffpga` はプロジェクトルート直下にあり、そこから `ffpga/src` と `ffpga/build` を相対参照している。

ABC472A も同じ構成とする。

```text
<WORKDIR>/
├─ abc472a.ffpga
├─ ffpga\
│  ├─ src\
│  │  ├─ main.v
│  │  └─ spi_target.v
│  └─ build\
├─ firmware\
├─ sim\
├─ REF\
└─ REPORT_abc472a.md
```

`.ffpga` を `ffpga` 配下へ置いてはいけない。

`ffpga\abc472a.ffpga` とすると、REFの相対パス構成では `ffpga\ffpga\src` を参照する不整合が起きるためである。

---

## 作業内容

### 1. REF の ABC471A プロジェクトを確認

まず、

```text
REF\abc471a
```

配下を確認し、以下を特定する。

- `.ffpga` ファイル
- ForgeFPGA Workshop のプロジェクト構成
- RTLソースの相対参照方法
- I/O設定
- クロック制約
- デバイス設定
- Synth / PNR後に保存される成果物
- 後からForgeFPGA Workshopで結果を再表示するために必要なファイル

REF は変更しない。

### 2. ABC472A用プロジェクトを作成

ABC471A のプロジェクトをひな形として、ABC472A用の ForgeFPGA Workshop プロジェクトを作成する。

`.ffpga` は作業ルート直下へ配置する。

```text
<WORKDIR>/abc472a.ffpga
```

成果物はREFと同様に、

```text
<WORKDIR>/ffpga/build
```

配下へ生成する構成とする。

### 3. RTL参照をABC472Aへ合わせる

プロジェクトが参照するRTLは、現在のABC472A実装を使用する。

```text
ffpga/src/main.v
ffpga/src/spi_target.v
```

REF側のABC471A RTLを参照したままにしないこと。

`.ffpga` からの相対参照がREFの実構成と一致していることを確認する。

### 4. ハードウェア設定はABC471Aを継承

ABC472Aは同じShrike-Lite実機、同じSPI V3構成を使うため、以下は原則としてABC471Aの設定をそのまま引き継ぐ。

- ForgeFPGAデバイス設定
- クロック入力
- 50 MHz制約
- SPIピン設定
- FPGA RESET
- その他ボード固有I/O設定

ABC472A固有の理由がない限り、I/O割当やクロック制約を変更しない。

---

## Synth / PNR

ABC472A用 `.ffpga` プロジェクト作成後、ForgeFPGA Workshop の通常フローで以下を実施する。

```text
Synth
PNR
Resource Report確認
Timing Summary確認
bitstream生成
```

可能な限り、REF の ABC471A と同じ手順・設定を用いる。

### 重要: 後からGUIで結果を確認できる状態を残す

今回の記事では、後から人間が ForgeFPGA Workshop を開いて、

- Resource Report
- Timing Summary
- その他必要な結果画面

を確認し、スクリーンショットを撮影する。

そのため、Synth / PNR が成功したら、

**ForgeFPGA Workshopでプロジェクトを再度開いたとき、再実行せずに今回のSynth / PNR結果を確認できる状態を保存しておくこと。**

具体的には、

- `abc472a.ffpga`
- `ffpga/build` 配下のSynth / PNR生成物
- レポート類
- Workshopが結果状態を再表示するために必要なプロジェクト関連ファイル

を削除しない。

一時ファイル整理のために、Workshopの結果再表示に必要なファイルを削除しないこと。

Synth / PNR後にプロジェクト保存操作が必要なら保存すること。

### 結果を記録

最低限、以下を `REPORT_abc472a.md` に追記する。

- Synth 成功 / 失敗
- PNR 成功 / 失敗
- Resource使用量
- Timing Summary
- 50 MHz制約に対する結果
- Achievable frequency等、Workshopが表示する主要値
- bitstream生成結果
- 後からWorkshopで結果確認可能な状態を保存したこと

数値は実際の出力から転記し、推測しないこと。

---

## 重要な制約

以下は禁止。

- REF 配下の変更
- 完成済みの `main.v` の論理変更
- 完成済みの `spi_target.v` の変更
- MicroPythonテストの変更
- SPI V3仕様の変更
- I/Oピンの独自変更
- クロック制約の独自変更
- Synth / PNRを通すためだけのRTL仕様変更
- Synth / PNR結果を後から確認するために必要な成果物の削除

今回の目的は、

**既存のABC472A RTLを、REFの実プロジェクト構成と同じ相対パス構成でSynth / PNRし、後からForgeFPGA Workshopで結果を確認できる状態まで準備すること**

である。

---

## 実機作業

以下は行わない。

```text
Shrike-Liteへのbitstream書き込み
MicroPython実機テスト
AtCoder提出
```

実機作業は人間側で行う。

---

## 確認項目

作業後、最低限以下を確認する。

- `<WORKDIR>/abc472a.ffpga` が作成されている
- `.ffpga` が作業ルート直下にある
- ABC472Aの `ffpga/src/main.v` を参照している
- ABC472Aの `ffpga/src/spi_target.v` を参照している
- ABC471A固有RTLを参照していない
- I/O設定がREFのABC471Aと一致している
- クロック制約がREFのABC471Aと一致している
- Synthが成功している
- PNRが成功している
- bitstreamが生成されている
- 成果物が `ffpga/build` に保存されている
- Resource Report / Timing Summaryが取得できている
- 後からForgeFPGA Workshopで結果を確認できるプロジェクト状態が保存されている
- REF配下を変更していない
- 既存RTL・テストを変更していない

---

## REPORT追記

既存の、

```text
REPORT_abc472a.md
```

へ短く追記する。

追記内容:

- `abc472a.ffpga` 作成
- プロジェクトルート直下へ配置したこと
- 参照したREFプロジェクト
- 継承したI/O / clock設定
- Synth / PNR結果
- Resource使用量
- Timing Summary
- bitstream生成結果
- Workshopで後から結果確認できる状態を保存したこと
- 未実施項目

既存レポートを大幅に書き換えない。

---

## 完了報告

完了後、以下だけ簡潔に報告する。

- 作成した `abc472a.ffpga`
- プロジェクト配置
- REFから継承した設定
- 変更したファイル一覧
- Synth / PNR結果
- Resource使用量
- Timing Summary
- bitstream生成結果
- ForgeFPGA Workshopで後から結果確認できる状態か
- 未実施項目
