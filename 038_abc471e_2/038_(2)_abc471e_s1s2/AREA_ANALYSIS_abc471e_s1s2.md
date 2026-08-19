# ABC471E S1/S2 面積解析

## 1. Executive Summary

結論は次のとおりである。

1. **S1/S2化で消えたのは、ほぼ60 FFだけである。** Baseline V2からS1/S2への差分は、`FDCE -60`、LUT合計 `-11`、`MUXF7 +10`、CARRY4とFDPEは不変である。LUTとMUXF7を合わせた組合せprimitive数は `2132 -> 2131`、わずか1セル減である。総セル差 `3401 -> 3340` の61セルは、ほぼそのまま60 FF削減で説明できる。

2. **入力ごとの乗算回数半減は、物理multiplierを消していない。** 逐次multiplierはV2と同じ1個が残る。S1/S2版とV2で、multiplier内部の128 FF、直前next-state LUT構成、20 CARRY4は同一だった。1 Aiの実行時間は半減しても、回路の存在面積は減らない。

3. **multiplier operand MUXもほぼ小さくなっていない。** S1/S2版とV2はどちらも11個の乗算開始状態を持つ。S1/S2版のunique operand候補はLHS 9種類、RHS 9種類で、V2のLHS 8種類、RHS 9種類より少なくない。構造解析でも、`mul_lhs[29:0]`、`mul_rhs[29:0]`、`mul_start`の61 FF直前にあるlast-level LUTは両版とも62個だった。

4. **削除した60bitのnext-state MUXは減ったが、上流ロジックが増えて相殺した。** topの逐次always block由来FFの直前にあるunique combinational driverは `806 -> 748`、58個減った。一方、設計全体のLUT+MUXF7は1個しか減っていない。shared addからadd/subへの拡張、raw/reduced result選択、最終計算状態、operand選択、state decodeの再マッピングが、末端58セルの削減を上流でほぼ相殺した。

5. **S1/S2版の561 CLBは、現状ではほぼLUT site数に支配されている。** PNRは2114 CLB LUT siteを使用し、1 CLBあたり最大4 siteなので理論最小は `ceil(2114/4)=529 CLB` である。実際の561 CLBはこの下限より32 CLB多いだけである。Shrike-Liteの140 CLBへ入れるには、完全packingを仮定しても2114 siteを560以下へ、1554 site、73.5%削減する必要がある。

6. **FFもraw bit数ではなくpair-slot packingが問題である。** PNR前処理後の935 FFのうち、932 FFがlogic CLB、3 FFがIOBへ入った。logic側では823個のFF pair slotを占有し、second FFとして同居できたのは109個だけだった。140 CLBのpair slotは560なので、823 slotは147.0%である。`932 < 1120 raw FF bit capacity`だけを見てもfitは判断できない。

7. **最大の面積要因はmultiplier単体ではなく、広い状態レジスタ群とそのnext-state/control/operand MUX網である。** multiplier本体は強い構造推定で約139 LUT、128 FF、20 CARRY4である。top interfaceまで含めても約190～290 LUT、189 FF、20～26 CARRY4程度の圧力であり、2121 LUT全体の一部である。組合せ係数とFermat inverseだけで論理上337 FFを持ち、多数の30-bit sourceをmultiplierへ接続する。さらにprotocol、入力、最終計算を単一の大きい逐次always/caseで制御するため、flatten後に広いdecode/MUX網へ混ざっている。

したがって、`old_prefix`と`pair_sum`の削除効果が小さかった直接理由は、削除した2本が主としてFFであり、`x*old_prefix`は専用乗算器ではなく既存shared multiplierの時間利用だったこと、さらにS1/S2最終処理とadd/sub拡張が組合せMUXを追加したことである。

### 確度表記

本書では次の表記を使う。

- **直接確認**: report、PNR log、primitive直前のsource attribute、または明確なnetlist接続から得た値。
- **強い推定**: source attributeを持つFF/CARRYを境界にした浅い論理コーン、RTL register幅、V2との同一構造から得た値。
- **仮説**: source情報を失ったLUTの機能帰属や、hierarchical PNR reportなしでのCLB配分予想。

## 2. 使用した資料と解析方法

### S1/S2版

- `ffpga/src/main.v`
- `ffpga/src/spi_target.v`
- `ffpga/build/post_synth_report.txt`
- `ffpga/build/post_synth_results.v`
- `ffpga/build/netlist.edif`
- `hardware_logs/PNR_REPORT_abc471e_s1s2.md`
- `IMPL_abc471e_s1s2.md`
- `IMPLEMENTATION_REPORT_abc471e_s1s2.md`
- `SPEC_abc471e_s1s2.md`

### 比較対象

- `reference/abc471e_baseline_v2/ffpga/src/main.v`
- `reference/abc471e_baseline_v2/ffpga/build/post_synth_report.txt`
- `reference/abc471e_baseline_v2/ffpga/build/post_synth_results.v`
- `reference/abc471e_baseline_v2/IMPL_abc471e_baseline_v2.md`
- `reference/abc471e_baseline_v2/IMPLEMENTATION_REPORT_abc471e_baseline_v2.md`

