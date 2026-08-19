# ABC471E S1/S2 面積差分診断レポート

作成日: 2026-08-17  
正本: `DIAGNOSTIC_REQUEST_abc471e_s1s2.md` SHA-256 `9BF90F96FDC2BF21CC4DBE48FE731BFCFD6B078F0A651318CC40FEE0FDD0CE9B`

## 1. Executive Summary

`pow_fixed` と `coefficient_pow_fixed` を `diagnostics/` 以下に作成し、両方について診断用Icarusテスト4ケースを実行した。両版とも4/4 PASSであり、SPI、S1/S2更新、shared modular multiplier、top shared modular add/sub、STATUS/replyが実動していることを確認した。

Post-Synthesisの前にForgeFPGA synthesisのCLI再現性を確認した。ForgeFPGA Workshopのプロジェクト設定が指定するbundled Yosys 0.59+0を用い、正規S1/S2 RTLと既存scriptの同一コピーを隔離領域で再合成した結果、主要primitive countだけでなく、次の3成果物のSHA-256まで既存成果物と完全一致した。

- `post_synth_report.txt`
- `post_synth_results.v`
- `netlist.edif`

したがってCLI再現性は成立したと判断し、同じbundled toolと同じsynthesis pass/optionsで2診断版をPost-Synthesisした。

主要な実測結果は次のとおりである。ここでaggregate costは対象RTL内部だけでなく、その削除で変化したoperand MUX、next-state、decode、control、ABC9再マッピングを含む差分であり、block単体面積ではない。

| aggregate差分 | LUT減少 | FF減少 | CARRY4減少 | LUT+MUXF7+MUXF8減少 |
|---|---:|---:|---:|---:|
| pow = original - pow_fixed | 276 | 67 | 2 | 199 |
| combination = pow_fixed - coefficient_pow_fixed | 622 | 256 | 46 | 622 |
| combination + pow = original - coefficient_pow_fixed | 898 | 323 | 48 | 821 |

結論は次のとおりである。

- Fermat/powは無視できないが、今回の差分ではcombination逐次計算・storage・controlの方が大きい。
- combination + powは、LUTを898個、FFを323個、CARRY4を48個減らす大きな面積要因である。ただし「他の全blockより最大」とまでは、この2差分だけでは証明できない。
- 全体を固定してもLUT 1223、FF 625、CARRY4 73が残る。4 LUT/Type=Lという粗い下限でも `ceil(1223/4)=306` Type=L相当であり、140には依然遠い。
- 残るshared multiplier本体、top add/sub、normalization、S1/S2、SPI/protocolと、それらの30-bit next-state/datapathが支配的である。30-bit幅縮小の必要性を強く示す結果だが、今回は実装していない。
- 次にPNRするなら、Post-Synthesisが最小で診断情報量も最大の `coefficient_pow_fixed` が優先である。ただし上記の下限からfitは期待しにくい。

PNR、bitstream生成、実機試験、次段階の最適化は実行していない。

## 2. 実験目的と条件

目的は、現行S1/S2版から次を差分で除去し、物理的に常在する回路のaggregate costを測ることである。

1. `pow_fixed`: Fermat inverse / binary exponentiationのみ除去
2. `coefficient_pow_fixed`: combination計算とFermat/powを除去

共通して次を維持した。

- `MOD = 998244353`
- `N_MAX = 200000`
- 30-bit modular datapath
- SPI Template V3相当の外部protocol
- SPIから受信したAによるS1/S2入力集計
- 1個のshared modular multiplier
- top shared modular add/sub
- S1²、S1²-S2、係数付き2項、最終加算

診断版の数学的有効範囲は `N=3, K=2` のみであり、一般N/Kの正しさは意図していない。

使用ツール:

- Icarus Verilog 12.0 (devel), `s20150603-1539-g2693dd32b`
- ForgeFPGA bundled Yosys 0.59+0, git `946048486`
- Yosys実体: `C:\Program Files\Renesas Electronics\Go Configure Software Hub\external\yosys\v59\yosys.exe`

診断成果物:

- `diagnostics/pow_fixed/`
- `diagnostics/coefficient_pow_fixed/`
- CLI再現確認用隔離コピー: `diagnostics/cli_repro/`

## 3. 元S1/S2の基準値とCLI再現性

### 3.1 基準値

| item | original |
|---|---:|
| wires | 3270 |
| wire bits | 7100 |
| cells | 3340 |
| CARRY4 | 121 |
| FDCE | 940 |
| FDPE | 8 |
| FF total | 948 |
| INV | 140 |
| LUT2 | 482 |
| LUT3 | 142 |
| LUT4 | 608 |
| LUT5 | 449 |
| LUT6 | 440 |
| LUT total | 2121 |
| MUXF7 | 10 |
| MUXF8 | 0 |
| LUT + MUXF7 | 2131 |
| LUT + MUXF7 + MUXF8 | 2131 |

### 3.2 ForgeFPGA設定との照合

`abc471e_s1s2.ffpga` のsynthesis設定を確認した。

| setting | value |
|---|---|
| Yosys version | 59 |
| flatten | true |
| noDSP | true |
| useABC9 | true |
| noFSM | false |
| autoname | true |
| additionalArguments | empty |
| source | `main.v`, `spi_target.v` |

既存 `ffpga/build/synth_script.ys` は次のflowである。

```text
read_verilog -sv "../src/main.v" "../src/spi_target.v"
hierarchy -check
flatten -noscopeinfo
synth_xilinx -nobram -noiopad -nodsp -abc9
clean
autoname
write_verilog "post_synth_results.v"
write_edif "netlist.edif"
tee -q -o post_synth_report.txt stat
```

topはRTLの `(* top *) module main` 属性から選択された。Post-Synthesis scriptはSDCを読み込まないため、timing constraintはこの測定の入力ではない。Yosysはインストール先を基準にbundled libraryを解決し、logで `v59/share/xilinx/cells_sim.v`、`cells_xtra.v`、`abc9_model.v`、`share/abc9_map.v` の使用を確認した。追加environment variableは設定していない。

### 3.3 隔離再合成

正規RTLとscriptを `diagnostics/cli_repro/` へSHA-256一致でコピーし、`build/` から次を実行した。

```powershell
& 'C:\Program Files\Renesas Electronics\Go Configure Software Hub\external\yosys\v59\yosys.exe' -s synth_script.ys
```

全primitive countは既存値と完全一致した。さらに成果物全体も一致した。

| file | existing SHA-256 | CLI repro SHA-256 | result |
|---|---|---|---|
| `post_synth_report.txt` | `3015FDB2006ADE434109F27BC1A4E17BEA044EEB85140D79A0FFDEBF72A034C6` | same | exact match |
| `post_synth_results.v` | `CE8187902B826205F8B82E1DAC13E7F4923306D301E6C2D6F8678FE49F7E116B` | same | exact match |
| `netlist.edif` | `1FA2F70D1A95F83D6C2925DB602BABFD5F978ACABBD96EA317E39F5DCDE2E6B8` | same | exact match |

以上をCLI再現性成立の根拠とした。既存 `ffpga/build/` は上書きしていない。

## 4. pow_fixed

### 4.1 削除したもの

- `pow_result[29:0]`
- `pow_base[29:0]`
- `pow_exp[29:0]`
- `pow_context`
- `C_POW_CHECK`
- `C_POW_RESULT_START/WAIT`
- `C_POW_BASE_START/WAIT`
- pow専用multiplier launchとoperand source

削除したpow状態レジスタのRTL上の公称幅は `30 + 30 + 30 + 1 = 91 bit` である。

### 4.2 残したもの

