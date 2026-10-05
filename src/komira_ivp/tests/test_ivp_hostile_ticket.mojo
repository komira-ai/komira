# =============================================================================
# HOSTILE / malformed ticket REJECTION.
#
# A viewport server treats every ticket as untrusted (a remote client can POST
# arbitrary bytes). This suite is the falsifying gate for validation: every hostile
# shape MUST be rejected fail-closed (a `raises`, never a silent accept, never a
# crash). It exercises all four defense layers:
#
#   Layer 0 (SIZE):   over-large blob; too-short blob.
#   Layer 1 (STRUCT): bad magic; unknown version; wrong facet; unknown source
#                     kind; truncated body; trailing bytes; over-count fields.
#   Layer 2 (EXPR):   a disallowed Expr tag (agg-fn / UDF-bearing); a disallowed
#                     op code inside an allowed tag; an over-deep tree.
#   Layer 3 (SEMANTIC): empty locator; blank projection name; window over cap;
#                     total-node budget exceeded.
#
# The disallowed-tag / over-deep cases are hand-assembled byte blobs (a real
# attacker posts bytes, not a Mojo Expr), proving the DECODER — not a Mojo type
# check — is what rejects an out-of-allow-list node.
# =============================================================================

from std.testing import TestSuite, assert_raises, assert_true

from komira_core.collections import Slab
from komira_core.plan.expr import Expr
from komira_ivp import (
    IvpWriter,
    GridTicket,
    SourceLocator,
    IvpSortKey,
    IvpComputedCol,
    encode_grid_ticket,
    decode_grid_ticket,
    IvpTicketLimits,
    validate_ticket_bytes,
    validate_ticket,
    decode_and_validate_grid_ticket,
    IVP_SRC_PARQUET_FILE,
    IVP_VERSION_1,
)


# Magic + framing constants (mirror ivp_ticket.mojo — a hostile client would
# know these, so the tests must too).
comptime M0: UInt8 = 0x49
comptime M1: UInt8 = 0x56
comptime M2: UInt8 = 0x50
comptime M3: UInt8 = 0x31
comptime FACET_GRID: UInt8 = 0
comptime EXPR_AGG_FN_TAG: UInt8 = 12  # a NON-allow-listed Expr tag.
comptime EXPR_BINARY_OP_TAG: UInt8 = 3
comptime BOGUS_BINOP: UInt8 = 200  # not a real op code.


def _valid_minimal_bytes() raises -> List[UInt8]:
    """A known-good minimal window ticket — the base every mutation starts
    from, so a mutation test proves the mutation (not a latent bug) is what
    triggers rejection."""
    var t = GridTicket.minimal(
        SourceLocator(IVP_SRC_PARQUET_FILE, String("/data/t.parquet")),
        UInt64(0),
        UInt64(100),
    )
    return encode_grid_ticket(t)


def test_valid_base_decodes() raises:
    """Sanity: the base blob the mutations start from DOES decode+validate."""
    var bytes = _valid_minimal_bytes()
    var limits = IvpTicketLimits.default()
    var t = decode_and_validate_grid_ticket(Span(bytes), limits)
    assert_true(t.limit == UInt64(100))


# --- Layer 0: size ------------------------------------------------------------


def test_reject_oversize_ticket() raises:
    var limits = IvpTicketLimits(max_ticket_bytes=32)
    var big = List[UInt8]()
    for _ in range(1024):
        big.append(UInt8(0))
    with assert_raises(contains="exceeds cap"):
        validate_ticket_bytes(Span(big), limits)


def test_reject_too_short_ticket() raises:
    var limits = IvpTicketLimits.default()
    var tiny = List[UInt8]()
    tiny.append(M0)
    tiny.append(M1)
    with assert_raises(contains="too short"):
        validate_ticket_bytes(Span(tiny), limits)


# --- Layer 1: structural framing ---------------------------------------------


def test_reject_bad_magic() raises:
    var bytes = _valid_minimal_bytes()
    bytes[0] = UInt8(0xFF)  # corrupt the magic.
    with assert_raises(contains="bad magic"):
        _ = decode_grid_ticket(Span(bytes))


def test_reject_unknown_version() raises:
    var w = IvpWriter()
    w.write_u8(M0)
    w.write_u8(M1)
    w.write_u8(M2)
    w.write_u8(M3)
    w.write_uvarint(UInt64(999))  # unsupported version
    w.write_u8(FACET_GRID)
    var bytes = w.take_bytes()
    with assert_raises(contains="unsupported protocol version"):
        _ = decode_grid_ticket(Span(bytes))


