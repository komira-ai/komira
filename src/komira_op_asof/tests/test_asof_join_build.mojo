# =============================================================================
# test_asof_join_build -- `AsofJoinBuildTable[KB, TempK, *Payload]` and its
# free functions (komira_op_asof.asof_join_build)
# =============================================================================
#
# One struct over the whole shape matrix:
#   - no keys (binary lower bound)   x payload {0,1,2,3,4} x {I64,I32} temporal
#   - one key (linear partition walk) x payload {0,1,3,4}
#   - two keys (composite partition)  x payload {0,1,2,3,4} x {I64,I32} temporal
#
# Payloads go through the Float64 channel (`asof_build_append_N_f64`,
# `payload_read_f64[p]`) with small integers, which it carries exactly.
#
# The key model: every value of the temporal type is a key. The type's
# minimum is a key like any other (`Int64.MIN` <= 10, so a probe of it finds
# the first row); a table that treated the minimum as an "empty" sentinel
# turns the two `*_type_minimum_is_a_key` assertions red. Float keys follow
# `sort_key_lt` (test_float_keys_follow_the_sort_order).
# =============================================================================

from std.math import nan

from komira_op_asof.asof_join_build import (
    AsofJoinBuildTable,
    AsofKeyBundle0,
    AsofKeyBundle1,
    AsofKeyBundle2,
    PayloadSlot,
    PayloadBlock,
    payload_slot,
    asof_build_append_0_f64,
    asof_build_append_1_f64,
    asof_build_append_2_f64,
    asof_probe_forward_0,
    asof_probe_forward_1,
    asof_probe_forward_2,
)


# =============================================================================
# 0-by-key family — binary lower-bound probe
# =============================================================================


def test_0x_i64_p3_basic() raises:
    """0-by-key + I64 temporal + 3-I64 payload (the stage state's
    shape). Forward-search binary semantics + payload round-trip."""
    var t = AsofJoinBuildTable[
        AsofKeyBundle0,
        DType.int64,
        PayloadSlot[DType.int64],
        PayloadSlot[DType.int64],
        PayloadSlot[DType.int64],
    ](
        PayloadBlock[
            PayloadSlot[DType.int64],
            PayloadSlot[DType.int64],
            PayloadSlot[DType.int64],
        ](
            payload_slot[DType.int64](8),
            payload_slot[DType.int64](8),
            payload_slot[DType.int64](8),
        ),
        8,
    )
    # ASC-sorted by temporal: 10, 20, 30
    var pv0 = List[Float64]()
    pv0.append(100.0)
    pv0.append(200.0)
    pv0.append(300.0)
    asof_build_append_0_f64(t, Int64(10), pv0)
    var pv1 = List[Float64]()
    pv1.append(101.0)
    pv1.append(201.0)
    pv1.append(301.0)
    asof_build_append_0_f64(t, Int64(20), pv1)
    var pv2 = List[Float64]()
    pv2.append(102.0)
    pv2.append(202.0)
    pv2.append(302.0)
    asof_build_append_0_f64(t, Int64(30), pv2)

    if t.n_rows() != 3:
        raise Error("0x_i64_p3 n_rows != 3")
    # probe 5 -> smallest >= 5 -> slot 0
    if asof_probe_forward_0(t, Int64(5)) != 0:
        raise Error("0x probe 5 -> slot 0")
    # probe 20 (equality) -> slot 1
    if asof_probe_forward_0(t, Int64(20)) != 1:
        raise Error("0x probe 20 -> slot 1")
    # probe 25 -> slot 2
    if asof_probe_forward_0(t, Int64(25)) != 2:
        raise Error("0x probe 25 -> slot 2")
    # probe 35 -> miss
    if asof_probe_forward_0(t, Int64(35)) != -1:
        raise Error("0x probe 35 -> miss")
    # the type minimum is a key: Int64.MIN <= 10 -> slot 0
    if asof_probe_forward_0(t, Int64.MIN) != 0:
        raise Error("0x_type_minimum_is_a_key: Int64.MIN -> slot 0")
    # payload round-trip at slot 0
    if Int(t.payload_read_f64[0](0)) != 100:
        raise Error("0x payload[0]@0 != 100")
    if Int(t.payload_read_f64[2](2)) != 302:
        raise Error("0x payload[2]@2 != 302")
    if Int(t.temp_at(1)) != 20:
        raise Error("0x temp_at(1) != 20")
    print("test_0x_i64_p3_basic PASS")


