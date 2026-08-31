# WORK6_abc472b.md

## 目的

WORK5で、37.5 MHz Timing PASS済みproduction bitstreamを使った実機試験により、

```text
PASS=20 FAIL=92 TOTAL=112
```

となった。

最優先case:

```text
best_at_first_cut = [100, 1, 1]
expected = 98
```

は、

```text
A1: resetなし連続  0 PASS / 20 FAIL
A2: 毎回reset      0 PASS / 20 FAIL
B1: input 4MHz / answer 4MHz  0 PASS / 10 FAIL
B2: input 2MHz / answer 4MHz  0 PASS / 10 FAIL
B3: input 4MHz / answer 2MHz  0 PASS / 10 FAIL
B4: input 2MHz / answer 2MHz  0 PASS / 10 FAIL
```

で再現した。

raw MISOのdummy byteは全112件で`0x00`であり、
代表PASS caseは全速度条件でPASSしている。

したがってWORK5では、

**単純なSPI速度marginや256byte burst境界だけでは説明できず、入力組立～DistRAM write/read～CALC FSM～answerまでの内部経路を実機で観測する必要がある**

と判断して停止した。

WORK6の目的は、

# **実機で誤答が生じる原因を特定すること**

である。

---

# 1. 作業場所

主作業フォルダ:

```text
<workspace>
```

Shrike-LiteのUSBストレージとして現在使用されているドライブ:

```text
E:\
```

今回Codexは、

**上記作業フォルダ内とEドライブ内では、原因調査に必要なファイル作成・変更・コピー・削除・実行を広く許可する。**

ただし、Eドライブが本当に今回対象のShrike-Lite用ストレージであることを、
既存`abc472b.bin`、容量、ドライブ情報等から開始時に確認すること。

別ドライブを推測で操作しない。

---

# 2. 自由度

WORK6では、WORK5までよりCodexの自由度を上げる。

原因調査に有効と判断した場合、作業フォルダ内で以下を行ってよい。

- debug専用RTLの追加・変更
- `main.v`のdebug variant作成
- 必要ならproduction RTLの一時変更
- debug専用`spi_target.v` variant作成
- telemetry protocolの追加
- debug用MicroPythonの追加・変更
- Icarus testbenchの追加
- ForgeFPGA WorkshopのSynth / PNR / bitstream生成
- PLL / SDCのdebug用変更
- 内部clockの変更
- FF版 / DistRAM版 / 別RAM構成との比較
- 特定信号の固定
- 部分回路のbypass
- shadow register追加
- internal state dump
- readback機構追加
- caseを固定した最小回路作成
- その他、原因切り分けに合理的な実験

**「この方法で調べなければならない」という固定手順は設けない。**

Codexは実際の観測結果を見て、
次の実験を自分で選んでよい。

ただし、各実験で何を変えたかと結果は必ず記録する。

---

# 3. production baselineを失わない

自由に実験してよいが、WORK4 / WORK5時点のproduction状態を失わないこと。

開始時に最低限、

```text
ffpga/src/main.v
ffpga/src/spi_target.v
abc472b.ffpga
ffpga/timing-constraints/atcoder_spi_template_v3.sdc
firmware/micropython/abc472b_test.py
37.5 MHz production bitstream
```

のhashを確認する。

必要なら、

```text
debug_work6/baseline/
```

へコピーしてよい。

実験後にproductionへ戻せる状態を確保する。

`REF/`は基本的に参照用として扱い、
原因調査のために書き換える必要がない限り変更しない。

---

# 4. WORK5の最重要観測候補

WORK5で挙げた内部観測候補は次の通り。

```text
受信確定時:
    rx_data_strobe
    rx_data
    n_reg
    length_byte_index
    lengths_received

書込時:
    received_length
    lengths_write_enable
    lengths_write_address
    lengths_write_data
    total_sum

CALC時:
    state
    calc_address
    lengths_read_enable
    lengths_read_address
    lengths_read_data

候補評価時:
    prefix_sum
    prefix_after_read
    right_after_read
    current_diff
    best_diff
    best_after_evaluate

回答時:
    answer
    reply_byte_index
    tx_data
```

最優先case `[100, 1, 1]`なら、正常時には概ね次が見えるはず。

```text
N = 3

write:
addr0 = 100
addr1 = 1
addr2 = 1
total = 102

candidate 0:
read = 100
prefix_after_read = 100
right_after_read  = 2
current_diff      = 98
best              = 98

candidate 1:
read = 1
prefix_after_read = 101
right_after_read  = 1
current_diff      = 100
best              = 98

answer = 98
```

これらを全て一度に観測する必要はない。

**原因を最短で分離できる観測点をCodexが選んでよい。**

