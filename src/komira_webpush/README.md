# `komira_webpush`

## Responsibility

Web Push message encryption: what an application server does to a push
message before it hands the body to a push service, and what the browser (the
user agent) does to read it.

- The `aes128gcm` HTTP content coding (RFC 8188): the header (salt, record
  size, key id), the content-encryption key and nonce derived from the input
  keying material, one-record encryption, and decryption of a body of one or
  more records.
- Web Push encryption (RFC 8291) on P-256 ECDH: a fresh salt and a fresh
  sender key per message, the input keying material bound to the
  subscription's public key and authentication secret, and the user agent's
  side that decrypts.

Sending a message (RFC 8030, the push service's HTTP API, and VAPID, RFC
8292) is not here. The cryptography is `komira_crypto`'s (`p256_ecdh`,
HKDF-SHA-256, AES-128-GCM); secret intermediates are wiped once used.

## API

Everything is exported from `komira_webpush`:

- `webpush_encrypt(ua_public, auth_secret, plaintext)`: the request body for
  one subscription, with the salt and sender key drawn from the system
  CSPRNG. `webpush_encrypt_with(randomness, ...)` takes them from a
  `WebPushRandomness` conformer instead (`SystemWebPushRandomness` is the
  system one); a conformer must never return the same value twice.
- `webpush_decrypt(ua_private, ua_public, auth_secret, body)`: the user
  agent's side.
- `p256_public_key(private_key)`: the uncompressed point
  (`0x04 || x || y`, `PUBLIC_KEY_SIZE` bytes) of a P-256 private key.
- `webpush_ikm(...)`: RFC 8291 section 3.3's input keying material.
- `aes128gcm_keys`, `aes128gcm_encrypt`, `aes128gcm_parse_header`
  (`Aes128GcmHeader`), `aes128gcm_decrypt`: the RFC 8188 content coding on its
  own (`Aes128GcmKeys` wipes its key and nonce when destroyed).
- `AUTH_SECRET_SIZE` (16), `PUBLIC_KEY_SIZE` (65), `RECORD_SIZE` (4096, the
  record size every message is written with) and `MAX_PLAINTEXT_SIZE` (3993:
  what fits in the 4096-byte body a push service must accept).

Every refusal raises an `Error` whose text starts with `webpush:` or
`aes128gcm:`.

## Examples

Every example below runs as a test when the package is built.

Encrypt a message for one subscription and decrypt it as the browser would.
The subscriber's key pair and authentication secret come from the browser's
`PushSubscription`; here they are RFC 8291's example values. Two encryptions
of the same message differ (new salt, new sender key) and both decrypt:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_crypto import hex_lower, p256_ecdh
from komira_encoding import base64_url_decode_nopad
from komira_webpush import AUTH_SECRET_SIZE, MAX_PLAINTEXT_SIZE, PUBLIC_KEY_SIZE, RECORD_SIZE, WebPushRandomness, aes128gcm_decrypt, aes128gcm_encrypt, aes128gcm_keys, aes128gcm_parse_header, p256_public_key, webpush_decrypt, webpush_encrypt, webpush_encrypt_with, webpush_ikm

def text_of(bytes: List[UInt8]) raises -> String:
    return String(StringSlice(from_utf8=Span[UInt8](bytes)))

var ua_private = base64_url_decode_nopad("q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94")
var ua_public = p256_public_key(Span[UInt8](ua_private))
var auth = base64_url_decode_nopad("BTBZMqHH6r4Tts7J_aSIgg")
assert_equal(len(auth), AUTH_SECRET_SIZE)

var message = List[UInt8](String("build 42 finished").as_bytes())
var body = webpush_encrypt(Span[UInt8](ua_public), Span[UInt8](auth), Span[UInt8](message))

# The header names the record size and carries the sender's public key.
var header = aes128gcm_parse_header(Span[UInt8](body))
assert_equal(header.rs, RECORD_SIZE)
assert_equal(len(header.keyid), PUBLIC_KEY_SIZE)
# One record: the message, a one-byte delimiter, a 16-byte tag.
assert_equal(len(body), header.records_offset + len(message) + 1 + 16)

var again = webpush_encrypt(Span[UInt8](ua_public), Span[UInt8](auth), Span[UInt8](message))
assert_false(hex_lower(Span[UInt8](body)) == hex_lower(Span[UInt8](again)))

