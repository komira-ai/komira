# =============================================================================
# test_h1_response_trailer_and_extension_limits_conformance.mojo
# =============================================================================
# ⛔⛔ EVERY CASE IN THIS FILE STATES A CONFORMANCE BAR. Do not weaken an
#    assertion, do not delete a case, and do not "fix" a red by relaxing the
#    bar — each one is named for the upstream test that establishes it
#    (hyper, Go net/http, Envoy) and each has a one-line repro in its
#    docstring.
#
# WHY THESE. A production failure with the signature
# `EOF_MID_RESPONSE: chunked body unterminated` can sit behind a suite with
# many chunked tests, none of which reaches the one case that occurs in
# production. The pattern is not "nobody wrote tests"; it is "the tests cover
# the shapes that are easy to write".
# Limits are the archetype: they are asserted from ONE side (the rejection)
# or not at all, and a limit asserted from one side also passes against a
# limit of zero.
#
# THE STRUCTURAL FINDING, stated once so each case need not restate it:
# `codec/h1/chunked.mojo`'s `_DECODE_STATE_TRAILER` loop reads trailer
# lines until an empty line, validating ONLY that each line contains a
# colon. It has:
#   * no limit on the NUMBER of trailer fields
#   * no limit on the SIZE of a single trailer line
#   * no CUMULATIVE byte budget across the trailer section
#   * no field-value validation (NUL, bare CR)
# The one bound it does carry — `n - i > limits.max_total_header_bytes` —
# is reachable ONLY when no CRLF exists in the buffer, i.e. it bounds the
# PARTIAL tail, not the section. So the budget a caller thinks it has
# depends on how the peer packetised the bytes, which is the subject of
# `test_same_oversized_trailer_line_two_verdicts_by_read_chunking`.
#
# ⚠ AND THE ENVOY POINT, which is why "we discard trailers anyway" is not a
# defence: `LargeTrailersRejectedEvenWhenDisabled`. Trailer support here IS
# effectively disabled — the section is parsed and thrown away, nothing
# writes `RecvRingBody._trailers`. A DISABLED FEATURE THAT STILL READS ITS
# INPUT IS AN UNBOUNDED SINK, and it is a cheaper sink than a supported one
# because no limit was ever wired to it.
#
# No UnsafePointer crosses a module boundary here; no wildcard origin.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_client.response_body import RecvRingBody
from komira_http_core.transport.scripted import ScriptedStream


# =============================================================================
# §0 — Fixture helpers (same idiom as the sibling suites).
# =============================================================================


def _make_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


def _append_str(mut out: List[UInt8], s: String):
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1


def _slice_of(src: List[UInt8], start: Int, end_excl: Int) -> List[UInt8]:
    var out = List[UInt8]()
    var i = start
    while i < end_excl:
        out.append(src[i])
        i = i + 1
    return out^


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


def _drain_detail(
    var pre: List[UInt8],
    var wire: List[UInt8],
    max_read: Int,
    max_body_bytes: Int,
    mut out: List[UInt8],
) raises -> String:
    """Drive a chunked RecvRingBody over (pre_body, wire) to completion.
    Returns "" on a clean End, else the Error frame's detail."""
    var stream = ScriptedStream.from_read_script(wire^)
    if max_read > 0:
        stream.set_max_read_per_call(max_read)
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^, pre_body_bytes=pre^, max_body_bytes=max_body_bytes,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var iter = 0
    while True:
        iter = iter + 1
        if iter > 4_000_000:
            return String("ITER_CAP")
        var f = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
        if f.is_end():
            return String("")
        if f.is_error():
            return f.error_detail()
        if f.is_data():
            var chunk = f.take_data_chunk()
            var k = 0
            while k < chunk.__len__():
                out.append(chunk[k])
                k = k + 1
    return String("")


def _trailer_wire(var trailer_section: List[UInt8]) -> List[UInt8]:
    """`5\\r\\nhello\\r\\n0\\r\\n` + <trailer_section> + `\\r\\n`."""
    var w = List[UInt8]()
    _append_str(w, String("5\r\nhello\r\n0\r\n"))
    var i = 0
    while i < trailer_section.__len__():
        w.append(trailer_section[i])
        i = i + 1
    _append_str(w, String("\r\n"))
    return w^


