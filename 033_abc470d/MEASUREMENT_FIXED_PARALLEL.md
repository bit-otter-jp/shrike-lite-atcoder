# ABC470D 固定幅並列版 テスト・測定結果

測定日: 2026-08-14 (Asia/Tokyo)

## 結論

固定幅版は全対象Kで正しく、入力順を保つprefix batchingにより高並列・ランダムケースのlogical clockを大幅に削減した。一方、ローカル `vvp` 実時間は全条件でBaselineより長く、logical clock削減がシミュレータ実時間削減には直結しなかった。

次段階の先読みスケジューリングで基準にするKは **`K=256`** と評価する。理由は次のとおり。

- 高並列で `1956 clocks`（Baseline比255.6倍）、ランダムで `2134 clocks`（234.3倍）まで削減する。
- 固定幅群の3ケース平均 `vvp` 中央値が8.351秒で、測定したKの中で最小だった。
- Peak Working Setは最大62.59 MiBで十分小さい。
- K=512はさらにlogical clockを減らすが、K=256比で高並列・ランダム双方の `vvp` が悪化した。

logical clockだけを最小化する選択はK=512、`vvp`だけを最小化する選択はBaseline K=1である。K=256は次段階の比較基準として両者のバランスが最もよい。

## 環境・条件

- OS: Microsoft Windows NT 10.0.26200.0
- CPU識別子: Intel64 Family 6 Model 154 Stepping 3、論理プロセッサ20
- Icarus Verilog: 12.0 devel (`s20150603-1539-g2693dd32b`)
- Python: 3.13.1
- コンパイル: `iverilog -g2012 -DONLINE_JUDGE -DATCODER`
- 実行: `vvp -n`
- `N=Q=500000`
- 各条件3回。表の `vvp` は中央値、Peak Working Setは3回中最大。
- `vvp` 時間は入力生成とコンパイルを除き、プロセス開始から終了まで。TIME=0入力、クロック処理、回答出力を含む。
- 50 MHz換算は `20 ns/clock` の理想FPGAモデル上の参考値。
- 全81実行で50万個の出力トークンを期待出力と照合した。

比較用K=1は固定幅版ではなく、未変更の `abc470d_baseline.sv` を同じ入力・同じ条件で再測定した値である。

## 正しさテスト

実行コマンド:

```powershell
python tests\test_fixed_parallel.py
```

結果:

```text
PASS K=4:   3 samples, 12 special/boundary, 300 random
PASS K=8:   3 samples, 12 special/boundary, 300 random
PASS K=16:  3 samples, 12 special/boundary, 300 random
PASS K=32:  3 samples, 12 special/boundary, 300 random
PASS K=64:  3 samples, 12 special/boundary, 300 random
PASS K=128: 3 samples, 12 special/boundary, 300 random
PASS K=256: 3 samples, 12 special/boundary, 300 random
PASS K=512: 3 samples, 12 special/boundary, 300 random
```

全2520実行で、逐次Python参照実装の回答、および独立したPython prefix groupingが算出するlogical clock数と一致した。特殊ケースには、SPEC記載のグループ途中競合、競合後を飛び越さないケース、Type 2頻発、Type 2直前直後のType 1、K幅境界を含む。

## A. 高並列ケース

`(1,2), (3,4), ...` の互いに素な交換を循環させた。各位置対を合計2回交換するため最終状態は恒等順列であり、全要素を検証した。

| K | logical clocks | 50 MHz換算 | `vvp` 中央値 | Peak Working Set |
|---:|---:|---:|---:|---:|
| 1 (Baseline) | 500002 | 10.000040 ms | 6.984 s | 54.86 MiB |
| 4 | 125002 | 2.500040 ms | 8.465 s | 62.54 MiB |
| 8 | 62502 | 1.250040 ms | 8.147 s | 62.54 MiB |
| 16 | 31252 | 0.625040 ms | 8.184 s | 62.54 MiB |
| 32 | 15627 | 0.312540 ms | 7.809 s | 62.50 MiB |
| 64 | 7815 | 0.156300 ms | 7.756 s | 62.51 MiB |
| 128 | 3909 | 0.078180 ms | 8.009 s | 62.52 MiB |
| 256 | 1956 | 0.039120 ms | 7.673 s | 62.56 MiB |
| 512 | 979 | 0.019580 ms | 7.787 s | 62.65 MiB |

logical clockはほぼK倍に改善し続けた。固定幅版の最短 `vvp` はK=256だが、Baselineより9.87%長い。K=256→512ではclockを49.95%削減した一方、`vvp` は1.49%悪化した。

## B. ランダムケース

seed `470`、全クエリType 1、`x != y` の位置を一様ランダム生成した。同じ入力を全Kで使用し、逐次交換で生成した期待順列の全要素を検証した。

