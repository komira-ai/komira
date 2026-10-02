# =============================================================================
# tests/test_secret_store_port.mojo — the secret-store seam, bound from outside
#   any store implementation.
# =============================================================================
#
# This test's only dependencies are `komira_crypto` and this package. If
# anything reachable from `SecretStore` / `SecretValue` needed a store
# implementation, this target would fail to LINK.
#
# WHAT THIS FILE ADDS, that a link check cannot say:
#
#   1. A CONSUMER CAN BIND ITS OWN STORE. A struct declared HERE CONFORMS to
#      `SecretStore` and is accepted by a `[S: SecretStore]` generic. It is
#      checked at COMPILE time — if `SecretStore` had a supertype that a
#      consumer could not satisfy, `_resolve_through[LocalTestStore]` would not
#      compile.
#
#   2. THE SEAM'S BEHAVIOUR. Handle in / value out; an unknown ref RAISES rather
#      than yielding a silent empty value (fail-closed — a missing secret has no
#      benign default); a re-scripted ref resolves to the NEW value at the SAME
#      handle (the stable-handle property, which is what makes rotation work).
#
#   3. THE VALUE-HANDLING DISCIPLINE IS A PROPERTY OF THE TYPE. `SecretValue` is
#      the seam's return type. Pinned here: `Display` is redacted (an accidental
#      `print` is a no-op, not a leak), an over-length value RAISES rather than
#      silently truncating a credential, and the scoped `Span` reader reports
#      exactly the true length.
#
#   4. THE TYPE FIREWALL IS INTACT. `SecretMeta` (the catalog-facing record) has
#      no path to a `SecretValue` — it carries only NAMES, and its `Display`
#      renders them.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false, assert_raises

from komira_crypto import zeroize_inline_array

from komira_secret_store.secret_value import (
    MAX_SECRET_LEN,
    SecretMeta,
    SecretValue,
)
from komira_secret_store.secret_store import SecretStore, StaticSecretStore


# =============================================================================
# §1 — A conformer declared outside this package, with no store
#      implementation on this target's dependency path.
# =============================================================================
struct LocalTestStore(SecretStore, Movable):
    """A `SecretStore` conformer written HERE, in a target whose whole dep
    closure is `komira_crypto` + this package. Its existence is the proof that
    a consumer can bind its own store.

    Deliberately trivial — it answers one scripted handle and raises on anything
    else. The point is not what it does; it is that it COMPILES."""

    var _answer: String
    var _known_ref: String

    def __init__(out self, known_ref: String, answer: String):
        self._known_ref = known_ref
        self._answer = answer

    def resolve(mut self, secret_ref: String) raises -> SecretValue:
        if secret_ref != self._known_ref:
            raise Error(String("LocalTestStore: unknown ref ") + secret_ref)
        return SecretValue.from_string(self._answer)


def _resolve_through[S: SecretStore](mut store: S, ref_: String) raises -> Int:
    """A `[S: SecretStore]` generic — the shape every real consumer uses
    (a registry or connector generic over its store). Returns the revealed
    length so the caller can assert without the value escaping this frame."""
    var v = store.resolve(ref_)
    return v.len()


def test_consumer_can_declare_its_own_conformer() raises:
    """A conformer declared by a consumer satisfies the trait and is accepted
    by a `[S: SecretStore]` generic. If `SecretStore` had a supertype a
    consumer could not satisfy, this would not compile."""
    var store = LocalTestStore(String("prod-pg"), String("hunter2-hunter2"))
    var n = _resolve_through[LocalTestStore](store, String("prod-pg"))
    assert_equal(n, 15, "the seam round-trips through a [S: SecretStore] generic")


def test_shipped_double_conforms_the_same_trait() raises:
    """`StaticSecretStore` ships WITH the trait, because a trait whose only
    conformers live elsewhere could not be tested here at all. It must satisfy
    the SAME generic as the local conformer."""
    var store = StaticSecretStore()
    store.put(String("prod-pg"), String("scripted"))
    var n = _resolve_through[StaticSecretStore](store, String("prod-pg"))
    assert_equal(n, 8, "the shipped double satisfies the same [S: SecretStore]")


# =============================================================================
# §2 — THE SEAM'S BEHAVIOUR.
# =============================================================================
def test_unknown_ref_raises_rather_than_returning_empty() raises:
    """FAIL-CLOSED. A missing secret has no benign default, so an
    unresolvable ref RAISES. A silent empty `SecretValue` would be the dangerous
    failure — code downstream would authenticate with nothing."""
    var store = StaticSecretStore()
    store.put(String("known"), String("v"))
    with assert_raises():
        _ = store.resolve(String("no-such-ref"))


