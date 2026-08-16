# ABC470D Permutation Compiler版 テスト・測定結果

測定日: 2026-08-14 (Asia/Tokyo)

## 結論

Permutation Compilerは、最大規模 `N=Q=500000` のA～Fすべてで、50万queryを `U/Uinv/V/Vinv` と向きbitが表す1個の最終変換へTIME=0でコンパイルし、その変換だけを **1 logical clock** で `answer[]` へ格納した。50 MHz換算はクエリ内容によらず **20 ns** である。

これは「50万queryを1 clockで逐次実行した」という結果ではない。query compilerを0-clockと定義した理想FPGAモデルで、逐次命令列そのものを消し、合成済み変換を1 clockで空間展開した結果である。Icarusの `vvp` 実時間にはTIME=0の入力、50万回のcompiler更新、補助順列初期化、最後のgather/scatterをすべて含めた。

今回のローカル実測では、Compiler版はlogical clockだけでなく `vvp` もA～FすべてでBaselineより5.19%～13.70%短かった。6ケース中央値平均はCompiler 5.837秒、Baseline 6.503秒、Fixed K=256 8.419秒、OoO OFF 20.172秒である。一方、Peak Working SetはCompiler 86.00～86.05 MiBで、Baselineより約31.1 MiB、Fixedより約23.4 MiB多い。

強依存Fでは、Baseline／Fixed／OoO OFF／OoO ONがすべて `500002 clocks` のままなのに対し、Compilerは `1 clock` だった。OoO ONは相殺0件のまま1024件normalizationと依存再構築を各clockで反復し、`vvp` 中央値が6266.929秒（104.45分）まで悪化した。Compilerは5.449秒で、OoO ON比約1150倍短かった。この差は並列発行の高速化ではなく、命令列を残す設計を捨てたことによる。

## 環境・条件

- OS: Microsoft Windows NT 10.0.26200.0
- CPU識別子: Intel64 Family 6 Model 154 Stepping 3、論理プロセッサ20
- Icarus Verilog: 12.0 devel (`s20150603-1539-g2693dd32b`)
- Python: 3.13.1
- GHC: ローカル環境に未導入
- コンパイル: `iverilog -g2012 -Wall -DONLINE_JUDGE -DATCODER`
- 実行: `vvp -n`
- 全ケース `N=Q=500000`
- 比較対象: Baseline K=1、Fixed K=256、OoO 256/1024 cancellation OFF／ON、Permutation Compiler
- 各条件3回。`vvp` は中央値、Peak Working Setは3回中最大。
- `vvp` 時間は入力生成、期待値生成、コンパイル、Python出力照合を含まず、`vvp` プロセス開始から終了まで。
- 全90実行で各50万個、合計4500万個の出力tokenを逐次Python期待値と照合した。
- 50 MHz換算は `20 ns/clock` の理想FPGAモデル上の参考値であり、`vvp` wall timeとは別指標である。

## 正しさテスト

実行コマンド:

```powershell
python tests\test_permutation_compiler.py
```

結果:

```text
PASS: 3 samples, 15 special, 300 random (seed=470); Haskell skipped (ghc not found)
```

SystemVerilogは合計318実行で、公式3例、N最小、Type 1のみ、Type 2のみ、偶数／奇数反転、反転前後swap、同一swap、強依存、3-cycle／n-cycle、cancellation可能／不能、Interleaved dependency、Cancellation-rich、固定seedランダム300件を通過した。

独立Python検証は次を行った。

- `U,V`を使わず、現在順列を直接swap／逆順列化する逐次参照モデル
- 数式から独立に配列を更新するPermutation Compilerモデル
- 各query直後の `U/Uinv`, `V/Vinv` 双方向不変条件
- 各query prefixでの表現式と逐次currentの一致
- SystemVerilog最終回答、`LOGICAL_CLOCKS=1`、Type 1/2件数、最終invertedの一致
- `inverted=1` を含む多数のケースでPinv不要scatterの一致と全answer添字の充足

Haskell参考実装については要求された抽象名と入力形式をテストで検査する経路を用意したが、ローカルに `ghc`, `runghc`, `stack`, `cabal` が存在しなかったため、実行ファイルによる比較は行えていない。GHCがある環境では次でHaskell実行を必須化できる。

