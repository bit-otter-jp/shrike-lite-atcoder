# WORK4_abc472b.md

## 目的

WORK3では、RTLを変更せずShrike-Liteの内部clockを40 MHzへ下げて
Synth / PNRを実施したが、40 MHz Timingをわずかに満たさなかった。

WORK3結果:

```text
Synth                  : PASS
DistRAM                : RAM64X1D ×34、Type=M 34/40
Resource               : LUT5 786、FF 189、CLB 134/140、BRAM 0
Routing                : verified=1、congestion=0
WNS                    : -0.324 ns
TNS                    : -0.910 ns
Achievable Period      : 25.323 ns
Achievable Frequency   : 39.490 MHz
```

今回のWORK4ではRTLを変更せず、
ForgeFPGA WorkshopのPLL Configuratorを使って
適切な内部clock設定を自動的に探索し、
Timingを満たす周波数を決定する。

周波数は人間の勘で決めず、
直前のPNRで得たAchievable Frequencyを基準に機械的に決定する。

作業フォルダ:

```text
D:\my_ws\_scratch\abc472b
```

---

# 1. 最初に確認するもの

作業開始時に以下を確認する。

```text
WORK3_abc472b.md
REPORT_WORK3_abc472b.md
abc472b.ffpga
ffpga/timing-constraints/
REF/abc468b_pll/
```

WORK1～WORK3のREPORTは変更しない。

今回の結果は独立した、

```text
REPORT_WORK4_abc472b.md
```

へ記録する。

---

# 2. RTL等は変更しない

以下は変更禁止。

```text
ffpga/src/main.v
ffpga/src/spi_target.v
firmware/micropython/abc472b_test.py
sim/
REF/
REPORT_WORK_abc472b.md
REPORT_WORK2_abc472b.md
REPORT_WORK3_abc472b.md
```

今回の目的はRTL高速化ではなく、
既存回路に適したclockを決定することである。

---

# 3. 最初の関門: PLL Configuratorの自動操作可否

ForgeFPGA Workshopに備わっているPLL Configuratorを使用し、
指定した目標周波数に対する推奨PLL設定を取得できるか確認する。

重要:

**PLL divider値を推測・手計算・独自探索で作らない。**

今回使ってよいのは、
ForgeFPGA WorkshopのPLL Configurator自身が提示・生成する設定である。

CodexがWorkshopのGUI操作、Tcl、既存のWorkshop機能などを利用して
PLL Configuratorから推奨設定を自動取得できる場合のみ、
以降の周波数探索へ進む。

## 自動取得できない場合

以下のいずれかに該当した場合は、この時点で停止する。

- PLL ConfiguratorをCodexから操作できない
- 目標周波数を入力して推奨設定を取得できない
- Configuratorの生成結果を `.ffpga` へ安全に反映できない
- 人間のGUI操作が必要
- divider値を推測しないと先へ進めない
- Configuratorの結果かどうか確認できない

この場合、

**マニュアルを読んでPLL原理から独自設定を作る作業へ勝手に切り替えないこと。**

また、既存のPLL設定を変更しない。

停止理由を `REPORT_WORK4_abc472b.md` に記録して終了する。

REPORT作成と最終報告は停止条件の対象外であり、必ず実施する。

---

# 4. 周波数決定ルール

Timing未達時の次回目標周波数は、
直前のPNRで得た **Achievable Frequency** から決める。

計算:

```text
next_raw = Achievable Frequency × 0.95
```

その値を **0.5 MHz単位で切り下げる**。

式:

```text
next_target_MHz = floor(next_raw × 2) / 2
```

四捨五入ではなく切り下げること。

## WORK4最初の目標

WORK3のAchievable Frequencyは、

```text
39.490 MHz
```

なので、

```text
39.490 × 0.95 = 37.5155 MHz
```

0.5 MHz単位で切り下げ、

```text
37.5 MHz
```

を最初の目標とする。

---

# 5. PLL Configuratorで設定を取得

目標周波数をPLL Configuratorへ入力し、
Configuratorが提示する推奨設定を取得する。

目標値そのものが生成できない場合は、
Configuratorが生成可能な候補のうち、

**目標周波数以下で最も近い推奨設定**

を採用してよい。

ただし、

- Configurator由来であること
- 実際の出力周波数を取得できること
- 採用したPLL parameterを記録できること

が条件である。

記録項目:

- target frequency
- Configuratorのactual / generated output frequency
- pllFref
- pllRequiredFout
- pllRefDiv
- pllFbDiv
- pllPostDiv1
- pllPostDiv2
- その他Configuratorが変更したPLL項目

実際に `.ffpga` へ反映した値をREPORTへ記録する。

---

# 6. SDCを実PLL周波数へ合わせる

SDCはPLL Configuratorが生成した **実際の出力周波数** に合わせる。

```text
period_ns = 1000 / actual_frequency_MHz
```

とする。

例:

```text
37.5 MHz -> 26.666... ns
```

必要な精度を保って `create_clock` のperiodへ設定する。

PLLを変更してSDCを旧値のまま残さない。
SDCだけを変更してPLLを旧値のまま残さない。

必ず、

```text
PLL actual frequency
SDC constrained frequency
```

を一致させる。

SPI clockは、

```text
4 MHz
```

のまま変更しない。

---

# 7. 各試行のSynth

PLL / SDCを更新したらSynthを実行する。

毎回以下を確認する。

- Synth成功
- RTL未変更
- DistRAM推論維持
- `RAM64X1D ×34` 相当
- Type=M使用量
- 大量FF展開していない

DistRAM推論が崩れた場合はそこで停止する。
RTL修正は行わない。

---

# 8. 各試行のPNR / Timing

Synth成功後、通常のWorkshopフローでPNR / Timingを実行する。