---

# 5. 特に疑う領域

WORK5までの結果から、優先度が高いのは、

```text
3byte入力組立
  ↓
DistRAM write
  ↓
DistRAM read
  ↓
CALC
  ↓
answer
```

である。

ただし、原因をDistRAMへ決め打ちしない。

Icarusでは524ケースPASSしているが、
実機でのみFAILしている。

WORK4では、

```text
RAM64X1D ×34
Type=M 34/40
```

へ実推論されている。

そのため、

- behavioral RAM modelと実primitiveの差
- write/read timing
- read address / output timing
- physical primitive mapping
- CALCとの境界

は有力候補だが、
入力組立や別の実機依存要因も残っている。

観測結果に応じて優先順位を変更してよい。

---

# 6. 有効そうな実験例

以下は候補であって必須ではない。

## 6.1 内部telemetry

`[100,1,1]`だけを対象に、
書込値 / 読出値 / CALC値をSPIで順番に返す。

## 6.2 DistRAM readback

CALC前に、

```text
RAM[0]
RAM[1]
RAM[2]
```

を直接readbackして、

```text
100
1
1
```

になっているか確認する。

## 6.3 shadow register比較

DistRAMへwriteすると同時に、
debug用FFにも同じ値を保持し、

```text
DistRAM read
vs
shadow FF
```

を比較する。

## 6.4 FF版との比較

N=3固定またはN小規模だけでよいので、
DistRAMを使わないdebug版を作り、
同じ実機caseがPASSするか比較する。

これでDistRAM領域を大きく切り分けられる。

## 6.5 CALC bypass

RAM read値をそのまま返す、
または固定式で`98`を作るなど、
回答経路だけを分離する。

## 6.6 post-synth / primitive simulation

有効なら、
post-synth netlistやRAM64X1D primitiveモデルを使った確認を行ってよい。

## 6.7 clock変更

debug目的で内部clockを変えてよい。

ただしproduction周波数変更ではなく、
原因切り分け実験として扱う。

---

# 7. bitstream生成から実機まで自動化してよい

WORK6では、

**debug RTL生成 → Synth / PNR → bitstream生成 → Eドライブ配置 → Thonny実行 → 実機ログ回収**

までCodexが自動化してよい。

ForgeFPGA WorkshopはWORK4までに自動操作実績があるため、
可能ならその経路を再利用する。

ThonnyはWORK5で、

```text
script open
F5
Shell回収
```

まで自動化できた。

今回もその経路を再利用してよい。

---

# 8. Eドライブへのbitstream配置

WORK5開始時には、

```text
E:\abc472b.bin
workspace bitstream/abc472b.bin
WORK4 FPGA_bitstream_MCU.bin
```

のhash一致を確認できている。

WORK6ではdebug bitstreamをEドライブへ配置してよい。

推奨:

```text
E:\abc472b_debug_work6.bin
```

または実験番号付き名称。

MicroPython側の`BITSTREAM`もdebug用名称へ合わせてよい。

必要なら既存、

```text
E:\abc472b.bin
```

を上書きしてもよいが、
その場合は必ず元production bitstreamのhashとバックアップを保持する。

**Eドライブ全体のformat、partition変更、無関係ファイルの大量削除は行わない。**

コピー後は可能なら、

```text
source hash
E:\ destination hash
```

の一致を確認する。

---

# 9. Shrike-LiteへのflashもCodexが試す

debug MicroPythonから、

```python
shrike.flash(...)
```

を使い、
Eドライブへ配置したdebug bitstreamをShrike-Liteへflashしてよい。

可能なら、

```text
ForgeFPGA
↓
bitstream生成
↓
E:\へコピー
↓
Thonny
↓
shrike.flash()
↓
debug case実行
↓
Shell回収
```

を人間操作なしで完結させる。

これが成功した場合、
**WORK6の重要な副成果としてREPORTへ記録する。**

---

# 10. 実験管理

原因調査は複数回になる可能性があるため、

```text
debug_work6/
```

配下へ実験ごとの記録を残すことを推奨する。

例:

```text
debug_work6/
├─ exp01_ram_readback/
├─ exp02_shadow_ff/
├─ exp03_ff_only/
├─ logs/
└─ baseline/
```

命名はCodexが合理的に決めてよい。

各実験について最低限、

```text
目的
変更点
bitstream
実機case
結果
解釈
次に何を試すか
```

を残す。

REPORT本文へ全ログを貼る必要はない。

---

# 11. Timingの扱い

debug RTLはproductionとは異なるため、
Resource / Timingも変わる可能性がある。

実機へflashするdebug bitstreamは、
原則としてその設定clockでTiming PASSしたものを使用する。

