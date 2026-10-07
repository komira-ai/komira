# =============================================================================
# test_plain_ba_fused_byte_equiv — the fused PLAIN BYTE_ARRAY walk
#     (`set_plain_ba_fused_enabled`) byte-equivalence oracle
# =============================================================================
#
# `plain.decode_plain_byte_array` has two walks of a PLAIN BYTE_ARRAY page. The
# two-pass walk reads every 4-byte length prefix to size the destination, then
# RE-READS every one of those prefixes and copies the bodies. The second walk
# recomputes `str_len` for every value and re-traverses the page — work pass 1
# already did.
#
# The second pass exists for ONE reason: `total_data_bytes` is not known until
# every length has been read, so the data buffer cannot be allocated before the
# walk. It buys no lifetime, no alignment and no ownership. `data_len -
# 4*num_values` is an EXACT bound for a conforming page, so the pass is
# removable — which is what `_decode_plain_ba_fused` does.
#
# ---------------------------------------------------------------------------
# ⚠ WHAT EACH TEST IS THE FALSIFIER FOR, AND WHICH MUTATION KILLS IT
# ---------------------------------------------------------------------------
# A falsifier that some OTHER guard also catches is not a falsifier for this
# change. Each row names a mutation of the PRODUCTION code and the ONE
# assertion here that goes RED under it.
#
#   M1  `_decode_plain_ba_fused`: drop the `fast_copy_bytes` call
#         -> KILLED BY `test_arms_are_byte_identical_on_conforming_pages`
#            (the per-byte data-buffer comparison).
#   M2  `_decode_plain_ba_fused`: drop `offsets_buf.set_typed(i + 1, ...)`
#         -> KILLED BY the same test's offsets comparison.
#   M3  `_decode_plain_ba_fused`: use the LEGACY bound
#       `str_len > data_len - pos` instead of the prefix-reserve bound
#         -> KILLED BY `test_prefix_reserve_rejects_the_capacity_witness`.
#            ⚠ THIS IS THE MUTATION THAT WOULD OTHERWISE SURVIVE. Under it the
#            witness page STILL RAISES (on value 1, from the legacy truncated-
#            prefix check) after a 100-byte write into a 96-byte buffer, so a
#            test that only asserts "raised" is GREEN on a heap overflow. The
#            assertion is therefore on the ERROR TEXT and on WHICH VALUE INDEX
#            the error names.
#   M4  `_decode_plain_ba_fused`: drop the up-front
#       `num_values > data_len >> 2` refusal
#         -> KILLED BY `test_page_too_small_for_its_prefixes_is_refused_up_front`
#            (again on the message, because the walk raises anyway — one value
#            later, and only after `4 * num_values` has been computed on a
#            header-supplied `num_values`).
#   M5  `_decode_plain_ba_fused`: drop `data_buf.set_length(total_data_bytes)`
#         -> KILLED BY `test_arms_are_byte_identical_on_conforming_pages`
#            (`data.len()` must equal the two-pass arm's).
#   M6  `_decode_plain_ba_fused`: drop the slack `memset`
#         -> ⛔ NOT FALSIFIABLE FROM ANY TEST, AND THAT IS MEASURED: the
#            mutation was run and came back GREEN. `StringArray` holds
#            `SharedAlignedBuffer`s, and SAB CARRIES NO SEPARATE CAPACITY
#            (`shared_aligned_buffer.capacity()` returns `_length`;
#            `into_span_capacity` is sized to `_length` and says so). So the
#            region `[total_data_bytes, cap)` the memset covers is UNREACHABLE
#            through the public API — no oracle can read it. It is kept anyway
#            for ONE narrow reason: a SIMD consumer that rounds its read up to
#            a 64-byte boundary would, on a slack page, read dirty heap where
#            the two-pass arm gives it `OwnedAlignedBuffer`'s zeroed pad. That
#            is a real divergence between the arms and it costs a memset of
#            ZERO bytes on every conforming page. ⚠ Do not add a test claiming
#            to cover it; claiming a falsifier that does not exist is worse
#            than naming the gap.
#   M7  `_decode_plain_ba_fused`: allocate `data_len` instead of the exact
#       bound (i.e. "just over-allocate, it is only 4 bytes a value")
#         -> KILLED BY `test_a_conforming_page_costs_zero_extra_bytes`
#            (`plain_ba_fused_alloc_bytes() <= payload + 64`). ⚠ THE FIRST CUT
#            OF THAT ASSERTION USED `plain_ba_slack_bytes() == 0` AND THE
#            MUTATION SURVIVED: `slack` is derived from `cap`, and M7 changes
#            the ALLOCATION while leaving `cap` alone, so the model said 0 and
#            the allocator said otherwise. The counter now reads
#            `data_buf.capacity()` back from the buffer. This is the assertion
#            that makes the claim — "the deletion adds nothing" — a
#            READING rather than an argument.
#   M8  `plain.decode_plain_byte_array`: make the dispatch call the two-pass
#       arm on BOTH branches (i.e. the lever never arms)
#         -> KILLED BY `test_dictionary_page_decode_takes_the_gated_arm`, which
#            drives a PRODUCTION call site (`DictionaryDecoder.
#            init_dict_byte_array`) with the gate off and then on and asserts
#            the FUSED counter moved, and by
#            `test_a_conforming_page_costs_zero_extra_bytes`: only
#            the fused walk records its allocation, so with the gate ON
#            `plain_ba_fused_alloc_bytes() >= payload` fails. ⛔ None of the
#            byte-equality tests can catch it: they would keep comparing the
#            two-pass arm against itself and pass.
#   M9  `scan_copy_trace.plain_ba_fused_enabled` reads the latch the wrong way
#       round
#         -> KILLED BY `test_gate_flips_in_process`.
#
# Every page here is hand-built bytes.
#
# Hard-rule audit:
# - No UnsafePointer in any public signature (raw pointers stay inside the
#   single `_buf_from` helper and the snapshot reads).
# - No wildcard origins introduced. No address made from an integer.
# =============================================================================

