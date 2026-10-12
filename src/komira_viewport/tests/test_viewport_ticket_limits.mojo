# =============================================================================
# Ticket structure caps and the semantic validation layer, at their boundaries.
#
#   * Each structural count cap (projection 4096, sort keys 256, computed
#     columns 1024) admits exactly the cap and refuses one more, naming both.
#   * The total Expr node budget counts every node of the filter, the sort keys
#     and the computed columns, through every node kind (a kind counted as a
#     leaf, or a sub-tree left out, lowers the total and slips past the cap).
#   * The size floor and ceiling of the raw blob, and the window limit, are
#     held at their exact boundary.
#   * Two faults at once: the check that runs first names the refusal, across
#     the structural decode, the semantic layer, and the four layers of
#     decode_and_validate_grid_ticket.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_collections.slab import Slab
from komira_plan_expr.expr import Expr, UN_NOT, BIN_ADD, STR_CONTAINS
from komira_plan_expr.scalar_value import ScalarValue
from komira_viewport import (
    ViewportWriter,
    GridTicket,
    SourceLocator,
    ViewportSortKey,
    ViewportComputedCol,
    encode_grid_ticket,
    decode_grid_ticket,
    ViewportTicketLimits,
    validate_ticket_bytes,
    validate_ticket,
    decode_and_validate_grid_ticket,
    VIEWPORT_SRC_PARQUET_FILE,
    VIEWPORT_SRC_ICEBERG_TABLE,
)


# --- raw ticket bytes with chosen faults ---------------------------------------


def _ticket_head(
    mut w: ViewportWriter,
    magic_bad_at: Int = -1,
    version: UInt64 = UInt64(1),
    facet: UInt8 = UInt8(0),
    src_kind: UInt8 = UInt8(0),
):
    var magic: List[UInt8] = [UInt8(0x49), UInt8(0x56), UInt8(0x50), UInt8(0x31)]
    if magic_bad_at >= 0:
        magic[magic_bad_at] = magic[magic_bad_at] ^ UInt8(0x01)
    for i in range(4):
        w.write_u8(magic[i])
    w.write_uvarint(version)
    w.write_u8(facet)
    w.write_u8(src_kind)
    w.write_string(String("t.parquet"))


def _raw_ticket(
    magic_bad_at: Int = -1,
    version: UInt64 = UInt64(1),
    facet: UInt8 = UInt8(0),
    src_kind: UInt8 = UInt8(0),
    n_proj: UInt64 = UInt64(0),
    filter_flag: UInt8 = UInt8(0),
    n_sort: UInt64 = UInt64(0),
    n_comp: UInt64 = UInt64(0),
) -> List[UInt8]:
    """A ticket whose declared counts are written without the elements they
    promise: a decode that honours a count past its cap reads past the end."""
    var w = ViewportWriter()
    _ticket_head(w, magic_bad_at, version, facet, src_kind)
    w.write_uvarint(n_proj)
    w.write_u8(filter_flag)
    w.write_uvarint(n_sort)
    w.write_uvarint(n_comp)
    w.write_uvarint(UInt64(0))
    w.write_uvarint(UInt64(10))
    w.write_uvarint(UInt64(0))
    return w.take_bytes()


def test_raw_base_decodes() raises:
    var b = _raw_ticket()
    var t = decode_grid_ticket(Span(b))
    assert_equal(t.limit, UInt64(10))
    assert_equal(t.source.locator, String("t.parquet"))


def test_ticket_bad_magic_at_each_byte() raises:
    for pos in range(4):
        var b = _raw_ticket(magic_bad_at=pos)
        with assert_raises(contains="bad magic"):
            _ = decode_grid_ticket(Span(b))


def test_every_source_kind_admitted_and_the_next_refused() raises:
    for k in range(4):
        var b = _raw_ticket(src_kind=UInt8(k))
        assert_equal(decode_grid_ticket(Span(b)).source.kind, UInt8(k))
    for k in range(4, 256):
        var b = _raw_ticket(src_kind=UInt8(k))
        with assert_raises(contains="unknown source-locator kind " + String(k)):
            _ = decode_grid_ticket(Span(b))


