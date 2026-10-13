# =============================================================================
# komira_secret_registry/tests/test_secret_bindings.mojo: the store-less
#   `SecretBindings` table and its lift into a `SecretRegistry`, record by
#   record.
# =============================================================================
#
# Every check compares a WHOLE table against an expected list of rows built
# here from literals (never with the product's `SecretRegistryEntry`
# constructor, so a constructor that swaps or drops a field cannot also build
# its own expectation):
#
#   * `_assert_bindings` reads every row through the public accessors
#     (`num_entries`, `node_id_at`, `has_binding`, `name_handle_for`,
#     `secret_ref_for`) and asks every pool node id that is NOT in the table
#     too: unbound reads answer `False` / `""`.
#   * `_assert_registry` reads every field of every `SecretRegistryEntry` the
#     registry holds (its `_entries` slab, white box: the registry has no
#     public read of `name_handle`), then reveals every bound node (exact
#     bytes, exactly one resolve each) and every unbound pool node (raises
#     with the node id, no resolve, no consume).
#
# The grid: a left table of 0..2 rows `merge_from` a right table of 0..2 rows
# (9 cells). The pool's rows differ in kind: node id 0 and a negative id beside
# positive ones (so a node id is never mistaken for a list index), and one row
# whose handle, ref and secret are all empty strings (so `name_handle_for`
# answering `""` for a BOUND row is told apart from an unbound one by
# `has_binding`). Every cell runs through every checker: the merged table, its
# `clone`, and the registry `from_bindings` lifts out of it.
#
# Offline and in-process: no sockets, no files, no cloud.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false, assert_raises

from komira_secret_registry.secret_bindings import (
    SecretBindings,
    SecretRegistryEntry,
)
from komira_secret_registry.credential_consumer import CredentialConsumer
from komira_secret_registry.secret_registry import SecretRegistry

from komira_secret_store.secret_store import StaticSecretStore


comptime _Registry = SecretRegistry[StaticSecretStore]

# A node id no pool row uses, and one equal to a list index (1) no row uses.
def _absent_ids() -> List[Int]:
    var ids = List[Int]()
    ids.append(77)
    ids.append(1)
    return ids^


@fieldwise_init
struct _Row(Copyable, Movable):
    """An expected binding plus the secret its ref resolves to."""

    var node_id: Int
    var name_handle: String
    var secret_ref: String
    var secret: String


def _pool() -> List[_Row]:
    """Four rows: ids 5, 0, -3, 9; row 1 is the all-empty kind."""
    var p = List[_Row]()
    p.append(_Row(5, "warehouse", "ref-a", "sec-a"))
    p.append(_Row(0, "", "", ""))
    p.append(_Row(-3, "bucket", "ref-c", "sec-c-longer"))
    p.append(_Row(9, "queue", "ref-d", "sec-d"))
    return p^


def _slice(pool: List[_Row], start: Int, n: Int) -> List[_Row]:
    var out = List[_Row]()
    for i in range(start, start + n):
        out.append(pool[i].copy())
    return out^


def _table(rows: List[_Row]) -> SecretBindings:
    var b = SecretBindings()
    for i in range(len(rows)):
        b.bind(rows[i].node_id, rows[i].name_handle, rows[i].secret_ref)
    return b^


def _contains(rows: List[_Row], node_id: Int) -> Bool:
    for i in range(len(rows)):
        if rows[i].node_id == node_id:
            return True
    return False


def _assert_bindings(
    b: SecretBindings, rows: List[_Row], pool: List[_Row], what: String
) raises:
    """`b` holds exactly `rows`, in order, every field; every pool id outside
    `rows` and every `_absent_ids()` id is unbound."""
    assert_equal(b.num_entries(), len(rows), what + ": num_entries")
    for i in range(len(rows)):
        var id = rows[i].node_id
        var at = what + " row " + String(i)
        assert_equal(b.node_id_at(i), id, at + ": node_id_at")
        assert_true(b.has_binding(id), at + ": has_binding")
        assert_equal(b.name_handle_for(id), rows[i].name_handle, at + ": name_handle_for")
        assert_equal(b.secret_ref_for(id), rows[i].secret_ref, at + ": secret_ref_for")
    var unbound = List[Int]()
    for i in range(len(pool)):
        if not _contains(rows, pool[i].node_id):
            unbound.append(pool[i].node_id)
    var absent = _absent_ids()
    for k in range(len(absent)):
        unbound.append(absent[k])
    for k in range(len(unbound)):
        var id = unbound[k]
        var at = what + " unbound " + String(id)
        assert_false(b.has_binding(id), at + ": has_binding")
        assert_equal(b.name_handle_for(id), String(""), at + ": name_handle_for")
        assert_equal(b.secret_ref_for(id), String(""), at + ": secret_ref_for")


struct _RecordingConsumer(CredentialConsumer, Movable):
    """Copies the revealed bytes out of the scoped `Span` and counts calls."""

    var seen: List[UInt8]
    var consume_count: Int

    def __init__(out self):
        self.seen = List[UInt8]()
        self.consume_count = 0

    def consume(mut self, secret: Span[UInt8, _]) raises:
        self.consume_count += 1
        self.seen = List[UInt8]()
        for i in range(len(secret)):
            self.seen.append(secret[i])


def _store_for(pool: List[_Row]) -> StaticSecretStore:
    """A store scripting every pool row's `secret_ref -> secret`."""
    var store = StaticSecretStore()
    for i in range(len(pool)):
        store.put(pool[i].secret_ref, pool[i].secret)
    return store^


