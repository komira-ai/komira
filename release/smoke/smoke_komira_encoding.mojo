# =============================================================================
# release/smoke/smoke_komira_encoding.mojo -- the program the gamma stage's
#   validation `install` runs (release/machine.textproto) against
#   komira_encoding as a consumer gets it: installed from the channel inside a
#   digest-pinned container. kci copies this file into the container and
#   requires the line `komira_encoding validation: N of N checks passed` with
#   N > 0, and a zero exit.
#
# release/smoke/BUCK also builds it against the in-repository
# //src/komira_encoding and `./buck2 test //...` runs it, so an API change
# fails this repository's build and tests before it can fail a release.
# =============================================================================
#
# The consumer's check: import the published package and use it. It states
# its own number of checks and prints "N of N", so a run that stops early
# or checks nothing is not a pass.
from komira_encoding import (
    base32_decode,
    base32_encode,
    base64_decode,
    base64_encode,
    base64_url_decode,
    base64_url_decode_nopad,
    base64_url_encode,
    base64_url_encode_nopad,
    error_kind,
    hex_decode,
    hex_encode,
    pem_decode,
    pem_encode,
    pem_label,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


struct Checks(Movable):
    var run: Int
    var passed: Int

    def __init__(out self):
        self.run = 0
        self.passed = 0

    def expect(mut self, ok: Bool, what: String):
        self.run += 1
        if ok:
            self.passed += 1
        else:
            print("FAILED: " + what)

    def expect_text(mut self, got: String, want: String, what: String):
        self.expect(got == want, what + ": got '" + got + "', want '" + want + "'")

    def expect_kind(mut self, kind: String, want: String, what: String):
        self.expect(kind == want, what + ": error kind '" + kind + "', want '" + want + "'")


def _decode_error_kind(scheme: String, text: String) -> String:
    try:
        if scheme == "base64":
            _ = base64_decode(text)
        elif scheme == "hex":
            _ = hex_decode(text)
        else:
            _ = base32_decode(text)
    except e:
        return error_kind(e)
    return String("no error")


def main() raises:
    var c = Checks()
    # RFC 4648 section 10: the test vectors, encode and decode.
    var plain = List[String]()
    plain.append("")
    plain.append("f")
    plain.append("fo")
    plain.append("foo")
    plain.append("foob")
    plain.append("fooba")
    plain.append("foobar")
    var b64 = List[String]()
    b64.append("")
    b64.append("Zg==")
    b64.append("Zm8=")
    b64.append("Zm9v")
    b64.append("Zm9vYg==")
    b64.append("Zm9vYmE=")
    b64.append("Zm9vYmFy")
    var b32 = List[String]()
    b32.append("")
    b32.append("MY======")
    b32.append("MZXQ====")
    b32.append("MZXW6===")
    b32.append("MZXW6YQ=")
    b32.append("MZXW6YTB")
    b32.append("MZXW6YTBOI======")
    var hx = List[String]()
    hx.append("")
    hx.append("66")
    hx.append("666f")
    hx.append("666f6f")
    hx.append("666f6f62")
    hx.append("666f6f6261")
    hx.append("666f6f626172")
    for i in range(len(plain)):
        var data = _bytes(plain[i])
        c.expect_text(base64_encode(data), b64[i], "base64_encode '" + plain[i] + "'")
        c.expect(_same(base64_decode(b64[i]), data), "base64_decode '" + b64[i] + "'")
        c.expect_text(base32_encode(data), b32[i], "base32_encode '" + plain[i] + "'")
        c.expect(_same(base32_decode(b32[i]), data), "base32_decode '" + b32[i] + "'")
        c.expect_text(hex_encode(data), hx[i], "hex_encode '" + plain[i] + "'")
        c.expect(_same(hex_decode(hx[i]), data), "hex_decode '" + hx[i] + "'")
    # Every byte value, through every scheme and back.
    var all = List[UInt8]()
    for i in range(256):
        all.append(UInt8(i))
    c.expect(_same(base64_decode(base64_encode(all)), all), "base64 round trip of all 256 byte values")
    c.expect(_same(base64_url_decode(base64_url_encode(all)), all), "base64url round trip of all 256 byte values")
    c.expect(_same(base64_url_decode_nopad(base64_url_encode_nopad(all)), all), "base64url nopad round trip of all 256 byte values")
    c.expect(_same(base32_decode(base32_encode(all)), all), "base32 round trip of all 256 byte values")
    c.expect(_same(hex_decode(hex_encode(all)), all), "hex round trip of all 256 byte values")
    # base64url: the two symbols that differ from base64, and the unpadded form.
    var sym = List[UInt8]()
    sym.append(0xFB)
    sym.append(0xFF)
    sym.append(0xFE)
    c.expect_text(base64_encode(sym), "+//+", "base64 of fb fffe")
    c.expect_text(base64_url_encode(sym), "-__-", "base64url of fb ff fe")
    var two = List[UInt8]()
    two.append(0xFB)
    two.append(0xFF)
    c.expect_text(base64_url_encode(two), "-_8=", "base64url of fb ff")
    c.expect_text(base64_url_encode_nopad(two), "-_8", "base64url nopad of fb ff")
    # The named errors: strict decoding refuses what is not canonical.
    c.expect_kind(_decode_error_kind("base64", "Zm9v YmFy"), "InvalidCharacter", "whitespace in base64")
    c.expect_kind(_decode_error_kind("base64", "Zm9vYg"), "InvalidPadding", "missing base64 padding")
    c.expect_kind(_decode_error_kind("base64", "Zh=="), "NonCanonical", "non-zero unused bits")
    c.expect_kind(_decode_error_kind("hex", "abc"), "InvalidLength", "odd number of hex digits")
    c.expect_kind(_decode_error_kind("hex", "zz"), "InvalidCharacter", "a non-hex digit")
    c.expect_kind(_decode_error_kind("base32", "MZXW6YT!"), "InvalidCharacter", "a character outside base32")
    # PEM armor: encode, read the label, decode, and refuse the wrong label.
    var der = List[UInt8]()
    for i in range(100):
        der.append(UInt8((i * 7 + 3) & 0xFF))
    var pem = pem_encode("CERTIFICATE", der)
    c.expect(pem.startswith("-----BEGIN CERTIFICATE-----\n"), "pem_encode starts with its BEGIN line")
    c.expect_text(pem_label(pem), "CERTIFICATE", "pem_label")
    c.expect(_same(pem_decode(pem, "CERTIFICATE"), der), "pem round trip")
    var kind = String("no error")
    try:
        _ = pem_decode(pem, "PRIVATE KEY")
    except e:
        kind = error_kind(e)
    c.expect_kind(kind, "LabelMismatch", "pem_decode with the wrong label")
    print("komira_encoding validation: " + String(c.passed) + " of " + String(c.run) + " checks passed")
    if c.passed != c.run:
        raise Error("komira_encoding validation failed")
