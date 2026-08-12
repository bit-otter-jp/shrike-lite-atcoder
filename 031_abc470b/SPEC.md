# ABC470B 分散RAM版仕様

## 目的

AtCoder ABC470B「Monocolor」を、色ごとの出現数をForgeFPGAの分散RAMへ保持する方式でShrike-Liteへ実装する。

問題の制約は次のとおり。

```text
1 <= N <= 100
1 <= C[i] <= N
```

各色の出現数を`count[color]`として保持し、入力を1個処理するたびに該当色のカウントを1増やす。

同時に、更新後のカウント値と`max_count`を比較して最大出現数を逐次更新する。

全入力の処理完了後、回答は次の式で求める。

```text
ANSWER = N - max_count
```

最後に全色のカウントを再走査して最大値を求める方式は採用しない。

今回の主な確認目的は次のとおり。

- 100色分の7bitカウンタを分散RAMへ保持できるか
- ForgeFPGA Workshopが分散RAMとして推論するか
- 4MHz SPIバースト転送へ十分追従できるか
- 同期readの分散RAMでread-modify-writeを正しく実装できるか
- 入力ごとのカウント更新と`max_count`更新を正しく行えるか
- 最後の入力の更新完了を待って正しい回答を返せるか

過剰な高速化や並列化は行わず、Shrike-Liteへ収まりやすく、動作を説明しやすい小さな回路を優先する。

## ベース

ルート側のプロジェクトを今回の実装対象とする。

```text
abc470b.ffpga
SPEC.md

bitstream/

ffpga/
  src/
    main.v
    spi_target.v
  timing-constraints/
    atcoder_spi_template_v3.sdc

firmware/
  micropython/
    abc470b_test.py

references/
  022_(2)_abc468b_distRAM/
  AN-FG-018 How to use distributed memory as a RAM/

sim/
```

主な実装対象は次のとおり。

```text
ffpga/src/main.v
firmware/micropython/abc470b_test.py
sim/
```

必要であれば、分散RAM本体を別モジュールへ分離してよい。

ただし、不要なファイル分割は行わない。

`spi_target.v`は、明確な不具合がない限り変更しない。

次のファイルも原則として変更しない。

```text
abc470b.ffpga
ffpga/timing-constraints/atcoder_spi_template_v3.sdc
references/**
```

`references`以下は読み取り専用の参照資料として扱う。

Git操作は行わない。

## 参照資料

### ABC468B 分散RAM版成果物

```text
references/022_(2)_abc468b_distRAM/
```

今回の実装では、この成果物をShrike-Lite上で実動作した分散RAM使用例として参照する。

主に次の内容を確認する。

- SPI 4MHzの通信構成
- RESETおよびSTARTコマンド
- RESET ACKおよびSTART ACK
- SPIバースト転送
- MISOの`VALID`付き回答形式
- MicroPython側の実機試験方法
- Icarus Verilog用シミュレーション方法
- 分散RAMのモジュール記述
- START後の逐次初期化方法
- 同期readの扱い
- ForgeFPGA Workshopで分散RAMとして推論された実装形式

ABC468B固有の次の回路は今回へ流用しない。

- 範囲更新器
- 1件保留バッファ
- `update_overrun`
- 最終集計器
- 監視区間処理

今回必要なのは、色ごとのカウントをread-modify-writeする小さな更新器である。

### Renesas公式分散RAMサンプル

```text
references/AN-FG-018 How to use distributed memory as a RAM/
```

次の公式資料を参照する。

```text
AN-FG-018 How to use distributed memory as a RAM.ffpga
REN_an-fg-018_how_to_use_distributed_memory_as_a_ram_APN_20250323.pdf
ffpga/src/dist_ram_2ports.v
ffpga/sim/dist_ram_2ports_tb.vt
```

分散RAMのVerilog記述は、公式サンプルの実際のソースコードを正本として参照する。

PDF掲載コードだけを手作業で転記せず、`.ffpga`プロジェクト内の実ソースを確認する。

ForgeFPGA Workshopが分散RAMとして推論できる記述形式を優先する。

