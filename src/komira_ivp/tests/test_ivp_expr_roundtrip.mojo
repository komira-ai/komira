# =============================================================================
# Expr WIRE round-trip (identical plan hash).
#
# The falsifying gate: an Expr encoded to IVP wire bytes
# and decoded back reconstructs a STRUCTURALLY IDENTICAL tree —
#     Expr -> encode_expr -> bytes -> decode_expr -> Expr'
# with structural_hash(Expr) == structural_hash(Expr').
#
# "structural plan hash" here is FNV-1a over the Expr's canonical `write_to`
# text — the EXACT mechanism `LogicalPlan.structural_hash()` (the plan_compile_
# cache key) uses. We assert BOTH the textual form (the strongest structural
# check) AND its FNV-1a hash (to match the exit-criterion wording literally),
# across the whole v1 Expr allow-list plus a deep composite predicate. We ALSO
# prove the full GridTicket round-trips byte-for-byte (encode∘decode∘encode is
# stable) so the round-trip guarantee holds at the ticket level, not just per
# Expr.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.plan.expr import (
    Expr,
    BIN_ADD, BIN_SUB, BIN_MUL, BIN_DIV,
    BIN_EQ, BIN_NE, BIN_LT, BIN_LE, BIN_GT, BIN_GE,
    BIN_AND, BIN_OR,
    UN_NOT, UN_NEGATE, UN_IS_NULL, UN_IS_NOT_NULL,
    STR_CONTAINS, STR_STARTS_WITH, STR_ENDS_WITH, STR_LIKE,
)
from komira_core.collections import Slab
from komira_core.plan.scalar_value import ScalarValue
from komira_ivp import (
    IvpWriter,
    IvpReader,
    encode_expr,
    decode_expr,
    SourceLocator,
    GridTicket,
    IvpSortKey,
    IvpComputedCol,
    encode_grid_ticket,
    decode_grid_ticket,
    IVP_SRC_PARQUET_FILE,
    IVP_SRC_GLOB,
    RowCount,
    encode_grid_response,
    decode_grid_response,
    IVP_COUNT_EXACT,
    IVP_COUNT_ESTIMATED,
    IVP_PAYLOAD_ARROW_IPC,
    IVP_PAYLOAD_JSON,
)


# --- structural-hash helpers (mirror LogicalPlan.structural_hash) ------------


def _expr_text(e: Expr) -> String:
    """The canonical textual form of an Expr (its `write_to` output) — the
    structural fingerprint LogicalPlan.structural_hash hashes."""
    var s = String("")
    s.write(e)
    return s^


def _fnv1a(s: String) -> UInt64:
    """FNV-1a 64-bit over the string bytes — byte-identical to the folding
    inside LogicalPlan.structural_hash()."""
    var h: UInt64 = 14695981039346656037
    var prime: UInt64 = 1099511628211
    var b = s.as_bytes()
    for i in range(len(b)):
        h = h ^ UInt64(b[i])
        h = h * prime
    return h


def _assert_expr_roundtrips(e: Expr) raises:
    """Encode → decode → assert identical text AND identical FNV-1a hash."""
    var w = IvpWriter()
    encode_expr(w, e)
    var bytes = w.take_bytes()
    var r = IvpReader(bytes^)
    var decoded = decode_expr(r)
    r.expect_end()  # the Expr consumed exactly its bytes.

    var orig_text = _expr_text(e)
    var dec_text = _expr_text(decoded)
    assert_equal(orig_text, dec_text)
    assert_equal(_fnv1a(orig_text), _fnv1a(dec_text))


# --- per-variant round-trips -------------------------------------------------


def test_roundtrip_col_ref_plain() raises:
    _assert_expr_roundtrips(Expr.col_ref("l_orderkey"))


def test_roundtrip_col_ref_sides() raises:
    _assert_expr_roundtrips(Expr.left("l_key"))
    _assert_expr_roundtrips(Expr.right("r_key"))


def test_roundtrip_literals() raises:
    _assert_expr_roundtrips(Expr.literal(ScalarValue.from_int64(42)))
    _assert_expr_roundtrips(Expr.literal(ScalarValue.from_int32(Int32(-7))))
    _assert_expr_roundtrips(Expr.literal(ScalarValue.from_float(3.14159)))
    _assert_expr_roundtrips(Expr.literal(ScalarValue.from_float32(Float32(2.5))))
    _assert_expr_roundtrips(Expr.literal(ScalarValue.from_string("shipped")))
    _assert_expr_roundtrips(Expr.literal(ScalarValue.from_bool(True)))
    _assert_expr_roundtrips(Expr.literal(ScalarValue.from_bool(False)))
    _assert_expr_roundtrips(Expr.literal(ScalarValue()))  # untyped null