from std.memory import unsafe_memcpy
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_true,
)

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer

from komira_parquet import DictionaryDecoder, decode_plain_byte_array
from komira_parquet.scan_copy_trace import (
    plain_ba_fused_alloc_bytes,
    plain_ba_fused_count,
    plain_ba_fused_enabled,
    plain_ba_slack_bytes,
    plain_ba_two_pass_count,
    reset_scan_copy_counts,
    set_plain_ba_fused_enabled,
)


# =============================================================================
# Helpers
# =============================================================================


def _u32_le(value: Int) -> List[UInt8]:
    """Little-endian 4-byte encoding, as a Parquet BYTE_ARRAY length prefix."""
    var out = List[UInt8]()
    out.append(UInt8(value & 0xFF))
    out.append(UInt8((value >> 8) & 0xFF))
    out.append(UInt8((value >> 16) & 0xFF))
    out.append(UInt8((value >> 24) & 0xFF))
    return out^


def _extend(mut dst: List[UInt8], src: List[UInt8]):
    for i in range(len(src)):
        dst.append(src[i])


def _buf_from(bytes: List[UInt8]) -> OwnedAlignedBuffer:
    """Copy `bytes` into a fresh aligned buffer, so the decoder under test
    receives a real heap allocation whose end is a real allocation end."""
    var n = len(bytes)
    var buf = OwnedAlignedBuffer(max(n, 1))
    if n > 0:
        var view = buf.view_range_mut(0, n)
        unsafe_memcpy(dest=view._unsafe_ptr(), src=bytes.unsafe_ptr(), count=n)
    buf.set_length(Int64(n))
    return buf^


