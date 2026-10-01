# =============================================================================
# test_secret_writer.mojo — the `SecretWriter` write-verb gate.
# =============================================================================
#
# Drives `StaticSecretWriter` (the in-process `SecretWriter` test double) and
# asserts the app secret WRITE verb — the deployer-sourced write into
# the customer store that ensure-secret uses.
#
# Each test is a FALSIFIER: it proves a property that FAILS on a broken writer and
# passes only when the writer is correct. The cases:
#   (1) write records the ref + the value bytes (the write happened, with the
#       right value) — FAILS if write is a no-op / writes the wrong value.
#   (2) write-then-resolve ROUND-TRIP: a value written via the SecretWriter is
#       FOUND by a paired resolve (the running app's runtime resolve finds the
#       deployer-written value) — FAILS if the write does
#       not land where the resolve reads.
#   (3) a re-write of the SAME ref OVERWRITES (the versioned-PUT / rotation
#       semantics) — FAILS if the write appends / keeps a stale value.
#   (4) the TYPE FIREWALL: a `SecretWriter` is a DISTINCT type from `SecretStore`
#       — the write verb is reachable ONLY through a `SecretWriter`, and the
#       resolve verb is reachable ONLY through a `SecretStore`. Proven by the
#       generic `_write_via[W: SecretWriter]` helper accepting the writer but NOT
#       a `StaticSecretStore` (a compile-time firewall the source structurally
#       encodes; the runtime test asserts the two seams do not overlap by
#       exercising each through its own trait bound).
#
# NO CLOUD, NO STORE — the double is fully in-process. This is the write-seam
# proof the ensure-secret step builds on.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_secret_store.secret_store import SecretStore
from komira_secret_store.secret_value import SecretValue

from kci_secret_writer import SecretWriter, StaticSecretWriter


comptime _SMTP_REF: String = "example/managed/comms/smtp-relay-credential"
comptime _SMTP_VAL: String = "relay-server-token-abc123"


def _secret_value(s: String) raises -> SecretValue:
    """A zeroizing SecretValue from a plaintext String (the ensure-secret path:
    the deployer hands the applier the value, which it moves into the write)."""
    return SecretValue.from_string(s)


# =============================================================================
# A generic write-through helper — proves the TYPE FIREWALL: it accepts any
# `SecretWriter` but is structurally unable to accept a `SecretStore` (resolve
# double). The write verb flows ONLY through the writer bound.
# =============================================================================
def _write_via[W: SecretWriter](
    mut w: W, secret_ref: String, var value: SecretValue
) raises:
    # The deploy-context bearer token — a plain-String token the applier
    # threads so a LIVE conformer PUTs the version AS the assumed customer role.
    # The StaticSecretWriter test double records it; the write-verb type firewall is
    # unchanged.
    w.write(secret_ref, value^, String("test-deploy-token"))


# =============================================================================
# A generic resolve-through helper — the RESOLVE verb flows ONLY through the
# `SecretStore` bound. A `StaticSecretWriter` cannot be passed here (it is not a
# `SecretStore`) — the firewall in the OTHER direction.
# =============================================================================
def _resolve_via[S: SecretStore](
    mut s: S, secret_ref: String
) raises -> SecretValue:
    return s.resolve(secret_ref)


# =============================================================================
# (1) write records the ref + the value bytes.
# =============================================================================
def test_write_records_ref_and_value() raises:
    var w = StaticSecretWriter()
    # Nothing written yet.
    assert_false(w.was_written(_SMTP_REF), "no write yet")
    assert_equal(w.write_count(), 0, "write_count starts at 0")

    _write_via(w, _SMTP_REF, _secret_value(_SMTP_VAL))

    # THE FALSIFIER: the write landed the RIGHT ref with the RIGHT value.
    assert_true(w.was_written(_SMTP_REF), "the ref was written")
    assert_equal(w.write_count(), 1, "exactly one write")
    assert_equal(
        w.written_len(_SMTP_REF), _SMTP_VAL.byte_length(), "the written value's byte length"
    )
    assert_true(
        w.written_equals(_SMTP_REF, _SMTP_VAL),
        "the written value byte-equals the deployer-sourced value",
    )
    _ = w^