def test_roundtrip_negative_and_large_ints() raises:
    _assert_expr_roundtrips(Expr.literal(ScalarValue.from_int64(-1)))
    _assert_expr_roundtrips(
        Expr.literal(ScalarValue.from_int64(9223372036854775807))
    )
    _assert_expr_roundtrips(
        Expr.literal(ScalarValue.from_int64(-9223372036854775808))
    )


def test_roundtrip_comparison_predicate() raises:
    # col("age") > 25
    var e = Expr.binary(
        BIN_GT, Expr.col_ref("age"), Expr.literal(ScalarValue.from_int64(25))
    )
    _assert_expr_roundtrips(e)


def test_roundtrip_logical_and_of_comparisons() raises:
    # (col("age") >= 18) & (col("age") < 65)
    var left = Expr.binary(
        BIN_GE, Expr.col_ref("age"), Expr.literal(ScalarValue.from_int64(18))
    )
    var right = Expr.binary(
        BIN_LT, Expr.col_ref("age"), Expr.literal(ScalarValue.from_int64(65))
    )
    _assert_expr_roundtrips(Expr.binary(BIN_AND, left^, right^))


def test_roundtrip_arithmetic() raises:
    # (col("price") * col("qty"))
    _assert_expr_roundtrips(
        Expr.binary(BIN_MUL, Expr.col_ref("price"), Expr.col_ref("qty"))
    )


def test_roundtrip_unary_ops() raises:
    _assert_expr_roundtrips(Expr.unary(UN_IS_NULL, Expr.col_ref("email")))
    _assert_expr_roundtrips(Expr.unary(UN_IS_NOT_NULL, Expr.col_ref("email")))
    _assert_expr_roundtrips(Expr.unary(UN_NEGATE, Expr.col_ref("balance")))
    var eq = Expr.binary(
        BIN_EQ, Expr.col_ref("status"), Expr.literal(ScalarValue.from_string("x"))
    )
    _assert_expr_roundtrips(Expr.unary(UN_NOT, eq^))


def test_roundtrip_string_ops() raises:
    _assert_expr_roundtrips(
        Expr.string_op(STR_CONTAINS, Expr.col_ref("name"), "smith")
    )
    _assert_expr_roundtrips(
        Expr.string_op(STR_STARTS_WITH, Expr.col_ref("name"), "Dr")
    )
    _assert_expr_roundtrips(
        Expr.string_op(STR_ENDS_WITH, Expr.col_ref("file"), ".parquet")
    )
    _assert_expr_roundtrips(
        Expr.string_op(STR_LIKE, Expr.col_ref("sku"), "A%Z")
    )


def test_roundtrip_alias_computed_column() raises:
    # (col("price") * col("qty")).alias("total")
    var prod = Expr.binary(BIN_MUL, Expr.col_ref("price"), Expr.col_ref("qty"))
    _assert_expr_roundtrips(Expr.alias(prod^, "total"))


def test_roundtrip_deep_composite() raises:
    # ((a + b) * c > 100) & (name contains "z") & NOT(flag)
    var ab = Expr.binary(BIN_ADD, Expr.col_ref("a"), Expr.col_ref("b"))
    var abc = Expr.binary(BIN_MUL, ab^, Expr.col_ref("c"))
    var cmp = Expr.binary(BIN_GT, abc^, Expr.literal(ScalarValue.from_int64(100)))
    var namez = Expr.string_op(STR_CONTAINS, Expr.col_ref("name"), "z")
    var notflag = Expr.unary(UN_NOT, Expr.col_ref("flag"))
    var lhs = Expr.binary(BIN_AND, cmp^, namez^)
    _assert_expr_roundtrips(Expr.binary(BIN_AND, lhs^, notflag^))


# --- ticket-level round-trip (byte-for-byte stability) -----------------------