def _rejected(detail: String) -> Bool:
    """True iff the drain ended in a decoder-level rejection. Deliberately
    broad: WHICH error kind is a design choice, THAT it is rejected is the
    conformance bar."""
    return detail.find(String("MALFORMED_CHUNKED")) >= 0


# =============================================================================
# §1 — TRAILER FIELD COUNT. hyper has six dedicated trailer-limit tests; the
#      chunked decoder here has none, and no count limit at all.
# =============================================================================


def test_trailer_field_count_limit_both_sides() raises:
    """`DEFAULT_MAX_HEADERS` is 100 and governs the header section. RFC 9110
    §6.5 makes a trailer section a field section, so the same ceiling has to
    govern it — otherwise the cheapest way past a header-count limit is to
    move the fields after the body.

    ACCEPT SIDE (passes today): 100 trailer fields.
    REJECT SIDE (RED today): 101 trailer fields are accepted. There is no
    count check in `_DECODE_STATE_TRAILER` at all, so the true limit is
    unbounded.

    Repro: `5\\r\\nhello\\r\\n0\\r\\n` + `A: b\\r\\n` x 101 + `\\r\\n`
    Expected: rejected.  Actual: clean End, payload "hello"."""
    var at_limit = List[UInt8]()
    var i = 0
    while i < 100:
        _append_str(at_limit, String("A: b\r\n"))
        i = i + 1
    var out_a = List[UInt8]()
    var d_a = _drain_detail(
        _trailer_wire(at_limit^), List[UInt8](), 0, 1024 * 1024, out_a,
    )
    assert_equal(d_a, String(""))
    assert_equal(out_a.__len__(), 5)

    var over_limit = List[UInt8]()
    var j = 0
    while j < 101:
        _append_str(over_limit, String("A: b\r\n"))
        j = j + 1
    var out_r = List[UInt8]()
    var d_r = _drain_detail(
        _trailer_wire(over_limit^), List[UInt8](), 0, 1024 * 1024, out_r,
    )
    assert_true(_rejected(d_r))


# =============================================================================
# §2 — SINGLE TRAILER LINE SIZE.
# =============================================================================


def test_single_trailer_line_over_max_header_bytes_is_rejected() raises:
    """`DEFAULT_MAX_HEADER_BYTES` is 8192 — the per-field-line ceiling.
    `_DECODE_STATE_TRAILER` never compares `crlf2 - i` to anything, so a
    single trailer line of any length that arrives with its CRLF is
    accepted.

    ACCEPT SIDE (passes today): an 8000-byte value.
    REJECT SIDE (RED today): an 8192-byte value is accepted.

    Repro: `0\\r\\nX: ` + 'a' x 8192 + `\\r\\n\\r\\n`
    Expected: rejected.  Actual: clean End."""
    var ok_line = List[UInt8]()
    _append_str(ok_line, String("X: "))
    var i = 0
    while i < 8000:
        ok_line.append(UInt8(ord("a")))
        i = i + 1
    _append_str(ok_line, String("\r\n"))
    var out_a = List[UInt8]()
    var d_a = _drain_detail(
        _trailer_wire(ok_line^), List[UInt8](), 0, 1024 * 1024, out_a,
    )
    assert_equal(d_a, String(""))

    var big_line = List[UInt8]()
    _append_str(big_line, String("X: "))
    var j = 0
    while j < 8192:
        big_line.append(UInt8(ord("a")))
        j = j + 1
    _append_str(big_line, String("\r\n"))
    var out_r = List[UInt8]()
    var d_r = _drain_detail(
        _trailer_wire(big_line^), List[UInt8](), 0, 1024 * 1024, out_r,
    )
    assert_true(_rejected(d_r))


