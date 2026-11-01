# =============================================================================
# test_manifest_body.mojo -- the snapshot manifest body and its codec.
# =============================================================================
#
#   round trip   encode then decode returns the same version, embedding
#                dimension, and every table in order (name, object key, schema
#                version, row count); an empty body, a body of a non-default
#                dimension and non-ASCII names round-trip too; encoding is
#                deterministic.
#   layout       the encoded header is [version 2][dimension][table count], each
#                a little-endian i64.
#   dimension    there is no default dimension: a body carries the one it
#                was built with and the writer must supply it; a constructor refuses a dimension of zero or
#                less; check_embedding_dim accepts the graph's dimension and
#                refuses any other; a decoded body reports the dimension written.
#   version      2 is the only layout: versions 0, 1 and 3 are refused.
#   refusal      a dimension above 2147483647 (the largest, itself, is accepted), every truncation of a valid body,
#                trailing bytes, a negative count, a negative length, a negative schema
#                version or row count (also refused by add_table), a count
#                larger than the bytes can hold, a dimension of zero or less and
#                a name or key that is not UTF-8 are each an error, never a
#                partial body.
#   lookup       resolve and has_table find a present table and refuse an absent
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
    KG_SNAPSHOT_FORMAT_VERSION,
    KgManifestBody,
    KgTableEntry,
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


def _sample(dim: Int) raises -> KgManifestBody:
    var body = KgManifestBody(dim, List[KgTableEntry]())
    body.add_table(String("episodes"), String("obj/aa11"), 1, 12)
    body.add_table(String("edges"), String("obj/bb22"), 1, 0)
    body.add_table(String("entities"), String("obj/cc33"), 2, 7)
    return body^


def _assert_same(a: KgManifestBody, b: KgManifestBody) raises:
    assert_equal(a.format_version, b.format_version)
    assert_equal(a.embedding_dim, b.embedding_dim)
    assert_equal(a.num_tables(), b.num_tables())
    for i in range(a.num_tables()):
        assert_equal(a.tables[i].name, b.tables[i].name)
        assert_equal(a.tables[i].object_key, b.tables[i].object_key)
        assert_equal(a.tables[i].schema_version, b.tables[i].schema_version)
        assert_equal(a.tables[i].row_count, b.tables[i].row_count)


# --- round trip --------------------------------------------------------------


def test_roundtrip_keeps_version_dimension_and_tables() raises:
    var body = _sample(5)
    var decoded = KgManifestBody.decode(body.encode())
    assert_equal(decoded.format_version, KG_SNAPSHOT_FORMAT_VERSION)
    assert_equal(decoded.embedding_dim, 5)
    assert_equal(decoded.num_tables(), 3)
    _assert_same(body, decoded)
    assert_equal(decoded.tables[2].name, "entities")
    assert_equal(decoded.tables[2].schema_version, 2)
    assert_equal(decoded.tables[0].row_count, 12)


def test_roundtrip_empty_body() raises:
    var decoded = KgManifestBody.decode(KgManifestBody(8).encode())
    assert_equal(decoded.num_tables(), 0)
    assert_equal(decoded.embedding_dim, 8)
    assert_equal(decoded.format_version, KG_SNAPSHOT_FORMAT_VERSION)


def test_roundtrip_non_ascii_names_byte_for_byte() raises:
    var body = KgManifestBody(3)
    body.add_table(String("épisodes-§-日本"), String("objets/ü/é"), 1, 3)
    var decoded = KgManifestBody.decode(body.encode())
    assert_equal(decoded.tables[0].name, "épisodes-§-日本")
    assert_equal(decoded.tables[0].object_key, "objets/ü/é")
    assert_equal(
        decoded.tables[0].name.byte_length(), body.tables[0].name.byte_length()
    )


def test_encoding_is_deterministic() raises:
    var a = _sample(8).encode()
    var b = _sample(8).encode()
    assert_equal(len(a), len(b))
    for i in range(len(a)):
        assert_equal(a[i], b[i])


