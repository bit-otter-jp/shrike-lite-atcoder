# ABC472A Shrike-Lite 実装レポート

## 実装ファイル

- `ffpga/src/main.v`: ABC472Aのストリーム変換とV3 SPI接続
- `ffpga/src/spi_target.v`: `REF/spi_template_v3/spi_target.v` と同内容の共通SPI回路
- `sim/tb_abc472a.v`: 4 MHz SPIを含む自動テスト
- `sim/run_iverilog.ps1`: Icarusのビルド・実行スクリプト
- `firmware/micropython/abc472a_test.py`: RP2040側の転送・表示・実機テストコード

`REF` 配下は変更していない。

## FPGA側の処理構造

`rx_data_strobe` ごとに受信byteを1回だけ処理し、`0x41`なら`0x41`、それ以外なら`0x2E`を`tx_data`へ設定する。保持する問題データは返信用1byteだけで、文字列バッファや問題固有FSMはない。

## SPI通信シーケンス

SPIは4 MHz、CPOL=0、CPHA=0、8bit、MSB first。1文字以上100文字以下の入力とflush 1byteを、CSをLowに保った1回のバーストで送る。

```text
MOSI: S[0]  S[1]  ... S[N-1] flush
MISO: dummy R[0]  ... R[N-2] R[N-1]
```

先頭dummyは`0x00`として捨て、flush時のMISOを最終結果として回収する。CS非選択中に返信byteをdummyへ戻すため、次トランザクションの先頭へ前回結果は混入しない。

## 論理クロックとbyte処理

Icarusでは内部クロック50 MHz、SPI 4 MHzで検証した。SPI 1byteは2 usで、受信後の問題処理は1回の8bit比較・選択だけである。V3共通回路の3段同期と`o_rx_data_strobe`をそのまま利用する。

## テスト内容と結果

実行コマンド:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\sim\run_iverilog.ps1
python -m py_compile .\firmware\micropython\abc472a_test.py
```

- Icarus SPI統合テスト: **35ケース PASS / 0 FAIL**
- 公式サンプル3件: PASS
- A-Z全26文字: PASS
- 長さ1、長さ100、全A、Aなし、A複数、先頭A、末尾A: PASS
- 決定的ランダム24件（長さ1、100を含む）: PASS
- 1byte遅延、先頭dummy、最終flush、連続35トランザクション: PASS
- MicroPythonソース構文確認: PASS

MicroPythonテストコードには上記の主要ケースと決定的ランダム5件を含めた。期待値生成はテストオラクルだけに使用し、実際の結果文字列はFPGAから受信する。

## Shrike-Lite実機テストと処理時間測定

- bitstream書き込み: 成功
- 実機正答テスト: `SUMMARY PASS=17 FAIL=0 TOTAL=17 RESULT=PASS`
- ベンチマーク: 最大長100文字を1回ウォームアップ後、同一SPIセッションで20回測定。全20回でdummyと変換結果が一致し、`RESULT=PASS`。
- 測定範囲: `fpga_convert()` 呼び出しのみ。入力検査、ASCII格納、SPIバースト転送、dummy/flush応答回収、結果文字列化を含む。
- 測定外: bitstream書き込み、FPGA reset、SPI初期化、ケース／期待値生成、print。
- 実測値: `MIN_US=3827 AVG_US=3849 MAX_US=3922`

## 既知の制約

- 入力は仕様どおり英大文字A-Z、長さ1～100とする。
- 1入力文字列とflushは同じCS Low区間で転送する。
- 新しいトランザクションの前にCS High期間を設ける。

## 未実施項目

- AtCoder提出

## ForgeFPGA Workshop ビルド結果

- プロジェクト: `abc472a.ffpga`（`REF/abc471a/abc471a.ffpga` をひな形に作成）
- RTL参照: `ffpga/src/main.v`、`ffpga/src/spi_target.v`
- デバイス: family `04`、type `06`、partNumber `67`、package `26`
- クロック制約: `clk`、20.000 ns（50 MHz）
- I/O: `clk=CLK_t[0:0]_W_in0`、`spi_sck=IOB_t[0:0]_xy[0:9]_in0`、`spi_ss_n=IOB_t[0:0]_xy[0:10]_in0`、`spi_mosi=IOB_t[0:0]_xy[0:22]_in0`、`spi_miso/miso_en=IOB_t[0:0]_xy[0:23]_out0/out1`、`clk_en=IOB_t[0:0]_xy[0:25]_out0`、`rst_n=IOB_t[0:0]_xy[31:4]_in0`
- Synth: 成功（Yosys v0.59）
- PNR / bitstream: 成功（Place and Route v23、Workshop v6.54 Build 002）
- Resource: CLB LUT5s 40/1120（3.57%）、FF 31（CLB 27/1120、IOB 4/736）、CLB 9/140（6.43%）、BRAM 0/8
- Timing Summary（POST-ROUTE）: WNS +12893 ps、TNS 0 ps、Achievable Period 7106 ps、Achievable Frequency 140.726 MHz。50 MHz制約を満足。
- bitstream: `ffpga/build/FPGA_bitstream.bin` および `ffpga/build/bitstream/` の MCU / OTP / FLASH_MEM 各形式を生成
- Workshopでプロジェクトを再オープンし、再ビルドなしで成果物が不変かつ Synth / PNR 状態が保持されることを確認済み
