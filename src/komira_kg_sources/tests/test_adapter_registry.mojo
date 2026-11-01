# =============================================================================
# test_adapter_registry.mojo -- AdapterRegistry over two made-up record types.
# =============================================================================
#
# The package ships no adapter; the two here (a journal of dated lines and a card
# of free text) live in the test, with a third that fails if it is ever called.
#
#   dispatch     each tag reaches its own adapter: the same bytes lower to
#                different episodes under the two tags, with the partition id the
#                caller gave, in the adapters' order, text verbatim; the
#                registered tags list in registration order.
#   unregistered a tag nobody registered (and the empty tag, and a near miss)
#                dispatches nothing: no value comes back and no adapter, the
#                failing one included, is called.
#   duplicates   an adapter whose tag is taken is refused, at any depth of the
#                chain, and so is a tag that is empty, has a control byte or is
#                over the size limit; the registry is unchanged.
#   failures     an adapter that cannot parse or lower its bytes raises through
#                the registry.
#   empty        the empty registry has no tag and dispatches nothing.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_kg import EpisodeInput
from komira_kg_sources import (
    EmptyAdapterRegistry,
    RawSurfaceAdapter,
    RegisteredAdapter,
    register,
)


@fieldwise_init
struct JournalEntry(Copyable, Movable):
    """One line of a made-up journal: the time it describes and its text."""

    var time: Int64
    var text: String


@fieldwise_init
struct Journal(Movable):
    """A made-up record: an id and dated entries."""

    var id: String
    var entries: List[JournalEntry]


@fieldwise_init
struct Card(Movable):
    """A second made-up record: a title and free text."""

    var title: String
    var text: String