def test_reject_wrong_facet() raises:
    var w = IvpWriter()
    w.write_u8(M0)
    w.write_u8(M1)
    w.write_u8(M2)
    w.write_u8(M3)
    w.write_uvarint(IVP_VERSION_1)
    w.write_u8(UInt8(1))  # text facet — not served in v1
    var bytes = w.take_bytes()
    with assert_raises(contains="grid facet"):
        _ = decode_grid_ticket(Span(bytes))


def test_reject_unknown_source_kind() raises:
    var w = IvpWriter()
    w.write_u8(M0)
    w.write_u8(M1)
    w.write_u8(M2)
    w.write_u8(M3)
    w.write_uvarint(IVP_VERSION_1)
    w.write_u8(FACET_GRID)
    w.write_u8(UInt8(99))  # bogus source kind
    var bytes = w.take_bytes()
    with assert_raises(contains="unknown source-locator kind"):
        _ = decode_grid_ticket(Span(bytes))


def test_reject_truncated_body() raises:
    var bytes = _valid_minimal_bytes()
    # Drop the last 3 bytes (the view_version varint + tail) — the cursor runs
    # past the buffer end and must raise, not read garbage.
    var truncated = List[UInt8]()
    for i in range(len(bytes) - 3):
        truncated.append(bytes[i])
    with assert_raises():
        _ = decode_grid_ticket(Span(truncated))


def test_reject_trailing_bytes() raises:
    var bytes = _valid_minimal_bytes()
    bytes.append(UInt8(0))  # one extra byte after a well-formed message
    bytes.append(UInt8(0))
    with assert_raises(contains="trailing bytes"):
        _ = decode_grid_ticket(Span(bytes))


def test_reject_invalid_utf8_string() raises:
    # A source locator whose bytes are NOT valid UTF-8 (a lone 0xFF) — read_string
    # validates UTF-8 at the choke point and rejects (an untrusted ticket cannot
    # smuggle malformed bytes into a String).
    var w = IvpWriter()
    w.write_u8(M0)
    w.write_u8(M1)
    w.write_u8(M2)
    w.write_u8(M3)
    w.write_uvarint(IVP_VERSION_1)
    w.write_u8(FACET_GRID)
    w.write_u8(IVP_SRC_PARQUET_FILE)
    # locator string: length 3, bytes [0x61, 0xFF, 0x62] — 0xFF is never a valid
    # UTF-8 byte.
    w.write_uvarint(UInt64(3))
    w.write_u8(UInt8(0x61))
    w.write_u8(UInt8(0xFF))
    w.write_u8(UInt8(0x62))
    var bytes = w.take_bytes()
    with assert_raises(contains="UTF-8"):
        _ = decode_grid_ticket(Span(bytes))


def test_reject_overcount_projection() raises:
    var w = IvpWriter()
    w.write_u8(M0)
    w.write_u8(M1)
    w.write_u8(M2)
    w.write_u8(M3)
    w.write_uvarint(IVP_VERSION_1)
    w.write_u8(FACET_GRID)
    w.write_u8(IVP_SRC_PARQUET_FILE)
    w.write_string(String("/data/t.parquet"))
    w.write_uvarint(UInt64(1_000_000_000))  # absurd projection count
    var bytes = w.take_bytes()
    with assert_raises(contains="exceeds cap"):
        _ = decode_grid_ticket(Span(bytes))


# --- Layer 2: Expr allow-list + op codes + depth -----------------------------


def _ticket_prefix_with_filter(mut w: IvpWriter):
    """Write a valid ticket header up to (and including) the has-filter=True
    flag, so the caller can append a hostile filter Expr and then the tail."""
    w.write_u8(M0)
    w.write_u8(M1)
    w.write_u8(M2)
    w.write_u8(M3)
    w.write_uvarint(IVP_VERSION_1)
    w.write_u8(FACET_GRID)
    w.write_u8(IVP_SRC_PARQUET_FILE)
    w.write_string(String("/data/t.parquet"))
    w.write_uvarint(UInt64(0))   # projection count = 0
    w.write_bool(True)           # has_filter = True


def _ticket_tail(mut w: IvpWriter):
    """Write the ticket tail after the filter Expr: 0 sort keys, 0 computed,
    offset/limit/view_version."""
    w.write_uvarint(UInt64(0))   # sort keys
    w.write_uvarint(UInt64(0))   # computed
    w.write_uvarint(UInt64(0))   # offset
    w.write_uvarint(UInt64(100)) # limit
    w.write_uvarint(UInt64(0))   # view_version


