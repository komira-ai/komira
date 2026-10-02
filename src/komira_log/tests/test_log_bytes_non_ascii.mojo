# =============================================================================
# A LOG MESSAGE IS A BYTE STRING — THE DRAIN, THE LAYOUT AND THE MERGE MUST
# ALL SAY SO
# =============================================================================
#
# ⛔ THE DEFECT CLASS THIS FILE GUARDS: rebuilding bytes with `chr`. Sibling:
# `tests/test_env_filter_bytes_non_ascii.mojo`, which guards the directive
# parser — and fixing one member of a class in a package does not close the
# package, so every member is guarded here.
#
# `chr` maps a CODE POINT to its UTF-8 ENCODING. A decoder that rebuilds stored
# bytes with `out += chr(Int(b))` therefore RE-ENCODES every byte >= 0x80 into
# TWO: `é` (C3 A9) -> `Ã©` (C3 83 C2 A9). ASCII is the corruption's FIXED
# POINT, which is why an ASCII-only log test cannot see it.
#
# THE FOUR MODULES, TEN CALL SITES, each with its own falsifier below:
#
#   1. `pattern_layout.interpolate`   — the LITERAL bytes of the format string.
#      ⭐ LIVE ON EVERY RENDERED LINE: `logger`, `logger_erased`, `facade` and
#      BOTH drains call it, so a non-ASCII `fmt` would be mojibaked on every
#      path this package has.
#   2. `engine/drain._decode_args`    x3 — the string ARG, the field KEY and
#      the field VALUE of a P2 binary record.
#   3. `engine/drain._decode_args_kv` x3 — the same three on the native-indexing
#      seam (`decode_one_to_view`), whose own comment calls it a
#      "byte-identical arg-walk" to `_decode_args` — so a defect in one is a
#      defect in both. ⚠ The producer (`log_arg.StrArg.encode_into`) copies the
#      caller's bytes RAW, so a `chr` decode makes an ASYMMETRIC codec pair.
#   4. `engine/span_drain._json_escape` — the pass-through arm, i.e. a SPAN
#      NAME in exported OTLP-shaped JSON. It is a wrapper over
#      `komira_trace.exporter.json_escape`, which is the mutation site.
#   5. `engine/merge._ts_key` and `_read_lines` — the log-merge k-way
#      merge. ⚠ SEE THE DISPOSITION NOTE ON EACH: this module has no
#      production importer in this package (only its tests), so these two are
#      the class's shape without a live consumer here. They are guarded anyway,
#      because the module is a documented merge surface and the next reader
#      copies what is there.
#
# ⚠ NOTHING HERE ASSERTS THAT TWO CODE PATHS AGREE — agreement is also
# satisfied by both being wrong alike. Every assertion is against the EXACT bytes of the fixture's own source
# text.
#
# ⚠ NO FILESYSTEM NAMES ARE CREATED FROM THE NON-ASCII FIXTURE except in the
# merge test, which writes FILE CONTENT (never a filename) — so canonical
# decomposition cannot reach any assertion here, and `Zürich` (a 2-byte lead)
# is used deliberately.
# =============================================================================

from komira_runtime_paths import test_tmpdir
from std.ffi import external_call
from std.testing import assert_equal, assert_true

from komira_log.log_arg import ARG_FIELD, ARG_I64, ARG_STR
from komira_log.pattern_layout import interpolate
from komira_log.engine.drain import _decode_args, _decode_args_kv
from komira_log.engine.merge import (
    _read_lines,
    _ts_key,
    merge_segment_files,
    merge_segment_lines,
)
from komira_log.engine.span_drain import (
    PendingSpan,
    _format_span_otlp,
    _json_escape,
)


# =============================================================================
# THE FIXTURE — all three multi-byte UTF-8 lead classes + an ASCII control
# =============================================================================
#
#   'Zürich'  7 bytes  5A C3 BC 72 69 63 68   2-byte lead (C3)   the common case
#   '東京'     6 bytes  E6 9D B1 E4 BA AC      two 3-byte sequences
#   '𐍈'       4 bytes  F0 90 8D 88            one 4-byte sequence
#   'plain'   5 bytes  ASCII — the CONTROL

comptime _EXPECTED_FIXTURE_BYTES: Int = 22  # 7 + 6 + 4 + 5


def _fixture() raises -> List[String]:
    return [
        String("Zürich"),
        String("東京"),
        String("𐍈"),
        String("plain"),
    ]