def test_header_layout_is_version_dimension_count() raises:
    var bytes = _sample(384).encode()
    assert_equal(_read_i64(bytes, 0), 2)
    assert_equal(_read_i64(bytes, 8), 384)
    assert_equal(_read_i64(bytes, 16), 3)
    assert_equal(KG_SNAPSHOT_FORMAT_VERSION, 2)


# --- the embedding dimension -------------------------------------------------


def test_there_is_no_default_dimension() raises:
    # A body is built with the dimension the writer's embedder produces; the
    # one-argument form makes an empty body of that dimension.
    var empty = KgManifestBody(3)
    assert_equal(empty.embedding_dim, 3)
    assert_equal(empty.num_tables(), 0)
    assert_equal(empty.format_version, KG_SNAPSHOT_FORMAT_VERSION)
    with assert_raises(contains="must be positive"):
        _ = KgManifestBody(0)
    with assert_raises(contains="must be positive"):
        _ = KgManifestBody(-3)


def test_body_carries_the_dimension_it_was_built_with() raises:
    for d in [1, 3, 8, 384, 3072]:
        var body = KgManifestBody(d, List[KgTableEntry]())
        assert_equal(body.embedding_dim, d)
        assert_equal(KgManifestBody.decode(body.encode()).embedding_dim, d)


def test_constructor_refuses_a_non_positive_dimension() raises:
    with assert_raises(contains="must be positive"):
        _ = KgManifestBody(0, List[KgTableEntry]())
    with assert_raises(contains="must be positive"):
        _ = KgManifestBody(-5, List[KgTableEntry]())


def test_check_embedding_dim_refuses_a_mismatch() raises:
    var body = _sample(5)
    body.check_embedding_dim(5)
    with assert_raises(contains="does not match the graph's 5"):
        body.check_embedding_dim(9)
    with assert_raises(contains="does not match the graph's 5"):
        body.check_embedding_dim(4)
    # The check follows the decoded dimension, not the default.
    var decoded = KgManifestBody.decode(body.encode())
    decoded.check_embedding_dim(5)
    with assert_raises(contains="does not match"):
        decoded.check_embedding_dim(9)


# --- corrupt input -----------------------------------------------------------


def test_every_version_but_two_is_refused() raises:
    for v in [0, 1, 3, -1]:
        var b = List[UInt8]()
        _i64(b, Int64(v))
        _i64(b, 8)
        _i64(b, 0)
        with assert_raises(
            contains="unsupported snapshot format version " + String(v)
        ):
            _ = KgManifestBody.decode(b)
    # A version-1 body (no dimension field) is refused whole.
    var v1 = List[UInt8]()
    _i64(v1, 1)
    _i64(v1, 0)
    with assert_raises(contains="unsupported snapshot format version 1"):
        _ = KgManifestBody.decode(v1)


def test_the_largest_dimension_is_accepted_and_one_more_refused() raises:
    var ok = List[UInt8]()
    _i64(ok, 2)
    _i64(ok, 2147483647)
    _i64(ok, 0)
    assert_equal(KgManifestBody.decode(ok).embedding_dim, 2147483647)
    var over = List[UInt8]()
    _i64(over, 2)
    _i64(over, 2147483648)
    _i64(over, 0)
    with assert_raises(contains="invalid embedding dimension 2147483648"):
        _ = KgManifestBody.decode(over)


def test_every_truncation_of_a_valid_body_is_refused() raises:
    var full = _sample(5).encode()
    for n in range(len(full)):
        var cut = List[UInt8](capacity=n)
        for i in range(n):
            cut.append(full[i])
        var refused = False
        try:
            _ = KgManifestBody.decode(cut)
        except:
            refused = True
        assert_true(refused, "a body cut to " + String(n) + " bytes was accepted")
    _ = KgManifestBody.decode(full)  # the whole body is fine


def test_trailing_bytes_are_refused() raises:
    var bytes = _sample(5).encode()
    bytes.append(UInt8(0))
    with assert_raises(contains="1 trailing bytes"):
        _ = KgManifestBody.decode(bytes)