### 解析方法

`post_synth_results.v`を読み、各primitive直前の `(* src = "..." *)` を抽出した。さらにprimitiveの入出力netを読み、次を集計した。

- source文字列別のprimitive数
- sourceが明確なFF/CARRY4のRTL行帰属
- multiplier内部FFを終点とする1～2段のcombination cone
- multiplier input register 61bitを終点とする1～2段のcone
- top shared add/sub CARRY4への直前入力cone
- top逐次FF直前のunique combinational driver
- MUXF7のselect sourceと逐次sink
- gate-level fanoutの上位net

解析は一時的な標準入力スクリプトだけで行い、解析用生成物はプロジェクト内へ残していない。合成、PNR、bitstream生成は再実行していない。

`netlist.edif`はPNR入力とinstance構成の確認に用いた。EDIFには元RTLのsource propertyが残っていないため、機能帰属は主にVerilog netlistを使用した。

## 3. V2 vs S1/S2比較

### Post-Synthesis

| primitive | Baseline V2 | S1/S2 | 差分 |
|---|---:|---:|---:|
| cells | 3401 | 3340 | -61 |
| CARRY4 | 121 | 121 | 0 |
| FDCE | 1000 | 940 | -60 |
| FDPE | 8 | 8 | 0 |
| FF合計 | 1008 | 948 | -60 |
| INV | 140 | 140 | 0 |
| LUT2 | 409 | 482 | +73 |
| LUT3 | 173 | 142 | -31 |
| LUT4 | 535 | 608 | +73 |
| LUT5 | 582 | 449 | -133 |
| LUT6 | 433 | 440 | +7 |
| LUT合計 | 2132 | 2121 | -11 |
| MUXF7 | 0 | 10 | +10 |
| LUT+MUXF7 | 2132 | 2131 | **-1** |

**直接確認:** cell差61は、FF差60と組合せprimitive差1でほぼ完全に説明できる。S1/S2化はregister削減としては成功したが、mapped combinational footprintは変わっていない。

### PNR

| 項目 | Baseline V2 | S1/S2 | 差分 |
|---|---:|---:|---:|
| Type=L Utilized | 571 | 561 | -10 |
| Logic CLB usage | 407.9% | 400.7% | -7.2 point |
| LUT usage | 385.2% | 377.5% | -7.7 point |
| FF usage | 157.1% | 147.0% | -10.1 point |

S1/S2 PNRの追加情報:

```text
2114 CLB LUT sites
  420 6-input LUT
  381 dual 5-input LUT
2495 logical LUT total in PNR representation

823 occupied CLB FF pair slots
109 additional dual-FFs
932 logic-CLB FFs
3 IOB FFs

121 CARRY4を含む621 instancesが128 CLBへcarry-chain packing
10 MUXF7 instancesがROM/MUXF packing段階で10 CLB追加
```

PNR前処理では13個のduplicate FFが削減された。合成948 FFから13を引いた935 FFは、logic CLBの932 FFとIOBの3 FFに一致する。

## 4. Post-Synthesis cell breakdownとpacking下限

S1/S2版の組合せprimitiveは次の構成である。

```text
LUT2..6 = 2121
MUXF7   =   10
CARRY4  =  121
INV     =  140
```

PNRの2114 CLB LUT siteから得られる絶対下限は529 CLBである。

```text
ceil(2114 / 4) = 529 CLB
actual         = 561 CLB
```

実際の値は理想LUT packing下限の約1.06倍である。このため、現在の561を主に説明するのは「packingが極端に悪い」ことではなく、「LUT siteが約4倍多い」ことである。ただしFF pair、carry chain、MUXF7、control set、routing localityが残り32 CLBとfit失敗の形を決めている。

140 CLBへ入る最大LUT site数は560である。

```text
2114 - 560 = 1554 site reduction required
1554 / 2114 = 73.5%
```

したがって、数十FFまたは数十LUTの局所最適化だけでは到達できない。

## 5. source attribute解析

### 5.1 直接帰属できた範囲

| source group | LUT2～6 | MUXF7 | CARRY4 | FDCE | FDPE | 確度 |
|---|---:|---:|---:|---:|---:|---|
| top逐次always `main.v:211-815` | 0 | 0 | 0 | 772 | 3 | 直接確認 |
| multiplier always `main.v:872-919` | 0 | 0 | 0 | 128 | 0 | 直接確認 |
| `spi_target.v`逐次block | 0 | 0 | 1 | 25 | 3 | 直接確認 |
| precise main arithmetic line | 0 | 0 | 112 | 0 | 0 | 直接確認 |
| user RTL sourceなし | 2121 | 10 | 8 | 15 | 2 | 直接確認 |