def test_0x_i64_p0_keyonly() raises:
    """0-by-key + 0-payload (key-only presence). Binary probe only."""
    var t = AsofJoinBuildTable[AsofKeyBundle0, DType.int64](
        PayloadBlock[](), 8
    )
    var empty = List[Float64]()
    asof_build_append_0_f64(t, Int64(10), empty)
    asof_build_append_0_f64(t, Int64(20), empty)
    asof_build_append_0_f64(t, Int64(30), empty)
    if t.n_rows() != 3:
        raise Error("0x_p0 n_rows != 3")
    if asof_probe_forward_0(t, Int64(5)) != 0:
        raise Error("0x_p0 probe 5 -> slot 0")
    if asof_probe_forward_0(t, Int64(25)) != 2:
        raise Error("0x_p0 probe 25 -> slot 2")
    if asof_probe_forward_0(t, Int64(35)) != -1:
        raise Error("0x_p0 probe 35 -> miss")
    if Int(t.temp_at(1)) != 20:
        raise Error("0x_p0 temp_at(1) != 20")
    print("test_0x_i64_p0_keyonly PASS")


def test_0x_i64_p1() raises:
    """0-by-key + 1-payload."""
    var t = AsofJoinBuildTable[
        AsofKeyBundle0, DType.int64, PayloadSlot[DType.int64]
    ](
        PayloadBlock[PayloadSlot[DType.int64]](payload_slot[DType.int64](8)),
        8,
    )
    var a = List[Float64]()
    a.append(100.0)
    asof_build_append_0_f64(t, Int64(10), a)
    var b = List[Float64]()
    b.append(200.0)
    asof_build_append_0_f64(t, Int64(20), b)
    var s = asof_probe_forward_0(t, Int64(15))
    if s != 1:
        raise Error("0x_p1 probe 15 -> slot 1")
    if Int(t.payload_read_f64[0](s)) != 200:
        raise Error("0x_p1 payload != 200")
    print("test_0x_i64_p1 PASS")


def test_0x_i64_p2() raises:
    """0-by-key + 2-payload."""
    var t = AsofJoinBuildTable[
        AsofKeyBundle0,
        DType.int64,
        PayloadSlot[DType.int64],
        PayloadSlot[DType.int64],
    ](
        PayloadBlock[
            PayloadSlot[DType.int64], PayloadSlot[DType.int64]
        ](payload_slot[DType.int64](8), payload_slot[DType.int64](8)),
        8,
    )
    var a = List[Float64]()
    a.append(100.0)
    a.append(1000.0)
    asof_build_append_0_f64(t, Int64(10), a)
    var b = List[Float64]()
    b.append(200.0)
    b.append(2000.0)
    asof_build_append_0_f64(t, Int64(20), b)
    var s = asof_probe_forward_0(t, Int64(20))
    if s != 1:
        raise Error("0x_p2 probe 20 -> slot 1")
    if Int(t.payload_read_f64[0](s)) != 200 or Int(t.payload_read_f64[1](s)) != 2000:
        raise Error("0x_p2 payload mismatch")
    print("test_0x_i64_p2 PASS")


