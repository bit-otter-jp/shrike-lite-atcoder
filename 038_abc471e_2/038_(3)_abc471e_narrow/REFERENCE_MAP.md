# ABC471E Narrow - Reference Map

## 1. Purpose

このファイルは、`abc471e_narrow` から参照する既存プロジェクト／資料の
**論理名と実体パスの対応だけ**を管理する。

`SPEC`、`IMPL_REQUEST`、`IMPL`、`REPORT` では、
可能な限り物理パスを直接書かず、ここで定義した論理名を使用する。

目的は次のとおり。

- 過去プロジェクト一式を `reference/` 以下へ再帰コピーしない。
- ローカル開発環境とGitHub公開環境で参照先が変わっても、
  原則としてこのファイルだけを変更すればよい構成にする。
- 既存の30bit S1/S2実装を凍結した比較基準として扱う。
- `abc471e_narrow` 側から参照元を変更しない。

---

## 2. Reference Rules

1. 参照元は **read-only** として扱う。
2. 参照元のRTL、testbench、build成果物、文書を変更しない。
3. 参照元を `abc471e_narrow/reference/` へ再帰コピーしない。
4. 必要な情報は論理名から参照する。
5. 新しい参照が必要になった場合は、このファイルへ論理名を追加する。
6. 物理パス変更時は、原則としてこのファイルだけを更新する。
7. `SPEC` や `IMPL` に過去プロジェクトの深い相対パスを直接埋め込まない。

---

## 3. Active Reference Map

### `S1S2_30BIT_BASELINE`

**用途:**  
ABC471Eの30bit S1/S2実装。`abc471e_narrow` の直接比較基準。

**Local path:**

```text
../abc471e_s1s2
```

**主な参照対象:**

```text
SPEC_abc471e_s1s2.md
IMPL_REQUEST_abc471e_s1s2.md
IMPL_abc471e_s1s2.md
IMPLEMENTATION_REPORT_abc471e_s1s2.md

ffpga/src/main.v
ffpga/src/spi_target.v
sim/abc471e_s1s2_tb.v

ffpga/build/synth_script.ys
ffpga/build/post_synth_report.txt
ffpga/build/post_synth_results.v
ffpga/build/netlist.edif
```

**扱い:**

```text
READ ONLY
```

---

### `S1S2_30BIT_AREA_ANALYSIS`

**用途:**  
30bit S1/S2版がShrike-Liteへ入らない原因を調査した面積解析。

**Physical path:**

```text
../abc471e_s1s2/AREA_ANALYSIS_abc471e_s1s2.md
```

**主な基準値:**

```text
Post-Synthesis:
LUT total = 2121
FF        = 948
CARRY4    = 121

PNR:
Type=L Utilized = 561 / 140
CLB LUT site    = 2114
LUT-site theoretical minimum = 529 CLB
```

この資料は、`abc471e_narrow` でbit幅縮小を行う理由の根拠として使用する。

---

### `S1S2_30BIT_DIAGNOSTIC`

**用途:**  
Fermat/pow、およびcombination計算を固定して差分合成した面積診断。

**Physical path:**

```text
../abc471e_s1s2/DIAGNOSTIC_AREA_REPORT_abc471e_s1s2.md
```

**主な比較値:**

```text
                    LUT    FF   CARRY4
original           2121   948    121
pow_fixed          1845   881    119
coeff+pow_fixed    1223   625     73
```

**主な意味:**

- combination + pow は大きな面積要因。
- しかし、それらを固定してもLUT 1223が残る。
- 局所最適化だけでは140 Type=Lへ届かない。
- 30bit datapath全体を狭幅化する実験へ進む根拠となる。

---

### `FORGE_SYNTH_CLI_REFERENCE`

**用途:**  
ForgeFPGA Workshopと同一条件でPost-SynthesisをCLI実行するための基準。

**Source project:**

```text
S1S2_30BIT_BASELINE
```

**Yosys executable used by the verified environment:**

```text
C:\Program Files\Renesas Electronics\Go Configure Software Hub\external\yosys\v59\yosys.exe
```

**Reference synthesis script:**

```text
../abc471e_s1s2/ffpga/build/synth_script.ys
```

**確認済み条件:**

```text
ForgeFPGA bundled Yosys 0.59+0
flatten = true
noDSP   = true
ABC9    = enabled
autoname = true
```

正規30bit版について、
CLI再合成した以下3成果物が既存ForgeFPGA成果物とSHA-256完全一致している。

```text
post_synth_report.txt
post_synth_results.v
netlist.edif
```

`abc471e_narrow` の面積比較では、この再現済みflowを基準とする。

---

## 4. Logical Reference Usage

他文書では、例えば次のように記述する。

```text
比較基準は REFERENCE_MAP.md の S1S2_30BIT_BASELINE とする。
面積縮小の判断根拠は S1S2_30BIT_AREA_ANALYSIS および
S1S2_30BIT_DIAGNOSTIC を参照する。
Post-Synthesisは FORGE_SYNTH_CLI_REFERENCE と同一条件で行う。
```

次のような深い物理パスの直接記述は避ける。

```text
../abc471e_s1s2/reference/abc471e_baseline_v2/...
```

---

## 5. GitHub / Release Packaging

GitHub公開時にローカルの隣接プロジェクトを参照できない場合でも、
`SPEC`、`IMPL`、`REPORT` 側の論理名は変更しない。

必要に応じて公開用資料を例えば、

```text
reference/
├─ s1s2_30bit/
├─ AREA_ANALYSIS_abc471e_s1s2.md
└─ DIAGNOSTIC_AREA_REPORT_abc471e_s1s2.md
```

のように配置し、**この `REFERENCE_MAP.md` のPhysical pathだけを公開用に更新する。**

公開時に何を同梱するかは、後で決定する。
現時点では参照元のコピーを作成しない。

---

## 6. Current Project Boundary

`abc471e_narrow` は、30bit S1/S2版を改変するプロジェクトではない。

このプロジェクトでは別実験として、

```text
30bit modular datapath
        ↓
narrow modular datapath
```

を構築し、Shrike-Liteへ収まるbit幅を探索する。

最初の候補は8bit縮小模型とするが、
プロジェクト名は特定bit幅へ固定しない。

幅別の実験結果は `abc471e_narrow` 側で管理し、
30bit基準側へ書き戻さない。
