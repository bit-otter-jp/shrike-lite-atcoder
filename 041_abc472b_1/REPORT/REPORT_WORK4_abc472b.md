# ABC472B Shrike-Lite WORK4 実行レポート

実施日: 2026-08-29

## 結論

ForgeFPGA WorkshopのPLL ConfiguratorをCodexから自動操作し、最初のtargetである37.5 MHzの推奨設定を取得・適用できた。RTLを変更せずSynth / PNRを実施し、最初の試行でTiming PASSしたため探索を終了した。

- PLL Configurator自動操作: PASS
- 最終採用target / actual PLL frequency: 37.5 / 37.5 MHz
- Synth / DistRAM: PASS、`RAM64X1D` 34個、Type=M 34/40
- Routing: `Routing verified: 1`、最終congestion 0
- Timing: WNS +1.343 ns、TNS 0 ns
- Achievable Frequency: 39.490 MHz
- bitstream: Timing合格済み実機候補として生成済み
- 実機書き込み・実機試験: 未実施

## 目的とWORK3開始条件

WORK3では40 MHz / 25 nsで次の結果となり、Timing未達だった。

| 項目 | WORK3結果 |
|---|---:|
| WNS | -0.324 ns |
| TNS | -0.910 ns |
| Achievable Period | 25.323 ns |
| Achievable Frequency | 39.490 MHz |

WORK4ではRTLを変更せず、PLL Configuratorが生成する設定だけを用いてTiming PASSするclockを探索した。

## PLL Configurator自動操作可否

ForgeFPGA Workshop v6.54のメイン画面からFPGA Editorを自動で開き、FPGA Editor内の `PLL Configurator` ボタンをUI Automationで操作できた。

Configuratorの次の要素を機械的に識別・操作できた。

- `Required Output Frequency, MHz`へのtarget入力
- `Actual Output Frequency, MHz`の読み出し
- REFDIV / FBDIV / POSTDIV1 / POSTDIV2の読み出し
- actual output periodの読み出し
- Apply
- Save All

最初はApply/Saveしないプローブとして37.5 MHzを入力し、Configurator自身がactual 37.5 MHzと有効なparameterを生成し、Applyが有効になることを確認した。その後、同じ自動経路でApply / Save Allを行った。dividerの推測、手計算、総当たり、マニュアル由来の独自設計、人間操作は行っていない。

## 周波数決定

WORK4の規定式を使用した。

```text
39.490 MHz × 0.95 = 37.5155 MHz
floor(37.5155 × 2) / 2 = 37.5 MHz
```

Configuratorが37.5 MHzそのものを生成できたため、目標以下の代替候補は使用していない。

## 試行結果

| Trial | target MHz | actual MHz | SDC period ns | WNS ns | TNS ns | Achievable MHz | Result |
|---:|---:|---:|---:|---:|---:|---:|---|
| 1 | 37.5 | 37.5 | 26.666666667 | +1.343 | 0 | 39.490 | PASS |

試行1が `WNS >= 0`、`TNS = 0`、`Achievable Frequency >= actual PLL frequency` の全条件を満たしたため、追加targetや再試行はない。試行周波数列は `[37.5 MHz]` である。

## Configurator生成PLL設定

Configurator画面と保存後の `abc472b.ffpga` の双方で次を確認した。

| 項目 | 値 |
|---|---:|
| Input Frequency / `pllFref` | 50 MHz / 50.000000 |
| Required Output Frequency / `pllRequiredFout` | 37.5 MHz / 37.500000 |
| Actual Output Frequency | 37.5 MHz |
| `pllRefDiv` | 1 |
| `pllFbDiv` | 27 |
| `pllPostDiv1` | 6 |
| `pllPostDiv2` | 6 |
| Actual Output Period | 26.666666666666668 ns |
| VCO Frequency | 1350 MHz |
| PFD Frequency | 50 MHz |
| Manual calculation mode | 0（自動） |
| Bypass / Clock Selection / User Clock / Lock | 0 / 0 / 0 / 0 |

## SDC

actual 37.5 MHzからWORK4指定式でperiodを算出した。

```text
1000 / 37.5 = 26.666666666... ns
```

`ffpga/timing-constraints/atcoder_spi_template_v3.sdc`を次の記述へ更新した。

```tcl
create_clock -name clk {clk} -period 26.666666667
```

Timing engine内部では1 ps単位へ丸められ、Constrained Periodは26,667 ps、fall timeは13,333 psとなった。この丸めとwaveform省略に関する3 warningはあるが、critical warningは0である。SPI clock 4 MHzは変更していない。

