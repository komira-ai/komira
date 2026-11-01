# =============================================================================
# test_dns_hints.mojo
# =============================================================================
# The hints the resolver hands getaddrinfo: ai_flags 0, ai_family AF_INET,
# ai_socktype SOCK_STREAM. Hermetic: reads `_resolver_hints()` and never calls
# getaddrinfo.
#
# THE DEFECT THIS CATCHES. With AI_ADDRCONFIG in ai_flags, glibc answers an
# AF_INET lookup only when the host has a non-loopback IPv4 address. Where `lo`
# is the only interface (a loopback-only remote executor, a container with
# networking off) every name then fails with EAI_NONAME, `localhost`
# included, although the hosts file maps it. That failure needs a
# loopback-only host to show; this test pins the cause on any host:
# re-adding AI_ADDRCONFIG (0x0020 glibc, 0x0400 Darwin) turns it red. The
# behaviour itself is covered by test_dns_resolve.mojo and
# test_dns_resolve_errors.mojo, which resolve `localhost` through getaddrinfo
# and fail on a loopback-only host when the flag is set.
# =============================================================================

from std.testing import assert_equal

from komira_net.dns import _resolver_hints


def test_hints_carry_no_flags() raises:
    """ai_flags (offset 0) is 0: in particular no AI_ADDRCONFIG."""
    var hints = _resolver_hints()
    # SAFETY: `hints` is a local 48-byte struct addrinfo; offset 0 is an
    # aligned Int32 inside it, read while `hints` is live.
    var flags = hints.unsafe_ptr().bitcast[Int32]()[0]
    assert_equal(flags, Int32(0), "ai_flags must be 0 (no AI_ADDRCONFIG)")


def test_hints_ask_for_ipv4_stream() raises:
    """ai_family (offset 4) is AF_INET (2) and ai_socktype (offset 8) is
    SOCK_STREAM (1), the same values on glibc and BSD/Darwin."""
    var hints = _resolver_hints()
    # SAFETY: as above; offsets 4 and 8 are aligned Int32s inside `hints`.
    var p = hints.unsafe_ptr()
    assert_equal((p + 4).bitcast[Int32]()[0], Int32(2), "ai_family")
    assert_equal((p + 8).bitcast[Int32]()[0], Int32(1), "ai_socktype")


def main() raises:
    test_hints_carry_no_flags()
    test_hints_ask_for_ipv4_stream()
    print("PASS komira_net.dns resolver hints")
