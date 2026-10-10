# komira_secret_store

The seam between code that uses a secret and code that knows where a secret
lives. `SecretStore` is a one-method trait: `resolve(secret_ref)` takes an
opaque handle and returns a `SecretValue`, and raises when the handle is
unknown or the store cannot answer. `StaticSecretStore` is an in-memory
conformer for tests: you script `handle -> value` pairs with `put`, it counts
every `resolve` call, and an unscripted handle raises.

`SecretValue` holds the plaintext in a fixed inline buffer of
`MAX_SECRET_LEN` (4096) bytes. It is move-only, its `Display` prints only the
length (`SecretValue(<redacted:NB>)`), the bytes are read through the scoped
`revealed_bytes()` span, and its destructor wipes the whole buffer through
`komira_crypto`'s `zeroize_inline_array`. A value longer than
`MAX_SECRET_LEN` raises rather than being truncated. `SecretMeta` is the
names-only record a catalog holds (a handle plus two provider ordinals); it has
no path to a value.

The package ships no real store: a client for a secret service, a keychain
reader or a cache is written elsewhere and conforms to `SecretStore`.

## Examples

Resolve a scripted handle, rotate it, and see an unknown handle refused:

<!-- mojo-hidden from std.testing import assert_equal, assert_raises -->
```mojo
from komira_secret_store import SecretStore, StaticSecretStore

var store = StaticSecretStore()
store.put("db/password", "hunter2")

var v = store.resolve("db/password")
assert_equal(v.len(), 7)
assert_equal(String(v), "SecretValue(<redacted:7B>)")  # printing never leaks
var got = v.revealed_bytes()  # a view tied to `v`; it cannot outlive it
var want = "hunter2".as_bytes()
for i in range(len(want)):
    assert_equal(got[i], want[i])

store.put("db/password", "rotated!")  # same handle, new value
assert_equal(store.resolve("db/password").len(), 8)

with assert_raises(contains="no secret for secret_ref"):
    _ = store.resolve("db/missing")
assert_equal(store.resolve_count(), 3)  # the failed call is counted too
```

A consumer binds its own store by conforming to the trait, and code generic
over `[S: SecretStore]` accepts it:

<!-- mojo-hidden from std.testing import assert_equal, assert_raises -->
```mojo module
from komira_secret_store import MAX_SECRET_LEN, SecretMeta, SecretStore, SecretValue


struct OneSecret(SecretStore, Movable):
    var name: String
    var value: String

    def __init__(out self, name: String, value: String):
        self.name = name
        self.value = value

    def resolve(mut self, secret_ref: String) raises -> SecretValue:
        if secret_ref != self.name:
            raise Error("unknown ref " + secret_ref)
        return SecretValue.from_string(self.value)


def secret_length[S: SecretStore](mut store: S, name: String) raises -> Int:
    return store.resolve(name).len()


def main() raises:
    var mine = OneSecret("api/token", "abc123")
    assert_equal(secret_length(mine, "api/token"), 6)

    var too_long = List[UInt8](length=MAX_SECRET_LEN + 1, fill=0x41)
    with assert_raises(contains="exceeds MAX_SECRET_LEN"):
        _ = SecretValue(Span(too_long))

    var meta = SecretMeta("api/token", 1, 0)
    assert_equal(
        String(meta),
        "SecretMeta(name_handle='api/token', provider_kind=1, reachability=0)",
    )
```
