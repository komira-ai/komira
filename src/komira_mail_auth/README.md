# komira_mail_auth

Credential checks for a mail server (SMTP AUTH, RFC 4954, and IMAP LOGIN): a
trait that answers "is this password right for this user", an in-memory
implementation of it, the decoders for the SASL PLAIN (RFC 4616) and LOGIN
payloads a client sends, and the cap on the line a client sends back after a
`334` challenge. The package does no I/O and keeps no clock; the server that
owns the connection calls it after the connection is on TLS.

Every example below runs as a test when the package is built.

## Verify a credential

A server holds anything that conforms to `MailAuthVerifier`. `InMemoryAuthVerifier`
keeps the SHA-256 digest of each password and compares the digest of what the
client sent with `constant_time_eq_32`: the comparison takes the same time
wherever the bytes first differ, and a prefix or a longer password is refused
like any other wrong one. An unknown user takes the same comparison, against
a decoy digest. The time of the SHA-256 pass grows with the presented
password's length (the caller's own input); the stored password's length takes
no part. A username is compared with `==`. One SHA-256 pass is not a
password-hashing function, so this table is for tests and small configured
user sets.

```mojo
from komira_mail_auth import InMemoryAuthVerifier, MailAuthVerifier
from std.testing import assert_false, assert_true

var users = InMemoryAuthVerifier()
users.add_user("alice", "correct horse")
assert_true(users.verify("alice", "correct horse"))
assert_false(users.verify("alice", "correct hors"))  # a prefix
assert_false(users.verify("alice", "correct horse!"))  # a longer password
assert_false(users.verify("carol", "correct horse"))  # an unknown user
```

An implementation of the trait must not log the password; the Bool is the
only value that leaves `verify`.

## Decode a PLAIN or LOGIN reply

`decode_sasl_plain` takes the base64 text after `AUTH PLAIN` (or the
continuation line) and gives `SaslCredentials` (`authcid`, `password`) or
`None`. It refuses non-canonical base64, anything but exactly three
NUL-separated fields (an extra NUL is refused, not folded into the password),
an empty authcid or password, an authzid that is not empty and differs from
the authcid, and bytes that are not UTF-8. `SaslCredentials` has no printable
form.

```mojo
from komira_encoding import base64_encode
from komira_mail_auth import decode_sasl_plain, decode_sasl_login
from std.testing import assert_equal, assert_false, assert_true

var raw = String("\0alice\0s3cret")
var c = decode_sasl_plain(base64_encode(raw.as_bytes()))
assert_equal(c.value().authcid, "alice")
assert_equal(c.value().password, "s3cret")

var other = String("bob\0alice\0s3cret")  # authzid differs from authcid
assert_false(Bool(decode_sasl_plain(base64_encode(other.as_bytes()))))

var l = decode_sasl_login(
    base64_encode(String("alice").as_bytes()),
    base64_encode(String("s3cret").as_bytes()),
)
assert_true(Bool(l))
```

`decode_sasl_login_value` decodes one reply (refusing non-canonical base64,
an empty value, a NUL and invalid UTF-8); `decode_sasl_login` decodes both and
gives `SaslCredentials`. A server sends `SASL_LOGIN_USERNAME_CHALLENGE` and
`SASL_LOGIN_PASSWORD_CHALLENGE` after `334 `.

## The continuation-line cap

RFC 4954 section 4 calls 12288 octets a sufficient line length and has a
server answer a line over its own buffer with `500` (enhanced status `5.5.6`).
`MAX_SASL_LINE_BYTES` is that number, counted without the CRLF (our choice; the
RFC does not say), and `sasl_line_within_cap(length)` is
true for a length from 0 to the cap (CRLF excluded). A server checks the
length of the line before it decodes it and answers a longer one with
`500 5.5.6`; the decoders also return None for a longer payload.

```mojo
from komira_mail_auth import MAX_SASL_LINE_BYTES, sasl_line_within_cap
from std.testing import assert_false, assert_true

assert_true(sasl_line_within_cap(MAX_SASL_LINE_BYTES))
assert_false(sasl_line_within_cap(MAX_SASL_LINE_BYTES + 1))
```

## Limits

- No hashed-password or key-derivation verifier, no SCRAM, no OAUTHBEARER.
- The in-memory table is plaintext-derived data held in process memory; there
  is no persistence and no lockout or rate limit.
