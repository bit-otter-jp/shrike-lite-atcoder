# ABC472B Shrike-Lite - Qiita 第42回

第41回でTiming PASSしたものの実機FAILした版を、WORK5～WORK7で原因切り分け・修正した後編の公開用成果物です。

- 問題範囲: DistRAM read → CALC境界
- 修正: `CALC_READ → CALC_WAIT → CALC_EVALUATE`
- FPGA clock: 37.5 MHz
- SPI: 4 MHz

前編のWORK1～4とWORK4 baselineは、[`../041_abc472b_1/`](../041_abc472b_1/)を参照してください。このフォルダには第41回のsource、bitstream、WORK1～4、共通REFを重複収録していません。

## 最終結果

```text
Icarus          : 524/524 PASS
DistRAM         : RAM64X1D x34
CLB LUT5        : 737 / 1120
FF              : 190
CLB             : 131 / 140
BRAM            : 0 / 8
FPGA clock      : 37.5 MHz
WNS             : +2.648 ns
TNS             : 0
Achievable      : 41.635 MHz
CALC max        : 297 clocks / 7.92 us
Hardware        : 112/112 PASS
```

最大ケースbenchmark:

```text
N               : 100
L_i             : [100000] * 100
SPI input       : 301 byte = 256 + 45
Runs            : 20
MIN             : 4180 us
AVG             : 4223.1 us
MAX             : 4728 us
RESULT          : PASS
```

## 最終production

`ffpga/`、`abc472b.ffpga`、`bitstream/`、`firmware/micropython/abc472b_test.py`、`sim/`は最終production系です。`debug/`以下のRTL、プロジェクト、bitstreamは原因調査専用であり、productionではありません。

| ファイル | SHA-256 |
|---|---|
| `ffpga/src/main.v` | `36CA34656AB23CDF491EB089499B498F483874057751C27A6EED72ED934C1915` |
| `ffpga/src/spi_target.v` | `0F54A32D10C18DA29C352BD1981231BBF82B075E2E31F5593263D41A72778E02` |
| `abc472b.ffpga` | `23B94BD428392DF5A61DC2A8B0408AB75DA1D9DD3A49F8E7B861C6A093471E2E` |
| `ffpga/timing-constraints/atcoder_spi_template_v3.sdc` | `30B2D21AFB49B1104905E11AB29A002092756D013CA7A236DC592D1DE7C7C798` |
| `firmware/micropython/abc472b_test.py` | `759DD35D564E4823371F92D68CE277F13A282BF958AD78E0393FD364072B6CC3` |
| `bitstream/abc472b.bin` | `4BCBCBC4DBF0B3C678BE398A31710464C509A81A581DBE98D08282A5758F49A4` |
| `firmware/micropython/abc472b_benchmark.py` | `B8DFE507F15CAC5C8491EE62329D8C5A4A9572E852BE9D64D46509237A4C1940` |

最終`main.v`は1 clockの`CALC_WAIT`を含みます。`sim/tb_abc472b.v`はCALC clock数を`3 * (N - 1)`、最大297 clocksとして検証する524-case版です。

## 実機debug証拠

### WORK5

- debug runner: `firmware/micropython/abc472b_debug_work5.py`
- raw Thonny Shell log: `debug/WORK5/thonny_work5_all.txt`

このrunnerはreset有無、input/answer SPI 2/4 MHz、112件比較に使用したものです。raw logにはbaselineの`PASS=20 FAIL=92 TOTAL=112`と、`best_at_first_cut = [100,1,1]`が全条件でFAILした記録が含まれます。

### WORK6

- Exp01: `debug/WORK6/Exp01/`
  - shadow FF、DistRAM readback、`total_sum`の実機観測
  - raw log: `logs/thonny_exp01.txt`
  - debug bitstream SHA-256: `A96E351B17939D9FCD74B03714EEF5EAC7DCDA365EA551D36E0DFA2D95ACAFC1`
  - 結果: `SHADOW=100,1,1`、`RAM=100,1,1`、`TOTAL=102`、20/20 PASS
- Exp02: `debug/WORK6/Exp02/`
  - PNR timeoutの小規模status/resultと実験要約だけを収録
- Exp02b: `debug/WORK6/Exp02b/EXPERIMENT.md`
  - `FATAL ERROR: The design cannot fit into the current geometry.` / `PnR failed`の保存済み要約
- Exp03: `debug/WORK6/Exp03/`
  - 1 clock WAITのRTL、test script、raw log、summary、debug bitstream
  - debug bitstream SHA-256: `8CFA9033E7200EF046CB9DAADB1D94B5BCDAF9602D3368A8CD3983FE3A020CF1`
  - 結果: 112/112 PASS

WORK6の最終production raw logは`debug_work6/logs/thonny_production_fixed.txt`とWORK7 SEQ01が同一内容・同一SHA-256のため、公開フォルダ内では`hardware_logs/WORK7_SEQ01.log`および固定名logへ整理しています。

### WORK7

| 用途 | ファイル | SHA-256 |
|---|---|---|
| 最終112件回帰 | `hardware_logs/WORK7_SEQ01.log` | `9051ED805A1816ADB0BD8F198971E6D78FB64B8C91BF7E3DA96FFA2F21EE0085` |
| 最終112件回帰・固定名 | `hardware_logs/hardware_log_abc472b_final.log` | `9051ED805A1816ADB0BD8F198971E6D78FB64B8C91BF7E3DA96FFA2F21EE0085` |
| 最大ケースbenchmark | `hardware_logs/WORK7_SEQ02.log` | `4C187F103775F30D603CEA9CBCE1389631C2DB08FFAE2891E8E10C57B66CE65E` |
| benchmark・固定名 | `hardware_logs/hardware_log_abc472b_benchmark.log` | `4C187F103775F30D603CEA9CBCE1389631C2DB08FFAE2891E8E10C57B66CE65E` |

SEQ logと対応する固定名logは同一内容・同一hashです。raw logは改変せずコピーしています。

## フォルダ構成

| パス | 役割 |
|---|---|
| `ffpga/`, `abc472b.ffpga` | 最終production RTL、SDC、ForgeFPGA project |
| `bitstream/` | 最終production MCU bitstream |
| `firmware/micropython/` | production test、WORK5 debug runner、benchmark |
| `sim/` | 最終297-clock / 524-case simulation sourceとrunner |
| `hardware_logs/` | WORK7の最終回帰・benchmark raw log |
| `debug/WORK5/` | WORK5のbaseline failure一次資料 |
| `debug/WORK6/` | Exp01～Exp03の原因調査資料。productionとは別物 |
| `WORK/` | WORK5～7と対応するCODEX_PROMPT |
| `REPORT/` | WORK5～7の作業REPORT |
| `REF/` | 第41回baselineと共通REFへの案内のみ |

## 未収録項目

- 第41回のsource、旧bitstream、WORK1～4、共通REF: `../041_abc472b_1/`に公開済みのため
- `ffpga/build/`一式: 430ファイル、107,008,545 byteの巨大な中間生成物であり、source、project、SDC、最終bitstream、REPORT、raw logで公開目的を満たすため
- Exp01/Exp03の巨大な中間buildとGUI dump: 再現に必要な最小成果物だけを収録したため
- Exp02bの独立したfinal fatal raw log: 保存されておらず、存在する`EXPERIMENT.md`と`REPORT/REPORT_WORK6_abc472b.md`のみを収録。再生成・推測復元はしていません
- WORK6 final logのdebug側重複コピー: WORK7 SEQ01および固定名logと同一内容・同一hashのため

追加REFの扱いは[`REF/README.md`](REF/README.md)を参照してください。
