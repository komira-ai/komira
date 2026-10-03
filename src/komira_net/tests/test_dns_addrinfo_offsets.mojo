# =============================================================================
# test_dns_addrinfo_offsets.mojo
# =============================================================================
# HERMETIC unit test for the platform-branched `struct
# addrinfo` field-offset parser (`_collect_a_records_from_addrinfo_list` in
# komira_net.dns).
#
# The motivation: BSD/Darwin's `struct addrinfo` SWAPS `ai_addr` and
# `ai_canonname` relative to glibc — ai_addr lives at +32 on macOS but +24 on
# Linux. A blind reuse of the Linux offsets on macOS reads ai_canonname (a char*
# pointing at the host string) as if it were the sockaddr, and the resulting
# "IP" is garbage. This test pins the parser to the EXACT byte layout of the
# platform it compiles on, so it proves the comptime-branched offsets
# (_AI_OFF_ADDR / _AI_OFF_FAMILY / _AI_OFF_NEXT / _SIN_OFF_ADDR) are
# self-consistent and that a known sin_addr round-trips to the expected ip_be.
#
# Fully hermetic: builds the addrinfo + sockaddr_in byte layout in stack
# buffers, NEVER calls getaddrinfo, NEVER frees (the layout is stack-local). No
# network, no /etc/hosts dependency.
# =============================================================================

from std.testing import assert_equal, assert_true
from std.sys.info import CompilationTarget

from komira_net.dns import (
    IpAddr,
    _collect_a_records_from_addrinfo_list,
)


comptime _AF_INET: Int32 = Int32(2)
comptime _AF_INET6: Int32 = Int32(30)  # AF_INET6 (Darwin); value irrelevant — non-INET node must be skipped
comptime _ADDRINFO_SIZE: Int = 48
comptime _SOCKADDR_IN_SIZE: Int = 16

# THE platform-branched offsets the parser reads — MIRRORED here so the test
# builds the layout at the exact offsets the production parser will read. macOS
# swaps ai_addr to +32; Linux keeps it at +24. ai_family / ai_next / sin_addr
# are identical on both.
comptime _AI_OFF_FAMILY: Int = 4
comptime _AI_OFF_ADDR: Int = 32 if CompilationTarget.is_macos() else 24
comptime _AI_OFF_NEXT: Int = 40
comptime _SIN_OFF_ADDR: Int = 4


def _write_i32_at(
    buf: UnsafePointer[UInt8, MutUntrackedOrigin], off: Int, v: Int32
):
    """Write an Int32 at byte offset `off`."""
    (buf + off).bitcast[Int32]()[0] = v


def _write_ptr_at(
    buf: UnsafePointer[UInt8, MutUntrackedOrigin],
    off: Int,
    p: UnsafePointer[UInt8, MutUntrackedOrigin],
):
    """Write a pointer at byte offset `off`."""
    (buf + off).bitcast[UnsafePointer[UInt8, MutUntrackedOrigin]]()[0] = p


def _null_ptr() -> UnsafePointer[UInt8, MutUntrackedOrigin]:
    # b2: the null UnsafePointer ctor was removed; build NULL via an
    # Optional-None reinterpret (layout-compatible, all-zero bit pattern).
    var none: Optional[UnsafePointer[UInt8, MutUntrackedOrigin]] = None
    return UnsafePointer(to=none).bitcast[
        UnsafePointer[UInt8, MutUntrackedOrigin]
    ]()[]


def test_single_a_record_parses_to_expected_ip() raises:
    """A single AF_INET addrinfo node whose ai_addr points at a sockaddr_in
    with sin_addr = 1.2.3.4 must parse to ip_be = 0x04030201 — proving ai_addr
    is read from the correct (platform-branched) offset and sin_addr from +4."""
    # Stack buffers: one addrinfo + one sockaddr_in, zero-filled.
    var node = Array[UInt8, _ADDRINFO_SIZE](fill=UInt8(0))
    var sa = Array[UInt8, _SOCKADDR_IN_SIZE](fill=UInt8(0))

    # SAFETY: stack-local InlineArrays; the MutExternalOrigin pointers are the
    # parser's FFI ABI shape (the parser reads them read-only and frees
    # nothing). The buffers outlive the call (locals of this function).
    var node_p = node.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()
    var sa_p = sa.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()

    # sockaddr_in: write the 4 sin_addr bytes (network byte order) at +4. For
    # 1.2.3.4 the on-wire bytes in ascending address order are [1,2,3,4], which
    # the parser packs byte[0]-first → 0x04030201.
    (sa_p + _SIN_OFF_ADDR + 0)[0] = UInt8(1)
    (sa_p + _SIN_OFF_ADDR + 1)[0] = UInt8(2)
    (sa_p + _SIN_OFF_ADDR + 2)[0] = UInt8(3)
    (sa_p + _SIN_OFF_ADDR + 3)[0] = UInt8(4)

    # addrinfo: ai_family = AF_INET @ +4; ai_addr = &sockaddr_in @ +_AI_OFF_ADDR;
    # ai_next = NULL @ +40.
    _write_i32_at(node_p, _AI_OFF_FAMILY, _AF_INET)
    _write_ptr_at(node_p, _AI_OFF_ADDR, sa_p)
    _write_ptr_at(node_p, _AI_OFF_NEXT, _null_ptr())

    var out = _collect_a_records_from_addrinfo_list(node_p)
    assert_equal(len(out), 1)
    assert_equal(Int(out[0].family), Int(_AF_INET))
    assert_true(out[0].is_ipv4())
    assert_equal(Int(out[0].v4_be), 0x04030201)

    # Keep the buffers alive across the parse (method-based keepalive — the
    # InlineArrays' addresses were handed to the parser).
    _ = node
    _ = sa


