# ABC470D Out-of-Order 並列実行 実装要求

## 1. 前提

以下の2段階は完成済み成果物として扱う。

### Baseline

- `abc470d_baseline.sv`
- `DESIGN_BASELINE.md`
- `MEASUREMENT_BASELINE.md`

### 固定幅並列版

- `abc470d_fixed_parallel.sv`
- `DESIGN_FIXED_PARALLEL.md`
- `MEASUREMENT_FIXED_PARALLEL.md`
- `measurements/fixed_parallel_results.csv`

これら既存成果物は**変更しないこと**。

作業開始前に主要既存成果物の SHA-256 を記録し、完了時に不変を確認すること。

固定幅並列版の測定結果から、次段階の基準は以下とする。

```text
ISSUE_WIDTH = 256
LOOKAHEAD   = 1024
```

今回の目的は、並列幅そのものをさらに増やすことではない。

**256本の実行レーンを維持したまま、最大1024件の未処理クエリを見渡し、依存関係を壊さない範囲で後続の独立クエリを先に実行する。**

さらに、ABC470D固有の安全な最適化として、実行前にクエリ列を簡約する。

- 互いに独立な処理だけを挟んだ完全同一 swap のペアを相殺する。
- 連続する Type 2 は反転回数の偶奇だけが意味を持つため、偶数個なら全削除、奇数個なら1件へ圧縮する。
- 相殺によって新たな相殺条件が生じた場合は、安全条件を満たす範囲で再度簡約する。

---

## 2. 今回の目的

固定幅版では、未処理先頭からの連続 prefix の途中で1件でも位置競合すると、そのlogical clockのグループ形成を終了した。

今回のOut-of-Order版では、競合したクエリを待機させたまま、その後ろにある独立クエリを最大 `ISSUE_WIDTH=256` 件まで拾って同じlogical clockで実行する。

例:

```text
A: swap 1 2
B: swap 2 3
C: swap 4 5
D: swap 3 6
E: swap 7 8
```

この場合、

```text
A: 実行可能
B: Aに依存するため待機
C: A/Bのどちらにも依存しないため実行可能
D: 待機中のBに依存するため待機
E: 独立なので実行可能
```

従って、同一logical clockで

```text
A, C, E
```

を実行してよい。

`B`, `D` は元の相対順序を保って未処理のまま残す。

---

## 3. 基本パラメータ

初期実装では以下を固定する。

```text
ISSUE_WIDTH = 256
LOOKAHEAD   = 1024
```

可能ならparameter化すること。

ただし今回の主目的はLOOKAHEAD値の大規模な探索ではない。

まず `256 / 1024` の構成を正しく実装・評価することを優先する。

---

## 4. 未処理クエリ列の定義

Out-of-Order実行後は入力配列中に「実行済みの穴」が生じ得る。

従って `LOOKAHEAD=1024` は単純な生の配列添字1024個ではなく、

**元の入力順を保った「先頭から最大1024件の未処理クエリ」**

を意味する。

実装方法は問わない。

例えば以下のいずれでもよい。

- `query_done[]` とhead pointerを使う
- pending windowを別途保持する
- 未処理クエリを論理的にcompactする

ただし、未処理クエリ同士の元の相対順序は必ず保存すること。

---

## 5. Type 2 の扱い

Type 2:

```text
2
```

はOut-of-Order実行のbarrierとする。

ただし、**normalization段階で隣接するType 2同士を相殺することは許可する**。

例えば、

```text
2
2
```

は恒等操作なので両方削除してよい。

連続するType 2が `m` 件ある場合は、

```text
m が偶数: 全削除
m が奇数: Type 2を1件だけ残す
```

としてよい。

normalization後に残ったType 2は完全なbarrierである。

先読み窓内に残存Type 2が存在する場合、**最初の残存Type 2より後ろのクエリはOoO発行対象にしない**。

Type 2より前のType 1はOut-of-Order発行してよい。

Type 2より前の未処理Type 1がすべて処理または安全に相殺され、Type 2が未処理先頭になったら、そのType 2を単独1 logical clockで実行する。

残存Type 2を越える投機実行は禁止する。

---

## 6. Out-of-Order 発行ルール

相殺処理後の未処理Type 1列について、元の順番で最大 `LOOKAHEAD` 件まで走査する。

最初のType 2に到達したら走査を終了する。

走査中は、そのクエリより前に存在する**すべての未処理Type 1**が触れた位置を依存情報として扱う。

Type 1:

```text
1 x y
```

について、

- `x`
- `y`

のどちらも、それ以前の未処理Type 1で触れられていなければ、そのクエリは現在のlogical clockでreadyである。

