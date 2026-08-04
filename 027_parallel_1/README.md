# Qiita第27回「4bitパラレル通信を作る」公開資料

このディレクトリは、Qiita連載第27回で扱うShrike-Liteの4bitパラレル通信 Phase 1～4の公開資料です。RP2040側の実装方式を比較し、Phase 4のPIO＋DMA版を実機で再実行できるよう、コード、FPGA回路、bitstream、I/O割り当て、代表的な実機ログだけを収録しています。

## ディレクトリ構成

```text
027_parallel/
├─ README.md
├─ rp2040/
│  ├─ phase1_gpio.py
│  ├─ phase2_gpio_burst.py
│  ├─ phase3_pio.py
│  └─ phase4_pio_dma.py
├─ fpga/
│  ├─ io_spec.csv
│  ├─ phase1/
│  │  ├─ main.v
│  │  ├─ main_tb.v
│  │  ├─ shrike_parallel_proto.ffpga
│  │  └─ shrike_parallel_proto.bin
│  └─ burst_shared/
│     ├─ main.v
│     ├─ main_tb.v
│     ├─ shrike_parallel_burst_proto.ffpga
│     └─ shrike_parallel_burst_proto.bin
└─ results/
   ├─ phase1_hardware_test.log
   ├─ phase2_hardware_test.log
   ├─ phase3_hardware_test.log
   └─ phase4_hardware_test.log
```

Phase 1側とPhase 4側に保存されていたI/O CSVは同一で、同じピン割り当てをPhase 1～4で使用するため、`fpga/io_spec.csv`として1ファイルだけ収録しています。

## 各Phaseの違い

| Phase | RP2040側 | FPGA側 | 主な内容 |
|---|---|---|---|
| 1 | 通常GPIOによるbit banging | Phase 1専用 | `SOFT_RESET`と1byteの`INVERT`で基本ハンドシェイクを確認 |
| 2 | 通常GPIOによるbit banging | Phase 2～4共通 | 最大256byteの`BURST_INVERT`を追加 |
| 3 | PIO＋PythonによるFIFO給仕・回収 | Phase 2～4共通 | PIO0のState Machine 0で4bit転送を実行 |
| 4 | PIO＋DMA | Phase 2～4共通 | TX/RX FIFO転送をDMAへ移し、persistent State Machineを使用 |

Phase 2～4の`main.v`、`main_tb.v`、`shrike_parallel_burst_proto.bin`は、それぞれSHA-256が完全に一致しています。そのため、FPGA側は`fpga/burst_shared/`に1組だけ収録しています。

## 信号と接続

| 信号 | 方向（RP2040基準） | RP2040 | FPGA | 用途 |
|---|---|---|---|---|
| DATA[0] | 双方向 | GP2 | GPIO03 | 4bitデータバス bit 0 |
| DATA[1] | 双方向 | GP1 | GPIO04 | 4bitデータバス bit 1 |
| DATA[2] | 双方向 | GP3 | GPIO05 | 4bitデータバス bit 2 |
| DATA[3] | 双方向 | GP0 | GPIO06 | 4bitデータバス bit 3 |
| CLK | 出力 | GP15 | GPIO17 | RP2040が生成する転送クロック。アイドルはLow |
| REQ | 入力 | GP14 | GPIO18 | FPGAが駆動する応答ハンドシェイク |

PIOは連続するGP0～GP3をベースに使いますが、基板上の論理DATA順は`(GP2, GP1, GP3, GP0)`です。Phase 3・4のコードはこの違いをpack/unpack時に変換しています。

## 必要な環境

- Shrike-Lite
- Thonny
- Shrike-Lite用MicroPython
- Shrike-Liteファームウェアに含まれる`shrike` module
- `rp2.StateMachine`を利用できるMicroPython（Phase 3・4）
- `rp2.DMA`を利用できるMicroPython（Phase 4）

保存ログ取得時のShrike-Lite上のRP2040ファームウェアは手元のShrike-Lite購入時にセットアップされていた、`v1.26.0-preview.527.g599f545a3.dirty`です。通常のMicroPython v1.26.0と同じAPI・挙動であるとは限らないため、Phase 4では特に`rp2.DMA`の有無を確認してください。

## Phase 4を実行する

1. ThonnyでShrike-LiteのMicroPythonインタプリタへ接続します。
2. `fpga/burst_shared/shrike_parallel_burst_proto.bin`を、ファイル名を変えずにShrike-LiteのMicroPythonファイルシステム直下へアップロードします。
3. `rp2040/phase4_pio_dma.py`をThonnyで開き、同じデバイス上で実行します。デバイスへ保存する場合もファイル名は`phase4_pio_dma.py`のままで構いません。
4. コードは起動時に`shrike.reset()`と`shrike.flash("shrike_parallel_burst_proto.bin")`を呼び、FPGAを書き換えた後、100kHz、500kHz、1MHz、2MHz、4MHzの順に試験します。
5. 最終行が次の形式で`PASS`になることを確認します。

