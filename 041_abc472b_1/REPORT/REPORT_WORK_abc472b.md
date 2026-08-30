# ABC472B Shrike-Lite WORK_abc472b 実行レポート

## 参照確認

作業開始時に `WORK_abc472b.md` を全文確認し、編集前に次の実物REFを読み取り専用で確認した。

- `REF/abc468b_distRAM`: DistRAM推論記述、同期read、reset時にRAM本体を初期化しない構成
- `REF/abc472a`: 最新のSPI/MicroPython/Icarus/REPORT構成
- `REF/atcoder_spi_template_v3`: SPI V3正本

WORKで想定されたフォルダ名は `abc468b` / `template_spi_v3` だったが、実物名が上記だった点以外にRTL仕様を変更する矛盾はなかった。Webからの再構築は行っていない。`REF`配下は変更していない。

## 実装ファイル

- `ffpga/src/main.v`: 128x17bit DistRAM、入力FSM、逐次CALC、24bit回答制御
- `ffpga/src/spi_target.v`: V3正本と同一RTL（EOF改行を除く正規化テキスト一致）
- `sim/tb_abc472b.v`: 50 MHz内部clock / 4 MHz SPI統合テスト
- `sim/run_iverilog.ps1`: Icarusのcompile/runスクリプト
- `firmware/micropython/abc472b_test.py`: RP2040転送・実機テストコード
- `REPORT_abc472b.md`: 本レポート

## 内部構成とビット幅

| 対象 | 幅 |
|---|---:|
| N、入力数、RAM/candidate address | 7bit |
| L_i / DistRAM data | 17bit |
| total_sum、prefix_sum、left/right、diff、best、answer | 24bit |

`L_i`は論理上100x17bitを保持する。REFの推論パターンに合わせ、物理記述は `reg [16:0] mem_ram [127:0]` とし、address 0..99だけを使用する。RAM全要素をresetする記述や同内容のFF複製はない。

writeは3byte目の `L_i` 受信clockに同期して1件行う。readは同期式で、`CALC_READ`にaddressを提示し、次の `CALC_EVALUATE`で出力を使用する。Phase 1ではSynthを禁止されているため、DistRAMへの実推論確認は未実施であり、Phase 2のSynth結果で確認が必要である。

## SPIフレーミング

SPIは4 MHz、CPOL=0、CPHA=0、8bit、MSB first、MISO 1byte遅延である。

入力の論理列は次のとおり。

```text
byte 0       : N
byte 1..3    : L_1 (24bit big-endian)
...
```

V3 MicroPython正本が定義し試験対象としている実際の1パッケージ上限は256byte (`MAX_PACKAGE_SIZE=256`)。これは `spi_target.v` 内部のbyte数制限ではなく、V3側の転送上限である。301byte入力は256byte + 45byteへ分割する。CS Highは入力FSM、3byte組立位置、受信数、totalをresetしない。

回答は入力送信・CALC完了待ちの後、別の4byte read burstで取得する。

```text
MOSI: dummy dummy          dummy          dummy
MISO: 0x00  answer[23:16] answer[15:8]   answer[7:0]
```

4byte目の完了後に受信制御だけを初期状態へ戻し、DistRAM本体は一括resetしない。

## CALC FSMとclock数

全N件の入力受信後、切れ目0..N-2の最大N-1候補を逐次処理する。99候補の並列化は行っていない。

```text
CALC_READ (1 clock / candidate)
  -> CALC_EVALUATE (1 clock / candidate)
  -> 次candidate、またはANSWER_READY
```

候補ごとに `prefix += L_i`、`right = total-prefix`、比較と24bit減算による絶対差、best更新を行う。論理CALC clock数は厳密に `2 * (N-1)` で、最大N=100では198 clock。50 MHzで3.96 usである。Icarusの内部状態観測でも最大198 clockを確認した。MicroPythonの10 us待ちはこれに対して6.04 usの余裕があり、V3同期遅延を含む4 MHz SPI統合試験でも全最大ケースが回答readyになった。

## テスト結果

実行コマンド:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\sim\run_iverilog.ps1
python -m py_compile .\firmware\micropython\abc472b_test.py
```

- Icarus SPI統合テスト: **524ケース PASS / 0 FAIL**
- 公式サンプル3件: PASS（2、51、28105）
- directed/境界ケース: 合計12件（公式3件を含む）PASS
- 決定的ランダム: 512件 PASS
- N=2、N=100、L_i=1、L_i=100000、合計10,000,000: PASS
- answer=0、24bit回答のMSB非0、最適切れ目が先頭/末尾、同値最小: PASS
- V3境界 N=85 (256byte)、N=86 (259byte)、N=100 (301byte): PASS
- CS境界をまたぐ入力状態保持: PASS
- N件受信前にCALCへ入らず、受信後にN-1候補だけ評価: PASS
- DistRAM address 0..N-1の17bit内容、total、内部answer: PASS
- MISO 1byte遅延、24bit big-endian回答、回答後の再arm: PASS
- FPGA reset 1回で524問題を連続実行し、前回状態の非混入: PASS
- 最大CALC: 198 clockを実測
- MicroPython構文確認: PASS

Icarus `-Wall`では、合成用moduleに明示的な `timescale` がないというwarningだけが出た。V3正本を変更しないため許容し、機能試験はexit code 0で完了した。

## 既知の制約と未実施項目

- 入力は問題制約どおり `2 <= N <= 100`、`1 <= L_i <= 100000` を前提とする。
- 回答readは入力と別burstにし、入力後10 us待つ。
- Synth / PNR、bitstream生成、FPGA書き込み、実機テスト、AtCoder提出は未実施。
- DistRAMへの実推論、Type=M利用量、配置可否、timingはPhase 2のSynth / PNRで確認する。

Phase 1の指定範囲で停止し、Synth / PNRへは進んでいない。
