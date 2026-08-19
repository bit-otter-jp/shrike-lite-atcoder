# ABC471E Narrow - WORK_REQUEST_6

## 1. 適用文書

Applicable SPEC:

```text
SPEC_abc471e_narrow_3.md
```

Applicable IMPL:

```text
IMPL_abc471e_narrow_4.md
```

Previous completed REPORT:

```text
REPORT_abc471e_narrow_4.md
```

Interrupted previous WORK:

```text
WORK_REQUEST_abc471e_narrow_5.md
```

Reference map:

```text
REFERENCE_MAP.md
```

`WORK_REQUEST_5` は実行途中で人間判断により停止した。
本WORKは、その時点までに得られた `boundary_v4/` の結果を保全・整理し、
「厳密な最大N境界探索」から「代表点による実装可能性の観察」へ目的を変更する。

旧SPEC/IMPL/WORK/REPORTは履歴として保持し、上書きしない。

---

## 2. 目的変更

WORK_REQUEST_5では、WIDTH=5..9について、

```text
最大 PLACE_FIT N_MAX
```

を厳密に探索することを目的としていた。

しかし途中結果では、N_MAXを下げてもType=L使用数が単調に減少しない例が確認された。

既知の代表例:

```text
W8 N_MAX=250 : 165 Type=L  PLACE_FAIL
W8 N_MAX=63  : 141 Type=L  PLACE_FAIL
W8 N_MAX=31  : 151 Type=L  PLACE_FAIL
W8 N_MAX=15  : 141 Type=L  PLACE_FAIL
```

したがって、N_MAXを1ずつ詰めて「最大値」を確定しても、
ABC9 mapping、packing、state/counter幅、carry-chain、placer mappingの
局所的な揺らぎを細かく測定する比重が大きくなる。

本WORKでは厳密な最大N探索を打ち切る。

新しい目的は、

```text
WIDTH=5..9について、
代表的なN_MAX点でShrike-Liteへの
fit / fail / timingの実測例を整理し、
当初の面積予想と現実の差を明確にする
```

ことである。

---

## 3. 今回やらないこと

本WORK開始後は、原則として新しい設計実験を追加しない。

禁止:

```text
新しいN_MAX候補のPost-Synthesis
新しいN_MAX候補のPNR
W8 N_MAX=7の追加PNR
W5 N_MAX=16..29の厳密探索
W7/W8/W9の最大N確定探索
二分探索
全探索
architecture変更
RTL cleanup
state encoding探索
PNR option tuning
timing optimization
bitstream生成
flash
実機試験
```

すでに開始済みのtool processが残っている場合は、
安全に終了状態を確認してログを保存するだけとし、
次候補へ進まない。

---

## 4. 保護対象

開始時に、既存の主要文書とtreeの状態を記録する。

少なくとも:

```text
SPEC_abc471e_narrow.md
SPEC_abc471e_narrow_2.md
SPEC_abc471e_narrow_3.md

IMPL_abc471e_narrow.md
IMPL_abc471e_narrow_2.md
IMPL_abc471e_narrow_3.md
IMPL_abc471e_narrow_4.md

WORK_REQUEST_abc471e_narrow.md
WORK_REQUEST_abc471e_narrow_2.md
WORK_REQUEST_abc471e_narrow_3.md
WORK_REQUEST_abc471e_narrow_5.md

REPORT_abc471e_narrow.md
REPORT_abc471e_narrow_2.md
REPORT_abc471e_narrow_3.md
REPORT_abc471e_narrow_4.md

REFERENCE_MAP.md

ffpga/
sim/
tools/
experiments/
diagnostics/
compact_v3/
```

`boundary_v4/` はWORK_REQUEST_5の途中成果物を含むため、
本WORKではread-mostlyとする。

既存の実験成果物を書き換えない。

今回追加してよいものは、

```text
boundary_v4/summary/
REPORT_abc471e_narrow_6.md
```

を基本とする。

---

## 5. 最初に行うこと

WORK_REQUEST_5の途中で生成済みの `boundary_v4/` をinventoryする。

候補ごとに、

