# ABC471E Narrow WIDTH=8 構造診断レポート

## 1. Executive Summary

WIDTH=8、MOD=251、N_MAX=250 の既存実装 803 LUT を、指定された3つの診断設計で段階的に分解した。結果は次のとおりである。

| 設計 | LUT | FF | CARRY4 | MUXF7 | MUXF8 | LUT+MUX | ceil(LUT/4) |
|---|---:|---:|---:|---:|---:|---:|---:|
| W08_BASELINE | 803 | 308 | 35 | 0 | 0 | 803 | 201 |
| coefficient_pow_fixed | 431 | 222 | 21 | 2 | 1 | 434 | 108 |
| input_only | 363 | 189 | 21 | 0 | 0 | 363 | 91 |
| protocol_only | 203 | 101 | 8 | 0 | 0 | 203 | 51 |

LUT の段階差分は、combination+pow aggregate 372、final aggregate 68、input arithmetic aggregate 160、protocol/framing/validation baseline 203 である。最大の削減源は combination/Fermat-pow と、それに付随する状態・operand 選択・next-state logic の集合である。

560 LUT 以下へは 243 LUT 以上の削減が必要である。combination+pow aggregate の372 LUTだけが単独でこの幅を上回る。もっとも、`coefficient_pow_fixed` は N=3、K=2 への機能制限を含む診断モデルであり、372 LUTをそのまま正規実装から削除できるという意味ではない。次の IMPL では、この機能を保持したまま combination/pow/control の構造を作り直すことが最優先になる。

shared multiplier 本体は、`src` 属性と接続追跡で 38 FF、6 CARRY4、38個の FF 直前 unique LUT、深さ2以内51 unique primitive と観測された。3つの算術系設計で同じ値であり、803 LUTの第一主因ではない。第4診断を追加しなくても主因を判定できたため、追加診断は実施していない。

## 2. 目的

本作業は最適化実装ではなく、WIDTH=8 の803 LUTがどの機能集合に費やされているかを、差分合成と post-synthesis netlist から測定し、次に変更すべき構造を決めるための診断である。

正とした文書は `SPEC_abc471e_narrow.md` と `IMPL_abc471e_narrow_2.md` である。旧 IMPL、旧 WORK_REQUEST、旧 REPORT は履歴として保持した。正規RTL、既存 simulation、tools、experiments、30bit参照元は変更していない。

## 3. W08 baseline

既存の `REPORT_abc471e_narrow.md` と `experiments/w08/` を照合した。config、Icarus log、synth script/log、post-synthesis report/netlist、EDIF、resource summary が存在し、次の基準値と一致した。

| 項目 | 値 |
|---|---:|
| wires / wire bits / cells | 1076 / 2591 / 1171 |
| CARRY4 | 35 |
| FDCE / FDPE / FF total | 300 / 8 / 308 |
| INV | 25 |
| LUT2 / LUT3 / LUT4 / LUT5 / LUT6 | 202 / 103 / 170 / 191 / 137 |
| LUT total | 803 |
| MUXF7 / MUXF8 | 0 / 0 |
| LUT+MUXF7+MUXF8 | 803 |
| ceil(LUT/4) / ceil(FF/8) | 201 / 39 |

既存 W08 Icarus は 36/36 PASS である。合成は ForgeFPGA bundled Yosys `0.59+0 (git 946048486)`、シミュレーションは Icarus Verilog `12.0 devel (s20150603-1539-g2693dd32b)` を用いている。

## 4. 診断設計一覧

診断用の source、testbench、build成果物はすべて `diagnostics/w08/` の下に作成した。

### coefficient_pow_fixed

N=3、K=2 のみを受理し、`coeff_square=2`、`coeff_pair=1` を定数として使う。SPI/protocol、32bit N/K/A framing、`Ai<MOD` validation、動的 S1/S2、shared multiplier、shared add/sub、`S1^2-S2`、2つの係数付き積、final add、STATUS/reply は残した。

combination registers/states、numerator/denominator、Fermat pow registers/states、およびそれら専用の multiplier launch/operand decode はRTLから除去した。

### input_only

SPI/protocol、validation、counter、sticky error、動的 `x*x`、S1/S2 update、shared multiplier、shared add を残し、reply は `zero_extend(S1)` とした。combination、pow、S1のfinal square、`S1^2-S2`、係数付き積、final add はRTLから除去した。