LUT2～6とMUXF7は、cell自身のsourceがすべてYosysの `lut_map.v` になっていた。したがって、source attributeだけからLUTをRTL行へ正確に割り当てることはできない。sourceを持たないLUTを無理に行単位へ配賦していない。

FFはtopの巨大な1個のalways block全体をsourceに持つため、cell sourceだけでは個々のregister名を区別できない。FF内訳はRTL幅と構造接続を併用した。

### 5.2 CARRY4の直接行帰属

| RTL機能 | RTL付近 | CARRY4 | 確度 |
|---|---:|---:|---|
| top add/sub raw sum | 130～131 | 8 | 直接確認 |
| top MOD比較 | 133 | 2 | 直接確認 |
| top MOD reduction | 134 | 8 | 直接確認 |
| `N-1` | 192 | 8 | 直接確認 |
| `K-1` | 194 | 8 | 直接確認 |
| N validation compare | 358 | 2 | 直接確認 |
| K validation compare | 385 | 3 | 直接確認 |
| `received_count>=N` | 413 | 3 | 直接確認 |
| `received_count+1` | 427 | 8 | 直接確認 |
| `x_raw>=MOD` | 516 | 2 | 直接確認 |
| `x_raw-MOD` | 517 | 8 | 直接確認 |
| `input_count+1` | 546 | 8 | 直接確認 |
| `comb_r`選択の32-bit算術 | 563 | 8 | 直接確認 |
| 同比較 | 563 | 3 | 直接確認 |
| `comb_i>comb_r` | 578 | 3 | 直接確認 |
| `comb_i+1` | 617 | 8 | 直接確認 |
| calc_state decode由来 | 675およびcase全体 | 2 | 直接確認、意味は一意化不能 |
| multiplier内部加算 | 866 | 8 | 直接確認 |
| multiplier内部MOD比較 | 868 | 2 | 直接確認 |
| multiplier内部MOD reduction | 869 | 8 | 直接確認 |
| multiplier `bit_count+1` | 915 | 2 | 直接確認 |
| SPI bit counter | `spi_target.v:93` | 1 | 直接確認 |
| source消失 | 不明 | 8 | 帰属不能 |

sourceを失った8 CARRY4は、他の32-bit arithmeticがすべて説明済みで、未帰属の `comb_factor_wide=comb_n-comb_r+comb_i` がちょうど32bitであること、V2にも同じ8個があることから、combination factor経路である可能性が高い。ただしcell sourceからの直接確認ではない。

## 6. 機能ブロック別面積推定

### 6.1 FFとCARRY4の非重複分類

RTL上のregister幅は合計951bitである。合成FFは948個なので、3bitがconstant化、統合、または不要化されたと考えられる。

| 分類 | 含めた主なregister | RTL bit | 全951bit比 | CARRY4 | CARRY確度 |
|---|---|---:|---:|---:|---|
| A. SPI/protocol | spi_target 27bit、tx/status/word assembly/proto state 51bit | 78 | 8.2% | 17 | 直接確認 |
| B. 入力S1/S2 | N/K、received/input count、x_raw/x_reg/x_busy、s1/s2 | 251 | 26.4% | 18 | 直接確認 |
| C. multiplier実質 | 本体128bit、mul_lhs/rhs/start 61bit | 189 | 19.9% | 20 | 本体は直接確認 |
| D. top add/sub | operandはcombinational | 0 | 0.0% | 18 | 直接確認 |
| E. 組合せ係数 | comb_n/r/i、numerator/denominator、3 coeff registers | 246 | 25.9% | 38直接 + 8推定 | 混在 |
| F. Fermat/pow | pow_result/base/exp/context | 91 | 9.6% | 0専用 | shared multiplierを利用 |
| G. 最終回答 | term_square、term_pair、answer | 90 | 9.5% | 0専用 | D/Cを利用 |
| H. calc control | calc_state | 6 | 0.6% | 2 | decode sourceは直接、意味は不確定 |
| 合計 |  | 951 | 100% | 121 |  |

AのCARRY4にはN/K validationとreceived counterを含めた。分類境界は概念上のもので、protocolとinputが同じtop alwaysにあるためLUTは共有される。

### 6.2 LUT/MUXの構造的な目安

| 分類 | netlistから得たLUT/MUX evidence | 確度 |
|---|---|---|
| A. SPI core | spi_target FFの2段以内に19 LUT + 1 CARRY4。top protocol decodeは別で帰属不能 | 強い推定の下限 |
| B. 入力S1/S2 | top next-state networkの一部。251 FFと18 CARRY4は明確だがLUTを分離不能 | FF/CARRY直接、LUT不明 |
| C. multiplier本体 | FF直前131 LUT、2段以内139 LUT + 19/20 CARRY4 | 強い推定 |
| C. top multiplier interface | FF直前62 LUT、2段以内147 LUT + 6 CARRY4。6 CARRYはshared feederを含む | 強い推定、非排他的 |
| D. top add/sub | core 18 CARRY4。core直前71 LUT + 23 INV。downstreamにMUXF7 10 | 強い推定 |
| E/F. combination/pow | 337 FF、最大の30/32-bit scratch群、multiplier候補の大半。LUT sourceは消失 | FF直接、LUTは仮説 |
| G. final | 90 FF。multiplierとadd/subを共有し専用CARRYなし | FF直接、LUTは共有 |
| H. wide control/decode | top FF直前のunique combinational driver合計748。高fanout decodeあり | 強い推定、各機能と重複 |

