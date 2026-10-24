# `komira_secrets_azure`

## Responsibility

A `SecretStore` (see [komira_secret_store](https://github.com/komira-ai/komira/blob/main/src/komira_secret_store/__init__.mojo))
over Azure Key Vault. `resolve("https://acme-kv.vault.azure.net/secrets/db-password")`
sends

```text
GET /secrets/db-password?api-version=7.4
Authorization: Bearer <Entra access token>
```

over a fresh connector, reads the `value` field of the JSON answer (the
plaintext, JSON-decoded, not base64) and returns it as a zeroizing, redacted
`SecretValue`. The decoder handles every JSON escape, `\uXXXX` including
surrogate pairs, and raw UTF-8; an escape it cannot decode, an unterminated
string or a missing or empty `value` raises rather than returning part of a
value. Any other status raises with the status and a hint (404, 403, 401),
never the response body or the token.

A handle is a secret identifier URI, `https://{vault}.vault.azure.net/secrets/{name}[/{version}]`.
The token is sent only to a Key Vault host, so the host must be a plain DNS name
ending in `.vault.azure.net` (one label of letters, digits and `-`; a port,
userinfo, `#`, `\` or a dotted label is refused), and the path must start with
`/secrets/`. A refused handle raises before anything is sent.
`AzureKeyVaultStore.with_dial_host` points the TCP dial at another host (a
private endpoint, or `127.0.0.1` in a test) while the handle's vault stays the
logical identity.

The token comes from an `AzureTokenSource`. The live sources wrap
komira_azure_core's providers and set their audience to Key Vault (the providers
default to Storage, and Key Vault answers 401 to a Storage token):
`ServicePrincipalTokenSource[C]` (client credentials, scope
`https://vault.azure.net/.default`) and `ManagedIdentityTokenSource[C]` (the
Instance Metadata Service, resource `https://vault.azure.net`, system- or
user-assigned). Each re-mints only when the provider's cached token is near
expiry. `StaticAzureTokenSource` returns a canned token and counts mints.

The connector is a non-capturing factory `def () thin -> C`: a TLS connector
against a real vault, a `ScriptedConnector` in a test.

## API

| name | file | what it is |
|---|---|---|
| `AzureKeyVaultStore[C, T]` | [azure_key_vault_store.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_secrets_azure/azure_key_vault_store.mojo) | the `SecretStore` conformer |
| `parse_key_vault_ref`, `KeyVaultRef`, `build_kv_request_headers` | [azure_key_vault_store.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_secrets_azure/azure_key_vault_store.mojo) | the handle grammar and the read request |
| `AzureTokenSource` | [azure_token_source.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_secrets_azure/azure_token_source.mojo) | the access-token seam |
| `ServicePrincipalTokenSource[C]`, `ManagedIdentityTokenSource[C]`, `StaticAzureTokenSource` | [azure_token_source.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_secrets_azure/azure_token_source.mojo) | the live sources and the canned double |

## Examples

Resolve a secret over a scripted connector (no socket), and see a handle that
does not name a Key Vault refused:

<!-- mojo-hidden
from std.testing import assert_equal, assert_true
-->
```mojo module
from std.testing import assert_raises
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_secrets_azure import (
    AzureKeyVaultStore,
    StaticAzureTokenSource,
    build_kv_request_headers,
    parse_key_vault_ref,
)


def answer_200() -> ScriptedConnector:
    var body = String('{"value":"p\\u0026ss","id":"x"}')
    var reply = String("HTTP/1.1 200 OK\r\nContent-Length: ") + String(body.byte_length())
    reply += "\r\nContent-Type: application/json\r\n\r\n" + body
    var script = List[UInt8]()
    script.extend(Span(reply.as_bytes()))
    return ScriptedConnector.with_stream_tls(ScriptedStream.from_read_script(script^))


def main() raises:
    var kv = parse_key_vault_ref("https://acme-kv.vault.azure.net/secrets/db-password/v1")
    assert_equal(kv.host, "acme-kv.vault.azure.net")
    assert_equal(kv.path, "/secrets/db-password/v1")
    assert_equal(
        build_kv_request_headers("tok").get("Authorization").value(), "Bearer tok"
    )

    var store = AzureKeyVaultStore[ScriptedConnector, StaticAzureTokenSource].with_dial_host(
        answer_200, StaticAzureTokenSource("tok"), "127.0.0.1"
    )
    var v = store.resolve("https://acme-kv.vault.azure.net/secrets/db-password")
    assert_equal(v.len(), 4)  # "p&ss": the service's & is decoded
    assert_equal(String(v), "SecretValue(<redacted:4B>)")

    with assert_raises(contains="not a plain"):
        _ = parse_key_vault_ref("https://evil.example#.vault.azure.net/secrets/x")
```