def test_same_oversized_trailer_line_two_verdicts_by_read_chunking() raises:
    """⛔ THE SHARPEST OF THESE: THE SAME BYTES ON THE WIRE GET TWO DIFFERENT
    FRAMING VERDICTS DEPENDING ON HOW THE PEER PACKETISED THEM.

    The only bound in the trailer loop is
    `n - i > limits.max_total_header_bytes`, and it is inside the
    `crlf2 < 0` arm — so it bounds the PARTIAL tail the decoder is still
    waiting on, never a line it has in hand. A 200 KB trailer line that
    arrives in 64 KiB reads therefore trips it (the carry outgrows the
    budget before the CRLF shows up) and the same 200 KB line arriving in
    one buffer does not.

    A framing decision that depends on TCP segmentation is the exact
    property an attacker picks, and it is how two intermediaries end up
    disagreeing about where a message ends.

    Expected: both deliveries rejected.
    Actual: the one-shot delivery is ACCEPTED; the chunked delivery is
    rejected (kind 45)."""
    var line = List[UInt8]()
    _append_str(line, String("X: "))
    var i = 0
    while i < 200_000:
        line.append(UInt8(ord("a")))
        i = i + 1
    _append_str(line, String("\r\n"))
    var wire = _trailer_wire(line^)

    # Delivery A — split into 64 KiB reads, as a real socket would.
    var out_a = List[UInt8]()
    var d_a = _drain_detail(
        List[UInt8](), _slice_of(wire, 0, wire.__len__()), 65536,
        1024 * 1024, out_a,
    )
    assert_true(_rejected(d_a))

    # Delivery B — the identical bytes handed over in ONE buffer.
    var out_b = List[UInt8]()
    var d_b = _drain_detail(
        _slice_of(wire, 0, wire.__len__()), List[UInt8](), 0,
        1024 * 1024, out_b,
    )
    assert_true(_rejected(d_b))


# =============================================================================
# §3 — CUMULATIVE TRAILER BYTE BUDGET (a BYTE budget, not just a count).
# =============================================================================


def test_many_small_trailers_over_the_total_byte_budget_are_rejected() raises:
    """`DEFAULT_MAX_TOTAL_HEADER_BYTES` is 65536 — the aggregate ceiling
    across a field section. The trailer loop keeps NO running total, so N
    lines that are each individually tiny sum to an unbounded section.

    This is the Envoy `LargeTrailersRejectedEvenWhenDisabled` case: the
    bytes are read, scanned and discarded, so the work is done and the
    memory is touched whether or not anything consumes the result.

    Repro: `5\\r\\nhello\\r\\n0\\r\\n` + `A: b\\r\\n` x 15000 + `\\r\\n`
           (90000 bytes of trailer section, budget 65536)
    Expected: rejected.  Actual: clean End, payload "hello"."""
    var section = List[UInt8]()
    var i = 0
    while i < 15_000:
        _append_str(section, String("A: b\r\n"))
        i = i + 1
    var out = List[UInt8]()
    var d = _drain_detail(
        _trailer_wire(section^), List[UInt8](), 0, 1024 * 1024, out,
    )
    assert_true(_rejected(d))


# =============================================================================
# §4 — TRAILER FIELD-VALUE VALIDATION (RFC 9110 §5.5).
# =============================================================================


def test_trailer_value_containing_nul_is_rejected() raises:
    """RFC 9110 §5.5: a field value is `*( field-vchar [ 1*( SP / HTAB /
    field-vchar ) field-vchar ] )`. NUL is not a field-vchar. The trailer
    loop validates only "does this line contain a colon", so any octet
    except a CRLF pair passes.

    Repro: `0\\r\\nX-A: a<NUL>b\\r\\n\\r\\n`
    Expected: rejected.  Actual: clean End."""
    var line = List[UInt8]()
    _append_str(line, String("X-A: a"))
    line.append(UInt8(0))
    _append_str(line, String("b\r\n"))
    var out = List[UInt8]()
    var d = _drain_detail(
        _trailer_wire(line^), List[UInt8](), 0, 1024 * 1024, out,
    )
    assert_true(_rejected(d))


def test_trailer_value_containing_a_bare_cr_is_rejected() raises:
    """A CR not followed by LF inside a trailer value. `_find_crlf_in` only
    matches CR+LF, so the bare CR is swallowed into the middle of the line
    and the line is accepted.

    A bare CR inside a field is a classic response-splitting carrier: a
    downstream parser that terminates lines on CR alone sees two fields
    where we see one.

    Repro: `0\\r\\nX-A: a<CR>b\\r\\n\\r\\n`
    Expected: rejected.  Actual: clean End."""
    var line = List[UInt8]()
    _append_str(line, String("X-A: a"))
    line.append(UInt8(0x0D))
    _append_str(line, String("b\r\n"))
    var out = List[UInt8]()
    var d = _drain_detail(
        _trailer_wire(line^), List[UInt8](), 0, 1024 * 1024, out,
    )
    assert_true(_rejected(d))


