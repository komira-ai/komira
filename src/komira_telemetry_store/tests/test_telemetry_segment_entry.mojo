# =============================================================================
# komira_telemetry_store/tests/test_telemetry_segment_entry.mojo
#   THE FALSIFIER for `TelemetrySegmentEntry`: the manifest body that carries a
#   TIME RANGE, the one thing the whole layout turns on.
# =============================================================================
#
# Every case here is about a way a codec can be WRONG WITHOUT FAILING:
#
#   * a truncated body decoding to a zero-valued entry — `[min_ts=0,max_ts=0]`
#     answers `overlaps_time()` TRUE for any range containing the epoch and FALSE for
#     every real one, so a lenient decoder is a pruning oracle that LIES;
#   * an unknown version decoded with THIS build's field layout;
#   * a `merge_input_uuids` blob whose length is not a multiple of 16, so the
#     dup-window skip matches on a shifted window and drops a LIVE segment;
#   * `overlaps()` with exclusive bounds, which drops the object holding the row
#     exactly at the range edge.
#
# ROUND-TRIP EQUALITY IS ASSERTED FIELD BY FIELD, not by re-encoding and
# comparing bytes: encode(decode(x)) == encode(x) is satisfied by a codec that
# loses the SAME field in both directions.
# HERMETIC: pure bytes. No store, no I/O.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_telemetry_store.segment_entry import (
    TELEMETRY_SEGMENT_ENTRY_VERSION,
    TELEMETRY_UUID_BYTES,
    TelemetrySegmentEntry,
    decode_telemetry_segment_entry,
    encode_telemetry_segment_entry,
    make_log_segment_entry,
    uuid_in_flat,
)


def _uuid(fill: UInt8) -> InlineArray[UInt8, 16]:
    return InlineArray[UInt8, 16](fill=fill)


def _flat(var us: List[InlineArray[UInt8, 16]]) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(us)):
        for b in range(16):
            out.append(us[i][b])
    return out^


# =============================================================================
# CASE 1 — the round trip carries EVERY field, checked one at a time.
# =============================================================================


def test_01_round_trip_preserves_every_field() raises:
    var inputs = List[InlineArray[UInt8, 16]]()
    inputs.append(_uuid(UInt8(7)))
    inputs.append(_uuid(UInt8(9)))
    var e = TelemetrySegmentEntry(
        TELEMETRY_SEGMENT_ENTRY_VERSION,
        _uuid(UInt8(3)),
        String("telemetry/logs/20261001/data/00000000000000000042-aa.parquet"),
        Int64(1790812800_000_000_000),
        Int64(1790812860_000_000_000),
        Int64(11),
        Int64(99),
        Int64(1234),
        Int64(56789),
        Int64(2),
        _flat(inputs^),
        True,
    )
    var got = decode_telemetry_segment_entry(encode_telemetry_segment_entry(e))
    assert_equal(Int(got.version), Int(e.version), "1: version")
    for i in range(TELEMETRY_UUID_BYTES):
        assert_equal(Int(got.segment_uuid[i]), 3, "1: segment_uuid byte")
    assert_equal(got.object_key, e.object_key, "1: object_key")
    assert_equal(got.min_ts_ns, e.min_ts_ns, "1: min_ts_ns — THE pruning key")
    assert_equal(got.max_ts_ns, e.max_ts_ns, "1: max_ts_ns — THE pruning key")
    assert_equal(got.min_series_id, e.min_series_id, "1: min_series_id")
    assert_equal(got.max_series_id, e.max_series_id, "1: max_series_id")
    assert_equal(got.row_count, e.row_count, "1: row_count")
    assert_equal(got.byte_size, e.byte_size, "1: byte_size")
    assert_equal(got.merge_ops, e.merge_ops, "1: merge_ops")
    assert_equal(
        got.num_merge_inputs(),
        2,
        "1: merge_input_uuids — the dup-window skip set. Losing it means a"
        " reader returns a merged segment AND its inputs, i.e. every row twice",
    )
    assert_true(
        uuid_in_flat(got.merge_input_uuids, _uuid(UInt8(9))),
        "1: ...and the SECOND input survives, not just the first",
    )
    assert_true(got.has_text_sidecar, "1: has_text_sidecar")
    assert_true(got.is_merged(), "1: merge_ops > 0 => is_merged")