ただし、

**原因切り分けのためにclockを十分低くしたdebug構成**

を作ることは許可する。

Timing FAILしたbitstreamを実機へ書く場合は、
それが意図的なdebug実験であり、
危険性が低く、結果解釈に意味がある場合だけにする。

基本はTiming PASSを優先する。

---

# 12. 原因を見つけた後

原因が特定できた場合は、

1. 根拠となる実機観測を保存
2. 原因を説明
3. 最小修正案を作る
4. 必要なら修正版RTLを実装
5. Icarus
6. Synth / PNR
7. bitstream
8. Eドライブ配置
9. Thonny実機試験

まで進めてよい。

WORK6では、

**原因特定後の修正・再検証までCodex自身の判断で進めてよい。**

ただし、原因が確定していない状態で大量のRTL変更を重ね、
どの変更で直ったのか分からなくすることは避ける。

可能な限り1実験1仮説で進める。

---

# 13. production修正版

原因を特定し、修正が妥当と判断できた場合は、
最終的にproduction RTLへ修正を反映してよい。

その場合は必ず、

- baselineとの差分
- なぜ必要だったか
- Icarus結果
- Synth / PNR結果
- DistRAM推論状態
- Timing
- 実機テスト
- production bitstream hash

を記録する。

修正後もDistRAMを維持する必要はない。

もし原因がDistRAMそのもの、またはこのデバイスでの使い方にあるなら、
別実装を採用してよい。

ただし面積・Timing・機能結果を比較して判断する。

---

# 14. Thonny / COM6

WORK5でThonny自動操作は成功した。

WORK6では必要に応じて、

- Thonny GUI経由
- Thonny backend制御
- COM6直接アクセス

のどれを使ってもよい。

ただし同時に複数プロセスでCOM6を奪い合わないこと。

Thonny backendがCOM6を保持している場合は、
安全に停止 / 再開できる方法を調査してよい。

Thonnyを終了・再起動してもよい。

---

# 15. 作業範囲外

以下は原則行わない。

- <workspace> と E:\ 以外のユーザーファイル変更
- 他プロジェクトの変更
- OS設定の恒久変更
- ドライブformat / partition操作
- Firmware書換など復旧困難なハードウェア変更
- AtCoder提出
- Git push / tag / release

Gitのread-only確認やdiff確認は行ってよい。

---

# 16. 停止条件

WORK6は原因調査なので、過度に早く停止しない。

次の場合は停止する。

- Shrike-Liteが認識されなくなり復旧方法が不明
- Eドライブが対象デバイスか確認できない
- データ消失やハードウェア損傷の恐れがある
- 作業フォルダ / Eドライブ外の大規模変更が必要
- 原因候補がハードウェア故障へ及び、安全な追加検証方法がない
- 合理的な実験を複数行っても原因領域をこれ以上狭められない
- 人間の判断がないと次の実験が危険または不可逆

停止条件に達しても、

**REPORT_WORK6_abc472b.mdは必ず作成する。**

---

# 17. REPORT

WORK6の結果は独立して、

```text
REPORT_WORK6_abc472b.md
```

へ記録する。

他のREPORTへ追記しない。

最低限:

- WORK5からの開始条件
- baseline hash
- 実施した実験一覧
- 各実験の目的 / 変更 / 結果 / 解釈
- 内部観測値
- 原因特定結果
- 原因が未確定なら残る候補
- debug RTL / telemetry方法
- ForgeFPGA自動実行状況
- Eドライブbitstream配置状況
- hash確認
- Thonny自動実行状況
- Shrike-Lite flash自動化結果
- 修正した場合はproduction差分
- Icarus結果
- Synth / PNR / Timing / Resource
- 実機試験結果
- 作成ファイル
- 未実施項目
- 次に必要な作業

を記載する。

未確認値を推測で埋めない。

---

# 18. 完了条件

理想的な完了:

```text
実機FAIL再現
↓
内部観測
↓
原因特定
↓
最小修正
↓
Icarus PASS
↓
Synth / PNR / Timing PASS
↓
bitstream生成
↓
Eドライブ配置
↓
Shrike-Lite flash
↓
Thonny実機テスト PASS
```

ここまで自動で到達できれば完了。

原因特定までで修正が大きくなる場合は、
原因と修正方針を明確にして停止してもよい。

---

# 19. 完了報告

最後は簡潔に、

- 原因
- 根拠
- 何を変更したか
- debugで最も決定的だった観測
- Icarus
- Synth / PNR / Timing
- 実機結果
- Eドライブコピー自動化
- Shrike-Lite flash自動化
- Thonny実行自動化
- productionの最終状態
- REPORT_WORK6_abc472b.md

を報告する。
