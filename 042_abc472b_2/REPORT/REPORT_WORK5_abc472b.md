# ABC472B Shrike-Lite WORK5 デバッグレポート

## 結論

37.5 MHz Timing PASS済みbitstreamを使い、ThonnyからWORK5専用ランナーを自動実行した。最優先case `best_at_first_cut = [100, 1, 1]` はreset有無にかかわらず再現し、入力・回答の両方を2 MHzへ下げてもFAILした。

- A1（最初だけreset）: 0 PASS / 20 FAIL
- A2（毎回reset）: 0 PASS / 20 FAIL
- B1～B4: 各0 PASS / 10 FAIL
- 代表case C: 20 PASS / 12 FAIL、初回のFAIL 3件だけが全速度条件で再現
- 全実行: `PASS=20 FAIL=92 TOTAL=112 RESULT=FAIL`
- 4byte応答のdummyは全112件で `0x00`
- 2 MHzでも改善しないため、単純な入力SPIまたは回答SPIの速度marginだけでは説明できない

外部SPI試験だけでは入力組立、DistRAM write/read、CALC FSMを分離できないため、WORK5の停止条件どおりproduction RTLへdebug回路を追加せず停止した。次WORKでは専用debug RTL / telemetryの仕様決定が必要である。

## 目的と既知の初回結果

目的はproduction RTLを直す前に、実機FAILの発生領域を切り分けることである。37.5 MHz FPGA / SPI 4 MHzの初回19件は次の結果だった。

```text
SUMMARY PASS=16 FAIL=3 TOTAL=19 RESULT=FAIL
```

| Case | N | Input bytes / bursts | Result | Expected |
|---|---:|---:|---:|---:|
| `best_at_first_cut` | 3 | 10 / 1 | 7573991 | 98 |
| `burst_boundary_259` | 86 | 259 / 2 | 1737 | 1001 |
| `deterministic_random_100` | 100 | 301 / 2 | 76912 | 11636 |

`best_at_first_cut`はN=3、10byte、1 burst、値も `[100, 1, 1]` と小さい。このcase単独でFAILすれば256byte境界、大規模入力、17bit範囲超過を除外できるため最優先とした。

## 開始時確認

以下を開始時に読み直した。

- `REPORT_WORK4_abc472b.md`
- `ffpga/src/main.v`
- `ffpga/src/spi_target.v`
- `firmware/micropython/abc472b_test.py`
- 現在使用する `abc472b.bin`

実機側作業に使われている `E:\abc472b.bin`、workspaceの `bitstream/abc472b.bin`、WORK4 buildの `ffpga/build/bitstream/FPGA_bitstream_MCU.bin` は、サイズ46408 byte、SHA-256がすべて次の値で一致した。

```text
00C1CE6912B2CF64FEF6CE3E5C25558FDF1128A1377504093E7636CAA0C8BDEB
```

したがってWORK4の37.5 MHz Timing PASS成果物との不一致はない。

## WORK5専用ランナー

`firmware/micropython/abc472b_debug_work5.py`を新規作成した。先頭の`RUN_PLAN`で `ALL / A1 / A2 / B / C / SINGLE`を選べ、`ALL`では1回の起動でA1、A2、B1～B4、代表case Cを順番に走査する。

- `machine.SPI.init()`を使って入力burstと回答burstのbaudrateを別々に設定
- `SPI.init()`が使えない場合だけ公開APIでSPI objectを再生成
- 入力はV3上限256byteで分割し、FPGA側状態は維持
- FPGA回答前の待ちはproductionと同じ10 us
- 4byte raw MISOを整数化前に保存
- software計算は期待値oracleだけに使用し、ABC472B計算は必ずFPGAで実行
- 各runを後処理しやすい単一`REC`行で表示

実行後、再利用時の完了判定用に `WORK5_BEGIN` も出力するようにした。MicroPython互換構文についてホスト側`compile()`はPASSした。

## Thonny自動操作

### 検出と接続

