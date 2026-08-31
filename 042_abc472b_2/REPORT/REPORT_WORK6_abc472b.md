# REPORT WORK6 ABC472B

## 結論

WORK5の実機誤答は、入力組立やDistRAM内容の破壊ではなく、productionの
`CALC_READ`直後に`CALC_EVALUATE`していた物理DistRAM read-to-CALC境界の
settle/latency margin不足だった。

実機readbackでは`[100, 1, 1]`、`total=102`を毎回正しく観測した一方、
readとevaluateの間に1clockの`CALC_WAIT`を入れた2つの独立bitstreamは、
いずれもWORK5と同じ112件を全PASSした。最終productionへ同じ最小修正を反映し、
37.5 MHzでIcarus、Synth、DistRAM推論、PNR、Timing、bitstream、Eドライブ配置、
Shrike-Lite flash、Thonny実機試験まで完了した。

最終実機結果:

```text
WORK5_DONE PLAN=ALL PASS=112 FAIL=0 TOTAL=112 RESULT=PASS
```

## 開始条件

WORK5の37.5 MHz production bitstreamでは次の結果だった。

```text
PASS=20 FAIL=92 TOTAL=112
```

最優先case `best_at_first_cut = [100, 1, 1]`、expected 98は、reset有無と
input/answer SPI 2/4 MHzの全条件でFAILした。代表PASS caseは同条件でPASSし、
112件すべてのraw MISO dummyは`0x00`だった。

## production baseline保全

開始時に次をhash確認し、`debug_work6/baseline/`へ保全した。

| 対象 | WORK4/WORK5 baseline SHA-256 |
|---|---|
| `ffpga/src/main.v` | `240FE028D7CDD843FFB63E4110594C15DE2CB4DBD388E042049060BBE0621E0D` |
| `ffpga/src/spi_target.v` | `0F54A32D10C18DA29C352BD1981231BBF82B075E2E31F5593263D41A72778E02` |
| `abc472b.ffpga` | `EE4860FC97C68F8AC605598FC8EFA956AD20D87A323649974BD4CF121BAE5E4E` |
| SDC | `30B2D21AFB49B1104905E11AB29A002092756D013CA7A236DC592D1DE7C7C798` |
| `firmware/micropython/abc472b_test.py` | `759DD35D564E4823371F92D68CE277F13A282BF958AD78E0393FD364072B6CC3` |
| 37.5 MHz production MCU bitstream | `00C1CE6912B2CF64FEF6CE3E5C25558FDF1128A1377504093E7636CAA0C8BDEB` |

開始時のworkspace build、`bitstream/abc472b.bin`、`E:\abc472b.bin`は同じ
baseline bitstream hash、サイズ46408 byteだった。

## Eドライブ確認

開始時と各コピー前にEドライブを確認した。

- Device: `E:`
- DriveType: Removable (`2`)
- FileSystem: FAT
- Size: 1,417,216 byte
- 既存`E:\abc472b.bin`がWORK4/WORK5 baseline hashと一致

この情報と既存Shrike/ABC472Bファイルから対象のShrike-Lite用USBストレージと判断した。
format、partition変更、無関係ファイル削除は行っていない。

## 実験一覧

| Exp | 目的・変更 | Build | 実機結果 | 解釈 |
|---|---|---|---|---|
| 01 | 3入力をshadow FFへ保持し、同じ128x17 DistRAMを全アドレスscanして先頭3値とtotalをtelemetry返却。CALCは除外 | Icarus PASS、RAM64X1D x34、Timing PASS | 20/20 PASS | 入力組立、write、基本readback、totalは正常 |
| 02 | production CALCが消費する2 read値、total、prefix、answerを19-byte telemetry | Icarus/Synth PASS、RAM64X1D x34、731 cells。PNRは723.9秒で未完了 | 未実施 | 観測回路が重く、仮説判定不能 |
| 02b | 既存answer registerを使う16個の比較flagへ縮小 | Icarus/Synth PASS、RAM64X1D x34、669 cells。PNR FAIL | 未実施 | 観測回路追加によるgeometry不足。仮説否定ではない |
| 03 | 通常4-byte回答を維持し、`CALC_READ`と`CALC_EVALUATE`間へ1clock WAITだけ追加 | Icarus、Synth、PNR、Timing PASS | 112/112 PASS | read-to-CALC境界が決定要因 |

