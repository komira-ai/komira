# =============================================================================
# test_dns_transient.mojo
# =============================================================================
# The TRANSIENT and NXDOMAIN classes: getaddrinfo's EAI_AGAIN raises
# "DnsError[TRANSIENT]: ... (EAI_AGAIN)" and its EAI_NONAME raises
# "DnsError[NXDOMAIN]: ... (EAI_NONAME)", each distinct from the other and from
# the generic RESOLVE_FAILED. Linux only (the codes are glibc's); elsewhere
# this does nothing.
#
# Hermetic: RES_OPTIONS="attempts:0" makes glibc's stub resolver send no query
# at all, so a name the hosts file lacks fails with EAI_AGAIN without touching
# the network. glibc reads RES_OPTIONS once, when the process first initialises
# its resolver, and a later change does not undo it. So `setenv` is the first
# statement of `main`, before any lookup, and this test has its own file: no
# other test in this process may resolve a name first or expect a real answer.
#
# EAI_NONAME without a resolver: glibc rejects a malformed name (an empty
# label, as in "komira..malformed.invalid") before it would build a query.
# Under attempts:0 a name that needed a query fails with EAI_AGAIN instead (the
# test above), so an EAI_NONAME here comes from that local rejection alone.
# =============================================================================

from std.ffi import external_call
from std.sys.info import CompilationTarget
from std.testing import assert_equal

from komira_net.dns import resolve_host


def _set_no_resolver_attempts() raises:
    var name = String("RES_OPTIONS")
    var value = String("attempts:0")
    var rc = external_call["setenv", Int32](
        name.as_c_string_slice().unsafe_ptr(),
        value.as_c_string_slice().unsafe_ptr(),
        Int32(1),
    )
    assert_equal(rc, Int32(0), "setenv")


def test_eai_again_is_classified_as_transient() raises:
    """With no resolver attempt allowed, a name outside the hosts file fails
    with EAI_AGAIN, which raises the TRANSIENT class with the host named."""
    comptime if CompilationTarget.is_linux():
        var host = String("komira-transient.invalid")
        var msg = String("")
        try:
            _ = resolve_host(host, UInt16(80))
        except e:
            msg = String(e)
        assert_equal(
            msg,
            String("DnsError[TRANSIENT]: temporary failure resolving '")
            + host
            + "' (EAI_AGAIN)",
        )


def test_malformed_name_is_classified_as_nxdomain() raises:
    """A name glibc rejects without a query (an empty label) fails with
    EAI_NONAME, which raises the NXDOMAIN class with the host named."""
    comptime if CompilationTarget.is_linux():
        var host = String("komira..malformed.invalid")
        var msg = String("")
        try:
            _ = resolve_host(host, UInt16(80))
        except e:
            msg = String(e)
        assert_equal(
            msg,
            String("DnsError[NXDOMAIN]: no such host '")
            + host
            + "' (EAI_NONAME)",
        )


def main() raises:
    comptime if CompilationTarget.is_linux():
        _set_no_resolver_attempts()
    test_eai_again_is_classified_as_transient()
    test_malformed_name_is_classified_as_nxdomain()
    print("PASS komira_net.dns resolve_host transient and nxdomain")
