# REPORT WORK7 ABC472B

## 結論

最終productionを変更せず、実機112件回帰とN=100最大ケースの20回benchmarkを
Thonnyから全自動実行した。実機Runはretryなしで2回だけであり、両方のShell標準出力を
SEQ付き一次ログと固定名ログへ無改変で保存した。

- Final regression: `PASS=112 FAIL=0 TOTAL=112`
- Benchmark: 20/20 answers PASS
- MIN: 4180 us
- AVG: 4223.1 us
- MAX: 4728 us
- production MCU bitstream SHA-256:
  `4BCBCBC4DBF0B3C678BE398A31710464C509A81A581DBE98D08282A5758F49A4`

## 最終production hash確認

WORK7開始時に次の3ファイルを確認した。すべて46408 byteで、指定された最終production
SHA-256と一致したため実機試験へ進んだ。Eドライブへの再コピーは行っていない。

| 対象 | SHA-256 |
|---|---|
| `ffpga/build/bitstream/FPGA_bitstream_MCU.bin` | `4BCBCBC4DBF0B3C678BE398A31710464C509A81A581DBE98D08282A5758F49A4` |
| `bitstream/abc472b.bin` | `4BCBCBC4DBF0B3C678BE398A31710464C509A81A581DBE98D08282A5758F49A4` |
| `E:\abc472b.bin` | `4BCBCBC4DBF0B3C678BE398A31710464C509A81A581DBE98D08282A5758F49A4` |

EドライブはDriveType 2（Removable）、FAT、容量1,417,216 byteであり、既存の
`abc472b.bin`と合わせてShrike-Lite用USBストレージと確認した。WORK7終了時にも
`E:\abc472b.bin`の同じsize/hashを再確認した。

## 実機Run SEQ一覧

WORK7で実際にF5実行したRunは次の2回だけである。GUI操作失敗、誤Run、retryはない。

| SEQ | 目的 | スクリプト | 結果 | 一次ログ | 固定名ログ |
|---|---|---|---|---|---|
| WORK7_SEQ01 | 最終production 112件回帰 | `abc472b_debug_work5.py` | 112/112 PASS | `hardware_logs/WORK7_SEQ01.log` | `hardware_logs/hardware_log_abc472b_final.log` |
| WORK7_SEQ02 | N=100処理時間20回測定 | `abc472b_benchmark.py` | 20/20 PASS | `hardware_logs/WORK7_SEQ02.log` | `hardware_logs/hardware_log_abc472b_benchmark.log` |

固定名ログは対応するSEQログを`Copy-Item`で複製した。実際のThonny Shell出力は
要約・ヘッダ追加・編集をしていない。

| SEQ / 固定名 | size | SHA-256 |
|---|---:|---|
| `WORK7_SEQ01.log` | 25528 | `9051ED805A1816ADB0BD8F198971E6D78FB64B8C91BF7E3DA96FFA2F21EE0085` |
| `hardware_log_abc472b_final.log` | 25528 | `9051ED805A1816ADB0BD8F198971E6D78FB64B8C91BF7E3DA96FFA2F21EE0085` |
| `WORK7_SEQ02.log` | 1661 | `4C187F103775F30D603CEA9CBCE1389631C2DB08FFAE2891E8E10C57B66CE65E` |
| `hardware_log_abc472b_benchmark.log` | 1661 | `4C187F103775F30D603CEA9CBCE1389631C2DB08FFAE2891E8E10C57B66CE65E` |

## WORK7_SEQ01: final hardware test

WORK5/WORK6で確立した112件runnerを再利用した。runnerは`abc472b.bin`を
`shrike.flash()`してから、reset有無、input/answer SPI 2/4 MHz、FAIL/PASS代表caseを
実行した。

```text
WORK5_DONE PLAN=ALL PASS=112 FAIL=0 TOTAL=112 RESULT=PASS
```

監査結果:

- `REC` record: 112
- `STATUS=FAIL`: 0
- dummy異常: 0、全112件で`DUMMY=0`
- 最優先case record: 84
- 最優先caseの全record: `RAW_RX=00:00:00:62`、result 98、PASS

一次観測:

- `hardware_logs/WORK7_SEQ01.log`
- `hardware_logs/hardware_log_abc472b_final.log`

## WORK7_SEQ02: benchmark

### 入力と実行条件

