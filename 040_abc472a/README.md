# ABC472A Shrike-Lite実装 / ABC472A Shrike-Lite Implementation

AtCoder Beginner Contest 472 A「A」を、Shrike-Lite実機へ実装した一式です。

SPI V3を使い、入力文字を1byteずつFPGAへ送りながら、1byte遅れで変換結果を受け取るストリーム処理にしています。

このフォルダには、実装コードだけでなく、シミュレーション、ForgeFPGA Workshopプロジェクト、bitstream、実機テストログ、実装時にCodexへ渡したWORK / PROMPT、参照用REFも含めています。

## 内容

- Shrike-Lite RTL（SPI V3）
- Icarus Verilog シミュレーション
- MicroPython 実機テスト・時間測定
- ForgeFPGA Workshop プロジェクト・タイミング制約
- Shrike-Lite実機用 bitstream
- 最終実機テストログ
- 実装時に参照した最小限のREF
- 実装・検証レポート
- Codexへ渡したWORK / PROMPT

実装内容・テスト結果・Synth / PNR・実機測定結果については、[`REPORT_abc472a.md`](REPORT_abc472a.md) を参照してください。

AIへの依頼内容を確認したい場合は、`WORK_abc472a.md`、`WORK2_abc472a.md`、`WORK3_abc472a.md` と対応する `CODEX_PROMPT*.txt` を参照してください。

---

## English

This directory contains the Shrike-Lite implementation of AtCoder Beginner Contest 472 A.

The design uses SPI V3 and performs a one-byte stream conversion: while the RP2040 sends input bytes over MOSI, it receives the previous conversion result over MISO with a one-byte delay.

Included materials:

- Shrike-Lite RTL using SPI V3
- Icarus Verilog simulation
- MicroPython hardware test and timing benchmark
- ForgeFPGA Workshop project and timing constraint
- Final Shrike-Lite bitstream
- Final hardware PASS log
- Minimal reference files used during implementation
- Implementation and verification report
- AI work specifications and Codex prompts

See [`REPORT_abc472a.md`](REPORT_abc472a.md) for implementation details, verification results, Synth / PNR results, and hardware timing measurements.
