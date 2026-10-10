# =============================================================================
# komira_crypto/tests/test_sha256_compress.mojo
#
# sha256_compress_blocks and sha256_compress_blocks_portable against FIPS
# 180-4 vectors: one call over the padded one-block message "abc" and one
# call over the padded two-block message
# "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq" must leave the
# state equal to the digest, and an empty input must leave it unchanged.
# Before the CPU-feature dispatch sha256_compress_blocks called the
# SHA-extension body unconditionally and died with SIGILL on an x86-64 host
# without those extensions.
#
# sha256_compress_blocks_portable forces the body a CPU without the
# extensions runs, so the vectors check it on any host.
# On Linux x86-64 sha256_compress_uses_hw must agree with the kernel's view of
# the CPU (the sha_ni flag in /proc/cpuinfo): a dispatch that picked the
# hardware body on a CPU without the extensions, or never picked it, fails
# here. Off x86-64 it must say False, since only the portable body exists
# there; /proc/cpuinfo is not read.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal

from komira_crypto.internal.asm.sha256_compress import (
    sha256_compress_blocks,
    sha256_compress_blocks_portable,
    sha256_compress_uses_hw,
)


def _iv() -> Array[UInt32, 8]:
    var st = Array[UInt32, 8](fill=UInt32(0))
    st[0] = 0x6A09E667
    st[1] = 0xBB67AE85
    st[2] = 0x3C6EF372
    st[3] = 0xA54FF53A
    st[4] = 0x510E527F
    st[5] = 0x9B05688C
    st[6] = 0x1F83D9AB
    st[7] = 0x5BE0CD19
    return st^


def _padded(msg: String) -> List[UInt8]:
    var out = List[UInt8]()
    for c in msg.as_bytes():
        out.append(c)
    var bits = UInt64(len(out) * 8)
    out.append(0x80)
    while len(out) % 64 != 56:
        out.append(0)
    for k in range(8):
        out.append(UInt8(Int((bits >> UInt64(56 - 8 * k)) & 0xFF)))
    return out^


def _state_hex(st: Array[UInt32, 8]) -> String:
    var digits = String("0123456789abcdef").as_bytes()
    var out = String()
    for i in range(8):
        for k in range(8):
            var nib = Int((st[i] >> UInt32(28 - 4 * k)) & 0xF)
            out += chr(Int(digits[nib]))
    return out


comptime _ABC = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
comptime _TWO_BLOCK_MSG = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
comptime _TWO_BLOCK = "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"


def test_dispatched_one_and_two_blocks() raises:
    var st = _iv()
    var b1 = _padded("abc")
    sha256_compress_blocks(st, Span(b1))
    assert_equal(_state_hex(st), String(_ABC), "abc")
    var st2 = _iv()
    var b2 = _padded(_TWO_BLOCK_MSG)
    assert_equal(len(b2), 128, "two blocks")
    sha256_compress_blocks(st2, Span(b2))
    assert_equal(_state_hex(st2), String(_TWO_BLOCK), "two blocks")


def test_portable_one_and_two_blocks() raises:
    var st = _iv()
    var b1 = _padded("abc")
    sha256_compress_blocks_portable(st, Span(b1))
    assert_equal(_state_hex(st), String(_ABC), "portable abc")
    var st2 = _iv()
    var b2 = _padded(_TWO_BLOCK_MSG)
    sha256_compress_blocks_portable(st2, Span(b2))
    assert_equal(_state_hex(st2), String(_TWO_BLOCK), "portable two blocks")


def test_empty_input_leaves_state() raises:
    var empty = List[UInt8]()
    var st = _iv()
    sha256_compress_blocks(st, Span(empty))
    assert_equal(_state_hex(st), _state_hex(_iv()), "dispatched, empty")
    sha256_compress_blocks_portable(st, Span(empty))
    assert_equal(_state_hex(st), _state_hex(_iv()), "portable, empty")


def _cpu_flags_have_sha_ni() raises -> Bool:
    # Linux x86-64 only: /proc/cpuinfo has a "flags" line there.
    var info: String
    with open("/proc/cpuinfo", "r") as f:
        info = f.read()
    var at = info.find("\nflags")
    assert_equal(at >= 0, True, "/proc/cpuinfo has a flags line")
    var end = info.find("\n", at + 1)
    var flags = String(info[byte=at:end]) + " "
    return flags.find(" sha_ni ") >= 0


def test_dispatch_matches_the_cpu() raises:
    comptime if not CompilationTarget.is_x86():
        # Off x86-64 the C entry has no hardware body to pick: it always runs
        # the portable one (darwin-arm64 has no /proc/cpuinfo, and an arm64
        # Linux cpuinfo lists "Features", not "flags").
        assert_equal(sha256_compress_uses_hw(), False, "portable off x86-64")
        assert_equal(sha256_compress_uses_hw(), False, "cached answer")
    elif CompilationTarget.is_linux():
        var has = _cpu_flags_have_sha_ni()
        assert_equal(sha256_compress_uses_hw(), has, "dispatch vs sha_ni")
        # The answer is cached after the first read; a second call agrees.
        assert_equal(sha256_compress_uses_hw(), has, "cached answer")
    else:
        # x86-64 off Linux is no registered platform: the dispatch reads
        # CPUID there too, and this test has no oracle for it yet.
        raise Error("test_dispatch_matches_the_cpu: no CPU-feature oracle for this OS")


def main() raises:
    test_dispatch_matches_the_cpu()
    test_dispatched_one_and_two_blocks()
    test_portable_one_and_two_blocks()
    test_empty_input_leaves_state()
    print("test_sha256_compress: 4 tests PASS")