公式サンプルにもwarningがあるため、warningを減らす目的だけでRAM推論用の記述形式を変更しない。

warningは内容を確認し、機能、合成、配置、分散RAM推論に影響しないものは許容する。

## 通信仕様

SPI通信は既存テンプレートの4MHz設定を維持する。

```text
SPIクロック: 4MHz
CPOL: 0
CPHA: 0
データ幅: 8bit
ビット順: MSB first
```

既存テンプレートのRESET、START、NOP、ACKの扱いを維持する。

使用する制御値は既存実装を正とする。

現在のテンプレートでは少なくとも次を使用する。

```text
RESET     = 0xFF
START     = 0xFE
NOP       = 0x00
RESET_ACK = 0x5A
START_ACK = 0xA5
```

制御値やACKタイミングは、参照実装とルート側`spi_target.v`の実コードを確認したうえで合わせる。

### 問題データ

問題データは次の順序で送信する。

```text
N
C[0]
C[1]
...
C[N-1]
```

`N`および各`C[i]`は論理上7bitの値であり、SPI上では1byteの下位7bitへ格納する。

```text
bit 7   = 0
bit 6:0 = VALUE
```

有効範囲は次のとおり。

```text
1 <= N <= 100
1 <= C[i] <= N
```

AtCoderの入力は常に制約を満たすため、今回の主目的として異常入力処理は実装しない。

`N`から`C[N-1]`までは、1回のCS Lowによる連続SPIバーストとして送信する。

4MHz SPIでは1byteあたり2usで到着する。

## 分散RAM

色ごとの出現数をForgeFPGAの分散RAMで保持する。

論理上の構成は次のとおり。

```text
深さ: 128
幅: 7bit
使用アドレス: 1～100
未使用アドレス: 0、101～127
```

各アドレスは色番号へ直接対応させる。

```text
address = C[i]
data    = その色の現在の出現数
```

色番号を0始まりへ変換する必要はない。

カウント値は0～100なので7bitで保持する。

分散RAMは、公式AN-FG-018のデュアルポートRAM記述、およびABC468B分散RAM版の実装を参考にする。

想定するインターフェースは次のとおり。

```text
書き込みアドレス
書き込みデータ
書き込みイネーブル
読み出しアドレス
読み出しデータ
```

読み書きには既存のFPGA内部クロックを使用する。

今回の問題処理では、同一アドレスに対するread-modify-writeを逐次実行する。

read-during-write時の値へ依存する実装にはしない。

## 分散RAM推論を維持するための注意

分散RAMの全要素をRESET信号で一括クリアしない。

次のような、全要素をRESETで初期化する記述は使用しない。

```verilog
if (!reset_n) begin
    for (...) begin
        count_ram[...] <= 0;
    end
end
```

RESETでは、FSM、カウンタ、回答、受信状態などの制御レジスタだけを初期状態へ戻す。

分散RAMの内容は、START後の逐次初期化によって0へ設定する。

分散RAMと同じ内容を保持する100要素の複製レジスタ配列を作らない。

デバッグ目的でも、分散RAM全体を別のFF配列へコピーしない。

分散RAMとして推論されずFFへ展開された場合は、その状態を完成とみなさない。

公式サンプルおよびABC468B分散RAM版の記述と合成対象コードとの差を確認し、推論を妨げている記述を調査する。

## 配列初期化

START受信後、使用アドレス1～100へ`0`を順番に書き込む。

```text
write_address = 1～100
write_data    = 0
write_enable  = 1
```

初期化は100クロックで行う。

未使用アドレスは初期化しなくてよい。

同時に次の制御状態も新しい問題用へ初期化する。

```text
max_count      = 0
received_count = 0
VALID          = 0
ANSWER         = 0
```

分散RAM本体にはRESETを掛けない。

初期化完了状態は明確な内部フラグで管理する。

問題データはSTART ACK確認後に送信する。

既存の4MHz SPI通信と内部クロックの条件では、最初の`C[0]`を処理するまでに初期化が完了する構成を基本とする。

シミュレーションでは、実際の4MHz SPI相当のタイミングで`C[0]`処理前に初期化が完了していることを確認する。