# =============================================================================
# §5 — THE CHUNK-SIZE LINE: what may follow the hex digits.
# =============================================================================


def test_junk_after_whitespace_on_the_chunk_size_line_is_rejected() raises:
    """⛔ A REQUEST/RESPONSE-SMUGGLING DIVERGENCE OF THE SAME FAMILY AS THE
    `10000000000000005` OVERFLOW ALREADY FIXED IN THIS FILE.

    RFC 9112 §7.1: `chunk = chunk-size [ chunk-ext ] CRLF`, and
    `chunk-ext` begins with `;`. `_parse_chunk_size_line` breaks out of its
    scan on SP or HTAB with a comment about being "tolerant ... of trailing
    whitespace" — but it then returns the size it has accumulated WITHOUT
    checking what follows. So everything after the first space is ignored,
    whatever it is.

    Go's chunked reader rejects this exact input (`parseHexUint` errors on
    the first non-hex byte); we return 2 and frame the message on it. A peer
    that rejects and a peer that accepts disagree about where the next
    message starts — which is the definition of the primitive.

    TOLERANCE GUARD (passes today, and MUST keep passing): a chunk-size line
    with only trailing whitespace before the CRLF stays accepted, so this
    bar cannot be met by deleting the tolerance wholesale.

    Repro: `2 erfrferferf\\r\\nab\\r\\n0\\r\\n\\r\\n`
    Expected: rejected.  Actual: clean End, payload "ab"."""
    # Guard first — pure trailing whitespace remains tolerated.
    var out_ok = List[UInt8]()
    var d_ok = _drain_detail(
        _make_bytes(String("2 \r\nab\r\n0\r\n\r\n")),
        List[UInt8](), 0, 1024 * 1024, out_ok,
    )
    assert_equal(d_ok, String(""))
    assert_equal(out_ok.__len__(), 2)

    # The bar.
    var out = List[UInt8]()
    var d = _drain_detail(
        _make_bytes(String("2 erfrferferf\r\nab\r\n0\r\n\r\n")),
        List[UInt8](), 0, 1024 * 1024, out,
    )
    assert_true(_rejected(d))


# =============================================================================
# §6 — CHUNK-EXTENSION OVERHEAD. hyper: test_read_chunked_extensions_over_limit.
#      Go: TestChunkReaderTooMuchOverhead.
# =============================================================================


def test_chunk_extension_overhead_is_bounded() raises:
    """There is no extension budget of any kind — cumulative or ratio-based.
    The only bound on an extension is `DEFAULT_MAX_CHUNK_SIZE_LINE_BYTES`
    (256) PER LINE, which a peer simply respects while repeating the line.

    ~10k chunks, each one payload byte carrying 100 bytes of extension:
    1.06 MB of wire for 10 KB of payload, a 99% overhead ratio, accepted in
    full. Repeat it and the transfer never terminates while the CPU is spent
    scanning extension bytes that are then discarded.

    ⚠ The FALSE-POSITIVE GUARD for any fix to this lives in the sibling
    file: `test_byte_at_a_time_chunking_is_not_rejected`. A detector that
    charges FRAMING bytes rather than EXTENSION bytes turns every
    legitimate byte-at-a-time producer into a rejected response, so the two
    tests must go green together or not at all.

    Expected: rejected.  Actual: clean End, 10000-byte payload."""
    var n_chunks = 10_000
    var wire = List[UInt8]()
    var i = 0
    while i < n_chunks:
        _append_str(wire, String("1;"))
        var e = 0
        while e < 100:
            wire.append(UInt8(ord("e")))
            e = e + 1
        _append_str(wire, String("\r\nX\r\n"))
        i = i + 1
    _append_str(wire, String("0\r\n\r\n"))

    var out = List[UInt8]()
    var d = _drain_detail(List[UInt8](), wire^, 0, 8 * 1024 * 1024, out)
    assert_true(_rejected(d))


# =============================================================================
# §7 — THE CEILING THE CALLER ASKED FOR IS NOT THE CEILING THAT IS ENFORCED.
# =============================================================================