def test_reject_disallowed_expr_tag() raises:
    # A filter Expr whose FIRST tag byte is EXPR_AGG_FN (12) — a UDF-adjacent,
    # non-allow-listed node. The decoder must reject it (this is the core
    # "reject arbitrary Expr trees / UDF references" guarantee).
    var w = IvpWriter()
    _ticket_prefix_with_filter(w)
    w.write_u8(EXPR_AGG_FN_TAG)  # hostile: agg-fn tag, not in the allow-list
    _ticket_tail(w)
    var bytes = w.take_bytes()
    with assert_raises(contains="allow-list"):
        _ = decode_grid_ticket(Span(bytes))


def test_reject_disallowed_binop_code() raises:
    # A binary-op Expr with a bogus op code (200) — an allowed TAG but a
    # disallowed op must still be rejected.
    var w = IvpWriter()
    _ticket_prefix_with_filter(w)
    w.write_u8(EXPR_BINARY_OP_TAG)
    w.write_u8(BOGUS_BINOP)
    # left = col_ref("a"): tag 0, name "a", side 0
    w.write_u8(UInt8(0))
    w.write_string(String("a"))
    w.write_u8(UInt8(0))
    # right = col_ref("b")
    w.write_u8(UInt8(0))
    w.write_string(String("b"))
    w.write_u8(UInt8(0))
    _ticket_tail(w)
    var bytes = w.take_bytes()
    with assert_raises(contains="disallowed binary op"):
        _ = decode_grid_ticket(Span(bytes))


def test_reject_overdeep_expr_tree() raises:
    # A pathologically deep NOT(NOT(NOT(...))) chain: 128 EXPR_UNARY_OP(NOT)
    # tags before a leaf. Exceeds IVP_MAX_EXPR_DEPTH (64) -> reject.
    var w = IvpWriter()
    _ticket_prefix_with_filter(w)
    var depth = 128
    for _ in range(depth):
        w.write_u8(UInt8(4))   # EXPR_UNARY_OP
        w.write_u8(UInt8(0))   # UN_NOT
    # leaf col_ref("x")
    w.write_u8(UInt8(0))
    w.write_string(String("x"))
    w.write_u8(UInt8(0))
    _ticket_tail(w)
    var bytes = w.take_bytes()
    with assert_raises(contains="max depth"):
        _ = decode_grid_ticket(Span(bytes))


# --- Layer 3: semantic --------------------------------------------------------


def test_reject_empty_locator() raises:
    var t = GridTicket.minimal(
        SourceLocator(IVP_SRC_PARQUET_FILE, String("")),  # empty!
        UInt64(0),
        UInt64(100),
    )
    var limits = IvpTicketLimits.default()
    with assert_raises(contains="empty source locator"):
        validate_ticket(t, limits)


def test_reject_window_over_cap() raises:
    var t = GridTicket.minimal(
        SourceLocator(IVP_SRC_PARQUET_FILE, String("/data/t.parquet")),
        UInt64(0),
        UInt64(10_000_000),  # over the default 1M cap
    )
    var limits = IvpTicketLimits.default()
    with assert_raises(contains="window limit"):
        validate_ticket(t, limits)


def test_reject_blank_projection_name() raises:
    var proj = List[String]()
    proj.append(String("ok"))
    proj.append(String(""))  # blank!
    var filt: Optional[Expr] = None
    var t = GridTicket(
        SourceLocator(IVP_SRC_PARQUET_FILE, String("/data/t.parquet")),
        proj^,
        filt^,
        Slab[IvpSortKey](),
        Slab[IvpComputedCol](),
        UInt64(0),
        UInt64(100),
        UInt64(0),
    )
    var limits = IvpTicketLimits.default()
    with assert_raises(contains="blank projection"):
        validate_ticket(t, limits)


def _ticket_declaring(
    imm projection: List[String], imm computed_names: List[String]
) raises -> GridTicket:
    """A ticket whose DECLARED output names are `projection ++ computed_names` —
    the list a server turns into the top Project."""
    var proj = List[String]()
    for i in range(len(projection)):
        proj.append(projection[i].copy())
    var computed = Slab[IvpComputedCol]()
    for i in range(len(computed_names)):
        computed.append(
            IvpComputedCol(computed_names[i].copy(), Expr.col_ref("a"))
        )
    var filt: Optional[Expr] = None
    return GridTicket(
        SourceLocator(IVP_SRC_PARQUET_FILE, String("/data/t.parquet")),
        proj^,
        filt^,
        Slab[IvpSortKey](),
        computed^,
        UInt64(0),
        UInt64(100),
        UInt64(0),
    )