```text
WIDTH
MOD
N_MAX
COUNT_WIDTH
VALUE_BYTES

Icarus実施有無
Icarus result

Post-Synthesis実施有無
LUT
FF
CARRY4
ceil(LUT/4)

PNR実施有無
packing result
Type=L
MinPlacer result
router result

利用可能なtiming stage
achievable frequency
```

を、必ず保存済みlog / JSON / reportから回収する。

チャット上の途中報告だけを最終値の根拠にしない。

---

## 6. WORK_REQUEST_5の既知checkpoint

次の値は途中報告として既知である。
成果物から照合し、一致したものだけREPORTへ確定値として載せる。

```text
W5 / MOD=31
    N_MAX=30
        Post-Synthesis LUT=452
        Type=L=149/140
        PLACE_FAIL

    N_MAX=15
        Type=L=121/140
        PLACE_FIT
        PNR_COMPLETE
        post-route=51.634 MHz

W6 / MOD=61
    N_MAX=60
        Type=L=138/140
        PLACE_FIT
        PNR_COMPLETE
        post-route=48.757 MHz

W7 / MOD=127
    N_MAX=126
        Type=L=152/140
        PLACE_FAIL

    N_MAX=63
        Type=L=139/140
        PLACE_FIT
        PNR_COMPLETE
        post-route=33.118 MHz

W8 / MOD=251
    N_MAX=250
        LUT=557
        Type=L=165/140
        PLACE_FAIL
        post-LUT-packing estimate=11.324 MHz

    N_MAX=63
        Type=L=141/140
        PLACE_FAIL

    N_MAX=31
        Type=L=151/140
        PLACE_FAIL

    N_MAX=15
        Type=L=141/140
        PLACE_FAIL

W9 / MOD=509
    N_MAX=508
        Post-Synthesis screening lower bound=166 CLB
        SCREEN_FAIL
        PNR未実施
```

値が保存成果物と異なる場合は、成果物を正とし、
差異をREPORTに明記する。

---

## 7. 代表点の考え方

今回の代表点は「最大Nの証明」ではない。

各WIDTHについて、

```text
最大問題世界側の代表点
+
必要なら、fitした縮小側の代表点
```

を残す。

例えば:

```text
W5 : N=30 FAIL / N=15 FIT
W6 : N=60 FIT
W7 : N=126 FAIL / N=63 FIT
W8 : N=250 FAIL + 既取得tier例
W9 : N=508 SCREEN_FAIL
```

これにより、

```text
どの程度まで縮めると実装可能性が現れるか
```

の概観を示す。

「W5の最大fitは15」
「W7の最大fitは63」
などとは断定しない。

---

## 8. 非単調性の扱い

本REPORTの重要な観測事項として、
N_MAXと物理Type=L使用数が単調でないことを明示する。

特にW8では、

```text
N_MAX=63 -> 141
N_MAX=31 -> 151
N_MAX=15 -> 141
```

のような揺らぎが観測されている。

したがって、

```text
N_MAXを小さくすれば必ずfitへ近づく
```

とは結論しない。

原因を単一要因へ断定しない。

可能な説明要素としてのみ、

```text
COUNT_WIDTHの段差
Yosys/ABC9 mapping
carry-chain packing
dual-LUT packing
control/MUX形状
placer geometry
```

を挙げる。

---

## 9. Post-SynthesisとPNRの関係

次を区別する。

```text
logical/Post-Synthesis LUT
ceil(LUT/4) screening lower bound
packed Type=L
placement success/failure
route success/failure
```

W8で、

```text
557 LUT
ceil(557/4)=140
実PNR Type=L=165
```

となったことを代表例として使える。

`ceil(LUT/4)` は必要条件のscreeningであり、
物理fit予測ではないことを再確認する。

---

## 10. timingの扱い

timingは存在するstageだけ報告する。

PNR_COMPLETEした候補:

```text
W5 N=15 : post-route 51.634 MHz
W6 N=60 : post-route 48.757 MHz
W7 N=63 : post-route 33.118 MHz
```

を成果物から照合する。

50 MHz制約に対して、

```text
>=50 MHz
<50 MHz
```

を事実として分類してよい。

ただし今回の主目的は容量挙動の観察であり、
timing closureのために設計変更しない。

PLACE_FAIL候補について、
packing前後の推定値をpost-route timingと呼ばない。

---

## 11. W5/W6の逆転