- `comb_n`, `comb_r`, `comb_i`
- `numerator`, `denominator`
- `coeff_square`, `coeff_pair`, `coeff_pair_work`
- combinationのnumerator/denominator逐次積
- shared multiplierとtop add/sub
- S1/S2入力処理と最終計算

combinationではN=3,K=2に対して実際に `numerator=2`、`denominator=1` まで逐次更新する。

### 4.3 固定inverse

- denominator inverse: `inverse(1) = 1`
- pair係数用: `inverse(N-1) = inverse(2) = 499122177`

係数計算もshared multiplierへdispatchし、`coeff_square=2`、`coeff_pair=1` を得る。

### 4.4 Icarus結果

| A | 独立総当たり期待値 | result | observed multiplier launches | result |
|---|---:|---:|---:|---|
| `[1,2,3]` | 50 | 50 | 11 | PASS |
| `[0,0,0]` | 0 | 0 | 11 | PASS |
| `[1,1,1]` | 12 | 12 | 11 | PASS |
| `[MOD-1,1,0]` | 2 | 2 | 11 | PASS |

各A受信後のS1/S2も独立計算値と照合した。11 launchの内訳は、入力x²が3回、combinationが2回、係数計算が3回、最終計算が3回である。STATUSは `0x80`、4-byte answerも一致した。

### 4.5 Post-Synthesis結果

| item | pow_fixed |
|---|---:|
| wires | 3242 |
| wire bits | 6723 |
| cells | 3070 |
| CARRY4 | 119 |
| FDCE | 873 |
| FDPE | 8 |
| FF total | 881 |
| INV | 138 |
| LUT2 | 427 |
| LUT3 | 181 |
| LUT4 | 343 |
| LUT5 | 507 |
| LUT6 | 387 |
| LUT total | 1845 |
| MUXF7 | 58 |
| MUXF8 | 29 |
| LUT + MUXF7 | 1903 |
| LUT + MUXF7 + MUXF8 | 1932 |

## 5. coefficient_pow_fixed

### 5.1 削除したもの

pow_fixedの削除対象に加えて、次を削除した。

- `comb_n`, `comb_r`, `comb_i`
- `numerator`, `denominator`
- `coeff_square`, `coeff_pair`, `coeff_pair_work`
- combination専用FSM状態
- combination専用multiplier launch、operand source、decode

### 5.2 残したもの

- SPI/protocolとA入力
- S1/S2入力集計
- shared modular multiplier本体
- top shared modular add/sub
- S1²、S1²-S2、2つの係数付き最終積、最終加算

### 5.3 固定係数

N=3,K=2に対して次を最終multiplier operandとして直接使用した。

- `coeff_square = C(2,1) = 2`
- `coeff_pair = C(1,0) = 1`

A、S1、S2、pair_twiceは動的であるため、最終計算全体はconstant-foldされない。

### 5.4 Icarus結果

| A | 独立総当たり期待値 | result | observed multiplier launches | result |
|---|---:|---:|---:|---|
| `[1,2,3]` | 50 | 50 | 6 | PASS |
| `[0,0,0]` | 0 | 0 | 6 | PASS |
| `[1,1,1]` | 12 | 12 | 6 | PASS |
| `[MOD-1,1,0]` | 2 | 2 | 6 | PASS |

6 launchの内訳は入力x²が3回、最終計算が3回である。入力用add、最終sub、borrow correctionが必要なケース、最終addの状態通過もTBで観測した。

### 5.5 Post-Synthesis結果

| item | coefficient_pow_fixed |
|---|---:|
| wires | 2155 |
| wire bits | 4336 |
| cells | 2085 |
| CARRY4 | 73 |
| FDCE | 619 |
| FDPE | 6 |
| FF total | 625 |
| INV | 77 |
| LUT2 | 199 |
| LUT3 | 104 |
| LUT4 | 252 |
| LUT5 | 344 |
| LUT6 | 324 |
| LUT total | 1223 |
| MUXF7 | 58 |
| MUXF8 | 29 |
| LUT + MUXF7 | 1281 |
| LUT + MUXF7 + MUXF8 | 1310 |