def _assert_registry(
    mut reg: _Registry,
    probe: StaticSecretStore,
    rows: List[_Row],
    pool: List[_Row],
    what: String,
) raises:
    """`reg` holds exactly `rows`, in order, every field of every entry; each
    bound node reveals its own secret with one resolve; each unbound pool node
    and `_absent_ids()` id raises before the store and the consumer."""
    assert_equal(reg.num_entries(), len(rows), what + ": num_entries")
    for i in range(len(rows)):
        var at = what + " entry " + String(i)
        assert_equal(reg._entries[i].secret_node_id, rows[i].node_id, at + ": node_id")
        assert_equal(reg._entries[i].name_handle, rows[i].name_handle, at + ": name_handle")
        assert_equal(reg._entries[i].secret_ref, rows[i].secret_ref, at + ": secret_ref")
    for i in range(len(rows)):
        var id = rows[i].node_id
        var at = what + " reveal " + String(id)
        assert_true(reg.has_binding(id), at + ": has_binding")
        var before = probe.resolve_count()
        var consumer = _RecordingConsumer()
        reg.reveal_for[_RecordingConsumer](id, consumer)
        assert_equal(consumer.consume_count, 1, at + ": consumed once")
        var want = rows[i].secret.as_bytes()
        assert_equal(len(consumer.seen), len(want), at + ": byte count")
        for j in range(len(want)):
            assert_equal(consumer.seen[j], want[j], at + ": byte")
        assert_equal(probe.resolve_count(), before + 1, at + ": one resolve")
    var unbound = List[Int]()
    for i in range(len(pool)):
        if not _contains(rows, pool[i].node_id):
            unbound.append(pool[i].node_id)
    var absent = _absent_ids()
    for k in range(len(absent)):
        unbound.append(absent[k])
    for k in range(len(unbound)):
        var id = unbound[k]
        var at = what + " unbound " + String(id)
        assert_false(reg.has_binding(id), at + ": has_binding")
        var before = probe.resolve_count()
        var consumer = _RecordingConsumer()
        with assert_raises(contains="no secret binding for node_id " + String(id) + " "):
            reg.reveal_for[_RecordingConsumer](id, consumer)
        assert_equal(probe.resolve_count(), before, at + ": store not asked")
        assert_equal(consumer.consume_count, 0, at + ": consumer not called")


def test_entry_constructor_sets_every_field() raises:
    var e = SecretRegistryEntry(-4, "handle-x", "ref-y")
    assert_equal(e.secret_node_id, -4, "node id")
    assert_equal(e.name_handle, "handle-x", "name handle")
    assert_equal(e.secret_ref, "ref-y", "secret ref")
    var c = e.copy()
    assert_equal(c.secret_node_id, -4, "copy: node id")
    assert_equal(c.name_handle, "handle-x", "copy: name handle")
    assert_equal(c.secret_ref, "ref-y", "copy: secret ref")


def test_empty_table_binds_nothing() raises:
    var pool = _pool()
    _assert_bindings(SecretBindings(), List[_Row](), pool, "empty")


def test_bind_then_merge_grid() raises:
    """Left 0..2 rows `merge_from` right 0..2 rows: the merged table is left's
    rows then right's, every field; its clone is equal and independent; the
    registry lifted from it holds and reveals exactly those rows."""
    var pool = _pool()
    for nl in range(3):
        for nr in range(3):
            var what = "grid l" + String(nl) + " r" + String(nr)
            var left_rows = _slice(pool, 0, nl)
            var right_rows = _slice(pool, 2, nr)
            var left = _table(left_rows)
            var right = _table(right_rows)
            _assert_bindings(left, left_rows, pool, what + " left")
            _assert_bindings(right, right_rows, pool, what + " right")

            var want = left_rows.copy()
            for i in range(len(right_rows)):
                want.append(right_rows[i].copy())
            left.merge_from(right^)
            _assert_bindings(left, want, pool, what + " merged")

            var twin = left.clone()
            _assert_bindings(twin, want, pool, what + " clone")
            twin.bind(77, "late", "ref-late")
            _assert_bindings(left, want, pool, what + " original after clone bind")

            var store = _store_for(pool)
            var probe = store.share()
            var reg = _Registry.from_bindings(store^, left)
            _assert_bindings(left, want, pool, what + " bindings after lift")
            _assert_registry(reg, probe, want, pool, what + " registry")


def test_clone_does_not_share_with_the_original() raises:
    """A bind on the ORIGINAL after a clone leaves the clone unchanged too."""
    var pool = _pool()
    var rows = _slice(pool, 0, 2)
    var b = _table(rows)
    var twin = b.clone()
    b.bind(77, "late", "ref-late")
    _assert_bindings(twin, rows, pool, "clone after original bind")
    assert_equal(b.num_entries(), 3, "the original grew")
    assert_equal(b.secret_ref_for(77), "ref-late", "the original's new row")


def test_register_appends_every_field_in_order() raises:
    """`register` on a bare registry, all four pool rows: the same whole-table
    check as the lifted registry."""
    var pool = _pool()
    var store = _store_for(pool)
    var probe = store.share()
    var reg = _Registry(store^)
    for i in range(len(pool)):
        reg.register(pool[i].node_id, pool[i].name_handle, pool[i].secret_ref)
    _assert_registry(reg, probe, pool, pool, "register x4")


def main() raises:
    test_entry_constructor_sets_every_field()
    test_empty_table_binds_nothing()
    test_bind_then_merge_grid()
    test_clone_does_not_share_with_the_original()
    test_register_appends_every_field_in_order()
    print(
        "PASS test_secret_bindings (entry fields, empty table, merge grid 3x3"
        " with clone and lift, clone independence, register x4)"
    )