def test_reject_duplicate_declared_output_name() raises:
    """★ A window may not carry two columns with one name, and the DOOR refuses
    the half of that class a ticket can express on its own — before any file is
    opened.

    The predicate is over ONE list (`projection ++ computed names`), not over a
    catalogue of collision shapes, so all three ticket-expressible spellings are
    the same check. The fourth spelling — a computed name that collides with a
    SOURCE column — is invisible here (this layer never sees a schema) and is
    refused at serve time by the server's own unique-output-names check."""
    var limits = IvpTicketLimits.default()
    var none = List[String]()

    # (1) The same name twice in the PROJECTION.
    var dup_proj: List[String] = [String("a"), String("b"), String("a")]
    with assert_raises(contains="declares the output name 'a' twice"):
        validate_ticket(_ticket_declaring(dup_proj, none), limits)

    # (2) TWO COMPUTED columns with one name.
    var dup_comp: List[String] = [String("t"), String("t")]
    with assert_raises(contains="declares the output name 't' twice"):
        validate_ticket(_ticket_declaring(none, dup_comp), limits)

    # (3) A computed name that collides with a PROJECTION entry.
    var proj3: List[String] = [String("a"), String("b")]
    var comp3: List[String] = [String("b")]
    with assert_raises(contains="declares the output name 'b' twice"):
        validate_ticket(_ticket_declaring(proj3, comp3), limits)

    # (4) A PROJECTION that names the computed column — a shape the memory
    # conformer used to accept and the engine refused with a planner-internal
    # message ("column 'x' not in source schema"). One answer now, at the door,
    # in words a client can act on.
    var proj4: List[String] = [String("t")]
    var comp4: List[String] = [String("t")]
    with assert_raises(contains="declares the output name 't' twice"):
        validate_ticket(_ticket_declaring(proj4, comp4), limits)


def test_distinct_declared_output_names_are_admitted() raises:
    """THE CONTROL. A refusal that refuses everything satisfies every assertion
    above; these are the ticket shapes that MUST still be admitted."""
    var limits = IvpTicketLimits.default()
    var none = List[String]()

    # Distinct projection + distinct computed names, and the near-miss of every
    # refusal arm above (same shape, one character different).
    var proj: List[String] = [String("a"), String("b")]
    var comp: List[String] = [String("t"), String("t2")]
    validate_ticket(_ticket_declaring(proj, comp), limits)

    # No projection at all (the calculated-column shape), one computed column.
    var comp1: List[String] = [String("t")]
    validate_ticket(_ticket_declaring(none, comp1), limits)

    # Neither — a plain window.
    validate_ticket(_ticket_declaring(none, none), limits)

    # Case DIFFERS, so these are two different column names and both survive.
    # (The bridge's own lowering is case-insensitive when RESOLVING a bareword
    # to a column, but the wire carries the schema's canonical spelling and this
    # layer compares what it was sent.)
    var case_proj: List[String] = [String("Qty"), String("qty")]
    validate_ticket(_ticket_declaring(case_proj, none), limits)


def main() raises:
    var suite = TestSuite()
    suite.test[test_valid_base_decodes]()
    suite.test[test_reject_oversize_ticket]()
    suite.test[test_reject_too_short_ticket]()
    suite.test[test_reject_bad_magic]()
    suite.test[test_reject_unknown_version]()
    suite.test[test_reject_wrong_facet]()
    suite.test[test_reject_unknown_source_kind]()
    suite.test[test_reject_truncated_body]()
    suite.test[test_reject_trailing_bytes]()
    suite.test[test_reject_invalid_utf8_string]()
    suite.test[test_reject_overcount_projection]()
    suite.test[test_reject_disallowed_expr_tag]()
    suite.test[test_reject_disallowed_binop_code]()
    suite.test[test_reject_overdeep_expr_tree]()
    suite.test[test_reject_empty_locator]()
    suite.test[test_reject_window_over_cap]()
    suite.test[test_reject_blank_projection_name]()
    suite.test[test_reject_duplicate_declared_output_name]()
    suite.test[test_distinct_declared_output_names_are_admitted]()
    suite^.run()
