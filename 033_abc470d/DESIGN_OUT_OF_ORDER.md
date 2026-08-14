# ABC470D Out-of-Order版 設計メモ

## 1. 構成とパラメータ

既存Baseline／Fixed Parallelとは別に、次を既定値とするパラメータ化実装を追加する。

```text
ISSUE_WIDTH  = 256
LOOKAHEAD    = 1024
ENABLE_CANCEL = 0 / 1
```

並列実行時の `p` / `pinv` / `inverted` と更新式はFixed Parallelと同じである。今回変更するのは、256レーンへ発行する未処理Type 1の選び方と、発行前normalizationだけである。

## 2. 未処理クエリ管理

全クエリは元の入力配列に保持し、次の補助状態を持つ。

- `query_done[i]`: 実行または相殺済みか。
- `next_live[i]`, `prev_live[i]`: 元の入力順を保つliveクエリの双方向リスト。
- `live_head`: 最初のliveクエリ。
- `live_count`: 全liveクエリ数。
- `admit_index`: 先読み窓へ一度でも投入した生配列位置の直後。
- `window_count`: 現在liveかつ投入済みのクエリ数。

投入は生配列の先頭から一度だけ、単調増加順に行う。実行・相殺時はliveリストからO(1)で削除し、空いた数だけ `admit_index` 以降を投入する。従って窓は常に「元の相対順序を保った先頭から最大1024件の未処理クエリ」であり、実行済みの穴を数えない。

## 3. 1024件lookaheadと依存表現

残存Type 2より前の最初のType 1セグメントだけを発行対象とする。各位置について、そのセグメント内で触れるクエリを入力順にリンクする。

- `next_touch_x[i]`, `next_touch_y[i]`: クエリ `i` の各端点を次に触るliveクエリ。
- `dependency_count[i]`: `x`, `y` のうち、より前のliveクエリが存在する端点数（0～2）。
- `last_touch[position]` と世代stamp: 依存表の構築・新規投入に使用。

`dependency_count == 0` のクエリだけがreadyである。readyクエリは元の入力添字をkeyとする最大1024要素のmin-heapへ入れる。毎logical clock、最小添字から最大256件だけを取り出す。依存解放で窓の途中にあるクエリがreadyになっても、O(log 1024)で入力順の発行優先度を維持できる。

発行対象をすべて選び終えてから依存表を更新する。発行クエリの各端点について `next_touch` の依存数を1減らし、0になったクエリを次クロック用readyリストへ挿入する。この順序により、今クロックの完了でreadyになった依存クエリを同じpre-stateで誤って発行しない。

高競合列でも1024件を毎クロック再走査せず、完了した先頭touchから直接その次のtouchだけを解放できる。新しいクエリの投入は、窓内にbarrierがなければ既存依存表へ差分追加する。barrierを実行・削除した場合とcancellation後は、次の先頭セグメントについて最大1024件を再構築する。

## 4. ready判定と安全な追い越し

クエリ `qi = swap(x,y)` がreadyなのは、現在liveな先行クエリのどれも `x` または `y` に触れない場合だけである。位置ごとのtouchリンクでは、先行touchが1件以上あればその端点の依存数が立つため、この条件と `dependency_count == 0` は同値である。

待機クエリ自身もtouchリンクに残る。従って、待機クエリと同じ位置を使う後続クエリには必ず先行touch依存が付き、その待機クエリを追い越せない。一方、全先行liveクエリと位置集合が独立な後続クエリはreadyとなり、前方の待機クエリを越えて発行できる。

liveリストは入力順を保ち、ready min-heapは入力添字を優先するので、複数のreadyクエリは入力順に最大256件選ぶ。先読み窓外、または最初の残存Type 2より後ろは候補にならない。

## 5. 256件同時実行時のWrite競合不在

同一クロックにreadyな2クエリが同じ論理位置を共有すると、後方クエリには前方クエリへのtouch依存が存在するはずなので矛盾する。従って発行群の全 `x`,`y` は相異なる。

現在側が `p` の場合、発行群が読む `p[x]`,`p[y]` も順列の単射性によりすべて異なる。よって現在側 `p[x]`,`p[y]` と反対側 `pinv[p[x]]`,`pinv[p[y]]` のWrite先はそれぞれ一意である。現在側が `pinv` の場合も同様である。全レーンはnonblocking assignmentにより同じクロック開始時状態を読む。

## 6. Type 2 barrier

normalization後に残る最初のType 2は完全なbarrierである。

- 依存表とreadyリストはそのType 2直前までしか構築しない。
- Type 2後方のType 1は、先読み窓内でも発行しない。
- Type 2前方のlive Type 1がなくなってType 2が `live_head` になったときだけ、単独1 logical clockで `inverted` を反転する。
- barrier実行後、次セグメントの依存表を再構築する。

これにより向き変更を越えた投機実行はない。

## 7. 完全同一swapの相殺