def _utf8(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _lines(raw: List[UInt8]) -> List[String]:
    var out = List[String]()
    var cur = List[UInt8]()
    for i in range(len(raw)):
        if raw[i] == UInt8(10):
            out.append(String(unsafe_from_utf8=Span(cur)))
            cur.clear()
        else:
            cur.append(raw[i])
    out.append(String(unsafe_from_utf8=Span(cur)))
    return out^


def _entry(line: String) raises -> JournalEntry:
    var b = line.as_bytes()
    var time = Int64(0)
    var at = 0
    while at < len(b) and b[at] != UInt8(124):
        var d = Int(b[at]) - 48
        if d < 0 or d > 9:
            raise Error("journal entry '" + line + "' has no numeric time")
        time = time * Int64(10) + Int64(d)
        at += 1
    if at == len(b) or at == 0:
        raise Error("journal entry '" + line + "' is not time|text")
    var text = List[UInt8]()
    for i in range(at + 1, len(b)):
        text.append(b[i])
    return JournalEntry(time, String(unsafe_from_utf8=Span(text)))


struct JournalAdapter(RawSurfaceAdapter):
    """Reads `id`, then one `time|text` line per entry; one episode per entry."""

    comptime Source = Journal

    def __init__(out self):
        pass

    def surface_tag(self) -> String:
        return "test.journal"

    def parse(self, raw: List[UInt8]) raises -> Journal:
        var lines = _lines(raw)
        if len(lines[0].as_bytes()) == 0:
            raise Error("journal has no id")
        var entries = List[JournalEntry]()
        for i in range(1, len(lines)):
            entries.append(_entry(lines[i]))
        return Journal(lines[0].copy(), entries^)

    def lower(
        self, var source: Journal, partition_id: String
    ) raises -> List[EpisodeInput]:
        var out = List[EpisodeInput]()
        for i in range(len(source.entries)):
            out.append(
                EpisodeInput(
                    source.id + "#" + String(i),
                    partition_id,
                    source.entries[i].text.copy(),
                    Int64(1000),
                    source.entries[i].time,
                    "journal",
                    source.id,
                )
            )
        return out^


struct CardAdapter(RawSurfaceAdapter):
    """Reads a title line and then the text; one episode holding the text."""

    comptime Source = Card

    def __init__(out self):
        pass

    def surface_tag(self) -> String:
        return "test.card"

    def parse(self, raw: List[UInt8]) raises -> Card:
        var lines = _lines(raw)
        if len(lines) < 2:
            raise Error("card has no text")
        var text = String("")
        for i in range(1, len(lines)):
            if i > 1:
                text += "\n"
            text += lines[i]
        return Card(lines[0].copy(), text^)

    def lower(
        self, var source: Card, partition_id: String
    ) raises -> List[EpisodeInput]:
        var out = List[EpisodeInput]()
        out.append(
            EpisodeInput("card:" + source.title, partition_id, source.text.copy(), Int64(1000), Int64(7))
        )
        return out^


struct TrapAdapter(RawSurfaceAdapter):
    """Fails if it is ever asked to read anything."""

    comptime Source = Card

    def __init__(out self):
        pass

    def surface_tag(self) -> String:
        return "test.trap"

    def parse(self, raw: List[UInt8]) raises -> Card:
        raise Error("the trap adapter was called")

    def lower(
        self, var source: Card, partition_id: String
    ) raises -> List[EpisodeInput]:
        raise Error("the trap adapter was called")


struct FixedTagAdapter(RawSurfaceAdapter):
    """An adapter whose tag is configuration."""

    comptime Source = Card

    var tag: String

    def __init__(out self, var tag: String):
        self.tag = tag^

    def surface_tag(self) -> String:
        return self.tag.copy()

    def parse(self, raw: List[UInt8]) raises -> Card:
        return Card("t", "x")

    def lower(
        self, var source: Card, partition_id: String
    ) raises -> List[EpisodeInput]:
        return List[EpisodeInput]()


comptime Pair = RegisteredAdapter[CardAdapter, RegisteredAdapter[JournalAdapter, EmptyAdapterRegistry]]


def _pair() raises -> Pair:
    return register(register(EmptyAdapterRegistry(), JournalAdapter()), CardAdapter())


def test_each_tag_reaches_its_own_adapter() raises:
    var registry = _pair()
    var journal = registry.lower_raw("test.journal", _utf8("j1\n10|alpha beta\n20|gamma  \tdelta"), "part-9")
    assert_true(Bool(journal))
    var eps = journal.take()
    assert_equal(len(eps), 2)
    assert_equal(eps[0].uuid, "j1#0")
    assert_equal(eps[0].partition_id, "part-9")
    assert_equal(eps[0].body, "alpha beta")
    assert_equal(eps[0].valid_at, Int64(10))
    assert_equal(eps[0].facet, "journal")
    assert_equal(eps[0].facet_source, "j1")
    assert_equal(eps[1].uuid, "j1#1")
    assert_equal(eps[1].body, "gamma  \tdelta")
    assert_equal(eps[1].valid_at, Int64(20))

    var card = registry.lower_raw("test.card", _utf8("c1\nfirst line\nsecond"), "part-9")
    assert_true(Bool(card))
    var ceps = card.take()
    assert_equal(len(ceps), 1)
    assert_equal(ceps[0].uuid, "card:c1")
    assert_equal(ceps[0].body, "first line\nsecond")
    assert_equal(ceps[0].partition_id, "part-9")


def test_the_same_bytes_lower_differently_under_different_tags() raises:
    var registry = _pair()
    var bytes = _utf8("k\n5|hello")
    var journal = registry.lower_raw("test.journal", bytes, "p")
    var card = registry.lower_raw("test.card", bytes, "p")
    var as_journal = journal.take()
    var as_card = card.take()
    assert_equal(as_journal[0].uuid, "k#0")
    assert_equal(as_journal[0].body, "hello")
    assert_equal(as_card[0].uuid, "card:k")
    assert_equal(as_card[0].body, "5|hello")


def test_tags_list_in_registration_order() raises:
    var registry = _pair()
    var tags = registry.tags()
    assert_equal(len(tags), 2)
    assert_equal(tags[0], "test.journal")
    assert_equal(tags[1], "test.card")
    assert_true(registry.has_tag("test.journal"))
    assert_true(registry.has_tag("test.card"))
    assert_false(registry.has_tag("test.other"))


def test_an_unregistered_tag_dispatches_nothing() raises:
    var registry = register(_pair(), TrapAdapter())
    assert_true(registry.has_tag("test.trap"))
    assert_false(Bool(registry.lower_raw("test.unknown", _utf8("x\n1|y"), "p")))
    assert_false(Bool(registry.lower_raw("", _utf8("x\n1|y"), "p")))
    assert_false(Bool(registry.lower_raw("test.card ", _utf8("x\ny"), "p")))
    assert_false(Bool(registry.lower_raw("test.Card", _utf8("x\ny"), "p")))
    assert_false(registry.has_tag("test.unknown"))
    assert_false(registry.has_tag(""))
    # The trap is reachable under its own tag, so the silence above is not luck.
    with assert_raises(contains="the trap adapter was called"):
        _ = registry.lower_raw("test.trap", _utf8("x"), "p")


def test_a_duplicate_tag_is_refused_at_any_depth() raises:
    var registry = _pair()
    with assert_raises(contains="an adapter is already registered under 'test.card'"):
        _ = register(_pair(), CardAdapter())
    with assert_raises(contains="an adapter is already registered under 'test.journal'"):
        _ = register(_pair(), JournalAdapter())
    with assert_raises(contains="an adapter is already registered under 'test.journal'"):
        _ = register(register(EmptyAdapterRegistry(), JournalAdapter()), FixedTagAdapter("test.journal"))
    # The registry that was refused is as it was.
    assert_equal(len(registry.tags()), 2)
    var again = register(_pair(), FixedTagAdapter("test.fresh"))
    assert_equal(len(again.tags()), 3)
    assert_equal(again.tags()[2], "test.fresh")


def test_a_tag_that_cannot_be_stored_is_refused() raises:
    with assert_raises(contains="surface tag must not be empty"):
        _ = register(EmptyAdapterRegistry(), FixedTagAdapter(""))
    with assert_raises(contains="surface tag must not hold a control byte"):
        _ = register(EmptyAdapterRegistry(), FixedTagAdapter("a\nb"))
    var big = String("")
    for _ in range(65537):
        big += "x"
    with assert_raises(contains="surface tag is 65537 bytes"):
        _ = register(EmptyAdapterRegistry(), FixedTagAdapter(big))


def test_an_adapter_that_cannot_read_its_bytes_raises_through_the_registry() raises:
    var registry = _pair()
    with assert_raises(contains="journal has no id"):
        _ = registry.lower_raw("test.journal", _utf8("\n1|x"), "p")
    with assert_raises(contains="journal entry 'oops' has no numeric time"):
        _ = registry.lower_raw("test.journal", _utf8("j\noops"), "p")
    with assert_raises(contains="journal entry '5' is not time|text"):
        _ = registry.lower_raw("test.journal", _utf8("j\n5"), "p")
    with assert_raises(contains="journal entry '' is not time|text"):
        _ = registry.lower_raw("test.journal", _utf8("j\n"), "p")
    with assert_raises(contains="card has no text"):
        _ = registry.lower_raw("test.card", _utf8("only a title"), "p")


def test_the_empty_registry_has_no_tag_and_dispatches_nothing() raises:
    var empty = EmptyAdapterRegistry()
    assert_false(empty.has_tag("test.card"))
    assert_equal(len(empty.tags()), 0)
    assert_false(Bool(empty.lower_raw("test.card", _utf8("a\nb"), "p")))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
