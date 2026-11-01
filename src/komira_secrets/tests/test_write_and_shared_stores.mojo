# =============================================================================
# test_write_and_shared_stores.mojo -- SecretWriteStore, its in-memory double
#   and SharedMemorySecretStore.
# =============================================================================
#
#   write double   put returns the name as the handle, records the value and
#                  counts the call; the last write under a name wins in
#                  value_for; any_value_equals sees only values that were put;
#                  a share()d handle reads and extends the same log.
#   shared store   a value put through one handle resolves through it and through
#                  a share()d handle; resolve mints a fresh value each call that
#                  holds the written bytes; a rotation replaces the value; an
#                  unknown ref raises naming the ref but never a value; has()
#                  probes without raising; counters count puts and resolves
#                  (a failed resolve included) across handles.
#   traits         both stores satisfy SecretWriteStore, and the shared store
#                  also satisfies SecretStore, through generic code.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_secret_store import SecretStore, SecretValue

from komira_secrets import (
    InMemorySecretWriteStore,
    SecretWriteStore,
    SharedMemorySecretStore,
)


def _text(v: SecretValue) -> String:
    var out = String()
    var b = v.revealed_bytes()
    for i in range(len(b)):
        out += chr(Int(b[i]))
    return out^


def _resolve_error(mut s: SharedMemorySecretStore, ref_: String) -> String:
    try:
        _ = s.resolve(ref_)
    except e:
        return String(e)
    return String("<returned>")


def _write_through[W: SecretWriteStore](mut w: W, name: String) raises -> String:
    return w.put(name, String("v-") + name)


def _read_through[S: SecretStore](mut s: S, ref_: String) raises -> String:
    return _text(s.resolve(ref_))


def test_write_double_records_puts() raises:
    var w = InMemorySecretWriteStore()
    assert_equal(w.put_count(), 0)
    assert_equal(w.num_writes(), 0)
    assert_equal(w.value_for(String("a")), String(""), "nothing written yet")

    var handle = w.put(String("a"), String("one"))
    assert_equal(handle, String("a"), "the handle is the name")
    assert_equal(w.put_count(), 1)
    assert_equal(w.num_writes(), 1)
    assert_equal(w.value_for(String("a")), String("one"))
    assert_equal(w.value_for(String("b")), String(""), "another name is empty")

    _ = w.put(String("b"), String("two"))
    _ = w.put(String("a"), String("three"))
    assert_equal(w.put_count(), 3)
    assert_equal(w.num_writes(), 3)
    assert_equal(w.value_for(String("a")), String("three"), "the last write wins")
    assert_equal(w.value_for(String("b")), String("two"))

    assert_true(w.any_value_equals(String("two")))
    assert_true(w.any_value_equals(String("one")), "an overwritten value was put")
    assert_false(w.any_value_equals(String("never-put")))
    assert_false(w.any_value_equals(String("tw")), "a prefix is not equal")


def test_write_double_share_is_one_log() raises:
    var w = InMemorySecretWriteStore()
    var spy = w.share()
    _ = w.put(String("a"), String("one"))
    assert_equal(spy.put_count(), 1, "the spy sees the write")
    assert_equal(spy.value_for(String("a")), String("one"))
    var h = spy.put(String("b"), String("two"))
    assert_equal(h, String("b"))
    assert_equal(w.put_count(), 2, "the original sees the spy's write")
    assert_equal(w.num_writes(), 2)
    assert_true(w.any_value_equals(String("two")))


def test_shared_store_put_then_resolve() raises:
    var s = SharedMemorySecretStore()
    assert_false(s.has(String("tok")))
    var handle = s.put(String("tok"), String("hunter2"))
    assert_equal(handle, String("tok"), "the handle is the name")
    assert_true(s.has(String("tok")))
    assert_false(s.has(String("other")))

    var v = s.resolve(String("tok"))
    assert_equal(v.len(), 7)
    assert_equal(_text(v), String("hunter2"))
    assert_equal(String(v), String("SecretValue(<redacted:7B>)"))

    var again = s.resolve(String("tok"))
    assert_equal(_text(again), String("hunter2"), "each resolve mints a value")

    _ = s.put(String("empty"), String(""))
    assert_true(s.has(String("empty")))
    assert_equal(s.resolve(String("empty")).len(), 0)


def test_shared_store_handles_see_one_state() raises:
    var writer = SharedMemorySecretStore()
    var reader = writer.share()
    _ = writer.put(String("acct"), String("t-1"))
    assert_true(reader.has(String("acct")), "the reader sees the write")
    assert_equal(_text(reader.resolve(String("acct"))), String("t-1"))

    _ = reader.put(String("acct"), String("t-2"))
    assert_equal(
        _text(writer.resolve(String("acct"))),
        String("t-2"),
        "a rotation through the other handle is read",
    )
    assert_equal(writer.put_count(), 2)
    assert_equal(reader.put_count(), 2)
    assert_equal(writer.resolve_count(), 2)
    assert_equal(reader.resolve_count(), 2)


def test_shared_store_unknown_ref_raises() raises:
    var s = SharedMemorySecretStore()
    _ = s.put(String("known"), String("canary-value"))
    var msg = _resolve_error(s, String("missing"))
    assert_equal(msg, String("SharedMemorySecretStore: no secret for missing"))
    assert_false(msg.find(String("canary-value")) >= 0, "no value in the error")
    assert_equal(s.resolve_count(), 1, "a failed resolve is counted")
    assert_false(s.has(String("missing")), "the failed resolve stored nothing")


def test_generic_code_accepts_the_stores() raises:
    var w = InMemorySecretWriteStore()
    assert_equal(_write_through(w, String("k")), String("k"))
    assert_equal(w.value_for(String("k")), String("v-k"))

    var s = SharedMemorySecretStore()
    assert_equal(_write_through(s, String("k")), String("k"))
    assert_equal(_read_through(s, String("k")), String("v-k"))


def main() raises:
    test_write_double_records_puts()
    test_write_double_share_is_one_log()
    test_shared_store_put_then_resolve()
    test_shared_store_handles_see_one_state()
    test_shared_store_unknown_ref_raises()
    test_generic_code_accepts_the_stores()
    print("PASS test_write_and_shared_stores")
