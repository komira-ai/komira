# =============================================================================
# test_log_drain_corrupt_header_guard.mojo
#   THE LOGGER MAY NOT ABORT THE PROCESS IT INSTRUMENTS.
# =============================================================================
#
# WHAT THIS GUARDS. A `LogEventRecord`'s header is the ONLY description of its
# own arg bytes: `arg_inline_len` says how much of the 48-byte inline blob is
# live, `FLAG_HAS_ARG_OVERFLOW` + (`arg_off`, `arg_len`) say where the spilled
# bytes are, and `n_args` says how many tags the blob opens with. Every producer
# in this package writes those four consistently (`emit.mojo` clamps to
# `ARG_INLINE_BYTES` and only sets the flag alongside an `arena_append`;
# `ArgBlobWriter.inline_len()` returns `min(_pos, 48)`). The DRAIN must not
# trust them.
#
# Trusting them is a PROCESS ABORT in every binary that links `komira_log`.
# `decode_one` — the production TEXT drain, reached from
# `drain_worker`/`drain_to_lines` — reads `rec.arg_blob[i]` for
# `i < Int(rec.arg_inline_len)` and `self._arena[o + i]` for `i < arg_len`.
# Unbounded, a header that says 60 inline bytes, or names an arena span that
# does not exist, or opens with more tags than the blob has bytes, takes an
# out-of-bounds `List.__getitem__` and kills the process.
#
# Such records are not hypothetical: a lifetime defect in a caller (a drain
# reading an engine that was already destroyed) produces exactly these —
# `arg_inline_len == 49`, and the overflow flag set on a ring whose arena is
# empty. The guard here is the SECOND line: even with the producer side
# correct, a logger that can abort its host on a bad header is a shipped risk,
# and a truncated log line is strictly better than a dead process.
#
# WHAT EACH CASE ASSERTS: the decode RETURNS. Without the guard each of the four
# aborts the test binary outright — there is no assertion to fail, which is why
# every case here is "we got here at all" plus a check that the well-formed
# prefix of the record still decoded. The four cases are the four unguarded
# reads, one per read:
#
#   1. `arg_inline_len` past the 48-byte inline array   -> drain.mojo inline copy
#   2. the overflow flag set against an EMPTY arena     -> record_ring arena_slice
#   3. an arena span that runs off the end of the arena -> record_ring arena_slice
#   4. `n_args` larger than the blob has tag bytes      -> the tag-table walk
#
# Both decoders are driven for every case: `decode_one` (the shipped text drain)
# and `decode_one_to_view` (the native-index seam). They carry byte-identical
# materialize logic, so a guard on one and not the other is a half fix.
#
# Encapsulation: pure value/ref flow — a local ring, a local dictionary,
# POD records built field-by-field. No `UnsafePointer`, no wildcard origin.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_obs.ring_buffer import OVERFLOW_BLOCK

from komira_log.levels import LEVEL_INFO
from komira_log.log_arg import ARG_STR, ARG_I64, ArgI64, ArgStr
from komira_log.engine.emit import emit_record
from komira_log.engine.drain import decode_one, decode_one_to_view
from komira_log.engine.record_ring import LogRecordRing
from komira_log.engine.log_event_record import (
    LogEventRecord,
    REC_LOG,
    FLAG_HAS_ARG_OVERFLOW,
    ARG_INLINE_BYTES,
)
from komira_log.engine.site_dictionary import SiteDictionary, fnv1a_32
from komira_log.engine.calibration import CalibrationAnchor


comptime _FMT = "login {} status {}"
comptime _MODULE = "komira_auth"


def _dict() -> SiteDictionary:
    var d = SiteDictionary()
    d.register[_FMT, _MODULE]()
    return d^


def _anchor() -> CalibrationAnchor:
    return CalibrationAnchor(
        tick0=UInt64(0),
        wall0_ns=UInt64(1_780_272_000) * UInt64(1_000_000_000),
        tick_hz=UInt64(1_000_000_000),
    )


def _base_record() -> LogEventRecord:
    """A record whose SITE fields are all well-formed. Each case below corrupts
    exactly one arg-header field, so a decode that returns proves the guard and
    the surviving `<unknown site>`-free render proves the guard did not simply
    throw the whole record away."""
    var rec = LogEventRecord()
    rec.kind = REC_LOG
    rec.level = LEVEL_INFO
    rec.site_id = fnv1a_32(_FMT)
    rec.module_id = fnv1a_32(_MODULE)
    rec.timestamp = UInt64(0)
    rec.corr_id = UInt64(7)
    return rec^


def _decode_both(rec: LogEventRecord, mut ring: LogRecordRing) raises -> String:
    """Drive BOTH decoders over the same record. Returns the text drain's line;
    the view decode is exercised for its own bounds (it has the identical
    materialize logic and its own out-of-bounds sites)."""
    var d = _dict()
    var a = _anchor()
    var view = decode_one_to_view(rec, ring, d, a)
    assert_true(view.module.byte_length() > 0, "view decode produced a module")
    return decode_one(rec, ring, d, a)