def test_0x_i32_p4() raises:
    """0-by-key + I32 temporal + 4-payload. Exercises the parametric TempK
    narrowing (Date32 / Timestamp[s]) + 4 payload columns; Int32.MIN is a key."""
    var t = AsofJoinBuildTable[
        AsofKeyBundle0,
        DType.int32,
        PayloadSlot[DType.int64],
        PayloadSlot[DType.int64],
        PayloadSlot[DType.int64],
        PayloadSlot[DType.int64],
    ](
        PayloadBlock[
            PayloadSlot[DType.int64],
            PayloadSlot[DType.int64],
            PayloadSlot[DType.int64],
            PayloadSlot[DType.int64],
        ](
            payload_slot[DType.int64](8),
            payload_slot[DType.int64](8),
            payload_slot[DType.int64](8),
            payload_slot[DType.int64](8),
        ),
        8,
    )
    var a = List[Float64]()
    a.append(1.0)
    a.append(2.0)
    a.append(3.0)
    a.append(4.0)
    asof_build_append_0_f64(t, Int32(10), a)
    var b = List[Float64]()
    b.append(11.0)
    b.append(12.0)
    b.append(13.0)
    b.append(14.0)
    asof_build_append_0_f64(t, Int32(20), b)
    var c = List[Float64]()
    c.append(21.0)
    c.append(22.0)
    c.append(23.0)
    c.append(24.0)
    asof_build_append_0_f64(t, Int32(30), c)
    # probe 21 -> smallest >= 21 -> slot 2 (temp 30)
    var s = asof_probe_forward_0(t, Int32(21))
    if s != 2:
        raise Error("0x_i32_p4 probe 21 -> slot 2")
    if Int(t.payload_read_f64[0](s)) != 21 or Int(t.payload_read_f64[3](s)) != 24:
        raise Error("0x_i32_p4 payload mismatch")
    # the type minimum is a key: Int32.MIN <= 10 -> slot 0
    if asof_probe_forward_0(t, Int32.MIN) != 0:
        raise Error("0x_i32_p4_type_minimum_is_a_key: Int32.MIN -> slot 0")
    print("test_0x_i32_p4 PASS")


# =============================================================================
# 1-by-key family — linear partition probe
# =============================================================================


def test_1x_i64_p3_partition() raises:
    """1-by-key partitioned asof — probe matches partition_key AND forward-
    searches temporal within partition."""
    var t = AsofJoinBuildTable[
        AsofKeyBundle1[DType.int64],
        DType.int64,
        PayloadSlot[DType.int64],
        PayloadSlot[DType.int64],
        PayloadSlot[DType.int64],
    ](
        PayloadBlock[
            PayloadSlot[DType.int64],
            PayloadSlot[DType.int64],
            PayloadSlot[DType.int64],
        ](
            payload_slot[DType.int64](8),
            payload_slot[DType.int64](8),
            payload_slot[DType.int64](8),
        ),
        8,
    )
    # partition 1: temp 10, 30 ; partition 2: temp 20
    var a = List[Float64]()
    a.append(100.0)
    a.append(0.0)
    a.append(0.0)
    asof_build_append_1_f64(t, Int64(1), Int64(10), a)
    var b = List[Float64]()
    b.append(300.0)
    b.append(0.0)
    b.append(0.0)
    asof_build_append_1_f64(t, Int64(1), Int64(30), b)
    var c = List[Float64]()
    c.append(200.0)
    c.append(0.0)
    c.append(0.0)
    asof_build_append_1_f64(t, Int64(2), Int64(20), c)

    # partition 1, probe 5 -> slot 0 (temp 10)
    if asof_probe_forward_1(t, Int64(1), Int64(5)) != 0:
        raise Error("1x p1 probe 5 -> slot 0")
    # partition 1, probe 20 -> slot 1 (temp 30 in p1, NOT p2's temp 20)
    if asof_probe_forward_1(t, Int64(1), Int64(20)) != 1:
        raise Error("1x p1 probe 20 -> slot 1")
    # partition 2, probe 15 -> slot 2 (temp 20)
    if asof_probe_forward_1(t, Int64(2), Int64(15)) != 2:
        raise Error("1x p2 probe 15 -> slot 2")
    # missing partition -> -1
    if asof_probe_forward_1(t, Int64(99), Int64(10)) != -1:
        raise Error("1x p99 -> miss")
    if Int(t.payload_read_f64[0](1)) != 300:
        raise Error("1x payload@1 != 300")
    print("test_1x_i64_p3_partition PASS")


def test_1x_i64_p0() raises:
    """1-by-key + 0-payload."""
    var t = AsofJoinBuildTable[AsofKeyBundle1[DType.int64], DType.int64](
        PayloadBlock[](), 8
    )
    var empty = List[Float64]()
    asof_build_append_1_f64(t, Int64(1), Int64(10), empty)
    asof_build_append_1_f64(t, Int64(1), Int64(30), empty)
    asof_build_append_1_f64(t, Int64(2), Int64(20), empty)
    if asof_probe_forward_1(t, Int64(1), Int64(20)) != 1:
        raise Error("1x_p0 p1 probe 20 -> slot 1")
    if asof_probe_forward_1(t, Int64(2), Int64(15)) != 2:
        raise Error("1x_p0 p2 probe 15 -> slot 2")
    if asof_probe_forward_1(t, Int64(99), Int64(1)) != -1:
        raise Error("1x_p0 p99 -> miss")
    print("test_1x_i64_p0 PASS")


