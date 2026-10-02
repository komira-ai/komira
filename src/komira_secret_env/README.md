# `komira_secret_env`

## Responsibility

A `SecretStore` (see [komira_secret_store](../komira_secret_store/__init__.mojo))
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
| `EnvSecretStore[E]` | [env_secret_store.mojo](env_secret_store.mojo) | the `SecretStore` conformer |
| `EnvReader` | [env_secret_store.mojo](env_secret_store.mojo) | the lookup seam: `None` = unset |
| `ProcessEnv` | [process_env.mojo](process_env.mojo) | the reader over this process (`getenv(3)`) |
| `MapEnv` | [map_env.mojo](map_env.mojo) | the hermetic test double, with a lookup count |
| `is_secret_env_name`, `check_secret_env_name`, `MAX_SECRET_NAME_LEN` | [env_name.mojo](env_name.mojo) | the handle grammar |

## Dependencies

`komira_secret_store` only. `process_env.mojo` declares `getenv` itself, with
komira_core_ffi's signature exactly; the `getenv_link_probe` target links the
two side by side, so a signature change in either fails that build.
