# ABC471E AtCoder Verilog - WORK_REQUEST_2

## 1. 目的

AtCoderの「コードテスト」で提出用Verilogを実際に確認するため、**N=200000の最大N入力を、入力テキスト500,000 byte未満に収めて作成する。**

あわせて、

```text
正答
入力サイズ
SHA-256
ローカルIcarusでの実行結果
```

を確定する。

AtCoderへの本提出はまだ行わない。

---

## 2. 前提

WORK_REQUEST_1で作成した最終版を使用する。

対象:

```text
abc471e.v
```

WORK_REQUEST_1の確認済み結果:

```text
公式サンプル       3/3 PASS
境界ケース         9/9 PASS
独立ランダム     300/300 PASS
N=200000最大ケース 3/3 PASS
最終実時間         1.381～1.409秒
Peak Working Set   約9.3 MiB
```

今回、RTLのアルゴリズム変更や高速化は行わない。

---

## 3. コードテスト用入力の条件

次を満たす決定的な入力を1件作成する。

```text
N = 200000
K = 100000
```

`Ai` はABC471Eの公式制約内とする。

入力全体は、

```text
500000 byte 未満
```

にする。

AtCoderコードテストへコピーしやすい通常のテキスト形式とする。

---

## 4. Aiの作り方

入力サイズを抑えるため、基本値は1桁の小さい整数を使う。

ただし、小さい値だけでは入力値正規化などの確認が弱いため、周期的に大きい値も混ぜる。

少なくとも次の値を含める。

```text
1
2
3
998244352   # MOD-1
998244353   # MOD
998244354   # MOD+1
1000000000
```

大きい値の出現頻度は、入力全体が500000 byte未満に収まるよう調整する。

配列生成は決定的な規則とし、乱数を使う場合も固定seedとする。

最終REPORTには、Ai生成規則を人間が再現できる形で記載する。

---

## 5. 入力サイズ確認

生成後、ファイルの実byte数を取得する。

対象:

```text
abc471e_code_test.in
```

必須条件:

```text
size < 500000 bytes
```

500000 byte以上の場合はAi生成規則を調整して再生成する。

改行コードによる差を避けるため、最終成果物の実ファイルそのものについてbyte数を測定する。

---

## 6. 正答計算

コードテスト入力の正答を、提出用Verilogとは独立したPython実装で計算する。

期待値計算では、Python標準の整数演算・`math.comb`等を使用してよい。

FPGA向け逐次演算やVerilog内部処理を模倣する必要はない。

正答を、

```text
EXPECTED_ANSWER
```

としてREPORTへ明記する。

---

## 7. SHA-256

最終入力ファイルについてSHA-256を計算し、REPORTへ記録する。

```text
abc471e_code_test.in
size    = ...
sha256  = ...
answer  = ...
```

これにより、AtCoderへ貼り付ける入力とローカル検証した入力が同一であることを確認できるようにする。

---

## 8. ローカル最終確認

WORK_REQUEST_1の最終 `abc471e.v` を使用し、コードテスト用入力をIcarusで実行する。

コンパイル条件:

```powershell
iverilog -g2012 -Wall -s main -o abc471e.out abc471e.v
```

実行:

```powershell
vvp abc471e.out < abc471e_code_test.in
```

確認項目:

```text
終了コード = 0
標準エラー = 空
標準出力 = 正答1行のみ
出力値 = EXPECTED_ANSWER
```

実時間も1回測定してREPORTへ記録する。

---

## 9. 成果物

最低限、次を作成する。

```text
abc471e_code_test.in
REPORT_abc471e_code_test.md
```

必要なら入力生成用の補助スクリプトを追加してよい。

例:

```text
make_code_test_case.py
```

ただし、既存の `abc471e.v` は変更しない。

---

## 10. REPORTに記録する内容

`REPORT_abc471e_code_test.md` には最低限次を記載する。

```text
N
K
Ai生成規則
入力byte数
SHA-256
期待値
Icarus出力
一致確認
ローカル実時間
使用したabc471e.vのSHA-256
```

また、入力がAtCoderコードテストへ貼り付ける目的で500000 byte未満に調整されていることを明記する。

---

## 11. 停止条件

次をすべて満たした時点で停止する。

```text
N=200000
入力500000 byte未満
正答確定
SHA-256確定
ローカルIcarus PASS
REPORT作成完了
```

AtCoderコードテストへの入力操作、およびAtCoderへの本提出は行わない。

最終的に、

```text
入力ファイル
入力byte数
SHA-256
正答
ローカル実行結果
```

を報告して停止する。