def test_1x_i32_p1() raises:
    """1-by-key + 1-payload + I32 temporal."""
    var t = AsofJoinBuildTable[
        AsofKeyBundle1[DType.int64], DType.int32, PayloadSlot[DType.int64]
    ](
        PayloadBlock[PayloadSlot[DType.int64]](payload_slot[DType.int64](8)),
        8,
    )
    var a = List[Float64]()
    a.append(1.0)
    asof_build_append_1_f64(t, Int64(7), Int32(10), a)
    var b = List[Float64]()
    b.append(3.0)
    asof_build_append_1_f64(t, Int64(7), Int32(40), b)
    var s = asof_probe_forward_1(t, Int64(7), Int32(11))
    if s != 1:
        raise Error("1x_i32_p1 probe 11 -> slot 1 (temp 40)")
    if Int(t.payload_read_f64[0](s)) != 3:
        raise Error("1x_i32_p1 payload != 3")
    print("test_1x_i32_p1 PASS")


# =============================================================================
# 2-by-key family — composite partition probe
# =============================================================================


def test_2x_i64_p0_composite() raises:
    """2-by-key + 0-payload. Probe must match BOTH partition keys."""
    var t = AsofJoinBuildTable[
        AsofKeyBundle2[DType.int64, DType.int64], DType.int64
    ](PayloadBlock[](), 8)
    var empty = List[Float64]()
    # (1,1): temp 10, 30 ; (1,2): temp 20
    asof_build_append_2_f64(t, Int64(1), Int64(1), Int64(10), empty)
    asof_build_append_2_f64(t, Int64(1), Int64(1), Int64(30), empty)
    asof_build_append_2_f64(t, Int64(1), Int64(2), Int64(20), empty)
    # (1,1) probe 15 -> slot 1 (temp 30) NOT (1,2)'s temp 20
    if asof_probe_forward_2(t, Int64(1), Int64(1), Int64(15)) != 1:
        raise Error("2x (1,1) probe 15 -> slot 1")
    # (1,2) probe 5 -> slot 2 (temp 20)
    if asof_probe_forward_2(t, Int64(1), Int64(2), Int64(5)) != 2:
        raise Error("2x (1,2) probe 5 -> slot 2")
    # (2,2) no rows -> miss
    if asof_probe_forward_2(t, Int64(2), Int64(2), Int64(1)) != -1:
        raise Error("2x (2,2) -> miss")
    # partial-match (1,99) -> miss on k1
    if asof_probe_forward_2(t, Int64(1), Int64(99), Int64(1)) != -1:
        raise Error("2x (1,99) -> miss on k1")
    print("test_2x_i64_p0_composite PASS")


def test_2x_i64_p2_composite() raises:
    """2-by-key + 2-payload."""
    var t = AsofJoinBuildTable[
        AsofKeyBundle2[DType.int64, DType.int64],
        DType.int64,
        PayloadSlot[DType.int64],
        PayloadSlot[DType.int64],
    ](
        PayloadBlock[
            PayloadSlot[DType.int64], PayloadSlot[DType.int64]
        ](payload_slot[DType.int64](8), payload_slot[DType.int64](8)),
        8,
    )
    var a = List[Float64]()
    a.append(1.0)
    a.append(2.0)
    asof_build_append_2_f64(t, Int64(9), Int64(8), Int64(10), a)
    var b = List[Float64]()
    b.append(3.0)
    b.append(4.0)
    asof_build_append_2_f64(t, Int64(9), Int64(8), Int64(40), b)
    var s = asof_probe_forward_2(t, Int64(9), Int64(8), Int64(40))
    if s != 1:
        raise Error("2x_p2 probe 40 (equality) -> slot 1")
    if Int(t.payload_read_f64[0](s)) != 3 or Int(t.payload_read_f64[1](s)) != 4:
        raise Error("2x_p2 payload mismatch")
    print("test_2x_i64_p2_composite PASS")


