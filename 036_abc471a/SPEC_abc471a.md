# ABC471A FPGA実装仕様

## 目的

AtCoder ABC471A「Nine or Nein」の回答を、Shrike-Lite上のFPGAで計算する。

正の整数 `A`, `B` に対して、次の4つの値のうち少なくとも1つが9に等しいかを判定する。

```text
A + B
A - B
A * B
A / B
```

1つでも9に等しければ `Nine`、1つも等しくなければ `Nein` とする。

FPGAからは文字列そのものではなく、判定結果を1bit相当の値として返し、MicroPython側で `Nine` / `Nein` に変換する。

---

## 問題概要

制約は次のとおり。

```text
1 <= A <= 100
1 <= B <= 100
```

論理的な入力形式は次のとおり。

```text
A B
```

FPGAへの実際の転送形式は、後述するSPI入力送信仕様に従う。

---

## 公式サンプル

### サンプル1

```text
A = 16
B = 7
EXPECT = Nine
```

`A - B = 9`。

### サンプル2

```text
A = 66
B = 7
EXPECT = Nein
```

4つの値のいずれも9ではない。

### サンプル3

```text
A = 9
B = 1
EXPECT = Nine
```

`A * B = 9` および `A / B = 9`。

### サンプル4

```text
A = 9
B = 9
EXPECT = Nein
```

---

## 開発方針

既存のSPIテンプレートV3をベースに実装する。

SPI通信回路と基本プロトコルは可能な限り変更しない。

主な変更対象は次の2ファイルとする。

```text
ffpga/src/main.v
firmware/micropython/abc471a_test.py
```

`ffpga/src/spi_target.v` は原則として変更しない。

ABC468C固有の順位計算、階乗、順列処理、4bitパック処理などは使用しない。

回路はABC471Aに必要な最小構成とし、不要な抽象化や汎用演算器を追加しない。

---

## ディレクトリ構成

```text
abc471a/
│  abc471a.ffpga
│  SPEC.md
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
├─firmware
│  └─micropython
│          abc471a_test.py
│
└─reference
    ├─abc468c/
    └─atcoder_spi_template_v3/
```

`reference/` 以下は参照専用とし、変更しない。

---

## SPI基本プロトコル

SPIテンプレートV3の制御値を使用する。

| 用途        | 値 |
|---|---:|
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
SEND_AB
NOPで回答ポーリング
VALID付き回答受信
```

---

## 入力送信仕様

`A`, `B` はどちらも `1..100` なので、それぞれ1byteで送信する。

```text
byte 0 : A
byte 1 : B
```

例:

```text
A = 16
B = 7

送信データ = [0x10, 0x07]
```

`A`, `B` の2byteは1回のSPIバーストで送信する。

追加の入力コマンドは使用しない。

START受信後、FPGAは次の2byteを順番に `A`, `B` として解釈する。

---

## FPGA側の判定方法

4つの条件を独立した判定回路として並列に評価する。

概念的な条件は次のとおり。

```text
sum_nine = (A + B == 9)
sub_nine = (A - B == 9)
mul_nine = (A * B == 9)
div_nine = (A / B == 9)

nine = sum_nine | sub_nine | mul_nine | div_nine
```

ただし、実装では汎用除算器や汎用乗算器を使用しない。

---

## 加算条件

```text
A + B == 9
```

を直接判定する。

`A`, `B` は最大100なので、加算結果は8bitで保持できる。

---

## 減算条件

`A`, `B` は正の整数なので、

```text
A - B == 9
```

は次と等価である。

```text
A == B + 9
```

負数を扱う必要はない。

---

## 乗算条件

正の整数 `A`, `B` について、

```text
A * B == 9
```

となる組は次の3通りだけである。

```text
(A, B) = (1, 9)
(A, B) = (3, 3)
(A, B) = (9, 1)
```

したがって、汎用乗算器は使用せず、比較回路だけで判定する。

概念的には次のとおり。

```text
mul_nine =
    (A == 1 && B == 9) ||
    (A == 3 && B == 3) ||
    (A == 9 && B == 1)
```

---

## 除算条件

`B` は正の整数なので、

```text
A / B == 9
```

は次と等価である。

```text
A == 9 * B
```

除算器は使用しない。

`9 * B` は定数乗算なので、必要なら次のようにshiftと加算で実装する。

```text
9 * B = (B << 3) + B
```

`B <= 100` なので、中間値は11bitあれば十分である。

---

## 最終判定

4つの条件をORして最終結果を得る。

```text
nine =
    sum_nine |
    sub_nine |
    mul_nine |
    div_nine
