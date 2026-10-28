# Brute-force reference check of the six composite-key probes (INNER, LEFT,
# SEMI, ANTI, RIGHT, FULL). For each of 200 deterministic seeds a random
# build batch and probe batch are generated (1 to 8 keys; INT64, INT32,
# FLOAT64, STRING and DICTIONARY columns, including the uniform all-INT,
# all-STRING and all-DICTIONARY arms with the same or a different
# dictionary; NULLs; duplicate keys; empty sides; sliced columns; NaN
# payloads, -0.0 and infinities), and every probe's output is compared with
# a nested loop over the logical key values. NULL matches nothing, NaN equals
# NaN, -0.0 equals +0.0, SEMI/ANTI return probe rows in order, RIGHT/FULL
# emit each unmatched build row once. The last test pins the key-count
# mismatch error of SEMI, ANTI, RIGHT and FULL.

from std.memory import bitcast
from std.testing import TestSuite

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_op_join_probe.join_key_extract import (
    extract_join_key_columns_serial,
)
from komira_op_join_probe.join_multi_key_builder import (
    MultiKeyHashJoinBuilder,
)
from komira_op_join_probe.join_multi_key_filter import (
    multi_key_probe_semi,
    multi_key_probe_anti,
)
from komira_op_join_probe.join_multi_key_outer import (
    multi_key_probe_right_into,
    multi_key_probe_full_into,
)


def sort(mut l: List[Int]):
    var n = len(l)
    var width = 1
    var src = l.copy()
    var dst = l.copy()
    while width < n:
        var i = 0
        while i < n:
            var mid = min(i + width, n)
            var hi = min(i + 2 * width, n)
            var a = i
            var b = mid
            var o = i
            while a < mid and b < hi:
                if src[a] <= src[b]:
                    dst[o] = src[a]
                    a += 1
                else:
                    dst[o] = src[b]
                    b += 1
                o += 1
            while a < mid:
                dst[o] = src[a]
                a += 1
                o += 1
            while b < hi:
                dst[o] = src[b]
                b += 1
                o += 1
            i += 2 * width
        var t = src.copy()
        src = dst.copy()
        dst = t^
        width *= 2
    l = src^


struct Rng(Movable):
    var s: UInt64

    def __init__(out self, seed: Int):
        self.s = UInt64(seed + 1) * UInt64(6364136223846793005) + UInt64(
            1442695040888963407
        )

    def next(mut self) -> Int:
        self.s = self.s * UInt64(6364136223846793005) + UInt64(
            1442695040888963407
        )
        return Int((self.s >> 33) & UInt64(0x7FFFFFFF))

    def below(mut self, n: Int) -> Int:
        return self.next() % n


def _str_of(c: Int) -> String:
    if c == 0:
        return String("")
    if c == 1:
        return String("a")
    if c == 2:
        return String("b")
    if c == 3:
        return String("ab")
    if c == 4:
        return String("aaaaaaaaaaaaaaaaaaaaaaaaa")
    if c == 5:
        return String("日本語")
    return String("aaaaaaaaaaaaaaaaaaaaaaaab")


def _f_of(c: Int, v: Int) -> Float64:
    if c == 0:
        if v % 2 == 0:
            return Float64(0.0)
        return bitcast[DType.float64](UInt64(0x8000000000000000))
    if c == 1:
        var w = v % 4
        if w == 0:
            return bitcast[DType.float64](UInt64(0x7FF8000000000000))
        if w == 1:
            return bitcast[DType.float64](UInt64(0xFFF8000000000000))
        if w == 2:
            return bitcast[DType.float64](UInt64(0x7FF0000000000001))
        return bitcast[DType.float64](UInt64(0x7FF8000000000001))
    if c == 2:
        return Float64(1.5)
    if c == 3:
        return bitcast[DType.float64](UInt64(0x7FF0000000000000))
    if c == 4:
        return bitcast[DType.float64](UInt64(0xFFF0000000000000))
    if c == 5:
        return Float64(2.5)
    return Float64(-1.5)