### protocol_only

RESET/START、32bit word assembly、N/K/A receive、validation、input count、sticky error、reserved-byte payload semantics、STATUS/replyを残し、reply は `zero_extend(last_valid_A)` とした。S1/S2、multiplier、top add/sub、combination、pow、final calculation はRTLから除去した。

build script は除去対象識別子の静的 absence check も行う。診断モデルは正規SPECの代替実装ではなく、面積差分測定専用である。

## 5. Icarus 結果

各期待値は診断RTLを流用せず、testbench側で独立計算または固定期待値として確認した。

| 診断 | 結果 | 主な確認内容 | 観測した multiplier launch |
|---|---:|---|---:|
| coefficient_pow_fixed | 7/7 PASS | A=[1,2,3]→50、zero、MOD境界、別データ、Ai=MOD sticky、invalid N/K、extra payload | 30 |
| input_only | 6/6 PASS | 複数列の独立S1/S2、single、MOD境界、sticky error、invalid N/K、extra payload | 10 |
| protocol_only | 7/7 PASS | Ai=0/MOD-1、dynamic last A、Ai=MOD、invalid N/K、sticky、extra payload、FD/FE/FF payload semantics | 0 |

`coefficient_pow_fixed` では各 valid run が入力数 `n` 回に加え final 3回の積を起動すること、shared add/sub の S1/S2 と final subtraction/add states が実動することを確認した。`input_only` は各 valid input ごとに1回だけ `x*x` を起動する。`protocol_only` には multiplier launch 自体がない。

## 6. Post-Synthesis 比較

3設計とも Icarus PASS 後、既存 W08 と同じ次の flow で合成した。PNRは実施していない。

```text
flatten -noscopeinfo
synth_xilinx -nobram -noiopad -nodsp -abc9
clean
autoname
```

### 全資源

| 設計 | wires | bits | cells | CARRY4 | FDCE | FDPE | FF | INV | LUT2 | LUT3 | LUT4 | LUT5 | LUT6 | LUT | M7 | M8 | LUT+MUX | ceil(LUT/4) | ceil(FF/8) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline | 1076 | 2591 | 1171 | 35 | 300 | 8 | 308 | 25 | 202 | 103 | 170 | 191 | 137 | 803 | 0 | 0 | 803 | 201 | 39 |
| coefficient_pow_fixed | 664 | 1541 | 685 | 21 | 216 | 6 | 222 | 8 | 96 | 57 | 111 | 69 | 98 | 431 | 2 | 1 | 434 | 108 | 28 |
| input_only | 599 | 1360 | 581 | 21 | 183 | 6 | 189 | 8 | 100 | 56 | 76 | 71 | 60 | 363 | 0 | 0 | 363 | 91 | 24 |
| protocol_only | 303 | 789 | 316 | 8 | 96 | 5 | 101 | 4 | 65 | 37 | 40 | 32 | 29 | 203 | 0 | 0 | 203 | 51 | 13 |

`ceil(LUT/4)` と `ceil(FF/8)` は post-synthesis screening lower bound であり、物理 Type=L 使用数の予測値ではない。

## 7. aggregate 差分

| aggregate | 定義 | LUT | FF | CARRY4 | LUT+MUX | wires | bits | cells |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| coefficient+pow | baseline − coefficient_pow_fixed | 372 | 86 | 14 | 369 | 412 | 1050 | 486 |
| final | coefficient_pow_fixed − input_only | 68 | 33 | 0 | 71 | 65 | 181 | 104 |
| input arithmetic | input_only − protocol_only | 160 | 88 | 13 | 160 | 296 | 571 | 265 |
| protocol baseline | protocol_only | 203 | 101 | 8 | 203 | 303 | 789 | 316 |

LUT差分は803に対して順に46.3%、8.5%、19.9%、25.3%で、waterfallとして合計803になる。個別LUT種別の差分は成果物 `aggregate_differences.csv/json` に記録した。

ここでいう aggregate は独立block面積ではない。ABC9によるglobal remapping、constant propagation、state encoding、operand selectionの再構成を含む。実例として `coefficient_pow_fixed` だけは MUXF7=2、MUXF8=1になり、LUT差372に対してLUT+MUX差は369である。このため、差分をRTL blockの加算可能な固有面積とは扱わない。

## 8. multiplier 解析

post-synthesis netlist の `src` 属性と FF D入力からの接続を追跡した。

