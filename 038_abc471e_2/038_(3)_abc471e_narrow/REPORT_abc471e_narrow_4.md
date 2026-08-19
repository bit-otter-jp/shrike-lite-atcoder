# ABC471E Narrow compact_v3 W8 PNRレポート

## 1. 結論

`SPEC_abc471e_narrow_2.md` と `IMPL_abc471e_narrow_3.md` を正として、`compact_v3` W8 finalに対しForgeFPGAの通常flowでPlace-and-Routeを実行した。

PNR結果は**失敗**である。LUT packing自体は検証成功したが、minimum placementでType=Lが`165 / 140`（25 CLB超過、117.9%）となり、`FATAL ERROR: The design cannot fit into the current geometry.`で停止した。従って、現行RTLのままShrike-Lite Type=L 140へはfitしない。

配置が成立しなかったため、最終post-placement/post-route timing、WNS/TNS、正常なroute結果は存在しない。packing後の`11.324 MHz`は配置配線前の推定値であり、最終timingではない。

## 2. 事前条件

対象設定は`WIDTH=8 / MOD=251 / N_MAX=250 / VALUE_BYTES=1`である。

| 項目 | 確認結果 |
|---|---|
| final `main.v` SHA-256 | `e910abcf293fc37fbb071eef5cfad4eb91b0047263b512707278360032716fc6` |
| Icarus | `TOTAL=39 PASS=39 FAIL=0` |
| Post-Synthesis | 557 LUT / 163 FF / 31 CARRY4 |
| PNR入力EDIF SHA-256 | `018053a9ed8af5af46f2ed44358153fe99b0a9a953228d42d5551b878bbcc545` |
| clock制約 | `create_clock -name clk {clk} -period 20.000`（50 MHz） |

PNR用の分離projectへコピーした`main.v`、`spi_target.v`、`netlist.edif`、`post_synth_results.v`、`post_synth_report.txt`は、それぞれ元のcompact_v3 W8 finalと同一ハッシュである。I/O specは既存projectのものをそのまま使用した。

## 3. PNR実行条件

ForgeFPGA GUIの通常Place-and-Route flowを使用した。主なtool設定は次のとおりである。

| 設定 | 値 |
|---|---:|
| high-density packing | 1 |
| high-density I/O packing | 0 |
| concurrent clock optimization | 1 |
| place-and-trial-route | 0 |
| PNR trial iterations | 20 |
| max route iterations | 300 |
| max CPU | 16 |
| timing corner | 0 |

今回の範囲をPNRに限定するため、BIN/LOG/AXI/AXI_CRC/VM/DBのbitstream出力はすべて0に設定した。実行後もbitstream directoryは空であり、bitstream生成、flash、実機試験には進んでいない。

実行日時は2026-08-17 17:07 JST、automationによるForge起動からログ取得まで16.2秒だった。Place-and-Route tool processはexit code 3で終了した。

## 4. packingとresource結果

| 項目 | 結果 |
|---|---:|
| packing入力instance | 790 |
| I/O packing | 10 instances / 6 CLBs |
| carry-chain packing | 146 instances / 37 CLBs |
| timing-driven packing最終表示 | 171 CLBs |
| unpacked instance | 0 |
| packing verification | 1（成功） |
| packed Logic 6-LUT CLB | 165 |
| CLB LUT utilized | 539 |
| logical LUT total | 637 |
| 6-input LUT | 76 |
| dual 5-input LUT | 98 |
| CLB FF utilized | 138 |
| logical FF total | 160 |
| I/O FF | input 2 / output 1 |
| I/O CLB | 6 |
| clock | 1、fanout 54 CLBs |
| DSP | 0 |
| toolのtile必要数診断 | Logic-Memory FPGA 1K Tile x 2 |

Post-Synthesisの557 LUTはprimitive数である。一方、PNRの539 CLB LUT utilized、637 logical LUT total、165 Logic CLBはdual-LUT packingやcarry-chain/CLB制約を反映した指標であり、単純な`ceil(557/4)=140`ではfit判定できなかった。

## 5. placer診断とutilization

floorplanは184 IOB、140 Logic 6-LUT CLB（うち40 CLBがRAM/SR対応）である。