def test_stable_handle_resolves_to_the_new_value_after_rotation() raises:
    """THE STABLE-HANDLE PROPERTY — what makes rotation work. Re-scripting the
    SAME ref (the owner rotating the secret in the store) makes that ref
    resolve to the NEW value; the handle never changes."""
    var store = StaticSecretStore()
    store.put(String("prod-pg"), String("old"))
    var before = store.resolve(String("prod-pg"))
    assert_equal(before.len(), 3, "pre-rotation value")
    _ = before^

    store.put(String("prod-pg"), String("rotated-longer"))
    var after = store.resolve(String("prod-pg"))
    assert_equal(after.len(), 14, "the SAME handle now resolves to the NEW value")
    _ = after^

    assert_equal(store.resolve_count(), 2, "both resolves were observed")


def test_removed_ref_stops_resolving() raises:
    """The owner DELETING the secret from the store: the next resolve on
    that ref raises, rather than serving a stale cached value."""
    var store = StaticSecretStore()
    store.put(String("temp"), String("v"))
    _ = store.resolve(String("temp"))
    store.remove(String("temp"))
    with assert_raises():
        _ = store.resolve(String("temp"))


# =============================================================================
# §3 — THE VALUE-HANDLING DISCIPLINE IS A PROPERTY OF THE TYPE.
# =============================================================================
def test_display_is_redacted() raises:
    """An accidental `print(sv)` / log line / error-format is a NO-OP, not a
    leak. The guarantee is a property of the TYPE."""
    var sv = SecretValue.from_string(String("topsecretvalue"))
    var rendered = String(sv)
    assert_false(
        rendered.find(String("topsecretvalue")) >= 0,
        "the secret NEVER appears in Display",
    )
    assert_true(
        rendered.find(String("redacted")) >= 0, "Display says it is redacted"
    )
    _ = sv^


def test_over_length_value_raises_rather_than_truncating() raises:
    """Fail fast and loud. A silent truncation would corrupt a credential — the
    connection would then fail somewhere far from the cause."""
    var too_long = String("x") * (MAX_SECRET_LEN + 1)
    with assert_raises():
        _ = SecretValue.from_string(too_long)


def test_scoped_reader_reports_the_true_length() raises:
    """`revealed_bytes()` is the SOLE reader and is origin-bound to the value, so
    no owned plaintext copy escapes. It must expose EXACTLY the secret bytes —
    not the whole `MAX_SECRET_LEN` inline buffer."""
    var sv = SecretValue.from_string(String("abcde"))
    var span = sv.revealed_bytes()
    assert_equal(len(span), 5, "the span is the secret, not the buffer")
    assert_equal(Int(span[0]), Int(ord("a")), "first byte")
    assert_equal(Int(span[4]), Int(ord("e")), "last byte")
    _ = sv^


def test_zeroize_helper_is_reachable() raises:
    """`SecretValue`'s destructor calls `zeroize_inline_array`. That helper
    lives in `komira_crypto`, this package's one dependency; this pins that it
    is reachable and wipes every byte."""
    var buf = Array[UInt8, 64](fill=UInt8(0xCB))
    zeroize_inline_array(buf)
    for i in range(64):
        assert_equal(Int(buf[i]), 0, "every byte zeroed")


# =============================================================================
# §4 — THE TYPE FIREWALL.
# =============================================================================
def test_secret_meta_carries_names_only() raises:
    """`SecretMeta` is the catalog-facing record and has NO path to a
    `SecretValue`. Distinct type, no conversion — the firewall is in the TYPES,
    so a catalog surface cannot accidentally hold a value."""
    var meta = SecretMeta(String("prod-pg"), Int32(1), Int32(0))
    var rendered = String(meta)
    assert_true(
        rendered.find(String("prod-pg")) >= 0,
        "SecretMeta Display shows the handle — a NAME, safe to log",
    )


def main() raises:
    test_consumer_can_declare_its_own_conformer()
    test_shipped_double_conforms_the_same_trait()
    test_unknown_ref_raises_rather_than_returning_empty()
    test_stable_handle_resolves_to_the_new_value_after_rotation()
    test_removed_ref_stops_resolving()
    test_display_is_redacted()
    test_over_length_value_raises_rather_than_truncating()
    test_scoped_reader_reports_the_true_length()
    test_zeroize_helper_is_reachable()
    test_secret_meta_carries_names_only()
    print("PASS test_secret_store_port")
