# =============================================================================
# test_claims_principal.mojo — the opaque identity carriers: `Claims`,
# `Principal`, and the two `RequestContext` constructors that start them empty.
# =============================================================================
#
# Every function and both arms of every branch in `Claims` and `Principal` are
# reached here:
#   - `Claims.set` on a new key (append) and on an existing key (replace in
#     place: the length stays, the first-set order stays, the value changes);
#   - `Claims.get` and `Claims.has` on a present and on an absent key;
#   - `Claims.len`, `key_at`, `value_at` in insertion order;
#   - `Principal(subject)`, `Principal(subject, claims)` and `with_claim`;
#   - `RequestContext.new()` and `.for_worker(n)`: no principal, no attributes.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http_server.middleware import Claims, Principal, RequestContext


def test_empty_claims_hold_nothing() raises:
    var c = Claims()
    assert_equal(c.len(), 0)
    assert_false(c.has(String("a")), "an empty map has no key")
    assert_false(Bool(c.get(String("a"))), "get on an absent key is None")


def test_set_appends_new_keys_in_order() raises:
    var c = Claims()
    c.set(String("a"), String("1"))
    c.set(String("b"), String("2"))
    assert_equal(c.len(), 2)
    assert_equal(c.key_at(0), String("a"))
    assert_equal(c.value_at(0), String("1"))
    assert_equal(c.key_at(1), String("b"))
    assert_equal(c.value_at(1), String("2"))
    assert_true(c.has(String("b")))
    assert_true(Bool(c.get(String("b"))), "a set key reads Some")
    assert_equal(c.get(String("b")).value(), String("2"))
    # Lookup is by whole-key equality.
    assert_false(c.has(String("")), "the empty key was never set")
    assert_false(Bool(c.get(String("c"))), "an unset key reads None")


def test_set_replaces_in_place() raises:
    var c = Claims()
    c.set(String("a"), String("1"))
    c.set(String("b"), String("2"))
    c.set(String("a"), String("3"))
    assert_equal(c.len(), 2, "replacing a key does not add an entry")
    assert_equal(c.key_at(0), String("a"), "the first-set order is kept")
    assert_equal(c.value_at(0), String("3"), "the later value wins")
    assert_true(Bool(c.get(String("a"))), "a replaced key still reads Some")
    assert_equal(c.get(String("a")).value(), String("3"))
    assert_equal(c.value_at(1), String("2"), "the other key is untouched")


def test_principal_constructors_and_with_claim() raises:
    var bare = Principal(String("svc-1"))
    assert_equal(bare.subject, String("svc-1"))
    assert_equal(bare.claims.len(), 0, "a bare principal carries no claims")

    var c = Claims()
    c.set(String("role"), String("reader"))
    var given = Principal(String("svc-2"), c^)
    assert_equal(given.subject, String("svc-2"))
    assert_true(Bool(given.claims.get(String("role"))), "the constructor keeps the claims it is given")
    assert_equal(given.claims.get(String("role")).value(), String("reader"))

    var built = Principal(String("svc-3")).with_claim(
        String("role"), String("writer")
    ).with_claim(String("role"), String("admin"))
    assert_equal(built.subject, String("svc-3"))
    assert_equal(built.claims.len(), 1, "with_claim replaces an existing key")
    assert_true(Bool(built.claims.get(String("role"))), "with_claim stores the claim")
    assert_equal(built.claims.get(String("role")).value(), String("admin"))


def test_request_context_starts_unauthenticated() raises:
    var a = RequestContext.new()
    assert_false(Bool(a.principal), "new(): no principal until a middleware sets one")
    assert_equal(a.attributes.len(), 0)
    assert_equal(a.worker_id, 0)

    var b = RequestContext.for_worker(3)
    assert_false(Bool(b.principal), "for_worker(): no principal either")
    assert_equal(b.attributes.len(), 0)
    assert_equal(b.worker_id, 3)


def main() raises:
    test_empty_claims_hold_nothing()
    test_set_appends_new_keys_in_order()
    test_set_replaces_in_place()
    test_principal_constructors_and_with_claim()
    test_request_context_starts_unauthenticated()
    print("PASS test_claims_principal")
