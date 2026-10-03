# =============================================================================
# test_orc_lzo1x_decompress.mojo — LZO1X decoder golden vectors.
# =============================================================================
#
# # WHERE THESE BYTES CAME FROM
#
# Every `_C_*` constant below is the VERBATIM output of the reference encoder
# — liblzo2 2.10 `lzo1x_1_compress`, or `lzo1x_999_compress` for the two cases
# the fast encoder never emits — captured once and checked in, because the
# library itself is not a dependency. Each was validated at capture time by decoding it with liblzo2's
# OWN `lzo1x_decompress_safe` and asserting the result equalled the encoder's
# input, so no fixture can be a mutual delusion between our encoder and our
# decoder: THERE IS NO LZO ENCODER IN THIS TREE. That is the point. This
# decoder cannot be tested by round-trip — only against foreign bytes.
#
# # COVERAGE IS BY OPCODE, NOT BY VIBES
#
# The LZO1X instruction set is M1 / M2 / M3 / M4, the literal run, the
# first-literal-run form, the zero-run length extension (at three different
# bases), the 1..3 byte trailing literal run, and the end-of-stream marker. The
# corpus below was chosen by decoding candidate encodings under an
# opcode-counting harness and keeping the SMALLEST carrier of each class. Two
# classes — M1, and the first-literal-run form — are unreachable from
# `lzo1x_1` at any input, and required `lzo1x_999`: a second reference encoder
# for the same format, which is also a second opinion on what the format is.
#
# # THE NEGATIVE CASES ARE THE OTHER HALF
#
# `test_lzo1x_truncation_always_raises` feeds proper prefixes of every fixture
# to the decoder and requires each to raise. For a decoder pointed at customer
# bytes, failing loudly on malformed input is the property that matters —
# liblzo2's NON-safe entry point performs no bounds checks at all and is
# documented as usable only on trusted data.
#
# ⚠ DO NOT "REGENERATE" THESE. There is no encoder in the tree to regenerate
# them with, and adding one would introduce the GPL dependency this decoder
# exists to avoid.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_orc.lzo1x_decompress import lzo1x_decompress
from komira_orc import decompress_stream, ORC_COMPRESSION_LZO


comptime _LIMIT: Int = 1 << 30


# =============================================================================
# Fixture helpers
# =============================================================================


def _nib(c: UInt8) raises -> UInt8:
    if c >= 48 and c <= 57:  # '0'..'9'
        return c - 48
    if c >= 97 and c <= 102:  # 'a'..'f'
        return c - 87
    raise Error("fixture hex has a non-hex digit")


def _hex(s: StaticString) raises -> List[UInt8]:
    """Decode a hex StaticString to bytes. The golden vectors are stored as hex
    so they stay readable and diffable in review."""
    var b = s.as_bytes()
    if len(b) % 2 != 0:
        raise Error("fixture hex has an odd length")
    var out = List[UInt8](capacity=len(b) // 2)
    for i in range(0, len(b), 2):
        out.append((_nib(b[i]) << 4) | _nib(b[i + 1]))
    return out^


def _zeros(n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _i in range(n):
        out.append(0)
    return out^


def _repeat2(a: UInt8, b: UInt8, n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=2 * n)
    for _i in range(n):
        out.append(a)
        out.append(b)
    return out^


def _text_times(n: Int) -> List[UInt8]:
    var s = String("the quick brown fox jumps over the lazy dog. ")
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b) * n)
    for _i in range(n):
        for i in range(len(b)):
            out.append(b[i])
    return out^


def _lcg(n: Int, seed: Int) -> List[UInt8]:
    """The recurrence the fixture generator used, so a large expected output is
    reproduced here instead of embedded as kilobytes of hex."""
    var out = List[UInt8](capacity=n)
    var s = UInt64(seed)
    for _i in range(n):
        s = (s * UInt64(1103515245) + UInt64(12345)) & UInt64(0xFFFFFFFF)
        out.append(UInt8(Int((s >> 16) & UInt64(0xFF))))
    return out^


def _far_match_corpus() -> List[UInt8]:
    var head = _text_times(4)
    var mid = _repeat2(0x5A, 0xA5, 10000)
    var tail = _text_times(4)
    var out = List[UInt8]()
    out.extend(Span(head))
    out.extend(Span(mid))
    out.extend(Span(tail))
    return out^