def test_filter_flag_must_be_a_bool() raises:
    var b = _raw_ticket(filter_flag=UInt8(2))
    with assert_raises(contains="malformed bool byte 2"):
        _ = decode_grid_ticket(Span(b))


def test_count_caps_refuse_one_past() raises:
    var b = _raw_ticket(n_proj=UInt64(4097))
    with assert_raises(contains="projection column count 4097 exceeds cap 4096"):
        _ = decode_grid_ticket(Span(b))
    b = _raw_ticket(n_sort=UInt64(257))
    with assert_raises(contains="sort-key count 257 exceeds cap 256"):
        _ = decode_grid_ticket(Span(b))
    b = _raw_ticket(n_comp=UInt64(1025))
    with assert_raises(contains="computed-column count 1025 exceeds cap 1024"):
        _ = decode_grid_ticket(Span(b))
    # High bytes in a count: compared before any conversion, so refused.
    b = _raw_ticket(n_sort=UInt64(0xFFFFFFFFFFFFFFFF))
    with assert_raises(contains="exceeds cap 256"):
        _ = decode_grid_ticket(Span(b))
    b = _raw_ticket(n_comp=UInt64(0x8000000000000000))
    with assert_raises(contains="exceeds cap 1024"):
        _ = decode_grid_ticket(Span(b))


def _source() -> SourceLocator:
    return SourceLocator(VIEWPORT_SRC_PARQUET_FILE, String("t.parquet"))


def test_count_caps_admit_the_cap() raises:
    var proj = List[String]()
    for i in range(4096):
        proj.append(String("p") + String(i))
    var no_filter: Optional[Expr] = None
    var t = GridTicket(
        _source(), proj^, no_filter^, Slab[ViewportSortKey](),
        Slab[ViewportComputedCol](), UInt64(0), UInt64(1), UInt64(0),
    )
    var b = encode_grid_ticket(t)
    assert_equal(len(decode_grid_ticket(Span(b)).projection), 4096)

    var sk = Slab[ViewportSortKey]()
    for i in range(256):
        sk.append(ViewportSortKey(Expr.col_ref(String("s") + String(i)), i % 2 == 1))
    var no_filter2: Optional[Expr] = None
    var t2 = GridTicket(
        _source(), List[String](), no_filter2^, sk^,
        Slab[ViewportComputedCol](), UInt64(0), UInt64(1), UInt64(0),
    )
    var b2 = encode_grid_ticket(t2)
    var d2 = decode_grid_ticket(Span(b2))
    assert_equal(d2.sort_keys.len(), 256)
    assert_true(not d2.sort_keys[0].descending)
    assert_true(d2.sort_keys[255].descending)

    var cc = Slab[ViewportComputedCol]()
    for i in range(1024):
        cc.append(ViewportComputedCol(String("c") + String(i), Expr.col_ref(String("x"))))
    var no_filter3: Optional[Expr] = None
    var t3 = GridTicket(
        _source(), List[String](), no_filter3^, Slab[ViewportSortKey](),
        cc^, UInt64(0), UInt64(1), UInt64(0),
    )
    var b3 = encode_grid_ticket(t3)
    var d3 = decode_grid_ticket(Span(b3))
    assert_equal(d3.computed.len(), 1024)
    assert_equal(d3.computed[1023].name, String("c1023"))


def test_ticket_first_fault_is_reported() raises:
    var b = _raw_ticket(magic_bad_at=0, version=UInt64(2))
    with assert_raises(contains="bad magic"):
        _ = decode_grid_ticket(Span(b))
    b = _raw_ticket(version=UInt64(2), facet=UInt8(1))
    with assert_raises(contains="unsupported protocol version 2"):
        _ = decode_grid_ticket(Span(b))
    b = _raw_ticket(facet=UInt8(1), src_kind=UInt8(9))
    with assert_raises(contains="facet 1 is not the grid facet"):
        _ = decode_grid_ticket(Span(b))
    b = _raw_ticket(src_kind=UInt8(9), n_proj=UInt64(5000))
    with assert_raises(contains="unknown source-locator kind 9"):
        _ = decode_grid_ticket(Span(b))
    b = _raw_ticket(n_proj=UInt64(5000), n_sort=UInt64(300))
    with assert_raises(contains="projection column count 5000"):
        _ = decode_grid_ticket(Span(b))
    b = _raw_ticket(n_sort=UInt64(300), n_comp=UInt64(2000))
    with assert_raises(contains="sort-key count 300"):
        _ = decode_grid_ticket(Span(b))


