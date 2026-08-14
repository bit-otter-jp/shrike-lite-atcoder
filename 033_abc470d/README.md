# ABC470D 第33回公開スナップショット

Qiita第33回「ABC470D - 仮想理想FPGAなら何クロックで解ける？」で使用した公開用成果物です。

次の3方式のSystemVerilog、設計文書、テスト、測定ツールと結果を収録しています。

- Baseline
- Fixed Parallel
- Out-of-Order

Permutation Compilerは第34回で扱うため、このスナップショットには含めていません。

## テスト

```powershell
python tests\test_baseline.py
python tests\test_fixed_parallel.py
python tests\test_out_of_order.py
```

## 測定

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\measure_max.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools\measure_fixed_parallel.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools\measure_out_of_order.ps1
```

第33回本文のStrong dependencyケースだけを再測定する場合:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\measure_out_of_order.ps1 -OnlyCase strong_dependency
```

このコマンドはFixed K=256とOoO cancellation OFFを各3回実行し、結果を `build\out_of_order\selected_results.csv` に保存します。

`build/` 以下の入力、期待出力、コンパイル済みイメージ、一時出力は実行時に再生成されるためGit管理対象外です。