def _mixed_corpus() -> List[UInt8]:
    var a = _lcg(300, 7)
    var b = _text_times(6)
    var c = _lcg(300, 99)
    var unit = List[UInt8]()
    unit.extend(Span(a))
    unit.extend(Span(b))
    unit.extend(Span(c))
    unit.extend(Span(b))
    var out = List[UInt8]()
    for _i in range(3):
        out.extend(Span(unit))
    return out^


def _flr_corpus() raises -> List[UInt8]:
    """head(3) + 2046 zero bytes + lit(4) + head(3). The zeros put the trailing
    `head` at output distance 2053 — inside the 2049..3072 window that is the
    ONLY range the first-literal-run opcode can express."""
    var head = _hex(_FLR_HEAD_HEX)
    var lit = _hex(_FLR_LIT_HEX)
    var z = _zeros(2046)
    var out = List[UInt8]()
    out.extend(Span(head))
    out.extend(Span(z))
    out.extend(Span(lit))
    out.extend(Span(head))
    return out^


def _decode(comp: List[UInt8], hint: Int) raises -> List[UInt8]:
    var out = List[UInt8]()
    lzo1x_decompress(Span(comp), hint, _LIMIT, out)
    return out^


def _assert_bytes_equal(
    got: List[UInt8], want: List[UInt8], label: StaticString
) raises:
    assert_equal(len(got), len(want), String(label) + ": decoded length")
    for i in range(len(got)):
        if got[i] != want[i]:
            raise Error(
                String(label)
                + ": byte "
                + String(i)
                + " decoded as "
                + String(Int(got[i]))
                + ", expected "
                + String(Int(want[i]))
            )


# =============================================================================
# Golden vectors — liblzo2 2.10 reference-encoder output (see header).
# =============================================================================

# The two unique byte groups of the first-literal-run corpus; the 2046 zero
# bytes between them are generated (see `_flr_corpus`).
comptime _FLR_HEAD_HEX: StaticString = (
    "ea39e8"
)
comptime _FLR_LIT_HEX: StaticString = (
    "4d22a0eb"
)

# empty — the 3-byte end-of-stream marker alone
#   encoder lzo1x_1;  3 compressed byte(s) -> 0 decompressed
comptime _C_EMPTY: StaticString = (
    "110000"
)
comptime _R_EMPTY: StaticString = (
    ""
)

# one_byte — opens mid-match: a first byte of 18..20 is the trailing-literal state
#   encoder lzo1x_1;  5 compressed byte(s) -> 1 decompressed
comptime _C_ONE_BYTE: StaticString = (
    "1241110000"
)
comptime _R_ONE_BYTE: StaticString = (
    "41"
)

# short_text — opens with a direct literal run (first byte > 20)
#   encoder lzo1x_1;  17 compressed byte(s) -> 13 decompressed
comptime _C_SHORT_TEXT: StaticString = (
    "1e68656c6c6f206f7263206c7a6f110000"
)
comptime _R_SHORT_TEXT: StaticString = (
    "68656c6c6f206f7263206c7a6f"
)

# text_rep — M2 + M3 + the M3 length extension + trailing literals
#   encoder lzo1x_1;  78 compressed byte(s) -> 450 decompressed
comptime _C_TEXT_REP: StaticString = (
    "000d74686520717569636b2062726f776e20666f78206a756d7073206f76657220780306"
    "6c617a7920646f672e95017120005cb0000002206f76657220746865206c617a7920646f"
    "672e20110000"
)
comptime _R_TEXT_REP: StaticString = (
    "74686520717569636b2062726f776e20666f78206a756d7073206f76657220746865206c"
    "617a7920646f672e2074686520717569636b2062726f776e20666f78206a756d7073206f"
    "76657220746865206c617a7920646f672e2074686520717569636b2062726f776e20666f"
    "78206a756d7073206f76657220746865206c617a7920646f672e2074686520717569636b"
    "2062726f776e20666f78206a756d7073206f76657220746865206c617a7920646f672e20"
    "74686520717569636b2062726f776e20666f78206a756d7073206f76657220746865206c"
    "617a7920646f672e2074686520717569636b2062726f776e20666f78206a756d7073206f"
    "76657220746865206c617a7920646f672e2074686520717569636b2062726f776e20666f"
    "78206a756d7073206f76657220746865206c617a7920646f672e2074686520717569636b"
    "2062726f776e20666f78206a756d7073206f76657220746865206c617a7920646f672e20"
    "74686520717569636b2062726f776e20666f78206a756d7073206f76657220746865206c"
    "617a7920646f672e2074686520717569636b2062726f776e20666f78206a756d7073206f"
    "76657220746865206c617a7920646f672e20"
)