var first = webpush_decrypt(Span[UInt8](ua_private), Span[UInt8](ua_public), Span[UInt8](auth), Span[UInt8](body))
assert_equal(text_of(first), "build 42 finished")
var second = webpush_decrypt(Span[UInt8](ua_private), Span[UInt8](ua_public), Span[UInt8](auth), Span[UInt8](again))
assert_equal(text_of(second), "build 42 finished")
```

The largest message fills the 4096-byte body a push service must accept
(RFC 8030 section 7.2); one byte more is refused before anything is
encrypted:

<!-- mojo-hidden
from std.testing import assert_equal, assert_true
from komira_crypto import hex_lower, p256_ecdh
from komira_encoding import base64_url_decode_nopad
from komira_webpush import AUTH_SECRET_SIZE, MAX_PLAINTEXT_SIZE, PUBLIC_KEY_SIZE, RECORD_SIZE, WebPushRandomness, aes128gcm_decrypt, aes128gcm_encrypt, aes128gcm_keys, aes128gcm_parse_header, p256_public_key, webpush_decrypt, webpush_encrypt, webpush_encrypt_with, webpush_ikm
-->
```mojo
var ua_private = base64_url_decode_nopad("q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94")
var ua_public = p256_public_key(Span[UInt8](ua_private))
var auth = base64_url_decode_nopad("BTBZMqHH6r4Tts7J_aSIgg")

var largest = List[UInt8](length=MAX_PLAINTEXT_SIZE, fill=UInt8(0x61))
var body = webpush_encrypt(Span[UInt8](ua_public), Span[UInt8](auth), Span[UInt8](largest))
assert_equal(len(body), 4096)

var too_long = List[UInt8](length=MAX_PLAINTEXT_SIZE + 1, fill=UInt8(0x61))
var refused = String()
try:
    _ = webpush_encrypt(Span[UInt8](ua_public), Span[UInt8](auth), Span[UInt8](too_long))
except e:
    refused = String(e)
assert_true(refused.startswith("webpush: plaintext is "))
```

With a fixed salt and sender key (a `WebPushRandomness` that replays them;
only a test may do this), the body is RFC 8291 section 5's example byte for
byte, and the intermediate values are those of its appendix A:

<!-- mojo-hidden
from std.testing import assert_equal
from komira_crypto import hex_lower, p256_ecdh
from komira_encoding import base64_url_decode_nopad
from komira_webpush import AUTH_SECRET_SIZE, MAX_PLAINTEXT_SIZE, PUBLIC_KEY_SIZE, RECORD_SIZE, WebPushRandomness, aes128gcm_decrypt, aes128gcm_encrypt, aes128gcm_keys, aes128gcm_parse_header, p256_public_key, webpush_decrypt, webpush_encrypt, webpush_encrypt_with, webpush_ikm


def text_of(bytes: List[UInt8]) raises -> String:
    return String(StringSlice(from_utf8=Span[UInt8](bytes)))


-->
```mojo module
struct ReplayRandomness(WebPushRandomness):
    var _salt: List[UInt8]
    var _key: List[UInt8]

    def __init__(out self, salt: String, key: String) raises:
        self._salt = base64_url_decode_nopad(salt)
        self._key = base64_url_decode_nopad(key)

    def salt(mut self) raises -> Array[UInt8, 16]:
        var out = Array[UInt8, 16](fill=UInt8(0))
        for i in range(16):
            out[i] = self._salt[i]
        return out^

    def sender_private_key(mut self) raises -> Array[UInt8, 32]:
        var out = Array[UInt8, 32](fill=UInt8(0))
        for i in range(32):
            out[i] = self._key[i]
        return out^


def hex_of_b64(s: String) raises -> String:
    var bytes = base64_url_decode_nopad(s)
    return hex_lower(Span[UInt8](bytes))


