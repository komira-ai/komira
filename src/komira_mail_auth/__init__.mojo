"""Credential checks for a mail server: the `MailAuthVerifier` seam, an
test/dev fixture verifier, and the SASL PLAIN (RFC 4616) and LOGIN payload decoders
that SMTP AUTH (RFC 4954) and IMAP use.

| function / type | does |
|---|---|
| `MailAuthVerifier` | the trait a server calls with a decoded (username, password): `verify` answers True or False and nothing else (`verifier.mojo`) |
| `TestAuthVerifier` | a fixture for tests and local development: unsalted SHA-256 digests (not a password hash), no real credentials; the comparison is constant time over fixed-width digests (`verifier.mojo`) |
| `SaslCredentials` | the decoded authcid and password; it has no printable form (`sasl.mojo`) |
| `decode_sasl_plain` | the base64 PLAIN payload to `SaslCredentials`, or nothing (`sasl.mojo`) |
| `decode_sasl_login_value`, `decode_sasl_login` | one LOGIN reply, or both replies, to a username or `SaslCredentials` (`sasl.mojo`) |
| `SASL_LOGIN_USERNAME_CHALLENGE`, `SASL_LOGIN_PASSWORD_CHALLENGE` | the base64 prompts a server sends after `334 ` |
| `MAX_SASL_LINE_BYTES`, `sasl_line_within_cap` | the cap on a `334` continuation line a client sends back |

Decoding never raises and a refusal carries no detail: a payload is either
well formed or it is `None`. No function here logs, prints or returns the
password except as the field of the `SaslCredentials` the caller asked for.
"""

from .sasl import (
    MAX_SASL_LINE_BYTES,
    SASL_LOGIN_PASSWORD_CHALLENGE,
    SASL_LOGIN_USERNAME_CHALLENGE,
    SaslCredentials,
    decode_sasl_login,
    decode_sasl_login_value,
    decode_sasl_plain,
    sasl_line_within_cap,
)
from .verifier import TestAuthVerifier, MailAuthVerifier
