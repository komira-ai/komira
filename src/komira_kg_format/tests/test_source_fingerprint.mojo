# =============================================================================
# test_source_fingerprint.mojo -- the content hashes and the fingerprint set.
# =============================================================================
#
#   hash          fnv1a64_hex matches the published FNV-1a 64-bit values for the
#                 empty input, "a" and "foobar", is 16 lowercase hex digits and
#                 agrees with content_hash_of on text.
#   one byte      for a 40-byte input, changing any one byte to any other value
#                 changes the hash (every position and every replacement byte).
#   extraction    content_hash_of_extraction is stable for equal extractions and
#                 changes when any one field of an entity or a triple changes,
#                 when a count changes, when an entity is added, or when text
#                 moves across a field boundary; separators inside a field
#                 cannot imitate a boundary.
#   keying        the set is keyed by partition_id and source: the same source
#                 under two partitions has two independent fingerprints; patch
#                 replaces one key and leaves every other untouched; lookup of an
#                 unknown key is "".
#   wire          the set round-trips (non-ASCII ids included), encoding is
#                 deterministic, and its header is version 1 and the count.
#   refusal       every truncation, an unknown version, a negative count, a count
#                 the bytes cannot hold (also 2^63 - 1), a string length that
#                 would wrap, a string that is not UTF-8, an empty content hash,
#                 a key stored twice and trailing bytes are each an error.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_not_equal,
    assert_raises,
    assert_true,
)