def main() raises:
    var as_private = base64_url_decode_nopad("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")
    var ua_public = base64_url_decode_nopad(
        "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
    )
    var auth = base64_url_decode_nopad("BTBZMqHH6r4Tts7J_aSIgg")
    var salt = base64_url_decode_nopad("DGv6ra1nlYgDCS1FRnbzlw")

    var as_public = p256_public_key(Span[UInt8](as_private))
    var ecdh = p256_ecdh(Span[UInt8](as_private), Span[UInt8](ua_public))
    var ikm = webpush_ikm(Span[UInt8](ecdh), Span[UInt8](auth), Span[UInt8](ua_public), Span[UInt8](as_public))
    assert_equal(hex_lower(Span[UInt8](ikm)), hex_of_b64("S4lYMb_L0FxCeq0WhDx813KgSYqU26kOyzWUdsXYyrg"))
    var keys = aes128gcm_keys(Span[UInt8](ikm), Span[UInt8](salt))
    assert_equal(hex_lower(Span[UInt8](keys.cek)), hex_of_b64("oIhVW04MRdy2XN9CiKLxTg"))
    assert_equal(hex_lower(Span[UInt8](keys.nonce)), hex_of_b64("4h_95klXJ5E_qnoN"))

    var randomness = ReplayRandomness("DGv6ra1nlYgDCS1FRnbzlw", "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")
    var plaintext = base64_url_decode_nopad("V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24")
    var body = webpush_encrypt_with(randomness, Span[UInt8](ua_public), Span[UInt8](auth), Span[UInt8](plaintext))
    assert_equal(
        hex_lower(Span[UInt8](body)),
        hex_of_b64(
            "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml"
            + "mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT"
            + "pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
        ),
    )

    # The user agent reads it with its own private key.
    var ua_private = base64_url_decode_nopad("q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94")
    var opened = webpush_decrypt(Span[UInt8](ua_private), Span[UInt8](ua_public), Span[UInt8](auth), Span[UInt8](body))
    assert_equal(text_of(opened), "When I grow up, I want to be a watermelon")
```

The `aes128gcm` content coding on its own, on RFC 8188's examples: section
3.1 encrypts byte for byte with an empty key id, and section 3.2's body of two
25-byte records (key id `a1`) decrypts to the same text:

<!-- mojo-hidden
from std.testing import assert_equal
from komira_crypto import hex_lower, p256_ecdh
from komira_encoding import base64_url_decode_nopad
from komira_webpush import AUTH_SECRET_SIZE, MAX_PLAINTEXT_SIZE, PUBLIC_KEY_SIZE, RECORD_SIZE, WebPushRandomness, aes128gcm_decrypt, aes128gcm_encrypt, aes128gcm_keys, aes128gcm_parse_header, p256_public_key, webpush_decrypt, webpush_encrypt, webpush_encrypt_with, webpush_ikm

def text_of(bytes: List[UInt8]) raises -> String:
    return String(StringSlice(from_utf8=Span[UInt8](bytes)))

def hex_of_b64(s: String) raises -> String:
    var bytes = base64_url_decode_nopad(s)
    return hex_lower(Span[UInt8](bytes))
-->
```mojo
var ikm = base64_url_decode_nopad("yqdlZ-tYemfogSmv7Ws5PQ")
var salt = base64_url_decode_nopad("I1BsxtFttlv3u_Oo94xnmw")
var walrus = List[UInt8](String("I am the walrus").as_bytes())
var no_keyid = List[UInt8]()
var body = aes128gcm_encrypt(Span[UInt8](ikm), Span[UInt8](salt), Span[UInt8](no_keyid), 4096, Span[UInt8](walrus))
assert_equal(
    hex_lower(Span[UInt8](body)),
    hex_of_b64("I1BsxtFttlv3u_Oo94xnmwAAEAAA-NAVub2qFgBEuQKRapoZu-IxkIva3MEB1PD-ly8Thjg"),
)
assert_equal(text_of(aes128gcm_decrypt(Span[UInt8](ikm), Span[UInt8](body))), "I am the walrus")

var two_records = base64_url_decode_nopad(
    "uNCkWiNYzKTnBN9ji3-qWAAAABkCYTHOG8chz_gnvgOqdGYovxyjuqRyJFjEDyoF1Fvkj6hQPdPHI51OEUKEpgz3SsLWIqS_uA"
)
var header = aes128gcm_parse_header(Span[UInt8](two_records))
assert_equal(header.rs, 25)
assert_equal(text_of(header.keyid), "a1")
var ikm2 = base64_url_decode_nopad("BO3ZVPxUlnLORbVGMpbT1Q")
assert_equal(text_of(aes128gcm_decrypt(Span[UInt8](ikm2), Span[UInt8](two_records))), "I am the walrus")
```