# =============================================================================
# Byte helpers
# =============================================================================


def _bytes_of(imm s: String) raises -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _hex(imm b: List[UInt8]) raises -> String:
    var digits: List[String] = [
        String("0"), String("1"), String("2"), String("3"),
        String("4"), String("5"), String("6"), String("7"),
        String("8"), String("9"), String("a"), String("b"),
        String("c"), String("d"), String("e"), String("f"),
    ]
    var out = String("")
    for i in range(len(b)):
        if i > 0:
            out += " "
        var v = Int(b[i])
        out += digits[v >> 4]
        out += digits[v & 15]
    return out^


def _assert_bytes_eq(
    imm got: String, imm want: String, imm what: String
) raises:
    var gb = _bytes_of(got)
    var wb = _bytes_of(want)
    if len(gb) != len(wb):
        raise Error(
            what + ": got " + String(len(gb)) + " bytes [" + _hex(gb)
            + "] for a " + String(len(wb)) + "-byte source [" + _hex(wb)
            + "]. If every byte >= 0x80 doubled, a per-code-point `chr()`"
            " decode is back — see this file's header"
        )
    for i in range(len(gb)):
        if gb[i] != wb[i]:
            raise Error(
                what + ": byte " + String(i) + " differs (got [" + _hex(gb)
                + "] want [" + _hex(wb) + "])"
            )


def _sh(cmd: String) raises:
    var cmd_local = cmd
    var rc = external_call["system", Int32](
        cmd_local.as_c_string_slice().unsafe_ptr()
    )
    if Int(rc) != 0:
        raise Error("shell command failed rc=" + String(Int(rc)) + ": " + cmd)


def _scratch_dir() raises -> String:
    """A per-test-action scratch root under `$TEST_TMPDIR`, which the test
    runner makes private to this run, so two concurrent runs of the SAME test
    cannot collide."""
    var base = test_tmpdir()
    var pid = external_call["getpid", Int32]()
    var root = base + String("/logbytes_") + String(Int(pid))
    _sh(String("rm -rf '") + root + String("'"))
    _sh(String("mkdir -p '") + root + String("'"))
    return root


# =============================================================================
# Arg-blob builders — the PRODUCER side, byte-exact by construction
# =============================================================================
#
# These mirror `log_arg.{StrArg,FieldArg}.encode_into` exactly: a tag table of
# `n_args` bytes, then each arg's payload in order; a string payload is a
# u16 little-endian length followed by the RAW bytes. Written here rather than
# driven through the ring so the test asserts the DECODER in isolation — and
# so the "the producer writes raw bytes" claim is visible in the test itself
# rather than taken on trust.


def _put_u16(mut buf: List[UInt8], n: Int):
    buf.append(UInt8(n & 0xFF))
    buf.append(UInt8((n >> 8) & 0xFF))


def _put_str(mut buf: List[UInt8], imm s: String) raises:
    var b = _bytes_of(s)
    _put_u16(buf, len(b))
    for i in range(len(b)):
        buf.append(b[i])


def _blob_one_str(imm s: String) raises -> List[UInt8]:
    var buf = List[UInt8]()
    buf.append(ARG_STR)
    _put_str(buf, s)
    return buf^


def _blob_one_field(imm k: String, imm v: String) raises -> List[UInt8]:
    var buf = List[UInt8]()
    buf.append(ARG_FIELD)
    _put_str(buf, k)
    _put_str(buf, v)
    return buf^


# =============================================================================
# NON-VACUITY — without this, an all-ASCII fixture makes the file a tautology
# =============================================================================


