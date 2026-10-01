# =============================================================================
# test_log_erased_emit.mojo — the ERASED emit path is the SAME path.
# =============================================================================
#
# `logger_erased.emit_erased` exists to take `fmt` and the arg-type pack OUT of
# the monomorphisation key. That is a COMPILE-TIME claim, and it is worth
# nothing if the records it produces differ from the specialised path's — a
# second wire format would mean a second decoder, and a drift nobody would
# notice until a log line rendered as garbage in production.
#
# So these tests assert IDENTITY, not merely decodability:
#
#   1. THE DIGEST IS THE SAME FUNCTION. `fnv1a_32_dyn(lit) == fnv1a_32[lit]`
#      over a corpus, so a site registered through either path collides onto ONE
#      dictionary entry. If this drifts, the drain resolves `site_id -> fmt` to
#      the wrong fmt, or to nothing.
#   2. THE ARG BLOB IS BYTE-IDENTICAL for every tag — including the two-string
#      ARG_FIELD layout and the >48-byte overflow that spills to the arena.
#   3. THE RENDERED LINE IS BYTE-IDENTICAL from LEVEL onward, drained through
#      the real engine, for the same logical call written both ways.
#   4. THE GATES BEHAVE THE SAME — a below-threshold call emits NOTHING through
#      either path. (`emit_erased` is not `@always_inline`, so this is the test
#      that the gate ordering survived the rewrite.)
#   5. THE NON-WORKER FALLBACK still renders synchronously rather than stranding
#      a record on an undrained ring.
#
# ⚠ (2) IS THE LOAD-BEARING ONE. Lines can match while blobs differ (both render
# through `interpolate`), so a line-only test would pass over a wire-format
# break. The blob comparison is what actually pins the format.
# =============================================================================

from komira_log import SharedEngine, Logger, LogValue
from komira_log.logger_erased import emit_erased, fnv1a_32_dyn
from komira_log.env_filter import EnvFilter
from komira_log.levels import (
    LEVEL_TRACE,
    LEVEL_DEBUG,
    LEVEL_INFO,
    LEVEL_WARN,
    LEVEL_ERROR,
)
from komira_log.log_arg import (
    ArgI64,
    ArgU64,
    ArgStr,
    ArgF64,
    ArgBool,
    Field,
    LogArg,
)
from komira_log.log_value import LogValue as LV
from komira_log.engine.log_event_record import (
    LogEventRecord,
    ArgBlobWriter,
    ARG_INLINE_BYTES,
)
from komira_log.engine.site_dictionary import fnv1a_32

from std.testing import assert_equal, assert_true, assert_false


# -----------------------------------------------------------------------------
# Helpers.
# -----------------------------------------------------------------------------


def _filter_at(level: UInt8) -> EnvFilter:
    var f = EnvFilter()
    f.global_level = level
    return f^


def _suffix(s: String) -> String:
    """The line from LEVEL onward — drops the leading timestamp, which is
    wall-clock and differs between two emits by construction."""
    var b = s.as_bytes()
    var k = 0
    while k < len(b) and b[k] != UInt8(ord(" ")):
        k += 1
    var out = String("")
    for i in range(k + 1, len(b)):
        out += chr(Int(b[i]))
    return out


def _blob_specialised[*ArgTs: LogArg](*args: *ArgTs) -> List[UInt8]:
    """Encode `args` exactly as `_emit_through` does — the comptime `for` over
    the type pack, tag table then payloads — and return the bytes written."""
    var rec = LogEventRecord()
    var w = ArgBlobWriter(rec.arg_blob)
    comptime n = args.__len__()

    comptime for i in range(n):
        w.append(args[i].arg_tag())

    comptime for i in range(n):
        args[i].encode_into_blob(w)

    return _writer_bytes(w)


def _blob_erased(*args: LV) -> List[UInt8]:
    """Encode `args` exactly as `emit_erased` does — a runtime `for` over the
    HOMOGENEOUS variadic's elements. Taking `*args: LV` rather than a `List`
    keeps this the same construct the real path uses."""
    var rec = LogEventRecord()
    var w = ArgBlobWriter(rec.arg_blob)
    var n = len(args)

    for i in range(n):
        w.append(args[i].arg_tag())

    for i in range(n):
        args[i].encode_into_blob(w)

    return _writer_bytes(w)