Exp02bではForgeFPGA Workshop画面に次が明示されたため、timeoutを待たず停止した。

```text
FATAL ERROR: The design cannot fit into the current geometry.
PnR failed
```

これは観測回路を追加した設計の面積/geometry FAILであり、CALC比較結果のFAILではない。
以後の自動化には`FATAL ERROR`、`cannot fit`、`PnR failed`の即時検出を追加した。

## Exp01: 決定的な内部観測

TelemetryはV3 dummyに続く26-byte payloadとした。

```text
00 | A6 01 N COUNT BYTE_INDEX |
shadow0 shadow1 shadow2 | ram0 ram1 ram2 | total
```

`[100, 1, 1]`をresetなし10回、毎回reset 10回実行し、全20回で次を観測した。

```text
N=3
COUNT=3
BYTE_INDEX=0
SHADOW=100,1,1
RAM=100,1,1
TOTAL=102
```

- Icarus: `EXP01_SIM_PASS RUNS=2`
- DistRAM: `RAM64X1D x34`
- Resource: CLB 110/140、distributed-memory LUT5 272
- Timing: WNS +12.216 ns、TNS 0、Achievable 69.204 MHz
- MCU bitstream SHA-256:
  `A96E351B17939D9FCD74B03714EEF5EAC7DCDA365EA551D36E0DFA2D95ACAFC1`
- 実機: `PASS=20 FAIL=0`

従って、WORK5誤答の主因から3byte入力組立、DistRAM write、格納内容、基本readback、
`total_sum`を除外できた。

## Exp03: 原因特定

Exp01後の最小仮説として、production datapathと4-byte回答を維持したまま、
同期DistRAM readとCALC evaluateの間へ1clockの待機stateを追加した。
新しいtelemetry FFは追加していない。

- Icarus: 524 cases PASS、最優先case answer 98
- CALC clocks: `3 * (N - 1)`、最大297 clocks = 7.92 us @ 37.5 MHz
- Synth: 641 cells、`RAM64X1D x34`
- Resource: CLB 137/140、distributed-memory LUT5 272
- Timing: WNS +0.502 ns、TNS 0、Achievable 38.220 MHz
- MCU bitstream SHA-256:
  `8CFA9033E7200EF046CB9DAADB1D94B5BCDAF9602D3368A8CD3983FE3A020CF1`
- 実機: `PASS=112 FAIL=0 TOTAL=112`
- raw dummy異常: 0/112
- 最優先case raw: 全条件で`00:00:00:62`

Exp03は`CALC_WAIT=3 / ANSWER_READY=4`だった。最終productionでは既存の
`ANSWER_READY=3`を維持し`CALC_WAIT=4`としたため、両者は別Synth/PNR、別配置、
別bitstreamである。それでも双方が112/112 PASSしたことから、単一の偶然の配置ではなく、
read値をevaluate前に追加1clock保持することが決定要因と判断した。

## 原因

behavioral RTLの同期readモデルでは`CALC_READ`の次clockに値を利用できるが、
高密度なproduction配置で実DistRAM出力を24-bit加減算/絶対差回路へ直結して
直後の`CALC_EVALUATE`で取り込む構成は、実機上のsettle/latency marginが不足していた。

DistRAMの内容自体はExp01で正しく、SPI速度を2 MHzへ落としても元bitstreamの誤答は
変わらなかった。したがって原因は17-bit modulo、SPI burst境界、単純なSPI速度margin、
reset残留ではなく、DistRAM read値からCALC評価への物理境界である。