def test_2x_i32_p3_composite() raises:
    """2-by-key + 3-payload + I32 temporal."""
    var t = AsofJoinBuildTable[
        AsofKeyBundle2[DType.int64, DType.int64],
        DType.int32,
        PayloadSlot[DType.int64],
        PayloadSlot[DType.int64],
        PayloadSlot[DType.int64],
    ](
        PayloadBlock[
            PayloadSlot[DType.int64],
            PayloadSlot[DType.int64],
            PayloadSlot[DType.int64],
        ](
            payload_slot[DType.int64](8),
            payload_slot[DType.int64](8),
            payload_slot[DType.int64](8),
        ),
        8,
    )
    var a = List[Float64]()
    a.append(1.0)
    a.append(2.0)
    a.append(3.0)
    asof_build_append_2_f64(t, Int64(1), Int64(2), Int32(10), a)
    var b = List[Float64]()
    b.append(4.0)
    b.append(5.0)
    b.append(6.0)
    asof_build_append_2_f64(t, Int64(1), Int64(2), Int32(30), b)
    var s = asof_probe_forward_2(t, Int64(1), Int64(2), Int32(25))
    if s != 1:
        raise Error("2x_i32_p3 probe 25 -> slot 1 (temp 30)")
    if Int(t.payload_read_f64[0](s)) != 4 or Int(t.payload_read_f64[2](s)) != 6:
        raise Error("2x_i32_p3 payload mismatch")
    print("test_2x_i32_p3_composite PASS")


def test_2x_i64_p4_composite() raises:
    """2-by-key + 4-payload (widest variant) + empty-probe miss."""
    var t = AsofJoinBuildTable[
        AsofKeyBundle2[DType.int64, DType.int64],
        DType.int64,
        PayloadSlot[DType.int64],
        PayloadSlot[DType.int64],
        PayloadSlot[DType.int64],
        PayloadSlot[DType.int64],
    ](
        PayloadBlock[
            PayloadSlot[DType.int64],
            PayloadSlot[DType.int64],
            PayloadSlot[DType.int64],
            PayloadSlot[DType.int64],
        ](
            payload_slot[DType.int64](8),
            payload_slot[DType.int64](8),
            payload_slot[DType.int64](8),
            payload_slot[DType.int64](8),
        ),
        8,
    )
    var a = List[Float64]()
    a.append(1.0)
    a.append(2.0)
    a.append(3.0)
    a.append(4.0)
    asof_build_append_2_f64(t, Int64(3), Int64(4), Int64(10), a)
    var b = List[Float64]()
    b.append(5.0)
    b.append(6.0)
    b.append(7.0)
    b.append(8.0)
    asof_build_append_2_f64(t, Int64(3), Int64(4), Int64(50), b)
    var s = asof_probe_forward_2(t, Int64(3), Int64(4), Int64(11))
    if s != 1:
        raise Error("2x_p4 probe 11 -> slot 1 (temp 50)")
    if Int(t.payload_read_f64[0](s)) != 5 or Int(t.payload_read_f64[3](s)) != 8:
        raise Error("2x_p4 payload mismatch")
    # empty-table probe on a fresh instance -> miss
    var empty_t = AsofJoinBuildTable[
        AsofKeyBundle2[DType.int64, DType.int64], DType.int64
    ](PayloadBlock[](), 8)
    if asof_probe_forward_2(empty_t, Int64(0), Int64(0), Int64(0)) != -1:
        raise Error("2x_p4 empty probe -> miss")
    print("test_2x_i64_p4_composite PASS")


# =============================================================================
# Float keys follow the sort order (DuckDB's)
# =============================================================================