`ENABLE_CANCEL=1` では、発行判定前に現在の先読み窓内だけをnormalizationする。同じType 2セグメント内を入力順に走査し、各位置の「現在残っている最後のtouch」を管理する。

`swap(x,y)` の両端点で最後のtouchが同じ先行クエリ `j` を指し、`j` も完全に同じ `(x,y)` なら、`j` と現在クエリの間に残るどのType 1も `x,y` に触れていない。両swapは間の全操作と可換で2回適用が恒等なので、安全に両方を削除できる。

削除時には、先行swap `j` が持っていた端点別のprevious-touchを復元する。単純にlast-touchをclearしないため、さらに前の依存履歴を失わず、不正な相殺を起こさない。

両クエリが現在の先頭1024 live件に入っている場合だけ判定する。残存Type 2をまたぐlast-touchは世代を分けるため、Type 2越しの相殺はない。

## 8. cascading cancellation

normalizationは次の固定点処理とする。

1. 各Type 2セグメントをprevious-touch復元付きstack相当の1 passで簡約し、可能なType 1ペアをcascadingに削除する。
2. 残ったlive列を走査し、隣接Type 2のrunを偶奇簡約する（ペアを削除し、奇数なら1件残す）。
3. 削除があれば窓を再び1024 live件まで補充し、1へ戻る。
4. Type 1／Type 2のいずれも削除できなくなったら終了する。

Type 1削除でType 2同士が隣接した場合は同じ反復の2で削除される。Type 2削除でType 1セグメントが結合した場合は次反復の1で新しい相殺を検出する。窓補充後も固定点まで繰り返すため、削除によって新しく先読み範囲へ入ったクエリも、その時点の1024件だけを使って安全に簡約できる。

normalizationはlogical clockを消費しない。相殺で全クエリが消えた場合、そのエッジをanswer格納クロックとして扱い、空のquery clockを追加しない。

## 9. logical clockと統計

```text
logical clocks = 1 (Pinv・scheduler初期化)
               + Type 1 issue cycles
               + 実行された残存Type 2数
               + 1 (answer格納)
```

相殺されたType 1、偶数簡約で消えたType 2、normalization自体は0 clockである。最終Type 1／Type 2を実行した次のクロックでanswerを格納する。normalizationだけで残りが全削除された場合は、その時点のクロックをanswer格納に使う。

標準エラーへ以下を出し、独立モデル・測定ツールで照合する。

- logical clocks / query clocks / issue cycles
- Type 1 executed / canceled
- Type 2 executed / eliminated
- issue width / lookahead / cancellation mode

平均issue数は `Type 1 executed / issue cycles` とする。

## 10. テスト計画

- 逐次ABC470D参照モデルで最終回答を検証する。
- Verilogのデータ構造とは独立に、Pythonではliveクエリlist、先行touch集合、意味的normalization固定点を使うOoOモデルを作る。
- cancellation OFF/ONの双方で、公式3例、境界、固定seedランダムを比較する。
- logical clocks、Type 1 executed/canceled、Type 2 executed/eliminated、issue cyclesを照合する。
- OoO固有として、先頭依存チェーン後方の独立発行、待機依存の追越し禁止、多段依存、256 issue境界、1024 lookahead境界、実行済み穴、Type 2前後を明示テストする。
- cancellation固有として、独立swap越しの相殺、同位置touch／Type 2越しの相殺禁止、`A B B A`、`2 2`、`2 2 2`、`2 A A 2`、`A 2 2 A`、lookahead内外を明示テストする。
- OFFとONの最終回答が常に逐次結果と一致することを確認する。

## 11. 性能測定計画

`N=Q=500000` の次の5ケースを、Baseline、Fixed K=256、OoO cancellation OFF、OoO cancellation ONで各3回測定する。

- A 高並列: 互いに素なswap列。
- B ランダム: seed `470` のType 1列。
- C 高競合: `swap(1,500000)` の反復。
- D Interleaved dependency: hotspot依存チェーンと独立swapを交互配置し、Fixedのprefixを早期停止させる。
- E Cancellation-rich: 同一swapペアの間に独立操作を置き、ONで大量相殺できる列。

入力と期待出力は全実装で同一とし、全50万要素をトークン比較する。コンパイルは `iverilog -g2012 -DONLINE_JUDGE -DATCODER`、実行は `vvp -n`。各条件のlogical clock、50 MHz換算、3回の `vvp` 中央値、3回中最大Peak Working Setを記録する。OoOは追加統計とissue効率も記録する。

## 12. 設計妥当性の結論

永続先読み窓は先頭1024 liveクエリの元順序を保ち、位置touch依存は採用クエリだけでなく待機中を含む全先行live Type 1を表す。従って依存する後続だけを確実に待機させ、独立な後続だけを安全に追い越せる。ready群の位置非重複と順列の単射性から両物理配列のWrite競合もない。Type 2 barrierで向きの逐次意味を保ち、previous-touch復元と固定点反復により許可条件内のcascading cancellationだけを行う。よって `256/1024` OoO版として設計上妥当である。