# --- semantic layer -------------------------------------------------------------


def _eight_node_ticket(proj: List[String], var comp_names: List[String]) -> GridTicket:
    """filter NOT(a) = 2 nodes; sort key contains(b, 'x') = 2; first computed
    column alias(a + 1) = 4 (alias, binary, col-ref, literal); every further
    computed column is a single col-ref."""
    var filter: Optional[Expr] = Expr.unary(UN_NOT, Expr.col_ref(String("a")))
    var sk = Slab[ViewportSortKey]()
    sk.append(ViewportSortKey(
        Expr.string_op(STR_CONTAINS, Expr.col_ref(String("b")), String("x")), False
    ))
    var cc = Slab[ViewportComputedCol]()
    for i in range(len(comp_names)):
        if i == 0:
            cc.append(ViewportComputedCol(comp_names[i], Expr.alias(
                Expr.binary(BIN_ADD, Expr.col_ref(String("a")),
                            Expr.literal(ScalarValue.from_int(1))),
                String("inner"),
            )))
        else:
            cc.append(ViewportComputedCol(comp_names[i], Expr.col_ref(String("a"))))
    return GridTicket(
        _source(), proj.copy(), filter^, sk^, cc^, UInt64(0), UInt64(10), UInt64(0)
    )


def test_node_budget_counts_every_kind() raises:
    var t = _eight_node_ticket(List[String](), [String("c")])
    validate_ticket(t, ViewportTicketLimits(max_total_expr_nodes=8))
    with assert_raises(contains="total Expr node count 8 exceeds cap 7"):
        validate_ticket(t, ViewportTicketLimits(max_total_expr_nodes=7))
    # A second computed column adds one node: 9.
    var t9 = _eight_node_ticket(List[String](), [String("c"), String("d")])
    with assert_raises(contains="total Expr node count 9 exceeds cap 8"):
        validate_ticket(t9, ViewportTicketLimits(max_total_expr_nodes=8))


def test_blank_computed_name_refused() raises:
    var t = _eight_node_ticket(List[String](), [String("c"), String("")])
    with assert_raises(contains="blank computed-column name at index 1"):
        validate_ticket(t, ViewportTicketLimits())


def test_window_limit_boundary() raises:
    var at = GridTicket.minimal(_source(), UInt64(0), UInt64(50))
    validate_ticket(at, ViewportTicketLimits(max_window_limit=UInt64(50)))
    with assert_raises(contains="window limit 50 exceeds cap 49"):
        validate_ticket(at, ViewportTicketLimits(max_window_limit=UInt64(49)))


def test_ticket_size_boundaries() raises:
    var six = List[UInt8]()
    for _ in range(6):
        six.append(UInt8(0))
    validate_ticket_bytes(Span(six), ViewportTicketLimits(max_ticket_bytes=6))
    with assert_raises(contains="ticket size 6 bytes exceeds cap 5 bytes"):
        validate_ticket_bytes(Span(six), ViewportTicketLimits(max_ticket_bytes=5))
    _ = six.pop()
    with assert_raises(contains="too short"):
        validate_ticket_bytes(Span(six), ViewportTicketLimits())


