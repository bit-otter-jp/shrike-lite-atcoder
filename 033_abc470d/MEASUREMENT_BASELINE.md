# ABC470D Baseline テスト・測定結果

測定日: 2026-08-14 (Asia/Tokyo)

## 環境

- OS: Microsoft Windows NT 10.0.26200.0
- CPU識別子: Intel64 Family 6 Model 154 Stepping 3、論理プロセッサ20
- Icarus Verilog: 12.0 devel (`s20150603-1539-g2693dd32b`)
- Python: 3.13.1
- 公式問題の制限: 2 sec / 1024 MiB
- コンパイル／実行条件: `iverilog -g2012 -DONLINE_JUDGE -DATCODER`, `vvp -n`

制限は[公式問題](https://atcoder.jp/contests/abc470/tasks/abc470_d?lang=ja)、Verilog のコマンドは[コンテストルール](https://atcoder.jp/contests/abc470/rules?lang=ja)を基準にした。

この測定値はローカル Windows 環境の値であり、AtCoder の Linux 実行環境での値と同一ではない。

## 機能テスト

実行コマンド:

```powershell
python tests\test_baseline.py
```

結果:

```text
PASS: 3 official samples, 8 boundary cases, 300 random cases (seed=470)
```

- 公式サンプル3件: すべて公式出力と一致。
- 境界ケース8件: 最小 `N/Q`、型1のみ、型2のみ、端点交換、逆順列化の奇数／偶数回、逆順列化前後の交換を確認。
- ランダム300件: 小規模順列に対し、各型2で配列を実際に逆順列へ作り直す Python 参照実装と全件一致。
- 全311件で、回路が標準エラーへ報告する論理クロック数が `Q+2` と一致。
- judged stdout には回答だけが出ており、Icarus の終了診断は混入しない。

## 最大規模性能試験

実行コマンド:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\measure_max.ps1
```

ケース:

- `N = 500000`
- `Q = 500000`
- 初期順列は恒等順列。
- 全クエリを `1 1 500000` とした。型2より多い4配列要素更新を毎クエリ行う。
- 交換回数が偶数なので最終回答は恒等順列。出力50万要素を全件検証した。
- 実時間は入力生成と `iverilog` コンパイルを除き、`vvp` プロセス開始から終了までを計測した。従って `TIME=0` 入力ロード、論理クロック処理、回答出力を含む。
- 最大メモリは実行中の `WorkingSet64` / `PeakWorkingSet64` を5 ms以下の待機間隔で観測し、その最大値を記録した。

| Run | 論理クロック数 | `vvp` 実時間 | Peak Working Set |
|---:|---:|---:|---:|
| 1 | 500002 | 6.949 s | 55.15 MiB |
| 2 | 500002 | 6.804 s | 55.12 MiB |
| 3 | 500002 | 6.622 s | 55.15 MiB |
| 中央値 | 500002 | 6.804 s | 55.15 MiB |

出力検証、論理クロック診断ともに3回すべて成功した。

## 判定と発見した問題点

- 正しさ: 公式例、境界例、ランダム比較、最大出力のすべてで問題なし。
- 論理クロック: 目標どおり厳密に `Q+2`。最大ケースは `500000+2 = 500002`。
- メモリ: ローカル Peak Working Set 55.15 MiB以下で、公式1024 MiB制限に対して十分小さい。
- 実時間: ローカル中央値6.804秒で、公式ページの公称2秒を超えた。現行ルール上、Verilog の実行コマンドは `vvp -n a.out` だが、言語別の時間倍率は確認できなかった。環境が異なるため AtCoder 上の合否をこの値だけでは断定できないものの、実時間制限に関するリスクが残る。実際の AtCoder 環境での提出測定、または後続段階での I/O／シミュレーション実行コスト改善が必要である。
- Icarus 12.0では `$fscanf` の書込先に可変添字のメモリ要素を直接指定できなかった。スカラーへ読み込んでから配列へ格納することで回避した。これは `TIME=0` 内の処理であり、論理クロック数には影響しない。
- Windows の親環境に `Path` / `PATH` が併存し `Start-Process` が失敗したため、測定スクリプトは .NET の `Process` と非同期ストリーム転送を使う。`vvp` 本体の測定条件には影響しない。

本段階では仕様に従い、複数クエリの並列化、先読み、クエリスケジューリングは実装していない。