def test_fixture_is_actually_non_ascii() raises:
    """NON-VACUITY GUARD FOR EVERY OTHER TEST IN THIS FILE.

    ⛔ THE DEFECTIVE DECODE IS THE IDENTITY ON ASCII, so an all-ASCII fixture
    makes every assertion below pass against it. ⛔ AND A TYPICAL BENCH CORPUS
    IS ASCII, which is how this class goes unnoticed. With the fixture
    ASCII-ified and this guard neutered, the DEFECTIVE code passes in full.

    Four properties, each ruling out a different degenerate fixture:
      1. a fixture string holds a byte >= 0x80;
      2. all three multi-byte lead classes appear (C0-DF, E0-EF, F0-F7) — a
         decode that only handled 2-byte sequences survives a C3-only fixture;
      3. an all-ASCII CONTROL string is present, so a "fix" that damages ASCII
         is caught rather than hidden;
      4. the exact stored byte total, so a substitution preserving the class
         set still reds.

    Killed by: replacing any non-ASCII fixture string with ASCII; dropping the
    3-byte or the 4-byte one; dropping the ASCII control.
    """
    var ks = _fixture()
    var total = 0
    var n_high = 0
    var saw_2b = False
    var saw_3b = False
    var saw_4b = False
    var saw_ascii_control = False
    for i in range(len(ks)):
        var b = _bytes_of(ks[i])
        total += len(b)
        var this_high = 0
        for j in range(len(b)):
            var v = Int(b[j])
            if v >= 0x80:
                this_high += 1
                n_high += 1
            if v >= 0xC0 and v <= 0xDF:
                saw_2b = True
            if v >= 0xE0 and v <= 0xEF:
                saw_3b = True
            if v >= 0xF0 and v <= 0xF7:
                saw_4b = True
        if this_high == 0:
            saw_ascii_control = True
    if n_high == 0:
        raise Error(
            "VACUOUS FIXTURE: nothing holds a byte >= 0x80, so every assertion"
            " in this file passes against the DEFECTIVE per-code-point"
            " `chr` decode. See this file's header."
        )
    if not saw_2b:
        raise Error("VACUOUS FIXTURE: no 2-byte (C0-DF) lead byte present")
    if not saw_3b:
        raise Error("VACUOUS FIXTURE: no 3-byte (E0-EF) lead byte present")
    if not saw_4b:
        raise Error("VACUOUS FIXTURE: no 4-byte (F0-F7) lead byte present")
    if not saw_ascii_control:
        raise Error("VACUOUS FIXTURE: no all-ASCII CONTROL string")
    assert_equal(total, _EXPECTED_FIXTURE_BYTES)


# =============================================================================
# FALSIFIER 1 — `pattern_layout.interpolate`
# =============================================================================


def test_format_literal_bytes_survive_interpolation() raises:
    """SITE: `komira_log/pattern_layout.interpolate`, the LITERAL-byte arm.

    ⭐ THE BROADEST-REACH SITE IN THIS PACKAGE: `logger`, `logger_erased`,
    `facade`, `drain.decode_one` and `drain.decode_one_to_view` all render
    through this one function, so a non-ASCII format string was mojibaked on
    EVERY path `komira_log` has.

    The placeholder value is ASCII and the literal is not (and vice versa in
    the second half), so the two are distinguishable in the output — a decode
    that damaged only one of them cannot hide behind the other.

    Killed by: restoring `out += chr(Int(c))` in `interpolate`.
    """
    var ks = _fixture()
    for i in range(len(ks)):
        # Literal non-ASCII on BOTH sides of the placeholder, plus the brace
        # escapes, so the run-copy cannot swallow a `{{`/`}}`.
        var fmt = ks[i] + String(" {} ") + ks[i] + String(" {{x}}")
        var vals: List[String] = [String("42")]
        var want = ks[i] + String(" 42 ") + ks[i] + String(" {x}")
        _assert_bytes_eq(interpolate(fmt, vals), want, "interpolate literal")
        # And a non-ASCII VALUE under an ASCII literal — the other direction.
        var vals2: List[String] = [ks[i]]
        _assert_bytes_eq(
            interpolate(String("v={}"), vals2), String("v=") + ks[i],
            "interpolate value",
        )
    # A format that is ONLY non-ASCII literal (no placeholder at all).
    var none: List[String] = []
    _assert_bytes_eq(
        interpolate(String("東京𐍈"), none), String("東京𐍈"),
        "interpolate literal-only",
    )


# =============================================================================
# FALSIFIERS 2-4 — `engine/drain._decode_args` (3 independent call sites)
# =============================================================================


def test_drain_decodes_a_string_arg_exactly() raises:
    """SITE: `komira_log/engine/drain._decode_args`, the ARG_STR arm.

    The producer (`log_arg.StrArg.encode_into`) copies the caller's `String`
    bytes RAW behind a u16 length, so a `chr` decode made this an ASYMMETRIC
    codec pair and every non-ASCII `log.info["{}"](name)` came out of the drain
    mojibaked.

    Killed by: restoring `s += chr(Int(blob[off + j]))` at the ARG_STR arm of
    `_decode_args` (i.e. inlining the old loop in place of `_decode_str_run`).
    """
    var ks = _fixture()
    for i in range(len(ks)):
        var decoded = _decode_args(_blob_one_str(ks[i]), 1)
        assert_equal(len(decoded[0]), 1)
        assert_equal(len(decoded[1]), 0)
        _assert_bytes_eq(decoded[0][0], ks[i], "_decode_args ARG_STR")


