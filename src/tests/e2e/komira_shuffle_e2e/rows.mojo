# =============================================================================
# komira_shuffle_e2e/rows.mojo -- the deterministic input of the cross-process
# shuffle tests, and the oracle computed from it.
# =============================================================================
#
# A map task's rows are a pure function of (producer, rows_per, partitions), so
# a replayed map writes the same rows and the test can compute, without running
# any task, what every partition must hold:
#
#   * row j of producer p has payload `p<p>_r<j>` (unique across the shuffle)
#     and a key chosen so that `HashPartitioner(R)` sends it to partition
#     `(p * rows_per + j) mod R`. Every partition then holds rows of every
#     producer, so a reduce reads one slice per producer and a reducer that
#     dies after its first slice has read part of its input, not all of it.
#   * `expected_partition_body(p)` is the bytes `read_shuffle_partition` must
#     return: each producer's frames for that partition, producers in ascending
#     order (the seal's plan order), each frame `[len: i64 LE][payload]` in row
#     order (`encode_partition_body`).
#
# Bytes travel between processes as lowercase hex on one stdout line.
# =============================================================================

from komira_shuffle.partitioner import HashPartitioner
from komira_shuffle.sink import ShuffleRow, encode_partition_body

comptime _KEY_SEARCH_LIMIT = 4096


def to_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def row_payload(producer: Int, row: Int) -> String:
    return String("p") + String(producer) + "_r" + String(row)


def row_partition(producer: Int, row: Int, rows_per: Int, partitions: Int) -> Int:
    return (producer * rows_per + row) % partitions


def row_key(producer: Int, row: Int, rows_per: Int, partitions: Int) raises -> List[UInt8]:
    """The smallest-nonce key `k<p>_<j>_<n>` that `HashPartitioner(partitions)`
    sends to `row_partition(producer, row, ...)`."""
    var target = row_partition(producer, row, rows_per, partitions)
    var partitioner = HashPartitioner(Int64(partitions))
    for nonce in range(_KEY_SEARCH_LIMIT):
        var key = to_bytes(String("k") + String(producer) + "_" + String(row) + "_" + String(nonce))
        if partitioner.partition_for(key) == target:
            return key^
    raise Error(
        "rows: no key for producer " + String(producer) + " row " + String(row)
        + " reaches partition " + String(target) + " in " + String(_KEY_SEARCH_LIMIT) + " tries"
    )


def producer_rows(producer: Int, rows_per: Int, partitions: Int) raises -> List[ShuffleRow]:
    var out = List[ShuffleRow]()
    for j in range(rows_per):
        out.append(ShuffleRow(row_key(producer, j, rows_per, partitions), to_bytes(row_payload(producer, j))))
    return out^


def expected_partition_body(partition: Int, producers: Int, rows_per: Int, partitions: Int) raises -> List[UInt8]:
    """What a correct reduce of `partition` returns, byte for byte."""
    var out = List[UInt8]()
    for p in range(producers):
        var rows = producer_rows(p, rows_per, partitions)
        var mine = List[ShuffleRow]()
        for i in range(len(rows)):
            if row_partition(p, i, rows_per, partitions) == partition:
                mine.append(rows[i].copy())
        out.extend(encode_partition_body(mine))
    return out^


def expected_partition_hex(partition: Int, producers: Int, rows_per: Int, partitions: Int) raises -> String:
    return to_hex(expected_partition_body(partition, producers, rows_per, partitions))


def to_hex(bytes: List[UInt8]) -> String:
    comptime digits = "0123456789abcdef"
    var d = String(digits).as_bytes()
    var out = List[UInt8]()
    for b in bytes:
        out.append(d[Int(b >> 4)])
        out.append(d[Int(b & 0xF)])
    return String(unsafe_from_utf8=Span(out))


def _nibble(c: UInt8) raises -> UInt8:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return c - UInt8(ord("0"))
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return c - UInt8(ord("a")) + 10
    raise Error("rows: not a lowercase hex digit: " + String(Int(c)))


def from_hex(s: String) raises -> List[UInt8]:
    var b = s.as_bytes()
    if len(b) % 2 != 0:
        raise Error("rows: odd-length hex string")
    var out = List[UInt8]()
    for i in range(0, len(b), 2):
        out.append((_nibble(b[i]) << 4) | _nibble(b[i + 1]))
    return out^