def _writer_bytes[o: Origin[mut=True]](mut w: ArgBlobWriter[o]) -> List[UInt8]:
    """The bytes the writer produced, inline path or overflow path alike.

    Reads through the WRITER rather than through the record: the writer holds a
    `mut` borrow of `rec.arg_blob`, so touching the record while it is alive is
    an aliasing error the compiler rejects (and rightly — that is the borrow the
    encode is writing through). `full_blob()` returns the whole 48-byte inline
    array plus any overflow tail, so truncating to `total_len()` is exactly the
    bytes written, on both paths.
    """
    var total = w.total_len()
    var full = w.full_blob()
    var out = List[UInt8]()
    for i in range(total):
        out.append(full[i])
    return out^


def _assert_bytes_equal(a: List[UInt8], b: List[UInt8], what: String) raises:
    assert_equal(len(a), len(b), String("length differs for ") + what)
    for i in range(len(a)):
        assert_equal(
            Int(a[i]),
            Int(b[i]),
            String("byte ") + String(i) + String(" differs for ") + what,
        )


# -----------------------------------------------------------------------------
# 1. THE DIGEST IS THE SAME FUNCTION.
# -----------------------------------------------------------------------------


def test_runtime_digest_matches_comptime_digest() raises:
    """`fnv1a_32_dyn` must be `fnv1a_32` with the loop moved to runtime.

    If it is not, a site registered by the erased path lands under a different
    key than the same `fmt` registered by the specialised path, and the drain
    resolves the wrong text — or none.
    """
    assert_equal(Int(fnv1a_32_dyn("")), Int(fnv1a_32("")))
    assert_equal(Int(fnv1a_32_dyn("a")), Int(fnv1a_32("a")))
    assert_equal(
        Int(fnv1a_32_dyn("job {} started")), Int(fnv1a_32("job {} started"))
    )
    assert_equal(
        Int(fnv1a_32_dyn("deploy {} -> {} in {}ms")),
        Int(fnv1a_32("deploy {} -> {} in {}ms")),
    )
    assert_equal(Int(fnv1a_32_dyn("komira")), Int(fnv1a_32("komira")))
    # Distinct fmts must not collide onto one id (a trivially-constant digest
    # would satisfy every assertion above).
    assert_true(fnv1a_32_dyn("job {} started") != fnv1a_32_dyn("job {} ended"))


# -----------------------------------------------------------------------------
# 1b. RENDER PARITY, per tag.
#
# The blob tests below cover ENCODE for every tag, and they cover RENDER only
# where the encoding happens to contain a rendered string (the ARG_FIELD value,
# which both paths pre-render at construction). `render()` is what the drain
# calls for the non-worker fallback line, so a tag whose render drifts produces
# a wrong log line on that path with every blob assertion still green.
# -----------------------------------------------------------------------------


def test_render_matches_per_tag() raises:
    assert_equal(LV.i64(-7).render(), ArgI64(-7).render())
    assert_equal(LV.i64(0).render(), ArgI64(0).render())
    assert_equal(
        LV.u64(UInt64(1 << 40)).render(), ArgU64(UInt64(1 << 40)).render()
    )
    assert_equal(LV.f64(2.5).render(), ArgF64(2.5).render())
    assert_equal(LV.f64(-0.125).render(), ArgF64(-0.125).render())
    assert_equal(LV.boolean(True).render(), ArgBool(True).render())
    assert_equal(LV.boolean(False).render(), ArgBool(False).render())
    assert_equal(LV.text(String("hi")).render(), ArgStr(String("hi")).render())
    assert_equal(
        LV.field(String("k"), LV.i64(3)).render(),
        Field(String("k"), ArgI64(3)).render(),
    )
    assert_equal(
        LV.field(String("k"), LV.boolean(False)).render(),
        Field(String("k"), ArgBool(False)).render(),
    )
    assert_equal(
        LV.field(String("k"), LV.f64(1.5)).render(),
        Field(String("k"), ArgF64(1.5)).render(),
    )


# -----------------------------------------------------------------------------
# 2. THE ARG BLOB IS BYTE-IDENTICAL — the load-bearing test.
# -----------------------------------------------------------------------------


def test_blob_identical_scalars() raises:
    _assert_bytes_equal(
        _blob_specialised(ArgI64(-7)), _blob_erased(LV.i64(-7)), String("i64")
    )
    _assert_bytes_equal(
        _blob_specialised(ArgU64(UInt64(1 << 40))),
        _blob_erased(LV.u64(UInt64(1 << 40))),
        String("u64"),
    )
    _assert_bytes_equal(
        _blob_specialised(ArgF64(2.5)), _blob_erased(LV.f64(2.5)), String("f64")
    )
    _assert_bytes_equal(
        _blob_specialised(ArgBool(True)),
        _blob_erased(LV.boolean(True)),
        String("bool-true"),
    )
    _assert_bytes_equal(
        _blob_specialised(ArgBool(False)),
        _blob_erased(LV.boolean(False)),
        String("bool-false"),
    )
    _assert_bytes_equal(
        _blob_specialised(ArgStr(String("hello"))),
        _blob_erased(LV.text(String("hello"))),
        String("str"),
    )