def _plain_page(lengths: List[Int]) -> List[UInt8]:
    """Build a conforming PLAIN BYTE_ARRAY values section: `[u32 len][body]`
    repeated, EXACTLY packed (no trailing bytes). Bodies are a deterministic
    ramp so a dropped or misplaced copy is visible, not merely absent."""
    var page = List[UInt8]()
    for i in range(len(lengths)):
        var n = lengths[i]
        _extend(page, _u32_le(n))
        for b in range(n):
            page.append(UInt8((i * 31 + b * 7 + 1) & 0xFF))
    return page^


def _bytelen(s: String) -> Int:
    """UTF-8 byte length. Mojo has no `len(String)` — the ambiguity is
    deliberate — and every use here is an "is this message non-empty" test."""
    return s.byte_length()


struct _Snapshot(Movable):
    """A decoded StringArray's whole observable state, copied out as plain
    bytes so the comparison outlives the arrays and holds no pointer."""

    var offsets: List[UInt8]
    var data: List[UInt8]
    var length: Int
    var data_length: Int

    def __init__(
        out self,
        var offsets: List[UInt8],
        var data: List[UInt8],
        length: Int,
        data_length: Int,
    ):
        self.offsets = offsets^
        self.data = data^
        self.length = length
        self.data_length = data_length


def _assert_same_array(a: _Snapshot, b: _Snapshot, label: String) raises:
    """Byte-for-byte equality of two decoded StringArrays' observable state."""
    assert_equal(a.length, b.length, label + ": value count must match")
    assert_equal(
        a.data_length, b.data_length, label + ": data_length must match"
    )
    assert_equal(
        len(a.offsets),
        len(b.offsets),
        label + ": offsets buffer LENGTH must match",
    )
    assert_equal(
        len(a.data), len(b.data), label + ": data buffer LENGTH must match"
    )
    for i in range(len(a.offsets)):
        assert_equal(
            Int(a.offsets[i]),
            Int(b.offsets[i]),
            label + ": offsets byte " + String(i) + " differs",
        )
    for i in range(len(a.data)):
        assert_equal(
            Int(a.data[i]),
            Int(b.data[i]),
            label + ": data byte " + String(i) + " differs",
        )


def _decode_to_bytes(
    page: List[UInt8], data_len: Int, num_values: Int, fused: Bool
) raises -> _Snapshot:
    """Decode `page` on the requested arm and snapshot the result."""
    set_plain_ba_fused_enabled(fused)
    var buf = _buf_from(page)
    var view = buf.view_range_ro(0, data_len)
    var arr = decode_plain_byte_array(view.into_span(), num_values)

    var off = List[UInt8]()
    var ov = arr.offsets.view_ro()
    var op = ov._unsafe_ptr()
    for i in range(arr.offsets.len()):
        off.append((op + i)[])
    var dat = List[UInt8]()
    var dv = arr.data.view_ro()
    var dp = dv._unsafe_ptr()
    for i in range(arr.data.len()):
        dat.append((dp + i)[])
    var n = arr.length
    var dl = arr.data_length
    _ = arr^
    _ = buf^
    return _Snapshot(off^, dat^, n, dl)


def _raises_with(
    page: List[UInt8], data_len: Int, num_values: Int, fused: Bool
) raises -> String:
    """Decode on the requested arm; return the error text, or "" if it did not
    raise. Returning the TEXT is deliberate — see M3/M4 in the header: a
    mutation that removes a bound still raises, one value later, so "raised" is
    not a falsifier and the message is."""
    set_plain_ba_fused_enabled(fused)
    var buf = _buf_from(page)
    var view = buf.view_range_ro(0, data_len)
    var msg = String("")
    try:
        var arr = decode_plain_byte_array(view.into_span(), num_values)
        _ = arr^
    except e:
        msg = String(e)
    _ = buf^
    return msg^


# =============================================================================
# 1. Byte equivalence — the arms must be indistinguishable
# =============================================================================