def test_02_a_raw_log_entry_is_shaped_the_way_the_writer_makes_it() raises:
    var e = make_log_segment_entry(
        _uuid(UInt8(1)),
        String("telemetry/logs/20261001/data/x.parquet"),
        Int64(100),
        Int64(200),
        Int64(5),
        Int64(4096),
        False,
    )
    assert_equal(e.merge_ops, Int64(0), "2: a raw segment has merge_ops 0")
    assert_equal(e.num_merge_inputs(), 0, "2: ...and no merge inputs")
    assert_false(e.is_merged(), "2: ...and is not merged")
    assert_equal(
        e.min_series_id,
        Int64(0),
        "2: logs have no series axis (sort key is `(ts)` alone) — the field is"
        " carried so ONE body type serves both datasets, and it is ZERO here",
    )


# =============================================================================
# CASE 3 — overlaps() IS THE ENTIRE PRUNING DECISION. Closed on both ends.
# =============================================================================


def test_03_overlaps_is_inclusive_at_both_ends() raises:
    var e = make_log_segment_entry(
        _uuid(UInt8(1)), String("k.parquet"),
        Int64(100), Int64(200), Int64(5), Int64(1), False,
    )
    assert_true(e.overlaps_time(Int64(150), Int64(160)), "3: strictly inside")
    assert_true(e.overlaps_time(Int64(0), Int64(1000)), "3: strictly outside")
    assert_true(
        e.overlaps_time(Int64(200), Int64(300)),
        "3: a query starting EXACTLY at max_ts must keep this object — the row"
        " at ts=200 is in the answer, and an exclusive upper bound would prune"
        " away the only object holding it",
    )
    assert_true(
        e.overlaps_time(Int64(0), Int64(100)),
        "3: a query ending EXACTLY at min_ts must keep this object, same reason",
    )
    assert_false(
        e.overlaps_time(Int64(201), Int64(300)),
        "3: one ns past max_ts prunes OUT — and this is the assertion that"
        " makes the whole layout worth anything. If it were true, every query"
        " would fetch every object and the manifest range would be decoration",
    )
    assert_false(e.overlaps_time(Int64(0), Int64(99)), "3: below min_ts prunes OUT")


# =============================================================================
# CASE 4 — FAIL-LOUD. A codec that folds a bad read to a default publishes a
# pruning oracle that lies.
# =============================================================================


def test_04_a_truncated_body_raises_rather_than_decoding_to_zeros() raises:
    var e = make_log_segment_entry(
        _uuid(UInt8(1)),
        String("telemetry/logs/20261001/data/x.parquet"),
        Int64(1790812800_000_000_000), Int64(1790812860_000_000_000),
        Int64(5), Int64(4096), False,
    )
    var full = encode_telemetry_segment_entry(e)
    # Truncate at every length short of the full body. EVERY one must raise —
    # a single length that silently decodes is a body a reader will trust.
    var raised = 0
    for cut in range(len(full)):
        var short = List[UInt8](capacity=cut)
        for i in range(cut):
            short.append(full[i])
        try:
            _ = decode_telemetry_segment_entry(short)
        except:
            raised += 1
    assert_equal(
        raised,
        len(full),
        "4: EVERY truncation must raise. A prefix that decodes yields an entry"
        " with a zeroed [min_ts,max_ts], which prunes IN for any range"
        " containing the epoch and OUT of every real query — silently",
    )
    # POSITIVE CONTROL: the untruncated body still decodes, so the loop above
    # is measuring truncation and not a codec that raises on everything.
    var ok = decode_telemetry_segment_entry(full)
    assert_equal(ok.min_ts_ns, e.min_ts_ns, "4: positive control — full body decodes")


