# The digest the corpus hashes use, against published vectors and against
# komira_crypto.
#
# What each case proves:
# - test_published_vectors: the FIPS 180-4 examples (the empty text, "abc", the
#   448-bit message whose length spills into a second block, and the 896-bit
#   message) give the published digests.
# - test_every_length_matches_komira_crypto: the empty text and every length
#   from 1 to 200 bytes give the digest komira_crypto gives, so the padding
#   boundaries (55, 56, 63, 64, 65, 119, 120, 128 bytes) and multi-block
#   messages are right.
# - test_a_long_text: a text of 100 000 bytes gives komira_crypto's digest.
# - test_bytes_above_ascii: UTF-8 text with bytes of 0x80 and above hashes as
#   its bytes (a byte widened with sign extension would not).

from std.testing import assert_equal

from komira_bench_corpus import sha256_hex
from komira_crypto import hex_lower, sha256_string


def _reference(text: String) -> String:
    return hex_lower(Span(sha256_string(text)))


def test_published_vectors() raises:
    assert_equal(
        sha256_hex(String("")),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    )
    assert_equal(
        sha256_hex(String("abc")),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    )
    assert_equal(
        sha256_hex(
            String("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
        ),
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
    )
    assert_equal(
        sha256_hex(
            String(
                "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn"
                "hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
            )
        ),
        "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1",
    )


def test_every_length_matches_komira_crypto() raises:
    var text = String("")
    assert_equal(sha256_hex(text), _reference(text))
    for n in range(1, 201):
        text += String(chr(97 + (n * 7) % 26))
        assert_equal(sha256_hex(text), _reference(text), "length " + String(n))


def test_a_long_text() raises:
    var block = String("0123456789abcdef")
    var text = String("")
    for _ in range(6250):
        text += block
    assert_equal(text.byte_length(), 100000)
    assert_equal(sha256_hex(text), _reference(text))


def test_bytes_above_ascii() raises:
    var raw = List[UInt8]()
    raw.extend(String("caf").as_bytes())
    raw.append(UInt8(0xC3))
    raw.append(UInt8(0xA9))
    raw.extend(String(" select ").as_bytes())
    raw.append(UInt8(0xE2))
    raw.append(UInt8(0x82))
    raw.append(UInt8(0xAC))
    raw.append(UInt8(0x20))
    raw.append(UInt8(0xF0))
    raw.append(UInt8(0x9F))
    raw.append(UInt8(0x98))
    raw.append(UInt8(0x80))
    var text = String(unsafe_from_utf8=Span(raw))
    assert_equal(sha256_hex(text), _reference(text))


def main() raises:
    test_published_vectors()
    test_every_length_matches_komira_crypto()
    test_a_long_text()
    test_bytes_above_ascii()
    print("all sha256 tests passed")
