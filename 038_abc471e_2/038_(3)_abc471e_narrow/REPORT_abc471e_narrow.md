# ABC471E Narrow WIDTH Sweep Report

## 1. Executive Summary

`S1S2_30BIT_BASELINE` の数学構造、FSM構造、1個のshared modular multiplier、
1系統のtop modular add/sub、32bit SPI framingを維持し、主要datapathと内部counterを
compile-time parameter `WIDTH` へ縮小した。

WIDTH=8..16の全9点について、次を完了した。

- Icarus Verilogによる決定的ケース、不正入力、各幅24件のランダム全組合せ照合: 全PASS
- `MUL_CLOCKS`: 全幅で `2 * WIDTH`
- `AI_MIN_CLOCKS = AI_MAX_CLOCKS`: 全幅で `2 * WIDTH + 7`
- ForgeFPGA bundled Yosysによる同一条件Post-Synthesis: 全9点完了
- resource抽出、Post-Synthesis screening、30bit基準との比較

8bit版は30bit基準に対してLUTを2121から803へ62.1%、FFを948から308へ67.5%、
CARRY4を121から35へ71.1%削減した。ただしLUT-only rough lower boundは201であり、
Type=L capacity 140を61上回る。10bit版の同値は224である。

今回定義したscreeningではWIDTH=8..16の全点が「PNR価値低」となり、
PNR候補または境界域は現れなかった。「fitした」という判定はしておらず、要求どおり
PNRも実行していない。

## 2. 実験条件

### 2.1 参照とarchitecture

- 直接基準: `REFERENCE_MAP.md` の `S1S2_30BIT_BASELINE`
- 面積背景: `S1S2_30BIT_AREA_ANALYSIS`、`S1S2_30BIT_DIAGNOSTIC`
- 合成flow: `FORGE_SYNTH_CLI_REFERENCE`
- RTL: 全WIDTHで同一の `ffpga/src/main.v` と `ffpga/src/spi_target.v`
- WIDTH差分: `WIDTH`、`MOD`、`N_MAX` parameterだけ

### 2.2 tool

| tool | version / condition |
|---|---|
| Icarus Verilog | 12.0 (devel), `s20150603-1539-g2693dd32b` |
| ForgeFPGA bundled Yosys | 0.59+0, git `946048486` |
| synthesis | `flatten -noscopeinfo`; `synth_xilinx -nobram -noiopad -nodsp -abc9`; `clean`; `autoname` |

Post-Synthesis scriptは参照flowと同様にSDCを入力しない。各実験の実際のparameterは
`experiments/wXX/config.json`、`synth_script.ys`、`synth.log`に残した。
`synth.log`で各幅の `WIDTH/MOD/N_MAX` parameter適用も確認した。

## 3. parameterized implementation概要

次を1つのparameterized RTLとして実装した。

- `main` と `modular_multiplier` に `WIDTH` と `MOD`、`main` に `N_MAX` をparameter化
- `x`、S1/S2、係数、pow、term、answer、shared multiplier、shared add/subをWIDTH bit化
- 32bit SPI word assembly後に検証し、N/K/counter/combination indexをWIDTH bit化
- 有効Aiは受信時に `Ai < MOD` を検証後、WIDTH bitへ取り込み
- `Ai >= MOD` は正規化せずsticky protocol error
- answerは32bitへゼロ拡張してbig-endian返信
- multiplierはVerilog `*` を使わない2-phase shift-add構造を維持
- `spi_target.v` は30bit基準とSHA-256一致のまま使用

入力ストリームでは配列を保存せず、次だけを保持する。

```text
S1 = Σ Ai mod MOD
S2 = Σ Ai^2 mod MOD
```

最終計算もIMPLどおりである。

```text
pair_twice  = S1^2 - S2 mod MOD
answer      = C(N-1,K-1) * S2
            + C(N-2,K-2) * pair_twice mod MOD
```

WIDTH別special architecture、複数multiplier、係数アルゴリズム変更、SPI変更は行っていない。

## 4. WIDTH / MOD / N_MAX一覧

`tools/width_configs.py` がtrial divisionによる独立な素数判定を行い、
`2^WIDTH` 未満の最大素数を探索した。

| WIDTH | MOD | N_MAX | prime verified |
|---:|---:|---:|:---:|
| 8 | 251 | 250 | yes |
| 9 | 509 | 508 | yes |
| 10 | 1021 | 1020 | yes |
| 11 | 2039 | 2038 | yes |
| 12 | 4093 | 4092 | yes |
| 13 | 8191 | 8190 | yes |
| 14 | 16381 | 16380 | yes |
| 15 | 32749 | 32748 | yes |
| 16 | 65521 | 65520 | yes |