readyなクエリを入力順に最大 `ISSUE_WIDTH` 件まで選び、同一logical clockで実行する。

重要:

**依存情報へ登録するのは「今回採用したクエリ」だけではない。走査済みの全未処理クエリである。**

これにより、待機中の依存クエリを後続クエリが不正に追い越すことを防ぐ。

---

## 7. 発行例

```text
q0: swap 1 2
q1: swap 2 3
q2: swap 4 5
q3: swap 3 6
q4: swap 7 8
```

走査:

```text
q0:
  earlier touched positions = {}
  -> ready
  touched = {1,2}

q1:
  2が既出
  -> wait
  touched = {1,2,3}

q2:
  4,5とも未出
  -> ready
  touched = {1,2,3,4,5}

q3:
  3が既出
  -> wait
  touched = {1,2,3,4,5,6}

q4:
  7,8とも未出
  -> ready
```

このlogical clockでは、

```text
q0, q2, q4
```

を同時実行する。

残りは、

```text
q1, q3
```

の順序を保って次回以降へ残す。

---

## 8. 同時実行の安全性

同一logical clockで発行するType 1群は、論理位置 `x`,`y` が互いにすべて異なる。

固定幅版と同様、順列の単射性により、現在側配列から読んだ値もすべて異なる。

従って、

- 現在側 `p` または `pinv` のWrite先
- 反対側 `pinv` または `p` のWrite先

はいずれも同一logical clock内で競合しない。

全発行レーンは同じlogical clock開始時状態を読むこと。

`p` / `pinv` の更新には、固定幅版と同様にnonblocking assignmentを使用してよい。

---

# 9. 完全同一 swap の安全な相殺

今回、ABC470D固有の追加最適化として、次の条件を満たす完全同一Type 1ペアを実行前に削除してよい。

例:

```text
A: swap 1 2
B: swap 3 4
C: swap 5 6
D: swap 1 2
```

`B`, `C` は `{1,2}` に触れない。

従って、

```text
swap(1,2)
...
swap(1,2)
```

の間に `{1,2}` へ触れる未処理クエリが存在しないため、2回の同一swapは互いに相殺する。

結果は、

```text
B
C
```

だけを実行した場合と等しい。

---

## 10. 相殺の許可条件

2つの未処理Type 1 `qj`, `qi` (`j < i`) を相殺してよいのは、最低限以下をすべて満たす場合だけとする。

1. 両方がType 1である。
2. `x`,`y` が完全一致する。
3. normalization後の `qj` と `qi` の間に残存Type 2がない。
4. `qj` と `qi` の間にある**現在liveな未処理Type 1**のどれも、`x` または `y` に触れない。
5. 両方が現在の先読み範囲内に存在する。
6. 相殺判定はOut-of-Order発行より前に行う。

この条件なら、間の全swapは `swap(x,y)` と可換であり、

```text
swap(x,y) * independent_operations * swap(x,y)
```

は

```text
independent_operations
```

と同じ結果になる。

残存Type 2をまたぐType 1相殺は禁止する。Type 2の偶数個相殺によってbarrier自体が消滅した場合は、その後の再走査で新たに安全なType 1相殺が成立してよい。

---

## 11. normalization と cascading cancellation

今回の相殺処理は、単発のpeephole削除ではなく、**安全な簡約がなくなるまで繰り返すnormalization**として扱ってよい。

### Type 1 の cascading cancellation

ペアを削除したことで、さらに安全な完全同一swapペアが露出する場合がある。

例:

```text
A
B
B
A
```

依存条件を満たす場合、

```text
B B
```

の相殺後に

```text
A A
```

も相殺できる。

### Type 2 の cancellation

連続するType 2は反転回数の偶奇だけが意味を持つ。

```text
2
2
```

は削除する。

```text
2
2
2
```

は1件のType 2へ圧縮してよい。

### Type 1 / Type 2 をまたぐ cascading

他の相殺によってType 2同士が新たに隣接した場合、そのType 2ペアも削除してよい。

例:

```text
2
A
A
2
```

`A A` が安全に相殺できるなら、

```text
2
2
```

が残り、さらに両Type 2を相殺して全体を削除できる。

同様に、

```text
A
2
2
A
```

ではType 2ペアを先に削除した結果、

```text
A
A
```

が残る。

その時点でType 1の安全条件を満たすなら、さらに `A A` を相殺してよい。

従って、normalizationは削除によって新しい簡約機会が生じなくなるまで繰り返してよい。

実装方法は問わない。

例えば、