def test_arms_are_byte_identical_on_conforming_pages() raises:
    """Every conforming page must decode to identical bytes on both arms.

    The length ladder is chosen against `fast_copy_bytes`' block structure and
    against the historic BYTE_ARRAY defects: 0 (the `str_len > 0` guard), 1,
    15/16/17 (the sub-vector band where the whole copy runs byte-at-a-time),
    31/32/33 and 63/64/65 (block boundaries), and 200 (multi-block with a
    tail). Leading AND trailing zero-length values are included because an
    empty value at the END is what makes `cap == total` land exactly."""
    var pages = List[List[UInt8]]()
    var counts = List[Int]()

    var a = List[Int]()
    a.append(0)
    pages.append(_plain_page(a))
    counts.append(len(a))

    var b = List[Int]()
    b.append(1)
    b.append(0)
    b.append(1)
    pages.append(_plain_page(b))
    counts.append(len(b))

    var c = List[Int]()
    for n in range(0, 34):
        c.append(n)
    pages.append(_plain_page(c))
    counts.append(len(c))

    var d = List[Int]()
    d.append(63)
    d.append(64)
    d.append(65)
    d.append(0)
    d.append(200)
    d.append(0)
    pages.append(_plain_page(d))
    counts.append(len(d))

    var e = List[Int]()
    e.append(0)
    e.append(0)
    e.append(0)
    pages.append(_plain_page(e))
    counts.append(len(e))

    for ci in range(len(pages)):
        var nvals = counts[ci]
        var dlen = len(pages[ci])
        var off_r = _decode_to_bytes(pages[ci], dlen, nvals, False)
        var on_r = _decode_to_bytes(pages[ci], dlen, nvals, True)
        _assert_same_array(off_r, on_r, "case " + String(ci))
    set_plain_ba_fused_enabled(False)
    print("  OK both arms emit byte-identical StringArrays on 5 page shapes")


def test_a_conforming_page_costs_zero_extra_bytes() raises:
    """⭐ THE READING: on a conforming page the fused arm's exact bound
    `data_len - 4*num_values` EQUALS `total_data_bytes`, so the deletion
    allocates byte-for-byte what the two-pass arm allocated.

    Asserted on the ALLOCATION read back from the buffer, not on the bound —
    see M7 in the header for why the bound-derived form could not see the
    mutation it was written for. The `+ 64` is `OwnedAlignedBuffer`'s stated
    SIMD tail pad (its own docstring: capacity is "rounded up to the next
    64-byte boundary"); the two-pass arm pays exactly the same pad, so
    "payload + at most one pad" IS "byte-for-byte what the two-pass arm
    allocated"."""
    reset_scan_copy_counts()
    var lengths = List[Int]()
    var payload = 0
    for n in range(0, 40):
        lengths.append(n * 3)
        payload += n * 3
    var page = _plain_page(lengths)
    var snap = _decode_to_bytes(page, len(page), len(lengths), True)
    assert_equal(snap.data_length, payload, "precondition: payload size")
    assert_equal(
        plain_ba_slack_bytes(),
        0,
        "an exactly-packed page must leave the fused arm's BOUND equal to the"
        " payload; a non-zero slack means the bound is not the exact one",
    )
    assert_true(
        plain_ba_fused_alloc_bytes() <= payload + 64,
        "the fused arm must ALLOCATE the payload plus at most one 64-byte SIMD"
        " pad. Allocated "
        + String(plain_ba_fused_alloc_bytes())
        + " for a payload of "
        + String(payload)
        + " — that is an over-allocation, not the exact bound",
    )
    assert_true(
        plain_ba_fused_alloc_bytes() >= payload,
        "the allocation must at least hold the payload",
    )
    reset_scan_copy_counts()
    set_plain_ba_fused_enabled(False)
    print("  OK the exact bound over-allocates 0 bytes on a conforming page")


