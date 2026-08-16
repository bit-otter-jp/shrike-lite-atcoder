# ABC470D fast-vvp 実装・測定結果

測定日: 2026-08-16 (Asia/Tokyo)

## 結論

`abc470d_fast_vvp.sv` は、SystemVerilogをIcarus上の手続き型プログラム
として実行する版である。クロック、query配列、answer配列を持たず、
入力を読みながら現在の順列を直接更新する。

`N=Q=500000` の2ケースを各3回測定した結果、`vvp` 中央値は次のとおり
だった。

| 最大ケース | Baseline | Permutation Compiler | fast-vvp |
|---|---:|---:|---:|
| Random、Type 1のみ | 6.977 s | 6.312 s | **3.410 s** |
| Cancellation-rich、Type 1/2混在 | 5.779 s | 5.016 s | **2.788 s** |

fast-vvpは両ケースで最速だったが、目標としていた2秒未満には到達しなかった。

## 採用アルゴリズム

現在の順列を `P`、その逆順列を `Pinv`、向きを `inverted` で表す。

- 通常向きのType 1は `P[x]` と `P[y]` を交換する。
- 逆向きのType 1は `Pinv[x]` と `Pinv[y]` を交換する。
- `Pinv` 構築後は、片方の交換に対応するもう片方の2要素も更新し、
  常に逆写像関係を維持する。
- Type 2は `inverted` の1 bitを反転するだけである。
- `Pinv` は逆向きType 1または逆向き最終出力が初めて必要になるまで
  構築しない。構築前の通常向きType 1では `P` だけを更新する。

各queryはO(1)、`Pinv` の遅延構築と最終出力は最大1回のO(N)である。

## Icarus向けの最適化

- `initial` 内だけで完結させ、clock、event scheduling、nonblocking
  assignmentをなくした。
- 生queryの保存と再生をなくし、読んだ直後に処理する。
- `answer[]` を持たず、最終的な `P` または `Pinv` を直接出力する。
- 初期順列は64整数を1回の `$fscanf` で読み、system task呼出しを減らした。
- query種別は十進整数ではなく `" %c"` で読み、`'1'` と比較する。
- Type 1引数のformatは余分な空白directiveを省いた `"%d%d"` とした。
- query loopは `repeat(q)` とした。
- 出力は64整数を1回の `$fwrite` にまとめた。末尾の空白は採点上の
  whitespaceとして扱われる。
- `integer` 配列2本だけを確保した。

## 候補方式の実測

候補絞り込みは既存の最大Random入力で単発測定した。最終比較の3回中央値
とは区別する。

| 候補 | vvp wall time | Peak Working Set | 判定 |
|---|---:|---:|---|
| 直接 `P/Pinv`、単値出力 | 4.564 s | 24.25 MiB | 出力呼出しが多い |
| 同上、64要素まとめ出力 | 4.121 s | 24.41 MiB | 改善 |
| 全入力 `$fread`＋byte配列parser | 15.147 s | 482.23 MiB | 不採用 |
| `$fgets`＋手続き的digit parser | 10.386 s | 24.39 MiB | 不採用 |
| `$fgets`＋`$sscanf`、単値出力 | 5.421 s | 24.26 MiB | 不採用 |
| 19-bit配列、単値出力 | 4.730 s | 24.25 MiB | `integer` より遅い |
| 最終採用版、3回中央値 | **3.410 s** | **24.42 MiB** | 採用 |

`$write` とstdout指定の `$fwrite` は約3.62秒で実質同等だった。
最終版では出力先を明示する `$fwrite` を採用した。

## 正しさ

独立Python参照実装は、Type 2ごとに順列全体から逆順列を作る逐次定義を
使っており、SystemVerilog版の遅延 `Pinv` 実装とは別経路である。

```text
PASS: 3 official samples, 10 special, 300 random (seed=470)
```

特殊ケースには最小N、Type 2のみ、偶数・奇数回反転、逆向きで最初の
Type 1、両向きのType 1、64要素batch境界と端数を含めた。

最大規模では、後述の全18 runについて50万個の出力tokenをPython期待値と
比較し、すべて一致した。

## 最大規模の詳細

環境と測定方法:

- OS: Microsoft Windows NT 10.0.26200.0
- CPU識別: Intel64 Family 6 Model 154 Stepping 3、論理プロセッサ20
- Icarus Verilog: 12.0 devel (`s20150603-1539-g2693dd32b`)
- Python: 3.13.1
- compile: `iverilog -g2012 -Wall -DONLINE_JUDGE -DATCODER`
- run: `vvp -n`
- compile、ケース生成、Python照合はwall timeに含めない
- `vvp` process開始から終了までを測り、標準入出力のpipe転送は含める
- 各条件3回の中央値、Peak Working Setは3回中最大

### Random、seed 470、Type 1のみ

入力サイズは11,167,506 bytes。

| 実装 | run 1 | run 2 | run 3 | 中央値 | Peak Working Set |
|---|---:|---:|---:|---:|---:|
| Baseline | 6.896 s | 6.977 s | 7.209 s | 6.977 s | 54.88 MiB |
| Permutation Compiler | 6.229 s | 6.386 s | 6.312 s | 6.312 s | 86.00 MiB |
| fast-vvp | 3.468 s | 3.377 s | 3.410 s | **3.410 s** | **24.42 MiB** |

fast-vvpはBaseline比で約2.05倍、Permutation Compiler比で約1.85倍速い。

### Cancellation-rich、Type 1=400000、Type 2=100000

入力サイズは5,988,909 bytes。

| 実装 | run 1 | run 2 | run 3 | 中央値 | Peak Working Set |
|---|---:|---:|---:|---:|---:|
| Baseline | 5.894 s | 5.711 s | 5.779 s | 5.779 s | 54.89 MiB |
| Permutation Compiler | 5.028 s | 5.013 s | 5.016 s | 5.016 s | 86.00 MiB |
| fast-vvp | 2.786 s | 2.788 s | 2.813 s | **2.788 s** | **24.42 MiB** |

fast-vvpはBaseline比で約2.07倍、Permutation Compiler比で約1.80倍速い。

## 再現コマンド

```powershell
python tests\test_fast_vvp.py
powershell -NoProfile -ExecutionPolicy Bypass -File tools\measure_fast_vvp.ps1
```

全runの未丸め値とPeak Working Setは
`measurements/fast_vvp_results.csv` に保存する。
