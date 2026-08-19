# ABC471E Narrow compact_v3 実装レポート

## 1. 結論

`SPEC_abc471e_narrow_2.md` と `IMPL_abc471e_narrow_3.md` を正として、既存RTLを変更せず `compact_v3/` に単一parameterized RTLを実装した。

WIDTH=8 (`MOD=251`, `N_MAX=250`, `VALUE_BYTES=1`) の最終結果は次のとおりである。

| 項目 | 旧W8 baseline | compact_v3 W8 | 差 |
|---|---:|---:|---:|
| LUT | 803 | 557 | -246 (-30.6%) |
| FF | 308 | 163 | -145 (-47.1%) |
| CARRY4 | 35 | 31 | -4 (-11.4%) |
| MUXF7 / MUXF8 | 0 / 0 | 0 / 0 | 0 / 0 |
| ceil(LUT/4) | 201 | 140 | -61 |
| ceil(FF/8) | 39 | 21 | -18 |

必達目標の `W8 LUT <= 560` には3 LUTの余裕で到達した。余裕目標の `W8 LUT <= 520` には37 LUT届かなかった。`ceil(557/4)=140` は必要条件にすぎず、Type=Lへのfitを意味しない。PNRは指示どおり実行していない。

W8が521..560 LUTの範囲だったため、gateに従ってW9のみ追加評価した。W9はIcarus 39/39 PASS、Post-Synthesisは663 LUT / 184 FF / 41 CARRY4だった。W10はこのWORKでは実行していない。

## 2. 実装したarchitecture

主な変更は以下である。

- `WIDTH`, `MOD`, `N_MAX`, `VALUE_BYTES=(WIDTH+7)/8` を持つ単一RTLとした。WIDTH別コピーは作成していない。
- N/K/A/answerを`VALUE_BYTES` byteのunsigned big-endianとした。W8は1 byte、W9は2 byteである。
- commandはcommand phaseだけで解釈し、payload中の`FD/FE/FF`は値のbyteとして扱う。
- 算術制御を7状態のone-hot sequencer (`IDLE/LAUNCH/WAIT/ALU/COMB_CHECK/POW_CHECK/PUBLISH`) と小さなmultiply/ALU contextへ統合した。
- 乗算起動点を共通`A_LAUNCH`の1か所へ集約した。operandはcontextで選択し、multiplier内部のcapture registerを唯一のstaging層として使う。
- `numerator/denominator/i/r`, pow result/base/exp, coefficient、final temporaryを4本のWIDTH-sized scratchへライフタイム共有した。
- A配列は保存せず、ストリーム中に`S1=sum(Ai)`と`S2=sum(Ai^2)`だけを保持する。
- `C(N-1,K-1)`、Fermat inverse、係数生成、finalを同じ1個のmodular multiplierと1系統のtop modular add/subで順次実行する。
- answer専用register、旧32bit receive shift、専用input count、用途別combination/pow/final register群を撤去した。
- multiplierのproduct専用FFをなくし、accumulatorを完了値として直接使用した。
- 公開状態と完了保持状態を1状態へ共有し、STATUS読出しを妨げないよう初回だけreply/statusをロードする。

外部framingのbyte数は、N個のAを含む値payloadだけを数えると、旧32bit版の`4*(N+2)` byteからW8の`N+2` byteへ75%減る。answerも4 byteから1 byteへ減る。command、ACK、STATUSは従来どおり1 byteである。

## 3. Icarus検証

tool:

```text
Icarus Verilog version 12.0 (devel) (s20150603-1539-g2693dd32b)
```

### W8

最終実行は39/39 PASSだった。以下を含む。

- N=1,K=1、K=1、K=N、A=[1,2,3]
- Ai=0、Ai=MOD-1 (=250)
- N=0、N=MOD (=251)、K=0、K>N、Ai=MOD
- N個後のextra payload
- sticky ERROR、RESET recovery、STATUS、1-byte answer
- payload中のFD/FE/FFがcommandにならず、その後Ai>=MOD errorになること
- seed固定のrandom small case 24件を、問題定義から直接列挙する独立brute forceと照合