def test_trailing_slack_decodes_identically_and_is_reported() raises:
    """A values window with TRAILING bytes past the last value still decodes
    identically, and the slack is REPORTED in bytes.

    ⚠ IT DOES NOT COVER THE ZEROING OF THAT SLACK, and the earlier name of this
    test claimed it did. `StringArray` holds `SharedAlignedBuffer`s, which carry
    no capacity distinct from their length, so the region the `memset` covers
    cannot be read back through any public API — the mutation was run and came
    back GREEN. See M6 in the header."""
    reset_scan_copy_counts()
    var lengths = List[Int]()
    lengths.append(3)
    lengths.append(5)
    var page = _plain_page(lengths)
    # 16 bytes of trailing slack inside the declared window.
    for i in range(16):
        page.append(UInt8(0xEE))
    var dlen = len(page)
    var nvals = len(lengths)

    var off_r = _decode_to_bytes(page, dlen, nvals, False)
    var on_r = _decode_to_bytes(page, dlen, nvals, True)
    _assert_same_array(off_r, on_r, "trailing-slack page")
    assert_equal(
        plain_ba_slack_bytes(),
        16,
        "the fused arm must REPORT the 16 bytes of window slack it"
        " over-allocated — that number is the honest size of the one thing"
        " this deletion introduces",
    )
    reset_scan_copy_counts()
    set_plain_ba_fused_enabled(False)
    print("  OK trailing slack: identical bytes, slack reported in bytes")


# =============================================================================
# 2. Acceptance equivalence — the arms must reject the same pages
# =============================================================================


def test_both_arms_reject_the_same_malformed_pages() raises:
    """Every malformed page the legacy arm rejects must be rejected by the
    fused arm too. The fused arm's bound is STRICTLY STRONGER, so the risk this
    covers is the other direction — a page the fused arm lets through."""
    # (a) oversized length prefix: 128 MiB declared out of an 8-byte page.
    var over = List[UInt8]()
    _extend(over, _u32_le(0x0800_0000))
    for _ in range(4):
        over.append(UInt8(65))
    assert_true(
        _bytelen(_raises_with(over, len(over), 1, False)) > 0,
        "legacy arm must reject an oversized length prefix",
    )
    assert_true(
        _bytelen(_raises_with(over, len(over), 1, True)) > 0,
        "fused arm must reject an oversized length prefix",
    )

    # (b) negative length prefix (read as a SIGNED Int32).
    var neg = List[UInt8]()
    _extend(neg, _u32_le(-1))
    for _ in range(4):
        neg.append(UInt8(65))
    assert_true(
        _bytelen(_raises_with(neg, len(neg), 1, False)) > 0,
        "legacy arm must reject a negative length prefix",
    )
    assert_true(
        _bytelen(_raises_with(neg, len(neg), 1, True)) > 0,
        "fused arm must reject a negative length prefix",
    )

    # (c) header promises more values than the body carries.
    var trunc = List[UInt8]()
    _extend(trunc, _u32_le(2))
    trunc.append(UInt8(65))
    trunc.append(UInt8(66))
    assert_true(
        _bytelen(_raises_with(trunc, len(trunc), 3, False)) > 0,
        "legacy arm must reject a walk that runs off the page",
    )
    assert_true(
        _bytelen(_raises_with(trunc, len(trunc), 3, True)) > 0,
        "fused arm must reject a walk that runs off the page",
    )
    set_plain_ba_fused_enabled(False)
    print("  OK both arms reject all three malformed page classes")


