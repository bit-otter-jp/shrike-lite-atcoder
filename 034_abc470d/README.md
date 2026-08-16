# Shrike-LiteでAtCoder問題を解く 第34回 ABC470D

Qiita連載第34回「ABC470D - 50万クエリ、結局ひとつの変換じゃない？」の再現用資料です。

第33回では、1 query/clock、固定幅並列、lookahead付きOut-of-Order、cancellationによりquery executionの高速化を試しました。今回は方向を変え、50万query全体を1個のpermutation transformationへcompileする **Permutation Compiler** を扱います。仮想理想FPGAモデルではquery compileを0 clocks、最終変換の適用を1 clockと定義するため、有効なquery列は内容によらず **1 logical clock** です。

logical clockは理想モデルの指標であり、Icarus/`vvp` wall timeとは別物です。数式、Pinv不要scatter、競合がない理由は [DESIGN_PERMUTATION_COMPILER.md](DESIGN_PERMUTATION_COMPILER.md)、最大規模A〜Fの結果は [MEASUREMENT_PERMUTATION_COMPILER.md](MEASUREMENT_PERMUTATION_COMPILER.md) を参照してください。

[abc470d_fast_vvp.sv](abc470d_fast_vvp.sv) は、FPGAらしさとlogical clockを評価対象から外し、SystemVerilogをIcarus上の手続き型プログラムとして使うAC狙いのおまけです。ローカル最大規模では2秒未満に届いておらず、AtCoder本番judgeでのACは未確認です。詳細と不採用候補は [MEASUREMENT_FAST_VVP.md](MEASUREMENT_FAST_VVP.md) と [experiments/](experiments/) にあります。

Haskell版はquery列を1個の変換へfoldする考え方を示す参照実装です。ローカルにGHCがないため、実行確認済みではありません。

## 主な再現コマンド

```powershell
python tests\test_permutation_compiler.py
python tests\test_fast_vvp.py

# Permutation Compilerだけを最大規模A〜Fで再測定
powershell -NoProfile -ExecutionPolicy Bypass -File tools\measure_permutation_compiler.ps1 -OnlyImplementation permutation_compiler

# Baseline / Permutation Compiler / fast-vvpを最大規模2ケースで再測定
powershell -NoProfile -ExecutionPolicy Bypass -File tools\measure_fast_vvp.ps1
```

`measure_permutation_compiler.ps1` の全実装比較には、Strong dependencyのOoO cancellation ONが1 runあたり約104分かかる既知の条件が含まれます。既存の全比較値は [measurements/permutation_compiler_results.csv](measurements/permutation_compiler_results.csv) に保存しています。

`abc470d_baseline.sv`、`abc470d_fixed_parallel.sv`、`abc470d_out_of_order.sv` は比較測定の再現に必要な最小限の参照実装です。build生成物と生成ケースはGit管理対象外です。
