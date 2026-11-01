# =============================================================================
# test_join_probe_outer_semi_anti_layouts -- SEMI, ANTI, their counts, LEFT,
# RIGHT and FULL against a hash-free nested-loop oracle, over every chain layout
# and with NULL keys on both sides.
# =============================================================================
#
# What each test proves:
#   * `test_null_probe_keys_match_nothing_*`: the build holds a real key 0 and
#     the probe holds NULL rows whose stored value is also 0. A probe kernel
#     that walks the chain for a NULL probe row pairs it with that real 0, so
#     LEFT, RIGHT, FULL, SEMI, ANTI and both counts all disagree with the
#     oracle. Run on the small-build arm and on the large-build (bloom,
#     two-stage prefetch) arm.
#   * `test_null_build_keys_never_link_*`: the build holds NULL rows whose
#     stored value is 0, no real 0, and the probe holds a real 0. A build that
#     links a NULL row lets that probe row match it.
#   * `test_every_chain_layout_*`: the same fixtures through the four layouts
#     (`nobi` x `fused`). A kernel that reads the chain at the wrong stride, or
#     a build-row lookup that assumes the elided index array, returns other
#     rows' keys or pairs.
#   * `test_payload_inline_index_is_refused_*`: a payload-inline index (32-byte
#     entries) is refused by each kernel that hoists the entries at the 16-byte
#     stride, naming the kernel, instead of returning a plausible wrong join.
#   * `test_payload_inline_index_serves_stride_aware_kernels`: RIGHT, FULL and
#     the INNER count walk entries through the stride-aware accessors, so on a
#     payload-inline index they still equal the oracle.
#
# Pair results are compared as multisets (the pair order within a probe row is
# the chain order and is not part of the contract); SEMI and ANTI results are
# compared as exact ascending lists.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_op_join_build.join import HashJoinBuilder


struct _Fixture(Copyable):
    var build_keys: List[Int64]
    var build_nulls: List[Bool]
    var probe_keys: List[Int64]
    var probe_nulls: List[Bool]

    def __init__(out self):
        self.build_keys = List[Int64]()
        self.build_nulls = List[Bool]()
        self.probe_keys = List[Int64]()
        self.probe_nulls = List[Bool]()


def _pa(
    keys: List[Int64], nulls: List[Bool]
) raises -> PrimitiveArray[DType.int64]:
    var n = len(keys)
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p[i] = keys[i]
        if nulls[i]:
            arr._set_null(i)
    return arr^


def _fixture(large: Bool, real_zero_in_build: Bool) -> _Fixture:
    """NULL rows on both sides store 0. With `real_zero_in_build` the build
    holds a real 0 and no key is shifted; without it every real build key is
    shifted off 0, so only the probe holds a real 0."""
    var f = _Fixture()
    var nb = 4200 if large else 40
    var np_ = 400 if large else 60
    var bmod = 3000 if large else 11
    var pmod = 6000 if large else 13
    var pmul = 13 if large else 3
    var shift = 0 if real_zero_in_build else 1
    for i in range(nb):
        var is_null = i % 5 == 3
        f.build_nulls.append(is_null)
        f.build_keys.append(Int64(0 if is_null else shift + (i * 7) % bmod))
    for i in range(np_):
        var is_null = i % 4 == 1
        f.probe_nulls.append(is_null)
        f.probe_keys.append(Int64(0 if is_null else (i * pmul) % pmod))
    return f^


def _tally(
    build_rows: List[Int], probe_rows: List[Int]
) -> Dict[Int, Int]:
    var d = Dict[Int, Int]()
    for i in range(len(build_rows)):
        var k = (build_rows[i] + 1) * 10_000_000 + (probe_rows[i] + 1)
        d[k] = d.get(k, 0) + 1
    return d^


def _same_pairs(
    actual_b: List[Int],
    actual_p: List[Int],
    want_b: List[Int],
    want_p: List[Int],
) -> Bool:
    if len(actual_b) != len(want_b) or len(actual_p) != len(want_p):
        return False
    var a = _tally(actual_b, actual_p)
    var w = _tally(want_b, want_p)
    if len(a) != len(w):
        return False
    for kv in w.items():
        if a.get(kv.key, 0) != kv.value:
            return False
    return True