## 6. 3版比較表

| item | S1/S2 original | pow_fixed | coefficient+pow fixed |
|---|---:|---:|---:|
| wires | 3270 | 3242 | 2155 |
| wire bits | 7100 | 6723 | 4336 |
| cells | 3340 | 3070 | 2085 |
| CARRY4 | 121 | 119 | 73 |
| FDCE | 940 | 873 | 619 |
| FDPE | 8 | 8 | 6 |
| FF | 948 | 881 | 625 |
| INV | 140 | 138 | 77 |
| LUT2 | 482 | 427 | 199 |
| LUT3 | 142 | 181 | 104 |
| LUT4 | 608 | 343 | 252 |
| LUT5 | 449 | 507 | 344 |
| LUT6 | 440 | 387 | 324 |
| LUT total | 2121 | 1845 | 1223 |
| MUXF7 | 10 | 58 | 58 |
| MUXF8 | 0 | 29 | 29 |
| LUT+MUXF7 | 2131 | 1903 | 1281 |
| LUT+MUXF7+MUXF8 | 2131 | 1932 | 1310 |

`MUXF8` は要求書の最小比較項目外だが、診断版で29個発生したため省略すると再マッピングを過大評価する。以後はLUT totalに加えて `LUT+MUXF7+MUXF8` も参照する。

## 7. aggregate cost

表中の正値は削減、負値は診断版でそのcell種が増加したことを示す。

| item | pow aggregate | combination aggregate | combination + pow aggregate |
|---|---:|---:|---:|
| 定義 | original - pow_fixed | pow_fixed - coefficient_fixed | original - coefficient_fixed |
| cells | 270 | 985 | 1255 |
| CARRY4 | 2 | 46 | 48 |
| FDCE | 67 | 254 | 321 |
| FDPE | 0 | 2 | 2 |
| FF total | 67 | 256 | 323 |
| INV | 2 | 61 | 63 |
| LUT2 | 55 | 228 | 283 |
| LUT3 | -39 | 77 | 38 |
| LUT4 | 265 | 91 | 356 |
| LUT5 | -58 | 163 | 105 |
| LUT6 | 53 | 63 | 116 |
| LUT total | 276 | 622 | 898 |
| MUXF7 | -48 | 0 | -48 |
| MUXF8 | -29 | 0 | -29 |
| LUT+MUXF7 | 228 | 622 | 850 |
| LUT+MUXF7+MUXF8 | 199 | 622 | 821 |
| wires | 28 | 1087 | 1115 |
| wire bits | 377 | 2387 | 2764 |

元全体に対するcombined aggregateはLUT 42.3%、FF 34.1%、CARRY4 39.7%である。pow単独はLUT 13.0%、FF 7.1%、CARRY4 1.7%であり、combination追加削除の効果の方が大きい。

RTL上の公称状態幅との比較:

| 対象 | RTL公称状態幅 | 実測FF aggregate | 解釈 |
|---|---:|---:|---|
| pow regs | 91 bit | 67 | 一部bitの定数化・共有・周辺制御の再合成を含む |
| combination regs（pow_fixedに残るもの） | 246 bit | 256 | 246 bit本体に加え、FSM/operand/control差を含む |
| combination + pow | 337 bit | 323 | block境界と合成FF境界は一対一でない |

この差が、aggregateを「レジスタ宣言幅」や「module単体面積」と呼べない理由である。

## 8. operand MUX / next-state / CARRY4の変化

### 8.1 multiplier launchとoperand source

RTLのlaunch状態を静的に数えた。定数も1つのsourceとして数える。

| version | launch states | unique LHS sources | unique RHS sources |
|---|---:|---:|---:|
| original | 11 | 9 | 9 |
| pow_fixed | 9 | 7 | 9 |
| coefficient_pow_fixed | 4 | 4 | 4 |