- 既存Thonny process PID <local-process-id>を検出
- `configuration.ini`と画面statusからinterpreterは `MicroPython (Raspberry Pi Pico)`、portはCOM6と確認
- Thonny Shellが表示され、既存の実機試験出力もあることを確認

TkのEditor / Shell内部はWindows UI Automationから無名Paneとしてしか見えなかった。一方、Thonny top-level、WindowsのOpen dialog、Thonnyの`Where to open from?` modalは識別できた。

### 自動化した範囲

1. 既存Thonnyと接続状態を検出
2. UI treeと画面を保存
3. 通常のCtrl+Oを試行。不安定な場合はF5前に停止
4. `single_instance=True`のThonny launcherへローカルscript pathを渡して既存windowへ専用runnerを開く
5. window titleが `abc472b_debug_work5.py` になったことを確認
6. F5で実行
7. 事前画像で確認したShell本文中央だけをクリックし、Shell全文をコピー
8. `debug_work5/logs/thonny_work5_all.txt`へ保存

ファイルを開く途中の失敗試行では、対象titleを確認できない限りF5へ進まないようにしたため、誤ったscriptの実行はない。最終試行では人間操作なしでrunner実行と全112件のShell回収に成功した。

実行されたeditor版には`WORK5_BEGIN`がまだなかったため、自動化wrapperの終了判定だけはexit code 1になった。ただしログにはsetup、112件すべて、section summary、最終`WORK5_DONE`が揃っており、実機結果は完全に回収できている。ローカルrunnerへ開始markerを追加済みである。2 MHz FAILの停止条件に達しているため、marker確認だけを目的とした実機再実行はしていない。

## 試験A: 再現性とreset依存

### A1: 最初に1回だけreset、20 transaction連続

```text
PASS=0 FAIL=20 TOTAL=20
```

| Raw MISO | Result | Count |
|---|---:|---:|
| `00:73:D1:E7` | 7590375 | 13 |
| `00:71:D0:E7` | 7459047 | 3 |
| `00:77:D1:E7` | 7852519 | 2 |
| `00:73:91:E7` | 7573991 | 2 |

### A2: 各case前にreset、20回

```text
PASS=0 FAIL=20 TOTAL=20
```

| Raw MISO | Result | Count |
|---|---:|---:|
| `00:73:D1:E7` | 7590375 | 13 |
| `00:77:D1:E7` | 7852519 | 7 |

resetなし・毎回resetのどちらでも20/20再現した。誤答値は一定ではなく、resetで解消しない。従って単純な「前transactionの論理レジスタがre-armされない」だけでは説明できない。DistRAM本体は仕様どおりreset対象外なので、内部read/writeや未観測addressの影響まではAだけでは除外できない。

## 試験B: 入力 / 回答SPI速度分離

対象はすべて `best_at_first_cut`、各10回である。

| Mode | Input | Answer | PASS | FAIL | 主なraw |
|---|---:|---:|---:|---:|---|
| B1 | 4 MHz | 4 MHz | 0 | 10 | `00:73:D1:E7` 8回、`00:73:D0:E7` 2回 |
| B2 | 2 MHz | 4 MHz | 0 | 10 | `00:73:D1:E7` 7回、他3回 |
| B3 | 4 MHz | 2 MHz | 0 | 10 | `00:73:D1:E7` 8回、他2回 |
| B4 | 2 MHz | 2 MHz | 0 | 10 | `00:73:D1:E7` 7回、他3回 |

- 入力だけ2 MHzにしたB2で改善しない
- 回答だけ2 MHzにしたB3で改善しない
- 両方2 MHzにしたB4でも改善しない

従ってWORK5の判定基準にある入力側だけ、回答側だけ、両側CDC marginだけのいずれにも該当しない。

## raw MISOの特徴

- 全112件で `raw[0]` dummyは `0x00`
- PASS caseは期待する `00:MSB:MID:LSB` と完全一致
- FAIL caseもraw[1:3]から組み立てた整数と表示resultが一致
- Cでは各FAIL caseのrawがB1～B4で同一
- `best_at_first_cut`のrawだけはA/Bの繰り返しで複数値へ変動