```powershell
python tests\test_permutation_compiler.py --require-haskell
```

## 最大規模ケース

- A 高並列: 互いに素なswapを循環。
- B ランダム: seed `470`、全件Type 1。
- C 高競合: `swap(1,500000)` を50万回。
- D Interleaved dependency: 独立な3位置チェーンごとに `swap(a,b), swap(b,c)`。
- E Cancellation-rich: Type 1 40万件、Type 2 10万件からなるcascading cancellation列。
- F Strong dependency: `swap(1,2), swap(2,3)` を交互に50万件。全クエリが直前の未処理クエリと共有位置を持ち、同一swap間にも共有位置へのtouchがあるためOoO ONでも相殺不能。

最大規模A～Fはいずれも最終 `inverted=0` である。`inverted=1` のscatterは前節の小規模・ランダムテストで明示的に検証した。

## A. 高並列

| 実装 | logical clocks | 50 MHz換算 | `vvp` 中央値 | Peak Working Set |
|---|---:|---:|---:|---:|
| Baseline K=1 | 500002 | 10.000040 ms | 6.772 s | 54.86 MiB |
| Fixed K=256 | 1956 | 0.039120 ms | 7.668 s | 62.59 MiB |
| OoO OFF | 1956 | 0.039120 ms | 24.966 s | 123.75 MiB |
| OoO ON | 1956 | 0.039120 ms | 45.172 s | 123.70 MiB |
| Permutation Compiler | **1** | **20 ns** | **6.107 s** | 86.00 MiB |

既存最少1956 clocksから99.9489%削減した。Fixedが既にレーンを埋めていてもCompilerのclock数は変わらない。`vvp` はBaseline比9.82%、Fixed比20.36%短かった。

## B. ランダム

| 実装 | logical clocks | 50 MHz換算 | `vvp` 中央値 | Peak Working Set |
|---|---:|---:|---:|---:|
| Baseline K=1 | 500002 | 10.000040 ms | 6.803 s | 54.90 MiB |
| Fixed K=256 | 2134 | 0.042680 ms | 8.054 s | 62.55 MiB |
| OoO OFF | 1956 | 0.039120 ms | 25.351 s | 123.78 MiB |
| OoO ON | 1956 | 0.039120 ms | 46.281 s | 123.70 MiB |
| Permutation Compiler | **1** | **20 ns** | **6.450 s** | 86.00 MiB |

既存最少1956 clocksから99.9489%削減した。位置競合率は最終変換へのfold回数を変えない。`vvp` はBaseline比5.19%、Fixed比19.92%短かった。

## C. 高競合

| 実装 | logical clocks | 50 MHz換算 | `vvp` 中央値 | Peak Working Set |
|---|---:|---:|---:|---:|
| Baseline K=1 | 500002 | 10.000040 ms | 6.428 s | 54.88 MiB |
| Fixed K=256 | 500002 | 10.000040 ms | 9.751 s | 62.50 MiB |
| OoO OFF | 500002 | 10.000040 ms | 16.496 s | 123.68 MiB |
| OoO ON | 2 | 40 ns | 9.486 s | 123.73 MiB |
| Permutation Compiler | **1** | **20 ns** | **5.827 s** | 86.01 MiB |

OoO ONは同一swap 50万件を全相殺して2 clocks、Compilerは相殺可能性を調べず50万回の同じO(1)合成規則で1 clockとなった。`vvp` はBaseline比9.35%、Fixed比40.24%短かった。

## D. Interleaved dependency

| 実装 | logical clocks | 50 MHz換算 | `vvp` 中央値 | Peak Working Set |
|---|---:|---:|---:|---:|
| Baseline K=1 | 500002 | 10.000040 ms | 6.992 s | 54.86 MiB |
| Fixed K=256 | 250003 | 5.000060 ms | 8.566 s | 62.50 MiB |
| OoO OFF | 1956 | 0.039120 ms | 24.100 s | 123.78 MiB |
| OoO ON | 1956 | 0.039120 ms | 43.614 s | 123.71 MiB |
| Permutation Compiler | **1** | **20 ns** | **6.034 s** | 86.00 MiB |