def test_semantic_first_fault_is_reported() raises:
    var limits = ViewportTicketLimits(max_total_expr_nodes=1, max_window_limit=UInt64(5))
    # empty locator AND window over cap AND node budget over.
    var t1 = _eight_node_ticket(List[String](), [String("c")])
    t1.source = SourceLocator(VIEWPORT_SRC_ICEBERG_TABLE, String(""))
    with assert_raises(contains="empty source locator"):
        validate_ticket(t1, limits)
    # window over cap AND node budget over.
    var t2 = _eight_node_ticket(List[String](), [String("c")])
    with assert_raises(contains="window limit 10 exceeds cap 5"):
        validate_ticket(t2, limits)
    # node budget over AND blank projection name.
    var t3 = _eight_node_ticket([String("")], [String("c")])
    with assert_raises(contains="total Expr node count 8"):
        validate_ticket(t3, ViewportTicketLimits(max_total_expr_nodes=1))
    # blank projection AND blank computed name AND a duplicate (both blank).
    var t4 = _eight_node_ticket([String("")], [String("c"), String("")])
    with assert_raises(contains="blank projection column name at index 0"):
        validate_ticket(t4, ViewportTicketLimits())
    # blank computed name AND a duplicate pair of blank names.
    var t5 = _eight_node_ticket(List[String](), [String("c"), String(""), String("")])
    with assert_raises(contains="blank computed-column name at index 1"):
        validate_ticket(t5, ViewportTicketLimits())


def test_layers_run_in_order() raises:
    # Size before structure: an over-large blob with a bad magic.
    var b = _raw_ticket(magic_bad_at=0)
    with assert_raises(contains="exceeds cap 8 bytes"):
        _ = decode_and_validate_grid_ticket(Span(b), ViewportTicketLimits(max_ticket_bytes=8))
    # Structure before semantics: an empty locator followed by a trailing byte.
    var t = GridTicket.minimal(SourceLocator(VIEWPORT_SRC_PARQUET_FILE, String("")), UInt64(0), UInt64(1))
    var tb = encode_grid_ticket(t)
    tb.append(UInt8(0))
    with assert_raises(contains="1 trailing bytes"):
        _ = decode_and_validate_grid_ticket(Span(tb), ViewportTicketLimits())
    _ = tb.pop()
    with assert_raises(contains="empty source locator"):
        _ = decode_and_validate_grid_ticket(Span(tb), ViewportTicketLimits())


def test_limits_defaults_and_copy() raises:
    var d = ViewportTicketLimits.default()
    assert_equal(d.max_ticket_bytes, 256 * 1024)
    assert_equal(d.max_total_expr_nodes, 4096)
    assert_equal(d.max_window_limit, UInt64(1_000_000))
    var l = ViewportTicketLimits(max_ticket_bytes=1, max_total_expr_nodes=2, max_window_limit=UInt64(3))
    var c = l.copy()
    l.max_ticket_bytes = 9
    assert_equal(c.max_ticket_bytes, 1)
    assert_equal(c.max_total_expr_nodes, 2)
    assert_equal(c.max_window_limit, UInt64(3))


def test_source_locator_copy() raises:
    var s = SourceLocator(VIEWPORT_SRC_ICEBERG_TABLE, String("db.t"))
    var c = s.copy()
    s.locator = String("other")
    assert_equal(c.kind, VIEWPORT_SRC_ICEBERG_TABLE)
    assert_equal(c.locator, String("db.t"))


def main() raises:
    var suite = TestSuite()
    suite.test[test_raw_base_decodes]()
    suite.test[test_ticket_bad_magic_at_each_byte]()
    suite.test[test_every_source_kind_admitted_and_the_next_refused]()
    suite.test[test_filter_flag_must_be_a_bool]()
    suite.test[test_count_caps_refuse_one_past]()
    suite.test[test_count_caps_admit_the_cap]()
    suite.test[test_ticket_first_fault_is_reported]()
    suite.test[test_node_budget_counts_every_kind]()
    suite.test[test_blank_computed_name_refused]()
    suite.test[test_window_limit_boundary]()
    suite.test[test_ticket_size_boundaries]()
    suite.test[test_semantic_first_fault_is_reported]()
    suite.test[test_layers_run_in_order]()
    suite.test[test_limits_defaults_and_copy]()
    suite.test[test_source_locator_copy]()
    suite^.run()
