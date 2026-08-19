# ABC471E Narrow - WORK_REQUEST

## 1. 今回の仕事

`abc471e_narrow` の通常アーキテクチャを実装し、
WIDTHを8bitから順に増やしたときの機能・性能・Post-Synthesis面積を連続測定する。

今回の目的は、

```text
30bit S1/S2版
    ↓
同じ基本アーキテクチャを狭幅化
    ↓
WIDTHごとの面積スケーリングを測定
```

することである。

今回は「手段を問わず140 Type=Lへ詰める」最適化は行わない。

---

## 2. 作業開始時に読む文書

最初に次を読む。

```text
SPEC_abc471e_narrow.md
IMPL_abc471e_narrow.md
REFERENCE_MAP.md
```

さらに `REFERENCE_MAP.md` の論理参照から必要な範囲で、

```text
S1S2_30BIT_BASELINE
S1S2_30BIT_AREA_ANALYSIS
S1S2_30BIT_DIAGNOSTIC
FORGE_SYNTH_CLI_REFERENCE
```

を確認する。

物理パスは `REFERENCE_MAP.md` を正とする。

---

## 3. 保護対象

次はread-onlyとして扱う。

```text
SPEC_abc471e_narrow.md
IMPL_abc471e_narrow.md
REFERENCE_MAP.md

S1S2_30BIT_BASELINE
S1S2_30BIT_AREA_ANALYSIS
S1S2_30BIT_DIAGNOSTIC
```

参照元へ書き込まない。

作業開始時と終了時に主要保護対象のSHA-256またはtree digestを比較し、
結果をREPORTへ記録する。

---

## 4. 作成する基本構成

プロジェクトrootに、必要に応じて次を作成する。

```text
ffpga/
  src/
  timing-constraints/

sim/

tools/

experiments/
  w08/
  w09/
  w10/
  ...

REPORT_abc471e_narrow.md
```

`reference/` 以下へ過去プロジェクトを再帰コピーしない。

参照は `REFERENCE_MAP.md` を使用する。

---

## 5. 実装前設計確認

まず30bit S1/S2版を確認し、
`IMPL_abc471e_narrow.md` を満たすparameterized narrow実装の具体設計を決める。

既に `IMPL` が内部方針を定義しているため、
今回は新しいIMPL文書を勝手に作り直さない。

必要な具体化は、RTLコメントまたはREPORTのImplementation節へ記録してよい。

ただし `IMPL` と矛盾する必要が生じた場合は実装せず停止し、
矛盾点を報告する。

---

## 6. WIDTH / MOD / N_MAX の決め方

今回のWIDTH sweepでは、各WIDTH `W` について、

```text
MOD =
    2^W 未満の最大の素数

N_MAX =
    MOD - 1
```

とする。

したがって最初の例は、

```text
W=8
MOD=251
N_MAX=250
```

となる。

各Wについて、使用するMODが本当に素数であることを
小さな補助スクリプト等で確認し、REPORTへ値を記録する。

MOD値を面積結果に合わせて恣意的に選ばない。

---

## 7. sweep範囲

最低限、

```text
WIDTH = 8
WIDTH = 9
WIDTH = 10
```

は必ず実施する。

その後、

```text
11
12
13
...
```

と1bitずつ増やし、今回の上限は16bitとする。

したがって原則として、

```text
WIDTH = 8..16
```

を同一アーキテクチャ・同一tool flowで測定する。

途中のWIDTHがPost-Synthesis上明らかに大きくても、
16bitまでは測定可能なら継続する。

合成toolの異常、極端な実行時間、設計上の不整合等で継続不能な場合は、
理由をREPORTしてその時点で停止してよい。

---

## 8. WIDTHごとの設定管理

WIDTHごとにRTLを手コピーして別設計へしない。

1つのparameterized implementationを基礎とし、
各実験点で、

```text
WIDTH
MOD
N_MAX
```

だけを明示的に切り替える。

各 `experiments/wXX/` には少なくとも、

```text
使用したWIDTH/MOD/N_MAX
Icarus結果
Post-Synthesis report
Post-Synthesis netlist
合成logまたは再現に必要な情報
抽出したresource summary
```

を追跡可能な形で残す。

---

## 9. Icarus検証

各WIDTHについて、Post-Synthesis前にIcarusで機能確認する。

最低限:

```text
RESET / RESET_ACK
START / START_ACK

N=1,K=1
K=1
K=N

A=[1,2,3] 等の手計算例

Ai=0
Ai=MOD-1

不正:
N=0
N>N_MAX
K=0
K>N
Ai=MOD

ERROR sticky
STATUS polling
4-byte answer
```

さらに小さいNでランダムケースを実行し、
Python等による独立全組合せ列挙と比較する。

目安として各WIDTHで少なくとも20ランダム有効ケースを行う。

実装の式をそのままPythonへ転記しただけの期待値計算を使わない。

---

## 10. reserved payload byteテスト

WIDTHに応じて有効値として表現可能な場合、

```text
0xFD
0xFE
0xFF
```

をAiのpayload byte中に含むケースを確認する。

例えばWIDTH=8 / MOD=251では `253..255` は有効Aiではないため、
無理に有効ケースへ入れない。

WIDTH>=9等でMODが255を超える場合は、
これらを含む有効Aiを使ってpayload中予約値がコマンド扱いされないことを確認する。

---

## 11. 性能測定

各WIDTHで最低限次を記録する。

```text
MUL_CLOCKS
AI_MIN_CLOCKS
AI_MAX_CLOCKS
```

shared multiplierが `WIDTH` に応じて想定どおり縮んでいるか確認する。