struct _Oracle(Movable):
    var left_b: List[Int]
    var left_p: List[Int]
    var right_b: List[Int]
    var right_p: List[Int]
    var full_b: List[Int]
    var full_p: List[Int]
    var semi: List[Int]
    var anti: List[Int]
    var inner_count: Int

    def __init__(out self):
        self.left_b = List[Int]()
        self.left_p = List[Int]()
        self.right_b = List[Int]()
        self.right_p = List[Int]()
        self.full_b = List[Int]()
        self.full_p = List[Int]()
        self.semi = List[Int]()
        self.anti = List[Int]()
        self.inner_count = 0


def _oracle(f: _Fixture) -> _Oracle:
    """Nested-loop join: a NULL key on either side matches nothing."""
    var o = _Oracle()
    var nb = len(f.build_keys)
    var matched = List[Bool]()
    for _ in range(nb):
        matched.append(False)
    for pi in range(len(f.probe_keys)):
        var found = False
        for bi in range(nb):
            if (
                (not f.probe_nulls[pi])
                and (not f.build_nulls[bi])
                and f.probe_keys[pi] == f.build_keys[bi]
            ):
                found = True
                matched[bi] = True
                o.inner_count += 1
                o.left_b.append(bi)
                o.left_p.append(pi)
                o.right_b.append(bi)
                o.right_p.append(pi)
                o.full_b.append(bi)
                o.full_p.append(pi)
        if found:
            o.semi.append(pi)
        else:
            o.anti.append(pi)
            o.left_b.append(-1)
            o.left_p.append(pi)
            o.full_b.append(-1)
            o.full_p.append(pi)
    for bi in range(nb):
        if not matched[bi]:
            o.right_b.append(bi)
            o.right_p.append(-1)
            o.full_b.append(bi)
            o.full_p.append(-1)
    return o^


def _same_list(actual: List[Int], want: List[Int]) -> Bool:
    if len(actual) != len(want):
        return False
    for i in range(len(want)):
        if actual[i] != want[i]:
            return False
    return True


def _check_all(
    f: _Fixture, nobi: Bool, fused: Bool, label: String
) raises:
    var tag = (
        label + " nobi=" + String(nobi) + " fused=" + String(fused) + ": "
    )
    var o = _oracle(f)
    var b = HashJoinBuilder.build(
        _pa(f.build_keys, f.build_nulls), True, nobi, fused
    )
    var pa = _pa(f.probe_keys, f.probe_nulls)

    var left = b.probe_left(pa)
    assert_true(
        _same_pairs(left[0], left[1], o.left_b, o.left_p), tag + "LEFT"
    )
    var lb = List[Int]()
    var lp = List[Int]()
    b.probe_left_into(pa, lb, lp)
    assert_true(
        _same_pairs(lb, lp, o.left_b, o.left_p), tag + "LEFT into buffers"
    )
    var right = b.probe_right(pa)
    assert_true(
        _same_pairs(right[0], right[1], o.right_b, o.right_p), tag + "RIGHT"
    )
    var full = b.probe_full(pa)
    assert_true(
        _same_pairs(full[0], full[1], o.full_b, o.full_p), tag + "FULL"
    )
    assert_true(_same_list(b.probe_semi(pa), o.semi), tag + "SEMI rows")
    assert_true(_same_list(b.probe_anti(pa), o.anti), tag + "ANTI rows")
    assert_equal(b.probe_semi_count(pa), len(o.semi), tag + "SEMI count")
    assert_equal(b.probe_anti_count(pa), len(o.anti), tag + "ANTI count")
    assert_equal(b.count_inner_matches(pa), o.inner_count, tag + "INNER count")
    _ = b
    _ = pa


def _check_layouts(large: Bool, real_zero_in_build: Bool, label: String) raises:
    var f = _fixture(large, real_zero_in_build)
    for cfg in range(4):
        _check_all(f, (cfg & 1) == 0, (cfg & 2) == 0, label)


def test_null_probe_keys_match_nothing_small_build() raises:
    _check_layouts(False, True, "small build, real 0 in build")


def test_null_probe_keys_match_nothing_large_build() raises:
    _check_layouts(True, True, "large build, real 0 in build")


