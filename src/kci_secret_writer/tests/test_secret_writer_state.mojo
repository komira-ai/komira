# =============================================================================
# test_secret_writer_state.mojo — the `StaticSecretWriter` bookkeeping gate.
# =============================================================================
#
# test_secret_writer.mojo proves the write verb and the write-then-resolve
# round trip. This file proves the rest of the double's state, which the
# seed-if-absent and bootstrap-define flows assert through:
#   (1) an unknown ref reads as absent on every reader, and a write to one ref
#       does not make another ref present;
#   (2) define_container records an empty slot and mints no version;
#   (3) the version count is per ref and grows on every write, a byte-identical
#       re-write included;
#   (4) last_token is set by each of the three verbs;
#   (5) written_equals rejects a one-byte difference at the first, a middle and
#       the last byte, a prefix, an extension, and a missing ref; an empty value
#       is written and compares equal to "";
#   (6) share() hands out a second handle over the same state;
#   (7) as_static_store maps every ref to its own value, as an independent copy,
#       and a re-write replaces the writer's value;
#   (8) a value of MAX_SECRET_LEN bytes of valid UTF-8 (every ASCII byte and a
#       2-, 3- and 4-byte character) round-trips through the writer and the
#       paired resolve unchanged;
#   (9) a written value that is not UTF-8 is recorded byte for byte, but
#       as_static_store refuses it naming the ref, never the bytes (the resolve
#       double holds only Strings).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_secret_store import MAX_SECRET_LEN, SecretValue

from kci_secret_writer import StaticSecretWriter


comptime _A: String = "example/app/smtp-relay"
comptime _B: String = "example/app/api-key"
comptime _C: String = "example/app/empty"
comptime _UNKNOWN: String = "example/app/never-touched"


def _v(s: String) raises -> SecretValue:
    return SecretValue.from_string(s)


def _bytes_equal(got: Span[UInt8, _], want: Span[UInt8, _]) -> Bool:
    if len(got) != len(want):
        return False
    for i in range(len(got)):
        if got[i] != want[i]:
            return False
    return True


# =============================================================================
# (1) an unknown ref is absent on every reader.
# =============================================================================
def test_unknown_ref_reads_as_absent() raises:
    var w = StaticSecretWriter()
    assert_false(w.has_version(_UNKNOWN, "tok-probe"), "fresh: no version")
    assert_equal(w.version_count(_UNKNOWN), 0, "fresh: version_count 0")
    assert_equal(w.written_len(_UNKNOWN), 0, "fresh: written_len 0")
    assert_false(w.written_equals(_UNKNOWN, ""), "fresh: equals '' is False")
    assert_false(w.was_written(_UNKNOWN), "fresh: not written")
    assert_false(w.was_defined(_UNKNOWN), "fresh: not defined")

    # Another ref's write and define do not make _UNKNOWN present.
    w.write(_A, _v("alpha"), "tok-w")
    w.define_container(_B, "tok-d")
    assert_false(w.has_version(_UNKNOWN, "tok-probe"), "after writes: no version")
    assert_equal(w.version_count(_UNKNOWN), 0, "after writes: version_count 0")
    assert_equal(w.written_len(_UNKNOWN), 0, "after writes: written_len 0")
    assert_false(w.written_equals(_UNKNOWN, "alpha"), "after writes: equals False")
    assert_false(w.was_written(_UNKNOWN), "after writes: not written")
    assert_false(w.was_defined(_UNKNOWN), "after writes: not defined")
    # The written ref is present, with its own length, and is not defined: a
    # write is not a define (was_defined answers for empty containers only).
    assert_equal(w.written_len(_A), 5, "the written ref's length")
    assert_false(w.was_defined(_A), "a write is not a define")
    _ = w^