pow_fixedではpow用2 launchを消したが、固定inverse `1` と `499122177` がRHS候補になるため、RTL上のRHS source種類数は9のままである。ただし動的sourceと状態依存は減っており、LUT totalは276減った。

coefficient_pow_fixedではcombination/係数計算の5 launchをさらに消し、LHS/RHSとも4 sourceまで縮小した。ここでLUTが追加622減ったことは、combination storageだけでなくwide operand選択とcontrollerの削除が効いたことと整合する。

### 8.2 FF直前の組合せdriver

`post_synth_results.v` で各FDCE/FDPEのD入力を直接駆動するprimitiveを接続関係から集計した。

| direct D driver | original | pow_fixed | coefficient_pow_fixed |
|---|---:|---:|---:|
| LUT2～LUT6 | 909 | 823 | 567 |
| MUXF7/MUXF8 | 10 | 29 | 29 |
| other/direct | 29 | 29 | 29 |
| FF total | 948 | 881 | 625 |

pow削除でLUT直結D pathが86、combination追加削除で256減っている。後者はFF減少数と一致し、wide next-state網の大幅縮小を支持する。

### 8.3 MUXF7/MUXF8

originalのMUXF7は10、MUXF8は0だった。両診断版ではMUXF7 58、MUXF8 29となり、29組の `2 x MUXF7 -> 1 x MUXF8` 木へ再マップされた。29個のMUXF8出力はFFのDを直接駆動する。

ただし、このMUXF7/MUXF8の `src` はYosysの `xilinx/lut_map.v` のみを指し、元RTL行は失われている。さらにautoname後の信号名は複数のlogic coneを連結した名前である。そのため「29個すべてがmultiplier operand MUX」などとは断定できない。pow_fixedとcoefficient_pow_fixedで個数が同一であることから、少なくともcombination専用MUXそのものではなく、診断版で共通に残るwide next-state coneまたはABC9の別分解形である可能性が高い。

この再配置のため、pow aggregateはLUTだけなら276減る一方、MUXF7/F8が合計77増え、`LUT+MUXF7+MUXF8` の純減は199となる。cell種別ごとの増減は非線形である。

### 8.4 CARRY4

source attributeと差分から次の内訳を得た。

| CARRY4 group | original | pow_fixed | coefficient_pow_fixed | certainty |
|---|---:|---:|---:|---|
| shared modular multiplier instance | 20 | 20 | 20 | 直接確認 |
| top shared modular add/sub | 18 | 18 | 18 | 直接確認 |
| x normalization compare/subtract | 10 | 10 | 10 | 直接確認 |
| received/input counters | 16 | 16 | 16 | 直接確認 |
| protocol comparisons + SPI | 9 | 9 | 9 | 直接確認した小項目の合算 |
| combination/pow/control remainder | 48 | 46 | 0 | 上記を総数から差し引いたaggregate |
| total | 121 | 119 | 73 | report実測 |

powを消してもshared multiplierの物理回路は残るため、その20 CARRY4は不変である。powの主処理は同じ乗算器の時間共有であり、計算回数を消しても乗算器本体のCARRY4は消えない。combinationを外すと、`comb_n`、`comb_r`、`comb_i`、`k-1`等の32-bit arithmetic/comparisonが消え、追加で46 CARRY4減った。

## 9. 仮説への回答

1. **Fermat/powを除去するとLUTはいくつ減るか**  
   LUT totalは276減る。ABC9の再分解でMUXF7/F8が77増えるため、LUT+MUXF7+MUXF8では199減る。

2. **FFはいくつ減るか**  
   67減る。RTL宣言上のpow状態は91 bitだが、aggregateは周辺最適化込みで67 FFである。

3. **CARRY4はいくつ減るか**  
   2減る。shared multiplier本体20 CARRY4は不変である。

