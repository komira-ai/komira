"""Binary-to-text encodings: base64, base64url, base32 and hex.

Pure Mojo, no dependencies. Every function takes and returns safe types:
`Span[UInt8]` (or `String`) in, `String` or `List[UInt8]` out.

| scheme | encode | decode |
|---|---|---|
| base64 (RFC 4648 section 4) | `base64_encode` (padded) | `base64_decode` (padding required) |
| base64url (RFC 4648 section 5) | `base64_url_encode` (padded), `base64_url_encode_nopad` (RFC 7515 section 2) | `base64_url_decode` (padded or not), `base64_url_decode_nopad` (padding rejected) |
| base32 (RFC 4648 section 6) | `base32_encode` (padded), `base32_encode_nopad` | `base32_decode` (either case, padded or not) |
| hex (RFC 4648 section 8) | `hex_encode` (lower case) | `hex_decode` (either case) |

Decoding is strict. It rejects, with a named error giving the byte position
(see `errors.mojo`): any byte outside the alphabet, INCLUDING whitespace and
line breaks (RFC 4648 section 3.3); `=` anywhere but the trailing padding; padding
that is missing where required, present where not allowed, or incomplete; a
symbol count no input encodes to; and non-zero unused bits in the last symbol
(RFC 4648 section 3.5), so every accepted input is the unique canonical encoding of
its output. Nothing is ever skipped. An error message never contains input
bytes.

Constant time. Decoding (and encoding) does no table lookup and no branch on
the data: symbols map to values by arithmetic range checks, the way
BoringSSL's constant-time base64 decoder does, and validity is accumulated
into a mask that is tested once, after the whole input has been processed.
What the timing may reveal: the input length, the number of trailing `=`
(fixed by the length for valid input), the output length, and, for invalid
input, that it was invalid and where the first invalid byte is (the error
says so anyway). Limits: the guarantee is about this source code. The
compiler may in principle turn a mask select into a branch (there is no
value barrier in Mojo to prevent it), and the output buffer and its growth
are ordinary heap memory; the decoded bytes are not zeroized after an
error. Treat it as BoringSSL-level hygiene for keys and tokens, not as a
verified constant-time implementation.
"""

from .base64 import (
    base64_encode,
    base64_decode,
    base64_url_encode,
    base64_url_encode_nopad,
    base64_url_decode,
    base64_url_decode_nopad,
)
from .base32 import base32_encode, base32_encode_nopad, base32_decode
from .hex import hex_encode, hex_decode
from .errors import (
    INVALID_CHARACTER,
    INVALID_PADDING,
    INVALID_LENGTH,
    NON_CANONICAL,
    error_kind,
)
