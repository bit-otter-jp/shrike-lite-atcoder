# ABC470D Out-of-Order版 テスト・測定結果

測定日: 2026-08-14 (Asia/Tokyo)

## 結論

`ISSUE_WIDTH=256 / LOOKAHEAD=1024` のOut-of-Order発行は、固定prefix版で早い位置の依存により空いていたレーンを、後方の独立クエリで埋められた。特にInterleaved dependencyでは、Fixed K=256の平均発行数が `2.000 queries/cycle`（効率0.781%）だったのに対し、OoOは `255.885 queries/cycle`（99.955%）となり、logical clockを `250003` から `1956` へ99.218%削減した。ランダムでも `2134` から `1956` へ8.341%削減し、理想的な `ceil(500000 / 256) = 1954` issue cyclesに到達した。

一方、ローカルIcarusの `vvp` 実時間は全ケースでBaseline K=1が最短だった。OoO cancellation OFFもFixed K=256より全ケースで遅く、1024件の依存管理コストがlogical clock削減を上回った。相殺機会のないケースではcancellation ONがさらに遅く、OFF比で約75%～87%悪化した。したがって、**理想FPGAモデル上のlogical clock改善と、Icarus上の実時間改善は一致しない**。

cancellationは適合入力では有効だった。高競合の完全同一swap 50万件をすべて相殺し、Cancellation-richではType 1を40万件、Type 2を10万件削除した。どちらもlogical clockは初期化と回答格納だけの `2` になった。ただし `vvp` はFixed K=256比でそれぞれ2.51%、27.34%遅く、相殺判定自体の実行コストは残った。

以上から、次段階の基準構成は次のように評価する。

- 発行機構の基準: **OoO 256/1024, cancellation OFF**。OoO単独のレーン充填効果を分離でき、ランダムとInterleaved dependencyでlogical clock改善を確認できる。
- ABC470D固有最適化を含む機能基準: **OoO 256/1024, cancellation ON**。安全な相殺が多い入力では圧倒的にlogical clockを減らすが、一般入力の `vvp` コストが大きいため常時高速化策とは評価しない。
- 実シミュレーション時間の基準: 引き続きBaseline K=1。今回のローカル測定では全ケースで最速だった。

## 環境・測定条件

- OS: Microsoft Windows NT 10.0.26200.0
- CPU識別子: Intel64 Family 6 Model 154 Stepping 3、論理プロセッサ20
- Icarus Verilog: 12.0 devel (`s20150603-1539-g2693dd32b`)
- Python: 3.13.1
- コンパイル: `iverilog -g2012 -DONLINE_JUDGE -DATCODER`
- 実行: `vvp -n`
- 全ケース `N=Q=500000`
- 比較対象: Baseline K=1、Fixed K=256、OoO 256/1024 cancellation OFF、同ON
- 各条件3回。表の `vvp` は中央値、Peak Working Setは3回中最大。
- `vvp` 実時間は入力生成、期待値生成、コンパイル、出力検証を含まず、`vvp` プロセス開始から終了まで。
- A～Eの全60実行と、Strong dependencyのFixed／OoO OFF各3回、合計66実行で、各50万個の出力トークンを逐次Python参照結果と照合した。
- 50 MHz換算は `20 ns/clock` の理想FPGAモデル上の参考値であり、`vvp` 実時間とは別の指標である。
- 平均発行数は `Type 1 executed / issue cycles`、issue効率はその値を256で割った値。全Type 1が相殺された条件はissue cycleが0なので、表では0とした。

BaselineとFixedは既存の各RTLをそのまま再コンパイルし、同一の新規入力・測定条件で比較した。

## 既存成果物の不変確認

作業開始前と完了時にSHA-256を取得し、次の7ファイルがすべて一致することを確認した。