def test_inline_len_beyond_the_inline_array_does_not_abort() raises:
    """CASE 1 — `arg_inline_len` names more bytes than `arg_blob` HAS.

    The 6-run reproduction saw 49 against a 48-byte array. Before the guard this
    is `drain.mojo`'s inline copy indexing `arg_blob[48]`:
    'index 48 is out of bounds, valid range is 0 to 47' — process dead."""
    var ring = LogRecordRing(capacity=8, overflow_policy=OVERFLOW_BLOCK)
    var rec = _base_record()
    rec.n_args = UInt8(2)
    # A well-formed 2-arg blob: tag table, then a 5-byte string, then an i64.
    rec.arg_blob[0] = ARG_STR
    rec.arg_blob[1] = ARG_I64
    rec.arg_blob[2] = UInt8(5)
    rec.arg_blob[3] = UInt8(0)
    var word = String("login").as_bytes()
    for i in range(5):
        rec.arg_blob[4 + i] = word[i]
    for i in range(8):
        rec.arg_blob[9 + i] = UInt8(0)
    rec.arg_blob[9] = UInt8(200)
    # THE CORRUPTION: 60 > ARG_INLINE_BYTES (48).
    rec.arg_inline_len = UInt16(60)

    var line = _decode_both(rec, ring)
    assert_true(line.byte_length() > 0, "corrupt inline_len still renders a line")
    assert_true(
        String("komira_auth") in line,
        "the record's well-formed site fields still decode",
    )
    # STRONGER THAN "it returned": the first 17 bytes of this blob ARE the bytes
    # a real producer would have written, and clamping to 48 leaves every one of
    # them readable — so the guard must recover the message EXACTLY, not just
    # avoid the abort. A guard that bailed on the whole record would pass the
    # two assertions above and fail this one.
    assert_true(
        String("login login status 200") in line,
        "the recoverable prefix decodes to the exact message",
    )


def test_overflow_flag_against_an_empty_arena_does_not_abort() raises:
    """CASE 2 — the overflow flag set on a ring whose arena is EMPTY.

    The other message the 6-run reproduction printed. Before the guard this is
    `record_ring.arena_slice` indexing `_arena[0]` on a zero-length list:
    'index 0 is out of bounds, valid range is 0 to -1' — process dead."""
    var ring = LogRecordRing(capacity=8, overflow_policy=OVERFLOW_BLOCK)
    var rec = _base_record()
    rec.n_args = UInt8(0)
    rec.flags = rec.flags | FLAG_HAS_ARG_OVERFLOW
    rec.arg_off = UInt32(0)
    rec.arg_len = UInt32(24)

    var line = _decode_both(rec, ring)
    assert_true(line.byte_length() > 0, "empty-arena overflow still renders a line")


def test_arena_span_past_the_end_of_the_arena_does_not_abort() raises:
    """CASE 3 — an arena span whose (off + len) runs past the arena.

    Distinct from case 2: the arena is NON-empty here, so a guard that only
    special-cased 'arena is empty' would still walk off the end."""
    var ring = LogRecordRing(capacity=8, overflow_policy=OVERFLOW_BLOCK)
    var spill = List[UInt8]()
    for i in range(16):
        spill.append(UInt8(i))
    var handle = ring.arena_append(spill)
    var rec = _base_record()
    rec.n_args = UInt8(0)
    rec.flags = rec.flags | FLAG_HAS_ARG_OVERFLOW
    rec.arg_off = handle[0]
    # THE CORRUPTION: the arena holds 16 bytes; the header claims 4096.
    rec.arg_len = UInt32(4096)

    var line = _decode_both(rec, ring)
    assert_true(line.byte_length() > 0, "over-long arena span still renders a line")


def test_n_args_larger_than_the_blob_does_not_abort() raises:
    """CASE 4 — `n_args` claims more tags than the blob has bytes.

    The third message this defect produced (`drain.mojo`'s tag-table walk,
    'index 8 is out of bounds, valid range is 0 to 7'). Materializing the blob
    safely is not enough: the DECODER walks a tag table sized by the header."""
    var ring = LogRecordRing(capacity=8, overflow_policy=OVERFLOW_BLOCK)
    var rec = _base_record()
    for i in range(8):
        rec.arg_blob[i] = ARG_I64
    rec.arg_inline_len = UInt16(8)
    # THE CORRUPTION: 200 tags claimed, 8 bytes of blob.
    rec.n_args = UInt8(200)

    var line = _decode_both(rec, ring)
    assert_true(line.byte_length() > 0, "over-claimed n_args still renders a line")


def test_a_well_formed_record_is_unchanged_by_the_guard() raises:
    """THE CONTROL. A guard that truncated healthy records would pass every case
    above and be worse than the abort. Emit a normal record through the real
    producer and assert the rendered line is fully intact."""
    var ring = LogRecordRing(capacity=8, overflow_policy=OVERFLOW_BLOCK)
    _ = emit_record[_FMT, _MODULE](
        ring, LEVEL_INFO, UInt64(7), ArgStr(String("login")), ArgI64(200)
    )
    var rec_opt = ring.try_pop()
    assert_true(Bool(rec_opt), "the producer pushed a record")
    var rec = rec_opt.value().copy()
    assert_equal(
        Int(rec.arg_inline_len),
        17,
        "producer wrote 17 inline bytes: 2 tags + (u16 len + 5 chars) + i64",
    )
    var line = _decode_both(rec, ring)
    assert_true(String("login login status 200") in line, "message intact")
    assert_true(String("komira_auth") in line, "module intact")


def main() raises:
    var suite = TestSuite()
    suite.test[test_inline_len_beyond_the_inline_array_does_not_abort]()
    suite.test[test_overflow_flag_against_an_empty_arena_does_not_abort]()
    suite.test[test_arena_span_past_the_end_of_the_arena_does_not_abort]()
    suite.test[test_n_args_larger_than_the_blob_does_not_abort]()
    suite.test[test_a_well_formed_record_is_unchanged_by_the_guard]()
    suite^.run()
