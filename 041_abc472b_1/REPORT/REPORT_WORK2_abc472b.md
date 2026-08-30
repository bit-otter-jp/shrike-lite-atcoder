# ABC472B Shrike-Lite WORK2_abc472b 実行レポート

### プロジェクトと制約

- プロジェクト: `abc472b.ffpga`（`REF/abc472a/abc472a.ffpga`をひな形としてルート直下へ作成）
- RTL参照: `ffpga/src/main.v`、`ffpga/src/spi_target.v`
- Timing constraint: `ffpga/timing-constraints/atcoder_spi_template_v3.sdc`
- Clock: `create_clock -name clk {clk} -period 20.000`（50 MHz）
- Device / I/O / tool設定: ABC472A実プロジェクトから継承
- Tool: ForgeFPGA Workshop v6.54 Build 002、Yosys v0.59、Place and Route compiler v23

Phase 1のRTL、MicroPython、simは変更していない。REFも変更していない。

### SynthとDistRAM推論

Synthは正常終了した。Yosys logでは `main.u_lengths_ram.mem_ram` が `__$XILINX_LUTRAM_SDP_` にマップされ、post-synth cellは次のとおりだった。

```text
RAM64X1D: 34個
```

128深度の各17bitが2個の64x1 dual-port RAMへ分割されたため、`2 * 17 = 34`個であり、128x17bit全体がDistRAMへ推論された結果である。PNR logでも次を確認した。

```text
Type=M: Capacity=40 Utilized=34 NumInst=34
Lut5 for Distributed memory: 272
Logic-Memory CLB for RAM/Shift-Register: 85.0%
```

総FFは189個（CLB FF 185、IOB FF 4）で、2176bitのRAM本体がFF配列へ展開された結果ではない。4k BRAM使用量は0である。

### Resource

| Resource | 使用量 |
|---|---:|
| CLB LUT5s | 786 / 1120 (70.18%) |
| 通常LUT5 | 514 |
| DistRAM用LUT5 | 272 (Type=M容量の85.0%) |
| FF | 189 |
| CLB FF | 185 / 1120 (16.52%) |
| IOB FF | 4 / 736 (0.54%) |
| CLB | 134 / 140 (95.71%) |
| Type=M / Logic-Memory CLB | 34 / 40 (85.0%) |
| 4k BRAM | 0 / 8 |
| OSC | 1 / 1 |
| PLL | 0 / 1 |

PNRは配置・routingを完了し、`Routing verified: 1`、最終congested net 0、tool exit code 0となった。配置密度はCLB 95.71%と高い。

### Timing結果と停止判断

POST-ROUTE Timingは50 MHz制約を満たさなかった。

```text
Constrained Period     : 20000 ps (50 MHz)
WNS                    : -3588 ps
TNS                    : -147114 ps
TNS endpoints          : 58
Achievable Period      : 23587 ps
Achievable Frequency   : 42.396 MHz
```

最悪pathはpropagation 23394 ps、logic stage 11で、内訳はlogic 46.4%、route 53.6%だった。SDC parser warningはwaveform未指定により50% duty cycleを仮定した1件で、critical warningではない。

WORK2の「Timingで問題が出た場合は仕様変更せず停止」に従い、RTL修正、constraint変更、再Synth / 再PNRは行っていない。50 MHz未達のためPhase 2は合格扱いにしない。

### bitstreamと保存状態

WorkshopのGenerate Bitstream一連フローはTiming結果確定後も継続し、次のファイルを生成した。

| ファイル | サイズ |
|---|---:|
| `ffpga/build/FPGA_bitstream.bin` | 45056 bytes |
| `ffpga/build/bitstream/FPGA_bitstream_MCU.bin` | 46408 bytes |
| `ffpga/build/bitstream/FPGA_bitstream_OTP.bin` | 45116 bytes |
| `ffpga/build/bitstream/FPGA_bitstream_FLASH_MEM.bin` | 45096 bytes |

実際の標準生成名は `FPGA_bitstream.bin` である。Timing未達のため`abc472b.bin`への公開用コピー、FPGA書き込み、実機試験には使用していない。

`Save All`実行後、`abc472b.ffpga`のpipeline stateはSynth=1、Generate Bitstream=1となり、`ffpga/build/`、Resource Report、Timing Report、Floorplan用成果物を保持している。同一セッションではResources Report / Timing Analysis / Floorplan操作が有効であることを確認した。ただしTiming停止条件に従い、Workshop終了後の独立した再オープン確認は実施していない。

### Phase 2 未実施項目

- Timing改善のためのRTL変更、constraint変更、再Synth / 再PNR
- Workshop終了後のGUI再オープン確認
- `abc472b.bin`への公開用コピー
- Shrike-Liteへの書き込み
- MicroPython実機テスト、実機時間測定
- AtCoder提出
- Git操作
