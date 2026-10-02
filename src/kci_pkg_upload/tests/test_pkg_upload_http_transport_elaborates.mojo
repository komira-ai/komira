# =============================================================================
# src/kci_pkg_upload/tests/test_pkg_upload_http_transport_elaborates.mojo
#   — the PRODUCTION transport and the production credential type-check as
#   the release tool will instantiate them.
# =============================================================================
#
# WHY A TEST THAT SENDS NOTHING. `HttpPkgTransport[C]` and `RegistrySet[T, C]`
# are parametric, and `mojo precompile` does not elaborate a parametric body
# until something instantiates it. Every other test here instantiates the
# SCRIPTED transport, so without this file the HTTPS arm could be ill-typed
# and still ship a green `.mojoc`, failing first in the publisher that builds
# it. This test instantiates the real transport — public-CA TLS over kernel
# TCP — and routes every `RegistrySet` method through it behind a condition
# that is false at run time, so the compiler must elaborate each body and
# nothing dials.
#
# Hermetic: the guarded branch never runs; no socket is opened.
# =============================================================================

from std.ffi import abort
from std.sys import argv
from std.testing import assert_true

from komira_http.client.tls_connector import TlsConnector, build_public_ca_tls_connector
from komira_http.transport.kernel_tcp import KernelTcpConnector

from kci_pkg_upload.approved_names import ApprovedNames
from kci_pkg_upload.coordinate import (
    SUBSTRATE_PUBLIC_PYPI,
    PackageCoordinate,
    PackageFile,
)
from kci_pkg_upload.credential import ScriptedCredential
from kci_pkg_upload.identity import ContentIdentity
from kci_pkg_upload.registry_set import RegistrySet
from kci_pkg_upload.transport import HttpPkgTransport


comptime _Conn = TlsConnector[KernelTcpConnector]


def _mk(host: String) -> _Conn:
    try:
        return build_public_ca_tls_connector(host)
    except e:
        abort(String("tls connector: ") + String(e))


def _names() raises -> ApprovedNames:
    """The approved names the (never-run) upload is elaborated with: the
    production type, so `RegistrySet.upload`'s whole signature is
    instantiated here."""
    var p = ApprovedNames()
    p.approve(String("d"))
    return p^


def test_the_production_types_elaborate() raises:
    var rs = RegistrySet[HttpPkgTransport[_Conn], ScriptedCredential](
        HttpPkgTransport[_Conn](_mk), ScriptedCredential()
    )
    # False at run time (no test runner passes a million argv entries), and not
    # foldable at compile time — so every call below is elaborated, none runs.
    if len(argv()) > 1_000_000:
        var c = PackageCoordinate(
            SUBSTRATE_PUBLIC_PYPI,
            String("test.pypi.org"),
            String("d"),
            String("1.1.1"),
            String("linux-64"),
            String("d-1.1.1-py3-none-any.whl"),
        )
        _ = rs.presence(c, ContentIdentity.none())
        _ = rs.read_back(c)
        _ = rs.fetch(c)
        _ = rs.upload(
            PackageFile(c.copy(), List[UInt8](), String("")), _names()
        )
    assert_true(True)
    print("  test_the_production_types_elaborate: PASS")


def main() raises:
    test_the_production_types_elaborate()
    print("test_pkg_upload_http_transport_elaborates: ALL PASS")