## 5. Icarus結果

| WIDTH | result | test count | random valid cases | reserved `FD/FE/FF` payload |
|---:|:---:|---:|---:|:---:|
| 8 | PASS | 36 | 24 | N/A (`MOD < 253`) |
| 9 | PASS | 37 | 24 | PASS |
| 10 | PASS | 37 | 24 | PASS |
| 11 | PASS | 37 | 24 | PASS |
| 12 | PASS | 37 | 24 | PASS |
| 13 | PASS | 37 | 24 | PASS |
| 14 | PASS | 37 | 24 | PASS |
| 15 | PASS | 37 | 24 | PASS |
| 16 | PASS | 37 | 24 | PASS |

各幅で次を確認した。

- RESET/RESET_ACK、START/START_ACK、STATUS polling、4-byte answer
- `N=1,K=1`、`K=1`、`K=N`、`A=[1,2,3]`
- S1/S2の逐次更新、`pair_twice`、subtraction borrowと`+MOD` correction
- `Ai=0`、`Ai=MOD-1`
- `N=0`、`N>N_MAX`、`K=0`、`K>N`、`Ai=MOD`
- ERRORがRESETまでsticky
- 前Ai busy時のword完成、N個後の余分なpayload
- WIDTH>=9で有効Ai `253,254,255` をpayloadとして送り、予約byteがcommand化されないこと

ランダム期待値はRTLの係数式を模倣せず、問題定義から全bitmaskを列挙し、
選択数Kの部分集合について和の2乗を加算して求めた。

## 6. 性能測定

| WIDTH | MUL_CLOCKS | AI_MIN_CLOCKS | AI_MAX_CLOCKS |
|---:|---:|---:|---:|
| 8 | 16 | 23 | 23 |
| 9 | 18 | 25 | 25 |
| 10 | 20 | 27 | 27 |
| 11 | 22 | 29 | 29 |
| 12 | 24 | 31 | 31 |
| 13 | 26 | 33 | 33 |
| 14 | 28 | 35 | 35 |
| 15 | 30 | 37 | 37 |
| 16 | 32 | 39 | 39 |

shared multiplierは各bitをadd phaseとdouble phaseの2 clockで処理し、全幅で
`MUL_CLOCKS = 2 * WIDTH` となった。Ai処理は受理、multiplier開始/完了、S2/S1更新を含み、
今回の測定定義では `2 * WIDTH + 7` clockである。入力値によるmin/max差はなかった。

## 7. Post-Synthesis比較表

### 7.1 全resource

| W | wires | bits | cells | CARRY4 | FDCE | FDPE | FF | INV | LUT2 | LUT3 | LUT4 | LUT5 | LUT6 | LUT | M7 | M8 | LUT+M7+M8 |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 8 | 1076 | 2591 | 1171 | 35 | 300 | 8 | 308 | 25 | 202 | 103 | 170 | 191 | 137 | 803 | 0 | 0 | 803 |
| 9 | 1202 | 2873 | 1258 | 44 | 328 | 8 | 336 | 27 | 215 | 73 | 190 | 221 | 152 | 851 | 0 | 0 | 851 |
| 10 | 1267 | 3005 | 1332 | 44 | 355 | 8 | 363 | 31 | 245 | 83 | 191 | 231 | 143 | 893 | 1 | 0 | 894 |
| 11 | 1328 | 3120 | 1421 | 44 | 382 | 8 | 390 | 31 | 254 | 93 | 223 | 206 | 180 | 956 | 0 | 0 | 956 |
| 12 | 1467 | 3517 | 1561 | 48 | 409 | 8 | 417 | 33 | 309 | 95 | 169 | 298 | 184 | 1055 | 8 | 0 | 1063 |
| 13 | 1577 | 3667 | 1610 | 60 | 436 | 8 | 444 | 35 | 267 | 99 | 192 | 279 | 221 | 1058 | 13 | 0 | 1071 |
| 14 | 1630 | 3765 | 1693 | 60 | 463 | 8 | 471 | 37 | 288 | 100 | 262 | 322 | 143 | 1115 | 9 | 1 | 1125 |
| 15 | 1714 | 4017 | 1798 | 60 | 490 | 8 | 498 | 41 | 315 | 101 | 237 | 336 | 203 | 1192 | 7 | 0 | 1199 |
| 16 | 1781 | 4056 | 1902 | 62 | 517 | 8 | 525 | 47 | 338 | 116 | 267 | 316 | 223 | 1260 | 8 | 0 | 1268 |

