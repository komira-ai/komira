# `komira_secrets_conjur`

## Responsibility

A `SecretStore` (see [komira_secret_store](https://github.com/komira-ai/komira/blob/main/src/komira_secret_store/__init__.mojo))
over CyberArk Conjur's REST API. `resolve("myorg/app/db/password")` sends

```text
GET /secrets/myorg/variable/app%2Fdb%2Fpassword
Authorization: Token token="<base64 access token>"
```

over a fresh connector, and the 200 body, which is the raw secret with no JSON
envelope and no base64, goes into a zeroizing, redacted `SecretValue`. Any other
status raises with the status and a hint (404 variable missing, 403 role lacks
`execute`, 401 token rejected), never the response body or the token. A 200 with
an empty body raises rather than yielding an empty value.

A handle is `{account}/{variable_id}` (the variable id is a slash-delimited
policy path, so the split is on the first `/`). The appliance host and port are
fixed when the store is built and every request goes there; a handle never
names a host. Handles often come from configuration other people write, and a
handle that chose the host would choose where the access token is sent, so a
handle that names a host (one containing `|`) is refused before any request,
and the refusal does not quote it. The handle is untrusted text. The account and the variable id are each sent as
one percent-encoded path component (the variable id is URL-encoded as Conjur's
API documents, so its `/` is `%2F` and a `?`, `#`, `%` or space cannot start a
query or an escape), a variable id or account of `.` or `..` is refused (it would
walk the path), and a control byte (CR, LF, NUL, any byte below 0x20, DEL)
anywhere in a handle is refused so it cannot add request headers; none of these
refusals quotes the handle. Non-ASCII is kept as UTF-8 and sent encoded. A handle
with no `/` or an empty account or variable id raises before any request. An
access token holding a space, a control byte or a non-ASCII byte is refused
rather than stamped into the `Authorization` header.

The access token comes from a `ConjurAuthSource`. `LiveConjurAuthSource[C]`
POSTs the API key (as the request body, never a header) to
`/authn/{account}/{login}/authenticate` and returns the 200 body trimmed of
surrounding ASCII whitespace; it mints a new token on every call and caches
nothing. `StaticConjurAuthSource` returns a canned token and counts mints.

The connector is a non-capturing factory `def () thin -> C`: a TLS connector
against a real appliance, a `ScriptedConnector` in a test. The Kubernetes authn
login and a token cache are not provided.

## API

| name | file | what it is |
|---|---|---|
| `ConjurSecretStore[C, T]` | [conjur_secret_store.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_secrets_conjur/conjur_secret_store.mojo) | the `SecretStore` conformer |
| `parse_conjur_ref`, `ConjurSecretRef`, `read_path_for`, `build_read_request_headers` | [conjur_secret_store.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_secrets_conjur/conjur_secret_store.mojo) | the handle grammar and the read request |
| `ConjurAuthSource` | [conjur_auth_source.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_secrets_conjur/conjur_auth_source.mojo) | the access-token seam |
| `LiveConjurAuthSource[C]`, `StaticConjurAuthSource` | [conjur_auth_source.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_secrets_conjur/conjur_auth_source.mojo) | the authn-POST source and the canned double |
| `authn_path_for`, `build_authn_request_headers` | [conjur_auth_source.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_secrets_conjur/conjur_auth_source.mojo) | the authn request |

## Examples

Resolve a variable over a scripted connector (no socket), and see the request
shape and a refusal:

<!-- mojo-hidden
from std.testing import assert_equal, assert_true
-->
```mojo module
from std.testing import assert_raises
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_secrets_conjur import (
    ConjurSecretStore,
    StaticConjurAuthSource,
    build_read_request_headers,
    parse_conjur_ref,
    read_path_for,
)


def answer_200() -> ScriptedConnector:
    var reply = String(
        "HTTP/1.1 200 OK\r\nContent-Length: 7\r\nContent-Type: text/plain\r\n\r\nhunter2"
    )
    var script = List[UInt8]()
    script.extend(Span(reply.as_bytes()))
    return ScriptedConnector.with_stream_tls(ScriptedStream.from_read_script(script^))


def main() raises:
    var parsed = parse_conjur_ref("myorg/app/db/password")
    assert_equal(parsed.account, "myorg")
    assert_equal(parsed.variable_id, "app/db/password")
    assert_equal(read_path_for(parsed.account, parsed.variable_id), "/secrets/myorg/variable/app%2Fdb%2Fpassword")
    var headers = build_read_request_headers("dG9rZW4=")
    assert_equal(headers.get("Authorization").value(), 'Token token="dG9rZW4="')

    var store = ConjurSecretStore[ScriptedConnector, StaticConjurAuthSource](
        answer_200, StaticConjurAuthSource("dG9rZW4="), "127.0.0.1"
    )
    var v = store.resolve("myorg/app/db/password")
    assert_equal(v.len(), 7)
    assert_equal(String(v), "SecretValue(<redacted:7B>)")

    with assert_raises(contains="malformed secret_ref"):
        _ = parse_conjur_ref("no-slash")

    # A handle never names the host the token is sent to.
    with assert_raises(contains="names a host"):
        _ = store.resolve("evil.example|myorg/app/db/password")
```