# =============================================================================
# (2) define_container makes an empty slot and mints no version.
# =============================================================================
def test_define_container_mints_no_version() raises:
    var w = StaticSecretWriter()
    assert_equal(w.define_count(), 0, "define_count starts at 0")
    w.define_container(_B, "tok-define")
    assert_equal(w.last_token(), "tok-define", "define records its token")
    assert_equal(w.define_count(), 1, "one define")
    assert_true(w.was_defined(_B), "the slot is defined")
    assert_false(w.was_defined(_A), "only that slot is defined")
    assert_equal(w.write_count(), 0, "a define is not a write")
    assert_false(w.was_written(_B), "a define records no value")
    assert_equal(w.written_len(_B), 0, "a define records no bytes")
    assert_equal(w.version_count(_B), 0, "a define mints no version")
    assert_false(w.has_version(_B, "tok-probe"), "a defined slot has no version")

    # A re-define is recorded again and still mints nothing.
    w.define_container(_B, "tok-define-2")
    assert_equal(w.define_count(), 2, "a re-define is counted")
    assert_equal(w.version_count(_B), 0, "a re-define mints no version")

    # A write into the defined slot mints its first version; define state stays.
    w.write(_B, _v("key-value"), "tok-w")
    assert_true(w.has_version(_B, "tok-probe"), "the write minted a version")
    assert_equal(w.version_count(_B), 1, "one version")
    assert_equal(w.define_count(), 2, "a write is not a define")
    assert_true(w.was_defined(_B), "the slot stays defined")
    _ = w^


# =============================================================================
# (3) the version count is per ref and grows on every write.
# =============================================================================
def test_version_count_per_ref_and_identical_rewrite() raises:
    var w = StaticSecretWriter()
    w.write(_A, _v("same"), "tok")
    assert_equal(w.version_count(_A), 1, "first write: one version")
    w.write(_A, _v("same"), "tok")
    assert_equal(w.version_count(_A), 2, "byte-identical re-write mints a version")
    w.write(_A, _v("same"), "tok")
    assert_equal(w.version_count(_A), 3, "a third write: three versions")
    w.write(_B, _v("other"), "tok")
    assert_equal(w.version_count(_B), 1, "another ref starts its own count")
    assert_equal(w.version_count(_A), 3, "another ref's write leaves A's count")
    assert_true(w.has_version(_A, "tok"), "A has a version")
    assert_true(w.has_version(_B, "tok"), "B has a version")
    assert_equal(w.write_count(), 4, "every write counted")
    assert_true(w.written_equals(_A, "same"), "A holds its value")
    assert_true(w.written_equals(_B, "other"), "B holds its value")
    assert_false(w.was_defined(_A), "re-writes do not define A")
    assert_false(w.was_defined(_B), "a write does not define B")
    assert_equal(w.define_count(), 0, "writes are not defines")
    _ = w^


# =============================================================================
# (4) last_token is set by write, define_container and has_version.
# =============================================================================
def test_last_token_follows_each_verb() raises:
    var w = StaticSecretWriter()
    assert_equal(w.last_token(), "", "no token before any call")
    w.write(_A, _v("alpha"), "tok-write")
    assert_equal(w.last_token(), "tok-write", "write records its token")
    w.define_container(_B, "tok-define")
    assert_equal(w.last_token(), "tok-define", "define records its token")
    _ = w.has_version(_A, "tok-probe")
    assert_equal(w.last_token(), "tok-probe", "has_version records its token")
    _ = w.has_version(_UNKNOWN, "tok-probe-absent")
    assert_equal(
        w.last_token(), "tok-probe-absent", "an absent probe records its token"
    )
    w.write(_A, _v("alpha"), "tok-write-2")
    assert_equal(w.last_token(), "tok-write-2", "the last call's token wins")
    _ = w^


# =============================================================================
# (5) written_equals compares every byte and the length.
# =============================================================================
def test_written_equals_rejects_one_byte_difference() raises:
    var w = StaticSecretWriter()
    w.write(_A, _v("abcdef"), "tok")
    assert_true(w.written_equals(_A, "abcdef"), "the same bytes")
    assert_false(w.written_equals(_A, "Xbcdef"), "first byte differs")
    assert_false(w.written_equals(_A, "abcXef"), "a middle byte differs")
    assert_false(w.written_equals(_A, "abcdeX"), "last byte differs")
    assert_false(w.written_equals(_A, "abcde"), "a prefix")
    assert_false(w.written_equals(_A, "abcdefg"), "an extension")
    assert_false(w.written_equals(_A, ""), "empty")

    # An empty value is a write: present, zero bytes, equal to "".
    w.write(_C, _v(""), "tok")
    assert_true(w.was_written(_C), "an empty value is written")
    assert_equal(w.written_len(_C), 0, "of zero bytes")
    assert_true(w.written_equals(_C, ""), "equal to the empty string")
    assert_false(w.written_equals(_C, "a"), "not equal to one byte")
    assert_equal(w.version_count(_C), 1, "an empty write mints a version")
    _ = w^