def test_negative_table_count_is_refused() raises:
    var b = List[UInt8]()
    _i64(b, 2)
    _i64(b, 5)
    _i64(b, -1)
    with assert_raises(contains="negative table_count"):
        _ = KgManifestBody.decode(b)


def _one_table_body(schema_version: Int64, row_count: Int64) -> List[UInt8]:
    var b = List[UInt8]()
    _i64(b, 2)
    _i64(b, 5)
    _i64(b, 1)
    _str(b, "t")
    _str(b, "k")
    _i64(b, schema_version)
    _i64(b, row_count)
    return b^


def test_negative_schema_version_and_row_count_are_refused() raises:
    # A well-formed single-table body decodes; each negative field is refused.
    var ok = KgManifestBody.decode(_one_table_body(1, 0))
    assert_equal(ok.resolve("t").schema_version, Int64(1))
    assert_equal(ok.resolve("t").row_count, Int64(0))
    with assert_raises(contains="negative schema_version -1"):
        _ = KgManifestBody.decode(_one_table_body(-1, 0))
    with assert_raises(contains="negative row_count -7"):
        _ = KgManifestBody.decode(_one_table_body(1, -7))


def test_add_table_refuses_a_negative_version_or_row_count() raises:
    var body = KgManifestBody(5, List[KgTableEntry]())
    with assert_raises(contains="negative schema_version"):
        body.add_table("t", "k", -1, 0)
    with assert_raises(contains="negative row_count"):
        body.add_table("t", "k", 1, -1)
    assert_equal(body.num_tables(), 0)


def test_table_count_beyond_the_bytes_is_refused() raises:
    var b = List[UInt8]()
    _i64(b, 2)
    _i64(b, 5)
    _i64(b, 1000000000)
    with assert_raises(contains="truncated table list"):
        _ = KgManifestBody.decode(b)


def test_negative_and_oversized_string_lengths_are_refused() raises:
    var neg = List[UInt8]()
    _i64(neg, 2)
    _i64(neg, 5)
    _i64(neg, 1)
    _i64(neg, -5)  # name_len
    for _ in range(40):
        neg.append(UInt8(0))
    with assert_raises(contains="negative length"):
        _ = KgManifestBody.decode(neg)
    var big = List[UInt8]()
    _i64(big, 2)
    _i64(big, 5)
    _i64(big, 1)
    _i64(big, 9000000000000)
    for _ in range(40):
        big.append(UInt8(0))
    with assert_raises(contains="truncated table name"):
        _ = KgManifestBody.decode(big)


def test_non_positive_dimension_in_a_body_is_refused() raises:
    for d in [0, -1]:
        var b = List[UInt8]()
        _i64(b, 2)
        _i64(b, Int64(d))
        _i64(b, 0)
        with assert_raises(contains="invalid embedding dimension"):
            _ = KgManifestBody.decode(b)


def test_name_or_key_that_is_not_utf8_is_refused() raises:
    var name = List[UInt8]()
    _i64(name, 2)
    _i64(name, 5)
    _i64(name, 1)
    _i64(name, 2)
    name.append(UInt8(0xC3))  # a lead byte with no continuation
    name.append(UInt8(0x28))
    _str(name, "k")
    _i64(name, 1)
    _i64(name, 1)
    with assert_raises(contains="table name is not valid UTF-8"):
        _ = KgManifestBody.decode(name)
    var key = List[UInt8]()
    _i64(key, 2)
    _i64(key, 5)
    _i64(key, 1)
    _str(key, "n")
    _i64(key, 1)
    key.append(UInt8(0xFF))
    _i64(key, 1)
    _i64(key, 1)
    with assert_raises(contains="object_key is not valid UTF-8"):
        _ = KgManifestBody.decode(key)


# --- lookup ------------------------------------------------------------------


def test_resolve_and_has_table() raises:
    var body = _sample(5)
    assert_true(body.has_table("edges"))
    assert_false(body.has_table("communities"))
    var e = body.resolve("entities")
    assert_equal(e.object_key, "obj/cc33")
    assert_equal(e.row_count, 7)
    with assert_raises(contains="table not present in snapshot: communities"):
        _ = body.resolve("communities")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