- 削除後に依存情報を再構築して再走査する
- stack / previous pointer等で簡約可能性を追跡する
- 安全な等価アルゴリズムを使う

などでよい。

ただし、

**単純なlast-touch clearによって過去の依存情報を失い、不正な相殺を発生させないこと。**

また、Type 1の相殺判定では、normalization後に残っているType 2をbarrierとして扱うこと。

normalization処理は理想FPGAモデル上、logical clockを消費しない組み合わせ処理として扱う。

Icarus上の実処理時間は通常どおり測定対象である。

---

## 12. 相殺とlogical clock

normalizationで相殺・圧縮されたクエリは、削除された分について実行されない。

従って削除されたType 1およびType 2はlogical clockを消費しない。奇数個の連続Type 2を1件へ圧縮した場合は、残った1件だけが単独1 logical clockを消費する。

相殺処理だけのために空のlogical clockを追加してはならない。

相殺によって先頭Type 1群がすべて消え、

- Type 2が先頭になった場合は、そのType 2の実行へ進む
- 全クエリが完了した場合は、回答格納へ進む

こと。

---

## 13. 比較用モード

相殺最適化そのものの効果を分離して確認するため、可能なら以下の2モードを同じOut-of-Order実装で切り替えられるようにする。

```text
ENABLE_CANCEL = 0
ENABLE_CANCEL = 1
```

### OoO only

```text
ISSUE_WIDTH=256
LOOKAHEAD=1024
ENABLE_CANCEL=0
```

### OoO + cancellation

```text
ISSUE_WIDTH=256
LOOKAHEAD=1024
ENABLE_CANCEL=1
```

最終報告では両者を比較する。

---

## 14. 実装前の設計文書

まず、

```text
DESIGN_OUT_OF_ORDER.md
```

を作成すること。

最低限、以下を記述する。

1. 未処理クエリ管理方法
2. 1024件lookaheadの作り方
3. ready判定アルゴリズム
4. 待機クエリを後続が不正に追い越さない理由
5. 256件同時実行時のWrite競合不在証明
6. Type 2 barrierの扱い
7. 完全同一swap相殺の安全条件
8. cascading cancellationの扱い
9. logical clockの数え方
10. テスト計画
11. 性能測定計画

設計の妥当性を確認してから、そのまま実装・テスト・測定まで進めること。

---

## 15. 正しさテスト

既存テストと同等以上の検証を行う。

最低限、以下を含める。

### 基本

- 公式3例
- 境界ケース
- Python逐次参照実装とのランダム比較
- 最終回答の一致
- logical clock数の独立Pythonモデルとの一致

### OoO固有

- 先頭に依存チェーンがあり、その後ろの独立クエリを先に発行できる
- 待機中クエリと依存する後続を追い越さない
- 複数段の依存チェーン
- 256件issue幅境界
- 1024件lookahead境界
- Type 2手前のType 1はOoO可能
- Type 2より後ろは絶対に先行実行しない
- 実行済み穴が多数ある状態でも未処理順序を維持する

### cancellation固有

以下を明示的にテストする。

#### 相殺可能

```text
swap 1 2
swap 3 4
swap 1 2
```

#### 相殺不可: 間で同じ位置に触れる

```text
swap 1 2
swap 2 3
swap 1 2
```

#### 相殺不可: Type 2をまたぐ

```text
swap 1 2
2
swap 1 2
```

#### cascading cancellation

```text
swap 1 2
swap 3 4
swap 3 4
swap 1 2
```

#### Type 2 cancellation

```text
2
2
```

が0件へ削減されること。

```text
2
2
2
```

が1件へ圧縮されること。

#### Type 1削除後にType 2が相殺

```text
2
swap 1 2
swap 1 2
2
```

が安全条件を満たす場合、最終的に全4件を削除できること。

#### Type 2削除後にType 1が相殺

```text
swap 1 2
2
2
swap 1 2
```

ではType 2ペア削除後、残ったswapペアが安全条件を満たせばさらに削除できること。

#### lookahead境界

同一swapの2件が同じlookahead内に入る場合／入らない場合を確認する。

Type 2相殺についても、normalization対象範囲外のクエリを不正に利用しないことを確認する。

`ENABLE_CANCEL=0` と `1` の最終回答が常に一致することも確認する。

---

## 16. 独立Pythonモデル

Python側に、Verilog実装とは独立した以下のモデルを作ること。

1. ABC470D逐次参照実装
2. OoO schedulerモデル
3. Type 1 / Type 2 normalization・cancellationモデル
4. logical clock計算

Verilogと同じコード構造をそのまま写すのではなく、意味上独立した検証モデルにすること。