もし参照実装の実際のACKタイミングでは初期化完了を保証できないことが判明した場合は、入力を失わない最小限の待機または1件保持を追加する。

大きなFIFOは追加しない。

## 入力処理

最初の問題データbyteを`N`として受信し、7bitレジスタへ保持する。

その後の`N` byteを`C[0]`～`C[N-1]`として処理する。

受信済み色数を`received_count`として管理する。

各色を受信したら、色番号を保持して分散RAMのread-modify-writeを開始する。

SPI受信自体は継続できる構成とする。

4MHz SPIでは次のbyteまで2usあるため、色1件のread-modify-writeは次の色が到着する前に完了させる。

過剰な並列更新器やFIFOは追加しない。

## カウント更新

各`C[i]`について、概念上次の処理を行う。

```text
old_count = count[C[i]]
new_count = old_count + 1
count[C[i]] = new_count

if new_count > max_count:
    max_count = new_count
```

分散RAMのreadが同期式であることを前提に、read addressを設定するクロックとread dataを使用するクロックを正しく分離する。

必要なクロック数を1クロックへ無理に圧縮しない。

目安として、1色につき数クロックの小さなFSMでよい。

例えば次のような段階を想定する。

```text
1. 色番号を保持し、read addressを設定
2. 同期read結果を取得
3. old_count + 1 を生成しwrite-back
4. new_countとmax_countを比較し、必要ならmax_countを更新
```

実際の状態数は、公式分散RAM記述のread timingとVerilogのnonblocking assignmentの更新タイミングに合わせて決定する。

同じ色が連続して到着した場合でも、前回のwrite-back完了後に次回readが行われ、1件も数え落とさないこと。

4MHz SPIバースト中にカウント更新が追いつかない構成にはしない。

## 最大値の逐次更新

最大出現数は7bitレジスタ`max_count`で保持する。

START時に`0`へ初期化する。

各色のカウントを更新した時点で、更新後の`new_count`と現在の`max_count`を比較する。

```text
if new_count > max_count:
    max_count = new_count
```

最後に分散RAMの100要素を読み出して最大値を探す処理は行わない。

これにより、最後の色のカウント更新が完了した時点で最大出現数も確定する。

## 最終処理

`C[N-1]`を受信しただけでは処理完了としない。

最後の色について次が完了するまで待つ。

- 同期read
- `+1`
- write-back
- `max_count`更新

その後、別の状態で回答を確定する。

```text
ANSWER = N - max_count
```

nonblocking assignmentの更新タイミングにより、最後の`max_count`更新前の値を使って回答を作らないこと。

必要であれば、最後のカウント更新状態と`PREPARE_REPLY`を別クロックへ分離する。

`N=1`、最後の入力で初めて最大値が更新されるケース、同じ色が最後まで連続するケースで正しく動作すること。

## 応答

処理中は`VALID=0`とする。

回答確定後は既存テンプレートと同じ1byte形式で返信する。

```text
bit 7   = VALID
bit 6:0 = ANSWER
```

回答範囲は0～99なので7bitで表現できる。

回答確定後は、次のRESETまたはSTARTまで有効な返信値を保持する。

MicroPython側はNOPを送って`VALID=1`になるまでポーリングする。

無限ループを避けるため、最大ポーリング回数を設定する。

ABC468B分散RAM版と同様に、最大16回のNOPポーリングを基本とする。

## RESETとSTART

RESETでは、少なくとも次の制御状態を初期状態へ戻す。

- SPI受信状態
- 問題データ受信状態
- `N`
- `received_count`
- `max_count`
- 回答
- `VALID`
- 分散RAM初期化状態
- read-modify-write状態
- 保持中の色番号

RESETでは分散RAM全体を一括初期化しない。

STARTでは新しい問題の処理に必要な制御状態を初期化し、分散RAMの逐次0クリアを開始する。

RESET ACKおよびSTART ACKの値と返信タイミングは、既存SPIテンプレートを維持する。

STARTによる複数問題の連続実行に対応する。

前回問題の分散RAM内容が残っていても、START後の逐次初期化完了後は今回の回答へ影響しないこと。