def test_float_keys_follow_the_sort_order() raises:
    """FLOAT64 temporal keys [1.0, 2.0, NaN] (ascending in `sort_key_lt`
    order): 2.5 and NaN both find the NaN row (NaN sorts above every number
    and equals NaN). An IEEE `<` search sends the NaN probe to slot 0.

    One FLOAT64 key: a NaN probe key finds the NaN partition and -0.0 finds
    the +0.0 one. An IEEE `==` never matches NaN."""
    var t = AsofJoinBuildTable[AsofKeyBundle0, DType.float64](
        PayloadBlock[](), 8
    )
    var empty = List[Float64]()
    asof_build_append_0_f64(t, Float64(1.0), empty)
    asof_build_append_0_f64(t, Float64(2.0), empty)
    asof_build_append_0_f64(t, nan[DType.float64](), empty)
    if asof_probe_forward_0(t, Float64(2.5)) != 2:
        raise Error("float temporal: 2.5 -> the NaN row (slot 2)")
    if asof_probe_forward_0(t, nan[DType.float64]()) != 2:
        raise Error("float temporal: NaN -> the NaN row (slot 2)")
    if asof_probe_forward_0(t, Float64(-0.0)) != 0:
        raise Error("float temporal: -0.0 -> 1.0 (slot 0)")

    var k = AsofJoinBuildTable[AsofKeyBundle1[DType.float64], DType.int64](
        PayloadBlock[](), 8
    )
    asof_build_append_1_f64(k, nan[DType.float64](), Int64(10), empty)
    asof_build_append_1_f64(k, nan[DType.float64](), Int64(20), empty)
    asof_build_append_1_f64(k, Float64(0.0), Int64(5), empty)
    if asof_probe_forward_1(k, nan[DType.float64](), Int64(15)) != 1:
        raise Error("float key: NaN finds the NaN partition (slot 1)")
    if asof_probe_forward_1(k, Float64(-0.0), Int64(1)) != 2:
        raise Error("float key: -0.0 finds the +0.0 partition (slot 2)")
    if asof_probe_forward_1(k, Float64(1.0), Int64(1)) != -1:
        raise Error("float key: 1.0 has no partition")
    print("test_float_keys_follow_the_sort_order PASS")


def test_float_temporal_nan_with_one_key() raises:
    """One INT64 key, FLOAT64 temporal. Key 1 holds t=[1.0, 2.0, NaN], key 2
    holds t=[NaN] (ascending in `sort_key_lt` order). Probe (1, 2.5) and
    (1, NaN) find the NaN row (slot 2); (1, -0.0) finds slot 0; (2, 0.5)
    finds key 2's NaN row (slot 3). An IEEE `<` sends the NaN probe to a
    miss or to an earlier row."""
    var t = AsofJoinBuildTable[AsofKeyBundle1[DType.int64], DType.float64](
        PayloadBlock[](), 8
    )
    var empty = List[Float64]()
    asof_build_append_1_f64(t, Int64(1), Float64(1.0), empty)
    asof_build_append_1_f64(t, Int64(1), Float64(2.0), empty)
    asof_build_append_1_f64(t, Int64(1), nan[DType.float64](), empty)
    asof_build_append_1_f64(t, Int64(2), nan[DType.float64](), empty)
    if asof_probe_forward_1(t, Int64(1), Float64(2.5)) != 2:
        raise Error("1x float temporal: 2.5 -> the NaN row (slot 2)")
    if asof_probe_forward_1(t, Int64(1), nan[DType.float64]()) != 2:
        raise Error("1x float temporal: NaN -> the NaN row (slot 2)")
    if asof_probe_forward_1(t, Int64(1), Float64(-0.0)) != 0:
        raise Error("1x float temporal: -0.0 -> 1.0 (slot 0)")
    if asof_probe_forward_1(t, Int64(2), Float64(0.5)) != 3:
        raise Error("1x float temporal: key 2 -> its NaN row (slot 3)")
    print("test_float_temporal_nan_with_one_key PASS")


