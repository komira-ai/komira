# =============================================================================
# test_delta_body.mojo -- the delta-layer chunk bodies and their codecs.
# =============================================================================
#
#   round trip   a delta (tables and name index) and a chain (base and deltas in
#                order) encode then decode to the same values; an empty delta, a
#                chain with no delta and non-ASCII names round-trip; encoding is
#                deterministic.
#   layout       the encoded header of a delta and of a chain is the format
#                version (delta 4, chain 3) as a little-endian i64 followed by
#                the counts.
#   kind         kg_chunk_is_chain_head tells a chain (version 3) from a base
#                manifest (version 2), and refuses a delta (version 4), any
#                other version or a body shorter than eight bytes; the three
#                versions differ so the first eight bytes decide.
#   cross-kind   a delta is never decoded as a chain nor a chain as a delta,
#                empty or not, including a delta whose length equals a chain's.
#   refusal      every truncation of a valid delta and of a valid chain, a wrong
#                version, a negative count, sequence number, schema version or
#                row count, a count the bytes cannot hold (including 2^63 - 1,
#                whose length sum would wrap), a string length that would wrap
#                the bounds check, a name that is not UTF-8, a table named twice
#                and trailing bytes are each an error, never a partial value.
#   write side   add_table and the chain constructors refuse negative numbers and
#                a repeated table name.
#   lookup       has_table and resolve find a present table and refuse an absent
#                one.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_kg_format import (
    KG_CHAIN_FORMAT_VERSION,
    KG_DELTA_FORMAT_VERSION,
    KG_SNAPSHOT_FORMAT_VERSION,
    KgChainBody,
    KgDeltaBody,
    KgManifestBody,
    KgNameIndexBody,
    kg_chunk_is_chain_head,
)


def _i64(mut out: List[UInt8], v: Int64):
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8(Int((u >> UInt64(8 * i)) & UInt64(0xFF))))


def _str(mut out: List[UInt8], s: String):
    var b = s.as_bytes()
    _i64(out, Int64(len(b)))
    for i in range(len(b)):
        out.append(b[i])


def _read_i64(bytes: List[UInt8], off: Int) -> Int64:
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(bytes[off + i])) << UInt64(8 * i)
    return Int64(u)