その物理境界の内訳が、primitiveの実効read latencyと、STAへ十分現れない
RAM-output-to-CALC settle marginのどちらであるかは、Exp02/02bがgeometryに収まらず
内部CALC値を実機観測できなかったため分離していない。ただし設計上の故障条件と
必要な修正は、異なる2つのWAIT付きbitstreamの全PASSで確定した。

## production最小修正

`ffpga/src/main.v`へ次だけを機能変更した。

- 既存`ANSWER_READY=3`を維持
- 空きstate値`CALC_WAIT=4`を追加
- `CALC_READ -> CALC_WAIT -> CALC_EVALUATE`へ変更
- コメントを3-state CALCに更新

演算幅、DistRAM宣言、SPI V3 protocol、PLL、SDC、MicroPython production codeは変更していない。

| 対象 | 最終 SHA-256 |
|---|---|
| `ffpga/src/main.v` | `36CA34656AB23CDF491EB089499B498F483874057751C27A6EED72ED934C1915` |
| `abc472b.ffpga` | `23B94BD428392DF5A61DC2A8B0408AB75DA1D9DD3A49F8E7B861C6A093471E2E` |
| `ffpga/src/spi_target.v` | `0F54A32D10C18DA29C352BD1981231BBF82B075E2E31F5593263D41A72778E02` |
| SDC | `30B2D21AFB49B1104905E11AB29A002092756D013CA7A236DC592D1DE7C7C798` |
| production MicroPython | `759DD35D564E4823371F92D68CE277F13A282BF958AD78E0393FD364072B6CC3` |

`sim/tb_abc472b.v`はCALC state観測と期待clock数を`3 * (N - 1)`へ更新した。
既存firmwareの10 us待機に対し最大CALCは7.92 usなのでfirmware変更は不要だった。

## production検証

### Icarus

```text
SUMMARY PASS cases=524 random=512 failures=0 max_calc_clocks=297
```

明示12ケースとdeterministic random 512ケースを含む全524ケースがPASSした。

### Synth / DistRAM

- Synth: PASS、640 cells
- `RAM64X1D`: 34 instances
- CARRY4 42、FDCE 144、FDPE 29、FDRE 17
- `mem_ram [127:0]`は大量FF化せず従来どおりDistRAM / Type=M相当を維持
- distributed-memory LUT5: 272、Type=M相当 34/40

### PNR / Resource / Timing

37.5 MHz、SDC 26,667 psでPASSした。

| 項目 | 最終production |
|---|---:|
| CLB LUT5 | 737 / 1120 (65.80%) |
| distributed-memory LUT5 | 272 (85.00%) |
| FF total | 190 |
| CLB | 131 / 140 (93.57%) |
| 4k BRAM | 0 / 8 |
| WNS | +2.648 ns |
| TNS | 0 ns |
| TNS endpoints | 0 |
| Achievable period | 24.018 ns |
| Achievable frequency | 41.635 MHz |

ForgeFPGA自動操作はSynth、PNR、bitstream生成、Save All、最終UI captureまで成功した。
`abc472b.ffpga`と`ffpga/build/`を開くことで結果を再確認できる状態を保存した。

### bitstream

最終MCU bitstream:

```text
size    46408 byte
SHA256  4BCBCBC4DBF0B3C678BE398A31710464C509A81A581DBE98D08282A5758F49A4
```

次の3箇所は同じhashで一致する。

- `ffpga/build/bitstream/FPGA_bitstream_MCU.bin`
- `bitstream/abc472b.bin`
- `E:\abc472b.bin`

旧production MCU bitstreamは`debug_work6/baseline/bitstream/abc472b.bin`から復元可能である。

## 最終実機試験

WORK5の同じ112件ランナーを再利用し、`E:\abc472b.bin`を
`shrike.flash("abc472b.bin")`で書き込んだ。

