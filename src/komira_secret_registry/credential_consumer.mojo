# =============================================================================
# komira_secret_registry/credential_consumer.mojo: the connector REVEAL
#   consumer seam (the scoped `revealed_bytes()` read).
# =============================================================================
#
# WHAT THIS IS. `CredentialConsumer` is the seam the connector reveal boundary
# (`SecretRegistry.reveal_for`) hands the resolved secret's bytes to. The reveal
# resolves a secret through the store, mints a LOCAL `SecretValue`, takes its
# scoped `revealed_bytes()` `Span`, and passes that `Span` to
# `CredentialConsumer.consume`, entirely inside the reveal call. The consumer is
# where a real connector opens a database connection or signs a request from the
# revealed bytes; the caller supplies it (a test passes one that asserts the
# bytes, production passes one that builds the connection).
#
# THE LOAD-BEARING LIFETIME PROPERTY. `consume` receives a `Span[UInt8, _]`
# whose origin is the LOCAL `SecretValue` inside the reveal. The `Span` is
# consumed within the `consume` call and cannot be returned from `reveal_for`:
# the compiler ties the span's origin to a value that drops (and therefore
# zeroizes) when the reveal method exits. So:
#   * the secret bytes never outlive the single reveal call;
#   * the consumer cannot keep the `Span` past `consume` (the origin would
#     escape `consume`, a compile error);
#   * the consumer cannot leak an owned copy through the `Span` (it is
#     read-only).
# A `with_revealed[f]` comptime-closure accessor is deliberately not built;
# `revealed_bytes()` is the sanctioned read.
#
# WHY A TRAIT (not a function parameter). The reveal seam must be a stable trait
# that the engine can hand a concrete connector consumer to and a test can hand
# a recording double to. A trait keeps `SecretRegistry.reveal_for` monomorphic
# over the consumer (`[Consumer: CredentialConsumer]`): no type erasure, no
# function pointer, no wildcard origin.
#
# ENCAPSULATION: `consume(mut self, secret: Span[UInt8, _]) raises` takes a
# read-only byte `Span` and returns nothing (the consumer's effect is on its own
# state, e.g. it opens a connection or records the bytes). No UnsafePointer
# crosses any boundary; the `Span` origin is the reveal-local `SecretValue`; no
# wildcard origin.
# =============================================================================


# =============================================================================
# §0 CredentialConsumer: the connector reveal-boundary consumer seam.
# =============================================================================
trait CredentialConsumer(Movable, Deinitable):
    """Receive a resolved secret's bytes AT the connector reveal boundary. The
    `SecretRegistry.reveal_for` call resolves the secret through the store,
    mints a LOCAL `SecretValue`, and hands its scoped `revealed_bytes()` `Span`
    to `consume`, entirely inside the reveal. A real connector opens its
    connection or signs its request here; a test asserts the bytes. The `Span`'s
    origin is the reveal-local `SecretValue`, so it cannot be returned or
    escaped (it is wiped when the reveal method exits); there is no owned copy
    to leak. `raises` so a connector that fails to use the bytes (e.g. a bad
    connection string) surfaces a clean failure."""

    def consume(mut self, secret: Span[UInt8, _]) raises:
        ...
