# =============================================================================
# run_sql over inner equi-joins: the shapes of TPC-H Q3, Q5 and Q10
# =============================================================================
#
# Covers: run_sql over six TPC-H-typed Parquet tables (INT32 and INT64 keys
# with NULLs and unmatched keys, DECIMAL(15,2) money, DATE32): the shapes of
# Q3, Q5 (a six-table join on two keys) and Q10 as comma joins in WHERE, with a
# revenue sum by one column, and their count(*), equal an oracle computed row
# by row in the test; JOIN ... ON counts the key pairs over INT32, INT64 and
# mixed keys; the unedited Q3 text is a named LOWERING_ refusal at step lower.
#
# Six TPC-H-typed tables (customer, orders, lineitem, supplier, nation, region)
# are written here as Parquet files in several row groups and registered on an
# EngineContext. Every cell is a function of its row number. Join keys are
# INT32 (custkey, suppkey, nationkey, regionkey) and INT64 (orderkey); money is
# DECIMAL(15,2); dates are DATE32. Each key column holds NULLs, and some keys
# have no partner on the other side, so a NULL key that wrongly matched, or a
# lost row, changes an answer.
#
# The full texts of Q3, Q5 and Q10 are not served (an ORDER BY over a DECIMAL
# or DATE32 key, which the sort sink does not order). The queries here keep their FROM lists, their join
# predicates written as comma joins in WHERE, and their filters, with an
# aggregate the engine serves: a revenue sum grouped by one column.
# The expected answers are computed in this file, row by row, with nested
# loops over the generated rows, where a NULL key never equals anything (SQL
# inner-join semantics); revenue is the integer cents x cents of the same rows.
# Grouped answers are compared as a map from the group key to its revenue,
# independent of row order.
#
# What each test proves:
#   * test_q3_shape_revenue_by_order_matches_the_oracle: customer, orders and
#     lineitem under a segment filter and two date filters, grouped by the INT64
#     l_orderkey, give the oracle's group set and exact DECIMAL(38, 4) revenues.
#   * test_q5_shape_revenue_by_nation_matches_the_oracle: the six-table join,
#     with c_nationkey = s_nationkey beside s_nationkey = n_nationkey (a join
#     on two keys), r_name = 'ASIA' and a one-year date range, grouped by the
#     nation name, gives the oracle's groups and revenues.
#   * test_q10_shape_revenue_by_customer_matches_the_oracle: four tables under
#     l_returnflag = 'R' and a date range, grouped by the INT32 c_custkey, give
#     the oracle's groups and revenues.
#   * test_join_counts_without_group_by_match_the_oracle: count(*) of each of
#     the three joins equals the oracle's row count, one context running all
#     three.
#   * test_explicit_join_on_counts_key_pairs_of_each_key_type: JOIN ... ON over
#     INT32 = INT32, INT64 = INT64, INT32 = INT64 and a key with repeated,
#     NULL and unmatched values count the pairs of equal non-NULL keys.
#   * test_a_refused_tpch_text_stays_a_named_refusal: the unedited text of Q3
#     is a refusal at step `execute` that names its DECIMAL revenue sort key,
#     and the context answers a join afterwards.

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.decimal_array import Decimal128Array
from arrow.primitive_array import PrimitiveArray
from arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from arrow.string_array import StringArray
from bench_corpus.catalog import find_query
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from runtime_paths import test_tmpdir
from scalar_arithmetic.decimal_arith import I128
from sdk_exec.engine_catalog import register_parquet
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import STEP_EXECUTE, SqlOutcome, run_sql


# Day numbers (days since the epoch) of the dates the queries name.
comptime _D_1995_03_15: Int = 9204
comptime _D_1994_01_01: Int = 8766
comptime _D_1995_01_01: Int = 9131
comptime _D_1993_10_01: Int = 8674


def _w(v: Int) -> I128:
    return Scalar[DType.int64](v).cast[DType.int128]()