### W9

同じRTLを`WIDTH=9`, `MOD=509`, `N_MAX=508`, `VALUE_BYTES=2`として実行し、39/39 PASSだった。2-byte big-endian N/K/A/answer、Ai=508、Ai=509 error、low byteがFD/FE/FFとなる有効Ai、sticky ERROR、STATUS、24件のrandom brute forceを確認した。

## 4. performance

system clock単位の測定結果であり、SPI転送時間はphaseおよびN_MAX推定から除外した。

| 設定 | MUL_CLOCKS | AI_MIN/MAX | N=8,K=4 combination | pow+coefficient | final | N_MAX級推定total |
|---|---:|---:|---:|---:|---:|---:|
| W8 | 16 | 22 / 22 | 118 | 607 | 60 | 11004 |
| W9 | 18 | 24 / 24 | 130 | 797 | 66 | 23935 |

W8のN_MAX推定は`N=250`, worst `r=124`として、実測した1 inputあたり22 clocks、combination反復、N=8,K=4で実測したpow/finalを合成した値である。データ依存するpow bit patternやSPI時間を含む厳密worst-caseではない。

旧W8ログと直接比較できる指標では、multiplierは16 clocksのまま、Ai処理は23から22 clocksへ1 clock短縮した。旧ログにはcombination/pow/final別またはN_MAX totalの測定がないため、それらの増減率は断定しない。compact_v3の絶対値は上表とログへ明示した。

## 5. Post-Synthesis結果

使用toolとflow:

```text
Yosys 0.59+0 (git sha1 946048486, x86_64-w64-mingw32-g++ 15.2.0 -O3)
flatten -noscopeinfo
synth_xilinx -nobram -noiopad -nodsp -abc9
clean
autoname
```

| 設定 | wires | bits | cells | CARRY4 | FDCE | FDPE | FF | INV | LUT2 | LUT3 | LUT4 | LUT5 | LUT6 | LUT | M7 | M8 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline W8 | 1076 | 2591 | 1171 | 35 | 300 | 8 | 308 | 25 | 202 | 103 | 170 | 191 | 137 | 803 | 0 | 0 |
| compact_v3 W8 | 761 | 1830 | 772 | 31 | 157 | 6 | 163 | 21 | 111 | 98 | 101 | 171 | 76 | 557 | 0 | 0 |
| compact_v3 W9 | 937 | 2235 | 911 | 41 | 178 | 6 | 184 | 23 | 159 | 93 | 133 | 189 | 89 | 663 | 0 | 0 |

W8ではwire数が29.3%、cell数が34.1%減った。W9の`ceil(LUT/4)=166`であり、Type=Lの140に対するPost-Synthesis必要条件を満たさない。

## 6. synthesis-guided cleanup

各checkpointにはconfig、Icarus log、synthesis script/log、post-synthesis Verilog、EDIF、resource summaryを保存した。`main_sha256`を含む全表は`compact_v3/resource_checkpoints.csv/json`にある。

| checkpoint | LUT | FF | CARRY4 | M7/M8 | top FF直前unique LUT/MUX | 判定 |
|---|---:|---:|---:|---:|---:|---|
| initial | 680 | 224 | 33 | 0/0 | 128 | 初回compact architecture |
| cleanup1 | 696 | 200 | 29 | 0/0 | 103 | single inverse案、LUT悪化で棄却 |
| cleanup2 | 654 | 200 | 31 | 0/0 | 104 | framing/register共有を維持しpow順を復元 |
| cleanup3 | 606 | 183 | 31 | 0/0 | 87 | top operand staging FFを除去 |
| cleanup4 | 571 | 167 | 31 | 0/0 | 79 | accepted count/scratch、product/acc共有 |
| cleanup5 | 597 | 168 | 28 | 8/4 | 79 | 2-stage correction、MUX増で棄却 |
| cleanup6 | 594 | 164 | 31 | 1/0 | 76 | reply/start派生化、LUT悪化で棄却 |
| cleanup7 | 600 | 169 | 31 | 0/0 | 79 | pow flag配置案、棄却 |
| cleanup8 | 580 | 167 | 31 | 0/0 | 79 | binary arithmetic state第1案、未達 |
| cleanup9 | 563 | 164 | 31 | 0/0 | 80 | pow flag共有と4bit state |
| cleanup10 | 569 | 163 | 31 | 0/0 | 79 | reply_valid派生化、棄却 |
| cleanup11 | 574 | 163 | 31 | 0/0 | 79 | tx active削減案、棄却 |
| cleanup12 | 561 | 164 | 31 | 2/0 | 80 | manual one-hot、目標まで1 LUT |
| cleanup13 | 601 | 163 | 31 | 2/1 | 80 | publish処理複製、棄却 |
| cleanup14/final | 557 | 163 | 31 | 0/0 | 80 | PUBLISH/DONE終端共有、採用 |