def test_canonname_offset_not_mistaken_for_addr() raises:
    """REGRESSION GUARD for the macOS swap. We populate the SLOT WHERE THE OTHER
    PLATFORM keeps ai_addr with a sentinel pointer to a sockaddr carrying a WRONG
    IP, and put the CORRECT sockaddr at THIS platform's ai_addr offset. If the
    parser read the wrong offset, it would return the wrong IP. On macOS the
    'wrong' slot is +24 (ai_canonname); on Linux it is +32 (ai_canonname). The
    parser must read THIS platform's _AI_OFF_ADDR and return the CORRECT IP."""
    var node = Array[UInt8, _ADDRINFO_SIZE](fill=UInt8(0))
    var sa_correct = Array[UInt8, _SOCKADDR_IN_SIZE](fill=UInt8(0))
    var sa_wrong = Array[UInt8, _SOCKADDR_IN_SIZE](fill=UInt8(0))

    var node_p = node.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()
    var sac_p = sa_correct.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()
    var saw_p = sa_wrong.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()

    # Correct sockaddr → 10.0.0.50 (a recognizable ClusterIP-shaped value).
    (sac_p + _SIN_OFF_ADDR + 0)[0] = UInt8(10)
    (sac_p + _SIN_OFF_ADDR + 1)[0] = UInt8(0)
    (sac_p + _SIN_OFF_ADDR + 2)[0] = UInt8(0)
    (sac_p + _SIN_OFF_ADDR + 3)[0] = UInt8(50)
    var expect = 10 | (0 << 8) | (0 << 16) | (50 << 24)

    # Wrong sockaddr → 9.9.9.9 (what a swapped-offset read would yield).
    (saw_p + _SIN_OFF_ADDR + 0)[0] = UInt8(9)
    (saw_p + _SIN_OFF_ADDR + 1)[0] = UInt8(9)
    (saw_p + _SIN_OFF_ADDR + 2)[0] = UInt8(9)
    (saw_p + _SIN_OFF_ADDR + 3)[0] = UInt8(9)

    # The OTHER platform's ai_addr offset (= this platform's ai_canonname slot).
    var other_addr_off = 24 if CompilationTarget.is_macos() else 32

    _write_i32_at(node_p, _AI_OFF_FAMILY, _AF_INET)
    _write_ptr_at(node_p, _AI_OFF_ADDR, sac_p)        # correct, this platform
    _write_ptr_at(node_p, other_addr_off, saw_p)      # decoy, other platform
    _write_ptr_at(node_p, _AI_OFF_NEXT, _null_ptr())

    var out = _collect_a_records_from_addrinfo_list(node_p)
    assert_equal(len(out), 1)
    assert_equal(Int(out[0].v4_be), expect)  # NOT 9.9.9.9

    _ = node
    _ = sa_correct
    _ = sa_wrong


def test_skips_non_inet_and_walks_next() raises:
    """A 2-node list: node[0] is a non-AF_INET record (must be skipped, and its
    ai_addr is NULL), node[1] is AF_INET with a real IP. Proves (a) family
    filtering, (b) ai_next traversal at +40, (c) a NULL ai_addr is tolerated."""
    var n0 = Array[UInt8, _ADDRINFO_SIZE](fill=UInt8(0))
    var n1 = Array[UInt8, _ADDRINFO_SIZE](fill=UInt8(0))
    var sa = Array[UInt8, _SOCKADDR_IN_SIZE](fill=UInt8(0))

    var n0_p = n0.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()
    var n1_p = n1.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()
    var sa_p = sa.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()

    # node[0]: non-INET family, NULL ai_addr, ai_next → node[1].
    _write_i32_at(n0_p, _AI_OFF_FAMILY, _AF_INET6)
    _write_ptr_at(n0_p, _AI_OFF_ADDR, _null_ptr())
    _write_ptr_at(n0_p, _AI_OFF_NEXT, n1_p)

    # node[1]: AF_INET → 8.8.4.4, ai_next → NULL.
    (sa_p + _SIN_OFF_ADDR + 0)[0] = UInt8(8)
    (sa_p + _SIN_OFF_ADDR + 1)[0] = UInt8(8)
    (sa_p + _SIN_OFF_ADDR + 2)[0] = UInt8(4)
    (sa_p + _SIN_OFF_ADDR + 3)[0] = UInt8(4)
    var expect = 8 | (8 << 8) | (4 << 16) | (4 << 24)
    _write_i32_at(n1_p, _AI_OFF_FAMILY, _AF_INET)
    _write_ptr_at(n1_p, _AI_OFF_ADDR, sa_p)
    _write_ptr_at(n1_p, _AI_OFF_NEXT, _null_ptr())

    var out = _collect_a_records_from_addrinfo_list(n0_p)
    # Exactly ONE A record (node[0] skipped), with node[1]'s IP.
    assert_equal(len(out), 1)
    assert_equal(Int(out[0].v4_be), expect)

    _ = n0
    _ = n1
    _ = sa


def test_empty_list_null_head() raises:
    """A NULL list head → empty result (no crash, no spurious record)."""
    var out = _collect_a_records_from_addrinfo_list(_null_ptr())
    assert_equal(len(out), 0)


def main() raises:
    test_single_a_record_parses_to_expected_ip()
    test_canonname_offset_not_mistaken_for_addr()
    test_skips_non_inet_and_walks_next()
    test_empty_list_null_head()
    print("PASS komira_net.dns addrinfo field-offset parser")
