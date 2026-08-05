"""Production-firmware lifecycle smoke test; no PIO is activated here."""
import errno
from array import array
import shrike_parallel_c as c

# Some target MicroPython errno modules omit EBUSY; RP2040 returned OSError(16).
EBUSY = getattr(errno, "EBUSY", 16)

assert c.version() == "0.1.0-a4"
for name in ("dma_open", "transfer_dma", "dma_rearm", "dma_close", "dma_status", "dma_last_metrics"):
    assert hasattr(c, name), name
assert issubclass(c.ProtocolTimeout, c.ProtocolError)
assert issubclass(c.DMAError, c.ProtocolError)
assert issubclass(c.ProtocolError, Exception)

# Power-on equivalent: no owner record. This must not query channel -1.
power_on_status = c.dma_status()
assert power_on_status["state"] == "CLOSED"
assert power_on_status["tx_channel"] == -1
assert power_on_status["rx_channel"] == -1
assert power_on_status["tx_claimed"] is False
assert power_on_status["rx_claimed"] is False
c.dma_close()
tx, rx = c.dma_open(recover=False)
assert tx != rx
status = c.dma_status()
assert status["state"] == "IDLE" and status["claim_shape_consistent"]
# An accepted transfer attempt that fails validation clears all prior metrics
# without starting hardware or changing IDLE state.
try:
    c.transfer_dma(bytes((0,)), 0, bytearray(1), 1,
                   array("I", [0] * 67), array("I", [0] * 66), bytearray(2))
    raise AssertionError("invalid request length did not fail")
except ValueError:
    pass
assert c.dma_status()["state"] == "IDLE"
assert all(value == 0 for value in c.dma_last_metrics().values())
try:
    c.dma_open(recover=False)
    raise AssertionError("second open did not fail")
except OSError as exc:
    assert exc.args, exc
    assert exc.args[0] == EBUSY, exc.args
c.dma_close()
c.dma_close()
closed_status = c.dma_status()
assert closed_status["state"] == "CLOSED"
assert closed_status["tx_channel"] == -1
assert closed_status["rx_channel"] == -1
assert closed_status["tx_claimed"] is False
assert closed_status["rx_claimed"] is False
print("A4_LIFECYCLE_SMOKE=PASS HARDWARE_TRANSFER=NOT_RUN")
