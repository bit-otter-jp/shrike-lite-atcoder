# ABC472B Shrike-Lite Phase 3 Report

実施日: 2026-08-29

## 結論

Phase 2の50 MHz Timing未達を受け、REF実物どおりPLLを40 MHz、SDCを25 nsへ変更して再Synth・PNRを実施した。

- Synth: 成功
- DistRAM推論: 成功（`RAM64X1D` 34個、Type=M 34/40）
- PNR/routing: 完了
- 40 MHz Timing: **未達**（WNS -324 ps、TNS -910 ps）
- Achievable Frequency: 39.490 MHz
- 判定: WORK3の停止条件に該当

このため、RTL変更、再配置試行、別周波数化は行わず停止した。

## REF確認と40 MHz設定

作業開始時に `REF/abc468b_pll` の実物を読み取り専用で確認し、次の2ファイルを正本として使用した。

- `REF/abc468b_pll/abc468b_pll.ffpga`
- `REF/abc468b_pll/ffpga/timing-constraints/abc468b.sdc`

REFのPLL値は次のとおりだった。

| 項目 | 値 |
|---|---:|
| `pllFref` | 50.000000 MHz |
| `pllRequiredFout` | 40.000000 MHz |
| `pllRefDiv` | 1 |
| `pllFbDiv` | 24 |
| `pllPostDiv1` | 6 |
| `pllPostDiv2` | 5 |

REFのSDC記述は次のとおりだった。

```tcl
create_clock -name clk {clk} -period 25.000
```

これらをそのまま `abc472b.ffpga` と `ffpga/timing-constraints/atcoder_spi_template_v3.sdc` に反映した。PLL dividerやSDC記述をWeb情報や推測から再構築していない。

確認時のREF SHA-256:

- `abc468b_pll.ffpga`: `B25FFBC73E4F1FDEC3EF30DAD7FC1B12F77C99B30EBB907079F3298F58A55004`
- `abc468b.sdc`: `593276C6A4DAEEE098B74463199C7CEC86CE1754409D257BEBFF714A33ECFA10`

## SynthとDistRAM推論

ForgeFPGA Workshopで40 MHz設定の再Synthを実施し、成功した。

- 合成ログ: `logs/forge_synthesis_gui.log`
- 合成レポート: `ffpga/build/post_synth_report.txt`
- 合成netlist: `ffpga/build/post_synth_results.v`
- ログ上の変換: `mapping memory main.u_lengths_ram.mem_ram via $__XILINX_LUTRAM_SDP_`
- `post_synth_report.txt`: `RAM64X1D` 34個
- `post_synth_results.v`の実インスタンス行数: 34

従って、`reg [16:0] mem_ram [127:0]` は大量FFではなく、Phase 2と同じDistRAM構成へ推論された。

## PNRとResource

DistRAM推論成功後に、40 MHz条件でPNRを1回実施した。追加の配置試行は行っていない。

PNR中のType=M確認:

```text
Type=M: Capacity=40 Utilized=34 NumInst=34. [ChainLen=1]=34
```

`ffpga/build/resource-utilization-report.log`の主な結果:

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

Routingは471 netsの検証を通過し、`Routing verified: 1`、congested net count 0だった。PNRログには、SDCでwaveformを省略したため50% duty cycleを仮定する警告と、`spi_miso_en`/`rst_n`がIOB FFへpackされていない旨の警告がある。

## Timing結果と停止理由

`ffpga/build/PNR_TIMING.log`のPOST-ROUTE結果:

| 項目 | 結果 |
|---|---:|
| Constrained Period | 25,000 ps |
| WNS | **-324 ps** |
| TNS | **-910 ps** |
| TNS Endpoints | 5 |
| Achievable Period | 25,323 ps |
| Achievable Frequency | **39.490 MHz** |

WORK3の合格条件 `WNS >= 0` かつ `TNS = 0` を満たさない。40 MHzでもTiming未達だったため、RTL修正、再配置、別周波数の検討・実行はしていない。

## bitstream

ForgeFPGA Workshopでは「Generate Bitstream」がPNR・Timing解析・bitstream生成を一体で行うため、Timing結果が判明した時点では次のファイルが生成済みだった。

- `ffpga/build/FPGA_bitstream.bin`
- `ffpga/build/bitstream/FPGA_bitstream_MCU.bin`
- `ffpga/build/bitstream/FPGA_bitstream_OTP.bin`
- `ffpga/build/bitstream/FPGA_bitstream_FLASH_MEM.bin`

ただし40 MHz Timingが不合格なので、これらは**Timing未達の未承認bitstream**であり、Shrike-Liteへの書き込みには使用していない。

## GUI再確認状態

PNR後にWorkshopのSave Allを実行し、`abc472b.ffpga`へ結果表示状態を保存した。

- pipeline stage 0 (Synth): 1
- pipeline stage 1 (PNR/bitstream): 1
- 保存時のopened tab: Timing Analysis

その後Workshopを独立に再起動してプロジェクトを再オープンし、次を確認した。

- Resources Report: 有効、LUT5 786 / FF 189 / CLB 134を再表示
- Timing Analysis: 有効
- Floorplan: 有効
- 再オープン前後のプロジェクトSHA-256: `574871D59D2067556EF93CB69A3D97FFDEF34F6D918511FEE0B59525999388B7` で不変

従って、後からForgeFPGA Workshopで結果を再表示できる状態で保存されている。

## CALC時間と既存テストの扱い

RTLは変更していない。最大N=100時のCALCは既存仕様どおり198クロックであり、40 MHzの名目時間は次のとおり。

```text
198 / 40,000,000 = 4.95 us
```

MicroPython側の待ち時間10 usは変更していない。ただし今回のPNRは40 MHz Timing未達なので、この名目時間を実機動作保証とは扱わない。

Phase 1で機能確認済みのIcarus/MicroPythonテストは、RTL・firmware・simを変更していないため再実行していない。

## 変更ファイルと生成物

設定として変更したファイル:

- `abc472b.ffpga`: REF由来の40 MHz PLL設定、およびWorkshopが保存したPhase 3 pipeline/GUI状態
- `ffpga/timing-constraints/atcoder_spi_template_v3.sdc`: 25 ns制約
- `REPORT_WORK3_abc472b.md`: 本報告書

Workshop実行により `ffpga/build/` と `logs/` 配下のSynth/PNR/Timing/bitstream成果物・実行記録を更新した。

## 変更禁止対象と未実施項目

次の既存ファイル・ディレクトリは変更していない。

- `ffpga/src/main.v`
- `ffpga/src/spi_target.v`
- `firmware/micropython/abc472b_test.py`
- `sim/`
- `REF/`
- `REPORT_WORK_abc472b.md`
- `REPORT_WORK2_abc472b.md`

未実施:

- 40 MHz未達後のRTL変更、再配置試行、別周波数化
- Shrike-Liteへの書き込み
- 実機試験
- AtCoder提出
- Git操作