## MicroPython実機試験コード

次のファイルを実装する。

```text
firmware/micropython/abc470b_test.py
```

ABC468B分散RAM版の実機試験コードを参考にし、次を維持する。

- SPI 4MHz
- CPOL=0
- CPHA=0
- 既存Shrike-Liteの端子割り当て
- 既存RESET/STARTコマンド
- ACK確認
- 1回のCS Lowによる問題データのバースト転送
- `VALID`付き1byte回答
- 上限付きNOPポーリング
- 1ケースの失敗で後続試験を停止しない構成

bitstream名は次のとおりとする。

```text
abc470b.bin
```

各ケースについて、少なくとも次を表示する。

```text
NAME
N
C
RESULT
EXPECT
VALID
PASS
TIME_US
RX
POLL_COUNT
RESET_ACK_RX
START_ACK_RX
DATA_REPLY_OK
```

`C`が長いケースでは、全要素を無理に1行表示しなくてよい。

最大ケースでは先頭数要素、末尾数要素、要素数などの要約表示でよい。

全ケース終了後に、PASS数、FAIL数および全体結果を表示する。

## テストケース

公式サンプル3件を使用する。

| NAME | N | C | EXPECT | 確認目的 |
|---|---:|---|---:|---|
| sample1 | 4 | `3 1 2 1` | 2 | 公式サンプル1 |
| sample2 | 5 | `3 3 3 3 3` | 0 | 公式サンプル2、全て同色 |
| sample3 | 9 | `4 2 3 3 4 1 2 7 1` | 7 | 公式サンプル3 |

追加で少なくとも次を確認する。

| NAME | N | C | EXPECT | 確認目的 |
|---|---:|---|---:|---|
| min | 1 | `1` | 0 | 最小N |
| all_same_max | 100 | `100`を100個 | 0 | 最大N、色番号上限、同一アドレス連続RMW |
| all_different | 100 | `1 2 ... 100` | 99 | 最大N、100アドレス使用 |
| two_colors_equal | 100 | `1`を50個、`2`を50個 | 50 | 同率最大 |
| max_updates_late | 10 | `1 2 3 4 5 6 7 8 9 9` | 8 | 最後の入力で最大値更新 |
| repeated_consecutive | 8 | `1 1 1 1 2 2 2 2` | 4 | 同一アドレス連続更新 |
| start_reuse | 複数ケース | STARTを挟み連続実行 | 各期待値 | 前回RAM内容が残らないこと |

必要に応じて、シミュレーションでは固定seedのランダムケースも追加する。

ランダムケースの期待値は単純な参照モデルで計算し、DUTの回答と比較する。

## シミュレーション

今回用として、次のファイル名を基本とする。

```text
sim/spi_target_stub.v
sim/tb_monocolor_distRAM.v
```

ABC468B分散RAM版のシミュレーション構成を参照してよい。

Icarus Verilogが利用可能なら、Verilog-2001モードでコンパイルと実行を行う。

少なくとも次を確認する。

- RESET ACK
- START ACK
- 公式サンプル3件
- 追加テスト
- 回答値
- `VALID`
- START後の逐次初期化
- `C[0]`処理前の初期化完了
- 同期readの1クロック以上の遅延を正しく扱うこと
- 同じ色が連続した場合のread-modify-write
- 更新後の`new_count`で`max_count`を比較すること
- 最後の入力のwrite-back完了待ち
- 最後の入力で`max_count`が更新されるケース
- `N=1`
- `N=100`
- 色番号100
- STARTによる複数ケースの連続実行
- RESET後に前回の回答が残らないこと
- 4MHz SPIバースト中に受信データを取りこぼさないこと

4MHz SPI相当として、1byteあたり2usの連続CS Lowバーストを再現する。

最大負荷ケースは次を基本とする。

```text
N=100
C=同じ色を100個
EXPECT=0
```

同一アドレスへのread-modify-writeが100回連続しても正しくカウントできることを確認する。

また、次の最大アドレスケースも確認する。

```text
N=100
C=1,2,3,...,100
EXPECT=99
```

