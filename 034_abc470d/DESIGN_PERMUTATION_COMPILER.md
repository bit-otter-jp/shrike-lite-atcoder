# ABC470D Permutation Compiler版 設計メモ

## 1. 目的と合成規約

全クエリを実行待ちの命令列として保持せず、初期順列 `P` に作用する1個の最終変換へTIME=0で畳み込む。理想FPGAモデルでlogical clockを消費するのは、合成済み変換を `answer[]` へ展開する最後の1 clockだけとする。

順列は位置から値への関数とし、合成は右側から適用する。

```text
(F ∘ G)(i) = F(G(i))
```

Type 1の位置交換をtransposition `T(x,y)` と書く。現在順列 `C` は、補助順列 `U,V` と向きbitで次のどちらかとして表す。

```text
inverted = 0: C = U ∘ P ∘ V
inverted = 1: C = V^-1 ∘ P^-1 ∘ U^-1
```

初期状態は `U=V=identity`, `inverted=0` なので、確かに `C=P` である。逆写像 `Uinv=U^-1`, `Vinv=V^-1` も同時に保持する。

## 2. 表現の導出とType 2

通常向きの表現の逆順列は、合成の逆写像の公式から

```text
(U ∘ P ∘ V)^-1 = V^-1 ∘ P^-1 ∘ U^-1
```

となり、ちょうど反転向きの表現である。逆に、反転向きの逆順列は

```text
(V^-1 ∘ P^-1 ∘ U^-1)^-1 = U ∘ P ∘ V
```

である。従ってType 2では `U,Uinv,V,Vinv` を変更せず、次だけを行えばよい。

```text
inverted ^= 1
```

この操作を2回行うと元の表現へ戻るため、Type 2の偶奇も自然に表現される。配列コピー、`P^-1` の生成、補助順列の交換は不要である。

## 3. Type 1更新式

位置 `x,y` の交換後は、向きにかかわらず `C' = C ∘ T(x,y)` である。

### 3.1 `inverted=0`

```text
C' = U ∘ P ∘ V ∘ T
```

従って `V' = V ∘ T` とする。右からのtranspositionは `V` の入力 `x,y` を交換するので、配列表現では次のO(1)更新になる。

```text
a = V[x]
b = V[y]
V[x] = b
V[y] = a
Vinv[a] = y
Vinv[b] = x
```

### 3.2 `inverted=1`

```text
C' = V^-1 ∘ P^-1 ∘ U^-1 ∘ T
```

`U'^-1 = U^-1 ∘ T`、すなわち `U' = T ∘ U` と置けば、同じ表現を維持できる。左からのtranspositionは `U` の出力値 `x,y` を交換する。出力値の現在位置を逆写像で求め、次のO(1)更新を行う。

```text
px = Uinv[x]
py = Uinv[y]
U[px] = y
U[py] = x
Uinv[x] = py
Uinv[y] = px
```

従って全Type 1は、現在順列本体や `P^-1` に触れず定数個の配列アクセスでコンパイルできる。

## 4. 逆写像不変条件

常に次を維持する。

```text
Uinv[U[i]] = i, U[Uinv[i]] = i
Vinv[V[i]] = i, V[Vinv[i]] = i
```

初期identityでは自明である。`V` の入力交換では、交換前の像を `a=V[x], b=V[y]` と保存し、交換後の原像を `Vinv[a]=y, Vinv[b]=x` に更新する。他の対応は変わらないため `Vinv=V^-1` が保たれる。

`U` の出力交換では、交換前に `px=Uinv[x], py=Uinv[y]` を求める。交換後は `U[px]=y, U[py]=x` なので、逆側を `Uinv[x]=py, Uinv[y]=px` とすれば `Uinv=U^-1` が保たれる。Type 2は補助順列を変更しないため不変条件へ影響しない。

以上と第2、3節から、クエリ数に関する帰納法により、全時点で次の表現不変条件が成立する。

```text
inverted = 0: current = U ∘ P ∘ V
inverted = 1: current = V^-1 ∘ P^-1 ∘ U^-1
```

## 5. `inverted=0` の最終gather

通常向きでは各位置 `i` の答えを式どおり直接読む。

```text
answer[i] <= U[p[V[i]]]
```

`V[i]` は初期順列上の位置、`p[V[i]]` はその値、`U[...]` はコンパイルされた出力値変換である。全 `i=1..N` を同一clockで格納する。

## 6. `inverted=1` のPinv不要scatter

反転向きの直接式は

```text
C(i) = Vinv(Pinv(Uinv(i)))
```

だが、`Pinv` は作らない。初期位置 `k` を全探索し `z=p[k]` と置くと、`Pinv[z]=k` である。さらに `i=U[z]=U[p[k]]` とすれば `Uinv[i]=z` なので、

```text
C(U[p[k]]) = Vinv(k)
```

を得る。従って全 `k=1..N` について次をscatterする。

```text
answer[U[p[k]]] <= Vinv[k]
```

### Write競合不在