def test_drain_decodes_a_field_key_exactly() raises:
    """SITE: `_decode_args`, the ARG_FIELD KEY arm — a SEPARATE call site from
    the value arm, so a fix to one cannot pass this.

    ⚠ ASSERTED WITH AN ASCII VALUE so a failure names the KEY unambiguously:
    `_decode_args` joins the pair as `key + "=" + val`, and if both halves were
    non-ASCII a single wrong byte count would not say which half moved.

    Killed by: restoring the `chr` loop at the KEY arm of `_decode_args`.
    """
    var ks = _fixture()
    for i in range(len(ks)):
        var decoded = _decode_args(_blob_one_field(ks[i], String("v")), 1)
        assert_equal(len(decoded[1]), 1)
        _assert_bytes_eq(
            decoded[1][0], ks[i] + String("=v"), "_decode_args FIELD key"
        )


def test_drain_decodes_a_field_value_exactly() raises:
    """SITE: `_decode_args`, the ARG_FIELD VALUE arm — the third independent
    call site in this function.

    Killed by: restoring the `chr` loop at the VALUE arm of `_decode_args`.
    """
    var ks = _fixture()
    for i in range(len(ks)):
        var decoded = _decode_args(_blob_one_field(String("k"), ks[i]), 1)
        assert_equal(len(decoded[1]), 1)
        _assert_bytes_eq(
            decoded[1][0], String("k=") + ks[i], "_decode_args FIELD value"
        )


# =============================================================================
# FALSIFIERS 5-7 — `engine/drain._decode_args_kv` (3 more call sites)
# =============================================================================


def test_view_drain_decodes_a_string_arg_exactly() raises:
    """SITE: `komira_log/engine/drain._decode_args_kv`, the ARG_STR arm — the
    native-indexing seam (`decode_one_to_view`), a SECOND arg walk whose own
    comment calls it "byte-identical" to `_decode_args`. It was, including the
    defect: a guard on one and not the other is exactly the half fix that
    module's header warns about for the BOUNDS guard.

    Killed by: restoring the `chr` loop at the ARG_STR arm of `_decode_args_kv`.
    """
    var ks = _fixture()
    for i in range(len(ks)):
        var decoded = _decode_args_kv(_blob_one_str(ks[i]), 1)
        assert_equal(len(decoded[0]), 1)
        _assert_bytes_eq(decoded[0][0], ks[i], "_decode_args_kv ARG_STR")


def test_view_drain_decodes_a_field_key_exactly() raises:
    """SITE: `_decode_args_kv`, the ARG_FIELD KEY arm.

    ⭐ THIS IS THE ARM THE SEARCH-SIDE INDEXER CONSUMES: the kv walk exists so
    the consumer can emit fixed-known-key COLUMNS, and a column NAME that has
    been re-encoded matches no query literal — the same one-sided-corruption
    shape that made `WHERE city = 'Zürich'` return an empty result set.

    Killed by: restoring the `chr` loop at the KEY arm of `_decode_args_kv`.
    """
    var ks = _fixture()
    for i in range(len(ks)):
        var decoded = _decode_args_kv(_blob_one_field(ks[i], String("v")), 1)
        assert_equal(len(decoded[1]), 1)
        assert_equal(len(decoded[2]), 1)
        _assert_bytes_eq(decoded[1][0], ks[i], "_decode_args_kv FIELD key")
        _assert_bytes_eq(decoded[2][0], String("v"), "kv ASCII value control")


def test_view_drain_decodes_a_field_value_exactly() raises:
    """SITE: `_decode_args_kv`, the ARG_FIELD VALUE arm.

    Killed by: restoring the `chr` loop at the VALUE arm of `_decode_args_kv`.
    """
    var ks = _fixture()
    for i in range(len(ks)):
        var decoded = _decode_args_kv(_blob_one_field(String("k"), ks[i]), 1)
        assert_equal(len(decoded[2]), 1)
        _assert_bytes_eq(decoded[1][0], String("k"), "kv ASCII key control")
        _assert_bytes_eq(decoded[2][0], ks[i], "_decode_args_kv FIELD value")