4MHz条件で追従できない場合は、テスト条件を緩めてPASSさせない。

原因となるクロック数、受信取りこぼし条件および考えられる対策を報告する。

## 合成時の確認項目

Codexによる作業ではForgeFPGA Workshopの合成、配置、bitstream生成、FPGA書き込みおよび実機試験は行わない。

こちらで合成した際に、少なくとも次を確認できる構成にする。

- FloorplanまたはResource Reportで分散RAMが使用されている
- `Type=M`の使用数が0より大きい
- 専用BRAMを使用していない
- 配置処理が完了する
- 分散RAMがFF配列へ展開されていない
- 合成ログのwarning内容を確認できる
- WNS
- TNS
- Achievable Period
- Achievable Frequency

`RAM-32 dual-port`等の具体的なプリミティブ数は事前に固定しない。

合成結果とFloorplanを正とする。

700bit相当の論理カウント情報が、すべてFFへ展開されていないことを重視する。

## 実装方針

- Verilog-2001でForgeFPGA Workshopが扱いやすい記述を優先する。
- 公式AN-FG-018の分散RAM推論パターンを尊重する。
- ABC468B分散RAM版の実動作した記述形式を優先して参照する。
- 多次元配列や複雑すぎるSystemVerilog構文は避ける。
- 100色のカウントをFF配列として保持しない。
- 大きなFIFOや不要な並列回路を追加しない。
- 最終100要素走査用のMUXや最大値探索器を追加しない。
- `max_count`は入力処理中に逐次更新する。
- read-modify-writeを無理に1クロックへ圧縮しない。
- 4MHz SPIへ確実に追従できる範囲で、単純なFSMを優先する。
- `spi_target.v`は原則として変更しない。
- 既存の日本語コメントを維持する。
- 新しいコメントも日本語で記述する。
- シミュレーション専用記述を合成対象へ混在させない。
- warningをゼロにすることを目的にRAM推論を壊す変更をしない。
- 未使用信号や明確な問題のあるwarningは可能な範囲で整理する。
- ファイルの移動、削除、無関係な整形を行わない。
- Git操作を行わない。

## 完了条件

次を完了する。

1. 本仕様書を全文確認する。
2. `references/022_(2)_abc468b_distRAM/`を確認する。
3. AN-FG-018の実ソースとテストベンチを確認する。
4. ルート側SPIテンプレートのRESET/START/ACK仕様を確認する。
5. 分散RAM版の`ffpga/src/main.v`を実装する。
6. 必要なら分散RAMモジュールを追加する。
7. `firmware/micropython/abc470b_test.py`を実装する。
8. 今回用のシミュレーション環境を作成する。
9. Icarus Verilogでコンパイル・実行する。
10. 公式サンプル3件で期待値と一致することを確認する。
11. 追加テストで期待値と一致することを確認する。
12. 同じ色が連続した場合のread-modify-writeを確認する。
13. 最後の入力の更新完了後に回答が確定することを確認する。
14. 4MHz SPI相当の最大ケースでデータを取りこぼさないことを確認する。
15. STARTによる複数ケース連続実行を確認する。
16. 変更したファイルと実装内容を報告する。
17. ForgeFPGA Workshopで合成する際の確認点を報告する。

ForgeFPGA Workshopによる実際の合成、配置、bitstream生成、FPGA書き込みおよび実機試験は行わない。

## 最終報告

作業終了時に、次の形式で簡潔に報告する。

```text
1. 変更ファイル
2. 参照した分散RAM実装
3. 実装した分散RAMの構成
4. START後の配列初期化
5. SPI問題データ形式
6. 1色あたりのread-modify-write手順
7. 分散RAMの読み出しタイミング
8. max_countの更新方法
9. 最後の入力から回答確定までの手順
10. 実行したシミュレーション
11. テスト結果
12. 4MHz最大負荷ケースの結果
13. 発生したwarning
14. 合成時に確認すべき項目
```

シミュレーションを実行できなかった場合は、実行できたと装わない。

使用したコマンド、発生したエラーおよび確認できなかった項目を明記する。
