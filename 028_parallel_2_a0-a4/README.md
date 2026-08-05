# 第28回：4bitパラレル通信をCで高速化する

## このfolderについて

Qiita連載第28回で扱う、Shrike-Liteの4bitパラレル通信 Phase 5-A2～A4の公開資料です。各段階のUser C Module sourceとtest scriptを収録しています。

sourceからMicroPython firmwareをbuildできるほか、CMake環境を用意しなくても、収録したA4 production UF2を書き込んで試せます。

## A2／A3／A4の違い

- **A2**: 最小User C Moduleです。`shrike_parallel_c.version()`だけを公開します。
- **A3**: request/responseのpack／unpack処理をC化します。
- **A4**: PIO＋DMA通信engineをC化します。FPGA programmingやPIOの初期化などはPython harnessが担当します。

各directoryはその段階だけで完結するsource snapshotです。別段階のC sourceやCMakeを混在させないでください。

## sourceからbuildする

1. [Shrike公式repository](https://github.com/vicharak-in/shrike)をsubmodule込みで取得します。
2. 使用したMicroPythonの基準commitは `7b9155b907c373847f3863ff01f507f3bc938729` です。
3. このcheckoutに同梱されたPico SDKには`shrike-lite` board定義がないため、`SHRIKE_lite` board設定の`PICO_BOARD`を`shrike-lite`から`pico`へ変更します。
4. 最初に`RPI_PICO`をbuildし、RP2040 toolchainが利用できることを確認します。
5. A2、A3、A4のうちbuildしたい段階のroot `micropython.cmake`を`USER_C_MODULES`へ指定し、`BOARD=SHRIKE_lite`でRP2 firmwareをbuildします。

指定例：

```text
USER_C_MODULES=<このfolder>/A4/micropython.cmake
BOARD=SHRIKE_lite
```

一般的なRP2 build方法は[MicroPython RP2 portのREADME](https://github.com/micropython/micropython/tree/master/ports/rp2)を参照してください。

## UF2を書き込んで試す

1. 元のfirmwareへ戻せるよう、必要に応じて事前にbackupを取ります。
2. Shrike-LiteをBOOTSEL modeでPCへ接続します。
3. `firmware/shrike-lite-parallel-a4-production.uf2`を書き込みます。
4. 環境によってMicroPython filesystemの既存fileが残るため、次節のtest scriptとFPGA bitstreamが正しく配置されていることを確認します。

このUF2はproduction版です。fault injection用test hookは含みません。

## test script

A3：

- `A3/tests/shrike_parallel_pack_unpack_a3_test.py`
- `A3/tests/shrike_parallel_burst_pio_dma_proto_ph5_a3.py`

A4：

- `A4/tests/shrike_parallel_dma_a4_lifecycle_test.py`
- `A4/tests/shrike_parallel_pack_unpack_a4_regression_test.py`
- `A4/tests/shrike_parallel_burst_pio_dma_proto_ph5_a4.py`

A4 adapterはA3 harnessをimportします。実機へ配置するときは、`shrike_parallel_burst_pio_dma_proto_ph5_a3.py`と`shrike_parallel_burst_pio_dma_proto_ph5_a4.py`を同じdirectoryへ置いてください。

通信testはFPGAを書き換え、GPIO、PIO、DMAを使用します。配線とbitstreamを確認し、他の処理が動いていない状態で実行してください。

## 使用するFPGA bitstream

第27回資料に収録済みの[shrike_parallel_burst_proto.bin](../027_parallel_1/fpga/burst_shared/shrike_parallel_burst_proto.bin)を使います。basenameを変更せず、MicroPython filesystem直下へ配置してください。

```text
size: 46408 bytes
SHA-256: 59202dc1ac4687a48d3337221de7bf7bba6dcfeb791498b0c28cced7b29b7f6e
```

## versionとSHA-256

| 段階 | version |
|---|---|
| A2 | `0.1.0-a2` |
| A3 | `0.1.0-a3` |
| A4 | `0.1.0-a4` |

A4 production UF2：

```text
file: firmware/shrike-lite-parallel-a4-production.uf2
size: 689152 bytes
SHA-256: 4c337729fdb6aa18bfcc9ed1ca69575bcb3dec095411960b63a760bd6abd1883
```

A4 production UF2は、後続のPhase 5作業でも4MHz通信に使用し、正常動作を確認しています。

## 関連link

- [Shrike公式repository](https://github.com/vicharak-in/shrike)
- [MicroPython RP2 build guide](https://github.com/micropython/micropython/tree/master/ports/rp2)
- [Raspberry Pi Pico SDK documentation](https://www.raspberrypi.com/documentation/microcontrollers/c_sdk.html)
- [第27回：4bitパラレル通信を作る(1)](../027_parallel_1/README.md)

このfolderのUser C Moduleとtest scriptは本連載用に作成したものです。MicroPython、Pico SDK、Shrike関連codeには、それぞれの配布元のlicenseが適用されます。
