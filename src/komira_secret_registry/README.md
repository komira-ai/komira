# komira_secret_registry

A per-execution side table from plan node ids to opaque secret handles, and
the boundary where a connector receives a secret's bytes.

- `SecretRegistry[Store]` owns a `SecretStore` (from `komira_secret_store`)
  by value and binds `node_id -> (name_handle, secret_ref)` with `register`.
  `reveal_for(node_id, consumer)` resolves the bound handle through the store,
  passes the value's bytes to `consumer.consume` as a `Span` tied to a local
  `SecretValue`, and drops the value (which wipes it) before returning. Every
  reveal calls the store again: the registry keeps no resolved values, so a
  rotated secret is seen on the next reveal. An unbound `node_id` raises before
  the store is asked. `into_store` gives the store back.
- `CredentialConsumer` is the one-method trait a connector implements to
  receive the bytes (`consume(secret: Span[UInt8, _])`).
- `SecretBindings` is the same table without a store, a `Copyable` value a
  plan can carry and merge (`bind`, `merge_from`, `has_binding`,
  `name_handle_for`, `secret_ref_for`); `SecretRegistry.from_bindings(store,
  bindings)` lifts it into a registry.

The package ships no store and no connector: both arrive through the traits.

## Examples

Register a node, reveal its secret into a consumer, rotate it, and see an
unbound node refused:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_raises, assert_true -->
```mojo
from komira_secret_registry import CredentialConsumer, SecretRegistry
from komira_secret_store import StaticSecretStore

struct LengthConsumer(CredentialConsumer, Movable):
    """Records only how many bytes it was handed and the first one."""
    var length: Int
    var first: UInt8

    def __init__(out self):
        self.length = 0
        self.first = 0

    def consume(mut self, secret: Span[UInt8, _]) raises:
        self.length = len(secret)
        self.first = secret[0]

var store = StaticSecretStore()
store.put("ref-pg", "s3cr3t")
var probe = store.share()  # a second handle onto the same scripted store

var reg = SecretRegistry[StaticSecretStore](store^)
reg.register(7, "prod-pg", "ref-pg")
assert_true(reg.has_binding(7))
assert_false(reg.has_binding(8))

var seen = LengthConsumer()
reg.reveal_for(7, seen)
assert_equal(seen.length, 6)
assert_equal(seen.first, UInt8(ord("s")))

probe.put("ref-pg", "rotated-secret")  # nothing is cached: the next reveal sees it
reg.reveal_for(7, seen)
assert_equal(seen.length, 14)
assert_equal(probe.resolve_count(), 2)

with assert_raises(contains="no secret binding for node_id 8"):
    reg.reveal_for(8, seen)
assert_equal(probe.resolve_count(), 2)  # refused before the store was asked
```

A plan carries store-less `SecretBindings`; two plans merge, and the engine
lifts the result into a registry over its store:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_secret_registry import SecretBindings, SecretRegistry
from komira_secret_store import StaticSecretStore

var left = SecretBindings()
left.bind(1, "warehouse", "ref-1")
var right = SecretBindings()
right.bind(2, "bucket", "ref-2")
left.merge_from(right^)

assert_equal(left.num_entries(), 2)
assert_equal(left.name_handle_for(2), "bucket")
assert_equal(left.secret_ref_for(1), "ref-1")
assert_equal(left.secret_ref_for(3), "")  # unbound: empty

var reg = SecretRegistry[StaticSecretStore].from_bindings(StaticSecretStore(), left)
assert_equal(reg.num_entries(), 2)
assert_true(reg.has_binding(1))
assert_false(reg.has_binding(3))
```