- 固定入力: `maximum_total = [100000] * 100`
- N: 100
- software oracle expected answer: 0
- input bytes: 301
- V3 input bursts: 256 + 45 byte
- answer burst: 4 byte
- SPI: 4 MHz、Mode 0
- FPGA internal clock: 37.5 MHz
- `CALC_WAIT_US`: 10 us
- 測定回数: 20
- 各run間のFPGA reset: なし
- warm-up用の測定除外run: なし。最初のrunを含む20値すべてを統計へ採用
- Timer: MicroPython `time.ticks_us()` / `time.ticks_diff()`

### 測定対象

各runのタイマ区間には次を含めた。

1. RP2040側のN範囲と100個の`L_i`範囲チェック
2. Nと`L_i`の301-byte big-endian serialize
3. SPI input transfer（256 + 45 byte）
4. `time.sleep_us(10)`
5. 4-byte answer read burstとdummy確認
6. 24-bit big-endian answer組立

### 測定対象外

次はタイマ開始前、または全測定終了後に実行した。

- `shrike.flash()`
- FPGA reset
- SPI object生成・初期化
- `[100000] * 100`のcase生成
- software oracle計算
- 経過時間配列の確保
- answerとexpectedの比較
- 全print出力

ABC472Bの回答計算はFPGAで行い、RP2040のsoftware計算は期待値oracleだけに使用した。

### 測定結果

20回すべてanswer 0、expected 0、PASSだった。

```text
BENCHMARK N=100 RUNS=20
MIN_US=4180
AVG_US=4223.1
MAX_US=4728
RESULT=PASS
```

各runの実測値（us）:

```text
4728, 4203, 4181, 4198, 4198,
4180, 4180, 4198, 4203, 4201,
4200, 4184, 4204, 4186, 4207,
4193, 4196, 4212, 4197, 4213
```

Shellが出力したMIN/AVG/MAXは、ログ中の20値からPowerShellで独立再計算した
4180 / 4223.1 / 4728 usと一致した。

一次観測:

- `hardware_logs/WORK7_SEQ02.log`
- `hardware_logs/hardware_log_abc472b_benchmark.log`

## Thonny自動実行

WORK6の`debug_work6/run_thonny_work6.ps1`を再利用し、両SEQで次を人間操作なしに
完了した。

```text
script open
F5
Shrike-Lite flash
実機処理
Shell全選択・copy
log保存
```

COM6はThonny backendだけが使用し、別プロセスから同時openしていない。

## production変更なしの確認

WORK7終了時に次のhashを開始時/WORK6確定値と比較し、すべて一致した。

| production対象 | SHA-256 |
|---|---|
| `ffpga/src/main.v` | `36CA34656AB23CDF491EB089499B498F483874057751C27A6EED72ED934C1915` |
| `ffpga/src/spi_target.v` | `0F54A32D10C18DA29C352BD1981231BBF82B075E2E31F5593263D41A72778E02` |
| `abc472b.ffpga` | `23B94BD428392DF5A61DC2A8B0408AB75DA1D9DD3A49F8E7B861C6A093471E2E` |
| SDC | `30B2D21AFB49B1104905E11AB29A002092756D013CA7A236DC592D1DE7C7C798` |
| `firmware/micropython/abc472b_test.py` | `759DD35D564E4823371F92D68CE277F13A282BF958AD78E0393FD364072B6CC3` |
| production MCU bitstream | `4BCBCBC4DBF0B3C678BE398A31710464C509A81A581DBE98D08282A5758F49A4` |

RTL、SPI V3、FFPGA、PLL/SDC、production MicroPython、production bitstream、REFは
変更していない。

## 作成ファイル

- `firmware/micropython/abc472b_benchmark.py`
  - benchmark専用、SHA-256
    `B8DFE507F15CAC5C8491EE62329D8C5A4A9572E852BE9D64D46509237A4C1940`
- `hardware_logs/WORK7_SEQ01.log`
- `hardware_logs/hardware_log_abc472b_final.log`
- `hardware_logs/WORK7_SEQ02.log`
- `hardware_logs/hardware_log_abc472b_benchmark.log`
- `REPORT_WORK7_abc472b.md`

## 未実施項目

WORK7の目的に不要であり、指示どおり次は実施していない。

- RTL / SPI V3 / FFPGA / PLL / SDC変更
- production MicroPython / production bitstream変更
- Synth / PNR / bitstream再生成
- Eドライブへのbitstream再コピー
- AtCoder提出
- Git操作
- 他プロジェクト変更

WORK7の完了条件をすべて満たしている。