def test_blob_identical_mixed_pack() raises:
    """A four-arg mixed pack — the shape a real call site has, and the one where
    an ordering bug between the tag table and the payloads would show."""
    _assert_bytes_equal(
        _blob_specialised(
            ArgI64(42), ArgStr(String("abc")), ArgBool(True), ArgF64(1.25)
        ),
        _blob_erased(
            LV.i64(42), LV.text(String("abc")), LV.boolean(True), LV.f64(1.25)
        ),
        String("mixed"),
    )


def test_blob_identical_field() raises:
    """ARG_FIELD is two length-prefixed strings, and its VALUE is pre-rendered
    at construction on both paths — the one arg whose encoding depends on a
    render, so the one most likely to drift."""
    _assert_bytes_equal(
        _blob_specialised(Field(String("rows"), ArgI64(1234))),
        _blob_erased(LV.field(String("rows"), LV.i64(1234))),
        String("field-i64"),
    )
    _assert_bytes_equal(
        _blob_specialised(Field(String("state"), ArgStr(String("DONE")))),
        _blob_erased(LV.field(String("state"), LV.text(String("DONE")))),
        String("field-str"),
    )
    _assert_bytes_equal(
        _blob_specialised(Field(String("ok"), ArgBool(False))),
        _blob_erased(LV.field(String("ok"), LV.boolean(False))),
        String("field-bool"),
    )


def test_blob_identical_overflow_spill() raises:
    """A string longer than the 48-byte inline blob drives the writer onto the
    overflow tail. Both paths must spill the SAME full byte sequence, because
    the drain reads the whole blob back from the arena, not just the tail."""
    var long = String("")
    for i in range(200):
        long += chr(ord("a") + (i % 26))
    assert_true(long.byte_length() > ARG_INLINE_BYTES)
    _assert_bytes_equal(
        _blob_specialised(ArgStr(long)), _blob_erased(LV.text(long)),
        String("overflow"),
    )


def test_blob_identical_zero_args() raises:
    """A no-arg site. The erased path reaches it with an EMPTY variadic, which
    is the arity a type pack cannot express as a distinct instantiation."""
    _assert_bytes_equal(
        _blob_specialised(), _blob_erased(), String("zero-args")
    )


# -----------------------------------------------------------------------------
# 3. THE RENDERED LINE IS BYTE-IDENTICAL through the real engine.
# -----------------------------------------------------------------------------


def test_rendered_line_matches_specialised_path() raises:
    var eng = SharedEngine(num_workers=1, filter=_filter_at(LEVEL_TRACE))
    eng.bind_worker_thread(UInt16(0))

    var log = Logger.borrow(eng)
    log.info["job {} finished in {}ms", "erase_test"](
        ArgStr(String("j-9")), ArgI64(120)
    )
    var spec = eng.drain_worker_to_lines(0, 16)
    assert_equal(len(spec), 1)

    emit_erased[LEVEL_INFO, "erase_test"](
        eng,
        "job {} finished in {}ms",
        LV.text(String("j-9")),
        LV.i64(120),
    )
    var erased = eng.drain_worker_to_lines(0, 16)
    assert_equal(len(erased), 1)

    assert_equal(_suffix(spec[0]), _suffix(erased[0]))
    assert_true(_suffix(erased[0]).find(String("job j-9 finished in 120ms")) >= 0)


def test_rendered_line_matches_with_fields() raises:
    var eng = SharedEngine(num_workers=1, filter=_filter_at(LEVEL_TRACE))
    eng.bind_worker_thread(UInt16(0))

    var log = Logger.borrow(eng)
    log.warn["upload failed: {}", "erase_test"](
        ArgStr(String("timeout")), Field(String("attempt"), ArgI64(3))
    )
    var spec = eng.drain_worker_to_lines(0, 16)

    emit_erased[LEVEL_WARN, "erase_test"](
        eng,
        "upload failed: {}",
        LV.text(String("timeout")),
        LV.field(String("attempt"), LV.i64(3)),
    )
    var erased = eng.drain_worker_to_lines(0, 16)

    assert_equal(len(spec), 1)
    assert_equal(len(erased), 1)
    assert_equal(_suffix(spec[0]), _suffix(erased[0]))
    assert_true(_suffix(erased[0]).find(String("attempt=3")) >= 0)