全checkpointのsource-level multiplier launch siteは共通`A_LAUNCH`の1か所である。途中案はLUTだけでなくFF、CARRY4、MUXF7/F8も比較し、局所的なFF/CARRY削減で総LUTが悪化した案は採用しなかった。

## 7. netlist構造比較

flatten/autoname後のprimitive接続と`src`属性を解析した。LUTのRTL行別帰属ではなく、構造指標として扱う。

| 指標 | baseline W8 | compact_v3 W8 | 変化 |
|---|---:|---:|---:|
| multiplier launch site | 11 | 1 | -10 (-90.9%) |
| unique LHS source expression | 9 | 4 | -5 (-55.6%) |
| unique RHS source expression | 9 | 7 | -2 (-22.2%) |
| multiplier FF | 38 | 30 | -8 (-21.1%) |
| multiplier CARRY4 | 6 | 6 | 不変 |
| multiplier FF直前unique driver | 38 | 30 | -8 |
| multiplier depth-2 unique primitive | 51 | 63 | +12 |
| top protocol/control FF | 225 | 80 | -145 (-64.4%) |
| top FF直前unique LUT/MUX driver | 217 | 80 | -137 (-63.1%) |
| 全FF直前unique combinational driver | 289 | 152 | -137 (-47.4%) |
| 非reset/non-raw-rx最大fanout指標 | 188 | 84 | -104 (-55.3%) |
| MUXF7 / MUXF8 | 0 / 0 | 0 / 0 | 不変 |

launchとtop next-state/register-enable coneは明確に縮小した。multiplier内部のFF/CARRY4は小さな固定資源として残り、product FF除去でFFは38から30へ減った。一方、operand selectionをmultiplier capture直前へ集約したため、multiplier FFのdepth-2 coneは51から63へ増えた。この局所増加を含めても全体は246 LUT減っている。

top protocol/control FFの225から80への削減には、可変framingだけでなくscratch共有とcontroller統合も含まれる。ABC9のglobal remapping後なので、protocol単独のLUT減少量として分離はしない。

## 8. 判断基準への回答

1. W8は557 LUT / 163 FF / 31 CARRY4。
2. 803 LUTから246 LUT、30.6%減った。
3. 560 LUT以下へ到達した（3 LUT余裕）。
4. 520 LUT以下には未到達（37 LUT超過）。
5. framingは32bit固定からW8 1 byte/W9 2 byteへ縮小し、top protocol/control FFは225から80、top FF直前driverは217から80へ減った。
6. launch siteは11から1、unique LHS/RHS sourceは9/9から4/7、全FF直前driverは289から152へ減った。
7. 直接比較可能なW8 multiplierは16で不変、Aiは23から22へ短縮。現版のN=8,K=4 phaseは118/607/60、N_MAX級推定は11004 clocks（SPI除外）。旧版phase別値がないため、その増減率は未確定。
8. gateに従いW9を実施し39/39 PASS、663 LUT / 184 FF / 41 CARRY4。W10は未実施。
9. W8はPost-Synthesis上のPNR候補である。ただし余裕は3 LUTしかなくfit保証はないため、次WORKで独立してPNRを実施するのが妥当。W9/W10をType=L候補にするには追加architecture変更が必要。

## 9. 成果物

主な成果物:

```text
compact_v3/main.v
compact_v3/spi_target.v
compact_v3/compact_v3_tb.v
compact_v3/run_build.ps1
compact_v3/analyze_results.py
compact_v3/w8/
compact_v3/w9/
compact_v3/checkpoints/
compact_v3/resource_checkpoints.csv
compact_v3/resource_checkpoints.json
compact_v3/final_resources.csv
compact_v3/final_resources.json
compact_v3/netlist_analysis_summary.csv
compact_v3/netlist_analysis.json
```

最終RTL SHA-256:

```text
main.v             e910abcf293fc37fbb071eef5cfad4eb91b0047263b512707278360032716fc6
compact_v3_tb.v    284816166ae993c154c2c9f97119e53cff4286c19d55925fa759cfd376c9c094
spi_target.v       62946ac3e2f0b16bd11fbf3411454496d02b44fe9db516d2ec63c9ec157d5463
```

## 10. 保護対象

開始時に個別SHA-256とtree manifestを取得した。終了時照合結果はすべて一致した。

| tree | files | start/end digest |
|---|---:|---|
| ffpga/src | 2 | `e2169674016710b861a11ffbf520117d1eec3a1a99f8dbb08bc1acc02982c7e7` |
| sim | 1 | `90d0761de81ce361fbac8cdbb6125fe15edebab829b4314a9574648f0a3208d9` |
| tools | 3 | `ad7024cba846e2a97e0959fccd8e384e5c18ed8da6c955bb6a9b21d168317fb1` |
| experiments | 93 | `9fd0dedcb616d84e590a7c5ca907772708363e98e0fd657edb776f6e9b3ccf42` |
| diagnostics | 50 | `2baad495f0e879a47eec75d0a5484929b0ffa3ae93cc83f0631a30da5a4732b5` |
| S1S2_30BIT_BASELINE | 128 | `b1b072a689ef32189755adb6bd696c3941da7dbbb5fd41c435c3b6be3b17ebcf` |

個別文書の開始時SHA-256は以下である。終了時もすべて一致した。

| file | SHA-256 |
|---|---|
| SPEC_abc471e_narrow.md | `d3acc9ce369c2ae66cc5654710b479b321c30da1dd00591daa662a45ebf1469a` |
| SPEC_abc471e_narrow_2.md | `7118a63b5a1e39c39439deacf1ea221ed002d7f0c58f128685dad887e53384fa` |
| IMPL_abc471e_narrow.md | `226e8f1a22a1cef0c1db432f86261e56cf1bb1cf0d6f0220ae6501a5837d55ee` |
| IMPL_abc471e_narrow_2.md | `6de576707de26a667be698dff34d956ec24ee34bbd6c4232855cecd756a3daf6` |
| IMPL_abc471e_narrow_3.md | `a89649f753d0bbe8bfeb098d2371525bba99a648f28a25de7d26fe0b440f1fd0` |
| WORK_REQUEST_abc471e_narrow.md | `8af622f69871e7d8ded84cbae3e4975e89560bedb900b81b1e26119866dd46e3` |
| WORK_REQUEST_abc471e_narrow_2.md | `fc7a0bd64054d0e75fae394fe8dafe903cd3ad36a116b5043dcaf881ec088b38` |
| WORK_REQUEST_abc471e_narrow_3.md | `46a5f1e737ccc553fae8e18c438af9898ee5e3d2f618fb86cca1d6a897500aea` |
| REPORT_abc471e_narrow.md | `70cde65f171340d790c4e669426cb80032106d33be36bc9cf2e7facc46cb3641` |
| REPORT_abc471e_narrow_2.md | `e2b60302058d399ba92b5866d6e2b25a4893d676802505d9b78770686077e13f` |
| REFERENCE_MAP.md | `b3f1a177ab67d6f55ece551a74598377d42f7f1aa95883ce5552f7022ceaec12` |

## 11. 停止点

compact_v3実装、W8/W9 Icarus、Post-Synthesis、cleanup、resource/netlist比較、保護対象照合までを本WORKの範囲とした。PNR、placer、timing closure、bitstream、flash、実機試験は実行せず、ここで停止する。
