# `komira_secrets_keychain`

## Responsibility

A `SecretStore` (see [komira_secret_store](https://github.com/komira-ai/komira/blob/main/src/komira_secret_store/__init__.mojo))
over the operating system's keychain, for local runs. `resolve("service/account")`
fetches the entry and returns it as a zeroizing, redacted `SecretValue`.

The handle is `service[/account]`, split on the first `/`. A handle with no `/`
names a service only (the keychain then matches on service alone); a service
that itself contains `/` must use the two-part form. An empty service is
refused before any fetch. A missing entry and a failed backend are both refused,
with different messages; no message carries a value.

The fetch is a seam (`KeychainBackend`), so the store is tested with no
keychain. `MacosSecurityKeychainBackend` runs
`/usr/bin/security find-generic-password -s <service> -a <account> -w` through
[komira_supervisor](https://github.com/komira-ai/komira/blob/main/src/komira_supervisor/__init__.mojo):
exit 0 is a hit (the one newline `-w` appends is stripped), exit 44 is a miss,
anything else is an error carrying the exit code and a bounded stderr tail.
The spawn is compiled only on macOS; on any other platform `fetch` answers an
error and starts no process. The exit-code mapping and the stdout parsing are
`map_security_result`, which has no platform dependency and is tested on every
platform; the spawn itself is not exercised by CI (the package's tests run on
Linux, where the macOS branch is not compiled). A Linux or Windows keychain is a new
`KeychainBackend`, with no change to the store.

This store reads a developer's own keychain. It is not a production secret
store.

## API

| name | file | what it is |
|---|---|---|
| `KeychainSecretStore[B]` | [keychain_secret_store.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_secrets_keychain/keychain_secret_store.mojo) | the `SecretStore` conformer |
| `parse_keychain_ref`, `KeychainRef` | [keychain_secret_store.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_secrets_keychain/keychain_secret_store.mojo) | the handle grammar |
| `KeychainBackend`, `KeychainLookup` | [keychain_backend.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_secrets_keychain/keychain_backend.mojo) | the fetch seam and its found / miss / error result |
| `StaticKeychainBackend` | [keychain_backend.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_secrets_keychain/keychain_backend.mojo) | the hermetic double, recording each query |
| `MacosSecurityKeychainBackend`, `build_security_argv`, `map_security_result` | [macos_security_backend.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_secrets_keychain/macos_security_backend.mojo) | the macOS backend and its argv |

## Examples

Resolve a scripted entry, and see a missing one refused:

<!-- mojo-hidden from std.testing import assert_equal, assert_raises -->
```mojo
from komira_secrets_keychain import KeychainSecretStore, StaticKeychainBackend

var backend = StaticKeychainBackend()
backend.put("app-db", "owner", "hunter2")
var store = KeychainSecretStore[StaticKeychainBackend](backend^)

var v = store.resolve("app-db/owner")
assert_equal(v.len(), 7)
assert_equal(String(v), "SecretValue(<redacted:7B>)")
var got = v.revealed_bytes()
var want = "hunter2".as_bytes()
for i in range(len(want)):
    assert_equal(got[i], want[i])

with assert_raises(contains="no keychain entry for secret_ref 'app-db/other'"):
    _ = store.resolve("app-db/other")
```
