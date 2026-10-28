# A generated message must survive being copied as a LIST ELEMENT.
#
# Mojo 1.0.0 treats a struct's synthesized copy constructor as trivial for
# some layouts (three Optional[String] plus one scalar Optional, in a struct
# with an explicit `__deinit__`), and then `List.copy()` copies
# the elements with a memcpy: the copy and the original share String buffers,
# dropping the copy frees them under the original, and a same-size allocation
# reuses the buffer. Every String below is longer than the inline capacity, so
# it owns a heap buffer.
#
# Each case: build a list, copy it, drop the copy, allocate same-size Strings to reuse any freed buffer, then read
# the originals back.
from copy_hazard_proto.copy_hazard import (
    Color,
    Everything,
    Leaf,
    OptStrings,
    OptStringsInt,
    PlainStrings,
)
from std.testing import assert_equal, assert_true

comptime N = 8


def pad(s: String) -> String:
    var out = s
    while out.byte_length() < 48:
        out += "."
    return out


def churn(n: Int) -> List[String]:
    var out = List[String]()
    for i in range(n):
        out.append(pad(String("CHURN") + String(i)))
    return out^


def opt(s: String) -> Optional[String]:
    return Optional[String](pad(s))


def copy_and_drop[T: Copyable & Deinitable](items: List[T]):
    # `List.copy()`, then drop the copy.
    var a = items.copy()
    _ = a^


def check_opt_strings() raises:
    var items = List[OptStrings]()
    for i in range(N):
        items.append(
            OptStrings(
                a=opt(String("a") + String(i)),
                b=opt(String("b") + String(i)),
                c=opt(String("c") + String(i)),
                d=Optional[Bool](True),
            )
        )
    copy_and_drop(items)
    var junk = churn(256)
    for i in range(N):
        assert_equal(items[i].a.value(), pad(String("a") + String(i)))
        assert_equal(items[i].b.value(), pad(String("b") + String(i)))
        assert_equal(items[i].c.value(), pad(String("c") + String(i)))
        assert_true(items[i].d.value())
    assert_equal(len(junk), 256)


def check_opt_strings_int() raises:
    var items = List[OptStringsInt]()
    for i in range(N):
        items.append(
            OptStringsInt(
                a=opt(String("a") + String(i)),
                b=opt(String("b") + String(i)),
                c=opt(String("c") + String(i)),
                d=Optional[Int64](Int64(i)),
            )
        )
    copy_and_drop(items)
    var junk = churn(256)
    for i in range(N):
        assert_equal(items[i].a.value(), pad(String("a") + String(i)))
        assert_equal(items[i].b.value(), pad(String("b") + String(i)))
        assert_equal(items[i].c.value(), pad(String("c") + String(i)))
        assert_equal(Int(items[i].d.value()), i)
    assert_equal(len(junk), 256)


def check_plain_strings() raises:
    var items = List[PlainStrings]()
    for i in range(N):
        items.append(
            PlainStrings(
                a=pad(String("a") + String(i)),
                b=pad(String("b") + String(i)),
                c=pad(String("c") + String(i)),
                d=True,
            )
        )
    copy_and_drop(items)
    var junk = churn(256)
    for i in range(N):
        assert_equal(items[i].a, pad(String("a") + String(i)))
        assert_equal(items[i].b, pad(String("b") + String(i)))
        assert_equal(items[i].c, pad(String("c") + String(i)))
    assert_equal(len(junk), 256)


def check_everything() raises:
    var items = List[Everything]()
    for i in range(N):
        var tags = List[String]()
        tags.append(pad(String("t0-") + String(i)))
        tags.append(pad(String("t1-") + String(i)))
        var labels = Dict[String, String]()
        labels[pad(String("k") + String(i))] = pad(String("v") + String(i))
        var leaves = List[Leaf]()
        leaves.append(Leaf(name=pad(String("l0-") + String(i))))
        leaves.append(Leaf(name=pad(String("l1-") + String(i))))
        var blob = List[UInt8]()
        for j in range(64):
            blob.append(UInt8(j))
        items.append(
            Everything(
                id=pad(String("id") + String(i)),
                tags=tags^,
                labels=labels^,
                leaf=Optional[Leaf](Leaf(name=pad(String("leaf") + String(i)))),
                leaves=leaves^,
                note=opt(String("note") + String(i)),
                color=Color(1),
                blob=blob^,
                _oneof0_case=2,
                text=None,
                node=Optional[Leaf](Leaf(name=pad(String("node") + String(i)))),
                number=None,
            )
        )
    copy_and_drop(items)
    var junk = churn(256)
    for i in range(N):
        assert_equal(items[i].id, pad(String("id") + String(i)))
        assert_equal(items[i].tags[0], pad(String("t0-") + String(i)))
        assert_equal(items[i].tags[1], pad(String("t1-") + String(i)))
        assert_equal(
            items[i].labels[pad(String("k") + String(i))],
            pad(String("v") + String(i)),
        )
        assert_equal(
            items[i].leaf.value().name, pad(String("leaf") + String(i))
        )
        assert_equal(items[i].leaves[0].name, pad(String("l0-") + String(i)))
        assert_equal(items[i].leaves[1].name, pad(String("l1-") + String(i)))
        assert_equal(items[i].note.value(), pad(String("note") + String(i)))
        assert_equal(items[i].color.value, 1)
        assert_equal(len(items[i].blob), 64)
        assert_equal(items[i]._oneof0_case, 2)
        assert_equal(
            items[i].node.value().name, pad(String("node") + String(i))
        )
    assert_equal(len(junk), 256)


def main() raises:
    # Run every layout and name each failing one, so a regression says which
    # shape broke rather than only the first.
    var failed = 0
    try:
        check_opt_strings()
    except e:
        print("FAIL OptStrings:", e)
        failed += 1
    try:
        check_opt_strings_int()
    except e:
        print("FAIL OptStringsInt:", e)
        failed += 1
    try:
        check_plain_strings()
    except e:
        print("FAIL PlainStrings:", e)
        failed += 1
    try:
        check_everything()
    except e:
        print("FAIL Everything:", e)
        failed += 1
    if failed > 0:
        raise Error(String(failed) + " layout(s) corrupted by List.copy()")
    print("test_copy_hazard: PASS")