結果が成果物でも確認できた場合、

```text
W5 N=30 : 149 Type=L FAIL
W6 N=60 : 138 Type=L FIT
```

という逆転を重要な観測として記録する。

これは、

```text
WIDTHが小さいほど必ず物理面積が小さい
```

という単純な期待が成立しない実例である。

ただしW5とW6では、

```text
MOD
N_MAX
COUNT_WIDTH
論理定数
mapping結果
```

も異なるため、
「WIDTHだけが原因」とは解釈しない。

---

## 12. summary data

新規に次を作成する。

```text
boundary_v4/summary/observed_points.csv
boundary_v4/summary/observed_points.json
```

最低限のcolumn:

```text
WIDTH
MOD
N_MAX
COUNT_WIDTH
VALUE_BYTES
Icarus
LUT
FF
CARRY4
LUT_LB
Type_L
PLACE
ROUTE
TIMING_STAGE
FMAX_MHZ
SOURCE_ARTIFACT
```

未実施値は空欄または明示的な `NOT_RUN` とする。

推測値で穴埋めしない。

---

## 13. グラフは作らない

本WORKでは「実装可能境界グラフ」を完成させることを目的としない。

理由:

```text
厳密最大Nを探索していない
物理使用量が非単調
観測点が疎である
```

ため。

必要なら後の記事作成時に、
`observed_points.csv` から

```text
FIT / FAILの観測点
```

として可視化できるようデータだけ整える。

点を滑らかな境界線で結ばない。

---

## 14. REPORT

主成果物:

```text
REPORT_abc471e_narrow_6.md
```

推奨構成:

```text
1. Executive Summary
2. WORK_REQUEST_5を停止した理由
3. 既取得成果物のinventory
4. 代表観測点
5. WIDTH別の観測
6. N_MAXとType=Lの非単調性
7. Post-Synthesis screeningと実PNRの差
8. timing観測
9. 今回言えること / 言えないこと
10. 未実施事項
11. 再現成果物
12. 保護対象確認
13. 停止点
```

---

## 15. REPORTで必ず答えること

1. W5..W9でどの代表点を実測したか。
2. どの代表点がPLACE_FIT / PNR_COMPLETEだったか。
3. W5/W6の逆転は再現成果物で確認できるか。
4. W8のN_MAX縮小時にType=Lが非単調だったか。
5. `ceil(LUT/4)` が物理fit予測として不十分だった具体例は何か。
6. 50 MHzをpost-routeで満たした代表点はあるか。
7. 今回、厳密な最大N_MAXを確定しなかった理由は何か。
8. 「実装可能境界」という言葉をどこまで使えるか。
9. 当初の面積感覚と実測の差から得た最も重要な教訓は何か。

---

## 16. 言ってよい結論

成果物が支持する範囲で、例えば次は言ってよい。

```text
W5..W9でfit/failの代表点を得た。
W6 N=60は配置配線まで成立した。
W7 N=63も配置配線まで成立した。
W8はN_MAXを大きく縮めても観測Type=Lが単調には減らなかった。
物理fitは単純なLUT数やWIDTH/N_MAXだけでは予測しにくい。
```

---

## 17. 言わない結論

次は断定しない。

```text
各WIDTHの厳密な最大N_MAX
このarchitectureの数学的・物理的な最適境界
W8はどのN_MAXでも絶対にfitしない
W9は小さいN_MAXでも絶対にfitしない
WIDTHとType=L使用数の単調関係
N_MAXとType=L使用数の単調関係
```

---

## 18. WORK_REQUEST_5の扱い

WORK_REQUEST_5は削除・修正しない。

履歴上は、

```text
厳密境界探索を試みたが、
途中観測で非単調性が明確になり、
人間判断で停止したWORK
```

として残す。

REPORT_abc471e_narrow_6.mdには、
WORK_REQUEST_5が完了ではなく途中停止だったことを明記する。

---

## 19. 停止条件

次を完了したら停止する。

```text
既取得boundary_v4成果物inventory
途中報告値と成果物の照合
observed_points.csv/json作成
代表点の整理
非単調性の整理
REPORT_abc471e_narrow_6.md作成
保護対象再照合
```

新規Icarus、Post-Synthesis、PNR、RTL変更には進まない。
