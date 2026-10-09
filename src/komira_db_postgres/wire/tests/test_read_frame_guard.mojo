"""komira_db_postgres.wire: PgReadFrame.drain_complete yields after 1,000,000
messages.

NO NETWORK. `drain_complete` folds buffered messages in a loop bounded at
1,000,000 messages per call, so one call over a huge buffer returns False to
the caller instead of running unbounded (the caller then recvs; this test
only pins the bound of one call). The buffer holds 999,999
NoticeResponses, then one DataRow (the 1,000,000th message), then
ReadyForQuery. The first drain must fold exactly 1,000,000 messages: it
returns False (still pending, the terminal not reached) with the DataRow
folded (row_count 1); the second drain reaches ReadyForQuery. A bound below
1,000,000 leaves the DataRow unfolded after the first drain; a bound above it
(or none) reaches ReadyForQuery in the first drain.
"""

from std.testing import assert_equal, assert_true, assert_false

from komira_db_postgres.wire.pg_query_op import PgReadFrame
from komira_db_postgres.wire.pgwire import (
    put_i16_be,
    put_i32_be,
    MSG_DATA_ROW,
    MSG_NOTICE,
    MSG_READY,
)


def _wire() -> List[UInt8]:
    comptime NOTICES = 999_999
    var wire = List[UInt8](capacity=NOTICES * 5 + 7 + 6)
    for _ in range(NOTICES):
        wire.append(MSG_NOTICE)
        put_i32_be(wire, Int32(4))  # empty body
    # The 1,000,000th message: a zero-column DataRow.
    wire.append(MSG_DATA_ROW)
    put_i32_be(wire, Int32(6))
    put_i16_be(wire, Int16(0))
    wire.append(MSG_READY)
    put_i32_be(wire, Int32(5))
    wire.append(UInt8(ord("I")))
    return wire^


def test_drain_yields_at_bound() raises:
    var frame = PgReadFrame(List[UInt32](), List[String]())
    frame.feed(_wire())
    assert_false(frame.drain_complete(), "first drain stops at the bound")
    assert_true(frame.is_pending())
    assert_equal(
        frame.row_count(), 1, "the 1,000,000th message folds in the first drain"
    )
    assert_true(frame.drain_complete(), "second drain reaches ReadyForQuery")
    assert_true(frame.is_ready())
    assert_equal(frame.row_count(), 1)
    print("  [1] drain bound exactly 1,000,000 messages per call OK")


def main() raises:
    print("== komira_db_postgres.wire PgReadFrame drain bound ==")
    test_drain_yields_at_bound()
    print("== PASSED ==")