このため、4byte burstの1byte alignmentや常時のMISO bit shiftは主因とは考えにくい。rawだけでは「FPGA内部answerが既に誤っている」ことと「一部caseだけMISO値が誤る」ことを完全には分離できないが、速度非依存、dummy正常、PASS case正常という組合せから、回答SPIより内部データ経路を先に観測すべきである。

## 試験C: 代表FAIL / PASS

各caseをB1～B4で1回ずつ実行した。全4 modeで同じstatusとrawになった。

| Case | Expected | Raw / Result | B1 | B2 | B3 | B4 |
|---|---:|---|---|---|---|---|
| `best_at_first_cut` | 98 | `00:73:D1:E7` / 7590375 | FAIL | FAIL | FAIL | FAIL |
| `burst_boundary_259` | 1001 | `00:00:06:C9` / 1737 | FAIL | FAIL | FAIL | FAIL |
| `deterministic_random_100` | 11636 | `00:01:2C:70` / 76912 | FAIL | FAIL | FAIL | FAIL |
| `official_sample_1` | 2 | `00:00:00:02` / 2 | PASS | PASS | PASS | PASS |
| `best_at_last_cut` | 98 | `00:00:00:62` / 98 | PASS | PASS | PASS | PASS |
| `burst_boundary_256` | 2875 | `00:00:0B:3B` / 2875 | PASS | PASS | PASS | PASS |
| `n100_all_one` | 0 | `00:00:00:00` / 0 | PASS | PASS | PASS | PASS |
| `deterministic_random_86` | 12693 | `00:00:31:95` / 12693 | PASS | PASS | PASS | PASS |

C合計は20 PASS / 12 FAILだった。259byteのFAILだけでなく10byte・1 burstのFAILが同じ速度傾向なので、複数burst境界は共通原因ではない。

## production RTL静的確認

`ffpga/src/main.v`と`ffpga/src/spi_target.v`は変更せず読み直した。

### 入力とbit幅

- `received_length = {length_high_bytes, rx_data}`で3byte big-endian組立
- DistRAM writeは`received_length[16:0]`
- 制約上の最大L_i=100000は17bitに収まる
- CALCでは`{7'd0, lengths_read_data}`として24bitへzero extend
- `total_sum`、`prefix_sum`、`best_diff`、`answer`、加減算、絶対差は24bit

従って `[100, 1, 1]`のFAILを17bit modulo overflowで説明する根拠はない。

### write / read / CALC

- 最終L_iのwrite enableは最終byteの`rx_data_strobe`と同じclockで成立
- FSMはそのclockで`CALC_READ`へ遷移し、最初のreadは次clock
- RAM RTLはread enable時に`o_rd_data <= mem_ram[i_rd_addr]`とする同期read
- FSMは`CALC_READ`と`CALC_EVALUATE`を分離
- `prefix_after_read`、`right_after_read`、`current_diff`、`best_after_evaluate`の式は仕様どおり
- 最終候補では`answer <= best_after_evaluate`なので最後のbest更新を取り込む
- 候補数はaddress 0からN-2までのN-1件

behavioral RTL上に明白な1clock latency違反や最終候補取りこぼしは見つからなかった。

### answer / re-arm

- ANSWER_READYはdummy、MSB、MID、LSBのV3 1byte遅延sequence
- 4byte目完了後に入力counter、total、CALC、answer、reply indexを次transaction用に初期化
- DistRAM本体だけは推論維持のためresetしないが、次問題で使用する0..N-1は受信時に上書きする設計

今回の全rawでdummyが0、PASS caseの24bit値が正しいことも、このsequenceの常時破綻とは一致しない。

### 実機primitive / CDCとの差が残る箇所