# =============================================================================
# (6) share() is a second handle over the same state.
# =============================================================================
def test_share_is_a_second_handle_over_one_state() raises:
    var w = StaticSecretWriter()
    var h = w.share()
    h.write(_A, _v("via-share"), "tok-share")
    assert_equal(w.write_count(), 1, "the write shows on the first handle")
    assert_true(w.written_equals(_A, "via-share"), "with its value")
    assert_equal(w.version_count(_A), 1, "and its version")
    assert_equal(w.last_token(), "tok-share", "and its token")
    w.define_container(_B, "tok-first")
    assert_true(h.was_defined(_B), "a define shows on the shared handle")
    assert_equal(h.define_count(), 1, "with its count")
    assert_equal(h.last_token(), "tok-first", "and its token")

    var fresh = StaticSecretWriter()
    assert_equal(fresh.write_count(), 0, "a new writer does not share state")
    assert_false(fresh.was_written(_A), "nor the written refs")
    _ = fresh^
    _ = h^
    _ = w^


# =============================================================================
# (7) as_static_store maps each ref to its own value, as a copy.
# =============================================================================
def test_as_static_store_maps_each_ref_to_its_value() raises:
    var empty = StaticSecretWriter()
    var none = empty.as_static_store()
    with assert_raises(contains="no secret for secret_ref"):
        _ = none.resolve(_A)
    _ = none^
    _ = empty^

    var w = StaticSecretWriter()
    w.write(_A, _v("alpha-value"), "tok")
    w.write(_B, _v("b"), "tok")
    w.write(_C, _v(""), "tok")
    var store = w.as_static_store()

    var ra = store.resolve(_A)
    assert_true(
        _bytes_equal(ra.revealed_bytes(), String("alpha-value").as_bytes()),
        "A resolves to A's value",
    )
    var rb = store.resolve(_B)
    assert_true(
        _bytes_equal(rb.revealed_bytes(), String("b").as_bytes()),
        "B resolves to B's value",
    )
    var rc = store.resolve(_C)
    assert_equal(rc.len(), 0, "the empty value resolves empty")
    with assert_raises(contains="no secret for secret_ref"):
        _ = store.resolve(_UNKNOWN)

    # The store holds a copy: a later write does not reach it.
    w.write(_A, _v("rotated"), "tok")
    var ra2 = store.resolve(_A)
    assert_true(
        _bytes_equal(ra2.revealed_bytes(), String("alpha-value").as_bytes()),
        "the store keeps the value it was seeded with",
    )
    # The writer itself holds the rotated value, and a new store resolves it.
    assert_true(w.written_equals(_A, "rotated"), "the writer holds the rotation")
    var store2 = w.as_static_store()
    var ra3 = store2.resolve(_A)
    assert_true(
        _bytes_equal(ra3.revealed_bytes(), String("rotated").as_bytes()),
        "a store taken after the rotation resolves the rotated value",
    )
    _ = ra3^
    _ = store2^
    _ = ra^
    _ = rb^
    _ = rc^
    _ = ra2^
    _ = store^
    _ = w^


# =============================================================================
# (8) MAX_SECRET_LEN bytes of valid UTF-8 round-trip unchanged.
# =============================================================================
def _append_grin(mut raw: List[UInt8]):
    # U+1F600 grinning face: F0 9F 98 80.
    raw.append(UInt8(0xF0))
    raw.append(UInt8(0x9F))
    raw.append(UInt8(0x98))
    raw.append(UInt8(0x80))