def test_05_an_unknown_body_version_is_refused() raises:
    var e = make_log_segment_entry(
        _uuid(UInt8(1)), String("x.parquet"),
        Int64(1), Int64(2), Int64(1), Int64(1), False,
    )
    var body = encode_telemetry_segment_entry(e)
    body[0] = UInt8(200)
    var refused = False
    try:
        _ = decode_telemetry_segment_entry(body)
    except:
        refused = True
    assert_true(
        refused,
        "5: an unknown version must RAISE, not be parsed with THIS build's"
        " field layout. A future body that adds a field before min_ts_ns would"
        " otherwise decode a byte-offset time range — plausible numbers,"
        " completely wrong pruning",
    )
    # Version 1 is permanently reserved: refused BY NAME, not as "unknown".
    body[0] = UInt8(1)
    var v1_message = String("")
    try:
        _ = decode_telemetry_segment_entry(body)
    except err:
        v1_message = String(err)
    assert_true(
        v1_message.find(String("REFUSING body version 1")) >= 0,
        "5: version 1 is reserved and is refused by name."
        " Got: " + v1_message,
    )
    var empty_refused = False
    try:
        _ = decode_telemetry_segment_entry(List[UInt8]())
    except:
        empty_refused = True
    assert_true(empty_refused, "5: an empty body must RAISE")


def test_06_a_partial_merge_uuid_is_refused() raises:
    var inputs = List[InlineArray[UInt8, 16]]()
    inputs.append(_uuid(UInt8(7)))
    var e = TelemetrySegmentEntry(
        TELEMETRY_SEGMENT_ENTRY_VERSION, _uuid(UInt8(3)), String("x.parquet"),
        Int64(1), Int64(2), Int64(0), Int64(0), Int64(1), Int64(1), Int64(1),
        _flat(inputs^), False,
    )
    var body = encode_telemetry_segment_entry(e)
    # Claim 15 bytes of merge uuids instead of 16, so the body is LONG ENOUGH
    # (the decoder's truncation check passes) but the blob is not a whole number
    # of uuids. The tail layout is [merge_len i64 LE][16 uuid bytes][flag u8],
    # so the length prefix's LOW byte sits at len - 1 - 16 - 8.
    #
    # THE OFFSET IS LOAD-BEARING AND WAS WRONG ONCE. One byte off writes into
    # the SECOND byte of the little-endian i64, making the claimed length 3856
    # instead of 15 — the decoder then raises TRUNCATED, the case still goes
    # green, and the multiple-of-16 branch this test is named for never runs.
    # That is why the assertion below reads the MESSAGE, not just "it raised".
    var n = len(body)
    var doctored = body.copy()
    var lenoff = n - 1 - 16 - 8
    doctored[lenoff] = UInt8(15)
    var refused = False
    var msg = String("")
    try:
        _ = decode_telemetry_segment_entry(doctored)
    except e2:
        refused = True
        msg = String(e2)
    assert_true(
        refused,
        "6: a merge_input_uuids blob whose length is not a multiple of 16 must"
        " RAISE. `uuid_in_flat` walks it in 16-byte groups, so a shifted window"
        " would match the WRONG segment and silently drop a live one from the"
        " read",
    )
    assert_true(
        msg.find(String("multiple of")) >= 0,
        "6: ...and it must raise AT THE GROUPING CHECK, not at the truncation"
        " check. A raise from the wrong branch means this case is not testing"
        " what it is named for. Got: " + msg,
    )


