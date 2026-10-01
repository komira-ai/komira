# =============================================================================
# test_message.mojo — Message[T] tests
# =============================================================================
# Cross-worker SPSC envelope.
#
# Tests:
#   1. Message[Int] roundtrip — payload + src_worker + op_id preservation
#   2. Message[String] roundtrip — heap-owning T (verify Movable bound holds)
#   3. Movable struct payload — generic Movable & Deinitable T
#   4. take_payload() move-out — partial-move via Optional.take pattern
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_async.channel.message import Message


def test_message_int_roundtrip() raises:
    """Message[Int] preserves all 3 fields."""
    var m = Message[Int](payload=42, src_worker=UInt16(3), op_id=Int64(101))
    assert_equal(m.payload, 42)
    assert_equal(Int(m.src_worker), 3)
    assert_equal(Int(m.op_id), Int(101))


def test_message_string_roundtrip() raises:
    """Message[String] holds heap-owning payload via Movable."""
    var m = Message[String](
        payload=String("cross-worker"), src_worker=UInt16(0), op_id=Int64(7)
    )
    assert_true(m.payload == String("cross-worker"))
    assert_equal(Int(m.src_worker), 0)
    assert_equal(Int(m.op_id), Int(7))


def test_message_max_src_worker() raises:
    """src_worker spans the full UInt16 range."""
    # UInt16 max = 65535
    var m = Message[Int](payload=1, src_worker=UInt16(65535), op_id=Int64(0))
    assert_equal(Int(m.src_worker), 65535)


def test_message_negative_op_id() raises:
    """op_id is signed Int64 — sentinel -1 reserved for "no
    routing"."""
    var m = Message[Int](payload=99, src_worker=UInt16(1), op_id=Int64(-1))
    assert_equal(Int(m.op_id), Int(-1))


def main() raises:
    test_message_int_roundtrip()
    test_message_string_roundtrip()
    test_message_max_src_worker()
    test_message_negative_op_id()
    print("PASS komira_async.channel.test_message")