```text
CLOCK_SWEEP_SUMMARY MODE=PIO_DMA COMPLETED_FREQUENCIES=5 REQUIRED_FREQUENCIES=5 ... PASS ...
```

Phase 1を試す場合だけ、専用の`fpga/phase1/shrike_parallel_proto.bin`をアップロードします。Phase 2・3・4は共通の`shrike_parallel_burst_proto.bin`を使います。Pythonコード内の`BITSTREAM`文字列と、収録したbitstreamのbasenameは一致しています。

## GPIO、PIO、DMAの注意

- GP0～GP3、GP14、GP15は通信中に他用途と共有しないでください。
- DATAは双方向です。RP2040側とFPGA側が同時に出力するとバス競合になるため、コードの方向切り替え処理を変更する場合は十分に確認してください。
- Phase 3・4はPIO0のState Machine 0（`SM_ID = 0`）を使用します。ほかのコードから同じState Machineを使わないでください。
- Phase 4は`rp2.DMA()`でTX用とRX用の2 channelを動的に確保します。保存ログではchannel 0と1でしたが、コードは番号を固定していません。実行中はほかの処理が確保したDMA channelとの競合に注意してください。
- Phase 4のDREQはPIO0 SM0のTX=0、RX=4、転送幅は32bitです。RX DMAを先に開始し、その後TX DMAを開始します。
- Phase 4の通常通信経路は`StateMachine.put()`／`get()`によるFIFO転送ではなくDMAを使います。異常終了時は再初期化またはbitstreamの再書き込みが必要になる場合があります。
- コードはPIO、DMA、GPIOを終了処理で停止・解放しますが、別プログラムと並行実行しないでください。

## 試験時間と実機確認済み範囲

Phase 4は各周波数で、`SOFT_RESET`、8パターンの`INVERT`、`INVERT` 1000回、長さ1・2・31・32・255・256byteの`BURST_INVERT`、32byte burst 1000回、アイドル状態を確認します。4MHzではさらに256byteのDMA bulk試験を1000回実行します。保存ログの全体時間は約176秒であり、書き込みやThonny側の処理を含めると完全試験には数分かかります。

収録ログで確認できる範囲は次のとおりです。

- Phase 1: `SOFT_RESET`、8パターンの`INVERT`、1000回loopがPASS
- Phase 2: Phase 1相当試験、6種類のburst長、32byte×1000回がPASS
- Phase 3: 100kHz～4MHzの5周波数で全機能試験がPASS
- Phase 4: 100kHz～4MHzの5周波数でPIO＋DMA試験がPASSし、4MHzの256byte×1000回DMA bulk試験もPASS

Phase 4ではソフトウェア上のDATA入力状態とREQ/CLKのアイドル状態を確認しています。一方、`DATA_INPUT_WAVEFORM`、`FIFO_STALL_WAVEFORM`、`BUS_CONTENTION_WAVEFORM`は保存ログ上`NOT_TESTED`、PIO制御word待ちは`STATIC_INFERRED`です。意図的なDMA bus errorやtimeoutの故障注入試験も保存ログには含まれていません。

詳細な実機出力は`results/`以下の各ログを参照してください。ログ本文に試験日時は含まれていません。

## Verilogテストベンチ

Icarus Verilogを使う場合の例です。

```sh
iverilog -g2005 -s main_tb -o phase1_tb.vvp fpga/phase1/main.v fpga/phase1/main_tb.v
vvp phase1_tb.vvp

iverilog -g2005 -s main_tb -o burst_tb.vvp fpga/burst_shared/main.v fpga/burst_shared/main_tb.v
vvp burst_tb.vvp
```

いずれも最後に`ALL TESTS PASS`と表示されることを期待します。生成される`.vvp`は公開資料には含めません。

## ForgeFPGA Workshopプロジェクトについて

公開資料では用途を明確にするため、次の2ファイルとして配置しています。

- `fpga/phase1/shrike_parallel_proto.ffpga`: Phase 1用。同じディレクトリの`main.v`を参照します。
- `fpga/burst_shared/shrike_parallel_burst_proto.ffpga`: Phase 2～4共通。同じディレクトリの`main.v`を参照します。

I/O割り当ては共通の`fpga/io_spec.csv`を参照してください。

## 性能値の扱い

この資料は、4bitパラレル通信がSPI 4MHzより高速であることを保証するものではありません。Python側のpack/unpackや試験処理を含むEnd-to-end時間も大きく影響します。Phase 4のPIO＋DMA版がShrike-Lite実機で動作した時点の検証資料として参照してください。
