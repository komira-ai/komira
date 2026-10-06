# =============================================================================
# test_kafka_golden_consumer_protocol.mojo — the ConsumerProtocol subscription
# and assignment blobs against independent reference bytes
# =============================================================================
#
# The blobs JoinGroup.Protocols[].Metadata and SyncGroup.Assignment carry.
# Each is an INT16 version followed by the data schema at that version
# (Apache Kafka tag 3.9.0, clients/src/main/resources/common/message/
# ConsumerProtocolSubscription.json and ConsumerProtocolAssignment.json; both
# are "flexibleVersions": "none"). Provenance and license: tests/GOLDENS.md.
#
# The codec decodes the subscription (version + Topics only), and both
# encodes (always version 0) and decodes the assignment, so the assignment is
# round-tripped: reference -> decode -> fields; fields -> encode -> reference.
#
# Truncation: both decoders stop before the blob's last field (UserData and
# OwnedPartitions for the subscription, UserData for the assignment), so a
# prefix that cuts only those trailing bytes is ACCEPTED. That is the codec's
# documented choice for the subscription and is reported for the assignment;
# the tests check that every prefix shorter than the end of the last field
# the decoder reads is refused, and leave the longer prefixes unasserted.
# TODO(kafka-goldens): assert those too if the decoders ever read UserData.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_kafka_server.wire.consumer_group import (
    decode_consumer_subscription,
    AssignedTopicPartitions,
    encode_consumer_assignment,
    decode_consumer_assignment,
)

# -----------------------------------------------------------------------------
# Golden plumbing (each welded test builds from its one file, so this block is
# repeated in every test_kafka_golden_*.mojo file).
# -----------------------------------------------------------------------------


def _nibble(c: UInt8) raises -> UInt8:
    if c >= 48 and c <= 57:  # '0'..'9'
        return c - 48
    if c >= 97 and c <= 102:  # 'a'..'f'
        return c - 87
    raise Error("golden: bad hex digit " + String(Int(c)))


struct _Golden(Movable):
    """Reference bytes written as hex, one schema field per `add` call."""

    var b: List[UInt8]

    def __init__(out self):
        self.b = List[UInt8]()

    def add(mut self, hex: String) raises:
        """Append the bytes spelled by `hex` (lower-case digits; spaces are
        ignored). An odd digit count is a typo in the golden: refuse it."""
        var s = hex.as_bytes()
        var digits = List[UInt8]()
        for i in range(len(s)):
            if s[i] != 32:
                digits.append(_nibble(s[i]))
        if len(digits) % 2 != 0:
            raise Error("golden: odd hex digit count in '" + hex + "'")
        for i in range(0, len(digits), 2):
            self.b.append((digits[i] << 4) | digits[i + 1])

    def bytes(self) -> List[UInt8]:
        return self.b.copy()


def _assert_bytes_eq(got: List[UInt8], want: List[UInt8], ctx: String) raises:
    for i in range(min(len(got), len(want))):
        if got[i] != want[i]:
            raise Error(
                ctx
                + ": first differing byte at offset "
                + String(i)
                + ": got "
                + String(Int(got[i]))
                + ", want "
                + String(Int(want[i]))
            )
    assert_equal(len(got), len(want), ctx + ": length mismatch")


def _every_prefix_refused(
    full: List[UInt8], decode: def (List[UInt8]) raises thin -> Int, ctx: String
) raises:
    """The decoder consumes the reference exactly, and refuses every strict
    prefix of it with the decoder's short-read error (never accepts one)."""
    assert_equal(decode(full), len(full), ctx + ": bytes consumed")
    for n in range(len(full)):
        var p = List[UInt8]()
        for i in range(n):
            p.append(full[i])
        var err = String("<accepted>")
        try:
            _ = decode(p)
        except e:
            err = String(e)
        assert_true(
            err.startswith("komira_kafka_server.wire: short read"),
            ctx + ": prefix of " + String(n) + " bytes: " + err,
        )


def _prefixes_refused_below(
    full: List[UInt8],
    limit: Int,
    decode: def (List[UInt8]) raises thin -> Int,
    ctx: String,
) raises:
    """Every prefix shorter than `limit` bytes is refused with the short-read
    error."""
    for n in range(limit):
        var p = List[UInt8]()
        for i in range(n):
            p.append(full[i])
        var err = String("<accepted>")
        try:
            _ = decode(p)
        except e:
            err = String(e)
        assert_true(
            err.startswith("komira_kafka_server.wire: short read"),
            ctx + ": prefix of " + String(n) + " bytes: " + err,
        )