各試行について記録する。

```text
target frequency
actual PLL frequency
SDC period
WNS
TNS
Achievable Period
Achievable Frequency
Routing verified
congestion
PASS / FAIL
```

Timing PASS条件:

```text
WNS >= 0
TNS = 0
Achievable Frequency >= actual PLL frequency
```

PASSしたら周波数探索を終了する。

---

# 9. Timing FAIL時の再試行

Timing FAILの場合は、
その試行で得られた **Achievable Frequency** を新しい基準値とする。

再び、

```text
next_raw = Achievable Frequency × 0.95
next_target_MHz = floor(next_raw × 2) / 2
```

で次の目標周波数を求める。

そして再度、

```text
PLL Configurator
↓
actual PLL frequency取得
↓
SDC更新
↓
Synth
↓
PNR / Timing
```

を行う。

Timing PASSするまで同じルールを繰り返してよい。

## 再試行を停止する条件

以下の場合は探索を停止する。

- PLL Configuratorの自動操作ができなくなった
- 目標以下の有効な推奨設定を取得できない
- Configurator出力を安全に反映できない
- 次のtargetが前回targetより下がらない
- Configuratorが前回と同じactual frequencyしか返さず探索が進まない
- Synth失敗
- DistRAM推論崩れ
- PNR / routing失敗
- 結果の信頼性を確認できない

停止した場合も追加の手動PLL設計やRTL変更は行わない。

---

# 10. bitstreamの扱い

ForgeFPGA WorkshopではPNR / Timing / bitstream生成が
一連のフローとして実行される場合がある。

Timing FAIL時にbitstreamが生成されても、

**Timing未達の未承認bitstream**

として扱い、実機には使用しない。

最初にTiming PASSした試行のbitstreamだけを、
実機候補として扱う。

実際の生成ファイル名・パスをREPORTへ記録する。

今回はShrike-Liteへの書き込みは行わない。

---

# 11. CALC時間

CALCはRTL未変更なので最大、

```text
198 clocks
```

のままである。

最終採用clockに対する名目CALC時間を、

```text
198 / actual_frequency
```

で算出しREPORTへ記録する。

MicroPython側の、

```text
CALC_WAIT_US = 10
```

は今回は変更しない。

ただし最終採用周波数で、

```text
198 clocks < 10 us
```

を満たすことを確認する。

満たさない場合は停止して報告し、
MicroPythonを勝手に変更しない。

---

# 12. GUI保存状態

最終試行後にSave Allを行い、
人間が後からForgeFPGA Workshopで、

- PLL設定
- Resource Report
- Timing Analysis
- Floorplan

を確認できる状態を保存する。

Timing PASSした場合は、
可能ならWorkshopを独立再起動してプロジェクトを再オープンし、
結果を再表示できることを確認する。

停止条件に該当して終了した場合も、
その時点の結果を可能な範囲で保存する。

---

# 13. REPORT_WORK4_abc472b.md

このWORKの結果は必ず、

```text
REPORT_WORK4_abc472b.md
```

へ記録する。

WORK1～WORK3のREPORTへ追記しない。

## 必須記録

- WORK4の目的
- WORK3の開始条件
- PLL Configuratorの自動操作可否
- 周波数決定ルール
- 各試行のtarget / actual PLL frequency
- 各試行のPLL parameter
- 各試行のSDC period
- 各試行のSynth結果
- 各試行のDistRAM推論結果
- 各試行のResource
- 各試行のPNR / Timing
- WNS / TNS
- Achievable Frequency
- PASS / FAIL
- 最終採用周波数、または停止理由
- bitstream生成状況
- GUI保存 / 再オープン確認状態
- 最終周波数での198 clockの名目CALC時間
- 変更ファイル
- 未実施項目

複数試行した場合は、
比較しやすい表にまとめる。

---

# 14. 停止条件とREPORT

どの停止条件に該当した場合でも、
以降の設定変更・再試行・次工程への進行を停止する。

ただし、

**REPORT作成と最終報告は停止条件の対象外である。**

必ず `REPORT_WORK4_abc472b.md` を作成し、
停止時点までに確認できた事実を記録する。

未確認値を推測で補わない。

---

# 15. 今回行わないこと

- RTL変更
- SPI V3変更
- MicroPython変更
- 人間によるPLL Configurator操作
- PLL原理を独自に学習してdividerを設計
- 手計算・総当たりによるPLL divider探索
- Shrike-Lite書き込み
- 実機試験
- AtCoder提出
- Git操作

---

# 完了条件

通常完了:

- PLL ConfiguratorをCodexから自動利用可能
- 最初のtarget 37.5 MHzから探索開始
- 各PLL設定はConfigurator由来
- actual PLL frequencyとSDCが一致
- RTL未変更
- DistRAM推論維持
- Timing PASSするまで規定ルールで必要な再試行
- 最終試行 WNS >= 0
- 最終試行 TNS = 0
- bitstream生成
- GUI結果保存
- `REPORT_WORK4_abc472b.md` 作成
- 実機未実施
- Git未実施

停止終了:

- 停止条件発生後に勝手な代替手段へ進んでいない
- `REPORT_WORK4_abc472b.md` に停止理由と取得済み結果を記録
- 最終報告実施

---

# 完了報告

完了後、簡潔に以下を報告する。

- PLL Configurator自動操作可否
- 試行した周波数列
- 各試行のTiming結果
- 最終採用周波数、または停止理由
- 最終DistRAM / Resource
- 最終WNS / TNS / Achievable Frequency
- 最終CALC名目時間
- bitstream状態
- GUI再確認状態
- `REPORT_WORK4_abc472b.md` 作成結果
- 変更ファイル
- 未実施項目