| resource | capacity | utilized | utilization |
|---|---:|---:|---:|
| Type=L | 140 | 165 | 117.9% |
| Type=M | 40 | 0 | 0.0% |
| IOB | 184 | 6 | 3.3% |

toolの補助utilizationはLUT 96.2%（dual-LUT 17.5%）、FF 24.6%（dual-FF 3.9%）、IO CLB 3.3%だった。

MinPlacer入力は173 instancesで、chain結合後は157 instances、630 nets、fanout 49超が2 nets、平均fanout 3.56、clock 1本だった。placer resource診断は次のとおりである。

```text
Type=L: Capacity=140 Utilized=165 NumInst=151. [ChainLen=1]=140 [ChainLen=2]=8 [ChainLen=3]=3
Type=M: Capacity=40 Utilized=0 NumInst=0.
Type=IOB: Capacity=184 Utilized=6 NumInst=6.
Resource over-use on combined types=L,M: Capacity=140,- Utilized=165,0, NumInst=151,0
FATAL ERROR: The design cannot fit into the current geometry.
MinPlacer failed.
```

失敗stageはminimum placementであり、主要因はType=Lの25 CLB超過である。

## 6. timing結果

| timing stage | achievable frequency |
|---|---:|
| EDIF parse直後 | 5.358 MHz |
| pre-LUT-packing | 5.358 MHz |
| design-rule packing後の再計算 | 5.358 MHz |
| post-LUT-packing | 11.324 MHz |
| post-placement | 取得不能 |
| post-route | 取得不能 |

制約は50 MHz（20.000 ns）である。post-LUT-packing推定11.324 MHzは約88.308 ns相当で、制約を満たす値ではない。ただし配置前推定のため、最終slackとして扱うことはできない。またtoolは各packing timing計算時にSDC parsing warningを1件報告したが、失敗runの一時directoryが保持されなかったため、個別warning messageは成果物に残っていない。

## 7. router結果

placement失敗後にclock-tree routingとdetailed routingの入口までは進み、`Running router version 0.`が記録された。しかし有効なplacementが存在しないため、直後に`FPGA P&R Error`、`Abnormal Exit due to errors`、exit code 3となった。正常完了したroute、post-route timing、route utilizationはない。

## 8. 成果物

| file | 内容 |
|---|---|
| `compact_v3/pnr_gui_project/forge_bitstream_log.txt` | placer/routerを含むForgeFPGA全ログ |
| `compact_v3/pnr_gui_project/pnr_summary.json` | machine-readableな結果要約 |
| `compact_v3/pnr_gui_project/automation_result.json` | 実行時刻、完了検出、bitstream未生成の記録 |
| `compact_v3/pnr_gui_project/abc471e_narrow_pnr.ffpga` | PNR専用project設定 |
| `compact_v3/run_forge_gui_pnr.ps1` | GUI通常flowの実行・ログ保存automation |

全ログのSHA-256は`36dd17f6ca96c8f98d126398ad1571bcf3a7436d2a1e159f0295d889f0e05161`である。

## 9. 保護対象と停止点

RTL変更、cleanup追加、WIDTH変更、SPEC/IMPL変更は行っていない。終了時の主要ハッシュは次のとおりで、開始時および前WORKのfinalと一致した。

| file | SHA-256 |
|---|---|
| `compact_v3/main.v` | `e910abcf293fc37fbb071eef5cfad4eb91b0047263b512707278360032716fc6` |
| `compact_v3/spi_target.v` | `62946ac3e2f0b16bd11fbf3411454496d02b44fe9db516d2ec63c9ec157d5463` |
| `compact_v3/compact_v3_tb.v` | `284816166ae993c154c2c9f97119e53cff4286c19d55925fa759cfd376c9c094` |
| `SPEC_abc471e_narrow_2.md` | `7118a63b5a1e39c39439deacf1ea221ed002d7f0c58f128685dad887e53384fa` |
| `IMPL_abc471e_narrow_3.md` | `a89649f753d0bbe8bfeb098d2371525bba99a648f28a25de7d26fe0b440f1fd0` |

WORK指定どおり、失敗stage、Type=L必要数、placer診断、主要resource/packing情報を記録し、bitstream生成・flash・実機試験へ進まず停止する。