def _new_context() raises -> EngineContext:
    return EngineContext(EngineOptions(worker_count=3))


struct _IntCol(Movable):
    """One integer column: the values and the NULL flags (a NULL cell's value is
    unused)."""

    var v: List[Int]
    var is_null: List[Bool]

    def __init__(out self):
        self.v = List[Int]()
        self.is_null = List[Bool]()

    def add(mut self, value: Int, missing: Bool = False):
        self.v.append(value)
        self.is_null.append(missing)

    def size(self) -> Int:
        return len(self.v)


struct _StrCol(Movable):
    var v: List[String]

    def __init__(out self):
        self.v = List[String]()


struct _Tpch(Movable):
    """The six tables, one list per column."""

    var reg_key: _IntCol
    var reg_name: _StrCol
    var nat_key: _IntCol
    var nat_region: _IntCol
    var nat_name: _StrCol
    var supp_key: _IntCol
    var supp_nation: _IntCol
    var cust_key: _IntCol
    var cust_nation: _IntCol
    var cust_seg: _StrCol
    var ord_key: _IntCol
    var ord_cust: _IntCol
    var ord_date: _IntCol
    var ord_prio: _IntCol
    var li_order: _IntCol
    var li_supp: _IntCol
    var li_price: _IntCol
    var li_disc: _IntCol
    var li_ship: _IntCol
    var li_flag: _StrCol

    def __init__(out self):
        self.reg_key = _IntCol()
        self.reg_name = _StrCol()
        self.nat_key = _IntCol()
        self.nat_region = _IntCol()
        self.nat_name = _StrCol()
        self.supp_key = _IntCol()
        self.supp_nation = _IntCol()
        self.cust_key = _IntCol()
        self.cust_nation = _IntCol()
        self.cust_seg = _StrCol()
        self.ord_key = _IntCol()
        self.ord_cust = _IntCol()
        self.ord_date = _IntCol()
        self.ord_prio = _IntCol()
        self.li_order = _IntCol()
        self.li_supp = _IntCol()
        self.li_price = _IntCol()
        self.li_disc = _IntCol()
        self.li_ship = _IntCol()
        self.li_flag = _StrCol()


def _region_name(i: Int) -> String:
    if i == 0:
        return "AFRICA"
    if i == 1:
        return "AMERICA"
    if i == 2:
        return "ASIA"
    if i == 3:
        return "EUROPE"
    return "MIDDLE EAST"


def _segment(i: Int) -> String:
    if i == 0:
        return "BUILDING"
    if i == 1:
        return "AUTOMOBILE"
    if i == 2:
        return "MACHINERY"
    if i == 3:
        return "HOUSEHOLD"
    return "FURNITURE"


def _flag(i: Int) -> String:
    if i == 0:
        return "R"
    if i == 1:
        return "A"
    return "N"


