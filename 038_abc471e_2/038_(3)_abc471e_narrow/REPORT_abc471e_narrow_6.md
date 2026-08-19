# ABC471E Narrow boundary_v4 代表点観測レポート

## 1. Executive Summary

`SPEC_abc471e_narrow_3.md` と `IMPL_abc471e_narrow_4.md` を正とし、途中停止された`WORK_REQUEST_abc471e_narrow_5.md`の`boundary_v4/`成果物を整理した。本WORKでは新規Icarus、Post-Synthesis、PNR、RTL変更を行っていない。

WORK_REQUEST_5は厳密な最大N_MAX探索を完了していない。保存済み成果物から、WIDTH=5..9の33候補にIcarus/Post-Synthesis、11候補にPNRが存在することを確認した。PLACE_FITかつPNR_COMPLETEだった保存済み観測点は次の5点である。

| WIDTH | MOD | N_MAX | Type=L | post-route | 50 MHz判定 |
|---:|---:|---:|---:|---:|---|
| 5 | 31 | 15 | 121/140 | 51.634 MHz | 達成 |
| 5 | 31 | 29 | 109/140 | 54.174 MHz | 達成 |
| 6 | 61 | 60 | 138/140 | 48.757 MHz | 未達 |
| 7 | 127 | 63 | 139/140 | 33.118 MHz | 未達 |
| 8 | 251 | 7 | 122/140 | 45.781 MHz | 未達 |

W5 N=29はWORK_REQUEST_5中断時に既に開始され、WORK_REQUEST_6開始前にログ取得まで終了していたrunである。W8 N=7も同様にWORK_REQUEST_6開始前の保存済み結果であり、本WORKで追加PNRしたものではない。

本結果は疎な観測点であって、WIDTH別の厳密な最大N_MAX表ではない。最重要の教訓は、logical LUT数、WIDTH、N_MAXの大小だけでは物理Type=L数を予測できず、実packing/placementの確認が必要という点である。

## 2. WORK_REQUEST_5を停止した理由

WORK_REQUEST_5は各WIDTHの最大PLACE_FIT N_MAXを探索する計画だった。しかし保存結果では、N_MAXを減らしてもPost-Synthesis LUTやType=Lが単調に減らなかった。

代表的にはW8で次の結果になった。

| N_MAX | COUNT_WIDTH | LUT | LUT lower bound | Type=L | 結果 |
|---:|---:|---:|---:|---:|---|
| 250 | 8 | 557 | 140 | 165 | PLACE_FAIL |
| 63 | 6 | 551 | 138 | 141 | PLACE_FAIL |
| 31 | 5 | 559 | 140 | 151 | PLACE_FAIL |
| 15 | 4 | 554 | 139 | 141 | PLACE_FAIL |
| 7 | 3 | 534 | 134 | 122 | PLACE_FIT / PNR_COMPLETE |

`63 -> 31 -> 15`とN_MAXを下げてもType=Lは`141 -> 151 -> 141`であり、単調ではない。従って、二分探索や少数点の補間では最大値を証明できず、1点ずつのmapping/packing揺らぎを測定する比重が大きくなった。人間判断で厳密境界探索を停止し、本WORKでは代表点観察へ目的を変更した。

## 3. 既取得成果物のinventory

`boundary_v4/wXX/nYYY/`を走査し、値は`config.json`、`icarus.log`、`resource_summary.json`、存在する場合のみ`forge_bitstream_log.txt`と`automation_result.json`から回収した。チャット途中報告を数値根拠には使用していない。

| WIDTH | 保存済みN_MAX | candidate数 |
|---:|---|---:|
| 5 | 1, 3, 7, 15, 29, 30 | 6 |
| 6 | 60 | 1 |
| 7 | 1, 3, 7, 15, 31, 63, 125, 126 | 8 |
| 8 | 1, 3, 7, 14, 15, 31, 63, 127, 250 | 9 |
| 9 | 1, 3, 7, 15, 31, 63, 127, 255, 508 | 9 |
| 合計 |  | 33 |

33候補すべてにIcarus PASSとPost-Synthesis成果物がある。最大問題世界の5候補はfull regression 42/42 PASS、tier候補はshort regression 22/22 PASSだった。PNR logがあるのは11候補、PLACE_FITは5候補、PNR_COMPLETEも同じ5候補だった。

全33点の値とsource artifactは次へ保存した。

- `boundary_v4/summary/observed_points.csv`
- `boundary_v4/summary/observed_points.json`

## 4. 代表観測点