# min_M1 — the M1 opcode (a 2-byte match) -- only lzo1x_999 emits it
#   encoder lzo1x_999;  34 compressed byte(s) -> 41 decompressed
comptime _C_MIN_M1: StaticString = (
    "18010000020202016500010c0152010000400154025800600258027e000102110000"
)
comptime _R_MIN_M1: StaticString = (
    "010000020202010201020101020200000200000101020100000001010102020002010101"
    "0102020102"
)

# min_trailing_lit_3 — a 3-byte trailing literal run
#   encoder lzo1x_999;  24 compressed byte(s) -> 41 decompressed
comptime _C_MIN_TRAILING_LIT_3: StaticString = (
    "140100016b000100006800d800c002710000c10400110000"
)
comptime _R_MIN_TRAILING_LIT_3: StaticString = (
    "010001010001010100000100000101000001000001000101010000010101000000010001"
    "0100010100"
)

# min_flr_m2 — the first-literal-run form: distance base 1 + 2048
#   encoder lzo1x_999;  26 compressed byte(s) -> 2056 decompressed
comptime _C_MIN_FLR_M2: StaticString = (
    "15ea39e8002000000000000000e30000014d22a0eb0001110000"
)

# incompressible — long literal runs + the literal length extension
#   encoder lzo1x_1;  1032 compressed byte(s) -> 1024 decompressed
comptime _C_INCOMPRESSIBLE: StaticString = (
    "00000000f171471d94ec8993c744bcd8cfcb3cc5a66819a8e6caa4e23b69bd418941da1e"
    "dc4ed83613c682494c19e2740ea94a4f394920c6ae776db8be592551547a3428e1414d18"
    "0a3571de14f241770bea0537b5dd78a93a16592a906bb244a8f2e6cb5a837eba11f2b0cb"
    "3609b3d85e48c5f4325cf848225fc0afc9d53e111e624a80604d4314c0b59687cb950f8f"
    "9e79e2ffc8fd789cfd0afbc080d0a0b14e83b7be0bd5741fae367b8aebce2d956336b5cf"
    "8efad19c64cf60d4ce95b01bd00b85fe7354e9d2732db74dadebe5e1473794dc9d8ad941"
    "ef664964cb5a47473bb30db7af027b26a952a2472b26106ce035d99f0ce46a8235870de7"
    "8f583b2e2833a562d8170112e65d95f17ab6842dc7e6dc8ff5425b57cfea04d531c766c7"
    "2f43a77606cb538fc306e7c2b5d21b1c9403f3256eda84b9554787a7cadf9f0be79b6a6b"
    "50564994d804f033f2b3ac32de4477d88fe6be9f5e56ecd471d7bef1e9f346bacff0bc1a"
    "bc1108bb4a9210673e61c121729cdf0283ce8dd540e99c72cd0393db9ad1821808e487d2"
    "d5a51db14b1128772d35c1d95c69c1214c4c0f852b83aa44cb3075865334c6f1aa25ad0b"
    "9f0e0452d8e93b1d81dde031b038f1229a2be27078476c5d37bb1b8fe24a966ad00fad2b"
    "8df125c589e4437c82e41942b3b292d4ba4d3f944a2fe025954db2c976cb7c7a628357c9"
    "0d34407adb8a5fdd0dd214eaa879c72424496c2ada64d91d2bfcc7b56fd8aa22a48631a4"
    "d3609be94141c02a5b05da045fc21817cac7e1608559e857ce28f4c8e7936d7181a0a661"
    "e7b9ec0beb27522d91503a637db0a48a1c9936d595aa0fb16e114c5afe80563a97f0f205"
    "6f18069653ac2c860a56f8918a7509aadd98d2d8d1b926d7623a856ee8a029910111ce37"
    "3c8e45f98af1b77065a6ba4bbd291532a743535ec5040af5737fe826b6488309e5aedd34"
    "15b9b81d46e29f324f95b1ba89672c693e17bdc6d0468a3da9f6fb03e6c44caec2e5d490"
    "c4e212d7a8137c650fdd0870e6ab77d996ad644df053101ed688eadfaaafe1c1785e6ab0"
    "e3dd502dd05d3fead4f80e275e6cd0cfa49799514fb21040e54db9a9fa0eff3816290409"
    "659f294f21365ca7c03b243addfa6e95e7fa15488bf93340e2aa2ae45a3170f2665a1e18"
    "e59d385253d2ba06b2b467e13618516fb3e9277dc7ea412fc72b6de06a4877bc38657a1f"
    "b0e9e9ac3cfd5c2dd5c31c2e76576d5842869e8e7451d1c90a208bb431c6fa076f380aa4"
    "930d26725cb5cefdec79ddcaeb36987b7ad976a8de99b277e9f7910127777364ce1c9ca8"
    "63a4c0532c8850ca59b2876ef1fc33727e6d447e77321605725e7e67066196c6814a48a8"
    "4fbc9d5125b2c3def0f2e02181529940f5ae610ce5a482225316ecc44f5dc0756c4d9c56"
    "e7eda44390f355ad8002093579a24a0e1b03d70fcc110000"
)
comptime _R_INCOMPRESSIBLE: StaticString = (
    "71471d94ec8993c744bcd8cfcb3cc5a66819a8e6caa4e23b69bd418941da1edc4ed83613"
    "c682494c19e2740ea94a4f394920c6ae776db8be592551547a3428e1414d180a3571de14"
    "f241770bea0537b5dd78a93a16592a906bb244a8f2e6cb5a837eba11f2b0cb3609b3d85e"
    "48c5f4325cf848225fc0afc9d53e111e624a80604d4314c0b59687cb950f8f9e79e2ffc8"
    "fd789cfd0afbc080d0a0b14e83b7be0bd5741fae367b8aebce2d956336b5cf8efad19c64"
    "cf60d4ce95b01bd00b85fe7354e9d2732db74dadebe5e1473794dc9d8ad941ef664964cb"
    "5a47473bb30db7af027b26a952a2472b26106ce035d99f0ce46a8235870de78f583b2e28"
    "33a562d8170112e65d95f17ab6842dc7e6dc8ff5425b57cfea04d531c766c72f43a77606"
    "cb538fc306e7c2b5d21b1c9403f3256eda84b9554787a7cadf9f0be79b6a6b50564994d8"
    "04f033f2b3ac32de4477d88fe6be9f5e56ecd471d7bef1e9f346bacff0bc1abc1108bb4a"
    "9210673e61c121729cdf0283ce8dd540e99c72cd0393db9ad1821808e487d2d5a51db14b"
    "1128772d35c1d95c69c1214c4c0f852b83aa44cb3075865334c6f1aa25ad0b9f0e0452d8"
    "e93b1d81dde031b038f1229a2be27078476c5d37bb1b8fe24a966ad00fad2b8df125c589"
    "e4437c82e41942b3b292d4ba4d3f944a2fe025954db2c976cb7c7a628357c90d34407adb"
    "8a5fdd0dd214eaa879c72424496c2ada64d91d2bfcc7b56fd8aa22a48631a4d3609be941"
    "41c02a5b05da045fc21817cac7e1608559e857ce28f4c8e7936d7181a0a661e7b9ec0beb"
    "27522d91503a637db0a48a1c9936d595aa0fb16e114c5afe80563a97f0f2056f18069653"
    "ac2c860a56f8918a7509aadd98d2d8d1b926d7623a856ee8a029910111ce373c8e45f98a"
    "f1b77065a6ba4bbd291532a743535ec5040af5737fe826b6488309e5aedd3415b9b81d46"
    "e29f324f95b1ba89672c693e17bdc6d0468a3da9f6fb03e6c44caec2e5d490c4e212d7a8"
    "137c650fdd0870e6ab77d996ad644df053101ed688eadfaaafe1c1785e6ab0e3dd502dd0"
    "5d3fead4f80e275e6cd0cfa49799514fb21040e54db9a9fa0eff3816290409659f294f21"
    "365ca7c03b243addfa6e95e7fa15488bf93340e2aa2ae45a3170f2665a1e18e59d385253"
    "d2ba06b2b467e13618516fb3e9277dc7ea412fc72b6de06a4877bc38657a1fb0e9e9ac3c"
    "fd5c2dd5c31c2e76576d5842869e8e7451d1c90a208bb431c6fa076f380aa4930d26725c"
    "b5cefdec79ddcaeb36987b7ad976a8de99b277e9f7910127777364ce1c9ca863a4c0532c"
    "8850ca59b2876ef1fc33727e6d447e77321605725e7e67066196c6814a48a84fbc9d5125"
    "b2c3def0f2e02181529940f5ae610ce5a482225316ecc44f5dc0756c4d9c56e7eda44390"
    "f355ad8002093579a24a0e1b03d70fcc"
)

