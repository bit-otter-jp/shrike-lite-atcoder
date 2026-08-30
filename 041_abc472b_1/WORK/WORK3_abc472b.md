# WORK3_abc472b.md

## 目的

WORK2で得られた50 MHz条件のSynth / PNR結果を受け、
Shrike-Liteの内部clockを40 MHzへ変更し、
実動作clockとTiming constraintを一致させた状態で
再Synth / PNR / bitstream生成を行う。

これはWORK2の訂正ではない。

WORK2では50 MHzを目標として正常にSynth / PNRを行い、

```text
WNS                    : -3.588 ns
TNS                    : -147.114 ns
Achievable Period      : 23.587 ns
Achievable Frequency   : 42.396 MHz
```

という結果を得た。

そのため今回はRTL高速化で50 MHzへ合わせるのではなく、

**現在の回路に適した動作周波数として40 MHzを採用する**

追加作業とする。

作業フォルダ:

```text
D:\my_ws\_scratch\abc472b
```

---

# 1. 最初に確認するもの

作業開始時に以下を確認する。

```text
WORK_abc472b.md
REPORT_WORK_abc472b.md
WORK2_abc472b.md
REPORT_WORK2_abc472b.md
abc472b.ffpga
ffpga/timing-constraints/
```

WORK1 / WORK2の結果を変更せず、
WORK3の結果は独立した、

```text
REPORT_WORK3_abc472b.md
```

へ記録する。

---

# 2. REF

以下を読み取り専用で確認する。

```text
REF/abc468b_distRAM/
REF/abc468b_pll/
REF/abc472a/
REF/atcoder_spi_template_v3/
```

今回の主要REFは、

```text
REF/abc468b_pll/
```

である。

このフォルダには、

- Shrike-LiteのPLL出力を40 MHzへ変更した `.ffpga`
- 40 MHzに対応してclock periodを25 nsへ更新した `.sdc`

がある。

**40 MHz PLL設定と25 ns SDCをセットの実績例として参照すること。**

PLL dividerやSDC記述をWeb情報や推測から再構築しない。
実物REFを確認してからABC472Bへ適用する。

REFは変更しない。

---

# 3. 今回変更してよいもの

原則として変更対象は以下だけ。

```text
abc472b.ffpga
ffpga/timing-constraints/<現在使用中のSDC>
REPORT_WORK3_abc472b.md
```

必要なWorkshop生成物は通常フローで更新してよい。

---

# 4. RTL等は変更しない

以下は変更しない。

```text
ffpga/src/main.v
ffpga/src/spi_target.v
firmware/micropython/abc472b_test.py
sim/
```

WORK1で機能確認済みであり、
WORK2ではDistRAM推論も成功している。

今回の目的はRTL高速化ではない。

---

# 5. PLLを40 MHzへ変更

`REF/abc468b_pll` 内の実物 `.ffpga` を確認し、
その40 MHz PLL設定をABC472Bの `.ffpga` へ適用する。

変更後、

```text
internal clock = 40 MHz
```

となっていることを `.ffpga` の設定値から確認する。

PLL divider等を独自に推測して作らない。

ABC472B固有の、

- device
- I/O
- source path
- build path
- その他プロジェクト設定

を壊さないこと。

---

# 6. SDCを25 nsへ変更

`REF/abc468b_pll` 内の更新済み `.sdc` を確認し、
40 MHz設定に対応するclock constraintをABC472Bへ適用する。

最終的に、

```text
clock period = 25 ns
```

となること。

単に計算だけで新規記述せず、
**REFの25 ns版SDCの実際の記述方法を参考にすること。**

PLLとSDCは必ずセットで、

```text
PLL : 40 MHz
SDC : 25 ns
```

へ揃える。

SPI clockは従来どおり、

```text
4 MHz
```

のままとする。

---

# 7. CALC時間

RTL上のCALC clock数は変更しない。

```text
2 × (N - 1)
```

最大N=100では、

```text
198 clock
```

40 MHzでは、

```text
198 / 40 MHz = 4.95 us
```

である。

MicroPython側の、

```text
CALC_WAIT_US = 10
```

はそのままとする。

---

# 8. Synthを再実行

40 MHz PLL設定 + 25 ns SDCでSynthを再実行する。

確認事項:

- Synth成功
- RTL未変更
- DistRAM推論維持

WORK2では、

```text
mem_ram
 -> __$XILINX_LUTRAM_SDP_
 -> RAM64X1D × 34
```

へマップされた。