```text
WORK5_DONE PLAN=ALL PASS=112 FAIL=0 TOTAL=112 RESULT=PASS
```

- resetなし連続20回: 20/20 PASS
- 毎回reset 20回: 20/20 PASS
- 最優先case、input/answer 4/4、2/4、4/2、2/2 MHz: 各10/10 PASS
- FAIL代表3件とPASS代表5件、全4速度条件: 全PASS
- raw dummy: 112/112で`0x00`
- 最優先case raw: `00:00:00:62`、answer 98

ログ: `debug_work6/logs/thonny_production_fixed.txt`

```text
SHA256 9051ED805A1816ADB0BD8F198971E6D78FB64B8C91BF7E3DA96FFA2F21EE0085
```

## 自動化結果

| 項目 | 結果 |
|---|---|
| ForgeFPGA Synth GUI自動化 | 成功 |
| ForgeFPGA PNR/Timing/bitstream GUI自動化 | 成功 |
| 明確なPNR fatalの即時検出 | 共通scriptへ追加済み |
| Eドライブ識別・hash検査 | 成功 |
| debug bitstreamのEドライブコピー | Exp01/Exp03とも成功 |
| production bitstreamのEドライブ更新 | 成功、source/destination hash一致 |
| `shrike.flash()`自動化 | Exp01/Exp03/final productionで成功 |
| Thonny script open / F5 | 成功 |
| Thonny Shell回収 | 成功 |
| COM6排他 | Thonny backendのみ使用し、直接COM6を同時openしていない |

## Eドライブ最終配置

| ファイル | SHA-256 |
|---|---|
| `E:\abc472b.bin` | `4BCBCBC4DBF0B3C678BE398A31710464C509A81A581DBE98D08282A5758F49A4` |
| `E:\abc472b_debug_work6_exp01.bin` | `A96E351B17939D9FCD74B03714EEF5EAC7DCDA365EA551D36E0DFA2D95ACAFC1` |
| `E:\abc472b_debug_work6_exp03.bin` | `8CFA9033E7200EF046CB9DAADB1D94B5BCDAF9602D3368A8CD3983FE3A020CF1` |

debug MicroPythonもExp01/Exp03用名称でEドライブへコピー済みである。

## 主な変更・作成ファイル

production変更:

- `ffpga/src/main.v`: `CALC_WAIT` 1clock追加
- `sim/tb_abc472b.v`: 3-state CALCの期待値へ更新
- `scripts/run_forge_bitstream.ps1`: 明確なfatalの即時検出
- `abc472b.ffpga`: 最終Synth/PNR/GUI状態をSave All
- `bitstream/abc472b.bin`: 修正後production bitstream
- `ffpga/build/`, `logs/`: 最終ForgeFPGA成果物と自動化ログ

debug/記録:

- `debug_work6/baseline/`
- `debug_work6/exp01_ram_shadow/`
- `debug_work6/exp02_calc_trace/`
- `debug_work6/exp02b_calc_flags/`
- `debug_work6/exp03_ram_read_wait/`
- `debug_work6/run_thonny_work6.ps1`
- `debug_work6/logs/thonny_production_fixed.txt`
- `REPORT_WORK6_abc472b.md`

変更していないproduction対象:

- `ffpga/src/spi_target.v`
- `ffpga/timing-constraints/atcoder_spi_template_v3.sdc`
- `firmware/micropython/abc472b_test.py`
- `firmware/micropython/abc472b_debug_work5.py`
- `REF/`

## 未実施項目

- AtCoder提出
- Git push/tag/releaseを含むGit操作
- 他プロジェクト変更
- OS恒久設定変更
- PLL/周波数/SDC変更
- Exp02/Exp02bの実機書き込み（PNR未完了/geometry FAILのためbitstreamなし）

WORK6の原因特定、最小production修正、全検証は完了している。次に必要なのは、
必要に応じたユーザー判断によるAtCoder提出または成果物管理であり、今回の範囲では行わない。
