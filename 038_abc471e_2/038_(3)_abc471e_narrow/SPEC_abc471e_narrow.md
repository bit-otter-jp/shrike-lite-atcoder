# ABC471E Narrow - SPEC

## 1. 文書の役割

この文書は `abc471e_narrow` の**外部要求仕様と外部制約**を定義する。

ここに記述する内容は、問題設定、対象ハードウェア、通信仕様、入力条件、出力条件など、
実装内部の都合では変更しない事項である。

内部アーキテクチャ、レジスタ共有、FSM構成、演算器構成、実験手順は本書では規定しない。

それらは次で管理する。

```text
IMPL_abc471e_narrow.md
WORK_REQUEST_abc471e_narrow.md
```

参照資料の実体パスは `REFERENCE_MAP.md` で管理する。

---

## 2. 目的

AtCoder ABC471E「Sum of Square of Sum」と同じ数学を、
Shrike-Lite上で扱える狭い数値世界へ縮小して実装する。

N個の値 `A1..AN` からK個を選び、
選んだ値の和を2乗した値を全ての選び方について加算し、
設定された素数 `MOD` で割った余りを回答する。

各実験点では数値幅 `WIDTH` を持つ。

`WIDTH` ごとの具体的な値や実験順序はSPECでは固定せず、
`WORK_REQUEST` で指定する。

---

## 3. 数学的仕様

回答は次で定義する。

```text
answer =
    Σ ( Σ Ai )^2 mod MOD
```

外側の総和は、N個からK個を選ぶ全ての組合せについて取る。

順序は区別しない。

入力配列そのものの並び順によって回答が変わってはいけない。

---

## 4. 数値世界

各実験構成は次を満たす。

```text
WIDTH >= 1

MOD is prime
0 < MOD < 2^WIDTH

1 <= N_MAX < MOD

1 <= N <= N_MAX
1 <= K <= N

0 <= Ai < MOD
```

`N_MAX < MOD` を必須とする。

これは組合せ係数を `mod MOD` で扱う際に、
有効範囲内の整数1..Nが0 mod MODにならない世界を定義するためである。

`WIDTH`、`MOD`、`N_MAX` の具体値は実験ごとに `WORK_REQUEST` で指定する。

---

## 5. 対象ハードウェア

対象はShrike-Lite上のForgeFPGAである。

外部クロックおよびSPI接続は既存のABC471E S1/S2版と同じ環境を基準とする。

面積評価ではShrike-Liteの実デバイス容量を基準とする。

```text
Type=L capacity = 140
```

あるWIDTHでfitしないこと自体は仕様違反ではない。

本プロジェクトは、どのWIDTHまで実装可能かを実験することも目的に含む。

---

## 6. SPI外部仕様

SPI外部仕様は既存ABC471E S1/S2版と互換とする。

基本値:

| 用途 | 値 |
|---|---:|
| NOP | `0x00` |
| DEBUG | `0xFD` |
| START | `0xFE` |
| RESET | `0xFF` |
| RESET_ACK | `0x5A` |
| START_ACK | `0xA5` |

SPIクロックの基準は4MHz。

応答は1byte遅延。

基本シーケンス:

```text
RESET
RESET_ACK確認
START
START_ACK確認
SEND_N
SEND_K
SEND_A_STREAM
STATUS polling
ANSWER受信
```

---

## 7. N / K / Ai の転送形式

SPI上では `N`、`K`、`Ai` を32bit unsigned big-endianで転送する。

```text
byte 0 : value[31:24]
byte 1 : value[23:16]
byte 2 : value[15:8]
byte 3 : value[7:0]
```

送信順:

```text
N
K
A1
A2
...
AN
```

`WIDTH` が8bitや10bitであっても、外部SPI framingは32bitのまま維持する。

---

## 8. payload中の予約値

N/K/A payload受信中は、byte値をコマンドとして解釈しない。

したがってpayload中の、

```text
0x00
0xFD
0xFE
0xFF
```

は通常データとして扱う。

特にpayload中の `0xFF` によりRESETしてはいけない。

---

## 9. 入力妥当性

最低限、次を不正入力として検出する。

```text
N == 0
N > N_MAX

K == 0
K > N

Ai >= MOD
```

また既存SPI protocolと同様に、

```text
32bit word完成時に前のAi処理がbusy
N個処理後の余分なpayload
想定外状態でのpayload
```

をprotocol errorとして扱う。

`protocol_error` はRESETまでstickyとする。

---

## 10. 回答フォーマット

回答は既存S1/S2版と同じく、

```text
STATUS 1byte
ANSWER 4byte
```

とする。

ANSWERは32bit unsigned big-endian。

`answer < MOD < 2^WIDTH` であるため、
上位未使用bitは0とする。

STATUS:

```text
bit 7   : VALID
bit 6   : ERROR
bit 5:0 : 0
```

代表値:

```text
0x00 : 未完了
0x80 : 正常完了
0xC0 : エラー付き完了
```

既存S1/S2版で修正済みのSTATUS polling境界動作を維持する。

---

## 11. RESET外部動作

RESETまたは外部reset後は、新しい計算を開始できる初期状態へ戻る。

前回計算の、

```text
answer
VALID
ERROR
受信途中状態
計算途中状態
```

を次回計算へ持ち越してはいけない。

---

## 12. 正しさ

有効入力に対する回答は、独立なソフトウェア基準値と一致しなければならない。

小さいNについては全組合せ列挙を正解基準として使用できる。

基準値生成コードは、FPGA内部アルゴリズムをそのまま模倣するのではなく、
問題定義から独立に計算する。

---

## 13. 参照基準

30bit版との比較には `REFERENCE_MAP.md` の次の論理参照を使用する。

```text
S1S2_30BIT_BASELINE
S1S2_30BIT_AREA_ANALYSIS
S1S2_30BIT_DIAGNOSTIC
FORGE_SYNTH_CLI_REFERENCE
```

物理パスは本SPECへ埋め込まない。

---

## 14. SPECで規定しない事項

次は内部設計または作業手順であり、本SPECでは固定しない。

```text
S1/S2をどのレジスタへ置くか
multiplierの内部構造
add/subの共有方法
FSM状態数
scratch register共有
組合せ係数の具体的実装手順
1演算のクロック数
WIDTH sweepの開始値・終了値
合成を何回行うか
PNRをいつ行うか
成果物ディレクトリ構成
```

これらは `IMPL` または `WORK_REQUEST` で定義する。

---

## 15. SPEC変更原則

性能や面積が改善するという理由だけで、本SPECを変更しない。

SPEC変更が必要な場合は、

```text
外部要求
対象ハードウェア
問題世界
通信契約
入力範囲
出力契約
```

のいずれかを意図的に変更する別実験として扱う。