# long_match — one huge back-reference: 65536 B out of 310 B
#   encoder lzo1x_1;  310 compressed byte(s) -> 65536 decompressed
comptime _C_LONG_MATCH: StaticString = (
    "034142414241422000000000000000000000000000000000000000000000000000000000"
    "000000000000000000000000000000000000000000000000000000000000000000000000"
    "000000000000000000000000000000000000000000000000000000000000000000000000"
    "000000000000000000000000000000000000000000000000000000000000000000000000"
    "000000000000000000000000000000000000000000000000000000000000000000000000"
    "00000000000000000000000000000000000000008b14000d414241424142414241424142"
    "414241422000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000000b0400"
    "0f414241424142414241424142414241424142110000"
)

# far_match — the M4 length extension, at distance >= 16384
#   encoder lzo1x_1;  167 compressed byte(s) -> 20360 decompressed
comptime _C_FAR_MATCH: StaticString = (
    "000d74686520717569636b2062726f776e20666f78206a756d7073206f76657220780306"
    "6c617a7920646f672e9501712061b2005aa5200000000000000000000000000000000000"
    "000000000000000000000000000000000000000000000000000000000000000000000000"
    "000000000000000000000000000000000000000000000000004b040012d43a107a9c3a3a"
    "18020e657220746865206c617a7920646f672e20110000"
)