def test_ticket_roundtrip_byte_stable() raises:
    var proj = List[String]()
    proj.append(String("l_orderkey"))
    proj.append(String("l_quantity"))

    var filt = Expr.binary(
        BIN_GT, Expr.col_ref("l_quantity"), Expr.literal(ScalarValue.from_int64(30))
    )

    var sort_keys = Slab[IvpSortKey]()
    sort_keys.append(IvpSortKey(Expr.col_ref("l_orderkey"), False))
    sort_keys.append(IvpSortKey(Expr.col_ref("l_quantity"), True))

    var computed = Slab[IvpComputedCol]()
    var prod = Expr.binary(
        BIN_MUL, Expr.col_ref("l_extendedprice"), Expr.col_ref("l_quantity")
    )
    computed.append(IvpComputedCol(String("gross"), prod^))

    var t = GridTicket(
        SourceLocator(IVP_SRC_GLOB, String("/data/lineitem/*.parquet")),
        proj^,
        Optional[Expr](filt^),
        sort_keys^,
        computed^,
        UInt64(1_000_000),
        UInt64(512),
        UInt64(7),
    )

    var bytes1 = encode_grid_ticket(t)
    var decoded = decode_grid_ticket(Span(bytes1))
    var bytes2 = encode_grid_ticket(decoded)

    # encode∘decode∘encode must be byte-for-byte stable.
    assert_equal(len(bytes1), len(bytes2))
    for i in range(len(bytes1)):
        assert_equal(bytes1[i], bytes2[i])

    # Structural round-trip of the decoded fields.
    assert_equal(decoded.source.kind, IVP_SRC_GLOB)
    assert_equal(decoded.source.locator, String("/data/lineitem/*.parquet"))
    assert_equal(len(decoded.projection), 2)
    assert_equal(decoded.offset, UInt64(1_000_000))
    assert_equal(decoded.limit, UInt64(512))
    assert_equal(decoded.view_version, UInt64(7))
    assert_true(Bool(decoded.filter))
    assert_equal(len(decoded.sort_keys), 2)
    assert_true(decoded.sort_keys[1].descending)
    assert_equal(len(decoded.computed), 1)
    assert_equal(decoded.computed[0].name, String("gross"))


def test_minimal_window_ticket_roundtrip() raises:
    var t = GridTicket.minimal(
        SourceLocator(IVP_SRC_PARQUET_FILE, String("/data/t.parquet")),
        UInt64(0),
        UInt64(100),
    )
    var bytes = encode_grid_ticket(t)
    var decoded = decode_grid_ticket(Span(bytes))
    assert_equal(decoded.source.kind, IVP_SRC_PARQUET_FILE)
    assert_equal(decoded.offset, UInt64(0))
    assert_equal(decoded.limit, UInt64(100))
    assert_true(not Bool(decoded.filter))
    assert_equal(len(decoded.sort_keys), 0)
    assert_equal(len(decoded.computed), 0)
    assert_equal(len(decoded.projection), 0)


# --- response envelope round-trip --------------------------------------------


def test_response_exact_count_roundtrip() raises:
    var payload = List[UInt8]()
    payload.append(UInt8(1))
    payload.append(UInt8(2))
    payload.append(UInt8(3))
    var bytes = encode_grid_response(
        UInt64(5), RowCount.exact(UInt64(6_000_000)),
        IVP_PAYLOAD_ARROW_IPC, Span(payload),
    )
    var resp = decode_grid_response(Span(bytes))
    assert_equal(resp.view_version, UInt64(5))
    assert_equal(resp.rowcount.kind, IVP_COUNT_EXACT)
    assert_equal(resp.rowcount.value, UInt64(6_000_000))
    assert_equal(resp.rowcount.error_bound, UInt64(0))
    assert_equal(resp.payload_kind, IVP_PAYLOAD_ARROW_IPC)
    assert_equal(len(resp.payload), 3)
    assert_equal(resp.payload[1], UInt8(2))


def test_response_estimated_count_roundtrip() raises:
    var payload = List[UInt8]()
    var bytes = encode_grid_response(
        UInt64(0),
        RowCount.estimated(UInt64(1_234_000), UInt64(50_000), String("refine-abc")),
        IVP_PAYLOAD_JSON, Span(payload),
    )
    var resp = decode_grid_response(Span(bytes))
    assert_equal(resp.rowcount.kind, IVP_COUNT_ESTIMATED)
    assert_equal(resp.rowcount.value, UInt64(1_234_000))
    assert_equal(resp.rowcount.error_bound, UInt64(50_000))
    assert_equal(resp.rowcount.refine_token, String("refine-abc"))
    assert_equal(resp.payload_kind, IVP_PAYLOAD_JSON)
    assert_equal(len(resp.payload), 0)


def main() raises:
    var suite = TestSuite()
    suite.test[test_roundtrip_col_ref_plain]()
    suite.test[test_roundtrip_col_ref_sides]()
    suite.test[test_roundtrip_literals]()
    suite.test[test_roundtrip_negative_and_large_ints]()
    suite.test[test_roundtrip_comparison_predicate]()
    suite.test[test_roundtrip_logical_and_of_comparisons]()
    suite.test[test_roundtrip_arithmetic]()
    suite.test[test_roundtrip_unary_ops]()
    suite.test[test_roundtrip_string_ops]()
    suite.test[test_roundtrip_alias_computed_column]()
    suite.test[test_roundtrip_deep_composite]()
    suite.test[test_ticket_roundtrip_byte_stable]()
    suite.test[test_minimal_window_ticket_roundtrip]()
    suite.test[test_response_exact_count_roundtrip]()
    suite.test[test_response_estimated_count_roundtrip]()
    suite^.run()
