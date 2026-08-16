# fast-vvp 不採用候補

最大Random入力（`N=Q=500000`）で候補を絞り込んだときの単発実測です。最終比較の3回中央値とは区別してください。遅かった理由は断定せず、この環境の実測値だけを記録します。

| 候補 | source | vvp wall time | Peak Working Set |
|---|---|---:|---:|
| 全入力 `$fread` + byte parser | `abc470d_fast_fread.sv` | 15.147 s | 482.23 MiB |
| `$fgets` + 手続きdigit parser | `abc470d_fast_fgets.sv` | 10.386 s | 24.39 MiB |
| `$fgets` + `$sscanf`、単値出力 | `abc470d_fast_fgets_sscanf.sv` | 5.421 s | 24.26 MiB |
| `$fgets` + 固定幅展開、単値出力 | `abc470d_fast_fgets_unrolled.sv` | 5.760 s | 24.28 MiB |
| 19-bit配列、単値出力 | `abc470d_fast_narrow_scalar.sv` | 4.730 s | 24.25 MiB |
| `integer`配列、単値出力 | `abc470d_fast_scalar.sv` | 4.564 s | 24.25 MiB |
| 64要素まとめ出力 | 開発途中版 | 4.121 s | 24.41 MiB |
| 追加最適化後 | [../abc470d_fast_vvp.sv](../abc470d_fast_vvp.sv) | **3.410 s**（3回中央値） | **24.42 MiB** |

測定条件、Type 1/2混在ケース、Baseline／Permutation Compilerとの比較は [../MEASUREMENT_FAST_VVP.md](../MEASUREMENT_FAST_VVP.md) にまとめています。