def test_the_configured_chunked_body_ceiling_is_the_one_enforced() raises:
    """⛔ THE ONE WITH A DIRECT LINE TO THE OBSERVED OUTAGE.

    `RecvRingBody.new_chunked(stream, pre, max_body_bytes)` stores
    `max_body_bytes` in `_max_body_bytes` and then drives the decoder with
    `ParseLimits.defaults()` — whose `max_body_bytes` is
    `DEFAULT_MAX_BODY_BYTES`, a hardcoded 10 MiB. The caller's number is
    never threaded in, so the ceiling actually enforced at the chunk-size
    line is 10 MiB, in BOTH directions:

      * `HttpClientConfig.max_response_body_bytes` defaults to 100 MiB and
        is threaded through `set_max_response_body_bytes` to every
        `new_chunked` call site in `state_machine.mojo`. A chunked response
        between 10 MiB and 100 MiB is rejected anyway.
        ⚠ A DISCARDED rejection leaves the decoder in
        `_DECODE_STATE_ERROR`, `is_done()` False, `poll_frame`
        returning Pending, and `collect_body` spinning-and-parking against it:
        a multi-minute wall ending in a 504 — reached WITHOUT any malformed
        byte on the wire, purely because the response was big.

      * A caller that asks for a ceiling BELOW 10 MiB does not get it: a
        chunk declaring 5 MiB under a 4 MiB ceiling is admitted at the size
        line, and 100 bytes of it are handed to the caller before anything
        notices.

    ARM A (passes today): a chunk-size line declaring exactly 10 MiB under a
      64 MiB ceiling is admitted — the truncation that follows is
      EOF_MID_RESPONSE, not a parse error. This is the accept side of the
      boundary and it is what makes ARM B mean something.
    ARM B (RED): 10 MiB + 1, still far under the 64 MiB the caller asked
      for, is rejected as a parse error.
      Repro: new_chunked(max_body_bytes=64 MiB) over `a00001\\r\\n` + EOF.
      Expected: EOF_MID_RESPONSE.  Actual: MALFORMED_CHUNKED kind=46.
    ARM C (RED): 5 MiB declared under a 4 MiB ceiling is admitted and
      partially delivered.
      Repro: new_chunked(max_body_bytes=4 MiB) over `500000\\r\\n` + 100
      bytes + EOF.
      Expected: rejected, nothing delivered.  Actual: 100 bytes delivered,
      then EOF_MID_RESPONSE."""
    comptime SIXTY_FOUR_MIB = 64 * 1024 * 1024

    # ARM A — exactly DEFAULT_MAX_BODY_BYTES (0xa00000 == 10 MiB): admitted.
    var out_a = List[UInt8]()
    var d_a = _drain_detail(
        _make_bytes(String("a00000\r\n")), List[UInt8](), 0,
        SIXTY_FOUR_MIB, out_a,
    )
    assert_true(d_a.find(String("EOF_MID_RESPONSE")) >= 0)

    # ARM B — one byte more, still 54 MiB under the CONFIGURED ceiling.
    var out_b = List[UInt8]()
    var d_b = _drain_detail(
        _make_bytes(String("a00001\r\n")), List[UInt8](), 0,
        SIXTY_FOUR_MIB, out_b,
    )
    assert_true(d_b.find(String("EOF_MID_RESPONSE")) >= 0)

    # ARM C — a ceiling BELOW the hardcoded default is not enforced at all.
    var wire_c = List[UInt8]()
    _append_str(wire_c, String("500000\r\n"))  # 0x500000 == 5 MiB
    var i = 0
    while i < 100:
        wire_c.append(UInt8(ord("A")))
        i = i + 1
    var out_c = List[UInt8]()
    var d_c = _drain_detail(
        wire_c^, List[UInt8](), 0, 4 * 1024 * 1024, out_c,
    )
    assert_equal(out_c.__len__(), 0)
    assert_true(d_c.find(String("EOF_MID_RESPONSE")) < 0)


def main() raises:
    test_trailer_field_count_limit_both_sides()
    test_single_trailer_line_over_max_header_bytes_is_rejected()
    test_same_oversized_trailer_line_two_verdicts_by_read_chunking()
    test_many_small_trailers_over_the_total_byte_budget_are_rejected()
    test_trailer_value_containing_nul_is_rejected()
    test_trailer_value_containing_a_bare_cr_is_rejected()
    test_junk_after_whitespace_on_the_chunk_size_line_is_rejected()
    test_chunk_extension_overhead_is_bounded()
    test_the_configured_chunked_body_ceiling_is_the_one_enforced()
    print("PASS: h1 response trailer + extension limits conformance")