| 設計 | multiplier FF | CARRY4 | FF直前 unique driver | 深さ2以内 unique primitive | launch sites | unique LHS | unique RHS |
|---|---:|---:|---:|---:|---:|---:|---:|
| baseline | 38 | 6 | 38 | 51 | 11 | 9 | 9 |
| coefficient_pow_fixed | 38 | 6 | 38 | 51 | 4 | 4 | 4 |
| input_only | 38 | 6 | 38 | 51 | 1 | 1 | 1 |
| protocol_only | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

38個の直前driverはすべて LUT2..LUT6 である。baselineの内訳は LUT2=1、LUT3=3、LUT4=15、LUT5=3、LUT6=16、input_onlyでは 2/3/15/3/15 である。global mappingによる1個のLUT種差はあるが、driver数、38 FF、6 CARRY4、深さ2 cone 51は不変である。

直接確認できる8bit multiplier本体の規模は「38 FF、6 CARRY4、少なくともFF直前38 LUT、浅いcone 51 primitive」である。LUTはmapping libraryへ `src` が失われるため、本体全体の排他的LUT総数は断定しない。input arithmetic aggregate 160 LUTには multiplierだけでなく、S1/S2 registers、input controller、top add、関連MUX/next-stateのglobal remapが含まれる。

launch sourceが 9/9→4/4→1/1 と減る一方で本体の38 FF/6 CARRY4は不変である。したがって multiplier engineそのものより、baselineで多数の利用者を接続するoperand MUX、launch decode、result routing、next-stateが大きく膨らんでいるという推定が強い。

## 9. add/sub 解析

top shared modular add/sub に帰属する CARRY4 は、baseline、coefficient_pow_fixed、input_onlyのすべてで5個、protocol_onlyで0個である。各 CARRY4 入力の1-hop upstream unique LUT/MUXは 18、16、16、0個だった。

したがって8bit top add/sub本体は、おおむね5 CARRY4と十数個規模の入力側LUT/MUXを持つ。ただし CARRY4 の20bit相当の鎖には加算、MOD比較、条件付き減算が同居し、下流選択logicもglobal mappingされるため、LUT総数は排他的に切り出せない。

input arithmetic aggregateの13 CARRY4差は、直接帰属できた multiplier 6 + top add/sub 5 に加え、input counter/validation/control側に帰属する2 CARRY4と整合する。final aggregateはCARRY4差0であり、finalが同じ shared multiplier/add-subを再利用しつつ、主に追加register、state、operand/result selectionとして68 LUT/33 FFを増やしていることを示す。

## 10. next-state / MUX / control 解析

| 設計 | top FF直前 unique LUT/MUX driver | 全FF直前 unique combinational driver | top protocol/control帰属FF | 最大fanout* | MUXF7/F8 |
|---|---:|---:|---:|---:|---:|
| baseline | 217 | 289 | 225 | 188 | 0/0 |
| coefficient_pow_fixed | 121 | 204 | 128 | 112 | 2/1 |
| input_only | 104 | 178 | 104 | 70 | 0/0 |
| protocol_only | 62 | 90 | 62 | 52 | 0/0 |

\* clock、reset、raw SPI receive-data netを除いた primitive input use の最大値。technology-mapped net名から得た構造指標であり、それ自体をcontrol netと断定してはいない。

SPI targetに `src` 帰属した FF/CARRY4 は全設計で28/1と不変だった。protocol_onlyの残りは top protocol/control 62 FF、mapping-library-only 11 FFである。baselineでは multiplier 38 FF、SPI 28 FF、top protocol/control 225 FF、mapping-only 17 FFに分類された。

baselineから combination/pow を外すと、top FF直前 unique LUT/MUX driverは96減り、top protocol/control帰属FFは97減る。launch source数と最大fanout指標も大幅に減る。MUXF7/F8がbaselineで0でも、MUX機能がないわけではなく、operand/state selectionがLUTへ吸収されている。以上は combination/powの演算値保存だけでなく、広い next-state/operand/result MUX coneがaggregateを押し上げているという強い推定を支持する。

## 11. 803 LUT の構成に関する結論

指定された10項目への回答を、根拠の強さとともにまとめる。