def _make() -> _Tpch:
    """Every cell is a function of its row number i. Keys that reach past the
    other side's range (customer 150.., order 400.., supplier 60..) have no
    partner; every key column has NULLs at a fixed stride."""
    var t = _Tpch()
    for i in range(5):
        t.reg_key.add(i)
        t.reg_name.v.append(_region_name(i))
    for i in range(25):
        t.nat_key.add(i)
        t.nat_name.v.append("NATION_" + String(i))
        if i == 23:
            t.nat_region.add(0, True)
        elif i == 24:
            t.nat_region.add(7)
        else:
            t.nat_region.add((2 + i // 2) % 5)
    for i in range(60):
        t.supp_key.add(i, i % 13 == 12)
        t.supp_nation.add((i * 3 + i // 7) % 4, i % 17 == 16)
    for i in range(150):
        t.cust_key.add(i, i % 29 == 28)
        t.cust_nation.add((i * 5 + i // 3) % 4, i % 31 == 30)
        t.cust_seg.v.append(_segment((i // 3) % 5))
    for i in range(400):
        t.ord_key.add(i, i % 41 == 40)
        t.ord_cust.add((i * 11) % 170, i % 23 == 22)
        t.ord_date.add(8400 + (i * 13) % 1100)
        t.ord_prio.add(0)
    for i in range(1500):
        t.li_order.add((i * 7) % 440, i % 37 == 36)
        t.li_supp.add((i * 11) % 67, i % 43 == 42)
        t.li_price.add(100000 + (i * 7919) % 900000, i % 53 == 52)
        t.li_disc.add((i * 3) % 11, i % 31 == 30)
        t.li_ship.add(8400 + (i * 17) % 1100)
        t.li_flag.v.append(_flag(i % 3))
    return t^


# ---------------------------------------------------------------- the files


def _add_int(
    mut sb: SchemaBuilder,
    mut rb: RecordBatchBuilder,
    name: String,
    ref c: _IntCol,
    bits: Int,
    is_date: Bool = False,
) raises:
    """Add the column as INT32 / INT64 (`bits`), or as DATE32 when `is_date`."""
    var n = c.size()
    if bits == 64:
        var wide = PrimitiveArray[DType.int64].allocate_nullable(n)
        for i in range(n):
            wide.set(i, Int64(c.v[i]))
        for i in range(n):
            if c.is_null[i]:
                wide._set_null(i)
        sb.add_field(Field(name, ArrowType.INT64, True))
        rb.add_column(Column.from_primitive[DType.int64](wide^))
        return
    var a = PrimitiveArray[DType.int32].allocate_nullable(n)
    for i in range(n):
        a.set(i, Int32(c.v[i]))
    for i in range(n):
        if c.is_null[i]:
            a._set_null(i)
    if is_date:
        sb.add_field(Field(name, ArrowType.DATE32, True))
        rb.add_column(
            Column.from_primitive_with_arrow_type[DType.int32](
                a^, ArrowType.DATE32
            )
        )
    else:
        sb.add_field(Field(name, ArrowType.INT32, True))
        rb.add_column(Column.from_primitive[DType.int32](a^))


def _add_money(
    mut sb: SchemaBuilder,
    mut rb: RecordBatchBuilder,
    name: String,
    ref c: _IntCol,
) raises:
    """Add the column as DECIMAL(15,2); the values are cents."""
    var n = c.size()
    var a = Decimal128Array.allocate_nullable(n, 15, 2)
    for i in range(n):
        if c.is_null[i]:
            a.set_null(i)
        else:
            a.set_i128(i, _w(c.v[i]))
    sb.add_field(Field.decimal128(name, 15, 2, True))
    rb.add_column(Column.from_decimal128(a^))


def _add_str(
    mut sb: SchemaBuilder,
    mut rb: RecordBatchBuilder,
    name: String,
    ref c: _StrCol,
) raises:
    sb.add_field(Field(name, ArrowType.STRING, False))
    rb.add_column(Column.from_string(StringArray.from_strings(c.v.copy())))


def _publish(
    mut ctx: EngineContext,
    prefix: String,
    table: String,
    mut sb: SchemaBuilder,
    mut rb: RecordBatchBuilder,
    rows_per_group: Int,
) raises:
    var batch = rb.build(sb.build())
    var path = test_tmpdir() + "/" + prefix + "_" + table + ".parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        batch, max_rows_per_rg=rows_per_group
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    register_parquet(ctx, table, path)


def _register_all(mut ctx: EngineContext, ref t: _Tpch, prefix: String) raises:
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    _add_int(sb, rb, "r_regionkey", t.reg_key, 32)
    _add_str(sb, rb, "r_name", t.reg_name)
    _publish(ctx, prefix, "region", sb, rb, 2)

    sb = SchemaBuilder()
    rb = RecordBatchBuilder()
    _add_int(sb, rb, "n_nationkey", t.nat_key, 32)
    _add_str(sb, rb, "n_name", t.nat_name)
    _add_int(sb, rb, "n_regionkey", t.nat_region, 32)
    _publish(ctx, prefix, "nation", sb, rb, 8)

    sb = SchemaBuilder()
    rb = RecordBatchBuilder()
    _add_int(sb, rb, "s_suppkey", t.supp_key, 32)
    _add_int(sb, rb, "s_nationkey", t.supp_nation, 32)
    _publish(ctx, prefix, "supplier", sb, rb, 20)

    sb = SchemaBuilder()
    rb = RecordBatchBuilder()
    _add_int(sb, rb, "c_custkey", t.cust_key, 32)
    _add_int(sb, rb, "c_nationkey", t.cust_nation, 32)
    _add_str(sb, rb, "c_mktsegment", t.cust_seg)
    _publish(ctx, prefix, "customer", sb, rb, 40)

    sb = SchemaBuilder()
    rb = RecordBatchBuilder()
    _add_int(sb, rb, "o_orderkey", t.ord_key, 64)
    _add_int(sb, rb, "o_custkey", t.ord_cust, 32)
    _add_int(sb, rb, "o_orderdate", t.ord_date, 32, True)
    _add_int(sb, rb, "o_shippriority", t.ord_prio, 32)
    _publish(ctx, prefix, "orders", sb, rb, 64)

    sb = SchemaBuilder()
    rb = RecordBatchBuilder()
    _add_int(sb, rb, "l_orderkey", t.li_order, 64)
    _add_int(sb, rb, "l_suppkey", t.li_supp, 32)
    _add_money(sb, rb, "l_extendedprice", t.li_price)
    _add_money(sb, rb, "l_discount", t.li_disc)
    _add_int(sb, rb, "l_shipdate", t.li_ship, 32, True)
    _add_str(sb, rb, "l_returnflag", t.li_flag)
    _publish(ctx, prefix, "lineitem", sb, rb, 100)


# --------------------------------------------------------------- the oracles


struct _Groups(Movable):
    """The oracle's answer: joined rows counted, and per group key the revenue
    in units of 10^-4 and whether any row had a non-NULL product."""

    var rows: Int
    var keys: List[String]
    var sums: List[Int]
    var has: List[Bool]

    def __init__(out self):
        self.rows = 0
        self.keys = List[String]()
        self.sums = List[Int]()
        self.has = List[Bool]()

    def index_of(self, key: String) -> Int:
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                return i
        return -1

    def add(mut self, key: String, term: Int, has_term: Bool):
        self.rows += 1
        var idx = self.index_of(key)
        if idx < 0:
            self.keys.append(key.copy())
            self.sums.append(0)
            self.has.append(False)
            idx = len(self.keys) - 1
        if has_term:
            self.sums[idx] += term
            self.has[idx] = True


def _eq(ref a: _IntCol, i: Int, ref b: _IntCol, j: Int) -> Bool:
    """SQL equality of two key cells: a NULL equals nothing."""
    return (not a.is_null[i]) and (not b.is_null[j]) and a.v[i] == b.v[j]


def _has_revenue(ref t: _Tpch, li: Int) -> Bool:
    return (not t.li_price.is_null[li]) and (not t.li_disc.is_null[li])


def _revenue(ref t: _Tpch, li: Int) -> Int:
    """l_extendedprice * (1 - l_discount) in units of 10^-4: cents x (100 -
    discount cents)."""
    return t.li_price.v[li] * (100 - t.li_disc.v[li])


def _oracle_q3(ref t: _Tpch) -> _Groups:
    var g = _Groups()
    for li in range(t.li_order.size()):
        if t.li_ship.v[li] <= _D_1995_03_15:
            continue
        for o in range(t.ord_key.size()):
            if not _eq(t.li_order, li, t.ord_key, o):
                continue
            if t.ord_date.v[o] >= _D_1995_03_15:
                continue
            for c in range(t.cust_key.size()):
                if not _eq(t.ord_cust, o, t.cust_key, c):
                    continue
                if t.cust_seg.v[c] != "BUILDING":
                    continue
                g.add(
                    String(t.li_order.v[li]),
                    _revenue(t, li),
                    _has_revenue(t, li),
                )
    return g^


def _oracle_q5(ref t: _Tpch) -> _Groups:
    var g = _Groups()
    for li in range(t.li_order.size()):
        for o in range(t.ord_key.size()):
            if not _eq(t.li_order, li, t.ord_key, o):
                continue
            if (
                t.ord_date.v[o] < _D_1994_01_01
                or t.ord_date.v[o] >= _D_1995_01_01
            ):
                continue
            for c in range(t.cust_key.size()):
                if not _eq(t.ord_cust, o, t.cust_key, c):
                    continue
                for s in range(t.supp_key.size()):
                    if not _eq(t.li_supp, li, t.supp_key, s):
                        continue
                    if not _eq(t.cust_nation, c, t.supp_nation, s):
                        continue
                    for n in range(t.nat_key.size()):
                        if not _eq(t.supp_nation, s, t.nat_key, n):
                            continue
                        for r in range(t.reg_key.size()):
                            if not _eq(t.nat_region, n, t.reg_key, r):
                                continue
                            if t.reg_name.v[r] != "ASIA":
                                continue
                            g.add(
                                t.nat_name.v[n].copy(),
                                _revenue(t, li),
                                _has_revenue(t, li),
                            )
    return g^


def _oracle_q10(ref t: _Tpch) -> _Groups:
    var g = _Groups()
    for li in range(t.li_order.size()):
        if t.li_flag.v[li] != "R":
            continue
        for o in range(t.ord_key.size()):
            if not _eq(t.li_order, li, t.ord_key, o):
                continue
            if (
                t.ord_date.v[o] < _D_1993_10_01
                or t.ord_date.v[o] >= _D_1994_01_01
            ):
                continue
            for c in range(t.cust_key.size()):
                if not _eq(t.ord_cust, o, t.cust_key, c):
                    continue
                for n in range(t.nat_key.size()):
                    if not _eq(t.cust_nation, c, t.nat_key, n):
                        continue
                    g.add(
                        String(t.cust_key.v[c]),
                        _revenue(t, li),
                        _has_revenue(t, li),
                    )
    return g^


def _pairs(ref a: _IntCol, ref b: _IntCol) -> Int:
    """The number of (row of a, row of b) pairs with equal non-NULL keys."""
    var n = 0
    for i in range(a.size()):
        for j in range(b.size()):
            if _eq(a, i, b, j):
                n += 1
    return n


# ------------------------------------------------------------------- queries


def _q3_from_where() -> String:
    return (
        " from customer, orders, lineitem where c_mktsegment = 'BUILDING'"
        " and c_custkey = o_custkey and l_orderkey = o_orderkey"
        " and o_orderdate < date '1995-03-15'"
        " and l_shipdate > date '1995-03-15'"
    )


def _q5_from_where() -> String:
    return (
        " from customer, orders, lineitem, supplier, nation, region"
        " where c_custkey = o_custkey and l_orderkey = o_orderkey"
        " and l_suppkey = s_suppkey and c_nationkey = s_nationkey"
        " and s_nationkey = n_nationkey and n_regionkey = r_regionkey"
        " and r_name = 'ASIA' and o_orderdate >= date '1994-01-01'"
        " and o_orderdate < date '1994-01-01' + interval '1' year"
    )


def _q10_from_where() -> String:
    return (
        " from customer, orders, lineitem, nation"
        " where c_custkey = o_custkey and l_orderkey = o_orderkey"
        " and o_orderdate >= date '1993-10-01'"
        " and o_orderdate < date '1994-01-01'"
        " and l_returnflag = 'R' and c_nationkey = n_nationkey"
    )


def _revenue_by(key: String, from_where: String) -> String:
    return (
        "select "
        + key
        + ", sum(l_extendedprice * (1 - l_discount)) as revenue"
        + from_where
        + " group by "
        + key
    )


def _count_of(from_where: String) -> String:
    return "select count(*)" + from_where


# ------------------------------------------------------------------ checkers


def _expect_ok(ref out: SqlOutcome, text: String) raises:
    if out.refusal:
        assert_true(
            False,
            "refused at "
            + out.refusal.value().step
            + ": "
            + out.refusal.value().reason
            + " -- "
            + text,
        )


def _key_text(ref batch: RecordBatch, row: Int) raises -> String:
    var ty = batch.schema.field_arrow_type(0)
    if ty == ArrowType.INT64:
        return String(Int(batch.column_at(0).as_primitive[DType.int64]().get(row)))
    if ty == ArrowType.INT32:
        return String(Int(batch.column_at(0).as_primitive[DType.int32]().get(row)))
    if ty == ArrowType.STRING:
        return batch.column_at(0).as_string().get(row)
    raise Error("the group key column has an unexpected type")


def _expect_groups(
    mut ctx: EngineContext, text: String, key_name: String, ref want: _Groups
) raises:
    """The answer of `text` (a key column, then `revenue`) holds exactly the
    oracle's groups, each once, with the oracle's DECIMAL(38, 4) revenue."""
    var out = run_sql(ctx, text)
    _expect_ok(out, text)
    var hit = List[Bool]()
    for _ in range(len(want.keys)):
        hit.append(False)
    var total = 0
    for b in range(len(out.batches)):
        ref batch = out.batches[b]
        assert_equal(batch.num_columns(), 2)
        assert_equal(batch.schema.field_name(0), key_name)
        assert_equal(batch.schema.field_name(1), "revenue")
        ref rev = batch.column_at(1)
        assert_equal(rev.decimal_precision(), 38)
        assert_equal(rev.decimal_scale(), 4)
        for r in range(batch.num_rows()):
            var key = _key_text(batch, r)
            var idx = want.index_of(key)
            assert_true(idx >= 0, "a group the oracle does not have: " + key)
            assert_false(hit[idx], "the group appears twice: " + key)
            hit[idx] = True
            if want.has[idx]:
                assert_false(rev.is_null_at(r), "revenue is NULL for " + key)
                assert_true(
                    rev.as_decimal128().get_i128(r) == _w(want.sums[idx]),
                    "revenue differs from the oracle for group " + key,
                )
            else:
                assert_true(
                    rev.is_null_at(r), "revenue is not NULL for " + key
                )
            total += 1
    assert_equal(total, len(want.keys))


def _expect_count(mut ctx: EngineContext, text: String, want: Int) raises:
    var out = run_sql(ctx, text)
    _expect_ok(out, text)
    assert_equal(len(out.batches), 1)
    assert_equal(out.batches[0].num_rows(), 1)
    assert_equal(
        Int(out.batches[0].column_at(0).as_primitive[DType.int64]().get(0)),
        want,
    )


# --------------------------------------------------------------------- tests


def test_q3_shape_revenue_by_order_matches_the_oracle() raises:
    var t = _make()
    var want = _oracle_q3(t)
    assert_true(len(want.keys) > 5, "the fixture leaves Q3's shape too small")
    var ctx = _new_context()
    _register_all(ctx, t, "sql_joins_q3")
    _expect_groups(
        ctx, _revenue_by("l_orderkey", _q3_from_where()), "l_orderkey", want
    )


def test_q5_shape_revenue_by_nation_matches_the_oracle() raises:
    var t = _make()
    var want = _oracle_q5(t)
    assert_true(len(want.keys) >= 2, "the fixture leaves Q5's shape too small")
    var ctx = _new_context()
    _register_all(ctx, t, "sql_joins_q5")
    _expect_groups(ctx, _revenue_by("n_name", _q5_from_where()), "n_name", want)


def test_q10_shape_revenue_by_customer_matches_the_oracle() raises:
    var t = _make()
    var want = _oracle_q10(t)
    assert_true(len(want.keys) > 5, "the fixture leaves Q10's shape too small")
    var ctx = _new_context()
    _register_all(ctx, t, "sql_joins_q10")
    _expect_groups(
        ctx, _revenue_by("c_custkey", _q10_from_where()), "c_custkey", want
    )


def test_join_counts_without_group_by_match_the_oracle() raises:
    var t = _make()
    var q3 = _oracle_q3(t)
    var q5 = _oracle_q5(t)
    var q10 = _oracle_q10(t)
    assert_true(q3.rows > 0 and q5.rows > 0 and q10.rows > 0)
    var ctx = _new_context()
    _register_all(ctx, t, "sql_joins_counts")
    _expect_count(ctx, _count_of(_q3_from_where()), q3.rows)
    _expect_count(ctx, _count_of(_q5_from_where()), q5.rows)
    _expect_count(ctx, _count_of(_q10_from_where()), q10.rows)


def test_explicit_join_on_counts_key_pairs_of_each_key_type() raises:
    var t = _make()
    var ctx = _new_context()
    _register_all(ctx, t, "sql_joins_on")
    # INT32 = INT32: orders per customer.
    var cust_orders = _pairs(t.ord_cust, t.cust_key)
    assert_true(cust_orders > 0)
    _expect_count(
        ctx,
        "select count(*) from orders join customer on o_custkey = c_custkey",
        cust_orders,
    )
    # INT64 = INT64: a key repeated on the probe side, NULL on both sides, and
    # lineitem keys past the last order.
    var li_orders = _pairs(t.li_order, t.ord_key)
    assert_true(li_orders > 0)
    _expect_count(
        ctx,
        "select count(*) from lineitem inner join orders on l_orderkey ="
        " o_orderkey",
        li_orders,
    )
    # INT32 = INT32 with the build side shorter than the probe side's key range.
    var li_supp = _pairs(t.li_supp, t.supp_key)
    assert_true(li_supp > 0)
    _expect_count(
        ctx,
        "select count(*) from lineitem join supplier on l_suppkey = s_suppkey",
        li_supp,
    )
    # INT32 against INT64.
    var mixed = _pairs(t.cust_key, t.ord_key)
    assert_true(mixed > 0)
    _expect_count(
        ctx,
        "select count(*) from customer join orders on c_custkey = o_orderkey",
        mixed,
    )


def test_a_refused_tpch_text_stays_a_named_refusal() raises:
    var t = _make()
    var q3 = _oracle_q3(t)
    var ctx = _new_context()
    _register_all(ctx, t, "sql_joins_refused")
    var out = run_sql(ctx, find_query(String("tpch/q3")).text)
    assert_false(out.ok(), "the unedited Q3 is expected to stay refused")
    # Its ORDER BY ... LIMIT is cut as a top-n, whose first key, the
    # DECIMAL(38, 4) revenue, is a type the sort sink does not order.
    assert_equal(out.refusal.value().step, String(STEP_EXECUTE))
    var reason = out.refusal.value().reason
    assert_true(
        "sorts by 'revenue', of unsupported sort key type" in reason,
        "reason '" + reason + "' does not name the revenue sort key",
    )
    assert_equal(len(out.batches), 0)
    # The refusal leaves the context answering joins.
    _expect_count(ctx, _count_of(_q3_from_where()), q3.rows)


def main() raises:
    var suite = TestSuite()
    suite.test[test_q3_shape_revenue_by_order_matches_the_oracle]()
    suite.test[test_q5_shape_revenue_by_nation_matches_the_oracle]()
    suite.test[test_q10_shape_revenue_by_customer_matches_the_oracle]()
    suite.test[test_join_counts_without_group_by_match_the_oracle]()
    suite.test[test_explicit_join_on_counts_key_pairs_of_each_key_type]()
    suite.test[test_a_refused_tpch_text_stays_a_named_refusal]()
    suite^.run()