この表のLUT値は相互排他的ではなく、合計して2121へ合わせてはいけない。flatten/ABC9後は一つのLUTがstate decode、register enable、operand selectを同時に実現することがある。

## 7. shared modular multiplier解析

### 7.1 multiplier本体

multiplier内部のregisterは次の128bitである。

```text
o_busy       1
o_done       1
o_product   30
acc         30
addend      30
multiplier  30
bit_count    5
phase        1
----------------
total      128
```

source attributeで128個のFDCEすべてが `main.v:872-919`へ直接帰属した。V2も同じ128個である。

内部arithmeticのCARRY4は次の20個である。

```text
31-bit add       8
MOD compare      2
MOD subtract     8
bit_count + 1    2
------------------
total           20
```

multiplier FFのD/CEを終点に浅いconeを調べると、S1/S2とV2は完全に同じだった。

| cone | LUT2 | LUT3 | LUT4 | LUT5 | LUT6 | LUT計 | CARRY4 |
|---|---:|---:|---:|---:|---:|---:|---:|
| FF直前 | 4 | 2 | 90 | 5 | 30 | 131 | 0 |
| 2段以内 | 7 | 4 | 92 | 6 | 30 | 139 | 19 |

20個中1個のCARRY4は浅いD cone外にあり、source属性からmultiplier内部であることは確認できる。

**強い推定:** operand selectionを除くmultiplier本体は、おおよそ139 LUT、128 FF、20 CARRY4である。これは小さくはないが、全2121 LUT、948 FF、121 CARRY4の全てを支配する規模でもない。

### 7.2 top operand registerを含む実質コスト

接続から、multiplier内部D logicへ直接入るtop FFは61個だった。これはRTLの次と一致する。

```text
mul_lhs   30
mul_rhs   30
mul_start  1
------------
total     61
```

この61 FFの直前MUXは次のとおりである。

|  | last-level LUT | 2段以内LUT | 2段以内CARRY4 |
|---|---:|---:|---:|
| Baseline V2 | 62 | 139 | 6 |
| S1/S2 | 62 | 147 | 6 |

S1/S2版ではlast-level数は全く減らず、2段coneは8 LUT増えている。2段coneには組合せ係数算術やstate decodeとの共有logicも含むため、147 LUTをmultiplier専用と断定できない。

実用的な範囲としては次のように見るのが妥当である。

```text
multiplier本体のみ:
    約139 LUT, 128 FF, 20 CARRY4

top interfaceの最終段まで含む強い下限:
    約201 LUT, 189 FF, 20 CARRY4

shared feederの2段coneまで含む上側目安:
    約286 LUT, 189 FF, 20～26 CARRY4
```

上側目安は他ブロックとの重複を含む。この結果から、multiplierは重要な面積要因だが、単独で561 CLBを作っているわけではない。仮に実質multiplier全体を消しても、残りのLUT/controlだけで140 CLBを大幅に超える可能性が高い。

## 8. combination / Fermat inverse解析

### 8.1 常時存在するstorage

組合せ係数blockは246bitを持つ。

| register | bit |
|---|---:|
| comb_n / comb_r / comb_i | 96 |
| numerator / denominator | 60 |
| coeff_square / coeff_pair / coeff_pair_work | 90 |
| 合計 | 246 |

Fermat/pow blockは91bitを持つ。

| register | bit |
|---|---:|
| pow_result / pow_base / pow_exp | 90 |
| pow_context | 1 |
| 合計 | 91 |

合計337bitはRTL register全体の35.4%である。これらは乗算回数ではなく、常時FPGA上に存在するstorageである。

### 8.2 arithmeticとMUX

combination側は強い推定で46 CARRY4を持つ。

```text
N-1 / K-1                  16
comb_r用算術と比較          11
comb_i比較                   3
comb_i+1                     8
comb_factor 32-bit算術       8  (source消失、強い推定)
--------------------------------
total                        46
```

Fermat exponentiationはpowごとに新しいmultiplierを持たない。`pow_result*pow_base`と`pow_base*pow_base`は同じshared multiplierへ投入される。したがって「指数が30bitで計算回数が多い」こと自体は面積を30倍にしない。

一方、pow機能のために常時存在するものは次である。

- 91 FF
- `pow_exp==0`、`pow_exp[0]`、`pow_context`のdecode
- pow_result/baseをmultiplier sourceへ選ぶ30-bit経路
- result/base更新のnext-state MUX
- combination計算とpow計算を往復するcalc_state decode

numerator/denominator、pow_result/base、coeff registersが同じ61bit multiplier interfaceへ集まるため、係数/pow機能はoperand MUX網の主要な入力源である。