| K | logical clocks | 50 MHz換算 | `vvp` 中央値 | Peak Working Set |
|---:|---:|---:|---:|---:|
| 1 (Baseline) | 500002 | 10.000040 ms | 7.443 s | 54.87 MiB |
| 4 | 125006 | 2.500120 ms | 8.371 s | 62.51 MiB |
| 8 | 62508 | 1.250160 ms | 8.467 s | 62.54 MiB |
| 16 | 31263 | 0.625260 ms | 8.189 s | 62.50 MiB |
| 32 | 15648 | 0.312960 ms | 8.313 s | 62.54 MiB |
| 64 | 7854 | 0.157080 ms | 8.130 s | 62.52 MiB |
| 128 | 3988 | 0.079760 ms | 8.203 s | 62.54 MiB |
| 256 | 2134 | 0.042680 ms | 8.011 s | 62.59 MiB |
| 512 | 1328 | 0.026560 ms | 8.241 s | 62.62 MiB |

K=256まではBaseline比234.3倍、K=512では376.5倍のclock削減となった。ただし位置衝突によりK=256→512のclock削減率は37.77%へ鈍化し、`vvp` は2.87%悪化した。固定幅の効果が薄くなり始める地点はK=256以降と判断する。

## C. 高競合ケース

`1 1 500000` を50万回繰り返した。毎回2件目が位置競合するため全Kで1 query/clockとなる。交換回数が偶数なので最終状態は恒等順列であり、全要素を検証した。

| K | logical clocks | 50 MHz換算 | `vvp` 中央値 | Peak Working Set |
|---:|---:|---:|---:|---:|
| 1 (Baseline) | 500002 | 10.000040 ms | 6.801 s | 54.90 MiB |
| 4 | 500002 | 10.000040 ms | 9.473 s | 62.50 MiB |
| 8 | 500002 | 10.000040 ms | 9.784 s | 62.51 MiB |
| 16 | 500002 | 10.000040 ms | 9.335 s | 62.50 MiB |
| 32 | 500002 | 10.000040 ms | 9.159 s | 62.53 MiB |
| 64 | 500002 | 10.000040 ms | 9.448 s | 62.54 MiB |
| 128 | 500002 | 10.000040 ms | 9.425 s | 62.53 MiB |
| 256 | 500002 | 10.000040 ms | 9.369 s | 62.54 MiB |
| 512 | 500002 | 10.000040 ms | 9.325 s | 62.50 MiB |

logical clockの改善はなく、競合検出とstamp更新により固定幅版はBaselineより34.67%～43.86%遅い。Kの大小によるメモリ・実時間差は小さく、実装が競合直後に走査を停止していることも確認できる。

## Kの評価

### logical clock

- 高並列では測定範囲全体でKにほぼ反比例し、K=512が最良。
- ランダムでもK=512が最良だが、位置衝突によってK=256以降の改善率が鈍化する。
- 高競合では全KがBaselineと同じで、固定幅を増やす効果はない。

### `vvp` 実時間

- Baseline K=1が3ケースすべてで最短。固定幅版は、処理クエリ総数自体は50万件のままで、グループ形成のstampアクセスも追加されるため、logical clock削減が実時間短縮にならなかった。
- 固定幅版だけの3ケース平均は、K=256の8.351秒が最短。K=32の8.427秒、K=64の8.445秒、K=512の8.451秒が続く。

### メモリ

- Baselineは54.86～54.90 MiB、固定幅版は62.50～62.65 MiB。
- 固定幅版の増加約7.7 MiBは主に `used_stamp[1:N]` による。K自体を増やしても静的配列サイズは変わらないため、K間の差は測定揺れ程度だった。
- 1024 MiB制限に対して十分余裕がある。

### K=1024を追加しなかった理由

追加条件は、K=512時点でもlogical clockと `vvp` 実時間の改善がともに明確に続くことである。logical clockは改善したが、K=256→512で `vvp` は高並列が7.673→7.787秒、ランダムが8.011→8.241秒へ悪化した。条件の一方を満たさないためK=1024は測定していない。

## 発見した問題点

- 理想FPGA上のlogical clockとIcarusの実時間は逆方向に動き得る。現実装の1クロック内ループは受理クエリを結局1件ずつ評価・更新するため、イベント数削減だけでは追加の競合判定コストを回収できない。
- 高競合入力では固定幅化の利益がなく、約35%～44%のシミュレーション実時間ペナルティだけが残る。
- Windowsの `vvp` 出力はCRLF、Python期待出力はLFだったため、バイトハッシュではなく空白区切りトークン全件比較を採用した。値の検証範囲は変わらない。
- 本測定値はローカルWindows環境の値であり、AtCoder Linux環境の値と同一ではない。

## 再現方法と生データ

```powershell
python tests\test_fixed_parallel.py
powershell -NoProfile -ExecutionPolicy Bypass -File tools\measure_fixed_parallel.ps1
```

各3回の実時間、生のbyte単位Peak Working Set、集計値は `measurements/fixed_parallel_results.csv` に保存している。

この版では、先読み、クエリ順序変更、競合クエリの飛び越し、空きレーンへの後続詰め込み、Out-of-Order処理を実装していない。