OoOは後続独立queryを探して1956 clocksまで減らすが、Compilerは依存解析そのものを不要にした。既存最少比99.9489%のclock削減、Baseline比13.70%の `vvp` 短縮である。

## E. Cancellation-rich

| 実装 | logical clocks | 50 MHz換算 | `vvp` 中央値 | Peak Working Set |
|---|---:|---:|---:|---:|
| Baseline K=1 | 500002 | 10.000040 ms | 5.891 s | 54.89 MiB |
| Fixed K=256 | 300002 | 6.000040 ms | 7.443 s | 62.54 MiB |
| OoO OFF | 300002 | 6.000040 ms | 14.143 s | 123.69 MiB |
| OoO ON | 2 | 40 ns | 9.086 s | 123.68 MiB |
| Permutation Compiler | **1** | **20 ns** | **5.154 s** | 86.05 MiB |

Compiler診断はType 1を40万件、Type 2を10万件コンパイルし、最終inverted=0を示した。クエリを削除したのではなく全件を変換へfoldした。`vvp` はBaseline比12.51%、Fixed比30.75%短かった。

## F. Strong dependency

| 実装 | logical clocks | 50 MHz換算 | `vvp` 中央値 | Peak Working Set |
|---|---:|---:|---:|---:|
| Baseline K=1 | 500002 | 10.000040 ms | 6.133 s | 54.89 MiB |
| Fixed K=256 | 500002 | 10.000040 ms | 9.030 s | 62.50 MiB |
| OoO OFF | 500002 | 10.000040 ms | 15.978 s | 123.72 MiB |
| OoO ON | 500002 | 10.000040 ms | 6266.929 s (104.45 min) | 125.16 MiB |
| Permutation Compiler | **1** | **20 ns** | **5.449 s** | 86.02 MiB |

OoO ONの3回は6190.385、6297.333、6266.929秒で、全回 `500002 clocks / Type 1 executed=500000 / canceled=0` だった。Compilerは同じ50万Type 1を一度ずつfoldし、既存最少比99.9998%のclock削減、Baseline比11.15%の `vvp` 短縮、OoO ON比約1150倍の実時間短縮となった。

## Compiler診断

| ケース | Type 1 compiled | Type 2 compiled | final inverted | logical clocks |
|---|---:|---:|---:|---:|
| A 高並列 | 500000 | 0 | 0 | 1 |
| B ランダム | 500000 | 0 | 0 | 1 |
| C 高競合 | 500000 | 0 | 0 | 1 |
| D Interleaved | 500000 | 0 | 0 | 1 |
| E Cancellation-rich | 400000 | 100000 | 0 | 1 |
| F Strong dependency | 500000 | 0 | 0 | 1 |

## 総合評価

### 数学的変換とlogical clock

- Type 1は通常向きで `V <- V ∘ T`、反転向きで `U <- T ∘ U` としてO(1)合成された。
- Type 2は補助配列を変更せず `inverted` のbit toggleだけで処理された。
- 通常向きは `answer[i] = U[p[V[i]]]` のgather、反転向きは `answer[U[p[k]]] = Vinv[k]` のPinv不要scatterで一致した。
- `U ∘ P` が全単射なのでscatter先は全て異なり、同一clockのWrite競合はない。
- A～Fの依存・競合・相殺可能性にかかわらずlogical clockは常に1だった。

### `vvp` 実時間

- CompilerはTIME=0 compiler処理も含めてA～FすべてでBaselineより短かった。
- 生query配列を保持せず、queryごとの現在順列／逆順列データパス更新、依存解析、normalizationを行わない効果が、4本の補助順列更新コストを上回った。
- ただしこの結果はローカルIcarus上の実測であり、「logical clock=1だから `vvp` も速い」という推論ではない。両指標は独立に測った結果、今回は同じ方向になった。
- FのOoO ONは、相殺が起きないのに各issue前のnormalizationを反復するため極端に悪化した。最適化の効果がない入力で判定コストだけが残る例である。

### Peak Working Set

- Baseline: 54.86～54.90 MiB
- Fixed K=256: 62.50～62.59 MiB
- Permutation Compiler: 86.00～86.05 MiB
- OoO: 123.68～125.16 MiB

