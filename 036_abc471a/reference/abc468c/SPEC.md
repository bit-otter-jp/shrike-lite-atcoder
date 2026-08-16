# ABC468C FPGA実装仕様

## 目的

AtCoder ABC468Cの回答を、Shrike-Lite上のFPGAで計算する。

順列PとQの辞書順順位を求め、次の値を回答とする。

```text
answer = max(0, rank(Q) - rank(P) - 1)
```

順位は0始まりとする。

```text
最小の順列: rank = 0
最大の順列: rank = N! - 1
```

Nの最大値は10とする。

---

## 問題概要

整数`N`と、`1`から`N`までの整数をそれぞれ一度ずつ含む2つの順列`P`、`Q`が与えられる。

```text
P = (P1, P2, ..., PN)
Q = (Q1, Q2, ..., QN)
```

`1`から`N`までの整数を並べ替えた順列`R`のうち、辞書順で次の条件を満たすものの個数を求める。

```text
P < R < Q
```

PとQ自身は回答へ含めない。

PがQ以上の場合や、PとQが辞書順で隣接している場合、条件を満たす順列は存在しないため、回答は0となる。

制約は次のとおり。

```text
1 <= N <= 10
Pは1からNまでの順列
Qは1からNまでの順列
```

論理的な入力形式は次のとおり。

```text
N
P1 P2 ... PN
Q1 Q2 ... QN
```

FPGAへの実際の転送形式は、後述するSPI入力送信仕様に従う。

---

## 順位を使った回答計算

すべての順列へ、辞書順で0から始まる順位を付ける。

```text
最小の順列: rank = 0
最大の順列: rank = N! - 1
```

PとQの順位を求めれば、回答は次の式で計算できる。

```text
if rank(Q) > rank(P) + 1:
    answer = rank(Q) - rank(P) - 1
else:
    answer = 0
```

---

## 公式サンプル

### サンプル1

```text
N = 3
P = [1, 3, 2]
Q = [3, 1, 2]
EXPECT = 2
```

条件を満たす順列は次の2つ。

```text
[2, 1, 3]
[2, 3, 1]
```

### サンプル2

```text
N = 5
P = [5, 4, 2, 1, 3]
Q = [5, 1, 2, 3, 4]
EXPECT = 0
```

PがQより辞書順で大きいため、条件を満たす順列は存在しない。

### サンプル3

```text
N = 7
P = [3, 6, 5, 2, 7, 1, 4]
Q = [4, 1, 5, 7, 2, 3, 6]
EXPECT = 223
```

---

## 開発方針

既存のSPIテンプレートV3をベースに実装する。

SPI通信回路と基本プロトコルは可能な限り変更しない。

主な変更対象は次の2ファイルとする。

```text
ffpga/src/main.v
firmware/micropython/abc468c_test.py
```

`ffpga/src/spi_target.v`は、原則として変更しない。

---

## ディレクトリ構成

```text
abc468c/
│  abc468c.ffpga
│  IMPLEMENTATION_SPEC.md
│
├─bitstream
├─ffpga
│  ├─src
│  │      main.v
│  │      spi_target.v
│  │
│  └─timing-constraints
│          atcoder_spi_template_v3.sdc
│
└─firmware
    └─micropython
            abc468c_test.py
```

---

## SPI基本プロトコル

SPIテンプレートV3の制御値を使用する。

| 用途        |      値 |
| --------- | -----: |
| NOP       | `0x00` |
| DEBUG     | `0xFD` |
| START     | `0xFE` |
| RESET     | `0xFF` |
| RESET_ACK | `0x5A` |
| START_ACK | `0xA5` |

SPIクロックは4MHzを基本とする。

SPI応答には1byteの遅延がある。

基本シーケンスは次のとおり。

```text
RESET
RESET_ACK確認
START
START_ACK確認
SEND_N
SEND_P
SEND_Q
回答ポーリング
回答受信
```

---

## 入力送信仕様

### SEND_N

Nは1byteで送信する。

```text
byte[7:4] = 0
byte[3:0] = N
```

例:

```text
N = 3  -> 0x03
N = 10 -> 0x0A
```

---

### SEND_P

順列Pの各要素を4bitとして扱い、2要素を1byteへ格納する。

