# ABC471E Narrow - WORK_REQUEST_5

## 1. 適用文書

Applicable SPEC:

```text
SPEC_abc471e_narrow_3.md
```

Applicable IMPL:

```text
IMPL_abc471e_narrow_4.md
```

Previous REPORT:

```text
REPORT_abc471e_narrow_4.md
```

Reference map:

```text
REFERENCE_MAP.md
```

旧SPEC/IMPL/WORK/REPORTは履歴として保持し、上書きしない。

---

## 2. 今回の目的

compact_v3 architectureをN_MAX連動可能にし、

```text
WIDTH = 5, 6, 7, 8, 9
```

について、

```text
Shrike-Liteで配置可能な最大N_MAX
```

を探索する。

主成果は、

```text
WIDTH / MOD / max PLACE_FIT N_MAX
```

の境界表である。

可能ならmax PNR_COMPLETE N_MAXとtimingも併記する。

---

## 3. 保護対象

開始時に個別SHA-256またはtree manifestを取得する。

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

S1S2_30BIT_BASELINE
```

を保護する。

新規実装・探索成果物は、

```text
boundary_v4/
```

以下だけに作成する。

---

## 4. Stage 0: parameterized boundary RTL

compact_v3 finalを基準に、新規 `boundary_v4/` RTLを作る。

追加・変更する主目的は、

```text
COUNT_WIDTH = max(1, ceil(log2(N_MAX+1)))
```

を導入し、N/K/counter類をN_MAXへ連動させること。

architectureはIMPL_4から逸脱しない。

候補ごとの手調整は禁止。

---

## 5. Stage 1: W8再現

最初に、

```text
WIDTH=8
MOD=251
N_MAX=250
VALUE_BYTES=1
```

を検証する。

### Icarus

旧compact_v3と同等の正しさを確認する。

最低限:

```text
39/39相当
random brute force
N=N_MAX
N=N_MAX+1 error
```

### Post-Synthesis

旧値:

```text
557 LUT / 163 FF / 31 CARRY4
```

との一致または差を確認する。

### PNR

必要なら既存automationを1回再実行し、

```text
165/140 Type=L
MinPlacer fail
```

と同等の結果が得られることを確認する。

大きく異なる場合は境界探索へ進まず原因を調べる。

---

## 6. WIDTH別設定

探索対象:

| WIDTH | MOD | N_MAX最大 | VALUE_BYTES |
|---:|---:|---:|---:|
| 5 | 31 | 30 | 1 |
| 6 | 61 | 60 | 1 |
| 7 | 127 | 126 | 1 |
| 8 | 251 | 250 | 1 |
| 9 | 509 | 508 | 2 |

---

## 7. 候補ごとの検証

各候補 `(WIDTH,N_MAX)` で最低限次を実行する。

### Icarus

```text
代表valid case
N=N_MAX
N=N_MAX+1 error
K=1
K=N
Ai=0
Ai=MOD-1
Ai=MOD error
sticky ERROR
STATUS / answer framing
payload FD/FE/FF semantics
random brute force
```

既に同WIDTH・同RTLで十分な回帰があり、
N_MAXだけが変わる連続候補では、
時間節約のためshort regressionを許可する。

境界確定候補ではfull regressionを再実行する。

### Post-Synthesis

全PNR候補で必須。

resource summaryを保存する。

### PNR

screeningを通過した候補で実行する。

---

## 8. safe screening

次の場合はPNRを省略してよい。

```text
ceil(LUT/4) > 140
```

これはType=L 140へfitする必要条件を満たさない。

それ以外は、

```text
「入る」と推定せず
```

必要に応じて実PNRする。

W8の557 LUTが165 Type=Lを要求した実績を、
候補除外の独自係数として使用してはならない。

---

## 9. 探索手順

各WIDTHで、最大N_MAXから探索する。

### 9.1 最大点

最初に:

```text
N_MAX = MOD-1
```

を評価する。

PLACE_FITなら、そのWIDTHの最大N境界は即確定。

### 9.2 count-width tier probe

最大点が失敗した場合、

```text
COUNT_WIDTH = ceil(log2(N_MAX+1))
```

が1bit小さくなる代表点を降順に試す。

代表点:

```text
2^b - 1
```

ただし `MOD-1` 以下へclipする。

例 W8:

```text
250
127
63
31
15
7
3
1
```

これでfitし始めるtierを特定する。

### 9.3 最大Nの確定探索

「上側でfail、下側でfit」が見つかったら、
その間について最大PLACE_FIT N_MAXを探索する。

mappingが非単調な可能性があるため、
二分探索だけで最大を断定しない。

推奨:

```text
1. Post-Synthesisを安価なscreeningとして使う
2. 上側から降順に候補を調べる
3. SCREEN_FAILはPNRを省略
4. screenを通った候補はPNR
5. 上から連続して確認し、最初のPLACE_FITを最大値として確定
```

上から全候補を確認したことが最大値確定の根拠になる。

---

## 10. 実行時間budget

探索が長時間化する場合、

```text
約60分
```

をsoft budgetとする。

budget到達時は無理に完走せず、

```text
largest confirmed PLACE_FIT
smallest confirmed higher FAIL
unresolved interval
```

をREPORTする。

exact maximumが未確定なら、
「最大」と断定しない。

ただしscreeningにより上側候補が全て数学的に除外できた場合は、
その範囲はconfirmed FAILとしてよい。

---

## 11. PNR automation

REPORT_abc471e_narrow_4で確立した通常ForgeFPGA GUI flowを再利用する。

各runで:

```text
専用copy project
bitstream output disabled
対象PIDだけ操作
Forge log保存
automation result保存
PNR summary保存
```

を行う。

既存ユーザーGUI processへ触れない。

PNR GUI識別子や実行方法の再探索は、
既存automationが動かない場合だけ行う。

---

## 12. fit判定

primary:

```text
PLACE_FIT
```

条件:

```text
MinPlacer success
Type=L <= 140
placement成立
```

secondary:

```text
PNR_COMPLETE
```

routerまで正常完了し、
post-route timingが得られたもの。

PLACE_FITとPNR_COMPLETEの最大Nが異なる場合は両方報告する。

---

## 13. timingの扱い

50 MHz SDCは変更しない。

ただし今回のN境界は容量境界であり、
50 MHz closureを成功条件にしない。

候補ごとに存在するstageだけ記録する。

```text
post-LUT-packing estimate
post-placement timing
post-route timing
WNS/TNS
achievable frequency
```

未配置の推定値をfinal timingと書かない。

---

## 14. 結果表

最低限次を作る。

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
LUT lower bound
Type=L used
placement result
route result
timing stage
achievable frequency
```