## Synth / DistRAM

37.5 MHz PLLと同期済みSDCで再Synthし、成功した。

- `mapping memory main.u_lengths_ram.mem_ram via $__XILINX_LUTRAM_SDP_`
- `post_synth_report.txt`: `RAM64X1D` 34個
- `post_synth_results.v`の`RAM64X1D`実インスタンス行数: 34
- 合成FF: FDCE 143、FDPE 29、FDRE 17（合計189）

従って、`reg [16:0] mem_ram [127:0]` は大量FFではなく、従来どおりDistRAMへ推論された。

## Resource / PNR / Timing

| Resource | 使用量 |
|---|---:|
| CLB LUT5 | 786 / 1120 (70.18%) |
| Distributed-memory LUT5 | 272 (85.00%) |
| FF total | 189 |
| CLB FF | 185 / 1120 (16.52%) |
| IOB FF | 4 / 736 (0.54%) |
| CLB | 134 / 140 (95.71%) |
| Type=M | 34 / 40 (85.00%) |
| 4k BRAM | 0 / 8 |

POST-ROUTE Timing:

| 項目 | 結果 |
|---|---:|
| Constrained Period | 26,667 ps |
| WNS | +1,343 ps |
| TNS | 0 ps |
| TNS Endpoints | 0 |
| Achievable Period | 25,323 ps |
| Achievable Frequency | 39.490 MHz |

Routingは471 netsを検証し、`Routing verified: 1`、最終congested net count 0だった。既存と同様に`spi_miso_en`と`rst_n`がIOB FFへpackされていない警告、およびbitstream checkerのclock buffer警告がある。

## bitstream

Timing PASSした試行1で次を生成した。

- `ffpga/build/FPGA_bitstream.bin`
- `ffpga/build/bitstream/FPGA_bitstream_MCU.bin`
- `ffpga/build/bitstream/FPGA_bitstream_OTP.bin`
- `ffpga/build/bitstream/FPGA_bitstream_FLASH_MEM.bin`

これらはWORK4で最初にTiming PASSした試行の実機候補である。ただし今回はShrike-Liteへ書き込んでいない。

## CALC時間

RTL未変更のため最大CALCは198 clocksのままである。

```text
198 / 37.5 MHz = 5.28 us
```

`5.28 us < CALC_WAIT_US 10 us` を満たす。`firmware/micropython/abc472b_test.py`と`CALC_WAIT_US = 10`は変更していない。

## GUI保存と独立再オープン

PNR完了後にSave Allし、pipeline stage 0/1がともに1の状態を `abc472b.ffpga` へ保存した。

その後Workshopを独立に再起動し、次を再表示できることを確認した。

- PLL Configurator: required 37.5 MHz、actual 37.5 MHz、1 / 27 / 6 / 6
- Resources Report: LUT5 786、FF 189、CLB 134
- Timing Analysis: 有効
- Floorplan: 有効

再オープン前後のプロジェクトSHA-256は `EE4860FC97C68F8AC605598FC8EFA956AD20D87A323649974BD4CF121BAE5E4E` で不変だった。

## 変更ファイルと生成物

設定・報告:

- `abc472b.ffpga`: Configurator由来37.5 MHz PLL設定と最終GUI/pipeline状態
- `ffpga/timing-constraints/atcoder_spi_template_v3.sdc`: 26.666666667 ns
- `REPORT_WORK4_abc472b.md`: 本報告書

WORK4用自動操作:

- `scripts/probe_forge_pll_target.ps1`: Configurator target入力、actual/parameter取得、Apply/Save
- `scripts/inspect_forge_pll_configurator.ps1`: Configuratorの独立再オープン確認

ForgeFPGA実行により `ffpga/build/` と `logs/` 配下のSynth / PNR / Timing / bitstream成果物・実行記録を更新した。

## 変更禁止対象と未実施項目

次を変更していない。

- `ffpga/src/main.v`
- `ffpga/src/spi_target.v`
- `firmware/micropython/abc472b_test.py`
- `sim/`
- `REF/`
- `REPORT_WORK_abc472b.md`
- `REPORT_WORK2_abc472b.md`
- `REPORT_WORK3_abc472b.md`

未実施:

- RTL / SPI V3 / MicroPythonの変更
- 37.5 MHz PASS後の追加周波数探索・再配置
- Shrike-Liteへの書き込み
- 実機試験
- AtCoder提出
- Git操作