```text
byte[7:4] = 先の要素
byte[3:0] = 次の要素
```

例:

```text
P = [1, 3, 2]
送信データ = [0x13, 0x20]
```

Nが奇数の場合、最後のbyteの下位4bitは0で埋める。

送信byte数は次のとおり。

```text
(N + 1) // 2
```

Pの全byteを1回のバーストで送信する。

---

### SEND_Q

QもPと同じ形式で送信する。

Qの全byteを1回のバーストで送信する。

PとQは別々のSPIバーストとして送信する。

---

## FPGA側の受信順序

START受信後、FPGAは次の順序でデータを解釈する。

```text
1byte                 : N
ceil(N / 2) byte      : P
ceil(N / 2) byte      : Q
```

SEND_PやSEND_Qを示す追加コマンドは使用しない。

Nから各フェーズの受信byte数を判断する。

---

## 順列順位の計算方法

順列の各桁を左から順に処理する。

現在の数字を`current_value`とする。

まだ使用していない数字のうち、`current_value`より小さい数字を1から順番に確認する。

該当する数字を1つ見つけるたびに、残り桁数の階乗を順位へ加算する。

```text
remaining = N - digit_index - 1
rank_work += remaining!
```

ソフトウェアで行う次の計算を、乗算器を使わずに実行する。

```text
未使用かつcurrent_valueより小さい数字の個数
×
remaining!
```

候補数字をFSMで1つずつ調べ、同じ加算器を繰り返し使用する。

---

## 使用済み数字の管理

1から10までの数字の使用状態を、10bitの`used_mask`で管理する。

```text
used_mask[0] = 数字1
used_mask[1] = 数字2
...
used_mask[9] = 数字10
```

各桁の処理完了後、現在の数字を使用済みにする。

```text
used_mask[current_value - 1] = 1
```

---

## 階乗値

階乗値は固定値のため、BRAMは使用しない。

組み合わせ回路または`case`文で選択する。

```text
0! =      1
1! =      1
2! =      2
3! =      6
4! =     24
5! =    120
6! =    720
7! =   5040
8! =  40320
9! = 362880
```

順位と回答は22bitで保持する。

---

## PとQでの回路共有

P用とQ用の順位計算回路を別々に作らない。

次の回路とレジスタをPとQで共有する。

```text
used_mask
rank_work
current_value
candidate
digit_index
階乗選択回路
加算器
順位計算FSM
```

Pの計算終了後、順位を`rank_p`へ保存する。

```text
rank_p = rank_work
```

その後、次の作業用状態をクリアする。

```text
rank_work = 0
used_mask = 0
digit_index = 0
```

同じ順位計算回路を使用してQを処理する。

---

## 4bitデータの展開

SPIから受信した1byteを、上位4bit、下位4bitの順に処理する。

```text
上位4bit
下位4bit
```

Nが奇数の場合、最後のbyteの下位4bitは処理しない。

1byteに含まれる2要素は、同時に計算せず、同じ順位計算回路で順番に処理する。

次のSPI byteを受信する前に、現在のbyteに含まれる要素の処理を完了させる。

処理中に次の受信byteが到着した場合は、`protocol_error`をセットする。

---

## 想定する主要レジスタ

名称は既存コードとの整合に応じて変更してよい。

| レジスタ             |     幅 | 用途          |
| ---------------- | ----: | ----------- |
| `n_reg`          |  4bit | N           |
| `sequence_phase` |  1bit | PまたはQ       |
| `digit_index`    |  4bit | 現在処理している桁   |
| `current_value`  |  4bit | 現在の数字       |
| `candidate`      |  4bit | 確認中の候補数字    |
| `used_mask`      | 10bit | 使用済み数字      |
| `rank_work`      | 22bit | 現在計算中の順位    |
| `rank_p`         | 22bit | Pの順位        |
| `answer`         | 22bit | 最終回答        |
| `rx_byte_buffer` |  8bit | 受信byte保持    |
| `nibble_select`  |  1bit | 上位または下位4bit |

---

## 想定するFSM処理

状態名は既存の`main.v`に合わせて変更してよい。

概念的には次の処理を行う。