# zero_run — 70000 zero bytes -- maximal run-length back-referencing
#   encoder lzo1x_1;  328 compressed byte(s) -> 70000 decompressed
comptime _C_ZERO_RUN: StaticString = (
    "020000000000200000000000000000000000000000000000000000000000000000000000"
    "000000000000000000000000000000000000000000000000000000000000000000000000"
    "000000000000000000000000000000000000000000000000000000000000000000000000"
    "000000000000000000000000000000000000000000000000000000000000000000000000"
    "000000000000000000000000000000000000000000000000000000000000000000000000"
    "000000000000000000000000000000000000008b10000d00000000000000000000000000"
    "000000200000000000000000000000000000000000000000000000000000000000000000"
    "000000000000000000000000000000000000000000000000000000000000000000000000"
    "000000000000000000000000008c00000001000000000000000000000000000000000000"
    "00110000"
)

# mixed — alternating incompressible and repetitive regions
#   encoder lzo1x_1;  732 compressed byte(s) -> 3420 decompressed
comptime _C_MIXED: StaticString = (
    "0000646c4e74921325222e31a1cd13be12ed426966ce24fc23d7da8d2097616a06956ec2"
    "8ad403136828d4571e3c5dee6e5ec04a91115f5d3b513ec253a416ad6ee5389411d0289a"
    "a34cf5c0347c59caf08495f3611b0b5068d59804f92eb7299955577999be78c010668702"
    "99e57f6cd235bcfb8f449deee23be1eccc8cbff5bfbec20bdbf86b9ce54f85b607cf46e9"
    "4a4b2afbd4e58f4fe15c11128218a32b18f772df8fd57a475bdee4743493265c919dd98b"
    "e654598a9d0f1f0ed42adde0dcd85e906ead1cd9abea9ed3da8898dbe003c1427eeb72b8"
    "4d2c03777b18e52f43397fb42ed9ca6a0b4dab6caf06137f6d55d9b9540152f12b8bb6e5"
    "2d3c322e85f3cce488b0fb11b4df02d66c65105f716c198820ef724c6e042ff2a3ec3cf6"
    "d9dc3eb8348927e7de769babc9fd0674686520717569636b2062726f776e20666f78206a"
    "756d7073206f76657220746865206c617a7920646f672e2074686520717569636b206272"
    "6f776e20666f78206a756d7073206f7620a4b000000023b0bda4e809554ceb0ed36c7868"
    "70aa219dbf8af64163789fdc91943c9a493ffdb5536980a3fc99eeff8eb9d43790a7c1fb"
    "c27ca561d79ae4d8f0783dd3dd2d5e3112bd436e6b27528c9f2a38bf86db81db0be8fa7e"
    "efaac6fd42ec420fa27d9a3c327828035a4e90ce40989c96099ed856d0a6ed3163febe62"
    "c0c944e752892aedeb7028fa80661fdda8d9f955d3493e834a8f7711eaf04320a0e53af3"
    "a4a8855d757e3aea97c878d00fc747949b322c7cb1798fb83ed7ce4f1b1a1dcb4f3224a3"
    "077b566d56ca12c0ac397cea18b31a573e3e2ebc160bd506693fe4060c7f7ed9db3e7518"
    "75c666c5b90793f003237e2c27b54bb529e5d35ec22d873d94e80b15289f8e86ab13ebf6"
    "6d0a813e15dad315a5b6de3d31bc3e6f5ebaff079dc4446f25769a4db2091a6cff184074"
    "6865207175696320e5e408200000000000000000bbcc110002206f76657220746865206c"
    "617a7920646f672e20110000"
)