**強い推定:** 「組合せ係数/Fermatが最大容疑」という見方はstorageとcontrolの観点では支持される。ただしpow単体が専用巨大乗算器を複製しているわけではなく、最大要因は337 FFと、それらのnext-state/operand selection/decodeの合計である。

## 9. operand MUX解析

### 9.1 multiplier候補数

S1/S2版のunique sourceは次のとおりである。

```text
LHS 9種類:
    x_reg
    numerator
    denominator
    pow_result
    pow_base
    coeff_square
    coeff_pair_work
    s1
    coeff_pair

RHS 9種類:
    x_reg
    comb_factor_mod_value
    comb_i[29:0]
    pow_base
    pow_result
    k_minus_one_mod_value
    s1
    s2
    term_pair
```

乗算開始状態は11個である。V2も11個で、unique sourceはLHS 8種類、RHS 9種類だった。`x*old_prefix`を削除しても、S1平方と新しいfinal termがoperand候補へ加わったため、MUX選択条件数は減っていない。

### 9.2 add/sub候補数

|  | A unique source | B unique source | arithmetic state |
|---|---:|---:|---:|
| V2 shared add | 5 | 3 | 5 |
| S1/S2 shared add/sub | 4 | 5 | 5 |

S1/S2版はsource総数が減っていないうえ、`sub`、`reduce enable`、borrow correction、raw/reduced result選択を追加した。

top add/sub coreはV2とS1/S2でどちらも18 CARRY4だった。core直前のcombination coneは次のように変わった。

|  | LUT2 | LUT3 | LUT4 | LUT5 | LUT6 | LUT計 | INV |
|---|---:|---:|---:|---:|---:|---:|---:|
| V2 | 1 | 17 | 12 | 22 | 18 | 70 | 23 |
| S1/S2 | 3 | 15 | 9 | 15 | 29 | 71 | 23 |

個数はほぼ同じだが、S1/S2ではLUT6が11個増え、より複雑なinput functionへ再カットされている。

### 9.3 MUXF7 10個

10個すべてのMUXF7について接続を追跡した結果、次を直接確認した。

- selectはすべて `main.v:133` の `mod_arith_sum >= MOD` comparator出力。
- 各MUXF7はtop逐次always由来FFを1個ずつ駆動。
- multiplier operand interfaceの2段coneにはMUXF7は0個。

したがってMUXF7 10個はmultiplier operand MUXではなく、top shared add/subのraw/reduced resultと、その値を受ける広いregister next-state選択から生成されたものと判断できる。

PNRでもROM/MUXF packing段階で10 instancesが10 CLB追加している。最終packingで他logicとの同居は起きるが、局所packing制約を持つことは確認できる。

### 9.4 V2→S1/S2のLUT構成変化

top逐次FF直前のunique combinational driverは次のように変化した。

|  | LUT2 | LUT3 | LUT4 | LUT5 | LUT6 | MUXF7 | 合計 |
|---|---:|---:|---:|---:|---:|---:|---:|
| V2 | 201 | 4 | 147 | 259 | 195 | 0 | 806 |
| S1/S2 | 202 | 8 | 183 | 163 | 182 | 10 | 748 |
| 差分 | +1 | +4 | +36 | -96 | -13 | +10 | -58 |

60 FF削除に対応して末端next-state cellは58個減った。しかし設計全体ではLUT+MUXF7が1個しか減っていないため、上流coneは差し引き約57セル増えたことになる。

ABC9のLUT cutは非局所的であり、LUT2 `+73`、LUT4 `+73`、LUT5 `-133`を特定のRTL一行へ一対一対応させることはできない。ただし次の構造変化とは整合する。

- old_prefix/pair_sum 60 FFとその末端next-state MUXを削除。
- multiplier launch数と61bit interfaceは不変。
- finalにS1平方、pair subtraction、term 2乗算を追加。
- addからadd/subへ拡張し、raw/reduced bypassを追加。
- comparator出力が120 cell inputへfanoutし、10 MUXF7を生成。

## 10. FF 948個の内訳とpacking

### 10.1 logical storage内訳

| block | RTL bit | 主なwide register |
|---|---:|---|
| SPI/protocol | 78 | RX/TX shift、word assembly、status/proto |
| input S1/S2 | 251 | N/K/count 4本、x、S1/S2 |
| multiplier本体+interface | 189 | 内部128、lhs/rhs/start 61 |
| combination | 246 | 3x32bit + 5x30bit |
| pow | 91 | 3x30bit + context |
| final | 90 | term 2本 + answer |
| calc_state | 6 | binary encoded 35 states |
| 合計 | 951 | 合成後948 |

この分類ではcombination 246bitが最大で、input 251bitとほぼ同規模、powを合わせると337bitで最大グループになる。

### 10.2 PNR packing

合成948 FFからduplicate 13個が消え、PNR入力では935 FFとなった。