from komira_kg_format import (
    KG_FINGERPRINT_FORMAT_VERSION,
    EntityMention,
    Extraction,
    SourceFingerprintSet,
    Triple,
    content_hash_of,
    content_hash_of_extraction,
    fnv1a64_hex,
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


def _hex_of(text: String) -> String:
    return fnv1a64_hex(text.as_bytes())


def test_published_fnv1a_vectors() raises:
    assert_equal(_hex_of(""), "cbf29ce484222325")
    assert_equal(_hex_of("a"), "af63dc4c8601ec8c")
    assert_equal(_hex_of("foobar"), "85944171f73967e8")


def test_digest_is_sixteen_lowercase_hex_digits_and_matches_text_hash() raises:
    var h = content_hash_of("some body of text")
    assert_equal(len(h.as_bytes()), 16)
    for b in h.as_bytes():
        assert_true((b >= 48 and b <= 57) or (b >= 97 and b <= 102))
    assert_equal(h, _hex_of("some body of text"))
    assert_equal(content_hash_of("some body of text"), h)


def test_changing_any_one_byte_to_any_other_value_changes_the_hash() raises:
    var base = List[UInt8]()
    for i in range(40):
        base.append(UInt8((i * 7 + 3) & 0xFF))
    var original = fnv1a64_hex(Span(base))
    for pos in range(40):
        var kept = base[pos]
        for v in range(256):
            if UInt8(v) == kept:
                continue
            base[pos] = UInt8(v)
            assert_true(
                fnv1a64_hex(Span(base)) != original,
                "byte " + String(pos) + " set to " + String(v) + " kept the hash",
            )
        base[pos] = kept
    assert_equal(fnv1a64_hex(Span(base)), original)


def _extraction() -> Extraction:
    var entities = List[EntityMention]()
    entities.append(EntityMention("Ada", "person", "wrote notes"))
    entities.append(EntityMention("Engine", "machine", ""))
    var triples = List[Triple]()
    triples.append(Triple("Ada", "wrote", "notes", "Ada wrote notes", 100, 200))
    return Extraction(entities^, triples^)


def test_equal_extractions_hash_equal() raises:
    assert_equal(
        content_hash_of_extraction(_extraction()),
        content_hash_of_extraction(_extraction()),
    )
    assert_equal(len(content_hash_of_extraction(Extraction()).as_bytes()), 16)


def test_every_field_of_an_entity_and_a_triple_is_in_the_hash() raises:
    var base = content_hash_of_extraction(_extraction())

    var e0 = _extraction()
    e0.entities[0].name = "Adb"
    var e1 = _extraction()
    e1.entities[0].entity_type = "persoo"
    var e2 = _extraction()
    e2.entities[0].summary = "wrote notes."
    var t0 = _extraction()
    t0.triples[0].subject_name = "Adb"
    var t1 = _extraction()
    t1.triples[0].predicate = "wrote_"
    var t2 = _extraction()
    t2.triples[0].object_name = "notez"
    var t3 = _extraction()
    t3.triples[0].fact = "Ada wrote notes!"
    var t4 = _extraction()
    t4.triples[0].valid_at = 101
    var t5 = _extraction()
    t5.triples[0].invalid_at = 201
    var changed = List[String]()
    changed.append(content_hash_of_extraction(e0))
    changed.append(content_hash_of_extraction(e1))
    changed.append(content_hash_of_extraction(e2))
    changed.append(content_hash_of_extraction(t0))
    changed.append(content_hash_of_extraction(t1))
    changed.append(content_hash_of_extraction(t2))
    changed.append(content_hash_of_extraction(t3))
    changed.append(content_hash_of_extraction(t4))
    changed.append(content_hash_of_extraction(t5))
    for i in range(len(changed)):
        assert_not_equal(changed[i], base, "field " + String(i))
        for j in range(i + 1, len(changed)):
            assert_not_equal(changed[i], changed[j])


def test_adding_an_entity_or_a_triple_changes_the_hash() raises:
    var base = content_hash_of_extraction(_extraction())
    var more = _extraction()
    more.entities.append(EntityMention("Lamp", "", ""))
    assert_not_equal(content_hash_of_extraction(more), base)
    var more_t = _extraction()
    more_t.triples.append(Triple("a", "b", "c", "d", 0, 0))
    assert_not_equal(content_hash_of_extraction(more_t), base)


def test_text_moved_across_a_field_boundary_changes_the_hash() raises:
    var a = Extraction()
    a.entities.append(EntityMention("ab", "c", ""))
    var b = Extraction()
    b.entities.append(EntityMention("a", "bc", ""))
    assert_not_equal(content_hash_of_extraction(a), content_hash_of_extraction(b))
    var c = Extraction()
    c.entities.append(EntityMention("a", "", "bc"))
    assert_not_equal(content_hash_of_extraction(b), content_hash_of_extraction(c))


def test_separator_bytes_inside_a_field_cannot_imitate_a_boundary() raises:
    # With a unit separator between fields, these two collide; with lengths
    # they do not.
    var us = chr(0x1F)
    var a = Extraction()
    a.entities.append(EntityMention("a" + us + "b", "c", ""))
    var b = Extraction()
    b.entities.append(EntityMention("a", "b" + us + "c", ""))
    assert_not_equal(content_hash_of_extraction(a), content_hash_of_extraction(b))
    var rs = chr(0x1E)
    var c = Extraction()
    c.entities.append(EntityMention("x" + rs, "", ""))
    var d = Extraction()
    d.entities.append(EntityMention("x", "", ""))
    d.entities.append(EntityMention("", "", ""))
    assert_not_equal(content_hash_of_extraction(c), content_hash_of_extraction(d))


def test_an_entity_is_not_a_triple() raises:
    var e = Extraction()
    e.entities.append(EntityMention("a", "b", "c"))
    var t = Extraction()
    t.triples.append(Triple("a", "b", "c", "", 0, 0))
    assert_not_equal(content_hash_of_extraction(e), content_hash_of_extraction(t))


def _set() raises -> SourceFingerprintSet:
    var s = SourceFingerprintSet()
    s.patch("p1", "doc-1", "aaaaaaaaaaaaaaaa", "")
    s.patch("p1", "doc-2", "bbbbbbbbbbbbbbbb", "sig-2")
    s.patch("p2", "doc-1", "cccccccccccccccc", "")
    return s^


def test_the_set_is_keyed_by_partition_and_source() raises:
    var s = _set()
    assert_equal(s.num_entries(), 3)
    assert_equal(s.lookup("p1", "doc-1"), "aaaaaaaaaaaaaaaa")
    assert_equal(s.lookup("p2", "doc-1"), "cccccccccccccccc")
    assert_equal(s.lookup("p1", "doc-2"), "bbbbbbbbbbbbbbbb")
    assert_equal(s.lookup("p2", "doc-2"), "")  # same source, other partition
    assert_equal(s.lookup("p3", "doc-1"), "")
    assert_equal(s.lookup_structural("p1", "doc-2"), "sig-2")
    assert_equal(s.lookup_structural("p1", "doc-1"), "")
    assert_equal(s.lookup_structural("p9", "doc-1"), "")


def test_patch_replaces_one_key_and_leaves_the_rest() raises:
    var s = _set()
    s.patch("p1", "doc-1", "dddddddddddddddd", "new-sig")
    assert_equal(s.num_entries(), 3)
    assert_equal(s.lookup("p1", "doc-1"), "dddddddddddddddd")
    assert_equal(s.lookup_structural("p1", "doc-1"), "new-sig")
    assert_equal(s.lookup("p1", "doc-2"), "bbbbbbbbbbbbbbbb")
    assert_equal(s.lookup("p2", "doc-1"), "cccccccccccccccc")
    assert_false(s.is_empty())
    assert_true(SourceFingerprintSet().is_empty())


def test_patch_refuses_an_empty_hash() raises:
    var s = SourceFingerprintSet()
    with assert_raises(contains="empty content_hash"):
        s.patch("p", "src", "", "")
    assert_true(s.is_empty())


def test_set_round_trips_and_encoding_is_deterministic() raises:
    var s = _set()
    s.patch("pé", "источник-日本", "eeeeeeeeeeeeeeee", "sïg")
    var bytes = s.encode()
    var back = SourceFingerprintSet.decode(bytes)
    assert_equal(back.num_entries(), 4)
    assert_equal(back.lookup("p1", "doc-2"), "bbbbbbbbbbbbbbbb")
    assert_equal(back.lookup("pé", "источник-日本"), "eeeeeeeeeeeeeeee")
    assert_equal(back.lookup_structural("pé", "источник-日本"), "sïg")
    var again = back.encode()
    assert_equal(len(again), len(bytes))
    for i in range(len(bytes)):
        assert_equal(bytes[i], again[i])


def test_header_is_version_and_count() raises:
    var bytes = _set().encode()
    assert_equal(_read_i64(bytes, 0), KG_FINGERPRINT_FORMAT_VERSION)
    assert_equal(_read_i64(bytes, 0), 1)
    assert_equal(_read_i64(bytes, 8), 3)
    assert_equal(len(SourceFingerprintSet().encode()), 16)


def _refused(bytes: List[UInt8]) -> Bool:
    try:
        _ = SourceFingerprintSet.decode(bytes)
    except:
        return True
    return False


def test_every_truncation_is_refused() raises:
    var full = _set().encode()
    for n in range(len(full)):
        var cut = List[UInt8](capacity=n)
        for i in range(n):
            cut.append(full[i])
        assert_true(_refused(cut), "a set cut to " + String(n) + " bytes was accepted")
    _ = SourceFingerprintSet.decode(full)


def test_trailing_bytes_and_wrong_version_are_refused() raises:
    var full = _set().encode()
    full.append(0)
    with assert_raises(contains="1 trailing bytes"):
        _ = SourceFingerprintSet.decode(full)
    var v = _set().encode()
    v[0] = 2
    with assert_raises(contains="unsupported fingerprint format version 2"):
        _ = SourceFingerprintSet.decode(v)


def test_counts_the_bytes_cannot_hold_are_refused() raises:
    var counts: List[Int64] = [Int64.MAX, 1000000, 2]
    for k in range(len(counts)):
        var b = List[UInt8]()
        _i64(b, 1)
        _i64(b, counts[k])
        _i64(b, 0)
        assert_true(_refused(b), "count " + String(counts[k]))
    var neg = List[UInt8]()
    _i64(neg, 1)
    _i64(neg, -1)
    with assert_raises(contains="negative entry count -1"):
        _ = SourceFingerprintSet.decode(neg)


def _one_entry(p: String, s: String, h: String, sig: String) -> List[UInt8]:
    var b = List[UInt8]()
    _i64(b, 1)
    _i64(b, 1)
    _str(b, p)
    _str(b, s)
    _str(b, h)
    _str(b, sig)
    return b^


def test_empty_hash_and_duplicate_key_are_refused() raises:
    _ = SourceFingerprintSet.decode(_one_entry("p", "s", "0123456789abcdef", ""))
    with assert_raises(contains="empty content_hash for s"):
        _ = SourceFingerprintSet.decode(_one_entry("p", "s", "", ""))
    var dup = List[UInt8]()
    _i64(dup, 1)
    _i64(dup, 2)
    for _ in range(2):
        _str(dup, "p")
        _str(dup, "s")
        _str(dup, "0123456789abcdef")
        _str(dup, "")
    with assert_raises(contains="source stored twice: s"):
        _ = SourceFingerprintSet.decode(dup)


def test_a_duplicate_at_the_end_of_a_large_body_is_refused() raises:
    # Thousands of distinct keys, then the first key again. The check must find
    # it and, on a hostile count, in time linear in the count.
    var n = 4000
    var b = List[UInt8]()
    _i64(b, 1)
    _i64(b, Int64(n + 1))
    for i in range(n):
        _str(b, "p")
        _str(b, "s" + String(i))
        _str(b, "0123456789abcdef")
        _str(b, "")
    _str(b, "p")
    _str(b, "s0")
    _str(b, "0123456789abcdef")
    _str(b, "")
    assert_true(_refused(b))
    with assert_raises(contains="source stored twice: s0"):
        _ = SourceFingerprintSet.decode(b)


def test_keys_that_differ_only_in_where_the_partition_ends_are_distinct() raises:
    var b = List[UInt8]()
    _i64(b, 1)
    _i64(b, 2)
    _str(b, "ab")
    _str(b, "c")
    _str(b, "0123456789abcdef")
    _str(b, "")
    _str(b, "a")
    _str(b, "bc")
    _str(b, "0123456789abcdef")
    _str(b, "")
    var back = SourceFingerprintSet.decode(b)
    assert_equal(back.num_entries(), 2)


def test_wrapping_length_and_non_utf8_strings_are_refused() raises:
    var wrap = List[UInt8]()
    _i64(wrap, 1)
    _i64(wrap, 1)
    _i64(wrap, Int64.MAX)  # partition_id length: offset + length would wrap
    for _ in range(100):
        wrap.append(65)
    with assert_raises(contains="truncated partition_id"):
        _ = SourceFingerprintSet.decode(wrap)

    var bad = List[UInt8]()
    _i64(bad, 1)
    _i64(bad, 1)
    _i64(bad, 2)
    bad.append(0xC3)
    bad.append(0x28)
    _str(bad, "s")
    _str(bad, "0123456789abcdef")
    _str(bad, "")
    with assert_raises(contains="partition_id is not valid UTF-8"):
        _ = SourceFingerprintSet.decode(bad)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