# =============================================================================
# Golden-vector tests — one per opcode-coverage class.
# =============================================================================

def test_lzo1x_empty() raises:
    """The 3-byte end-of-stream marker alone."""
    var comp = _hex(_C_EMPTY)
    var want = _hex(_R_EMPTY)
    _assert_bytes_equal(_decode(comp, 1), want, "empty")


def test_lzo1x_one_byte() raises:
    """Opens mid-match: a first byte of 18..20 is the trailing-literal state."""
    var comp = _hex(_C_ONE_BYTE)
    var want = _hex(_R_ONE_BYTE)
    _assert_bytes_equal(_decode(comp, 1), want, "one_byte")


def test_lzo1x_short_text() raises:
    """Opens with a direct literal run (first byte > 20)."""
    var comp = _hex(_C_SHORT_TEXT)
    var want = _hex(_R_SHORT_TEXT)
    _assert_bytes_equal(_decode(comp, 13), want, "short_text")


def test_lzo1x_text_rep() raises:
    """M2 + M3 + the M3 length extension + trailing literals."""
    var comp = _hex(_C_TEXT_REP)
    var want = _hex(_R_TEXT_REP)
    _assert_bytes_equal(_decode(comp, 450), want, "text_rep")


def test_lzo1x_min_M1() raises:
    """The M1 opcode (a 2-byte match) -- only lzo1x_999 emits it."""
    var comp = _hex(_C_MIN_M1)
    var want = _hex(_R_MIN_M1)
    _assert_bytes_equal(_decode(comp, 41), want, "min_M1")


def test_lzo1x_min_trailing_lit_3() raises:
    """A 3-byte trailing literal run."""
    var comp = _hex(_C_MIN_TRAILING_LIT_3)
    var want = _hex(_R_MIN_TRAILING_LIT_3)
    _assert_bytes_equal(_decode(comp, 41), want, "min_trailing_lit_3")


def test_lzo1x_min_flr_m2() raises:
    """The first-literal-run form: distance base 1 + 2048."""
    var comp = _hex(_C_MIN_FLR_M2)
    var want = _flr_corpus()
    _assert_bytes_equal(_decode(comp, 2056), want, "min_flr_m2")


def test_lzo1x_incompressible() raises:
    """Long literal runs + the literal length extension."""
    var comp = _hex(_C_INCOMPRESSIBLE)
    var want = _hex(_R_INCOMPRESSIBLE)
    _assert_bytes_equal(_decode(comp, 1024), want, "incompressible")