def test_07_an_empty_or_inverted_segment_is_never_published() raises:
    var empty_refused = False
    try:
        _ = make_log_segment_entry(
            _uuid(UInt8(1)), String("x.parquet"),
            Int64(1), Int64(2), Int64(0), Int64(1), False,
        )
    except:
        empty_refused = True
    assert_true(
        empty_refused,
        "7: a 0-row segment must RAISE — its [min,max] is meaningless and a"
        " reader would GET an object holding nothing",
    )
    var inverted_refused = False
    try:
        _ = make_log_segment_entry(
            _uuid(UInt8(1)), String("x.parquet"),
            Int64(9), Int64(2), Int64(1), Int64(1), False,
        )
    except:
        inverted_refused = True
    assert_true(
        inverted_refused,
        "7: max_ts < min_ts must RAISE — an inverted range prunes IN for"
        " nothing and OUT for everything",
    )


def test_08_uuid_in_flat_matches_only_on_a_group_boundary() raises:
    var us = List[InlineArray[UInt8, 16]]()
    us.append(_uuid(UInt8(1)))
    us.append(_uuid(UInt8(2)))
    var flat = _flat(us^)
    assert_true(uuid_in_flat(flat, _uuid(UInt8(1))), "8: first group matches")
    assert_true(uuid_in_flat(flat, _uuid(UInt8(2))), "8: second group matches")
    assert_false(uuid_in_flat(flat, _uuid(UInt8(3))), "8: absent uuid does NOT")
    # A uuid that STRADDLES the boundary (eight 1s then eight 2s) exists in the
    # flat bytes but is not a member. A byte-window scan would match it.
    var straddle = InlineArray[UInt8, 16](fill=UInt8(1))
    for i in range(8, 16):
        straddle[i] = UInt8(2)
    assert_false(
        uuid_in_flat(flat, straddle),
        "8: a uuid straddling two groups must NOT match. It is present in the"
        " byte stream; matching it would skip a LIVE segment from the read as"
        " though a merge had absorbed it — dropped rows, no error",
    )
    assert_false(uuid_in_flat(List[UInt8](), _uuid(UInt8(1))), "8: empty set")


# =============================================================================
# CASE 9 — THE ENVELOPE'S FIELD ORDER, PINNED AT BYTE OFFSETS, BECAUSE TWO
#   DIFFERENT ORDERS UNDER ONE VERSION BYTE ARE INDISTINGUISHABLE.
#
# The documented order is
#
#   [ver][uuid16][LP object_key][7 x i64][i64 n_merge][merge bytes][flag u8]
#
# An implementation that ordered the same fields differently under the SAME
# version byte would not be refused by this decoder (nor refuse these bytes):
# handing it these bytes makes it read the object key's LENGTH PREFIX as
# `min_ts_ns` and the key's first eight text bytes as `max_ts_ns`, a segment
# that prunes ITSELF out of every real time range, before it raises on a
# garbage length prefix further in. Either way the time-range read does not
# return the rows.
#
# THE ORDER IS PART OF THE FORMAT, and this case is where that is enforced
# rather than described.
#
# NO ROUND-TRIP TEST CAN SEE THIS. `encode`/`decode` agree with each other
# under ANY order, so CASE 1 is green for both layouts. Only an assertion on the
# BYTES separates them, which is what this case is.
# =============================================================================


def _le_i64_at(bytes: List[UInt8], off: Int) raises -> Int64:
    """Read a little-endian i64 out of the encoded envelope, for offset
    assertions. Deliberately NOT the module's own `_get_i64_le`: a test that
    reads the bytes back with the encoder's own private helper cannot detect a
    change that moves both together."""
    if off + 8 > len(bytes):
        raise Error("test: i64 read past the end of the envelope")
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(bytes[off + i])) << UInt64(8 * i)
    return Int64(u)


