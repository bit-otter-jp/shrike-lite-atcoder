# ABC472B Shrike-Lite - Qiita 第41回

Qiita連載「Shrike-LiteでAtCoder問題を解く(41)：ABC472B 前編」に対応する、WORK4終了時点のsnapshotです。

## WORK4時点の結果

- Icarus: 524/524 PASS
- DistRAM: RAM64X1D x34
- FPGA clock: 37.5 MHz
- SPI: 4 MHz
- Timing: PASS
- WNS: +1.343 ns
- TNS: 0
- Achievable Frequency: 39.490 MHz
- CLB: 134/140
- CALC: max 198 clocks / 5.28 us（`2 * (N - 1)`）

## 重要な注意

この版はTiming PASS版としてWORK4で生成され、WORK4終了時点では実機未試験でした。その後、同じbitstreamを使ったShrike-Lite実機19件試験で `PASS=16 / FAIL=3 / TOTAL=19` となりました。

代表的なFAILは次のcaseです。

```text
best_at_first_cut
N = 3
L = [100, 1, 1]
expected = 98
result = 7573991
```

この初回19件Runのraw Shell logは保存されていません。詳細な再現試験、原因調査、および `CALC_WAIT` を追加した修正版はQiita第42回で扱います。本snapshotには第42回の最終productionを収録していません。

## WORK4 baseline SHA-256

| ファイル | SHA-256 |
|---|---|
| `abc472b.ffpga` | `EE4860FC97C68F8AC605598FC8EFA956AD20D87A323649974BD4CF121BAE5E4E` |
| `ffpga/src/main.v` | `240FE028D7CDD843FFB63E4110594C15DE2CB4DBD388E042049060BBE0621E0D` |
| `ffpga/src/spi_target.v` | `0F54A32D10C18DA29C352BD1981231BBF82B075E2E31F5593263D41A72778E02` |
| `ffpga/timing-constraints/atcoder_spi_template_v3.sdc` | `30B2D21AFB49B1104905E11AB29A002092756D013CA7A236DC592D1DE7C7C798` |
| `firmware/micropython/abc472b_test.py` | `759DD35D564E4823371F92D68CE277F13A282BF958AD78E0393FD364072B6CC3` |
| `bitstream/abc472b.bin` | `00C1CE6912B2CF64FEF6CE3E5C25558FDF1128A1377504093E7636CAA0C8BDEB` |

主要6ファイルは、WORK6開始時に保存された `debug_work6/baseline/` の実物からコピーし、上記hashとの一致を確認しています。

## 収録内容

- `abc472b.ffpga`, `ffpga/`: WORK4版project、RTL、37.5 MHz用SDC
- `bitstream/abc472b.bin`: WORK4版37.5 MHz MCU bitstream
- `firmware/micropython/abc472b_test.py`: WORK4 baselineの実機test script
- `sim/run_iverilog.ps1`: WORK1以降変更されていないIcarus実行script
- `WORK/`: WORK1～WORK4仕様と対応するCODEX_PROMPT
- `REPORT/`: WORK1～WORK4結果report
- `REF/`: 参照資料実体は重複収録していません

実装工程を再現する場合は `REF/README.md` を参照し、GitHub公開リポジトリ内の既存公開物から必要なREFをコピーしてください。

## 未収録

- `sim/tb_abc472b.v`: 正確なWORK4の198-clock版が保存物から見つからなかったため未収録です。現行の297-clock版を改変・推測復元していません。そのため、収録した `run_iverilog.ps1` はこのsnapshot単体では実行できません。
- `ffpga/build/`: WORK4時点の完全なbuild成果物が保存されておらず、現行buildはWORK6版であるため未収録です。公開準備のためのSynth / PNR / bitstream再生成は行っていません。
- 初回実機19件のraw Shell log: 保存されていないため未収録です。
- WORK5以降の資料、debug runner、benchmark、実機log: 第42回側の内容のため未収録です。