```

各条件は同じ入力 `A`, `B` から独立に求められるため、逐次FSMで1条件ずつ計算する必要はない。

`B` の受信完了後、判定用状態へ進み、並列判定した結果を `answer` へ保存する。

---

## 想定する主要レジスタ

名称は既存コードとの整合に応じて変更してよい。

| レジスタ | 幅 | 用途 |
|---|---:|---|
| `a_reg` | 8bit | A |
| `b_reg` | 8bit | B |
| `input_index` | 1bit程度 | A/B受信位置 |
| `answer` | 1bit | `1=Nine`, `0=Nein` |
| `protocol_error` | 1bit | sticky error |
| `reply_valid` | 1bit | 回答有効 |

判定条件そのものをレジスタとして保持する必要はない。

---

## 想定するFSM処理

状態名は既存の `main.v` に合わせて変更してよい。

概念的には次の処理を行う。

```text
WAIT_START
RECEIVE_A
RECEIVE_B
CALC
PREPARE_REPLY
SEND_REPLY
```

`CALC` では4条件を並列に評価する。

ABC468Cのような反復計算用FSMは不要である。

---

## 回答フォーマット

回答は1byteで返す。

```text
bit 7   : VALID
bit 6   : ERROR
bit 5:1 : 0
bit 0   : ANSWER
```

ANSWERは次のとおり。

```text
0 : Nein
1 : Nine
```

代表的な返値は次のとおり。

```text
0x00 : 未完了
0x80 : 正常完了 / Nein
0x81 : 正常完了 / Nine
0xC0 : エラー付き完了 / Nein
0xC1 : エラー付き完了 / Nine
```

RP2040側はNOPを送信して回答byteをポーリングする。

SPIには1byteの応答遅延があるため、送信したNOPに対して返るbyteのVALID bitを確認する。

VALIDが1になったbyteにはANSWERも含まれているため、追加のRESULT受信は行わない。

MicroPython側では次のように解釈する。

```text
VALID  = reply & 0x80
ERROR  = reply & 0x40
ANSWER = reply & 0x01

ANSWER == 1 -> "Nine"
ANSWER == 0 -> "Nein"
```

---

## エラー検出

次の条件を検出した場合、`protocol_error` をセットする。

```text
Aが1から100の範囲外
Bが1から100の範囲外
想定外の状態で入力データを受信
```

`protocol_error` はRESETまで保持するsticky bitとする。

入力値はAtCoder側で保証されているため、エラー検出回路を過度に複雑化しない。

---

## RESET動作

RESET受信時はSPIテンプレートV3の既存動作を維持する。

少なくとも次の状態を初期化する。

```text
a_reg
b_reg
input_index
answer
protocol_error
reply_valid
```

RESET_ACKの返送方法もSPIテンプレートV3に合わせる。

---

## 実装上の注意

- `spi_target.v` は原則として変更しない
- SPIテンプレートV3のRESET/START/NOP通信方式を維持する
- `A`, `B` は各1byteで受信する
- 4つの条件は可能な限り並列に判定する
- 汎用除算器を使用しない
- `A * B == 9` のためだけに汎用乗算器を使用しない
- `A / B == 9` は `A == 9 * B` へ変形する
- 不要なメモリを使用しない
- 不要な抽象化や大規模な構造変更を行わない

---

## MicroPythonテスト

`abc471a_test.py` へ複数のテストケースを埋め込む。

各テストケースについて次を行う。

```text
RESET
RESET_ACK確認
START
START_ACK確認
SEND_AB
NOPで回答ポーリング
VALID付き回答受信
期待値との比較
```

ログには少なくとも次を表示する。

```text
NAME
A
B
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

### 公式サンプル

```text
A=16, B=7  -> Nine
A=66, B=7  -> Nein
A=9,  B=1  -> Nine
A=9,  B=9  -> Nein
```

### 各条件の単独確認

```text
A=4,  B=5  -> Nine   # A+B == 9
A=16, B=7  -> Nine   # A-B == 9
A=3,  B=3  -> Nine   # A*B == 9
A=18, B=2  -> Nine   # A/B == 9
```

### 境界・否定ケース

少なくとも次を含める。

```text
A=1,   B=1
A=1,   B=100
A=100, B=1
A=100, B=100
A=8,   B=1
A=10,  B=1
```

期待値はMicroPython側でも独立に計算してよい。

浮動小数点除算は使用せず、次の論理で期待値を求める。

```text
expected_nine =
    (A + B == 9) or
    (A - B == 9) or
    (A * B == 9) or
    (A == 9 * B)
```

---

## シミュレーションテスト

入力空間は `100 * 100 = 10000` 通りしかないため、Icarus Verilogによるホスト側テストでは全組み合わせを確認する。

```text
A = 1..100
B = 1..100
```

全10000ケースについて、RTLの結果とソフトウェア基準値が一致することを確認する。

実機MicroPythonテストで10000ケースすべてを実行することは必須としない。

---

## 完了条件

次のすべてを満たしたら実装完了とする。

```text
Verilogが合成可能
SPIテンプレートV3のRESET/START通信が動作
A,Bを各1byteで送受信可能
4条件を並列判定
汎用除算器を使用しない
A*B==9判定に汎用乗算器を使用しない
VALID/ERROR/ANSWERを1byteにまとめて返送
公式4サンプルがPASS
各条件の単独確認がPASS
IcarusでA,Bの全10000組み合わせがPASS
protocol_errorが正しく動作
実機MicroPythonテストがPASS
```