def _cut(full: List[UInt8], n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(full[i])
    return out^


def _delta() raises -> KgDeltaBody:
    var d = KgDeltaBody()
    d.add_table("edges", "d/aa11.parquet", 1, 3)
    d.add_table("entities", "d/bb22.parquet", 1, 2)
    d.add_index_entry("ada", 7)
    d.add_index_entry("grace hopper", 9)
    return d^


def _refused_delta(bytes: List[UInt8]) -> Bool:
    try:
        _ = KgDeltaBody.decode(bytes)
    except:
        return True
    return False


def _refused_chain(bytes: List[UInt8]) -> Bool:
    try:
        _ = KgChainBody.decode(bytes)
    except:
        return True
    return False


def test_delta_round_trips_tables_and_index() raises:
    var back = KgDeltaBody.decode(_delta().encode())
    assert_equal(back.format_version, KG_DELTA_FORMAT_VERSION)
    assert_equal(back.num_tables(), 2)
    assert_equal(back.tables[0].name, "edges")
    assert_equal(back.tables[0].object_key, "d/aa11.parquet")
    assert_equal(back.tables[0].schema_version, 1)
    assert_equal(back.tables[0].row_count, 3)
    assert_equal(back.tables[1].name, "entities")
    assert_equal(back.name_index.num_entries(), 2)
    assert_equal(back.name_index.entries[1].normalized_name, "grace hopper")
    assert_equal(back.name_index.entries[1].nid, 9)


def test_empty_delta_round_trips_and_is_sixteen_plus_eight_bytes() raises:
    var bytes = KgDeltaBody().encode()
    assert_equal(len(bytes), 24)  # version, table count, index count
    var back = KgDeltaBody.decode(bytes)
    assert_equal(back.num_tables(), 0)
    assert_equal(back.name_index.num_entries(), 0)


def test_non_ascii_names_and_keys_are_byte_faithful() raises:
    var d = KgDeltaBody()
    d.add_table("tabelle-é", "d/ключ-日本.parquet", 1, 1)
    d.add_index_entry("zoë 日本", 3)
    var back = KgDeltaBody.decode(d.encode())
    assert_equal(back.tables[0].name, "tabelle-é")
    assert_equal(back.tables[0].object_key, "d/ключ-日本.parquet")
    assert_equal(back.name_index.entries[0].normalized_name, "zoë 日本")


def test_delta_encoding_is_deterministic() raises:
    var a = _delta().encode()
    var b = _delta().encode()
    assert_equal(len(a), len(b))
    for i in range(len(a)):
        assert_equal(a[i], b[i])


def test_delta_header_layout() raises:
    var bytes = _delta().encode()
    assert_equal(_read_i64(bytes, 0), 4)
    assert_equal(_read_i64(bytes, 8), 2)  # table count
    assert_equal(_read_i64(bytes, 16), 5)  # first name length: "edges"


def test_chain_round_trips_in_order() raises:
    var deltas: List[Int64] = [4, 2, 9]
    var back = KgChainBody.decode(KgChainBody(1, deltas^).encode())
    assert_equal(back.format_version, KG_CHAIN_FORMAT_VERSION)
    assert_equal(back.base_seq, 1)
    assert_equal(back.num_deltas(), 3)
    assert_equal(back.delta_seqs[0], 4)
    assert_equal(back.delta_seqs[1], 2)
    assert_equal(back.delta_seqs[2], 9)


def test_chain_with_no_delta_and_append_delta() raises:
    var c = KgChainBody(5)
    var back = KgChainBody.decode(c.encode())
    assert_equal(back.base_seq, 5)
    assert_equal(back.num_deltas(), 0)
    c.append_delta(6)
    c.append_delta(7)
    var again = KgChainBody.decode(c.encode())
    assert_equal(again.num_deltas(), 2)
    assert_equal(again.delta_seqs[1], 7)


def test_chain_header_layout() raises:
    var bytes = KgChainBody(5).encode()
    assert_equal(len(bytes), 24)
    assert_equal(_read_i64(bytes, 0), 3)
    assert_equal(KG_CHAIN_FORMAT_VERSION, 3)
    assert_equal(_read_i64(bytes, 8), 5)
    assert_equal(_read_i64(bytes, 16), 0)


def test_chunk_kind_is_read_from_the_version() raises:
    assert_true(kg_chunk_is_chain_head(KgChainBody(1).encode()))
    assert_false(kg_chunk_is_chain_head(KgManifestBody(3).encode()))
    assert_true(KG_DELTA_FORMAT_VERSION != KG_SNAPSHOT_FORMAT_VERSION)
    assert_true(KG_DELTA_FORMAT_VERSION != KG_CHAIN_FORMAT_VERSION)
    assert_true(KG_CHAIN_FORMAT_VERSION != KG_SNAPSHOT_FORMAT_VERSION)


def test_no_delta_or_manifest_body_is_a_chain_head() raises:
    assert_false(kg_chunk_is_chain_head(KgManifestBody(3).encode()))
    with assert_raises(contains="unknown chunk format version 4"):
        _ = kg_chunk_is_chain_head(_delta().encode())
    with assert_raises(contains="unknown chunk format version 4"):
        _ = kg_chunk_is_chain_head(KgDeltaBody().encode())
    var one = KgDeltaBody()
    one.add_table("t", "k", 1, 1)
    with assert_raises(contains="unknown chunk format version 4"):
        _ = kg_chunk_is_chain_head(one.encode())


def test_a_delta_is_not_a_chain_and_a_chain_is_not_a_delta() raises:
    assert_true(_refused_chain(_delta().encode()))
    assert_true(_refused_chain(KgDeltaBody().encode()))
    assert_true(_refused_delta(KgChainBody(1).encode()))
    assert_true(_refused_delta(KgChainBody(0).encode()))
    # An empty delta and a chain of no deltas are both 24 bytes.
    assert_equal(len(KgDeltaBody().encode()), len(KgChainBody(0).encode()))
    var chain_deltas: List[Int64] = [2, 3]
    assert_true(_refused_delta(KgChainBody(1, chain_deltas^).encode()))


def test_a_delta_of_a_chains_length_is_not_a_chain() raises:
    # One table with an 11-byte name and a 45-byte key: the body is
    # 16 + (8 + 11) + (8 + 45) + 16 + 8 = 112 bytes, and a chain of the same
    # words would be read from the third word on. Under a shared version the
    # chain decoder accepted it.
    var d = KgDeltaBody()
    d.add_table("abcdefghijk", "k" * 45, 1, 1)
    var bytes = d.encode()
    assert_true(_refused_chain(bytes))
    assert_equal(_read_i64(bytes, 0), 4)
    # The same bytes under the chain's version are not a delta either.
    bytes[0] = 3
    assert_true(_refused_delta(bytes))


def test_chunk_kind_refuses_unknown_version_and_short_body() raises:
    var other = List[UInt8]()
    _i64(other, 9)
    with assert_raises(contains="unknown chunk format version 9"):
        _ = kg_chunk_is_chain_head(other)
    with assert_raises(contains="truncated"):
        _ = kg_chunk_is_chain_head(_cut(other, 7))


def test_delta_decode_refuses_a_chain_and_a_base() raises:
    assert_true(_refused_delta(KgChainBody(1).encode()))
    assert_true(_refused_delta(KgManifestBody(3).encode()))
    assert_true(_refused_chain(KgManifestBody(3).encode()))


def test_every_truncation_of_a_delta_is_refused() raises:
    var full = _delta().encode()
    for n in range(len(full)):
        assert_true(
            _refused_delta(_cut(full, n)),
            "a delta cut to " + String(n) + " bytes was accepted",
        )
    _ = KgDeltaBody.decode(full)


def test_every_truncation_of_a_chain_is_refused() raises:
    var deltas: List[Int64] = [4, 2, 9]
    var full = KgChainBody(1, deltas^).encode()
    for n in range(len(full)):
        assert_true(
            _refused_chain(_cut(full, n)),
            "a chain cut to " + String(n) + " bytes was accepted",
        )
    _ = KgChainBody.decode(full)


def test_trailing_bytes_are_refused() raises:
    var d = _delta().encode()
    d.append(0)
    with assert_raises(contains="1 trailing bytes"):
        _ = KgDeltaBody.decode(d)
    var c = KgChainBody(1).encode()
    c.append(0)
    with assert_raises(contains="1 trailing bytes"):
        _ = KgChainBody.decode(c)


def test_wrong_version_is_refused() raises:
    var d = _delta().encode()
    d[0] = 3
    with assert_raises(contains="unsupported delta format version 3"):
        _ = KgDeltaBody.decode(d)
    var c = KgChainBody(1).encode()
    c[0] = 4
    with assert_raises(contains="unsupported chain format version 4"):
        _ = KgChainBody.decode(c)


def test_counts_the_bytes_cannot_hold_are_refused() raises:
    var big: List[Int64] = [Int64.MAX, 1000000, 1]
    for k in range(len(big)):
        var d = List[UInt8]()
        _i64(d, 4)
        _i64(d, big[k])  # table count
        _i64(d, 0)
        assert_true(_refused_delta(d), "table count " + String(big[k]))
        var c = List[UInt8]()
        _i64(c, 3)
        _i64(c, 1)
        _i64(c, big[k])  # delta count
        assert_true(_refused_chain(c), "delta count " + String(big[k]))
        var ix = List[UInt8]()
        _i64(ix, 4)
        _i64(ix, 0)
        _i64(ix, big[k])  # name-index count
        assert_true(_refused_delta(ix), "index count " + String(big[k]))


def test_negative_counts_and_numbers_are_refused() raises:
    var d = List[UInt8]()
    _i64(d, 4)
    _i64(d, -1)
    with assert_raises(contains="negative table_count -1"):
        _ = KgDeltaBody.decode(d)

    var c = List[UInt8]()
    _i64(c, 3)
    _i64(c, 1)
    _i64(c, -1)
    with assert_raises(contains="negative delta_count -1"):
        _ = KgChainBody.decode(c)

    var base = List[UInt8]()
    _i64(base, 3)
    _i64(base, -2)
    _i64(base, 0)
    with assert_raises(contains="negative base_seq -2"):
        _ = KgChainBody.decode(base)

    var seq = List[UInt8]()
    _i64(seq, 3)
    _i64(seq, 1)
    _i64(seq, 1)
    _i64(seq, -3)
    with assert_raises(contains="negative delta_seq -3"):
        _ = KgChainBody.decode(seq)

    var ix = List[UInt8]()
    _i64(ix, 4)
    _i64(ix, 0)
    _i64(ix, -1)
    with assert_raises(contains="negative entry count -1"):
        _ = KgDeltaBody.decode(ix)


def _delta_with_one_table(schema_version: Int64, row_count: Int64) -> List[UInt8]:
    var d = List[UInt8]()
    _i64(d, 4)
    _i64(d, 1)
    _str(d, "edges")
    _str(d, "d/k")
    _i64(d, schema_version)
    _i64(d, row_count)
    _i64(d, 0)  # empty name index
    return d^


def test_negative_schema_version_and_row_count_are_refused() raises:
    _ = KgDeltaBody.decode(_delta_with_one_table(1, 0))
    with assert_raises(contains="negative schema_version -1"):
        _ = KgDeltaBody.decode(_delta_with_one_table(-1, 0))
    with assert_raises(contains="negative row_count -5"):
        _ = KgDeltaBody.decode(_delta_with_one_table(1, -5))


def test_string_length_that_would_wrap_the_bounds_check_is_refused() raises:
    var d = List[UInt8]()
    _i64(d, 4)
    _i64(d, 0)
    _i64(d, 1)  # one index entry
    _i64(d, Int64.MAX)  # its name length: offset + length would wrap negative
    for _ in range(40):
        d.append(65)
    with assert_raises(contains="truncated normalized name"):
        _ = KgDeltaBody.decode(d)


def test_names_that_are_not_utf8_are_refused() raises:
    var d = List[UInt8]()
    _i64(d, 4)
    _i64(d, 1)
    _i64(d, 2)  # a table name of two bytes
    d.append(0xC3)
    d.append(0x28)  # a lead byte followed by a non-continuation
    _str(d, "d/k")
    _i64(d, 1)
    _i64(d, 1)
    _i64(d, 0)
    with assert_raises(contains="table name is not valid UTF-8"):
        _ = KgDeltaBody.decode(d)

    var ix = List[UInt8]()
    _i64(ix, 4)
    _i64(ix, 0)
    _i64(ix, 1)
    _i64(ix, 1)
    ix.append(0xFF)
    _i64(ix, 4)
    with assert_raises(contains="normalized name is not valid UTF-8"):
        _ = KgDeltaBody.decode(ix)


def test_a_duplicate_table_at_the_end_of_a_large_delta_is_refused() raises:
    var n = 4000
    var d = List[UInt8]()
    _i64(d, 4)
    _i64(d, Int64(n + 1))
    for i in range(n):
        _str(d, "t" + String(i))
        _str(d, "k")
        _i64(d, 1)
        _i64(d, 1)
    _str(d, "t0")
    _str(d, "k")
    _i64(d, 1)
    _i64(d, 1)
    _i64(d, 0)
    with assert_raises(contains="table named twice: t0"):
        _ = KgDeltaBody.decode(d)


def test_a_table_named_twice_is_refused_on_decode_and_on_add() raises:
    var d = List[UInt8]()
    _i64(d, 4)
    _i64(d, 2)
    for _ in range(2):
        _str(d, "edges")
        _str(d, "d/k")
        _i64(d, 1)
        _i64(d, 1)
    _i64(d, 0)
    with assert_raises(contains="table named twice: edges"):
        _ = KgDeltaBody.decode(d)
    var w = KgDeltaBody()
    w.add_table("edges", "d/k", 1, 1)
    with assert_raises(contains="table named twice: edges"):
        w.add_table("edges", "d/other", 1, 1)


def test_write_side_refuses_negative_numbers() raises:
    var w = KgDeltaBody()
    with assert_raises(contains="negative schema_version"):
        w.add_table("edges", "d/k", -1, 0)
    with assert_raises(contains="negative row_count"):
        w.add_table("edges", "d/k", 1, -1)
    with assert_raises(contains="negative base_seq"):
        _ = KgChainBody(-1)
    var bad: List[Int64] = [1, -1]
    with assert_raises(contains="negative delta_seq"):
        _ = KgChainBody(0, bad^)
    var c = KgChainBody(0)
    with assert_raises(contains="negative delta_seq"):
        c.append_delta(-1)


def test_resolve_and_has_table() raises:
    var d = _delta()
    assert_true(d.has_table("edges"))
    assert_false(d.has_table("episodes"))
    assert_equal(d.resolve("entities").object_key, "d/bb22.parquet")
    with assert_raises(contains="table not present in delta: episodes"):
        _ = d.resolve("episodes")


def test_name_index_decode_advances_the_offset() raises:
    var idx = KgNameIndexBody()
    idx.add("a", 1)
    idx.add("b", 2)
    var bytes = idx.encode()
    var off = 0
    var back = KgNameIndexBody.decode(bytes, off)
    assert_equal(back.num_entries(), 2)
    assert_equal(off, len(bytes))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