# =============================================================================
# §1 — ConsumerProtocolSubscription.
# =============================================================================

# Byte offset just past Topics in both subscription references below.
comptime SUB_V0_TOPICS_END = 14
comptime SUB_V1_TOPICS_END = 10


def _sub_v0() raises -> List[UInt8]:
    var g = _Golden()
    g.add("0000")  # Version int16 = 0
    g.add("00000002")  # Topics []string length = 2
    g.add("0002 7431")  #   "t1"
    g.add("0002 7432")  #   "t2"   (offset 14 after this field)
    g.add("ffffffff")  # UserData nullable bytes = null
    return g.bytes()


def _sub_v1() raises -> List[UInt8]:
    var g = _Golden()
    g.add("0001")  # Version int16 = 1
    g.add("00000001")  # Topics []string length = 1
    g.add("0002 7431")  #   "t1"   (offset 10 after this field)
    g.add("00000002 abcd")  # UserData nullable bytes = ab cd
    g.add("00000001")  # OwnedPartitions array length = 1 (v1+)
    g.add("0002 7431")  #   [0] Topic string = "t1"
    g.add("00000001")  #   [0] Partitions []int32 length = 1
    g.add("00000000")  #     0
    return g.bytes()


def _decode_sub(b: List[UInt8]) raises -> Int:
    return len(decode_consumer_subscription(b).topics)


def test_subscription_v0() raises:
    var b = _sub_v0()
    var s = decode_consumer_subscription(b).copy()
    assert_equal(s.version, Int16(0))
    assert_equal(len(s.topics), 2)
    assert_equal(s.topics[0], "t1")
    assert_equal(s.topics[1], "t2")
    _prefixes_refused_below(
        b, SUB_V0_TOPICS_END, _decode_sub, "subscription v0"
    )


def test_subscription_v1() raises:
    var b = _sub_v1()
    var s = decode_consumer_subscription(b)
    assert_equal(s.version, Int16(1))
    assert_equal(len(s.topics), 1)
    assert_equal(s.topics[0], "t1")
    _prefixes_refused_below(
        b, SUB_V1_TOPICS_END, _decode_sub, "subscription v1"
    )


# =============================================================================
# §2 — ConsumerProtocolAssignment.
# =============================================================================

# Byte offset just past AssignedPartitions (before UserData).
comptime ASG_V0_PARTITIONS_END = 30


def _asg_v0() raises -> List[UInt8]:
    var g = _Golden()
    g.add("0000")  # Version int16 = 0
    g.add("00000002")  # AssignedPartitions array length = 2
    g.add("0002 7431")  #   [0] Topic string = "t1"
    g.add("00000002")  #   [0] Partitions []int32 length = 2
    g.add("00000000")  #     0
    g.add("00000002")  #     2
    g.add("0002 7432")  #   [1] Topic = "t2"
    g.add("00000000")  #   [1] Partitions length = 0   (offset 30 here)
    g.add("ffffffff")  # UserData nullable bytes = null
    return g.bytes()


def _decode_asg(b: List[UInt8]) raises -> Int:
    return len(decode_consumer_assignment(b))


def test_assignment_v0_round_trip() raises:
    var b = _asg_v0()
    var a = decode_consumer_assignment(b)
    assert_equal(len(a), 2)
    var a0 = a[0].copy()
    assert_equal(a0.topic, "t1")
    assert_equal(len(a0.partitions), 2)
    assert_equal(a0.partitions[0], Int32(0))
    assert_equal(a0.partitions[1], Int32(2))
    assert_equal(a[1].topic, "t2")
    assert_equal(len(a[1].partitions), 0)
    # Re-encode the decoded value: byte-identical to the reference.
    _assert_bytes_eq(encode_consumer_assignment(a), b, "assignment v0")
    _prefixes_refused_below(
        b, ASG_V0_PARTITIONS_END, _decode_asg, "assignment v0"
    )


def test_assignment_v0_from_fields() raises:
    var parts = List[Int32]()
    parts.append(Int32(0))
    parts.append(Int32(2))
    var assigned = List[AssignedTopicPartitions]()
    assigned.append(AssignedTopicPartitions("t1", parts^))
    assigned.append(AssignedTopicPartitions("t2", List[Int32]()))
    _assert_bytes_eq(
        encode_consumer_assignment(assigned), _asg_v0(), "assignment v0 (fields)"
    )


def main() raises:
    test_subscription_v0()
    test_subscription_v1()
    test_assignment_v0_round_trip()
    test_assignment_v0_from_fields()
    print("test_kafka_golden_consumer_protocol: OK")
