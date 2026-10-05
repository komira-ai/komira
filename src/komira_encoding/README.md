# komira_encoding

Binary-to-text encodings in pure Mojo, with no dependencies: base64 and
base64url (RFC 4648 sections 4 and 5), base32 (section 6), hex (section 8),
and PEM armor (RFC 7468).

Encoders take bytes (`Span[UInt8]`) and return a `String`. Decoders take a
`String` or bytes and return `List[UInt8]`. Decoding is strict: a byte
outside the alphabet (whitespace included), misplaced or missing padding, a
length no input encodes to, or non-zero unused bits in the last symbol is
refused with a named error that gives the byte position. Decoding runs in
constant time with respect to the data; the package docstring states the
limits of that claim.

Every example below runs as a test when the package is built, so it cannot
go stale.

## Round trips

```mojo
from komira_encoding import base32_decode, base32_encode, base64_decode, base64_encode, hex_decode, hex_encode
from std.testing import assert_equal

var data = "foobar".as_bytes()
assert_equal(base64_encode(data), "Zm9vYmFy")
assert_equal(base32_encode(data), "MZXW6YTBOI======")
assert_equal(hex_encode(data), "666f6f626172")

assert_equal(String(unsafe_from_utf8=base64_decode("Zm9vYmFy")), "foobar")
assert_equal(String(unsafe_from_utf8=base32_decode("MZXW6YTBOI======")), "foobar")
assert_equal(String(unsafe_from_utf8=hex_decode("666F6F626172")), "foobar")  # either case
```

## base64url, padded or not

`base64_url_encode_nopad` is the form JWTs and JWKs use (RFC 7515 section 2).
`base64_url_decode` accepts either form; `base64_url_decode_nopad` refuses
padding.

```mojo
from komira_encoding import base64_url_decode, base64_url_decode_nopad, base64_url_encode, base64_url_encode_nopad
from std.testing import assert_equal

var key: List[UInt8] = [0xFB, 0xFF]
assert_equal(base64_url_encode(key), "-_8=")
assert_equal(base64_url_encode_nopad(key), "-_8")
assert_equal(base64_url_decode("-_8="), key)
assert_equal(base64_url_decode("-_8"), key)
assert_equal(base64_url_decode_nopad("-_8"), key)
```

## PEM

`pem_encode` wraps the base64 body at 64 symbols a line. `pem_label` reads the
label of the first block, and `pem_decode` returns its bytes only when the
label is the one you ask for.

```mojo
from komira_encoding import LABEL_MISMATCH, PEM_LABEL_CERTIFICATE, PEM_LABEL_PRIVATE_KEY, error_kind, pem_decode, pem_encode, pem_label
from std.testing import assert_equal, assert_true

var der: List[UInt8] = [0x30, 0x03, 0x02, 0x01, 0x07]
var pem = pem_encode(PEM_LABEL_CERTIFICATE, der)
assert_equal(pem, "-----BEGIN CERTIFICATE-----\nMAMCAQc=\n-----END CERTIFICATE-----\n")
assert_equal(pem_label(pem), "CERTIFICATE")
assert_equal(pem_decode(pem, PEM_LABEL_CERTIFICATE), der)

var refused = False
try:
    _ = pem_decode(pem, PEM_LABEL_PRIVATE_KEY)
except e:
    refused = True
    assert_equal(error_kind(e), LABEL_MISMATCH)
assert_true(refused)
```

## Errors

A decoder raises an `Error` whose message starts with
`komira_encoding.<Kind>:`. `error_kind` returns the kind, or `""` for any
other error. The message names the function and the zero-based byte
position, and never contains a byte of the input, because the input is often
a key or a token and error messages end up in logs.

```mojo
from komira_encoding import INVALID_CHARACTER, base64_decode, error_kind
from std.testing import assert_equal, assert_true

var refused = False
try:
    _ = base64_decode("Zm9v YmFy")  # a space is not in the alphabet
except e:
    refused = True
    assert_equal(error_kind(e), INVALID_CHARACTER)
    assert_equal(
        String(e),
        "komira_encoding.InvalidCharacter: base64_decode: byte is not in the alphabet at position 4",
    )
assert_true(refused)
```

The kinds are `InvalidCharacter`, `InvalidPadding`, `InvalidLength`,
`NonCanonical` (non-zero unused bits, RFC 4648 section 3.5),
`InvalidBoundary` and `LabelMismatch` (PEM). Each is exported as a constant
(`INVALID_CHARACTER`, ...).