def test_drain_arg_walk_survives_a_mixed_multi_arg_record() raises:
    """SITES: both arg walks, with THREE args in one record.

    ⚠ THE OFFSET IS THE POINT. Every arm advances `off` by the DECLARED length,
    and the old decode's output length differed from that — so a record whose
    non-ASCII arg is followed by MORE args is where a length/offset confusion
    would surface. A single-arg record cannot show this.

    Killed by: restoring any `chr` loop in either walk.
    """
    var ks = _fixture()
    var buf = List[UInt8]()
    buf.append(ARG_STR)
    buf.append(ARG_FIELD)
    buf.append(ARG_STR)
    _put_str(buf, ks[0])
    _put_str(buf, ks[1])
    _put_str(buf, ks[2])
    _put_str(buf, ks[3])

    var d = _decode_args(buf, 3)
    assert_equal(len(d[0]), 2)
    assert_equal(len(d[1]), 1)
    _assert_bytes_eq(d[0][0], ks[0], "mixed: positional 0")
    _assert_bytes_eq(d[1][0], ks[1] + String("=") + ks[2], "mixed: field")
    _assert_bytes_eq(d[0][1], ks[3], "mixed: positional 1 (after the field)")

    var kv = _decode_args_kv(buf, 3)
    assert_equal(len(kv[0]), 2)
    assert_equal(len(kv[1]), 1)
    _assert_bytes_eq(kv[0][0], ks[0], "mixed kv: positional 0")
    _assert_bytes_eq(kv[1][0], ks[1], "mixed kv: key")
    _assert_bytes_eq(kv[2][0], ks[2], "mixed kv: value")
    _assert_bytes_eq(kv[0][1], ks[3], "mixed kv: positional 1")


# =============================================================================
# FALSIFIER 8 — `engine/span_drain._json_escape`
# =============================================================================


def test_span_name_survives_json_escape_exactly() raises:
    """SITE: `komira_log/engine/span_drain._json_escape`, the pass-through arm.

    JSON requires NO escaping above 0x7F, so the only correct handling of a
    multi-byte UTF-8 sequence is to copy its bytes through. Under the defect
    the emitted OTLP-shaped `"name"` was mojibaked — a silent wrong value in
    exported telemetry.

    Both halves are asserted: the function directly, and the production
    renderer `_format_span_otlp` that consumes it, because a decoder can be
    right and its one caller still hand it the wrong string. The escape arms
    (quote / backslash / control) are asserted in the SAME string so the
    run-copy rewrite cannot swallow one.

    Killed by: restoring `out += chr(Int(c))` in `komira_trace.exporter.json_escape`
    (reached through the `_json_escape` wrapper here).
    """
    var ks = _fixture()
    for i in range(len(ks)):
        _assert_bytes_eq(_json_escape(ks[i]), ks[i], "_json_escape plain")
        # Escapes on BOTH sides of the non-ASCII run.
        var tricky = String("\"a\\") + ks[i] + String("\tb\"")
        var want = String("\\\"a\\\\") + ks[i] + String("\\tb\\\"")
        _assert_bytes_eq(_json_escape(tricky), want, "_json_escape mixed")
        # Through the production renderer.
        var span = PendingSpan(
            UInt64(9), UInt64(0), UInt64(1), UInt64(0), Int64(10), Int64(20),
            UInt32(3), UInt32(1), True, ks[i],
        )
        var line = _format_span_otlp(span)
        var needle = String("\"name\":\"") + ks[i] + String("\"")
        if line.find(needle) < 0:
            raise Error(
                "_format_span_otlp did not carry the span name byte-exactly."
                " want substring [" + _hex(_bytes_of(needle)) + "] in ["
                + _hex(_bytes_of(line)) + "]"
            )


# =============================================================================
# FALSIFIERS 9-10 — `engine/merge` (`_ts_key`, `_read_lines`)
# =============================================================================
#
# ⚠ DISPOSITION, STATED RATHER THAN IMPLIED: `komira_log/engine/merge.mojo` has
# no production importer in this package — only `tests/test_log_p3_output.mojo`
# and this file import it. So neither of these two is a live wrong answer here.
# They are the same DEFECT SHAPE in a documented merge surface, guarded so the
# shape does not propagate by copy (which is how one defect becomes many).
#
# ⚠ `_ts_key`'s corruption was additionally ORDER-PRESERVING (0x80-0xBF -> C2
# xx, 0xC0-0xFF -> C3 xx, both monotone and above every ASCII byte), so even
# the merge ORDER was right. The function still returned bytes that are not the
# ones it claims to return, and THAT is what the next reader copies.