| 既存成果物 | SHA-256（開始時 = 完了時） |
|---|---|
| `abc470d_baseline.sv` | `D1604164AC381E6C6E847DFE973FCE68F46A0C02F7E726A0BAAD5724219392FE` |
| `DESIGN_BASELINE.md` | `073108E2EE9A2EE12444088AB64E45EC715FB25C3EA4D51F4670A3992D8705FC` |
| `MEASUREMENT_BASELINE.md` | `946BEB530BE84BA7017657032A9112A672717278DA1057DBF1154CBB7F8F78C2` |
| `abc470d_fixed_parallel.sv` | `8CB2B506CB9C7016E246CFA35ECDD59C444C9FE77F609259FE66FC6025862E1C` |
| `DESIGN_FIXED_PARALLEL.md` | `9841EB2D689E3DB7866D9394C72006A214B5467B24E2CA1B69705D9613C763AE` |
| `MEASUREMENT_FIXED_PARALLEL.md` | `5E2091A76E987CCE069BB3CC45DD1EDC7C6BD05ACA30C00FBB08DC11A4B82B7B` |
| `measurements/fixed_parallel_results.csv` | `5BCF38EAB5FF3EA7A0C9AC8967CC0D99453912E8095019C6440B71E86AF322D2` |

## 正しさテスト

実行コマンド:

```powershell
python tests\test_out_of_order.py
```

結果:

```text
PASS: cancellation OFF/ON, 3 samples, 17 special, 300 random (seed=470)
```

cancellation OFF/ONそれぞれ320件、合計640回のVerilog実行がすべて成功した。各実行で以下を独立Pythonモデルと照合した。

- ABC470D逐次モデルによる最終回答
- liveクエリを直接走査する意味ベースのOoO schedulerによるlogical clock
- list削除で固定点まで簡約するnormalizationモデル
- Type 1実行数・相殺数、Type 2実行数・消去数、issue cycles

PythonモデルはRTLのtouch link／ready heapを模倣せず、「先行する全live Type 1のtouch集合」を直接検査する構造にした。特殊テストには、先頭依存チェーンの追い越し、待機クエリに依存する後続の追い越し禁止、多段依存、256 issue境界、1024 lookahead境界、実行済み穴、Type 2 barrier前後、およびSPEC記載の全cancellation／cascading例を含む。

## 最大規模ケース

- A 高並列: 互いに素なswapを循環させる。
- B ランダム: seed `470`、全件Type 1。
- C 高競合: `swap(1,500000)` を50万回反復する。
- D Interleaved dependency: 互いに独立な3位置チェーンを並べ、各チェーンで `swap(a,b)`, `swap(b,c)` とする。Fixed prefixは2件目の競合で早期停止するが、OoOは後続チェーンから発行できる。
- E Cancellation-rich: 2件ずつの独立swapペアとType 2を、Type 1／Type 2双方のcascading cancellationが大量に起きる形で反復する。元の内訳はType 1が40万件、Type 2が10万件。
- F Strong dependency: `swap(1,2), swap(2,3)` を交互に50万件並べる。各queryが直前queryと位置を共有し、同一swap間にも共有位置へのtouchがある。

## A. 高並列

| 実装 | logical clocks | 50 MHz換算 | `vvp` 中央値 | Peak Working Set | 平均発行 / 効率 | Type 1 実行 / 相殺 | Type 2 実行 / 消去 |
|---|---:|---:|---:|---:|---:|---:|---:|
| Baseline K=1 | 500002 | 10.000040 ms | 7.215 s | 54.88 MiB | 1.000 / 0.391% | 500000 / 0 | 0 / 0 |
| Fixed K=256 | 1956 | 0.039120 ms | 7.933 s | 62.59 MiB | 255.885 / 99.955% | 500000 / 0 | 0 / 0 |
| OoO OFF | 1956 | 0.039120 ms | 25.704 s | 123.75 MiB | 255.885 / 99.955% | 500000 / 0 | 0 / 0 |
| OoO ON | 1956 | 0.039120 ms | 46.285 s | 123.72 MiB | 255.885 / 99.955% | 500000 / 0 | 0 / 0 |

Fixedがすでに理想的に256レーンを埋めるため、OoOのlogical clock改善はない。OoO OFFはFixed比3.24倍、ONは5.83倍の `vvp` 時間となり、純粋なscheduler／normalization overheadが表れた。

## B. ランダム

| 実装 | logical clocks | 50 MHz換算 | `vvp` 中央値 | Peak Working Set | 平均発行 / 効率 | Type 1 実行 / 相殺 | Type 2 実行 / 消去 |
|---|---:|---:|---:|---:|---:|---:|---:|
| Baseline K=1 | 500002 | 10.000040 ms | 7.306 s | 54.85 MiB | 1.000 / 0.391% | 500000 / 0 | 0 / 0 |
| Fixed K=256 | 2134 | 0.042680 ms | 8.234 s | 62.56 MiB | 234.522 / 91.610% | 500000 / 0 | 0 / 0 |
| OoO OFF | 1956 | 0.039120 ms | 25.298 s | 123.74 MiB | 255.885 / 99.955% | 500000 / 0 | 0 / 0 |
| OoO ON | 1956 | 0.039120 ms | 47.303 s | 123.72 MiB | 255.885 / 99.955% | 500000 / 0 | 0 / 0 |