性能改善のためにアーキテクチャを変更しない。

---

## 12. CLI Post-Synthesis

各WIDTHのIcarus PASS後、

```text
FORGE_SYNTH_CLI_REFERENCE
```

と同じForgeFPGA bundled Yosys環境・主要optionでPost-Synthesisする。

既存30bit版でCLI再現性が確認済みであるため、
その確認済みflowを利用する。

別Yosysへ勝手に切り替えない。

---

## 13. 各WIDTHで取得する合成値

最低限次を抽出する。

```text
wires
wire bits
cells

CARRY4
FDCE
FDPE
FF total
INV

LUT2
LUT3
LUT4
LUT5
LUT6
LUT total

MUXF7
MUXF8
```

さらに比較用指標として、

```text
LUT + MUXF7 + MUXF8
```

も記録する。

ただしこれは物理CLB面積そのものとは呼ばない。

---

## 14. Post-Synthesis screening

各WIDTHについて参考値として、

```text
LUT-only rough lower bound =
    ceil(LUT total / 4)

raw FF lower bound =
    ceil(FF total / 8)
```

を計算する。

これらはPNR Type=Lを正確に予測する式ではない。

特に、

```text
MUXF packing
dual LUT packing
FF pair slot
carry chain
routing locality
control set
```

を含まないため、
REPORTでは「Post-Synthesis screening値」と呼ぶ。

---

## 15. PNR候補判定

今回のWORKではPNRを実行しない。

ただし各WIDTHを、

```text
PNR候補
PNR価値低
境界域
```

のように分類してよい。

判断はPost-Synthesis値から行い、
「fitした」と断定しない。

少なくとも、

```text
LUT-only rough lower bound <= 140
かつ
raw FF lower bound <= 140
```

ならPNR候補として残す価値がある。

140を少し超えるだけのケースは、
mapping/packing差を考慮して「境界域」とする。

大幅に超えるケースは「PNR価値低」としてよい。

分類根拠をREPORTへ数値で記載する。

---

## 16. 30bit基準との比較

最終REPORTでは、`S1S2_30BIT_BASELINE` のPost-Synthesis値も比較表へ載せる。

最低限:

```text
WIDTH=30 baseline
WIDTH=8
WIDTH=9
...
WIDTH=16
```

について、

```text
MOD
N_MAX
LUT
FF
CARRY4
MUXF7
MUXF8
MUL_CLOCKS
AI clocks
screening lower bound
PNR候補判定
```

を比較する。

30bit baselineはMOD/N_MAX条件がnarrow sweepとは異なるため、
完全に同じ問題世界ではないことを明記する。

---

## 17. 見たい結果

REPORTでは最低限、次へ回答する。

1. 8bit版はどこまで小さくなったか。
2. 10bit版はPost-Synthesis上PNR候補になるか。
3. WIDTH増加に対してLUT/FF/CARRY4はどう増えるか。
4. 面積増加は概ね線形か、mappingで大きく跳ねる幅があるか。
5. multiplierのclock数はWIDTHにどう比例するか。
6. 140 Type=Lへ入りそうな最大WIDTHはどこか。
7. 最初に「PNR価値低」と判断されるWIDTHはどこか。
8. その境界の次に、狭小住宅型の強制面積最適化を試す価値があるか。

---

## 18. 成果ドキュメント

成果ドキュメントは必ず `REPORT_` prefixを使用する。

今回の主成果物:

```text
REPORT_abc471e_narrow.md
```

最低限次を含める。

```text
1. Executive Summary
2. 実験条件
3. parameterized implementation概要
4. WIDTH/MOD/N_MAX一覧
5. Icarus結果
6. 性能測定
7. Post-Synthesis比較表
8. resource scaling
9. Post-Synthesis screening
10. PNR候補判定
11. 30bit baselineとの比較
12. 次に試すWIDTH/最適化案
13. 未実施事項
14. 保護対象未変更確認
15. 停止点
```

必要な補助レポートを追加する場合も、

```text
REPORT_<purpose>.md
```

とする。

---

## 19. 禁止事項

今回のWORKでは次を行わない。

```text
SPEC変更
IMPL変更
REFERENCE_MAP変更
30bit参照元変更

PNR
placer
bitstream生成
実機flash
実機試験

手段を問わない面積最適化
bit-serial化
microcode化
scratch register全面再設計
係数アルゴリズム変更
SPI protocol変更

WIDTHごとの別アーキテクチャ化
結果の良いWIDTHだけ特別扱い
```

面積不足が見えても、
今回のsweep中に勝手に「もっと入る設計」へ変更しない。

---

## 20. 次段階との境界

今回のWIDTH sweepで限界候補が見つかった後、
例えば、

```text
WIDTH=10 は余裕
WIDTH=11 は境界
WIDTH=12 は明確に大きい
```

等となった場合でも、
今回はそこでアーキテクチャ最適化へ進まない。

次段階は別の `WORK_REQUEST` とする。

例:

```text
WORK_REQUEST_abc471e_narrow_fit_w11.md
```

そこでは必要に応じて、
IMPL更新または派生IMPL作成を先に行ったうえで、

```text
外部SPECを守る限り
手段を問わず140 Type=Lへ詰める
```

等の別実験を行う。

---

## 21. 停止条件

次を完了したら停止する。

```text
parameterized narrow RTL作成

WIDTH=8..16について、
可能な範囲で:
    Icarus PASS
    性能測定
    CLI Post-Synthesis
    resource抽出
    screening判定

30bit baselineとの比較

REPORT_abc471e_narrow.md作成

保護対象未変更確認
```

PNR、bitstream、実機、強制面積最適化には進まない。