`P` と `U` はともに全単射なので合成 `U ∘ P` も全単射である。従って異なる `k1,k2` に対して `U[p[k1]] != U[p[k2]]` であり、scatter先は必ず全て異なる。全レーンが同じclock開始時の読み値を使っても、同じ `answer` 要素へのWrite競合は発生しない。

## 7. SystemVerilog構成

新規 `abc470d_permutation_compiler.sv` は次だけを静的保持する。

```text
p, answer, U, Uinv, V, Vinv, inverted
```

TIME=0の `initial` 内で、`p` とidentity補助順列を初期化し、入力クエリを保存せず1件ずつblocking assignmentでcompiler状態へ反映する。OoO版の生query配列、live list、依存graph、ready heap、normalization状態、および `pinv` は持たない。

入力コンパイル完了後にクロックを開始し、最初のposedgeで第5節のgatherまたは第6節のscatterを `answer[]` へnonblocking assignmentする。続くnegedgeで出力するため、回答格納以外のlogical clockは増えない。

診断出力には `LOGICAL_CLOCKS=1`, Type 1/2件数、最終 `inverted`、simulation timeを記録する。stdoutは最終回答だけとする。

## 8. logical clockとIcarus実時間の分離

理想FPGAモデルの定義は次のとおり。

```text
input load + query compile + transform composition = TIME=0, 0 clock
materialize into answer[]                       = 1 clock
logical clocks                                 = 1
50 MHz equivalent                              = 20 ns
```

これは50万クエリを1 clockで逐次実行する意味ではない。命令列を0-clock compilerへ移し、合成後の最終変換だけを面積へ展開して1 clockで適用するモデルである。

一方、IcarusはTIME=0内の初期化、50万回の `$fscanf`、O(1)compiler更新、N件のgather/scatterをホスト上で逐次実行する。その全wall timeを `vvp` 実時間へ含める。従ってlogical clockが常に1でも `vvp` が既存版より速いとは仮定しない。

## 9. Haskell参考実装

`abc470d_permutation_compiler.hs` では、疎なidentity差分を持つ `Permutation`、forward/inverseを対にした `PermutationPair`、`CompilerState` を定義する。

- `identity`: 恒等置換
- input transposition: `V <- V ∘ T`
- output transposition: `U <- T ∘ U`
- `compileQuery`: 上記更新またはbit toggle
- `foldl'`: 全queryを1個の `CompilerState` へ畳み込む
- `materialize`: gatherまたはPinv不要scatter

これは提出速度ではなく、変換合成の意味を読みやすく示す参考実装である。

```text
Haskell: 変換を合成して意味を表現する
FPGA:    合成された変換を面積へ展開して同時適用する
```

## 10. 独立Pythonテスト計画

Python側では次の3経路を分離する。

1. `p/pinv` を直接更新する既存方式相当の逐次ABC470D参照モデル
2. 数式を直接評価するPython Permutation Compilerモデル
3. SystemVerilog実行、および利用可能な環境ではコンパイルしたHaskell参考実装

小規模compilerモデルでは全query後だけでなく各query後に `U/Uinv`, `V/Vinv` の双方向不変条件と、逐次currentが表現式に一致することを検査する。公式3例、N最小、Type 1/2単独、Type 2偶奇、反転前後swap、同一swap、強依存、3-cycle/n-cycle、cancellation可否、Interleaved、Cancellation-rich、固定seedランダム300件以上を含める。

SystemVerilogについては最終回答、`LOGICAL_CLOCKS=1`、Type 1/2件数、最終invertedを照合する。Haskell処理系がローカルにない場合はテストハーネスが明示的に報告し、ソース自体は同じテスト入力形式で実行可能に保つ。

## 11. 最大規模測定計画

`N=Q=500000` の既存A～Eを新規generatorから同じ定義で再生成し、Fに強依存交互列 `swap(1,2), swap(2,3), ...` を追加する。各ケースで以下を同一入力・期待出力により比較する。

```text
Baseline K=1
Fixed K=256
OoO 256/1024 cancellation OFF
OoO 256/1024 cancellation ON
Permutation Compiler
```

各条件を3回実行し、全50万出力tokenをPython逐次結果と照合する。logical clocks、50 MHz換算、`vvp` 中央値、3回中最大Peak Working SetをCSVと報告書へ記録する。Compiler版は全A～Fでlogical clockが1であること、Type 1/2件数と最終invertedも確認する。

## 12. 設計妥当性の結論

Type 1は向きに応じて `V` の入力または `U` の出力へtranspositionを合成し、forward/inverseを対で更新するため、補助順列と表現不変条件を保存する。Type 2は2表現が互いに逆順列なのでbit toggleだけで正しい。通常向きのgatherは合成式そのものであり、反転向きのscatterは `Pinv` の各対応を `p[k]` から列挙した同値式である。scatter先は全単射 `U ∘ P` の像なので競合しない。

従って、任意の有効なABC470Dクエリ列をTIME=0で1個の変換へ安全にコンパイルし、`Pinv` なしで最終回答を1 logical clockで格納できる設計である。