1. **combination+powを外すと372 LUT減る。** 803→431。これは直接確認した合成差分である。
2. **final calculationをさらに外すと68 LUT減る。** 431→363。直接確認した差分である。
3. **input S1/S2 arithmeticを外すと160 LUT減る。** 363→203。直接確認した差分である。
4. **protocol/framing/validationだけで203 LUT残る。** 直接確認した `protocol_only` の値である。
5. **shared multiplierは38 FF、6 CARRY4、FF直前38 unique LUT、深さ2 cone 51 primitive規模である。** FF/CARRY/接続数は直接確認、排他的な本体LUT総数は不確定である。
6. **top shared add/subは5 CARRY4、入力1-hopで16～18 unique LUT/MUX規模である。** `src` と接続から直接確認した構造値で、排他的LUT総数ではない。
7. **803 LUTの主因は combination/pow機能と、そのcontrol/MUXである。** 372 LUTという最大aggregate、top FF driver 217→121、launch source 9→4、fanout指標188→112からの強い推定である。protocol固定費203 LUTも無視できないが最大要因ではない。multiplier本体単独も第一主因ではない。
8. **560 LUTへ243 LUT以上削る現実的な候補は combination/pow/control領域だけである。** 372 LUT aggregateのうち243 LUT相当、約65.3%を機能保持しつつ回収する必要がある。final 68やinput arithmetic 160を単独で全削除しても届かず、しかもそれらは必須機能である。
9. **局所修正だけで140 Type=Lへ詰める可能性は低く、architecture変更が必要である。** 560 LUTは `ceil(LUT/4)=140` の必要条件にすぎず、routing/packingを保証しない。243 LUT、現状の30.3%削減をlocal boolean cleanupだけに期待する根拠はない。
10. **次のIMPLでは combination/Fermat-powの制御・状態・operand routingを最優先で変えるべきである。** multiplier/add-sub本体の局所削減は第二段階とする。

## 12. 560 LUTへ向けた削減候補ランキング

1. **Combination/Fermat-pow と係数生成のarchitecture再設計** — 観測aggregate 372 LUT / 86 FF / 14 CARRY4。唯一、単独の観測幅が必要243 LUTを超える。機能を維持した係数生成、逆元計算、pow sequenceの統合が必要である。
2. **算術controller、operand/result routing、state保持の縮退** — baselineでは multiplier launch sourceがLHS/RHS各9種、top FF直前driverが217個ある。算術engineの利用者を減らし、状態とoperand selectionを狭める施策は第一項と一体で扱う価値が高い。
3. **Final sequenceのstate/scratch/selection削減** — aggregate 68 LUT / 33 FF。単独では不足するが、第一項後の残差を埋める候補である。CARRY4差0なので、shared datapathを維持しながら制御・scratchを削る方向が妥当である。
4. **Input datapath周辺のcontroller/register削減** — input arithmetic aggregateは160 LUT / 88 FF / 13 CARRY4だが、multiplier、S1/S2、validationに必須部分を含む。multiplier本体は3設計で不変かつ第一主因でないため、先に手を付ける優先度は低い。
5. **Protocol局所最適化** — 固定費203 LUTは大きいが、32bit framingやSPI semanticsは変更禁止である。protocol_onlyを全削除しても比較としてしか意味がなく、243 LUTの必須削減を単独では満たせない。

## 13. IMPL_3への提案

次のIMPLでは、まず正規SPECを保持したまま、次の構造方針を1つ選んで設計・検証するのが妥当である。

- combination と Fermat exponentiationの別々の広いstate群を、少数の再利用可能な反復stateと小さなphase/contextへ統合する。
- multiplier operandを多数のstateから直接多重化せず、少数のoperand staging registerへ集約し、launch pointとresult destinationを狭める。
- numerator/denominator、pow、coefficient、finalのscratch lifetimeを解析し、同時に不要なregisterを共有する。ただし全面的register-file化は今回の禁止事項であり、次IMPLで明示的に仕様化してから行う。
- coefficient計算とinverse/powのalgorithm選択を、WIDTH=8だけでなく parameterized WIDTH の正当性とcycle上限を保つ条件で再評価する。
- 第一段階の合格条件を「正規Icarus全PASSかつ W08 post-synth LUT≤560」とし、達成後にのみ PNR可否を別工程で判断する。

これは提案だけであり、本作業では bit-serial化、microcode化、register-file化、multiplier/add-sub統合、係数algorithm変更のいずれも実装していない。

## 14. 未実施事項・不確定性