```text
logic CLB: 932 FF
IOB:         3 FF
total:     935 FF
```

logic CLB内の932 FFは、823 pair slot + 109 second FFとしてpackingされた。

```text
occupied pair slots = 823
available pair slots = 140 CLB * 4 = 560
823 / 560 = 147.0%
```

raw bit capacityは `140*8=1120 FF`だが、同じpairへ入れられたsecond FFは109個だけである。制御set、enable/reset、LUTとの接続、routing localityが異なるFFはpairにできない。このため「あと何bit消せば1120以下か」ではなく、occupied pair slotを263以上減らすか、dual packingを大幅に増やす必要がある。

現状ではLUT下限529 CLBの方がFF下限206 CLBより大きいため、FF単独が561の第一支配要因ではない。しかしLUTを大きく削減した後も、FF pair slotは140 CLB fitを妨げる第二の制約として残る。

## 11. CARRY4 121個の内訳

| block | CARRY4 | 根拠 |
|---|---:|---|
| SPI/protocol/count validation | 17 | source line直接帰属 |
| input normalize/count | 18 | source line直接帰属 |
| multiplier本体 | 20 | source line直接帰属 |
| top shared add/sub | 18 | source line直接帰属 |
| combination | 38 | source line直接帰属 |
| combination factor推定 | 8 | source消失、32-bit式から強い推定 |
| calc_state/global decode | 2 | sourceはcase、意味の一意化不能 |
| 合計 | 121 |  |

V2も同じ121個であり、対応する主要line群も同じ個数である。

入力乗算回数を2回から1回へ減らしても、multiplier内部の20 CARRY4は物理的に残る。top addはS1/S2でadd/subへ変わったが、V2のaddもsum、compare、MOD subtractで18 CARRY4をすでに使用しており、個数は変わらなかった。N/K/combination算術も変更していない。

したがって「時間利用回数が半分でも、shared arithmetic hardwareが残るためCARRY4が減らない」という理解はnetlistから直接支持される。

PNRでは621 instancesがcarry-chain packingにより128 CLBへ先に配置された。121 CARRY4だけで140 CLB容量に近いchain footprintを持つ。ただしcarry CLBの空きLUT/FFへ他logicを同居できるため、128と561を単純加算してはいけない。

## 12. high-fanout / control decode考察

PNR logは次を報告している。

```text
2420 nets
20 nets with fanout > 49
average fanout = 3.00
clock fanout = 355 CLBs
```

gate-level Verilogのcell input pinを数える方法では、clock/resetを除いてfanout 50超を24本検出した。PNR前処理のduplicate削減、net統合、CLB単位fanoutとは定義が異なるため20本と完全一致しない。

識別できた代表例:

| gate fanout | source/意味 | 確度 |
|---:|---|---|
| 948 FF pins | `clk` | 直接確認 |
| 948 FF pins | reset inverter出力 | 直接確認 |
| 506 cell inputs | sourceを失ったglobal LUT decode | 存在は直接、意味は帰属不能 |
| 162 cell inputs | multiplier内部FF 1bit | source直接、register名は消失。`phase`等のcontrol bitの可能性 |
| 154 cell inputs | sourceを失ったFF 1bit | 帰属不能 |
| 120 cell inputs | top add/sub MOD comparator、`main.v:133` | 直接確認 |
| 93～121 cell inputs | 複数のLUT decode | source消失 |
| 60 / 59 FF inputs | wide register bank共通enable相当 | 強い推定 |
| 59 cell inputs | calc_state case由来CARRY output | source直接、詳細意味は不明 |

特にfanout 120のMOD comparator出力は、10 MUXF7、40 LUT5、38 LUT4、32 LUT6へ入る。top add/sub result選択が局所的な30bit muxだけでなく、flatten後の広いnext-state networkへ混ざっている証拠である。

high fanout自体が必ずLUTを追加するわけではない。しかし次を通じてCLB利用へ影響する可能性がある。

- routing congestionと長い配線
- driver近傍へのsink clustering制約
- shared control setが合わないFFのpair packing悪化
- timing維持のためのLUT cut/replication
- wide register bank全体へ同じdecodeを配るLUT段数

PNRはpre-packing 4.329 MHz、design-rule packing後3.819 MHz、post-LUT-packing 10.534 MHzを報告したが、resource over-useでplacementが失敗したため、WNSやpost-route timingは得られていない。

## 13. 現在の最大面積要因ランキングと「561」の構成

### 13.1 netlist根拠に基づくランキング

1. **flattenされたwide next-state/control/MUX網**
   - 2121 LUT + 10 MUXF7。
   - top FF直前だけで748 unique combinational drivers。
   - LUT site下限529 CLBが実561 CLBをほぼ説明する。

2. **combination + Fermat/powの状態とoperand source**
   - 337 logical FF、強い推定でcombination arithmetic 46 CARRY4。
   - 30-bit sourceの大半をshared multiplierへ供給。
   - 計算回数ではなくstorage、decode、MUXが常在する。

