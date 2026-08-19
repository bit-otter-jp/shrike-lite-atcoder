Applicable SPEC: SPEC_abc471e_narrow_2.md
Applicable IMPL: IMPL_abc471e_narrow_3.md

対象:
  compact_v3 W8 final
  WIDTH=8 / MOD=251 / N_MAX=250 / VALUE_BYTES=1

目的:
  RTLを一切変更せずPNRを実行し、
  Shrike-Lite Type=L 140へfitするか確認する。

事前確認:
  final RTL SHA-256一致
  Icarus 39/39 PASS
  Post-Synth 557 LUT / 163 FF / 31 CARRY4

禁止:
  RTL変更
  cleanup追加
  WIDTH変更
  SPEC/IMPL変更

実施:
  ForgeFPGAの通常flowでPNR
  utilization取得
  timing結果取得
  placer/router log保存

成功時:
  Type=L使用数
  timing
  utilization
  PNR成功をREPORT

失敗時:
  failure stage
  Type=L要求数またはplacer診断
  主要resource/packing情報
  をREPORTして停止

今回は:
  bitstream生成・flash・実機試験には進まない