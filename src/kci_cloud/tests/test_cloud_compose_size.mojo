# =============================================================================
# test_cloud_compose_size.mojo
# =============================================================================
#
# THE SIZE GUARD (compose.mojo step 4): a list that expands to more than
# `MAX_EXPANDED_PRIMITIVES` (10,000) primitives is refused before any is
# built. The definitions are a diamond, ten wide at each of four levels:
# `acme.l3` holds ten buckets, `acme.l2` ten instances of `acme.l3`, `acme.l1`
# ten of `acme.l2`, and `acme.l0` ten of `acme.l1`: one instance of `acme.l0`
# is exactly 10,000 primitives. `acme.big` holds ten instances of `acme.l0`
# (100,000).
#
# 1. ONE OVER IS REFUSED: one `acme.l0` instance and one bucket at the top
#    (10,001, counting the authored primitive) is one finding on `(list)`
#    with each instance's count, and nothing is expanded.
# 2. FAR OVER IS REFUSED AT ONCE: `acme.big` (100,000) is counted as "more
#    than 10000" without overflowing or building anything, and so is a list
#    of two `acme.l0` instances (20,000).
# 3. EXACTLY THE LIMIT IS EXPANDED: one `acme.l0` instance alone expands to
#    10,000 buckets, the deepest `top/a0/b0/c0/d0`.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json
from kci_resource_proto.composite import CompositeDefinition
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud import Catalog, MAX_EXPANDED_PRIMITIVES, expand


def _level(name: String, prefix: String, inner: String) raises -> CompositeDefinition:
    """`name@1` holding ten components `<prefix>0`..`<prefix>9`: buckets when
    `inner` is empty, else instances of `inner@1`."""
    var comps = String("")
    for i in range(10):
        if i > 0:
            comps += String(",")
        comps += String('{"id":"') + prefix + String(i) + String('",')
        if inner.byte_length() == 0:
            comps += String('"bucket":{}}')
        else:
            comps += String('"composite":{"definition":"') + inner + String('","version":"1"}}')
    return decode_json[CompositeDefinition](String('{"name":"') + name + String('","version":"1","component":[') + comps + String("]}"))


def _diamond() raises -> List[CompositeDefinition]:
    var out = List[CompositeDefinition]()
    out.append(_level(String("acme.l3"), String("d"), String("")))
    out.append(_level(String("acme.l2"), String("c"), String("acme.l3")))
    out.append(_level(String("acme.l1"), String("b"), String("acme.l2")))
    out.append(_level(String("acme.l0"), String("a"), String("acme.l1")))
    out.append(_level(String("acme.big"), String("z"), String("acme.l0")))
    return out^


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


comptime _L0 = '{"id":"top","composite":{"definition":"acme.l0","version":"1"}}'


def test_one_over_the_limit_is_refused() raises:
    """Catches: no guard, a guard of `>=` or one that does not count the
    authored primitives, and a finding without the per-instance counts."""
    var x = expand(Catalog.v1(), _diamond(), _list(String('{"resource":[') + _L0 + ',{"id":"extra","bucket":{}}]}'))
    assert_equal(len(x.findings), 1)
    assert_equal(x.findings[0].resource_id, "(list)")
    assert_equal(
        x.findings[0].reason,
        "the list expands to more than 10000 primitives (top: 10000); split it, or share fewer instances of a definition",
    )
    assert_equal(len(x.resources), 0, "nothing is built")
    print("  test_one_over_the_limit_is_refused: PASS")


def test_far_over_the_limit_is_refused_at_once() raises:
    """Catches: a count that overflows or is not capped (100,000 would be
    built, or wrap), and a list of two instances each under the limit."""
    var big = expand(Catalog.v1(), _diamond(), _list(String('{"resource":[{"id":"big","composite":{"definition":"acme.big","version":"1"}}]}')))
    assert_equal(len(big.findings), 1)
    assert_true(big.findings[0].reason.find("(big: more than 10000)") >= 0, big.findings[0].reason)
    var two = expand(
        Catalog.v1(),
        _diamond(),
        _list(String('{"resource":[') + _L0 + ',{"id":"top2","composite":{"definition":"acme.l0","version":"1"}}]}'),
    )
    assert_equal(len(two.findings), 1)
    assert_true(two.findings[0].reason.find("(top: 10000, top2: 10000)") >= 0, two.findings[0].reason)
    print("  test_far_over_the_limit_is_refused_at_once: PASS")


def test_exactly_the_limit_is_expanded() raises:
    """Catches: a guard of `>=` (the boundary refused), and an expansion
    that loses or repeats primitives in a diamond."""
    var x = expand(Catalog.v1(), _diamond(), _list(String('{"resource":[') + _L0 + "]}"))
    assert_equal(len(x.findings), 0)
    assert_equal(len(x.resources), MAX_EXPANDED_PRIMITIVES)
    assert_equal(x.resources[0].id, "top/a0/b0/c0/d0")
    assert_equal(x.resources[len(x.resources) - 1].id, "top/a9/b9/c9/d9")
    print("  test_exactly_the_limit_is_expanded: PASS")


def main() raises:
    print("test_cloud_compose_size: the size guard")
    test_one_over_the_limit_is_refused()
    test_far_over_the_limit_is_refused_at_once()
    test_exactly_the_limit_is_expanded()
    print("ALL kci_cloud COMPOSE SIZE TESTS PASSED")