def test_float_temporal_nan_with_two_keys() raises:
    """The one-key case over two keys (INT64, INT32): partition (1, 5) holds
    t=[1.0, NaN], partition (1, 6) holds t=[2.0]. The key pair selects the
    partition; NaN and 1.5 both find the NaN row of (1, 5) (slot 1); (1, 6)
    with NaN finds nothing (its only row is 2.0)."""
    var t = AsofJoinBuildTable[
        AsofKeyBundle2[DType.int64, DType.int32], DType.float64
    ](PayloadBlock[](), 8)
    var empty = List[Float64]()
    asof_build_append_2_f64(t, Int64(1), Int32(5), Float64(1.0), empty)
    asof_build_append_2_f64(t, Int64(1), Int32(5), nan[DType.float64](), empty)
    asof_build_append_2_f64(t, Int64(1), Int32(6), Float64(2.0), empty)
    if asof_probe_forward_2(t, Int64(1), Int32(5), Float64(1.5)) != 1:
        raise Error("2x float temporal: 1.5 -> the NaN row (slot 1)")
    if asof_probe_forward_2(t, Int64(1), Int32(5), nan[DType.float64]()) != 1:
        raise Error("2x float temporal: NaN -> the NaN row (slot 1)")
    if asof_probe_forward_2(t, Int64(1), Int32(6), nan[DType.float64]()) != -1:
        raise Error("2x float temporal: NaN above (1, 6)'s only row -> miss")
    if asof_probe_forward_2(t, Int64(1), Int32(6), Float64(1.0)) != 2:
        raise Error("2x float temporal: (1, 6) at 1.0 -> slot 2")
    print("test_float_temporal_nan_with_two_keys PASS")


def test_equal_temporal_keys_resolve_to_the_earliest_row() raises:
    """Within one key group, rows with the same temporal key are told apart
    by their payload; every probe that lands on that temporal key returns
    the first of them. Zero, one and two keys."""
    comptime P = PayloadSlot[DType.int64]
    var t0 = AsofJoinBuildTable[AsofKeyBundle0, DType.int64, P](
        PayloadBlock[P](payload_slot[DType.int64](8)), 8
    )
    var t1 = AsofJoinBuildTable[AsofKeyBundle1[DType.int64], DType.int64, P](
        PayloadBlock[P](payload_slot[DType.int64](8)), 8
    )
    var t2 = AsofJoinBuildTable[
        AsofKeyBundle2[DType.int64, DType.int64], DType.int64, P
    ](PayloadBlock[P](payload_slot[DType.int64](8)), 8)
    # temporal 10, 10, 10, 20 with payloads 1, 2, 3, 4
    var temps: List[Int64] = [10, 10, 10, 20]
    for i in range(4):
        var pv = List[Float64]()
        pv.append(Float64(i + 1))
        asof_build_append_0_f64(t0, temps[i], pv)
        asof_build_append_1_f64(t1, Int64(7), temps[i], pv)
        asof_build_append_2_f64(t2, Int64(7), Int64(8), temps[i], pv)
    var probes: List[Int64] = [5, 10]
    for i in range(2):
        var s0 = asof_probe_forward_0(t0, probes[i])
        var s1 = asof_probe_forward_1(t1, Int64(7), probes[i])
        var s2 = asof_probe_forward_2(t2, Int64(7), Int64(8), probes[i])
        if s0 != 0 or s1 != 0 or s2 != 0:
            raise Error("equal temporal keys: the earliest row (slot 0)")
        if Int(t1.payload_read_f64[0](s1)) != 1:
            raise Error("equal temporal keys: payload of the earliest row")
    if asof_probe_forward_1(t1, Int64(7), Int64(11)) != 3:
        raise Error("1x: 11 -> the 20 row (slot 3)")
    if asof_probe_forward_2(t2, Int64(7), Int64(8), Int64(11)) != 3:
        raise Error("2x: 11 -> the 20 row (slot 3)")
    print("test_equal_temporal_keys_resolve_to_the_earliest_row PASS")


def main() raises:
    test_0x_i64_p3_basic()
    test_0x_i64_p0_keyonly()
    test_0x_i64_p1()
    test_0x_i64_p2()
    test_0x_i32_p4()
    test_1x_i64_p3_partition()
    test_1x_i64_p0()
    test_1x_i32_p1()
    test_2x_i64_p0_composite()
    test_2x_i64_p2_composite()
    test_2x_i32_p3_composite()
    test_2x_i64_p4_composite()
    test_float_keys_follow_the_sort_order()
    test_float_temporal_nan_with_one_key()
    test_float_temporal_nan_with_two_keys()
    test_equal_temporal_keys_resolve_to_the_earliest_row()
    print("ALL test_asof_join_build.mojo tests PASS (16/16)")