最終回答だけでなく、

- logical clock数
- 実行されたType 1数
- 相殺されたType 1数

も可能なら照合すること。

---

# 17. 性能測定

以下を比較する。

```text
1. Baseline K=1
2. Fixed Parallel K=256
3. OoO 256/1024, cancellation OFF
4. OoO 256/1024, cancellation ON
```

既存Baseline・Fixed成果物は変更しない。

測定条件は従来と揃える。

```text
iverilog -g2012 -DONLINE_JUDGE -DATCODER
vvp -n
```

各条件3回測定し、`vvp` 実時間は中央値を採用する。

Peak Working Setは3回中最大を記録する。

入力生成・コンパイル・Python出力照合時間は `vvp` 実時間に含めない。

全出力をトークン単位で検証する。

---

## 18. 性能測定ケース

`N=Q=500000` を基本とし、少なくとも以下を測定する。

### A. 高並列

固定幅版でも得意なケース。

目的:

- OoO化による余計な損失を見る
- scheduler overheadを見る

### B. ランダム

固定seedを使用する。

目的:

- 通常の位置衝突下でOoOがどの程度空きレーンを埋めるかを見る

### C. 高競合

```text
1 1 500000
```

を反復する。

目的:

- OoOでも救えない最悪ケース
- lookahead / dependency scanの純粋なペナルティを見る

### D. Interleaved dependency

OoOの主効果が出るように、依存チェーンと独立swapを交互に混ぜる。

概念例:

```text
hotspot swap
independent swap
hotspot-dependent swap
independent swap
hotspot-dependent swap
independent swap
...
```

固定prefix版では早い位置の競合によってグループが小さくなる一方、OoO版では後方の独立swapを拾って256レーンを埋められる入力にする。

### E. Cancellation-rich

安全な完全同一swap相殺が多数発生する入力を作る。

概念例:

```text
swap A
independent operations
swap A
swap B
independent operations
swap B
...
```

`ENABLE_CANCEL=0` と `1` の差が明確に観測できるケースにする。

期待最終回答は逐次Python参照実装で生成し、全要素を検証する。

---

## 19. 記録する指標

各実装・各ケースについて最低限、以下を記録する。

```text
logical clocks
50 MHz equivalent
vvp median
Peak Working Set
```

OoO版では可能なら追加で、

```text
Type 1 executed
Type 1 canceled
Type 2 eliminated
issue cycles
average issued queries / issue cycle
```

も記録する。

これにより、

- schedulerで空きレーンをどれだけ埋められたか
- cancellationが何件の実行を消したか

を確認できる。

---

## 20. 50 MHz換算

従来どおり、

```text
50 MHz = 20 ns / clock
```

としてlogical clockを参考換算する。

これは理想FPGAモデル上の値であり、Icarusの実時間とは別物である。

---

## 21. 今回期待する評価

最終報告では、少なくとも以下を明確にする。

- Fixed K=256に対し、OoOでlogical clockがどれだけ減ったか
- Interleaved dependencyで空きレーン問題を改善できたか
- Type 1 / Type 2 normalizationがlogical clock / executed query数をどれだけ削減したか
- 高競合では改善しないこと
- `vvp` 実時間が改善したか、据え置きか、悪化したか
- Peak Working Setの増加量
- 理想FPGA上の改善とIcarus実時間の関係

**logical clockが改善しても `vvp` が速くなるとは仮定しないこと。**

むしろ、1024件lookahead・依存解析・相殺判定のコストによって `vvp` が悪化する可能性も評価対象とする。

---

## 22. 成果物

最低限、以下を作成する。

```text
DESIGN_OUT_OF_ORDER.md
abc470d_out_of_order.sv
tests/test_out_of_order.py
tools/measure_out_of_order.ps1
tools/out_of_order_cases.py
MEASUREMENT_OUT_OF_ORDER.md
measurements/out_of_order_results.csv
```

必要なら補助ファイルを追加してよい。

---

## 23. 完了条件

以下が揃ったら完了とする。

- 既存Baseline / Fixed成果物が不変
- OoO設計文書完成
- ISSUE_WIDTH=256 / LOOKAHEAD=1024 実装完成
- cancellation OFF / ON の切替
- 正しさテスト完走
- logical clock独立照合
- Type 1相殺およびType 2偶奇簡約の安全条件の明示テスト
- 最大規模A〜E測定
- Baseline / Fixed / OoO / OoO+cancel比較
- 測定CSV
- 最終評価文書

今回の主目的は、

**「並列幅をさらに増やすこと」ではなく、「256レーンを先読みと依存解析によって効率よく埋めること」**

である。
