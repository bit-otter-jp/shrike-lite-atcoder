from machine import Pin, SPI
import time
import shrike

# ===== 共通部分：bitstream名とShrike-Liteのピン設定 =====
BITSTREAM = "atcoder_spi_template_v2.bin"

SCK = 2
CS = 1
MOSI = 3
MISO = 0
FPGA_RESET = 14

# ===== 共通部分：FPGAへのbitstream書き込みとリセット =====
shrike.reset()
shrike.flash(BITSTREAM)

reset_pin = Pin(FPGA_RESET, Pin.OUT, value=1)
reset_pin.value(0)
time.sleep_ms(100)
reset_pin.value(1)
time.sleep_ms(100)

# ===== 共通部分：SPI Masterの初期化 =====
cs = Pin(CS, Pin.OUT, value=1)

spi = SPI(
    0,
    baudrate=1_000_000,
    polarity=0,
    phase=0,
    bits=8,
    firstbit=SPI.MSB,
    sck=Pin(SCK),
    mosi=Pin(MOSI),
    miso=Pin(MISO)
)


# ===== 共通部分：1byteのSPI送受信 =====
def spi_exchange(value):
    tx = bytes([value])
    rx = bytearray(1)

    cs.value(0)
    spi.write_readinto(tx, rx)
    cs.value(1)

    return rx[0]


# ===== 問題ごとに変更する部分：入力データと期待値の確認 =====
# 今回は「受信値に1を加えて次回返す」回路をテストする。
patterns = [0x00, 0x12, 0x7F, 0xFF]
expected_rx = 0x00

for value in patterns:
    received = spi_exchange(value)

    result = "PASS" if received == expected_rx else "FAIL"

    print(
        "TX=0x{:02X} RX=0x{:02X} EXPECT=0x{:02X} {}".format(
            value,
            received,
            expected_rx,
            result
        )
    )

    # 問題固有の期待値計算
    expected_rx = (value + 1) & 0xFF
    time.sleep_ms(100)

# 問題固有の後処理：最後に送った0xFFの処理結果を読み出す
received = spi_exchange(0x00)
result = "PASS" if received == expected_rx else "FAIL"

print(
    "TX=0x00 RX=0x{:02X} EXPECT=0x{:02X} {}".format(
        received,
        expected_rx,
        result
    )
)