def test_prefix_reserve_rejects_the_capacity_witness() raises:
    """⭐ THE WITNESS THE EXACT BOUND EXISTS FOR — falsifier for M3.

    `data_len = 104, num_values = 2`, value 0 declaring length 100. The LEGACY
    per-value check proves only `str_len <= data_len - pos` = 100, so it
    ACCEPTS value 0 and raises only on value 1's missing prefix. A fused walk
    carrying that same bound would have written 100 bytes into the 96-byte
    buffer sized by `cap = 104 - 8` FIRST — a heap overflow behind a raise.

    So the assertion is on the MESSAGE and on the value INDEX it names, not on
    "did it raise": under M3 the page still raises, at value 1, after the
    overflow. Both arms must reject the page; only the fused one may name the
    reserve."""
    var page = List[UInt8]()
    _extend(page, _u32_le(100))
    for i in range(100):
        page.append(UInt8(i & 0xFF))
    assert_equal(len(page), 104, "witness page must be exactly 104 bytes")

    var legacy = _raises_with(page, 104, 2, False)
    assert_true(
        _bytelen(legacy) > 0, "the legacy arm must also reject the witness page"
    )

    var fused = _raises_with(page, 104, 2, True)
    assert_true(_bytelen(fused) > 0, "the fused arm must reject the witness page")
    assert_true(
        "later length prefixes are reserved" in fused,
        "the fused arm must reject the witness page ON THE PREFIX-RESERVE"
        " BOUND — without it the page is accepted at value 0 and overflows the"
        " destination before the walk raises. Got: "
        + fused,
    )
    assert_true(
        "value 0 " in fused,
        "the reserve must fire on value 0, BEFORE the copy; firing later means"
        " the overflow already happened. Got: "
        + fused,
    )
    set_plain_ba_fused_enabled(False)
    print("  OK the prefix reserve refuses the capacity witness at value 0")


def test_page_too_small_for_its_prefixes_is_refused_up_front() raises:
    """Falsifier for M4. `num_values` comes from the page header and is
    independent of the body, so a header can declare more values than the page
    could hold length prefixes for. The fused arm refuses that BEFORE computing
    `4 * num_values` (which is also what keeps that product from overflowing on
    a header-supplied count) and BEFORE allocating.

    Asserted on the message, because the walk raises under M4 too — one value
    later, from the truncated-prefix check."""
    var page = List[UInt8]()
    _extend(page, _u32_le(0))
    var fused = _raises_with(page, 4, 64, True)
    assert_true(
        "too few for the 4-byte length prefix" in fused,
        "a page smaller than 4 bytes per declared value must be refused up"
        " front, naming the prefix budget. Got: "
        + fused,
    )
    assert_true(
        _bytelen(_raises_with(page, 4, 64, False)) > 0,
        "the legacy arm must reject it too (one value later)",
    )
    set_plain_ba_fused_enabled(False)
    print("  OK an under-sized page is refused before the walk allocates")


# =============================================================================
# 3. The wiring — a PRODUCTION call site must reach the gated arm
# =============================================================================


def test_dictionary_page_decode_takes_the_gated_arm() raises:
    """⛔ THE FALSIFIER FOR M8 — the one no byte-equality test can be.

    Every test above calls `decode_plain_byte_array` directly. If the dispatch
    were reverted to call the two-pass arm on both branches, they would all
    keep comparing the two-pass arm against ITSELF and stay green. This drives
    a real production call site — `DictionaryDecoder.init_dict_byte_array`
    (`dictionary.mojo`), the PLAIN BYTE_ARRAY dictionary-page decode taken by
    every dictionary-encoded string column — with the gate off and then on, and
    asserts the FUSED counter moved and the resolved values are unchanged."""
    var lengths = List[Int]()
    lengths.append(5)
    lengths.append(0)
    lengths.append(11)
    lengths.append(3)
    var page = _plain_page(lengths)
    var nvals = len(lengths)

    reset_scan_copy_counts()

    set_plain_ba_fused_enabled(False)
    var buf_off = _buf_from(page)
    var dec_off = DictionaryDecoder()
    dec_off.init_dict_byte_array(
        buf_off.into_span_capacity()[: buf_off.len()], nvals
    )
    var vals_off = List[String]()
    for i in range(nvals):
        vals_off.append(dec_off.dict_values_bytes.value().get(i))
    _ = dec_off^
    _ = buf_off^

    var two_pass_after_off = plain_ba_two_pass_count()
    assert_true(
        two_pass_after_off >= 1,
        "the dictionary-page decode must reach the gated dispatch with the"
        " gate OFF (two-pass count did not move) — the call site is not wired",
    )
    assert_equal(
        plain_ba_fused_count(),
        0,
        "nothing may take the fused arm while the gate is OFF",
    )

    set_plain_ba_fused_enabled(True)
    var buf_on = _buf_from(page)
    var dec_on = DictionaryDecoder()
    dec_on.init_dict_byte_array(buf_on.into_span_capacity()[: buf_on.len()], nvals)
    var vals_on = List[String]()
    for i in range(nvals):
        vals_on.append(dec_on.dict_values_bytes.value().get(i))
    _ = dec_on^
    _ = buf_on^

    assert_equal(
        plain_ba_fused_count(),
        two_pass_after_off,
        "with the gate ON, every dictionary page that took the TWO-PASS arm"
        " with it off must now take the FUSED arm — an unequal count means"
        " the dispatch is not reached on this route",
    )
    assert_equal(
        plain_ba_two_pass_count(),
        two_pass_after_off,
        "the two-pass counter must NOT move again with the gate ON",
    )
    assert_equal(
        len(vals_on), len(vals_off), "resolved dictionary size must match"
    )
    for i in range(len(vals_off)):
        assert_equal(
            vals_on[i],
            vals_off[i],
            "dictionary entry " + String(i) + " must be unchanged by the arm",
        )
    assert_equal(
        plain_ba_slack_bytes(),
        0,
        "a writer-conforming dictionary page must cost zero extra bytes",
    )
    reset_scan_copy_counts()
    set_plain_ba_fused_enabled(False)
    print("  OK the dictionary-page call site reaches the gated arm")