def _make_col(
    kind: Int,
    cls: List[Int],
    big: Bool,
    dvar: Int,
    D: Int,
    mut rng: Rng,
) raises -> Column[HeapRegion]:
    var n = len(cls)
    var sliced = kind != 3 and rng.below(3) == 0
    var p0 = 0
    var p1 = 0
    var full = List[Int]()
    if sliced:
        p0 = 1 + rng.below(3)
        p1 = rng.below(3)
        for _ in range(p0):
            var j = rng.below(D + 1) - 1
            full.append(j)
    for i in range(n):
        full.append(cls[i])
    if sliced:
        for _ in range(p1):
            var j = rng.below(D + 1) - 1
            full.append(j)
    var m = len(full)
    var has_null = False
    for i in range(m):
        if full[i] < 0:
            has_null = True
    var use_nullable = has_null or rng.below(2) == 0
    var col: Column[HeapRegion]
    if kind == 0:
        var arr: PrimitiveArray[DType.int64]
        if use_nullable:
            arr = PrimitiveArray[DType.int64].allocate_nullable(m)
        else:
            arr = PrimitiveArray[DType.int64].allocate(m)
        var p = arr._typed_ptr_mut()
        var mult = Int64(1)
        if big:
            mult = Int64(3000000019)
        for i in range(m):
            if full[i] < 0:
                p.store[width=1](i, Int64(777))
                arr._set_null(i)
            else:
                p.store[width=1](i, (Int64(full[i]) - 1) * mult)
        col = Column.from_primitive[DType.int64](arr^)
    elif kind == 1:
        var arr = PrimitiveArray[DType.int32].allocate_nullable(m)
        var p = arr._typed_ptr_mut()
        for i in range(m):
            if full[i] < 0:
                p.store[width=1](i, Int32(777))
                arr._set_null(i)
            else:
                p.store[width=1](i, Int32(full[i]) - 1)
        col = Column.from_primitive[DType.int32](arr^)
    elif kind == 2:
        var arr: PrimitiveArray[DType.float64]
        if use_nullable:
            arr = PrimitiveArray[DType.float64].allocate_nullable(m)
        else:
            arr = PrimitiveArray[DType.float64].allocate(m)
        var p = arr._typed_ptr_mut()
        for i in range(m):
            if full[i] < 0:
                p.store[width=1](i, Float64(5.5))
                arr._set_null(i)
            else:
                p.store[width=1](i, _f_of(full[i], rng.next()))
        col = Column.from_primitive[DType.float64](arr^)
    elif kind == 3:
        var vals = List[String]()
        var valid = List[Bool]()
        for i in range(m):
            if full[i] < 0:
                vals.append(String("a"))
                valid.append(False)
            else:
                vals.append(_str_of(full[i]))
                valid.append(True)
        var sa = StringArray.from_strings_with_validity(vals, valid)
        col = Column.from_string(sa^)
    else:
        var idx: PrimitiveArray[DType.int32]
        if use_nullable:
            idx = PrimitiveArray[DType.int32].allocate_nullable(m)
        else:
            idx = PrimitiveArray[DType.int32].allocate(m)
        var p = idx._typed_ptr_mut()
        var dl = List[String]()
        for c in range(7):
            if dvar == 0:
                dl.append(_str_of(c))
            else:
                dl.append(_str_of(6 - c))
        if dvar != 0:
            dl.append(String("zz"))
        for i in range(m):
            if full[i] < 0:
                p.store[width=1](i, Int32(0))
                idx._set_null(i)
            else:
                if dvar == 0:
                    p.store[width=1](i, Int32(full[i]))
                else:
                    p.store[width=1](i, Int32(6 - full[i]))
        var dsa = StringArray.from_strings(dl)
        var da = StringDictionaryArray.from_parts(idx^, dsa^)
        col = Column.from_dictionary(da)
    if sliced:
        return col.slice(p0, n)
    return col^


def _arrow_type(kind: Int) -> ArrowType:
    if kind == 0:
        return ArrowType.INT64
    if kind == 1:
        return ArrowType.INT32
    if kind == 2:
        return ArrowType.FLOAT64
    if kind == 3:
        return ArrowType.STRING
    return ArrowType.DICTIONARY