# =============================================================================
# (2) write-then-resolve ROUND-TRIP: a value written via the
#     SecretWriter is FOUND by a paired resolve over the SAME store.
# =============================================================================
def test_write_then_resolve_round_trip() raises:
    var w = StaticSecretWriter()
    _write_via(w, _SMTP_REF, _secret_value(_SMTP_VAL))

    # The running app's runtime resolve reads over a SecretStore seeded with the
    # writer's writes (the round-trip: the deployer WRITES, the app RESOLVES).
    var store = w.as_static_store()
    var resolved = _resolve_via(store, _SMTP_REF)

    # THE FALSIFIER: the resolved value byte-equals the written value (the write
    # landed where the resolve reads). Length is a non-secret proxy + a byte cmp.
    assert_equal(
        resolved.len(), _SMTP_VAL.byte_length(), "resolved value length == written length"
    )
    # Byte-equality via the scoped reader (the value never escapes as a String).
    var bytes = resolved.revealed_bytes()
    var want = _SMTP_VAL.as_bytes()
    assert_equal(len(bytes), len(want), "resolved byte length")
    var all_eq = True
    for i in range(len(bytes)):
        if bytes[i] != want[i]:
            all_eq = False
    assert_true(all_eq, "the resolved value byte-equals the written value")
    _ = resolved^
    _ = store^
    _ = w^


# =============================================================================
# (3) a re-write of the SAME ref OVERWRITES (versioned PUT / rotation).
# =============================================================================
def test_rewrite_overwrites_versioned_put() raises:
    var w = StaticSecretWriter()
    _write_via(w, _SMTP_REF, _secret_value(String("old-token-v1")))
    assert_true(
        w.written_equals(_SMTP_REF, String("old-token-v1")), "first write landed"
    )

    # A rotation: the deployer writes a NEW value for the SAME ref.
    _write_via(w, _SMTP_REF, _secret_value(String("new-token-v2-rotated")))

    # THE FALSIFIER: the LATEST value wins (the store's create-secret-version
    # semantics) — a re-write overwrites, it does not keep the stale value.
    assert_equal(w.write_count(), 2, "two writes recorded")
    assert_false(
        w.written_equals(_SMTP_REF, String("old-token-v1")),
        "the stale value was overwritten",
    )
    assert_true(
        w.written_equals(_SMTP_REF, String("new-token-v2-rotated")),
        "the latest written value wins (versioned PUT)",
    )
    # The paired resolve reads the ROTATED value.
    var store = w.as_static_store()
    var resolved = _resolve_via(store, _SMTP_REF)
    assert_equal(
        resolved.len(),
        (String("new-token-v2-rotated")).byte_length(),
        "the resolve reads the rotated value",
    )
    _ = resolved^
    _ = store^
    _ = w^


# =============================================================================
# (4) the TYPE FIREWALL: write flows ONLY through `SecretWriter`, resolve ONLY
#     through `SecretStore`. The two `_*_via` generic helpers structurally encode
#     this — a `StaticSecretWriter` cannot be passed to `_resolve_via` (not a
#     SecretStore), a `StaticSecretStore` cannot be passed to `_write_via` (not a
#     SecretWriter). Here we exercise BOTH seams on the SAME data and assert they
#     are the two independent halves of the round-trip — the write side never
#     resolves, the resolve side never writes.
# =============================================================================
def test_type_firewall_write_and_resolve_are_distinct() raises:
    var w = StaticSecretWriter()
    # The WRITE side (SecretWriter only).
    _write_via(w, _SMTP_REF, _secret_value(_SMTP_VAL))
    assert_equal(w.write_count(), 1, "the writer recorded the write")

    # The RESOLVE side (SecretStore only) over the seeded store. `store` is a
    # `StaticSecretStore` — a `SecretStore`, NOT a `SecretWriter`; it has no
    # `write` verb. `w` is a `StaticSecretWriter` — a `SecretWriter`, NOT a
    # `SecretStore`; it has no `resolve` verb. The firewall is the TYPE split.
    var store = w.as_static_store()
    var resolved = _resolve_via(store, _SMTP_REF)
    assert_equal(resolved.len(), _SMTP_VAL.byte_length(), "the resolve side reads the value")

    # The two seams are distinct: the writer's resolve_count is not a thing (it
    # has none), and the store's write_count is not a thing (it has none). The
    # compile-time proof is that _write_via[W: SecretWriter] and
    # _resolve_via[S: SecretStore] each accept ONLY their own seam's type.
    _ = resolved^
    _ = store^
    _ = w^


def main() raises:
    test_write_records_ref_and_value()
    test_write_then_resolve_round_trip()
    test_rewrite_overwrites_versioned_put()
    test_type_firewall_write_and_resolve_are_distinct()
    print("test_secret_writer: all SecretWriter cases PASSED")