4. **combination逐次計算をさらに外すとどれだけ減るか**  
   LUT 622、FF 256、CARRY4 46が追加で減る。cellsは985減る。

5. **combination + powが最大面積要因という仮説は支持されるか**  
   「大きな主要因」という仮説は支持される。combined aggregateはLUT 898、FF 323、CARRY4 48である。ただし他の全blockを同条件で個別固定した比較ではないため、厳密な最大順位は未証明である。

6. **全部外しても140 CLB相当へ遠いか**  
   遠い。coefficient_pow_fixedにもLUT 1223が残り、4 LUT/Type=Lという粗い下限で306 Type=L相当である。MUXF7/F8や配線・packing制約を含めれば悪化し得る。

7. **残りの主要LUT要因は何か**  
   shared multiplier、top modular add/sub、x normalization、S1/S2の30-bit更新、SPI/protocol、残存controllerと各30-bit FFのnext-state logicである。今回のCARRY4帰属とFF直前driver数がこれを支持する。

8. **30-bit datapathを縮小する必要性は強まったか**  
   強まった。combination/powを完全に外してもLUT 57.7%、FF 65.9%、CARRY4 60.3%が残る。ただし幅縮小は本診断では実装していない。

9. **16bit化・8bit化の波及先**  
   shared multiplierのacc/a/bと加算・比較、top add/sub、normalization、S1/S2、term/answer、operand MUX、FF D logicへ同時に波及する。N/K/protocol counterを別に維持するか縮小するかで追加効果は変わる。

10. **次にPNRする価値が高い版**  
    `coefficient_pow_fixed`。3版中最小で、combination/powを除いた残存packingを直接観測できる。ただしPost-Synthesisの粗い下限が140を超えるため、fit確認より残存packing診断としての価値が中心である。

## 10. 次にPNRする価値がある版

優先順位は `coefficient_pow_fixed`、次点が `pow_fixed` である。

| version | LUT-only粗い下限 `ceil(LUT/4)` | LUT+MUXF7+MUXF8を4で割った参考値 | 意味 |
|---|---:|---:|---|
| original | 531 | 533 | 既存PNRのLUT-site下限529と概ね整合 |
| pow_fixed | 462 | 483 | pow削除後のpacking観測 |
| coefficient_pow_fixed | 306 | 328 | combination/pow削除後の残存packing観測 |

これはPost-Synthesis cellからの粗い参考値であり、PNR Type=Lを予測する式ではない。それでも両診断版が140から遠いという方向性は明瞭である。今回は要求どおりPNRしていない。

## 11. 30bit幅縮小への示唆

combined固定版に残るCARRY4 73のうち、直接確認できるだけでもshared multiplier 20、top add/sub 18、normalization 10、input/receive counter 16がある。LUT側でも30-bit FFのD入力を作るlogicとshared operand/controlが残る。

したがって幅縮小を別実験で行う場合、局所的な1レジスタ削減ではなく次へ広く効果が波及すると予想する。

- multiplierのacc/a/bと31-bit arithmetic
- top modular add/subとMOD比較
- x normalization
- S1/S2、term、answer、mul operand register
- bitごとのnext-state/enable MUX

一方、SPIの32-bit big-endian framing、N/K、`N_MAX`用counterはdatapath幅と独立に残せるため、幅縮小率と全体面積縮小率は一致しない。16bit化・8bit化、MOD変更、N_MAX変更はいずれも今回未実施である。

## 12. 未実施事項・不確実性