最終summary:

```text
WIDTH | MOD | max PLACE_FIT N_MAX | max PNR_COMPLETE N_MAX | Type=L | timing
```

---

## 15. 境界周辺の保存

各WIDTHで、

```text
最大fit候補
その直上のfail候補
```

は必ず完全な成果物を保存する。

最低限:

```text
config
RTL hash
Icarus log
synth script/log
post-synth report/netlist/EDIF
PNR project
Forge log
pnr_summary.json
automation_result.json
```

---

## 16. 追加optimization禁止

今回は境界探索であり、
候補をfitさせるための個別optimizationをしない。

禁止:

```text
候補固有RTL修正
state encoding調整
scratch再配置
特定WIDTH専用shortcut
特定N_MAX専用shortcut
新algorithm
timing optimization
PNR option tuningによるfit探索
```

同じtool設定・同じarchitectureで比較する。

---

## 17. REPORT

主成果物:

```text
REPORT_abc471e_narrow_5.md
```

最低限:

```text
1. Executive Summary
2. 探索条件
3. boundary_v4実装
4. W8再現確認
5. 探索方法
6. WIDTH別探索結果
7. max PLACE_FIT境界
8. max PNR_COMPLETE境界
9. Post-Synthesisと実Type=Lの関係
10. timing結果
11. 未確定区間
12. 再現手順
13. 保護対象確認
14. 停止点
```

---

## 18. 停止条件

次を完了したら停止する。

```text
boundary_v4作成
W8 baseline再現確認
W5..W9探索
各WIDTHの最大PLACE_FITを確定
またはsoft budget内のconfirmed boundを取得
REPORT_abc471e_narrow_5.md
保護対象再照合
```

行わない:

```text
bitstream生成
flash
実機試験
新architecture最適化
```