3. **input/protocolのwide register bank**
   - A+Bで329 logical FF、35 CARRY4。
   - 32-bit word assembly、N/K/counter、x normalization、S1/S2がtop next-state網を形成。

4. **shared multiplier本体と61bit interface**
   - 約201 LUT以上、189 FF、20 CARRY4が強い下限。
   - 2段shared feederまで含めると約286 LUT相当だが、他機能と重複。

5. **top shared add/subとfinal datapath**
   - 18 CARRY4、core前71 LUT、10 MUXF7、final 90 FF。
   - V2からの新しいraw/reduced selectionがMUXF7とhigh fanoutを生成。

6. **SPI target単体**
   - 27 logical FF、浅いcone下限19 LUT + 1 CARRY4。
   - top protocolを含めると増えるが、全561の主因ではない。

### 13.2 561 CLBの概念的な範囲

hierarchical PNR reportがないため、以下は**仮説的な非排他レンジ**である。範囲は合計して561へ合わせるための数値ではない。

| 概念block | CLB pressure目安 | 主な根拠 |
|---|---:|---|
| SPI/protocol | 約40～70 | 78 FF、protocol decode、word/reply MUX |
| S1/S2 input | 約70～110 | 251 FF、18 CARRY、normalize/count |
| multiplier本体+interface | 約50～80 | 139～286 LUT cone、189 FF、20 CARRY |
| combination/pow + operand selection | 約150～220 | 337 FF、46 CARRY推定、主要operand source |
| top add/sub + final | 約40～70 | 71 LUT feeder、10 MUXF7、18 CARRY、90 FF |
| global decode/packing overlap | 約80～130 | 748 terminal drivers、高fanout、source消失LUT |

この表で最も重要なのは、multiplier単体を最大300 LUT程度と見ても、残り約1800 LUTが存在することである。561は単一犯ではなく、wide state banksを巨大なcase/decode/MUX網で接続した全体構造によって生じている。

## 14. 次に行う診断実験候補

今回は実装・合成しない。次回、同一tool flowで一つずつ差し替えてPost-Synthesis/PNR差分を取る案である。

| 優先 | 診断版 | 外すもの | 分かること | 外部仕様への影響 | 結果の解釈 |
|---:|---|---|---|---|---|
| 1 | coefficient/pow固定版 | `C_COMB_INIT`以降の係数計算、pow、関連scratchを固定係数へ置換 | E+F全体と、そのmultiplier MUX入力のaggregate cost | 一般N/Kで回答不正。SPI framingは維持可能 | 大幅減なら係数/pow/controlが主因。小幅ならglobal protocol/inputやmapper共有が主因 |
| 2 | powのみ除去版 | inverse結果を固定し、pow_result/base/exp/contextとpow statesを削除 | Fermat部分91 FFとpow MUX/decodeの純コスト | inverseが固定されるため一般回答不正 | 1との差がcombination逐次積、2単独差がpowコスト |
| 3 | multiplier本体dummy版 | 同じstart/done interfaceでproduct固定、operandを参照する版と参照しない版の2種 | 本体とtop operand MUXを分離 | 数学結果不正。protocol/timing handshakeは模擬可能 | operand参照版差=本体寄り、非参照版との差=operand MUX/61 FF寄り |
| 4 | SPI/protocol最小版 | RESET/START/statusと固定answerだけ残す | SPI target + protocol baseline | 計算機能を全面破壊 | 561との差が算術/状態全体。最小版自体が大きければprotocol再設計候補 |
| 5 | S1/S2 input-only版 | N/K/A受信、normalize、S1/S2更新だけ残し、S2等を返す | A+B+Dのinput datapath cost | ABC471E answerではなくなる | SPI最小版との差がstream input/normalize/S1/S2 cost |
| 6 | final-only固定入力版 | S1/S2と係数をconstant/register preloadし、final 3乗算+subだけ残す | GとD、およびfinal operand MUX増分 | 入力streamを無視 | input-only、coefficient-onlyとの差と合わせてshared block重複を推定 |

診断では必ず同じYosys/ABC9/PNR設定を使い、LUT総数だけでなくLUT2～6、MUXF7、CARRY4、FF、occupied FF pair slot、carry packing CLBを比較する。blockをconstant化するとoptimizerがupstream MUXまで消すため、「回路本体だけ」ではなく「その機能を支える全coneの削減量」として解釈する。

## 15. 今後の面積削減候補

実装は行わない。今回のnetlistから物理面積へ効く可能性が高い順である。

### 1. 組合せ係数方式とFermat inverseの構造変更

最有力。E+Fで337 FFを持ち、multiplier operand候補とstate decodeの大部分を作る。係数を外部から供給する、より少ないstate/storageで逐次生成する、2回のFermat inverseを避けるなど、係数計算全体を変える案だけが100 CLB級以上の削減へ届く可能性を持つ。

ただしアルゴリズム変更は機能・protocolとのtrade-offを伴う。まず診断版でaggregate costを測るべきである。