OoOはFixed比でlogical clockを8.341%削減し、issue効率を91.610%から99.955%へ改善した。相殺件数は0であり、ONの `vvp` はOFFより86.98%長かった。

## C. 高競合

| 実装 | logical clocks | 50 MHz換算 | `vvp` 中央値 | Peak Working Set | 平均発行 / 効率 | Type 1 実行 / 相殺 | Type 2 実行 / 消去 |
|---|---:|---:|---:|---:|---:|---:|---:|
| Baseline K=1 | 500002 | 10.000040 ms | 6.689 s | 54.89 MiB | 1.000 / 0.391% | 500000 / 0 | 0 / 0 |
| Fixed K=256 | 500002 | 10.000040 ms | 9.634 s | 62.52 MiB | 1.000 / 0.391% | 500000 / 0 | 0 / 0 |
| OoO OFF | 500002 | 10.000040 ms | 16.937 s | 123.72 MiB | 1.000 / 0.391% | 500000 / 0 | 0 / 0 |
| OoO ON | 2 | 0.000040 ms | 9.876 s | 123.71 MiB | 0 / 0% | 0 / 500000 | 0 / 0 |

OFFでは全クエリが同じ2位置に依存するため、OoOでも1 query/cycleのままでlogical clockは改善しない。ONの削減はOoO発行ではなく、偶数回の完全同一swapをcascading cancellationした効果である。全実行を消しても、ONの `vvp` はFixedより2.51%長かった。

## D. Interleaved dependency

| 実装 | logical clocks | 50 MHz換算 | `vvp` 中央値 | Peak Working Set | 平均発行 / 効率 | Type 1 実行 / 相殺 | Type 2 実行 / 消去 |
|---|---:|---:|---:|---:|---:|---:|---:|
| Baseline K=1 | 500002 | 10.000040 ms | 6.954 s | 54.86 MiB | 1.000 / 0.391% | 500000 / 0 | 0 / 0 |
| Fixed K=256 | 250003 | 5.000060 ms | 8.893 s | 62.54 MiB | 2.000 / 0.781% | 500000 / 0 | 0 / 0 |
| OoO OFF | 1956 | 0.039120 ms | 25.274 s | 123.78 MiB | 255.885 / 99.955% | 500000 / 0 | 0 / 0 |
| OoO ON | 1956 | 0.039120 ms | 44.143 s | 123.71 MiB | 255.885 / 99.955% | 500000 / 0 | 0 / 0 |

今回の主目的を最も直接に示すケースである。Fixedは早い競合でグループ形成を止め、平均2レーンしか使えなかった。OoOは待機チェーンを保持したまま後続の独立チェーンを拾い、Fixed比99.218%のlogical clock削減と99.955%のissue効率を得た。ただし `vvp` はOFFでもFixedより184.20%、ONでは396.38%長い。

## E. Cancellation-rich

| 実装 | logical clocks | 50 MHz換算 | `vvp` 中央値 | Peak Working Set | 平均発行 / 効率 | Type 1 実行 / 相殺 | Type 2 実行 / 消去 |
|---|---:|---:|---:|---:|---:|---:|---:|
| Baseline K=1 | 500002 | 10.000040 ms | 6.116 s | 54.87 MiB | 1.000 / 0.391% | 400000 / 0 | 100000 / 0 |
| Fixed K=256 | 300002 | 6.000040 ms | 7.400 s | 62.54 MiB | 2.000 / 0.781% | 400000 / 0 | 100000 / 0 |
| OoO OFF | 300002 | 6.000040 ms | 14.516 s | 123.71 MiB | 2.000 / 0.781% | 400000 / 0 | 100000 / 0 |
| OoO ON | 2 | 0.000040 ms | 9.423 s | 123.71 MiB | 0 / 0% | 0 / 400000 | 0 / 100000 |