def test_merge_ts_key_is_byte_exact() raises:
    """SITE: `komira_log/engine/merge._ts_key`.

    The documented fallback — "a line with no space sorts by the whole line" —
    makes the WHOLE LINE the key, and a log line is not ASCII. Both branches
    are asserted: the leading-token branch (with a space) and the whole-line
    branch (without one).

    Killed by: restoring `out += chr(Int(b[i]))` in `_ts_key`.
    """
    var ks = _fixture()
    for i in range(len(ks)):
        # (a) whole-line branch — no space anywhere.
        _assert_bytes_eq(_ts_key(ks[i]), ks[i], "_ts_key whole-line branch")
        # (b) leading-token branch — the token itself carries the bytes.
        var line = ks[i] + String(" INFO [m] body")
        _assert_bytes_eq(_ts_key(line), ks[i], "_ts_key token branch")


def test_merge_reads_and_orders_non_ascii_lines_byte_exactly() raises:
    """SITE: `komira_log/engine/merge._read_lines`, plus `_ts_key` through the
    real k-way merge.

    The merged stream must reproduce each input line's bytes EXACTLY and in
    timestamp order. Line CONTENT is non-ASCII; the FILENAMES are ASCII, so no
    filesystem normalization can reach the assertion (see the header).

    Killed by: restoring `cur += chr(Int(b[i]))` in `_read_lines`.
    """
    var root = _scratch_dir()
    var ks = _fixture()

    # Two segments, interleaved by timestamp, each line's body non-ASCII.
    var seg0 = root + String("/app.core0.log")
    var seg1 = root + String("/app.core1.log")
    _sh(
        String("printf '%s' '2026-10-01T00:00:01.000Z ") + ks[0]
        + String("\n2026-10-01T00:00:03.000Z ") + ks[2]
        + String("\n' > '") + seg0 + String("'")
    )
    _sh(
        String("printf '%s' '2026-10-01T00:00:02.000Z ") + ks[1]
        + String("\n2026-10-01T00:00:04.000Z ") + ks[3]
        + String("\n' > '") + seg1 + String("'")
    )

    # (a) _read_lines alone — the direct falsifier.
    var lines0 = _read_lines(seg0)
    assert_equal(len(lines0), 2)
    _assert_bytes_eq(
        lines0[0], String("2026-10-01T00:00:01.000Z ") + ks[0],
        "_read_lines line 0",
    )
    _assert_bytes_eq(
        lines0[1], String("2026-10-01T00:00:03.000Z ") + ks[2],
        "_read_lines line 1",
    )

    # (b) the whole merge — order AND bytes.
    var paths: List[String] = [seg0, seg1]
    var merged = merge_segment_files(paths)
    assert_equal(len(merged), 4)
    var want: List[String] = [
        String("2026-10-01T00:00:01.000Z ") + ks[0],
        String("2026-10-01T00:00:02.000Z ") + ks[1],
        String("2026-10-01T00:00:03.000Z ") + ks[2],
        String("2026-10-01T00:00:04.000Z ") + ks[3],
    ]
    for i in range(len(want)):
        _assert_bytes_eq(merged[i], want[i], "merged line " + String(i))

    # (c) the pure merge over in-memory segments, so a filesystem failure
    # cannot be mistaken for a decode failure.
    var segs: List[List[String]] = [
        [want[0], want[2]],
        [want[1], want[3]],
    ]
    var merged2 = merge_segment_lines(segs)
    assert_equal(len(merged2), 4)
    for i in range(len(want)):
        _assert_bytes_eq(merged2[i], want[i], "merge_segment_lines " + String(i))

    _sh(String("rm -rf '") + root + String("'"))


def main() raises:
    test_fixture_is_actually_non_ascii()
    test_format_literal_bytes_survive_interpolation()
    test_drain_decodes_a_string_arg_exactly()
    test_drain_decodes_a_field_key_exactly()
    test_drain_decodes_a_field_value_exactly()
    test_view_drain_decodes_a_string_arg_exactly()
    test_view_drain_decodes_a_field_key_exactly()
    test_view_drain_decodes_a_field_value_exactly()
    test_drain_arg_walk_survives_a_mixed_multi_arg_record()
    test_span_name_survives_json_escape_exactly()
    test_merge_ts_key_is_byte_exact()
    test_merge_reads_and_orders_non_ascii_lines_byte_exactly()
    print("test_log_bytes_non_ascii: ALL PASS")
