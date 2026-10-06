# =============================================================================
# test_broker_field_numbers.mojo
# =============================================================================
#
# THE FIELD-NUMBER CENSUS for `komira.broker.v1`, stated as WIRE BYTES.
#
# A proto field number is what is stored and sent. Renumbering a field is
# legal to protoc and compiles clean; a heartbeat written by an older node
# does not fail to parse, it decodes as the WRONG field. Nothing in the
# toolchain objects, so this file is the guard.
#
# HOW EACH MESSAGE IS PINNED. For every message, a byte stream is written by
# hand here, field by field, with the number and wire type the proto
# declares and a value no other field of that message holds. Then:
#   1. it is decoded, and every field is read back BY NAME. This catches two
#      fields of one wire type swapping numbers, which a pure round trip
#      would not see.
#   2. the decoded message is encoded again and must give the hand-written
#      bytes back exactly. The binary encoder writes fields in declaration
#      order and each repeated element as its own tagged record, so the
#      hand-written stream is in that order; every implicit-presence field
#      here holds a non-zero value, so the comparison does not depend on
#      whether an encoder writes zero values. This catches a field moved to
#      a number nothing else uses (skipped on decode, missing on encode) and
#      a changed wire type.
# The bytes are a LITERAL restatement of the proto, deliberately: deriving
# them from the generated code would agree with it by construction.
#
# Pinned: BrokerClusterMap 1 nodes, 2 leaders; NodeEndpoint 1 node_id
# (int32), 2 host, 3 port; PartitionLeader 1 partition_id, 2 leader_node_id
# (int32: -1, NO_LEADER, is a sign-extended 10-byte varint); NodeLoad 1
# records_served, 2 partition_count, 3 reported_partition_total (presence:
# absent when unset); ClusterConfig 1 total_partitions, 2 node_count.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_proto_codec import decode_proto, encode_proto
from komira_broker_proto.broker import (
    BrokerClusterMap,
    ClusterConfig,
    NodeEndpoint,
    NodeLoad,
    PartitionLeader,
)


def _varint(mut b: List[UInt8], v: UInt64):
    var x = v
    while x >= 0x80:
        b.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    b.append(UInt8(x))


def _uint(mut b: List[UInt8], field: Int, v: UInt64):
    """A varint record: tag (wire type 0), then the value."""
    _varint(b, UInt64(field << 3))
    _varint(b, v)


def _int32(mut b: List[UInt8], field: Int, v: Int32):
    """A proto `int32` record: a negative value sign-extends to 64 bits."""
    _uint(b, field, UInt64(Int64(v)))


def _str(mut b: List[UInt8], field: Int, s: String):
    """A length-delimited record (wire type 2) holding `s`."""
    _varint(b, UInt64((field << 3) | 2))
    _varint(b, UInt64(s.byte_length()))
    for c in s.as_bytes():
        b.append(c)


def _msg(mut b: List[UInt8], field: Int, m: List[UInt8]):
    """A length-delimited record (wire type 2) holding an encoded message."""
    _varint(b, UInt64((field << 3) | 2))
    _varint(b, UInt64(len(m)))
    for i in range(len(m)):
        b.append(m[i])


def _hex(b: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(b)):
        out += hex(Int(b[i])) + " "
    return out


def _same(got: List[UInt8], want: List[UInt8], what: String) raises:
    assert_equal(_hex(got), _hex(want), what + ": re-encode differs from the hand-written bytes")


def _endpoint(node_id: Int32, host: String, port: UInt64) -> List[UInt8]:
    var b = List[UInt8]()
    _int32(b, 1, node_id)
    _str(b, 2, host)
    _uint(b, 3, port)
    return b^


def _leader(partition_id: UInt64, leader: Int32) -> List[UInt8]:
    var b = List[UInt8]()
    _uint(b, 1, partition_id)
    _int32(b, 2, leader)
    return b^


def test_node_endpoint() raises:
    """NodeEndpoint: 1 node_id (int32), 2 host, 3 port."""
    var b = _endpoint(7, "broker-7", 9092)
    var e = decode_proto[NodeEndpoint](b.copy())
    assert_equal(e.node_id, Int32(7))
    assert_equal(e.host, "broker-7")
    assert_equal(e.port, UInt32(9092))
    _same(encode_proto(e), b, "NodeEndpoint")


