# `komira_secret_env`

## Responsibility

A `SecretStore` (see [komira_secret_store](https://github.com/komira-ai/komira/blob/main/src/komira_secret_store/__init__.mojo))
whose handle is the NAME of an environment variable. `resolve("PYPI_TOKEN")`
returns the value of `PYPI_TOKEN` as a zeroizing, redacted `SecretValue`.
It is the store a binary composes for local runs and for CI jobs that receive
a credential as an environment variable.

A handle is a name, never a value: it must match `[A-Za-z_][A-Za-z0-9_]*` and
be at most 128 bytes, and a handle outside that grammar is refused without
being quoted, because it may be a pasted secret. An unset variable and a
set-but-empty one are both refused, with different messages naming the
handle. No refusal and no `Display` ever shows a value.

The value goes from the environ block straight into the `SecretValue`; no
`String` holds it. The environ block itself is not cleared (there is no
`unsetenv`), so the value stays in the process environment.

## API

| name | file | what it is |
|---|---|---|
| `EnvSecretStore[E]` | [env_secret_store.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_secret_env/env_secret_store.mojo) | the `SecretStore` conformer |
| `EnvReader` | [env_secret_store.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_secret_env/env_secret_store.mojo) | the lookup seam: `None` = unset |
| `ProcessEnv` | [process_env.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_secret_env/process_env.mojo) | the reader over this process (`getenv(3)`) |
| `MapEnv` | [map_env.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_secret_env/map_env.mojo) | the hermetic test double, with a lookup count |
| `is_secret_env_name`, `check_secret_env_name`, `MAX_SECRET_NAME_LEN` | [env_name.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_secret_env/env_name.mojo) | the handle grammar |

## Dependencies

`komira_secret_store` (the port), `komira_libc` and `komira_crypto`.
`ProcessEnv` reads through komira_libc's `_read_env_into`, so the binary
keeps its one `getenv` declaration, into a stack buffer that it wipes with
komira_crypto's `zeroize_inline_array` on every path out.

## Examples

Every example below runs as a test when the package is built, so it cannot
go stale. They read through `MapEnv`, the hermetic double, so they need no
variable in the process environment.

### Resolving a handle

The handle names the variable; the store returns its bytes as a
`SecretValue` whose `Display` is redacted.

```mojo
from komira_secret_env import EnvSecretStore, MapEnv
from std.testing import assert_equal

var env = MapEnv()
env.set("PYPI_TOKEN", "pypi-s3cr3t")
var probe = env.share()  # the same variables, for reading the lookup count
var store = EnvSecretStore[MapEnv](env^)

var value = store.resolve("PYPI_TOKEN")
assert_equal(value.len(), 11)
var got = value.revealed_bytes()
var want = "pypi-s3cr3t".as_bytes()
for i in range(len(want)):
    assert_equal(got[i], want[i])
assert_equal(String(value), "SecretValue(<redacted:11B>)")
assert_equal(probe.lookup_count(), 1)
```

### Refusals

An unset variable and an empty one are refused with different messages that
name the handle. A handle outside the grammar is refused before any lookup,
and the refusal does not quote it: it may be a pasted secret.

```mojo
from komira_secret_env import EnvSecretStore, MapEnv, is_secret_env_name
from std.testing import assert_equal, assert_false, assert_true

var env = MapEnv()
env.set("EMPTY_TOKEN", "")
var probe = env.share()
var store = EnvSecretStore[MapEnv](env^)

var unset = String()
try:
    _ = store.resolve("PYPI_TOKEN")
except e:
    unset = String(e)
assert_equal(unset, "EnvSecretStore: environment variable PYPI_TOKEN is not set")

var empty = String()
try:
    _ = store.resolve("EMPTY_TOKEN")
except e:
    empty = String(e)
assert_equal(empty, "EnvSecretStore: environment variable EMPTY_TOKEN is set but empty")
assert_equal(probe.lookup_count(), 2)

var pasted = String("ghp_pasted.token/value")
assert_false(is_secret_env_name(pasted))
var refused = String()
try:
    _ = store.resolve(pasted)
except e:
    refused = String(e)
assert_true(refused.startswith("EnvSecretStore: secret env name"), refused)
assert_equal(refused.find(pasted), -1)
assert_equal(probe.lookup_count(), 2)  # no lookup for a refused handle
```
