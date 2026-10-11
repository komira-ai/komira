# =============================================================================
# test_dns_resolve_errors.mojo
# =============================================================================
# resolve_host past the literal fast path: a name getaddrinfo resolves
# (one target per A record, each with the caller's port), the DnsError class
# of each getaddrinfo failure the test can cause, and the fast path never
# reaching getaddrinfo. Linux only, like test_dns_resolve.mojo: the failures
# are glibc's codes, and on another platform these tests do nothing.
#
# Offline: "LOCALHOST" is not an exact loopback alias, so it goes to
# getaddrinfo, and glibc's hosts-file lookup matches names case-insensitively
# ("localhost" is in every hosts file). The `.invalid` TLD is reserved
# (RFC 2606). A system error is caused by lowering RLIMIT_NOFILE to the lowest
# free descriptor, so the resolver cannot open the hosts file; the limit is
# restored before any assertion can raise.
# =============================================================================

from std.ffi import external_call
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_net.dns import _getaddrinfo_collect, resolve_host
from komira_async.reactor.socket_setup import inet_loopback_be


comptime _RLIMIT_NOFILE_LINUX: Int32 = 7


def _message(host: String, port: UInt16) -> String:
    """The message resolve_host raised for `host`, or "" if it returned."""
    try:
        _ = resolve_host(host, port)
    except e:
        return String(e)
    return String("")


def _tighten_nofile(saved: InlineArray[UInt64, 2]) raises:
    """Lower the soft descriptor limit to the lowest free descriptor."""
    var lowest = external_call["dup", Int32](Int32(2))
    assert_true(lowest >= Int32(0), "dup")
    _ = external_call["close", Int32](lowest)
    var tight = InlineArray[UInt64, 2](fill=UInt64(0))
    tight[0] = UInt64(Int(lowest))
    tight[1] = saved[1]
    # SAFETY: `tight` is a local two-word rlimit the call reads synchronously.
    var rc = external_call["setrlimit", Int32](
        _RLIMIT_NOFILE_LINUX, tight.unsafe_ptr()
    )
    assert_equal(rc, Int32(0), "setrlimit")


def _restore_nofile(saved: InlineArray[UInt64, 2]) -> Int32:
    # SAFETY: `saved` is a local two-word rlimit the call reads synchronously.
    return external_call["setrlimit", Int32](
        _RLIMIT_NOFILE_LINUX, saved.unsafe_ptr()
    )


def _save_nofile() raises -> InlineArray[UInt64, 2]:
    var saved = InlineArray[UInt64, 2](fill=UInt64(0))
    # SAFETY: `saved` is a local two-word rlimit the call fills synchronously.
    var rc = external_call["getrlimit", Int32](
        _RLIMIT_NOFILE_LINUX, saved.unsafe_ptr()
    )
    assert_equal(rc, Int32(0), "getrlimit")
    return saved^


def test_a_resolved_name_gives_one_target_per_a_record() raises:
    """A name that is no literal resolves through getaddrinfo: one target per
    A record, in getaddrinfo's order, each carrying the caller's port."""
    comptime if CompilationTarget.is_linux():
        var addrs = _getaddrinfo_collect(String("LOCALHOST"), UInt16(8080))
        assert_true(len(addrs) >= 1)
        var targets = resolve_host(String("LOCALHOST"), UInt16(8080))
        assert_equal(len(targets), len(addrs))
        for i in range(len(targets)):
            assert_equal(Int(targets[i].ip.v4_be), Int(addrs[i].v4_be))
            assert_equal(Int(targets[i].ip.v4_be), Int(inet_loopback_be()))
            assert_true(targets[i].ip.is_ipv4())
            assert_equal(Int(targets[i].port), 8080)


def test_nxdomain_is_classified_as_nxdomain() raises:
    """EAI_NONAME raises the NXDOMAIN class (not a later check's class, and
    not the generic failure)."""
    comptime if CompilationTarget.is_linux():
        var host = String("komira-nonexistent.invalid")
        assert_equal(
            _message(host, UInt16(80)),
            String("DnsError[NXDOMAIN]: no such host '")
            + host
            + "' (EAI_NONAME)",
        )


def test_a_system_error_is_resolve_failed_with_its_code() raises:
    """With no descriptor left getaddrinfo fails with EAI_SYSTEM (-11 in
    glibc): the generic class, carrying the code, not NXDOMAIN."""
    comptime if CompilationTarget.is_linux():
        var host = String("komira-no-descriptor.invalid")
        var saved = _save_nofile()
        _tighten_nofile(saved)
        var msg = _message(host, UInt16(80))
        assert_equal(_restore_nofile(saved), Int32(0), "the limit is restored")
        assert_equal(
            msg,
            String("DnsError[RESOLVE_FAILED]: getaddrinfo('")
            + host
            + "') failed (EAI=-11)",
        )


def test_the_literal_fast_path_never_calls_getaddrinfo() raises:
    """With no descriptor left getaddrinfo cannot succeed, yet the loopback
    aliases and a dotted quad still resolve: the literal check runs first
    and returns without reaching getaddrinfo."""
    comptime if CompilationTarget.is_linux():
        var saved = _save_nofile()
        _tighten_nofile(saved)
        var lo = _message(String("localhost"), UInt16(1))
        var quad = _message(String("192.0.2.7"), UInt16(1))
        var empty = _message(String(""), UInt16(1))
        assert_equal(_restore_nofile(saved), Int32(0), "the limit is restored")
        assert_equal(lo, String(""))
        assert_equal(quad, String(""))
        assert_equal(empty, String(""))


def main() raises:
    test_a_resolved_name_gives_one_target_per_a_record()
    test_nxdomain_is_classified_as_nxdomain()
    test_a_system_error_is_resolve_failed_with_its_code()
    test_the_literal_fast_path_never_calls_getaddrinfo()
    print("PASS komira_net.dns resolve_host errors")