### 2. scratch register lifetime共有とcontroller分割

numerator/denominator、pow_result/base、coeff_pair_work、term registersには寿命が重ならない区間がある。30-bit bankを再利用できれば、FFだけでなく各bankのnext-state LUTも消せる可能性がある。

単純に1本へ集約するとoperand MUXを深くしてLUTを増やす危険がある。register数、last-level LUT、MUXF7、high fanoutを同時に測る必要がある。

### 3. N関連32-bit register/counterを18bitへ保持

`N_MAX=200000 < 2^18`なので、SPI validation後の次は18bitで保持できる可能性がある。

```text
n_reg, k_reg
received_count, input_count
comb_n, comb_r, comb_i
```

7本を32bitから18bitへすると、仕様のN_MAXを変えず理論上98 FFを削減でき、関連compare/add/subのCARRY4も短くなる。単独で140 CLBへは届かないが、netlist根拠の強い中規模候補である。

### 4. multiplier operand request構造の再設計

現在は61bitのregistered interfaceと、11 launch state、9x9 unique sourceを持つ。operation codeと2本の共有scratchからのみ供給するmicro-operation形式、またはcontrollerを局所化してglobal caseから切り離す案がある。

S1/S2化でlast-level LUT62が全く減らなかったため、この部分は明確な改善対象である。ただし直接combinational MUXへ変えるだけではタイミングとLUT depthが悪化し得る。

### 5. multiplier内部とtop add/subの31-bit arithmetic共有

top add/subに18 CARRY4、multiplier内部に20 CARRY4が別々に存在する。時間的にはtop add/subとmultiplier内部phaseを排他的に使用できる可能性があるため、同一coreへ統合できればCARRY4と周辺LUTを減らせる。

一方、既に121 CARRY4が128 CLBへpackされるため物理的価値はあるが、総LUTを73.5%減らす主施策ではない。追加operand MUXで相殺されるリスクが高く、診断合成が必要である。

### 6. top add/sub raw/reduced選択の簡素化

現在のMOD comparator出力はfanout 120で10 MUXF7を生成する。borrow correctionを別cycleへ完全に分離する、raw/reduced destinationを局所registerに限定するなど、global next-state網へresult selectを混ぜない構造が候補になる。

期待効果は中小規模だが、MUXF7とhigh fanoutの直接根拠がある。

### 7. protocol/state controlの局所化

topに1個の大きいalways blockと35-state calc FSMがあり、FF直前driver748個と複数の高fanout decodeを生成している。protocol、input arithmetic、combination/pow、finalを局所enable付きcontrollerへ分ける診断価値がある。

RTLを分割するだけでは合成結果が同じになる可能性があり、enable/control setを増やすとFF packingを悪化させる。構造化そのものではなく、operand候補と同時更新候補を減らすことが目的である。

### 8. SPI/protocol簡略化

SPI target単体は浅いcone下限19 LUT + 27 FFであり、最大要因ではない。外部仕様を壊す割に効果が小さい可能性が高いため優先度は低い。

### 9. MOD/input bit幅縮小またはN_MAX縮小の別実験

30-bit arithmetic、multiplier、全modular registerを同時に縮めるため、物理効果は大きい可能性がある。しかし現仕様を変更する別実験であり、S1/S2版の次の自動ステップとして行うべきではない。今回の調査では実装していない。

## 16. 不確実な点・追加データが必要な点

1. LUT2～6とMUXF7 cellのsource attributeはmapping libraryしか指さない。LUTのRTL行別正確値は取得不能だった。
2. top FFは巨大always block全体のsourceしか持たず、個々のs1、pow_base等をgate cell名から一意化できない。FF内訳はRTL幅による論理内訳である。
3. `autoname`後のnet名は最初のnamed netから連結された長い名前で、見た目の `spi_miso` / `spi_ss_n` prefixは機能帰属を意味しない。
4. sourceを失った8 CARRY4をcomb_factorへ帰属したのは強い推定であり、直接確認ではない。
5. multiplierとoperand MUXの2段coneは共有decode/arithmeticを含む。上側LUT値はexclusive countではない。
6. PNR reportはhierarchical block別CLBを出していない。Section 13のCLBレンジは仮説で、561への厳密な配賦ではない。
7. PNRはresource over-useでplacementに失敗したため、WNS、route congestion、post-route fanout replicationは不明である。
8. block別の確定値には、Section 14の診断版を同一tool version・同一constraintで合成し、差分を取る必要がある。

## 停止点

本調査では既存RTL、testbench、firmware、SPEC、IMPL、IMPLEMENTATION_REPORT、reference、build成果物を変更していない。ForgeFPGA WorkshopのLint・synthesis・PNR、bitstream生成、実機flash、実機試験、最適化実装は行っていない。

次の実作業としては、まず「coefficient/pow固定版」と「powのみ除去版」の2診断合成を行い、337 FFとそのMUX/decodeが実際に何CLBを占めるかを差分で確定するのが最も情報量が多い。