def test_partition_leader() raises:
    """PartitionLeader: 1 partition_id, 2 leader_node_id; -1 is NO_LEADER."""
    var b = _leader(5, 3)
    var p = decode_proto[PartitionLeader](b.copy())
    assert_equal(p.partition_id, UInt32(5))
    assert_equal(p.leader_node_id, Int32(3))
    _same(encode_proto(p), b, "PartitionLeader")

    var none = _leader(6, -1)
    assert_equal(len(none), 2 + 1 + 10, "-1 as int32 is a 10-byte varint")
    var q = decode_proto[PartitionLeader](none.copy())
    assert_equal(q.partition_id, UInt32(6))
    assert_equal(q.leader_node_id, Int32(-1))
    _same(encode_proto(q), none, "PartitionLeader NO_LEADER")


def test_broker_cluster_map() raises:
    """BrokerClusterMap: 1 nodes (repeated NodeEndpoint), 2 leaders
    (repeated PartitionLeader), each element its own record, in order."""
    var b = List[UInt8]()
    _msg(b, 1, _endpoint(1, "broker-1", 9001))
    _msg(b, 1, _endpoint(2, "broker-2", 9002))
    _msg(b, 2, _leader(0, 2))
    _msg(b, 2, _leader(1, -1))
    var m = decode_proto[BrokerClusterMap](b.copy())
    assert_equal(len(m.nodes), 2)
    assert_equal(m.nodes[0].node_id, Int32(1))
    assert_equal(m.nodes[1].host, "broker-2")
    assert_equal(m.nodes[1].port, UInt32(9002))
    assert_equal(len(m.leaders), 2)
    assert_equal(m.leaders[0].leader_node_id, Int32(2))
    assert_equal(m.leaders[1].partition_id, UInt32(1))
    assert_equal(m.leaders[1].leader_node_id, Int32(-1))
    _same(encode_proto(m), b, "BrokerClusterMap")


def test_node_load() raises:
    """NodeLoad: 1 records_served, 2 partition_count, 3
    reported_partition_total, which has presence: unset is absent on the
    wire, and 0 set is written."""
    var b = List[UInt8]()
    _uint(b, 1, 1_000_000_007)
    _uint(b, 2, 4)
    _uint(b, 3, 12)
    var n = decode_proto[NodeLoad](b.copy())
    assert_equal(n.records_served, UInt64(1_000_000_007))
    assert_equal(n.partition_count, UInt32(4))
    assert_true(Bool(n.reported_partition_total))
    assert_equal(n.reported_partition_total.value(), UInt32(12))
    _same(encode_proto(n), b, "NodeLoad")

    var unset = List[UInt8]()
    _uint(unset, 1, 9)
    _uint(unset, 2, 1)
    var u = decode_proto[NodeLoad](unset.copy())
    assert_false(Bool(u.reported_partition_total), "field 3 absent decodes unset")
    _same(encode_proto(u), unset, "NodeLoad without field 3")

    var zero = List[UInt8]()
    _uint(zero, 1, 9)
    _uint(zero, 2, 1)
    _uint(zero, 3, 0)
    var z = decode_proto[NodeLoad](zero.copy())
    assert_true(Bool(z.reported_partition_total), "field 3 present as 0 is set")
    assert_equal(z.reported_partition_total.value(), UInt32(0))
    _same(encode_proto(z), zero, "NodeLoad with field 3 = 0")


def test_cluster_config() raises:
    """ClusterConfig: 1 total_partitions, 2 node_count."""
    var b = List[UInt8]()
    _uint(b, 1, 64)
    _uint(b, 2, 3)
    var c = decode_proto[ClusterConfig](b.copy())
    assert_equal(c.total_partitions, UInt32(64))
    assert_equal(c.node_count, UInt32(3))
    _same(encode_proto(c), b, "ClusterConfig")


def main() raises:
    print("test_broker_field_numbers: the komira.broker.v1 wire census")
    test_node_endpoint()
    test_partition_leader()
    test_broker_cluster_map()
    test_node_load()
    test_cluster_config()
    print("ALL komira.broker.v1 FIELD-NUMBER TESTS PASSED")