| W | MOD | N_MAX | CW | VB | Icarus | LUT | FF | CARRY4 | LUT LB | Type=L | PLACE | ROUTE | timing stage | FMAX MHz |
|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|---|---|---|---:|
| 5 | 31 | 30 | 5 | 1 | 42/42 | 452 | 130 | 25 | 113 | 149 | FAIL | incomplete | post-LUT estimate | 12.020 |
| 5 | 31 | 29 | 5 | 1 | 22/22 | 441 | 130 | 25 | 111 | 109 | FIT | complete | post-route | 54.174 |
| 5 | 31 | 15 | 4 | 1 | 22/22 | 457 | 128 | 20 | 115 | 121 | FIT | complete | post-route | 51.634 |
| 6 | 61 | 60 | 6 | 1 | 42/42 | 508 | 141 | 25 | 127 | 138 | FIT | complete | post-route | 48.757 |
| 7 | 127 | 126 | 7 | 1 | 42/42 | 516 | 152 | 28 | 129 | 152 | FAIL | incomplete | post-LUT estimate | 11.365 |
| 7 | 127 | 63 | 6 | 1 | 22/22 | 533 | 150 | 25 | 134 | 139 | FIT | complete | post-route | 33.118 |
| 8 | 251 | 250 | 8 | 1 | 42/42 | 557 | 163 | 31 | 140 | 165 | FAIL | incomplete | post-LUT estimate | 11.324 |
| 8 | 251 | 63 | 6 | 1 | 22/22 | 551 | 159 | 28 | 138 | 141 | FAIL | incomplete | post-LUT estimate | 10.576 |
| 8 | 251 | 31 | 5 | 1 | 22/22 | 559 | 157 | 28 | 140 | 151 | FAIL | incomplete | post-LUT estimate | 10.133 |
| 8 | 251 | 15 | 4 | 1 | 22/22 | 554 | 155 | 23 | 139 | 141 | FAIL | incomplete | post-LUT estimate | 10.590 |
| 8 | 251 | 7 | 3 | 1 | 22/22 | 534 | 153 | 21 | 134 | 122 | FIT | complete | post-route | 45.781 |
| 9 | 509 | 508 | 9 | 2 | 42/42 | 663 | 184 | 41 | 166 | — | SCREEN_FAIL | NOT_RUN | NOT_RUN | — |

PLACE_FAIL行のMHzはpost-LUT-packing estimateであり、final timingではない。W9 N=508は`ceil(663/4)=166 > 140`のためsafe screeningで除外され、PNRは実行されていない。

## 5. WIDTH別の観測

### W5

N=30は452 LUT、lower bound 113に対して実packingは149 Type=Lで配置失敗した。N=15は457 LUTとlogical LUTが多いにもかかわらず121 Type=Lで配置配線を完了した。さらに中断時runのN=29は441 LUT、109 Type=L、post-route 54.174 MHzだった。

N=29とN=30はCOUNT_WIDTHがともに5であるにもかかわらず、Type=Lが109と149に分かれた。この差をN_MAX comparator、ABC9、packing、carry/control構造などの単一要因へ帰属させる根拠はない。

### W6

最大問題世界側のN=60が508 LUT、138 Type=Lで配置配線を完了した。post-routeは48.757 MHzで、容量上は成立したが50 MHz制約には届かなかった。

### W7

N=126は516 LUT、152 Type=Lで配置失敗した。縮小代表点N=63は533 LUTとlogical LUTが増えた一方、139 Type=Lで配置配線を完了した。logical LUTの大小と物理fitが逆転した例である。

### W8

N=250はcompact_v3 baselineを再現し、557 LUT / 163 FF / 31 CARRY4、165 Type=Lで配置失敗した。N=63、31、15もそれぞれ141、151、141 Type=Lで配置失敗した。WORK_REQUEST_6開始前に取得済みのN=7は122 Type=Lで配置配線を完了したが、N=8..14をPNRしていないため厳密最大値は確定していない。

### W9

N=508は663 LUT、lower bound 166でSCREEN_FAILだった。小さいtierも合成済みで、N=1は550 LUT、lower bound 138のPNR候補だがPNR未実施である。従って「W9は小さいN_MAXでもfitしない」とは言えない。

## 6. N_MAXとType=Lの非単調性

W8の`141 -> 151 -> 141`に加え、W5ではN=29の109 Type=LからN=30の149 Type=Lへ40 CLB変化した。Post-Synthesis LUTもW5で`N=15:457`、`N=7:436`、`N=3:448`となり非単調だった。

観測と両立する説明要素には次がある。

- COUNT_WIDTHの段差
- Yosys/ABC9 mapping
- carry-chain packing
- dual-LUT packing
- control/MUX形状
- placer geometry

ただし本成果物だけから支配要因を一つに断定しない。特にN=29と30は同じCOUNT_WIDTHなので、COUNT_WIDTHだけでは説明できない。

## 7. Post-Synthesis screeningと実PNRの差

`ceil(LUT/4) > 140`は物理fitの必要条件を満たさないためSCREEN_FAILに使用できる。一方、140以下はPNR候補でしかない。

具体例:

| candidate | LUT | ceil(LUT/4) | Type=L | 結果 |
|---|---:|---:|---:|---|
| W8 N=250 | 557 | 140 | 165 | PLACE_FAIL |
| W7 N=126 | 516 | 129 | 152 | PLACE_FAIL |
| W5 N=30 | 452 | 113 | 149 | PLACE_FAIL |
| W6 N=60 | 508 | 127 | 138 | PLACE_FIT |

W8 N=250はlower boundがちょうど140でも実際には165 Type=Lを要した。さらにW5 N=30はlower bound 113でも149 Type=Lだった。従って、logical LUT数やその4分の1を物理fit予測として使用するのは不十分である。

## 8. timing観測

PNR_COMPLETEした候補だけをfinal timingとして比較する。

| candidate | post-LUT estimate | post-placement | post-route | 50 MHz |
|---|---:|---:|---:|---|
| W5 N=15 | 12.837 | 53.743 | 51.634 | 達成 |
| W5 N=29 | 12.984 | 56.051 | 54.174 | 達成 |
| W6 N=60 | 12.966 | 54.732 | 48.757 | 未達 |
| W7 N=63 | 11.460 | 52.108 | 33.118 | 未達 |
| W8 N=7 | 10.610 | 50.633 | 45.781 | 未達 |

単位はMHz。50 MHzをpost-routeで満たした保存済み代表点はW5 N=15とW5 N=29である。WNS/TNSは保存されたForge GUI logに数値として存在しないため、summaryではnull/空欄とした。

## 9. 今回言えること / 言えないこと

### 言えること

1. W5..W9で最大問題世界側または縮小側のfit/fail観測点を得た。
2. W5 N=15/29、W6 N=60、W7 N=63、W8 N=7はPLACE_FITかつPNR_COMPLETEだった。
3. W5 N=30の149 Type=L FAILとW6 N=60の138 Type=L FITという逆転は保存logで再現確認できる。
4. W8のN_MAX縮小時、Type=Lは単調に減らなかった。
5. 50 MHzをpost-routeで満たした観測点が存在する。

### 言えないこと

1. 各WIDTHの厳密な最大PLACE_FIT/PNR_COMPLETE N_MAX。
2. 未測定点を補間した連続的な「実装可能境界」。
3. W8またはW9が他のN_MAXでfit/failするという一般化。
4. WIDTHまたはN_MAXとType=Lの単調関係。
5. このarchitectureの数学的・物理的最適境界。

本REPORTで「実装可能境界」という語を使える範囲は、保存済み点におけるFIT/FAILの観測、または「観測された実装可能性」に限る。点を結ぶ境界線や最大値の意味では使用しない。

## 10. W5/W6の逆転

W5 N=30は452 LUTとW6 N=60の508 LUTより小さいが、物理結果はW5が149 Type=LでFAIL、W6が138 Type=LでFITだった。従って「WIDTHまたはlogical LUTが小さいほど物理面積も必ず小さい」という期待は成立しない。

ただし両点ではWIDTHだけでなくMOD、N_MAX、COUNT_WIDTH、論理定数、mapping結果が異なる。原因をWIDTH単独とは解釈しない。

## 11. 未実施事項

- WORK_REQUEST_5の厳密最大探索は未完了のまま停止した。
- W7 N=125、W8 N=14、W9 N=1はPNR project準備物があるがForge logはなく、PNRはNOT_RUNである。
- W5 N=16..28、W7 N=64..124、W8 N=8..14などを連続確認していない。
- 新規候補のIcarus、合成、PNRをWORK_REQUEST_6では実施していない。
- graph、bitstream出力、flash、実機試験、timing optimizationを実施していない。

成功runのForge logには通常flow終端のgenericなBitstream Generator messageがあるが、project設定では全bitstream outputを無効化しており、各`automation_result.json`の`bitstream_files`は0件である。WORK_REQUEST_6ではForge自体を起動していない。

## 12. 再現成果物

新規summary:

```text
boundary_v4/summary/observed_points.csv
boundary_v4/summary/observed_points.json
boundary_v4/summary/build_observed_points.ps1
boundary_v4/summary/protection_work6_start.json
```

各rowの`SOURCE_ARTIFACT`に、根拠としたcandidate別config/resource/Icarus/Forge/automationの相対pathを記録した。summary生成scriptは既存成果物をread-onlyで走査し、候補directoryを書き換えない。

## 13. 保護対象確認と停止点

WORK_REQUEST_6開始時に主要文書とtree digestを`boundary_v4/summary/protection_work6_start.json`へ保存した。`boundary_v4`は`summary/`を除外した532 filesのdigestを取得し、既存候補をread-mostlyで扱った。

終了時の再照合結果は`boundary_v4/summary/protection_work6_end.json`へ保存した。全tree、18文書、`summary/`を除く既存boundary_v4 532 filesは開始時と一致し、summaryの33 keysには欠落source artifactがなかった。

本WORKの追加先は`boundary_v4/summary/`と本REPORTだけである。新規Icarus、Post-Synthesis、PNR、RTL変更、厳密最大探索へ進まず停止する。