- PNR、placer、timing analysis、bitstream生成、実機flash、実機試験は未実施。
- 診断版はN=3,K=2専用であり、一般N/Kの機能等価性はない。
- aggregate差分にはABC9のglobal remappingが含まれる。特にLUT3/LUT5とMUXF7/F8は単調に減らない。
- MUXF7/F8のsource attributeはtool mapping sourceしか残さないため、元RTLへの正確な一対一帰属は不能。
- `ceil(LUT/4)` は説明用の粗い下限で、実際のShrike-Lite Type=L utilizationではない。
- timing constraintはPost-Synthesis scriptの入力でないため、今回の差分はタイミング制約下の物理最適化を含まない。
- shared multiplierの動作はIcarusで起動回数と結果を確認し、netlistでも20 CARRY4の同一残存を確認したが、診断版netlistの全内部netに対する形式等価検証は行っていない。

## 13. 元S1/S2ファイル未変更確認

作業開始時に記録したSHA-256と終了前の値を比較した。次はすべて一致した。

| protected item | SHA-256 / tree digest | result |
|---|---|---|
| `ffpga/src/main.v` | `0188DA7194F2D310A2A0580E8462F53A0BA1D9CF029B89A165021914C08C6D75` | MATCH |
| `ffpga/src/spi_target.v` | `C7166CE9076223A2818514EF7FF5CA3F6D322D1B9290484C5084C6AC09CD21EC` | MATCH |
| `sim/abc471e_s1s2_tb.v` | `DDB6AE57AA8BA1209BF9617C86BCB3170BFB0A5274B495AA4CB90084695F4044` | MATCH |
| `SPEC_abc471e_s1s2.md` | `63E6F3CA25184B6323579167E38585665816C65F179BB160CF8386EB1CE873A8` | MATCH |
| `IMPL_abc471e_s1s2.md` | `DDFBBF1BB092B7D73715B2F603CD65C133A5B25660998ABBF0E03896E084CF7B` | MATCH |
| `IMPLEMENTATION_REPORT_abc471e_s1s2.md` | `8C16973ED239339BB00B8FA9FBBE1A634E1A50F639471A12C09E17EB2831F694` | MATCH |
| `AREA_ANALYSIS_abc471e_s1s2.md` | `4726003A074F265DB90EEAFBC6549FFC6975495AD6549E65A6B2FCF54BAD3F28` | MATCH |
| `ffpga/build/synth_script.ys` | `EB7FC35BE1E4E67BD2E4847584175CE95FD9B40D7D1D610158DDAAA1D9C8F9DB` | MATCH |
| `ffpga/build/post_synth_report.txt` | `3015FDB2006ADE434109F27BC1A4E17BEA044EEB85140D79A0FFDEBF72A034C6` | MATCH |
| `ffpga/build/post_synth_results.v` | `CE8187902B826205F8B82E1DAC13E7F4923306D301E6C2D6F8678FE49F7E116B` | MATCH |
| `ffpga/build/netlist.edif` | `1FA2F70D1A95F83D6C2925DB602BABFD5F978ACABBD96EA317E39F5DCDE2E6B8` | MATCH |
| `reference/` 82 files | `03478275CAE578AF0227CA08A6335FAFFB7A4A68588F39DEF25CB9605719B3D9` | MATCH |
| `hardware_logs/` 1 file | `D080463ECCC0631B7017BB9DC034CDEA1CA0BCD865BFD8D8512EE2C7F685FB55` | MATCH |

`IMPL_REQUEST_abc471e_s1s2.md` は読み取りのみで、終了時SHA-256は `863565329A360D4213AD05C4A4BD0EABB95820257506EBE2DA843D415D6A8997` である。`firmware/` も読み取り・変更を行わず、終了時tree digestは `473ED103D83F2F45DB6CE1728BFDA568ECF860290BC4D40FC0DAE2E02DB4999D`（1 file）である。

診断用 `spi_target.v` は正規版の同一コピーであり、両版ともSHA-256 `C7166CE9076223A2818514EF7FF5CA3F6D322D1B9290484C5084C6AC09CD21EC` である。正規版、reference、既存build成果物への書き込みは行っていない。

以上で更新版要求の停止条件を満たした。次段階の最適化には進まない。
