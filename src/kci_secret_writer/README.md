# kci_secret_writer

The write-only secret seam. `SecretWriter` is a trait with three verbs:
`write` (move a zeroizing `SecretValue` into a secret reference as a new
version), `define_container` (create an empty secret slot, no value) and
`has_version` (does the reference hold at least one version; a reference that
does not exist answers `False`). Every verb also takes a per-call bearer token
that a live writer uses for the call and never stores.

`SecretWriter` is a separate type from `komira_secret_store`'s resolve-only
`SecretStore`, so code that holds only a `SecretStore` cannot write. Nothing
returns a written value: a writer has no read verb.

The package ships the trait and one conformer, `StaticSecretWriter`, an
in-memory test double that records each write, define and version count, and
can hand back a `StaticSecretStore` seeded with what it wrote (the
write-then-resolve round trip). It names no provider and makes no network
call; a real writer lives with its cloud client and conforms to the same trait.

## Examples

A write lands the value under its reference, and a re-write adds a version
whose value wins:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_secret_store import SecretValue
from kci_secret_writer import StaticSecretWriter

var w = StaticSecretWriter()
assert_false(w.has_version("app/smtp", "deploy-token"))

w.write("app/smtp", SecretValue.from_string("token-v1"), "deploy-token")
w.write("app/smtp", SecretValue.from_string("token-v2"), "deploy-token")

assert_equal(w.write_count(), 2)
assert_equal(w.version_count("app/smtp"), 2)
assert_true(w.has_version("app/smtp", "deploy-token"))
assert_true(w.written_equals("app/smtp", "token-v2"))
assert_false(w.written_equals("app/smtp", "token-v1"))
assert_equal(w.last_token(), "deploy-token")
```

Defining a container makes an empty slot, which holds no version:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from kci_secret_writer import StaticSecretWriter

var w = StaticSecretWriter()
w.define_container("app/api-key", "deploy-token")
assert_true(w.was_defined("app/api-key"))
assert_equal(w.define_count(), 1)
assert_false(w.was_written("app/api-key"))
assert_false(w.has_version("app/api-key", "deploy-token"))
```

Code generic over the trait writes; the paired resolve double reads the
value back, and printing a `SecretValue` shows only its length:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_secret_store import SecretValue
from kci_secret_writer import SecretWriter, StaticSecretWriter

def seed[W: SecretWriter](mut w: W, name: String, value: String) raises:
    if not w.has_version(name, "deploy-token"):
        w.write(name, SecretValue.from_string(value), "deploy-token")

var w = StaticSecretWriter()
seed(w, "app/db-password", "first")
seed(w, "app/db-password", "second")  # already has a version: not written
assert_equal(w.version_count("app/db-password"), 1)

var store = w.as_static_store()
var resolved = store.resolve("app/db-password")
assert_equal(resolved.len(), 5)
assert_equal(String(resolved), "SecretValue(<redacted:5B>)")
```