Compilerは生query配列とOoO状態を持たないためOoOより約37.6～39.2 MiB少ない。一方、`p,answer,U,Uinv,V,Vinv` の6配列を持つため、3配列中心のBaselineより約31.1 MiB、Fixedより約23.4 MiB多い。`pinv` は生成・保持していない。

## 既存成果物の不変確認

作業開始前と完了時にBaseline／Fixed／OoOの主要14成果物のSHA-256を取得し、全て一致することを確認した。

| 既存成果物 | SHA-256（開始時 = 完了時） |
|---|---|
| `abc470d_baseline.sv` | `D1604164AC381E6C6E847DFE973FCE68F46A0C02F7E726A0BAAD5724219392FE` |
| `DESIGN_BASELINE.md` | `073108E2EE9A2EE12444088AB64E45EC715FB25C3EA4D51F4670A3992D8705FC` |
| `MEASUREMENT_BASELINE.md` | `946BEB530BE84BA7017657032A9112A672717278DA1057DBF1154CBB7F8F78C2` |
| `abc470d_fixed_parallel.sv` | `8CB2B506CB9C7016E246CFA35ECDD59C444C9FE77F609259FE66FC6025862E1C` |
| `DESIGN_FIXED_PARALLEL.md` | `9841EB2D689E3DB7866D9394C72006A214B5467B24E2CA1B69705D9613C763AE` |
| `MEASUREMENT_FIXED_PARALLEL.md` | `5E2091A76E987CCE069BB3CC45DD1EDC7C6BD05ACA30C00FBB08DC11A4B82B7B` |
| `measurements/fixed_parallel_results.csv` | `5BCF38EAB5FF3EA7A0C9AC8967CC0D99453912E8095019C6440B71E86AF322D2` |
| `abc470d_out_of_order.sv` | `9A858AA1891F7D3FD389ACA0E6D16D9A07946570283D2454C70F7BD00CC1A2D0` |
| `DESIGN_OUT_OF_ORDER.md` | `DB8482CE92487D7E9451FCEA4F604CAF846F902D9AC13E1D1A6429B8665AE62A` |
| `MEASUREMENT_OUT_OF_ORDER.md` | `7E14C9433FA53160BE1E424D0402D3A3A1325A19E19A4461BA4F3521F0100B44` |
| `tests/test_out_of_order.py` | `8D5EBC345E38E9C14E467C662D5ADD1396EDB51797CC3CAC0A232883B3C956C1` |
| `tools/measure_out_of_order.ps1` | `1DEF60C3C8672B5D410884EA295ACCA2D17C929557954A24662AEC674A20A2EE` |
| `tools/out_of_order_cases.py` | `4C5D69E3F3F0EFB3AFC2559A5D9D480512FD62C9C29602CAF290B9A6C19A6F72` |
| `measurements/out_of_order_results.csv` | `9DF1B2DCB4978E388C8FE51191862894C4033C65C6D39FC4DC6FF874E7C0B56E` |

## 注意事項

- 1 logical clockは、query compilerを0-clockと定義する理想モデルの値である。実合成で50万query入力と変換合成を同一物理cycleに収められることを示す値ではない。
- Haskell参考実装は作成済みだが、ローカルにGHC toolchainがないため実行比較だけが未実施である。PythonとSystemVerilogの比較およびHaskellソースの要求抽象検査は通過している。
- 最大規模A～Fは最終inverted=0なので、Pinv不要scatterの最大規模wall-timeを通常gatherと分離してはいない。scatterの意味的正しさは反転向きの公式・特殊・ランダムテストで検証した。
- 本測定値はローカルWindows/Icarus環境の値であり、合成後FPGAやAtCoder Linux上の時間を直接表さない。

## 再現方法と生データ

```powershell
python tests\test_permutation_compiler.py
powershell -NoProfile -ExecutionPolicy Bypass -File tools\measure_permutation_compiler.ps1
```

GHC導入環境でHaskell比較を必須化する場合:

```powershell
python tests\test_permutation_compiler.py --require-haskell
```

各run実時間、byte単位Peak Working Set、logical clocks、実行／相殺／コンパイル件数、最終invertedは `measurements/permutation_compiler_results.csv` に保存している。