WORK3でも同等のDistRAM構成が維持されていることを確認する。

大量FF展開へ変化していた場合は、
RTLを勝手に変更せず停止する。

---

# 9. PNRを再実行

Synth成功・DistRAM推論維持を確認後、
PNR / routingを実行する。

40 MHz制約に対して、

```text
WNS >= 0
TNS = 0
Achievable Frequency >= 40 MHz
```

を確認する。

最低限記録するもの:

- LUT5
- FF
- CLB
- DistRAM / Type=M
- RAM64X1D数
- BRAM
- WNS
- TNS
- Achievable Period
- Achievable Frequency

40 MHzでもTiming未達の場合は、
RTL変更・再配置試行・別周波数化を勝手に行わず停止する。

---

# 10. bitstream生成

40 MHz Timingを満たした場合、
通常フローでbitstreamを生成する。

最終実機試験に使用するbitstreamが、

**PLL 40 MHz + SDC 25 nsで生成された最新版**

であることを確認する。

古い50 MHz版と取り違えないこと。

実際の生成ファイル名とパスをREPORTへ記録する。

---

# 11. GUI確認用状態を保存

人間が後からForgeFPGA Workshopで、

- PLL 40 MHz設定
- Resource Report
- Timing Summary
- Floorplan
- DistRAM配置

を確認できる状態を残す。

必要な、

```text
abc472b.ffpga
ffpga/build/
関連report
```

を削除しない。

可能であればWorkshop終了後に再オープンし、
結果画面を再表示できることを確認する。

---

# 12. REPORT_WORK3_abc472b.md

WORK3の結果は必ず、

```text
REPORT_WORK3_abc472b.md
```

へ記録する。

WORK1 / WORK2のREPORTへ追記しない。

最低限以下を記録する。

- WORK3の目的
- 40 MHz採用理由
- `REF/abc468b_pll` の `.ffpga` を参照したこと
- 同REFの25 ns `.sdc` を参照したこと
- PLL設定結果
- SDC設定結果
- Synth結果
- DistRAM推論結果
- Resource
- PNR / routing結果
- WNS
- TNS
- Achievable Period
- Achievable Frequency
- bitstream生成結果
- GUI再確認状態
- 変更ファイル
- 未実施項目

---

# 13. 停止条件に該当した場合

停止条件に該当した場合は、
以降の実装変更・再試行・次工程への進行を停止する。

ただし、

**REPORT作成と最終報告は停止条件の対象外とする。**

停止した場合でも必ず、

```text
REPORT_WORK3_abc472b.md
```

を作成し、停止時点までに得られた事実を記録する。

最低限、

- 停止理由
- 最後に成功した工程
- Synth / Resource / Timing等の実測結果
- 生成済み成果物
- 変更したファイル
- 未実施項目

を記録する。

新しい解析値や結果を推測で補わない。

---

# 14. 今回まだ行わないこと

以下は行わない。

```text
Shrike-Liteへのbitstream書き込み
MicroPython実機テスト
AtCoder提出
Git操作
```

実機作業は人間側で行う。

---

# 完了条件

通常完了の場合:

- WORK1 / WORK2の結果確認
- `REF/abc468b_pll` の `.ffpga` を実物確認
- 同REFの25 ns `.sdc` を実物確認
- REF未変更
- RTL未変更
- `abc472b.ffpga` のPLLを40 MHzへ変更
- ABC472BのSDCを25 nsへ変更
- PLLとSDCが40 MHz条件で一致
- Synth成功
- DistRAM推論維持
- PNR成功
- WNS >= 0
- TNS = 0
- Achievable Frequency >= 40 MHz
- bitstream生成
- GUI再確認可能な状態を保存
- `REPORT_WORK3_abc472b.md` 作成
- 実機作業未実施
- Git操作未実施

停止条件に該当した場合:

- 追加変更・再試行を行っていない
- 停止時点までの結果を `REPORT_WORK3_abc472b.md` に記録
- 最終報告を実施

---

# 完了報告

完了後、簡潔に以下を報告する。

- PLL 40 MHz設定結果
- SDC 25 ns設定結果
- Synth結果
- DistRAM推論結果
- Resource
- PNR結果
- WNS / TNS / Achievable Frequency
- bitstream生成結果
- GUI再確認可能か
- `REPORT_WORK3_abc472b.md` 作成結果
- 変更ファイル
- 未実施項目

停止条件に該当した場合も、
REPORT作成後に同じ形式で報告する。