- PNR、placer、timing、bitstream、flash、実機試験は実施していない。
- WIDTH=7以下、WIDTH=9以上の追加作業はしていない。
- 正規RTLの最適化、IMPL_3作成、architecture探索はしていない。
- flatten/ABC9後は多くのLUT `src` がmapping libraryへ移るため、LUTをRTL行単位に無理に再帰属していない。
- aggregate差分はglobal remappingを含み、独立block面積ではない。
- multiplierの38 FF/6 CARRY4と直前coneは直接追跡できるが、本体の排他的LUT総数は不確定である。
- high-fanout値は構造比較指標であり、technology-mapped長名から信号意味を断定していない。
- 3診断だけで multiplier が最大要因でないこと、および優先領域を判定できたため、許可されていた追加診断 `input_multiplier_dummy` は作成していない。

## 15. 保護対象未変更確認

開始時に個別 SHA-256 と tree manifest/digestを採取し、診断終了時に全file manifestを照合した。次の個別 SHA-256 は開始時と終了時で一致した。

| 対象 | SHA-256 |
|---|---|
| SPEC_abc471e_narrow.md | `d3acc9ce369c2ae66cc5654710b479b321c30da1dd00591daa662a45ebf1469a` |
| IMPL_abc471e_narrow.md | `226e8f1a22a1cef0c1db432f86261e56cf1bb1cf0d6f0220ae6501a5837d55ee` |
| IMPL_abc471e_narrow_2.md | `6de576707de26a667be698dff34d956ec24ee34bbd6c4232855cecd756a3daf6` |
| WORK_REQUEST_abc471e_narrow.md | `8af622f69871e7d8ded84cbae3e4975e89560bedb900b81b1e26119866dd46e3` |
| WORK_REQUEST_abc471e_narrow_2.md | `fc7a0bd64054d0e75fae394fe8dafe903cd3ad36a116b5043dcaf881ec088b38` |
| REFERENCE_MAP.md | `b3f1a177ab67d6f55ece551a74598377d42f7f1aa95883ce5552f7022ceaec12` |
| REPORT_abc471e_narrow.md | `70cde65f171340d790c4e669426cb80032106d33be36bc9cf2e7facc46cb3641` |
| ffpga/src/main.v | `8d6b53bf7c230add104c24da87c933fd89dda291339f0ffd20f421700a04befa` |
| ffpga/src/spi_target.v | `c7166ce9076223a2818514ef7ff5ca3f6d322d1b9290484c5084c6ac09cd21ec` |
| sim/abc471e_narrow_tb.v | `8261a2cac36a018ceb493d6ee601a8c8a756cba4621c2b54da12772a95dfec19` |

| tree | files | start/end digest |
|---|---:|---|
| ffpga/src | 2 | `e2169674016710b861a11ffbf520117d1eec3a1a99f8dbb08bc1acc02982c7e7` |
| sim | 1 | `90d0761de81ce361fbac8cdbb6125fe15edebab829b4314a9574648f0a3208d9` |
| tools | 3 | `ad7024cba846e2a97e0959fccd8e384e5c18ed8da6c955bb6a9b21d168317fb1` |
| experiments | 93 | `9fd0dedcb616d84e590a7c5ca907772708363e98e0fd657edb776f6e9b3ccf42` |
| S1S2_30BIT_BASELINE | 128 | `b1b072a689ef32189755adb6bd696c3941da7dbbb5fd41c435c3b6be3b17ebcf` |

新規解析物は `diagnostics/w08/` と本REPORTだけである。

## 16. 停止点

指定された W08 baseline確認、3診断のIcarus、同一flowのPost-Synthesis、4設計比較、aggregate差分、netlist構造解析、560 LUTへの優先順位整理、保護対象照合を完了した。

ここで停止する。PNR、実機作業、IMPL_3作成、最適化実装には進まない。

主要な再現成果物:

- `diagnostics/w08/run_diagnostics.ps1`
- `diagnostics/w08/resource_comparison.csv/json`
- `diagnostics/w08/aggregate_differences.csv/json`
- `diagnostics/w08/analyze_netlists.py`
- `diagnostics/w08/netlist_analysis_summary.csv`
- `diagnostics/w08/netlist_analysis.json`
- 各診断directoryの source、testbench、config、Icarus log、synth script/log、post-synth report/netlist、EDIF、resource summary
