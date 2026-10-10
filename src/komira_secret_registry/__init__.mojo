"""`komira_secret_registry`: the per-execution secret registry side table and
the connector reveal seam.

The secrets counterpart of komira_plan_expr's `FsBindings` (the file-system
`node_id -> scheme` table a plan carries). It binds a query's secret-bearing
plan nodes to opaque secret handles and resolves a handle only at the moment a
connector needs the bytes.

WHAT IT SHIPS:
  * `SecretRegistry[Store]`: the per-execution `node_id -> secret_ref` side
    table. It owns the resolve capability (`Store`) by value. `register` binds a
    secret-bearing node to its opaque handle; `reveal_for[Consumer]` is the
    connector reveal boundary. A per-execution VALUE (Movable, not Copyable),
    constructed at the engine boundary, threaded by value and dropped at
    execution exit. It holds its bindings in a plain value
    `Slab[SecretRegistryEntry]` and never stores a `SecretValue`: values are
    resolved on demand. Dropping the registry frees the Slab and the store, so
    RAII is the "wiped at execution end" guarantee.
  * `SecretRegistryEntry` / `SecretBindings`: the flat `(node_id, name_handle,
    secret_ref)` binding and the store-less bindings table. They live in
    `komira_secret_registry.secret_bindings` and are re-exported here.
  * `CredentialConsumer`: the reveal consumer seam. The reveal boundary hands it
    the scoped `revealed_bytes()` `Span` entirely inside the reveal call; a real
    connector opens its connection there, a test asserts the bytes. The `Span`
    is origin-bound to the reveal-local `SecretValue`, so it cannot escape
    (escape is a compile error) and the bytes are wiped when the call exits.

CUSTODY CHECKS RUN INSIDE ONE RESOLVE. `Store` is a concrete monomorph, for
example a store that authorizes the caller and then records an audit entry
around an inner provider store. A single `self._store.resolve(secret_ref)`
inside `reveal_for` then runs every check that composition makes: an
authorization deny raises before the inner provider is reached. There is no
type erasure; the concrete composed type is the `Store` parameter.

FAIL-FAST ON A MISSING BINDING (unlike `FsBindings`). An unbound `node_id`
raises in `reveal_for`: a secret-bearing node with no binding is a wiring
error, never a silent local fallback. An unbound file-system node resolves to
the local file system (`FsBindings.resolve_scheme` answers `FS_SCHEME_FILE`),
a benign default that a missing secret does not have.

Dependencies: `komira_secret_store` (the `SecretStore` trait and `SecretValue`)
and the core packages (`Slab` and the bindings table). Nothing from the engine,
the compiler or the file formats enters this closure.

A resolve cache is deliberately absent: resolve-on-demand is the tightest
custody default. If one is ever added it must hold
`Optional[OwnedPointer[SecretValue]]`, never a bare `SecretValue` inside a Slab.
"""

# `SecretBindings` and `SecretRegistryEntry` are two flat value types that import
# nothing. They live in `komira_secret_registry.secret_bindings` because the logical
# plan carries a `SecretBindings` field, and the plan tier must not depend on
# the secret-store stack. They are re-exported here so this package's surface is
# complete; a plan-tier consumer imports them from
# `komira_secret_registry.secret_bindings` directly, never through this facade.
from komira_secret_registry.secret_bindings import (
    SecretBindings,
    SecretRegistryEntry,
)

from .credential_consumer import CredentialConsumer
from .secret_registry import SecretRegistry