`LUT+M7+M8` は比較指標であり、物理CLB面積ではない。

### 7.2 WIDTH間差分

| transition | ΔLUT | ΔFF | ΔCARRY4 |
|---|---:|---:|---:|
| 8→9 | +48 | +28 | +9 |
| 9→10 | +42 | +27 | 0 |
| 10→11 | +63 | +27 | 0 |
| 11→12 | +99 | +27 | +4 |
| 12→13 | +3 | +27 | +12 |
| 13→14 | +57 | +27 | 0 |
| 14→15 | +77 | +27 | 0 |
| 15→16 | +68 | +27 | +2 |

## 8. resource scaling

WIDTH=8から16の端点平均では、1bitあたりLUTは約57.1、FFは約27.1、CARRY4は
約3.4増加した。

- FFは8→9の+28を除き、各bitで正確に+27であり、ほぼ線形。
- LUTは全体傾向として増加するが、増分は+3から+99まで変動。
- 最大のLUT jumpは11→12の+99。その次の12→13は+3でほぼplateau。
- CARRY4は線形ではなく、9、12、13、16bitで段階的に増加。
- MUXF7/F8も10bit以降に出現し、mapping結果は幅に対して単純比例しない。

従って「datapath幅に伴う概ね増加する基調」はあるが、LUT/CARRY mappingは明確に
非線形な段差を含む。

## 9. Post-Synthesis screening

| WIDTH | LUT | FF | ceil(LUT/4) | ceil(FF/8) |
|---:|---:|---:|---:|---:|
| 8 | 803 | 308 | 201 | 39 |
| 9 | 851 | 336 | 213 | 42 |
| 10 | 893 | 363 | 224 | 46 |
| 11 | 956 | 390 | 239 | 49 |
| 12 | 1055 | 417 | 264 | 53 |
| 13 | 1058 | 444 | 265 | 56 |
| 14 | 1115 | 471 | 279 | 59 |
| 15 | 1192 | 498 | 298 | 63 |
| 16 | 1260 | 525 | 315 | 66 |

これらはMUXF packing、dual LUT packing、FF pair slot、carry chain、routing locality、
control setを含まないPost-Synthesis screening値であり、PNR Type=L utilizationの予測値ではない。

## 10. PNR候補判定

機械集計では次の基準を使用した。

```text
PNR候補 : LUT lower bound <= 140 かつ FF lower bound <= 140
境界域  : 上記を外れるが、大きい方のlower boundが154以下（capacityの+10%以内）
PNR価値低: それ以外
```

| WIDTH | classification | numeric reason |
|---:|---|---|
| 8 | PNR価値低 | LUT lower bound 201 > 154 |
| 9 | PNR価値低 | LUT lower bound 213 > 154 |
| 10 | PNR価値低 | LUT lower bound 224 > 154 |
| 11 | PNR価値低 | LUT lower bound 239 > 154 |
| 12 | PNR価値低 | LUT lower bound 264 > 154 |
| 13 | PNR価値低 | LUT lower bound 265 > 154 |
| 14 | PNR価値低 | LUT lower bound 279 > 154 |
| 15 | PNR価値低 | LUT lower bound 298 > 154 |
| 16 | PNR価値低 | LUT lower bound 315 > 154 |

FF側は全幅で140以下だが、LUT側が支配的である。最小の8bitでも201であり、今回の
範囲に「140 Type=Lへ入りそうな最大WIDTH」はない。最初にPNR価値低となる幅も8bitである。

## 11. 30bit baselineとの比較

| WIDTH | MOD | N_MAX | LUT | FF | CARRY4 | M7 | M8 | MUL clocks | AI clocks | LUT LB | FF LB | 判定 |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 30 baseline | 998244353 | 200000 | 2121 | 948 | 121 | 10 | 0 | 60 | 67..71 | 531 | 119 | PNR価値低 |
| 8 | 251 | 250 | 803 | 308 | 35 | 0 | 0 | 16 | 23 | 201 | 39 | PNR価値低 |
| 9 | 509 | 508 | 851 | 336 | 44 | 0 | 0 | 18 | 25 | 213 | 42 | PNR価値低 |
| 10 | 1021 | 1020 | 893 | 363 | 44 | 1 | 0 | 20 | 27 | 224 | 46 | PNR価値低 |
| 11 | 2039 | 2038 | 956 | 390 | 44 | 0 | 0 | 22 | 29 | 239 | 49 | PNR価値低 |
| 12 | 4093 | 4092 | 1055 | 417 | 48 | 8 | 0 | 24 | 31 | 264 | 53 | PNR価値低 |
| 13 | 8191 | 8190 | 1058 | 444 | 60 | 13 | 0 | 26 | 33 | 265 | 56 | PNR価値低 |
| 14 | 16381 | 16380 | 1115 | 471 | 60 | 9 | 1 | 28 | 35 | 279 | 59 | PNR価値低 |
| 15 | 32749 | 32748 | 1192 | 498 | 60 | 7 | 0 | 30 | 37 | 298 | 63 | PNR価値低 |
| 16 | 65521 | 65520 | 1260 | 525 | 62 | 8 | 0 | 32 | 39 | 315 | 66 | PNR価値低 |