def test_09_the_envelope_field_order_is_the_documented_one() raises:
    var key = String(
        "telemetry/logs/20261001/data/00000000000000000042-aa.parquet"
    )
    var klen = key.byte_length()
    var inputs = List[InlineArray[UInt8, 16]]()
    inputs.append(_uuid(UInt8(4)))
    inputs.append(_uuid(UInt8(5)))
    var min_ts = Int64(1790812800_000_000_000)
    var max_ts = Int64(1790812860_000_000_000)
    var e = TelemetrySegmentEntry(
        TELEMETRY_SEGMENT_ENTRY_VERSION,
        _uuid(UInt8(3)),
        key,
        min_ts,
        max_ts,
        Int64(11),
        Int64(99),
        Int64(1234),
        Int64(56789),
        Int64(2),
        _flat(inputs^),
        True,
    )
    var enc = encode_telemetry_segment_entry(e)

    # ---- the fixed header: version, then the 16 uuid bytes. ----
    assert_equal(
        Int(enc[0]),
        Int(TELEMETRY_SEGMENT_ENTRY_VERSION),
        "9: the version byte leads the envelope",
    )
    for i in range(TELEMETRY_UUID_BYTES):
        assert_equal(
            Int(enc[1 + i]), 3, "9: segment_uuid occupies bytes 1..17"
        )

    # ---- THE DISCRIMINATING ASSERTION. ----
    assert_equal(
        _le_i64_at(enc, 17),
        Int64(klen),
        "9: `object_key` IS THE FIRST VARIABLE-LENGTH FIELD — its LENGTH"
        " PREFIX sits at byte 17, immediately after the uuid, as the"
        " documented order has it. A decoder written to an order with the SEVEN"
        " i64s here would read this key length as `min_ts_ns` and prune the"
        " segment out of every real time range without ever refusing the"
        " body. If this assertion moved, the format changed under a version"
        " byte that did not",
    )
    assert_equal(
        Int(enc[25]),
        Int(key.as_bytes()[0]),
        "9: the key's own bytes follow its length prefix at byte 25",
    )

    # ---- the seven i64s, in the documented order, AFTER the key. ----
    var ts_off = 25 + klen
    assert_equal(_le_i64_at(enc, ts_off), min_ts, "9: min_ts_ns follows the key")
    assert_equal(_le_i64_at(enc, ts_off + 8), max_ts, "9: then max_ts_ns")
    assert_equal(_le_i64_at(enc, ts_off + 16), Int64(11), "9: min_series_id")
    assert_equal(_le_i64_at(enc, ts_off + 24), Int64(99), "9: max_series_id")
    assert_equal(_le_i64_at(enc, ts_off + 32), Int64(1234), "9: row_count")
    assert_equal(_le_i64_at(enc, ts_off + 40), Int64(56789), "9: byte_size")
    assert_equal(_le_i64_at(enc, ts_off + 48), Int64(2), "9: merge_ops")

    # ---- the merge-input blob, then the flag LAST. ----
    assert_equal(
        _le_i64_at(enc, ts_off + 56),
        Int64(32),
        "9: `merge_input_uuids` is length-prefixed and ALWAYS written — two"
        " 16-byte uuids here",
    )
    assert_equal(
        len(enc),
        klen + 122,
        "9: the envelope is exactly 1 + 16 + 8 + klen + 56 + 8 + 32 + 1 bytes."
        " A size that drifts means a field was added, moved or dropped and the"
        " offsets above no longer describe the format",
    )
    assert_equal(
        Int(enc[len(enc) - 1]),
        1,
        "9: `has_text_sidecar` is the LAST byte of the envelope, not a field"
        " ahead of `object_key`",
    )


def main() raises:
    test_01_round_trip_preserves_every_field()
    test_02_a_raw_log_entry_is_shaped_the_way_the_writer_makes_it()
    test_03_overlaps_is_inclusive_at_both_ends()
    test_04_a_truncated_body_raises_rather_than_decoding_to_zeros()
    test_05_an_unknown_body_version_is_refused()
    test_06_a_partial_merge_uuid_is_refused()
    test_07_an_empty_or_inverted_segment_is_never_published()
    test_08_uuid_in_flat_matches_only_on_a_group_boundary()
    test_09_the_envelope_field_order_is_the_documented_one()
    print("PASS komira_telemetry_store.test_telemetry_segment_entry (the")
    print("     manifest body carries a TIME RANGE, prunes on CLOSED bounds,")
    print("     and RAISES on every shape that would decode into a pruning")
    print("     oracle that lies)")