- WORK4成果物は`RAM64X1D` 34個、Type=M 34/40であり、今回もその同一bitstreamを使用
- current post-synth netlistにも`RAM64X1D`が34個存在
- `spi_target`はSS/SCKを内部clockへ3段同期し、同期edgeでMOSIをsampleしてMISOをshiftするCDC構成
- ただし入力・回答とも2 MHzでFAIL patternが維持されるため、単純な4 MHz margin不足の優先度は下がる

Phase 1のIcarus SPI統合試験は524 PASS / 0 FAILで、production RTL未変更のためWORK5では再実行していない。シミュレーションの同期DistRAM modelで成立し、同じlogical caseが実機だけでFAILする点から、内部受信値、物理DistRAM write/read、CALC中間値を実機で直接観測する必要がある。

## 現時点の原因領域

最も疑わしい広い領域は、回答SPIより前の次の内部経路である。

```text
3byte入力組立
  -> DistRAM write / total_sum
  -> DistRAM read
  -> CALC FSM / prefix / diff / best / answer
```

特に2 MHzでも同じcaseだけFAILし、PASS caseは正しいrawを返すため、DistRAM write/readとCALC側を優先する。ただし外部rawだけでは、入力組立済み値が既に誤っている可能性と、DistRAMまたはCALCで誤る可能性を分離できない。A1/A2の誤答値変動もあるため、原因を特定のsignalやprimitiveへ断定していない。

## 次WORK向け内部観測候補

production RTLへは追加せず、専用debug RTL / telemetryとして次の順で観測するのがよい。

1. 受信確定時: `rx_data_strobe`、`rx_data`、`n_reg`、`length_byte_index`、`lengths_received`
2. 書込時: `received_length`、`lengths_write_enable/address/data`、更新後`total_sum`
3. CALC時: `state`、`calc_address`、`lengths_read_enable/address/data`
4. 候補評価時: `prefix_sum`、`prefix_after_read`、`right_after_read`、`current_diff`、`best_diff`、`best_after_evaluate`
5. 回答時: `answer`、`reply_byte_index`、`tx_data`
6. 上記で受信異常が出た場合だけ: SPI側の`r_ss_n_sync`、`r_sck_sync`、`r_transmision_count`、`o_rx_data_valid/strobe`

最初はN=3の固定caseだけを対象にし、各受信byte、write 3件、read/evaluate 2件を順番に取得できれば、入力・RAM・CALCの境界を小さいtraceで特定できる。

## 作成ファイルとログ

- `firmware/micropython/abc472b_debug_work5.py`: A1/A2/B/C/SINGLE runner
- `debug_work5/inspect_thonny_ui.ps1`: running ThonnyとUI treeの列挙
- `debug_work5/capture_thonny_window.ps1`: Thonny window証跡取得
- `debug_work5/run_thonny_work5.ps1`: script open、F5、Shell回収の自動化
- `debug_work5/logs/thonny_work5_all.txt`: 実機112件の全rawログ
- `debug_work5/logs/thonny_ui.txt`: 最終UI tree
- `debug_work5/logs/thonny_window.png`: `WORK5_DONE`表示を含む最終画面
- `REPORT_WORK5_abc472b.md`: 本レポート

## production変更と未実施項目

次は変更していない。開始時hashとの一致も確認した。

- `ffpga/src/main.v`
- `ffpga/src/spi_target.v`
- `abc472b.ffpga`
- `ffpga/timing-constraints/atcoder_spi_template_v3.sdc`
- `firmware/micropython/abc472b_test.py`
- `REF/`
- `REPORT_WORK_abc472b.md`～`REPORT_WORK4_abc472b.md`
- 37.5 MHz production bitstream

未実施:

- production RTL / SPI V3 RTL修正
- debug RTL / telemetry追加
- 追加Icarus testbenchと既存524件の再実行
- Synth / PNR / Timing / production bitstream再生成
- 別内部clock・別配置の試行
- Shrike-Liteへ新規production bitstreamを書き込む作業
- AtCoder提出
- Git操作
- pipeline化

WORK5は「2 MHzでもFAILし、内部観測が必要」の停止条件で完了とする。