```text
WAIT_START
RECEIVE_N
WAIT_SEQUENCE_BYTE
LOAD_NIBBLE
INIT_SCAN
SCAN_CANDIDATE
MARK_USED
FINISH_DIGIT
FINISH_SEQUENCE
CALC_ANSWER
PREPARE_REPLY
SEND_REPLY
```

### SCAN_CANDIDATE

次の処理を1候補ずつ行う。

```text
if candidate < current_value:
    if used_mask[candidate - 1] == 0:
        rank_work += factorial_value

    candidate += 1
else:
    次の状態へ
```

同じ22bit加算器を繰り返し使用する。

---

## 回答計算

Qの順位計算終了時、`rank_work`には`rank(Q)`が保存されている。

次の条件で回答を求める。

```text
if rank_work > rank_p + 1:
    answer = rank_work - rank_p - 1
else:
    answer = 0
```

PとQの辞書順が逆の場合や、隣接している場合は0を返す。

---

## 回答フォーマット

回答はステータス1byteと回答3byteで返す。

```text
byte 0 : STATUS
byte 1 : answer[23:16]
byte 2 : answer[15:8]
byte 3 : answer[7:0]
```

回答値は22bitなので、`answer[23:22]`は0とする。

STATUSの形式は次のとおり。

```text
bit 7   : VALID
bit 6   : ERROR
bit 5:0 : 0
```

例:

```text
0x00 : 未完了
0x80 : 正常完了
0xC0 : エラー付き完了
```

RP2040側はNOPを送信してSTATUSをポーリングする。

VALIDが1になった後、NOPを3byte送信して回答を受信する。

SPIの1byte応答遅延を考慮すること。

---

## エラー検出

次の条件を検出した場合、`protocol_error`をセットする。

```text
Nが1から10の範囲外
順列要素が0
順列要素がNより大きい
同じ数字が順列内で複数回出現
現在のbyteを処理中に次のbyteを受信
想定外の状態でデータを受信
```

`protocol_error`はRESETまで保持するsticky bitとする。

入力値はAtCoder側で保証されているため、エラー検出回路を過度に複雑化しないこと。

---

## RESET動作

RESET受信時は、SPIテンプレートV3の既存動作を維持する。

少なくとも次の状態を初期化する。

```text
n_reg
sequence_phase
digit_index
current_value
candidate
used_mask
rank_work
rank_p
answer
rx_byte_buffer
nibble_select
protocol_error
reply_valid
```

RESET_ACKの返送方法もSPIテンプレートV3に合わせる。

---

## 実装上の注意

* `spi_target.v`は原則として変更しない
* 入力されたPとQ全体をメモリへ保存しない
* 受信した順列要素をその場で処理する
* P用とQ用の順位計算回路を別々に作らない
* 候補数字を並列に数えるpopcount回路を作らない
* 可変乗算器を使用しない
* 候補数字をFSMで順番に確認する
* 同じ加算器を繰り返し使用する
* 既存SPIテンプレートV3の通信方式を維持する
* 不要な抽象化や大規模な構造変更を行わない

---

## MicroPythonテスト

`abc468c_test.py`へ複数のテストケースを埋め込む。

各テストケースについて次を行う。

```text
RESET
RESET_ACK確認
START
START_ACK確認
SEND_N
SEND_P
SEND_Q
回答ポーリング
回答受信
期待値との比較
```

ログには少なくとも次を表示する。

```text
NAME
N
P
Q
RESULT
EXPECT
VALID
ERROR
PASS
TIME_US
RX
POLL_COUNT
RESET_ACK_RX
START_ACK_RX
```

---

## 必須テストケース

少なくとも次を含める。

```text
N = 1
PとQが同じ
PとQが辞書順で隣接
P < Q
P > Q
Pが最小順列
Qが最大順列
N = 10
```

Python側で順列の辞書順順位を計算し、期待値を自動生成してよい。

FPGA側と同じアルゴリズムをそのまま複製するのではなく、Python標準機能などを利用した別方式で期待値を求めることが望ましい。

---

## 完了条件

次のすべてを満たしたら実装完了とする。

```text
Verilogが合成可能
SPIテンプレートV3のRESET/START通信が動作
PとQを4bitパックしたバーストで送信可能
PとQの順位を同じ回路で計算
候補走査で同じ加算器を繰り返し使用
回答を24bit形式で返送
全テストケースがPASS
protocol_errorが正しく動作
```