8bit版は30bit基準に対し、LUT -1318（-62.1%）、FF -640（-67.5%）、
CARRY4 -86（-71.1%）である。`LUT+MUXF7+MUXF8` は2131から803へ-62.3%となった。

ただし30bit基準は `MOD=998244353, N_MAX=200000`、narrow sweepは各幅で
`N_MAX=MOD-1` である。内部architecture比較の基準ではあるが、完全に同じ問題世界ではない。

## 12. 質問への回答と次に試すWIDTH/最適化案

1. **8bit版はどこまで小さくなったか。** 30bit比でLUT 62.1%、FF 67.5%、CARRY4 71.1%削減。ただしLUT lower boundは201。
2. **10bit版はPNR候補か。** いいえ。LUT lower bound 224、FF lower bound 46でLUT側が大きい。
3. **WIDTH増加時の傾向。** FFは約+27/bitでほぼ線形。LUTは平均+57.1/bit、CARRY4は段階増加。
4. **面積増加は線形か。** 大勢は増加するが、11→12のLUT +99、12→13の+3などmapping jumpがある。
5. **multiplier clocks。** 正確に `2 * WIDTH`。
6. **140 Type=Lへ入りそうな最大WIDTH。** 今回の8..16には存在しない。
7. **最初のPNR価値低。** WIDTH=8。
8. **強制面積最適化の価値。** 自然な境界点は得られなかった。8bitでもLUTを803から少なくとも560以下へ243（30.3%）削らないとLUT screening条件へ届かず、さらに物理packing余裕が必要である。小修正ではなく別WORK_REQUESTでのarchitecture最適化課題となる。

次段階を作るなら、まず同一architectureのWIDTH=7以下を別sweepとして測り、幅だけで境界が
存在するか確認するのが比較上明快である。外部問題世界を8bit以上に保つ必要がある場合は、
`WORK_REQUEST_abc471e_narrow_fit_w08.md` のような別実験でIMPL変更範囲を先に定義し、
bit-serial化、microcode化、scratch共有、係数計算再設計等を個別評価する必要がある。

## 13. 未実施事項

- PNR、placer、timing analysis、bitstream生成
- 実機flash、実機試験
- WIDTH=7以下
- 強制面積最適化、別architecture、自動探索
- Post-Synthesis netlistの形式等価検証

## 14. 保護対象未変更確認

開始時と終了時のSHA-256またはtree digestを比較した。

| protected item | start | end | result |
|---|---|---|---|
| `SPEC_abc471e_narrow.md` | `d3acc9ce369c2ae66cc5654710b479b321c30da1dd00591daa662a45ebf1469a` | same | MATCH |
| `IMPL_abc471e_narrow.md` | `226e8f1a22a1cef0c1db432f86261e56cf1bb1cf0d6f0220ae6501a5837d55ee` | same | MATCH |
| `REFERENCE_MAP.md` | `b3f1a177ab67d6f55ece551a74598377d42f7f1aa95883ce5552f7022ceaec12` | same | MATCH |
| `S1S2_30BIT_BASELINE` tree, 128 files | `b1b072a689ef32189755adb6bd696c3941da7dbbb5fd41c435c3b6be3b17ebcf` | same | MATCH |

baseline treeは相対pathと各file SHA-256を昇順連結し、そのmanifestをSHA-256化した。
開始・終了manifestも全128行一致した。参照元へ書き込みは行っていない。

## 15. 停止点

要求されたparameterized RTL、WIDTH=8..16のIcarus、性能測定、CLI Post-Synthesis、
resource抽出、screening、30bit比較、REPORT、保護対象確認を完了した。

PNR、bitstream、実機、強制面積最適化には進まず、ここで停止する。

再現コマンド:

```powershell
python tools/width_configs.py
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\run_sweep.ps1
```