ONはType 1を40万件、Type 2を10万件、合計50万件すべて削除し、Fixed比99.9993%のlogical clock削減となった。`vvp` はOFFより35.09%短縮したが、Fixedより27.34%、Baselineより54.07%長い。

## F. Strong dependency（第33回補足）

| 実装 | logical clocks | 50 MHz換算 | `vvp` 中央値 | Peak Working Set | 平均発行 / 効率 |
|---|---:|---:|---:|---:|---:|
| Fixed K=256 | 500002 | 10.000040 ms | 9.030 s | 62.50 MiB | 1.000 / 0.391% |
| OoO OFF | 500002 | 10.000040 ms | 15.978 s | 123.72 MiB | 1.000 / 0.391% |

`swap(1,2)` と `swap(2,3)` が交互に続くため、Fixedは毎回prefixの2件目で競合し、OoOも待機queryに依存する後続を追い越せない。両方式とも50万issue cyclesとなり、OoO OFFはclockを削減せず依存管理コストだけが残った。生の3回値は測定CSVに収録している。

## 総合評価

### レーン充填とlogical clock

- 高並列ではFixedがすでに99.955%のissue効率で、OoOの追加効果はなかった。
- ランダムではFixedの91.610%から99.955%へ改善し、logical clockを8.341%削減した。
- Interleaved dependencyではFixedの0.781%から99.955%へ改善し、logical clockを99.218%削減した。256レーンを1024件先読みで埋める目的は達成した。
- 高競合はOFFで改善しない。依存関係上、lookaheadを広げてもreadyは常に1件だけである。
- Strong dependencyでもFixed／OoO OFFはともに1 query/cycleで、logical clockは改善しない。

### cancellation

- 相殺機会がないA、B、Dではlogical clockはOFFと同一で、ONのnormalization処理だけが増えた。
- Cは完全同一swap 50万件を、EはType 1 40万件とType 2 10万件を安全に削除した。
- Type 1のprevious-touch復元とType 2偶奇簡約を固定点まで反復することで、Type 1削除後のType 2相殺、Type 2削除後のType 1相殺を含むcascading cancellationを確認した。

### `vvp` 実時間

- Baselineが5ケースすべてで最短だった。
- OoO OFFはFixed比で75.80%～224.01%遅かった。論理的な実行cycleを減らしても、live list、touch依存、ready heapのソフトウェアシミュレーションコストは減らない。
- 相殺のないA、B、Dで、ONはOFFよりそれぞれ80.07%、86.98%、74.66%遅かった。
- 大量相殺のC、EではONがOFFより41.69%、35.09%速くなったが、それでもFixedより遅かった。
- Strong dependencyではOoO OFFがFixedより76.94%遅く、先読みで発行数を増やせない場合のscheduler overheadが表れた。

### Peak Working Set

- Baseline: 54.85～54.89 MiB
- Fixed K=256: 62.52～62.59 MiB
- OoO: 123.71～123.78 MiB

OoOはFixedより約61.1～61.2 MiB増え、ほぼ2倍になった。主因は50万件分のlive-list／依存link／状態配列と、最大1024件のready・normalization管理である。cancellation ON/OFF間の差は測定揺れ程度だった。

## 発見した問題点・注意事項

- IcarusはRTL記述内のscheduler処理を逐次的なホスト計算として実行するため、理想上のlogical clock短縮がそのまま `vvp` 高速化にはならない。
- cancellation ONは、相殺が少ない入力で毎回のnormalization再構築が大きなオーバーヘッドになる。入力特性が不明な場合、常時ONを実時間最適化とは見なせない。
- 高競合CのONは高競合をOoOが解決した結果ではない。完全同一swapという入力固有の代数的簡約が全件に適用できた結果である。
- 本実装は最初の残存Type 2を完全なbarrierとして扱い、その後ろを先行実行しない。相殺でbarrierが消えた場合だけ、次のnormalization反復で新しい範囲を扱う。
- 本測定値はローカルWindows/Icarus環境の値であり、合成後の実FPGA性能やAtCoder Linux環境の実時間を直接表すものではない。

## 再現方法と生データ

```powershell
python tests\test_out_of_order.py
powershell -NoProfile -ExecutionPolicy Bypass -File tools\measure_out_of_order.ps1
```

各3回の実時間、byte単位Peak Working Set、query clocks、issue cycles、Type 1／Type 2統計、平均発行数とissue効率は `measurements/out_of_order_results.csv` に保存している。