def _make_batch(
    nk: Int,
    kinds: List[Int],
    cls: List[List[Int]],
    bigs: List[Bool],
    dvars: List[Int],
    D: Int,
    mut rng: Rng,
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    var bb = RecordBatchBuilder()
    for k in range(nk):
        sb.add_field(Field("k" + String(k), _arrow_type(kinds[k]), True))
        bb.add_column(_make_col(kinds[k], cls[k], bigs[k], dvars[k], D, rng))
    return bb.build(sb.build())


def _pair(b: Int, p: Int) -> Int:
    return (b + 1) * 1000000 + (p + 1)


def _fmt(imm l: List[Int]) -> String:
    var s = String("[")
    for i in range(min(len(l), 40)):
        s += String(l[i]) + ","
    s += "](" + String(len(l)) + ")"
    return s^


struct Stats(Movable):
    var cases: Int
    var semi_rows: Int
    var anti_rows: Int
    var inner_pairs: Int
    var right_unmatched: Int
    var null_cases: Int

    def __init__(out self):
        self.cases = 0
        self.semi_rows = 0
        self.anti_rows = 0
        self.inner_pairs = 0
        self.right_unmatched = 0
        self.null_cases = 0


def _run_case(seed: Int, mut st: Stats) raises:
    var rng = Rng(seed)
    var nk = 1 + rng.below(8)
    var D = 2
    if nk == 1:
        D = 6
    elif nk == 2:
        D = 4
    elif nk <= 4:
        D = 3
    var nb = rng.below(10)
    var np = rng.below(10)
    var r = rng.below(25)
    if r == 0:
        nb = 0
    elif r == 1:
        np = 0
    elif r == 2:
        nb = 150
        np = 170
    # per-key kinds
    var bk = List[Int]()
    var pk = List[Int]()
    var bigs = List[Bool]()
    var bdv = List[Int]()
    var pdv = List[Int]()
    for _ in range(nk):
        var fam = rng.below(4)
        if fam == 0:
            # int family
            var a = rng.below(2)
            var b = rng.below(2)
            bk.append(a)
            pk.append(b)
            bigs.append(a == 0 and b == 0 and rng.below(2) == 0)
            bdv.append(0)
            pdv.append(0)
        elif fam == 1:
            bk.append(2)
            pk.append(2)
            bigs.append(False)
            bdv.append(0)
            pdv.append(0)
        else:
            var a = 3 + rng.below(2)
            var b = 3 + rng.below(2)
            bk.append(a)
            pk.append(b)
            bigs.append(False)
            bdv.append(0)
            pdv.append(rng.below(2))
    if nk >= 2 and rng.below(2) == 0:
        var u = rng.below(3)
        for k in range(nk):
            if u == 0:
                bk[k] = 3
                pk[k] = 3
                pdv[k] = 0
            elif u == 1:
                bk[k] = 4
                pk[k] = 4
                pdv[k] = 0
            else:
                bk[k] = 4
                pk[k] = 4
                pdv[k] = 1
            bigs[k] = False
    var bcls = List[List[Int]]()
    var pcls = List[List[Int]]()
    var nullp = rng.below(4)  # 0: no nulls ... else ~1/6
    for k in range(nk):
        var cb = List[Int]()
        for _ in range(nb):
            var c = rng.below(D)
            if nullp != 0 and rng.below(6) == 0:
                c = -1
                st.null_cases += 1
            cb.append(c)
        bcls.append(cb^)
        var cp = List[Int]()
        for _ in range(np):
            var c = rng.below(D)
            if nullp != 0 and rng.below(6) == 0:
                c = -1
                st.null_cases += 1
            cp.append(c)
        pcls.append(cp^)
    var bbatch = _make_batch(nk, bk, bcls, bigs, bdv, D, rng)
    var pbatch = _make_batch(nk, pk, pcls, bigs, pdv, D, rng)
    var names = List[String]()
    for k in range(nk):
        names.append("k" + String(k))
    var bkeys = extract_join_key_columns_serial(bbatch, names)
    var builder = MultiKeyHashJoinBuilder.build(bkeys^)
    var pkeys = extract_join_key_columns_serial(pbatch, names)

    # reference result from a nested loop
    var inner = List[Int]()
    var left = List[Int]()
    var right = List[Int]()
    var full = List[Int]()
    var semi = List[Int]()
    var anti = List[Int]()
    var bmatched = List[Bool]()
    for _ in range(nb):
        bmatched.append(False)
    for p in range(np):
        var any = False
        for b in range(nb):
            var m = True
            for k in range(nk):
                var x = bcls[k][b]
                var y = pcls[k][p]
                if x < 0 or y < 0 or x != y:
                    m = False
                    break
            if m:
                any = True
                bmatched[b] = True
                inner.append(_pair(b, p))
                left.append(_pair(b, p))
                right.append(_pair(b, p))
                full.append(_pair(b, p))
        if any:
            semi.append(p)
        else:
            anti.append(p)
            left.append(_pair(-1, p))
            full.append(_pair(-1, p))
    for b in range(nb):
        if not bmatched[b]:
            right.append(_pair(b, -1))
            full.append(_pair(b, -1))
            st.right_unmatched += 1
    st.cases += 1
    st.semi_rows += len(semi)
    st.anti_rows += len(anti)
    st.inner_pairs += len(inner)

    var tag = "seed " + String(seed) + " nk=" + String(nk) + " nb=" + String(nb) + " np=" + String(np) + " bk=" + _fmt(bk) + " pk=" + _fmt(pk) + " pdv=" + _fmt(pdv)

    # actual
    var bm = List[Int]()
    var pm = List[Int]()
    builder.probe_inner_into(pkeys, bm, pm)
    var got = List[Int]()
    for i in range(len(bm)):
        got.append(_pair(bm[i], pm[i]))
    sort(got)
    sort(inner)
    if got != inner:
        raise Error("INNER mismatch " + tag + " got " + _fmt(got) + " want " + _fmt(inner))

    bm = List[Int]()
    pm = List[Int]()
    builder.probe_left_into(pkeys, bm, pm)
    got = List[Int]()
    for i in range(len(bm)):
        got.append(_pair(bm[i], pm[i]))
    sort(got)
    sort(left)
    if got != left:
        raise Error("LEFT mismatch " + tag + " got " + _fmt(got) + " want " + _fmt(left))

    var s = multi_key_probe_semi(builder, pkeys)
    if s != semi:
        raise Error("SEMI mismatch " + tag + " got " + _fmt(s) + " want " + _fmt(semi))
    var a = multi_key_probe_anti(builder, pkeys)
    if a != anti:
        raise Error("ANTI mismatch " + tag + " got " + _fmt(a) + " want " + _fmt(anti))

    bm = List[Int]()
    pm = List[Int]()
    multi_key_probe_right_into(builder, pkeys, bm, pm)
    got = List[Int]()
    for i in range(len(bm)):
        got.append(_pair(bm[i], pm[i]))
    sort(got)
    sort(right)
    if got != right:
        raise Error("RIGHT mismatch " + tag + " got " + _fmt(got) + " want " + _fmt(right))

    bm = List[Int]()
    pm = List[Int]()
    multi_key_probe_full_into(builder, pkeys, bm, pm)
    got = List[Int]()
    for i in range(len(bm)):
        got.append(_pair(bm[i], pm[i]))
    sort(got)
    sort(full)
    if got != full:
        raise Error("FULL mismatch " + tag + " got " + _fmt(got) + " want " + _fmt(full))


def test_probes_match_nested_loop() raises:
    var st = Stats()
    for seed in range(200):
        _run_case(seed, st)
    if (
        st.semi_rows < 50
        or st.anti_rows < 50
        or st.inner_pairs < 100
        or st.right_unmatched < 50
        or st.null_cases < 50
    ):
        raise Error(
            "reference check is vacuous: semi=" + String(st.semi_rows)
            + " anti=" + String(st.anti_rows)
            + " inner=" + String(st.inner_pairs)
            + " runm=" + String(st.right_unmatched)
            + " nulls=" + String(st.null_cases)
        )


def test_key_count_mismatch_raises() raises:
    var cb = List[List[Int]]()
    var c0 = List[Int]()
    c0.append(1)
    c0.append(2)
    cb.append(c0.copy())
    cb.append(c0.copy())
    var kinds = List[Int]()
    kinds.append(0)
    kinds.append(0)
    var bigs = List[Bool]()
    bigs.append(False)
    bigs.append(False)
    var dv = List[Int]()
    dv.append(0)
    dv.append(0)
    var rng = Rng(5)
    var bb = _make_batch(2, kinds, cb, bigs, dv, 3, rng)
    var names = List[String]()
    names.append("k0")
    names.append("k1")
    var builder = MultiKeyHashJoinBuilder.build(extract_join_key_columns_serial(bb, names))
    var pcl = List[List[Int]]()
    pcl.append(c0.copy())
    var kinds1 = List[Int]()
    kinds1.append(0)
    var bigs1 = List[Bool]()
    bigs1.append(False)
    var dv1 = List[Int]()
    dv1.append(0)
    var pb = _make_batch(1, kinds1, pcl, bigs1, dv1, 3, rng)
    var n1 = List[String]()
    n1.append("k0")
    var pk = extract_join_key_columns_serial(pb, n1)
    var want = "probe key count 1 != build key count 2"
    var bm = List[Int]()
    var pm = List[Int]()
    var msgs = List[String]()
    try:
        _ = multi_key_probe_semi(builder, pk)
    except e:
        msgs.append(String(e))
    try:
        _ = multi_key_probe_anti(builder, pk)
    except e:
        msgs.append(String(e))
    try:
        multi_key_probe_right_into(builder, pk, bm, pm)
    except e:
        msgs.append(String(e))
    try:
        multi_key_probe_full_into(builder, pk, bm, pm)
    except e:
        msgs.append(String(e))
    var names_fn = List[String]()
    names_fn.append("multi_key_probe_semi: ")
    names_fn.append("multi_key_probe_anti: ")
    names_fn.append("multi_key_probe_right_into: ")
    names_fn.append("multi_key_probe_full_into: ")
    if len(msgs) != 4:
        raise Error("key-count mismatch raised " + String(len(msgs)) + " of 4")
    for i in range(4):
        if msgs[i] != names_fn[i] + want:
            raise Error("unexpected key-count error: " + msgs[i])


def main() raises:
    var suite = TestSuite()
    suite.test[test_probes_match_nested_loop]()
    suite.test[test_key_count_mismatch_raises]()
    suite^.run()
