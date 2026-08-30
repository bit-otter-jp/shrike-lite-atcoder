# WORK2_abc472b.md

## 目的

ABC472B の Phase 1 実装を ForgeFPGA Workshop で Synth / PNR し、
DistRAM推論、Resource、Timingを確認したうえで bitstream を生成する。

作業フォルダ:

```text
D:\my_ws\_scratch\abc472b
```

Phase 1 は完了済みで、RTL / Icarus / MicroPythonテストコード / REPORT は
既に作成・検証済みである。

---

## Phase 1 確認済み事項

以下は既に確認済み。

```text
SPI              : 4 MHz / Mode 0 / 8bit / MSB first
入力             : N + L_i×3byte big-endian
最大入力         : 301byte
V3 package上限   : 256byte
最大入力分割     : 256byte + 45byte
回答             : dummy + 24bit big-endian の4byte read burst
L_i保持          : 128×17bit DistRAM推論用RTL
CALC             : read 1clock + evaluate 1clock / candidate
最大CALC         : 198clock = 3.96us @ 50MHz
Icarus           : 524 PASS / 0 FAIL
MicroPython構文  : PASS
```

Phase 1 の REPORT:

```text
REPORT_WORK_abc472b.md
```

を最初に確認すること。

---

# REF

作業開始時に以下を読み取り専用で確認する。

```text
REF/abc468b_distRAM/
REF/abc472a/
REF/atcoder_spi_template_v3/
```

参照目的:

```text
REF/abc468b_distRAM/
    DistRAMがForgeFPGAで実際に推論された既存例

REF/abc472a/
    最新のForgeFPGA Workshopプロジェクト構成、
    .ffpga配置、Synth / PNR / bitstream生成方法、
    GUIで後から結果確認できる状態の残し方

REF/atcoder_spi_template_v3/
    SPI V3正本、I/O / timing constraint
```

REFは変更しない。

---

# 重要: RTLは原則変更しない

Phase 1 のRTLは機能検証済みである。

以下を原則として変更しない。

```text
ffpga/src/main.v
ffpga/src/spi_target.v
firmware/micropython/abc472b_test.py
sim/
```

今回の目的は、

**現在のRTLをそのままSynth / PNRし、DistRAM推論と配置可能性を確認すること**

である。

SynthでDistRAMへ推論されない、
または配置不能・Timing違反などが発生した場合は、

**勝手にRTLを変更せず、その時点で停止して原因を報告すること。**

人間確認後に修正版WORKを作る。

---

# ForgeFPGA Workshopプロジェクト

ABC472Aの実プロジェクト構成をひな形として使用する。

`.ffpga` は作業ルート直下へ置く。

```text
D:\my_ws\_scratch\abc472b\
├─ abc472b.ffpga
└─ ffpga\
   ├─ src\
   │  ├─ main.v
   │  └─ spi_target.v
   ├─ timing-constraints\
   │  └─ atcoder_spi_template_v3.sdc
   └─ build\
```

`.ffpga` を `ffpga` 配下へ置かない。

ABC472Aと同様、
ルート直下の `.ffpga` から `ffpga/src` と `ffpga/build` を相対参照する構成とする。

---

# 継承するハードウェア設定

ABC472A / SPI V3 の実プロジェクトから以下を継承する。

- Shrike-Lite FPGA device設定
- clk
- clk_en
- rst_n
- spi_ss_n
- spi_sck
- spi_mosi
- spi_miso
- spi_miso_en
- I/O割当
- 50 MHz clock constraint
- SPI V3関連設定
- Synth / PNR tool設定

ABC472B固有の理由がない限り、
I/Oやclock constraintを変更しない。

---

# Timing constraint

内部clockは、

```text
20 ns = 50 MHz
```

とする。

REFの既存 `.sdc` を確認し、
同じ制約を使用する。

---

# Synth

ForgeFPGA Workshop の通常フローで Synth を実行する。

可能ならABC472Aで確認済みのWorkshop内蔵Tclフローを使用する。

Synth完了後、まず以下を確認する。

---

## 最重要: DistRAM推論確認

Phase 1 RTL:

```verilog
reg [16:0] mem_ram [127:0];
```

が、FF配列ではなくDistRAM / Type=M相当のメモリ資源へ推論されていることを確認する。

確認項目:

- DistRAM / Type=M 使用量
- RAMとして推論された幅・深さ
- 128×17bit相当の容量がメモリ資源へ割り当てられていること
- 1700bit超のデータ保持が大量FFへ展開されていないこと
- RAM本体resetなしの記述が推論を妨げていないこと

`REF/abc468b_distRAM` のSynth結果・構成と比較して判断する。

### DistRAMへ推論されなかった場合

その時点で停止する。

以下を報告する。

- 実際のSynth resource
- FF / LUT / Type=M等の使用量
- 推論ログ中の関連記述
- REFとの差
- 考えられる原因