def test_lzo1x_long_match() raises:
    """One huge back-reference: 65536 B out of 310 B."""
    var comp = _hex(_C_LONG_MATCH)
    var want = _repeat2(0x41, 0x42, 32768)
    _assert_bytes_equal(_decode(comp, 65536), want, "long_match")


def test_lzo1x_far_match() raises:
    """The M4 length extension, at distance >= 16384."""
    var comp = _hex(_C_FAR_MATCH)
    var want = _far_match_corpus()
    _assert_bytes_equal(_decode(comp, 20360), want, "far_match")


def test_lzo1x_zero_run() raises:
    """70000 zero bytes -- maximal run-length back-referencing."""
    var comp = _hex(_C_ZERO_RUN)
    var want = _zeros(70000)
    _assert_bytes_equal(_decode(comp, 70000), want, "zero_run")


def test_lzo1x_mixed() raises:
    """Alternating incompressible and repetitive regions."""
    var comp = _hex(_C_MIXED)
    var want = _mixed_corpus()
    _assert_bytes_equal(_decode(comp, 3420), want, "mixed")


def _sweep_truncations(h: StaticString, label: StaticString) raises -> Int:
    """Feed proper prefixes of one fixture to the decoder; every one must
    raise. A prefix is the cheapest exhaustive source of malformed input — it
    is well-formed right up to the cut, so it exercises the bounds check of
    whichever instruction straddles the cut."""
    var comp = _hex(h)
    var step = 1 if len(comp) <= 320 else (len(comp) // 320)
    var checked = 0
    var cut = 0
    while cut < len(comp):
        var prefix = List[UInt8]()
        for i in range(cut):
            prefix.append(comp[i])
        var raised = False
        var scratch = List[UInt8]()
        try:
            lzo1x_decompress(Span(prefix), 4096, _LIMIT, scratch)
        except:
            raised = True
        if not raised:
            raise Error(
                String(label)
                + " truncated to "
                + String(cut)
                + " byte(s) decoded WITHOUT raising"
            )
        checked += 1
        cut += step
    return checked


def test_lzo1x_truncation_always_raises() raises:
    var checked = 0
    checked += _sweep_truncations(_C_EMPTY, "empty")
    checked += _sweep_truncations(_C_ONE_BYTE, "one_byte")
    checked += _sweep_truncations(_C_SHORT_TEXT, "short_text")
    checked += _sweep_truncations(_C_TEXT_REP, "text_rep")
    checked += _sweep_truncations(_C_MIN_M1, "min_M1")
    checked += _sweep_truncations(_C_MIN_TRAILING_LIT_3, "min_trailing_lit_3")
    checked += _sweep_truncations(_C_MIN_FLR_M2, "min_flr_m2")
    checked += _sweep_truncations(_C_INCOMPRESSIBLE, "incompressible")
    checked += _sweep_truncations(_C_LONG_MATCH, "long_match")
    checked += _sweep_truncations(_C_FAR_MATCH, "far_match")
    checked += _sweep_truncations(_C_ZERO_RUN, "zero_run")
    checked += _sweep_truncations(_C_MIXED, "mixed")
    assert_true(
        checked > 500,
        "truncation sweep covered only " + String(checked) + " prefixes",
    )


def test_lzo1x_trailing_garbage_raises() raises:
    """Bytes after the end-of-stream marker mean the block was mis-parsed."""
    var comp = _hex(_C_TEXT_REP)
    comp.append(0)
    var out = List[UInt8]()
    var raised = False
    try:
        lzo1x_decompress(Span(comp), 4096, _LIMIT, out)
    except:
        raised = True
    assert_true(raised, "a trailing byte after the EOS marker must raise")


def test_lzo1x_output_limit_is_enforced() raises:
    """A block that expands past the caller's limit raises instead of
    allocating. `long_match` is 310 compressed bytes expanding to 65536."""
    var comp = _hex(_C_LONG_MATCH)
    var out = List[UInt8]()
    var raised = False
    try:
        lzo1x_decompress(Span(comp), 1024, 4096, out)
    except:
        raised = True
    assert_true(raised, "a 65536-byte block must not decode under a 4096 limit")


def test_lzo1x_appends_and_cannot_reach_behind_the_block() raises:
    """`out` is appended to, and a back-reference cannot reach into what was
    already in it — each ORC chunk is an independent LZO1X block."""
    var out = List[UInt8]()
    for i in range(7):
        out.append(UInt8(200 + i))
    var comp = _hex(_C_SHORT_TEXT)
    lzo1x_decompress(Span(comp), 64, _LIMIT, out)
    var want = _hex(_R_SHORT_TEXT)
    assert_equal(len(out), 7 + len(want), "appended length")
    for i in range(7):
        assert_equal(Int(out[i]), 200 + i, "pre-existing byte was disturbed")
    for i in range(len(want)):
        assert_equal(Int(out[7 + i]), Int(want[i]), "appended byte")


# =============================================================================
# End-to-end through the ORC chunk framing — the shape a customer file holds.
# =============================================================================


def _frame(payload: List[UInt8], is_original: Bool) -> List[UInt8]:
    var header24 = (len(payload) << 1) | (1 if is_original else 0)
    var out = List[UInt8]()
    out.append(UInt8(header24 & 0xFF))
    out.append(UInt8((header24 >> 8) & 0xFF))
    out.append(UInt8((header24 >> 16) & 0xFF))
    out.extend(Span(payload))
    return out^


def test_orc_lzo_stream_single_chunk() raises:
    """One LZO chunk behind ORC's 3-byte chunk header."""
    var stream = _frame(_hex(_C_TEXT_REP), False)
    var out = decompress_stream(Span(stream), ORC_COMPRESSION_LZO, 256 * 1024)
    _assert_bytes_equal(out, _hex(_R_TEXT_REP), "orc_single_chunk")


def test_orc_lzo_stream_multi_chunk_with_original() raises:
    """Three chunks in one stream: compressed, isOriginal=1 (stored verbatim),
    compressed. The reader must concatenate them, and the third chunk's
    back-references must not reach into the first two."""
    var a = _hex(_R_TEXT_REP)
    var b = _hex(_R_SHORT_TEXT)
    var c = _hex(_R_MIN_M1)

    var stream = _frame(_hex(_C_TEXT_REP), False)
    var mid = _frame(b, True)
    var last = _frame(_hex(_C_MIN_M1), False)
    stream.extend(Span(mid))
    stream.extend(Span(last))

    var out = decompress_stream(Span(stream), ORC_COMPRESSION_LZO, 256 * 1024)
    var want = List[UInt8]()
    want.extend(Span(a))
    want.extend(Span(b))
    want.extend(Span(c))
    _assert_bytes_equal(out, want, "orc_multi_chunk")


def test_orc_lzo_stream_truncated_chunk_raises() raises:
    """A chunk header promising more payload than the stream holds."""
    var stream = _frame(_hex(_C_TEXT_REP), False)
    var short = List[UInt8]()
    for i in range(len(stream) - 5):
        short.append(stream[i])
    var raised = False
    try:
        var _bad = decompress_stream(
            Span(short), ORC_COMPRESSION_LZO, 256 * 1024
        )
    except:
        raised = True
    assert_true(raised, "a truncated LZO chunk must raise")


def main() raises:
    test_lzo1x_empty()
    test_lzo1x_one_byte()
    test_lzo1x_short_text()
    test_lzo1x_text_rep()
    test_lzo1x_min_M1()
    test_lzo1x_min_trailing_lit_3()
    test_lzo1x_min_flr_m2()
    test_lzo1x_incompressible()
    test_lzo1x_long_match()
    test_lzo1x_far_match()
    test_lzo1x_zero_run()
    test_lzo1x_mixed()
    test_lzo1x_truncation_always_raises()
    test_lzo1x_trailing_garbage_raises()
    test_lzo1x_output_limit_is_enforced()
    test_lzo1x_appends_and_cannot_reach_behind_the_block()
    test_orc_lzo_stream_single_chunk()
    test_orc_lzo_stream_multi_chunk_with_original()
    test_orc_lzo_stream_truncated_chunk_raises()
    print("test_orc_lzo1x_decompress: ALL PASS")
