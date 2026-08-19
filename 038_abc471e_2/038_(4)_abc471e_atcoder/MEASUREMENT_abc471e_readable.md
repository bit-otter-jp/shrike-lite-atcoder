# ABC471E 3レジスタ可読版 測定記録

測定日: 2026-08-18 (JST)

## 結論

`abc471e_readable.v` を `N=200000, K=100000` の決定的最大ケースで 3 回実行した。
全実行が期待値 `762975326` と一致し、実時間は 1.624638～1.637253 秒、Peak
Working Set は 8.945～8.953 MiB だった。

3 回すべて採用基準の 3.0 秒以内であるため、可読性を維持したまま記事掲載候補とする。
追加の高速化は行っていない。

## 測定環境

| 項目 | 値 |
|---|---|
| OS | Microsoft Windows NT 10.0.26200.0, x64 |
| CPU | Intel64 Family 6 Model 154 Stepping 3, 20 logical processors |
| Icarus Verilog | 12.0 (devel), s20150603-1539-g2693dd32b |
| Python | 3.13.1 |
| PowerShell | 5.1.26100.8875 |

コンパイル条件:

```powershell
iverilog -g2012 -Wall -s main -o abc471e_readable.out abc471e_readable.v
```

## 正しさ確認

測定前に次を実行した。

```powershell
python test_abc471e_readable.py --random-cases 300
```

結果:

```text
official samples: 3 passed
boundary cases: 9 passed
random exhaustive-oracle cases: 300 passed (seed=47100005)
code-test input: passed (answer=379620342)
all tests passed
```

ランダムテストは `1<=N<=8` の K 要素部分集合を `itertools.combinations` で全列挙し、
各部分集合の整数和を二乗して加算する独立 oracle を使用した。

## 最大ケース

WORK_REQUEST_1 と同じ値生成規則を使用した。

```text
N = 200000
K = 100000
Ai = ((i * 1000003 + 123456789) mod 1000000000) + 1
i = 0, 1, ..., N-1
```

今回の測定ファイルは LF 改行で、実体情報は次のとおり。

```text
size     = 1977792 bytes
sha256   = 9f47585250ba0c1a8b157d8bb8ce5e94df72a6aceaaacffb97a8d85222ac7920
expected = 762975326
```

期待値は Python の多倍長整数と `math.comb` を使い、二乗項と全非順序対の寄与を
数えて求めた。

実行時間は `vvp` プロセスの開始直前から終了までを測り、標準入力をパイプへコピー
する時間も含めた。Peak Working Set は実行中に Windows の `PeakWorkingSet64` を
1 ms 間隔で取得した。

| Run | 終了コード | 実時間 (秒) | Peak Working Set (bytes) | MiB | 出力 | stderr |
|---:|---:|---:|---:|---:|---:|:---:|
| 1 | 0 | 1.632896 | 9,388,032 | 8.953 | 762975326 | 空 |
| 2 | 0 | 1.624638 | 9,379,840 | 8.945 | 762975326 | 空 |
| 3 | 0 | 1.637253 | 9,388,032 | 8.953 | 762975326 | 空 |

平均は 1.631596 秒、最大と最小の差は 0.012615 秒だった。標準出力はいずれも
答えと改行だけである。

## WORK_REQUEST_2 コードテスト入力

既存ファイルの SHA-256 が
`1ed80be11d579b6d34e3e382d88a0bc61125ee34d04ce1983b548d40fafea73c` であることを
確認してから単独実行した。

| 項目 | 結果 |
|---|---|
| 入力サイズ | 401,672 bytes |
| 期待値 | 379620342 |
| 出力 | 379620342、1行のみ |
| 終了コード | 0 |
| stderr | 空、0 bytes |
| ローカル実時間 | 1.348148 秒 |
| 一致 | PASS |

ローカル値は環境固有であり、AtCoder 実機の速度を保証するものではない。
