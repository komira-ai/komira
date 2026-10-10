# The oracle the cross-process tests judge by (rows.mojo), checked on its own:
#   * every row's key reaches the partition it was chosen for, so each
#     partition holds rows of every producer (a reducer that dies after one
#     slice has read part of its partition);
#   * the expected bodies of all partitions hold every row exactly once (a
#     doubled or lost row in the oracle would let a doubled or lost row in the
#     shuffle pass);
#   * hex round-trips bytes.
from std.testing import assert_equal, assert_true

from komira_shuffle.partitioner import HashPartitioner
from komira_shuffle.source import decode_partition_payloads
from komira_shuffle_e2e.rows import (
    expected_partition_body,
    from_hex,
    producer_rows,
    row_partition,
    row_payload,
    to_hex,
)

comptime P = 4
comptime ROWS = 8


def test_keys_reach_their_partition() raises:
    for r in [4, 8]:
        var part = HashPartitioner(Int64(r))
        for p in range(P):
            var rows = producer_rows(p, ROWS, r)
            assert_equal(len(rows), ROWS)
            for j in range(ROWS):
                assert_equal(part.partition_for(rows[j].key), row_partition(p, j, ROWS, r))


def test_expected_bodies_hold_every_row_once() raises:
    for r in [4, 8]:
        var seen = List[String]()
        for k in range(r):
            var producers_here = List[Int]()
            for payload in decode_partition_payloads(expected_partition_body(k, P, ROWS, r)):
                var s = String(unsafe_from_utf8=Span(payload))
                for t in seen:
                    assert_true(t != s, "row " + s + " appears twice")
                seen.append(s)
                var pid = atol(String(s.split("_")[0])[byte=1:])
                if pid not in producers_here:
                    producers_here.append(pid)
            assert_equal(len(producers_here), P, "a partition lacks rows of some producer")
        assert_equal(len(seen), P * ROWS)
        for p in range(P):
            for j in range(ROWS):
                var want = row_payload(p, j)
                var found = False
                for t in seen:
                    if t == want:
                        found = True
                assert_true(found, "row " + want + " is in no partition")


def test_hex_round_trip() raises:
    var b = List[UInt8]()
    for i in range(256):
        b.append(UInt8(i))
    var h = to_hex(b)
    assert_equal(h.byte_length(), 512)
    assert_true(h.startswith("000102"))
    var back = from_hex(h)
    assert_equal(len(back), 256)
    for i in range(256):
        assert_equal(Int(back[i]), i)


def main() raises:
    test_keys_reach_their_partition()
    test_expected_bodies_hold_every_row_once()
    test_hex_round_trip()
    print("test_rows: PASS")