# =============================================================================
# 4. The gate itself
# =============================================================================


def test_paired_counters_are_exclusive_and_cumulative() raises:
    """`fused + 2PASS` is the number of page traversals the lever is asked to
    delete. A page must be counted by exactly one of them, and the counts must
    be CUMULATIVE so the A/B can read the LAST dump line as the total."""
    reset_scan_copy_counts()
    var lengths = List[Int]()
    lengths.append(4)
    var page = _plain_page(lengths)

    _ = _decode_to_bytes(page, len(page), 1, False)
    assert_equal(plain_ba_two_pass_count(), 1, "the OFF arm counts 2PASS")
    assert_equal(plain_ba_fused_count(), 0, "the OFF arm must not count fused")

    _ = _decode_to_bytes(page, len(page), 1, True)
    assert_equal(plain_ba_fused_count(), 1, "the ON arm counts fused")
    assert_equal(
        plain_ba_two_pass_count(), 1, "the ON arm must not also count 2PASS"
    )

    _ = _decode_to_bytes(page, len(page), 1, True)
    assert_equal(plain_ba_fused_count(), 2, "counters must be CUMULATIVE")
    reset_scan_copy_counts()
    set_plain_ba_fused_enabled(False)
    print("  OK paired counters are exclusive and cumulative")


def test_zero_value_pages_are_counted_by_neither_arm() raises:
    """A zero-value page short-circuits before the dispatch, so it is not a
    traversal the lever can delete and must not inflate either half of the
    arming denominator."""
    reset_scan_copy_counts()
    var empty = List[UInt8]()
    empty.append(UInt8(0))
    _ = _decode_to_bytes(empty, 1, 0, True)
    _ = _decode_to_bytes(empty, 1, 0, False)
    assert_equal(
        plain_ba_fused_count(), 0, "a 0-value page is not a fused traversal"
    )
    assert_equal(
        plain_ba_two_pass_count(),
        0,
        "a 0-value page is not a two-pass traversal",
    )
    reset_scan_copy_counts()
    set_plain_ba_fused_enabled(False)
    print("  OK zero-value pages are counted by neither arm")


def test_gate_flips_in_process() raises:
    """The byte-equivalence oracle flips the arm many times in ONE process,
    through the setter; nothing is read from the environment."""
    set_plain_ba_fused_enabled(True)
    assert_true(
        plain_ba_fused_enabled(), "the setter must be able to force fusion ON"
    )
    set_plain_ba_fused_enabled(False)
    assert_false(
        plain_ba_fused_enabled(), "the setter must be able to force fusion OFF"
    )
    print("  OK the setter flips the latch in-process")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