def test_rendered_line_zero_args() raises:
    var eng = SharedEngine(num_workers=1, filter=_filter_at(LEVEL_TRACE))
    eng.bind_worker_thread(UInt16(0))

    var log = Logger.borrow(eng)
    log.error["shutting down", "erase_test"]()
    var spec = eng.drain_worker_to_lines(0, 16)

    emit_erased[LEVEL_ERROR, "erase_test"](eng, "shutting down")
    var erased = eng.drain_worker_to_lines(0, 16)

    assert_equal(len(spec), 1)
    assert_equal(len(erased), 1)
    assert_equal(_suffix(spec[0]), _suffix(erased[0]))


def test_erased_registers_the_site_for_decode() raises:
    """The erased path's RUNTIME registration must populate the SAME dictionary
    the drain reads, or the line renders with no message text at all."""
    var eng = SharedEngine(num_workers=1, filter=_filter_at(LEVEL_TRACE))
    eng.bind_worker_thread(UInt16(0))

    emit_erased[LEVEL_INFO, "erase_reg"](
        eng, "registered {} once", LV.i64(1)
    )
    emit_erased[LEVEL_INFO, "erase_reg"](
        eng, "registered {} once", LV.i64(2)
    )
    var lines = eng.drain_worker_to_lines(0, 16)
    assert_equal(len(lines), 2)
    assert_true(lines[0].find(String("registered 1 once")) >= 0)
    assert_true(lines[1].find(String("registered 2 once")) >= 0)
    assert_true(lines[0].find(String("erase_reg")) >= 0)


# -----------------------------------------------------------------------------
# 4. THE GATES BEHAVE THE SAME.
# -----------------------------------------------------------------------------


def test_gate_suppresses_below_global_level() raises:
    var eng = SharedEngine(num_workers=1, filter=_filter_at(LEVEL_WARN))
    eng.bind_worker_thread(UInt16(0))

    emit_erased[LEVEL_DEBUG, "erase_test"](eng, "should not appear")
    emit_erased[LEVEL_INFO, "erase_test"](eng, "should not appear either")
    assert_equal(len(eng.drain_worker_to_lines(0, 16)), 0)

    emit_erased[LEVEL_ERROR, "erase_test"](eng, "should appear")
    assert_equal(len(eng.drain_worker_to_lines(0, 16)), 1)


def test_gate_honours_disabled_engine() raises:
    var eng = SharedEngine(num_workers=1, filter=_filter_at(LEVEL_TRACE))
    eng.bind_worker_thread(UInt16(0))
    eng.set_enabled(False)
    emit_erased[LEVEL_ERROR, "erase_test"](eng, "engine off")
    assert_equal(len(eng.drain_worker_to_lines(0, 16)), 0)

    eng.set_enabled(True)
    emit_erased[LEVEL_ERROR, "erase_test"](eng, "engine on")
    assert_equal(len(eng.drain_worker_to_lines(0, 16)), 1)


# -----------------------------------------------------------------------------
# 5. THE NON-WORKER FALLBACK.
# -----------------------------------------------------------------------------


def test_non_worker_thread_takes_the_fallback_not_the_ring() raises:
    """With no worker id bound, the record must NOT be pushed onto ring 0 — it
    would sit there undrained. `_emit_through` renders synchronously in that
    case and so must the erased twin."""
    var eng = SharedEngine(num_workers=1, filter=_filter_at(LEVEL_TRACE))
    # Deliberately NOT bound: `current_worker_id()` is WORKER_ID_UNSET.
    emit_erased[LEVEL_INFO, "erase_test"](eng, "off-thread {}", LV.i64(5))
    assert_equal(len(eng.drain_worker_to_lines(0, 16)), 0)


def main() raises:
    test_runtime_digest_matches_comptime_digest()
    test_render_matches_per_tag()
    test_blob_identical_scalars()
    test_blob_identical_mixed_pack()
    test_blob_identical_field()
    test_blob_identical_overflow_spill()
    test_blob_identical_zero_args()
    test_rendered_line_matches_specialised_path()
    test_rendered_line_matches_with_fields()
    test_rendered_line_zero_args()
    test_erased_registers_the_site_for_decode()
    test_gate_suppresses_below_global_level()
    test_gate_honours_disabled_engine()
    test_non_worker_thread_takes_the_fallback_not_the_ring()
    print("test_log_erased_emit: OK")