RTL修正は行わない。

---

# Resource確認

Synth / PNR成功時、最低限以下を記録する。

- LUT5
- FF
- CLB
- DistRAM / Type=M
- BRAM
- その他Workshopが表示する主要resource

ABC472B固有ロジックと、
SPI V3の共通部分を完全に分離計測する必要はない。

---

# PNR

DistRAM推論が確認できたらPNRへ進む。

確認事項:

- PNR成功
- 50MHz timing constraint達成
- WNS
- TNS
- Achievable Frequency
- 配置不能・routing errorがない
- DistRAM配置が成立している

Floorplan等でDistRAMの配置が確認できる場合、
後からGUIで確認できる状態を残す。

---

# CALC timingについて

CALCの論理clockは、

```text
2 × (N - 1)
```

である。

最大:

```text
N=100
198 clock
```

50MHzなら、

```text
198 × 20ns = 3.96us
```

である。

Synth / PNR後も内部clock constraintは50MHzなので、
MicroPythonの、

```text
CALC_WAIT_US = 10
```

は論理上十分な余裕を持つ。

今回この値は変更しない。

Timing結果により50MHz制約自体が満たせない場合のみ停止して報告する。

---

# bitstream生成

Synth / PNR成功後、bitstreamを生成する。

ABC472Aで使用したWorkshop内蔵Tclの通常フローを参考にする。

最低限、Shrike-Lite実機書き込みに使う形式を生成する。

最終的な実機用ファイルを特定し、

```text
abc472b.bin
```

など、実際の生成ファイル名をREPORTへ記録する。

存在しない形式・名前を推測で記載しない。

---

# GUIで後から確認できる状態を保存

記事用に、人間が後からForgeFPGA Workshopを開いて、

- Resource Report
- Timing Summary
- Floorplan
- DistRAM配置

などのスクリーンショットを撮る。

そのため、

**Synth / PNR / bitstream生成後のプロジェクト状態を削除せず保存すること。**

残すもの:

```text
abc472b.ffpga
ffpga/build/
レポート
Workshopが結果再表示に必要とする関連ファイル
```

一時ファイル整理のために、
GUI再表示に必要な成果物を削除しない。

---

# REPORT

このWORKの実行結果は、独立した

```text
REPORT_WORK2_abc472b.md
```

へ記録する。

`REPORT_WORK_abc472b.md` など、他のWORKのREPORTへ追記しない。

停止条件に該当した場合も、
REPORT作成と最終報告は停止条件の対象外とし、必ず実施する。

停止した場合は、停止時点までに確認できた事実について、

- 停止理由
- 最後に成功した工程
- Synth / Resource / Timing等の実測結果
- 生成済み成果物
- 変更ファイル
- 未実施項目

を `REPORT_WORK2_abc472b.md` に記録する。

未確認の結果を推測で補わない。

記録内容:

## ForgeFPGA

- `.ffpga`作成
- REFとして使ったプロジェクト
- 50MHz constraint
- Synth成功 / 失敗
- DistRAM推論結果
- DistRAM / Type=M使用量
- Resource
- PNR成功 / 失敗
- WNS
- TNS
- Achievable Frequency
- bitstream生成結果
- GUI再表示可能な状態を保存したこと

DistRAMがどのように推論されたかは、
今回の記事で重要なので明確に記録する。

---

# 今回まだ行わないこと

以下は禁止。

```text
Shrike-Liteへのbitstream書き込み
MicroPython実機テスト
実機時間測定
AtCoder提出
Git操作
```

実機作業は人間側で行う。

---

# 完了条件

以下をすべて満たしたら完了。

- WORK2 / REPORT / REFを確認済み
- REF未変更
- 既存RTL未変更
- `abc472b.ffpga`作成
- `.ffpga`は作業ルート直下
- 50MHz constraint継承
- Synth成功
- 128×17bit配列がDistRAM / Type=Mへ推論
- 大量FF展開されていない
- Resource記録
- PNR成功
- WNS / TNS / Achievable Frequency記録
- 50MHz constraint達成
- bitstream生成
- GUIで後から結果確認可能な状態を保存
- `REPORT_WORK2_abc472b.md` 作成
- 実機作業未実施
- Git操作未実施

---

# 完了報告

完了後、簡潔に以下を報告する。

- 作成した `.ffpga`
- Synth結果
- DistRAM推論結果
- DistRAM / Type=M使用量
- LUT / FF / CLB / BRAM等
- PNR結果
- WNS / TNS / Achievable Frequency
- bitstream生成結果
- GUI再確認可能な状態か
- 変更ファイル
- 未実施項目

DistRAMへ推論されなかった場合は、
PNRへ進まず、その時点で停止する。
ただし `REPORT_WORK2_abc472b.md` を作成し、
停止時点までの結果を記録したうえで最終報告する。