def test_null_build_keys_never_link_small_build() raises:
    _check_layouts(False, False, "small build, NULL build rows store 0")


def test_null_build_keys_never_link_large_build() raises:
    _check_layouts(True, False, "large build, NULL build rows store 0")


def test_every_chain_layout_with_duplicate_keys() raises:
    # Few distinct keys, so every chain is long; the layouts differ in how a
    # chain entry maps back to a build row.
    var f = _Fixture()
    for i in range(300):
        f.build_nulls.append(i % 7 == 0)
        f.build_keys.append(Int64(0 if i % 7 == 0 else i % 5))
    for i in range(200):
        f.probe_nulls.append(i % 6 == 0)
        f.probe_keys.append(Int64(0 if i % 6 == 0 else i % 8))
    for cfg in range(4):
        _check_all(f, (cfg & 1) == 0, (cfg & 2) == 0, "duplicate keys")


def _payload_inline_builder(
    f: _Fixture,
) raises -> HashJoinBuilder:
    var pay = List[Int64]()
    for i in range(len(f.build_keys)):
        pay.append(Int64(1000 + i))
    var b = HashJoinBuilder.build(
        _pa(f.build_keys, f.build_nulls),
        pay_values=pay^,
        pay_build_col=1,
    )
    assert_true(b.pay_inline(), "the fixture index carries inline payload")
    return b^


def _expect_refused(raised: Bool, msg: String, kernel: String) raises:
    assert_true(raised, kernel + " refuses a payload-inline index")
    assert_true(
        kernel in msg,
        kernel + " names itself in its refusal, got: " + msg,
    )


def test_payload_inline_index_is_refused_by_semi_and_anti() raises:
    var f = _fixture(False, True)
    var b = _payload_inline_builder(f)
    var pa = _pa(f.probe_keys, f.probe_nulls)

    var raised = False
    var msg = String("")
    try:
        _ = b.probe_semi(pa)
    except e:
        raised = True
        msg = String(e)
    _expect_refused(raised, msg, "probe_semi")

    raised = False
    msg = String("")
    try:
        _ = b.probe_semi_count(pa)
    except e:
        raised = True
        msg = String(e)
    _expect_refused(raised, msg, "probe_semi_count")

    raised = False
    msg = String("")
    try:
        _ = b.probe_anti(pa)
    except e:
        raised = True
        msg = String(e)
    _expect_refused(raised, msg, "probe_anti")

    raised = False
    msg = String("")
    try:
        _ = b.probe_anti_count(pa)
    except e:
        raised = True
        msg = String(e)
    _expect_refused(raised, msg, "probe_anti_count")
    _ = b
    _ = pa


def test_payload_inline_index_is_refused_by_left() raises:
    var f = _fixture(False, True)
    var b = _payload_inline_builder(f)
    var pa = _pa(f.probe_keys, f.probe_nulls)

    var raised = False
    var msg = String("")
    var lb = List[Int]()
    var lp = List[Int]()
    try:
        b.probe_left_into(pa, lb, lp)
    except e:
        raised = True
        msg = String(e)
    _expect_refused(raised, msg, "probe_left_into")
    assert_equal(len(lb), 0, "a refused LEFT probe appends no pairs")

    raised = False
    msg = String("")
    try:
        _ = b.probe_left(pa)
    except e:
        raised = True
        msg = String(e)
    _expect_refused(raised, msg, "probe_left_into")
    _ = b
    _ = pa


def test_payload_inline_index_serves_stride_aware_kernels() raises:
    var f = _fixture(False, True)
    var o = _oracle(f)
    var b = _payload_inline_builder(f)
    var pa = _pa(f.probe_keys, f.probe_nulls)

    var right = b.probe_right(pa)
    assert_true(
        _same_pairs(right[0], right[1], o.right_b, o.right_p),
        "RIGHT on a payload-inline index",
    )
    var full = b.probe_full(pa)
    assert_true(
        _same_pairs(full[0], full[1], o.full_b, o.full_p),
        "FULL on a payload-inline index",
    )
    assert_equal(
        b.count_inner_matches(pa),
        o.inner_count,
        "INNER count on a payload-inline index",
    )
    _ = b
    _ = pa


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