def test_max_length_utf8_round_trip() raises:
    # Every ASCII byte 0x00..0x7F once, then the 9-byte cycle e-acute (2 bytes),
    # euro sign (3 bytes), grinning face (4 bytes) 440 times, then two grinning
    # faces: 128 + 3960 + 8 = 4096 bytes, every one a part of valid UTF-8.
    var raw = List[UInt8]()
    for i in range(128):
        raw.append(UInt8(i))
    for _ in range(440):
        raw.append(UInt8(0xC3))  # U+00E9 e-acute: C3 A9
        raw.append(UInt8(0xA9))
        raw.append(UInt8(0xE2))  # U+20AC euro sign: E2 82 AC
        raw.append(UInt8(0x82))
        raw.append(UInt8(0xAC))
        _append_grin(raw)
    _append_grin(raw)
    _append_grin(raw)
    assert_equal(len(raw), MAX_SECRET_LEN, "the fixture fills MAX_SECRET_LEN")
    var w = StaticSecretWriter()
    w.write(_A, SecretValue(Span(raw)), "tok")
    assert_equal(w.written_len(_A), MAX_SECRET_LEN, "every byte recorded")
    var same = String(StringSlice(from_utf8=Span(raw)))
    assert_true(w.written_equals(_A, same), "the recorded bytes equal the input")
    # The last character becomes the grinning face with smiling eyes: only the
    # last byte differs (0x80 -> 0x81) and the text stays valid UTF-8.
    var flipped = raw.copy()
    flipped[MAX_SECRET_LEN - 1] = UInt8(0x81)
    assert_false(
        w.written_equals(_A, String(StringSlice(from_utf8=Span(flipped)))),
        "the last byte is compared",
    )
    # A difference in bit 7 alone: e-acute (C3 A9) against "C)" (43 29), both
    # valid UTF-8; a comparison that dropped the high bit would call them equal.
    var e_acute = List[UInt8]()
    e_acute.append(UInt8(0xC3))
    e_acute.append(UInt8(0xA9))
    w.write(_B, SecretValue(Span(e_acute)), "tok")
    assert_true(
        w.written_equals(_B, String(StringSlice(from_utf8=Span(e_acute)))),
        "e-acute equals itself",
    )
    assert_false(w.written_equals(_B, "C)"), "bit 7 of each byte is compared")

    var store = w.as_static_store()
    var r = store.resolve(_A)
    assert_equal(r.len(), MAX_SECRET_LEN, "the resolved length")
    assert_true(
        _bytes_equal(r.revealed_bytes(), Span(raw)),
        "the resolved bytes equal the written bytes",
    )
    _ = r^
    _ = store^
    _ = w^


# =============================================================================
# (9) a value that is not UTF-8 is recorded, and as_static_store refuses it.
# =============================================================================
def test_non_utf8_value_is_recorded_but_not_resolvable() raises:
    # 0xFF never occurs in UTF-8; 0xC3 alone is a truncated 2-byte sequence.
    var raw = List[UInt8]()
    raw.append(UInt8(0x61))
    raw.append(UInt8(0xFF))
    raw.append(UInt8(0x62))
    var trunc = List[UInt8]()
    trunc.append(UInt8(0xC3))
    var w = StaticSecretWriter()
    w.write(_B, _v("fine"), "tok")
    w.write(_A, SecretValue(Span(raw)), "tok")
    assert_equal(w.written_len(_A), 3, "the bytes are recorded")
    assert_equal(w.version_count(_A), 1, "the write minted a version")
    try:
        _ = w.as_static_store()
        raise Error("as_static_store took a value that is not UTF-8")
    except e:
        var msg = String(e)
        assert_true(
            msg.find("example/app/smtp-relay' is not UTF-8") >= 0,
            "the refusal names the ref: " + msg,
        )
        assert_true(msg.find("resolve double holds only Strings") >= 0, msg)
        assert_true(msg.find("example/app/api-key") < 0, "not the valid ref: " + msg)

    # A truncated sequence alone is refused too; rewriting the value with UTF-8
    # makes the store whole again, with both refs.
    var t = StaticSecretWriter()
    t.write(_C, SecretValue(Span(trunc)), "tok")
    with assert_raises(contains="example/app/empty' is not UTF-8"):
        _ = t.as_static_store()
    _ = t^
    w.write(_A, _v("fixed"), "tok")
    var store = w.as_static_store()
    var ra = store.resolve(_A)
    assert_true(
        _bytes_equal(ra.revealed_bytes(), String("fixed").as_bytes()),
        "the rewritten value resolves",
    )
    var rb = store.resolve(_B)
    assert_equal(rb.len(), 4, "the other ref resolves")
    _ = ra^
    _ = rb^
    _ = store^
    _ = w^


def main() raises:
    test_unknown_ref_reads_as_absent()
    test_define_container_mints_no_version()
    test_version_count_per_ref_and_identical_rewrite()
    test_last_token_follows_each_verb()
    test_written_equals_rejects_one_byte_difference()
    test_share_is_a_second_handle_over_one_state()
    test_as_static_store_maps_each_ref_to_its_value()
    test_max_length_utf8_round_trip()
    test_non_utf8_value_is_recorded_but_not_resolvable()
    print("test_secret_writer_state: all cases PASSED")
