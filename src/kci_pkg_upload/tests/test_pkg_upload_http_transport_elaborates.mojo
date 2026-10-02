# =============================================================================
# src/kci_pkg_upload/tests/test_pkg_upload_http_transport_elaborates.mojo
#   — the PRODUCTION transport and the production credentials type-check as
#   a publisher will instantiate them.
# =============================================================================
#
# WHY A TEST THAT SENDS NOTHING. `HttpPkgTransport[C]`, `RegistrySet[T, C]`
# and `GithubOidcCredential[T]` are parametric, and `mojo precompile` does not
# elaborate a parametric body until something instantiates it. Every other
# test here instantiates the SCRIPTED transport, so without this file the
# HTTPS arm could be ill-typed and still ship a green `.mojoc`, failing first
# in the publisher that builds it. This test instantiates the real transport
# — public-CA TLS over kernel TCP — with each production credential
# (`StaticTokenCredential`, `GithubOidcCredential` over the same transport,
# `AnonymousCredential`), and routes every `RegistrySet` method on both arms
# through them behind a condition that is false at run time, so the compiler
# must elaborate each body and nothing dials.
#
# Hermetic: the guarded branch never runs; no socket is opened, and no
# environment is read.
# =============================================================================

from std.ffi import abort
from std.sys import argv
from std.testing import assert_true

from komira_http.client.tls_connector import TlsConnector, build_public_ca_tls_connector
from komira_http.transport.kernel_tcp import KernelTcpConnector
from komira_secret_store import SecretValue

from kci_pkg_upload.approved_names import ApprovedNames
from kci_pkg_upload.coordinate import (
    SUBSTRATE_PREFIX_DEV_CONDA,
    SUBSTRATE_PUBLIC_PYPI,
    PackageCoordinate,
    PackageFile,
)
from kci_pkg_upload.credential import (
    SURFACE_PREFIX_DEV,
    AnonymousCredential,
    RegistryCredential,
)
from kci_pkg_upload.github_oidc_credential import GithubOidcCredential
from kci_pkg_upload.identity import ContentIdentity
from kci_pkg_upload.registry_set import RegistrySet
from kci_pkg_upload.static_token_credential import StaticTokenCredential
from kci_pkg_upload.transport import HttpPkgTransport


comptime _Conn = TlsConnector[KernelTcpConnector]
comptime _Http = HttpPkgTransport[_Conn]


def _mk(host: String) -> _Conn:
    try:
        return build_public_ca_tls_connector(host)
    except e:
        abort(String("tls connector: ") + String(e))


def _names() raises -> ApprovedNames:
    """The approved names the (never-run) uploads are elaborated with: the
    production type, so `RegistrySet.upload`'s whole signature is
    instantiated here."""
    var p = ApprovedNames()
    p.approve(String("d"))
    return p^


def _coords() -> List[PackageCoordinate]:
    var out = List[PackageCoordinate]()
    out.append(
        PackageCoordinate(
            SUBSTRATE_PUBLIC_PYPI,
            String("test.pypi.org"),
            String("d"),
            String("1.1.1"),
            String("linux-64"),
            String("d-1.1.1-py3-none-any.whl"),
        )
    )
    out.append(
        PackageCoordinate(
            SUBSTRATE_PREFIX_DEV_CONDA,
            String("prefix.dev/example-channel"),
            String("d"),
            String("1.1.1"),
            String("linux-64"),
            String("d-1.1.1-h0_0.conda"),
        )
    )
    return out^


def _drive[C: RegistryCredential](mut rs: RegistrySet[_Http, C]) raises:
    """Every `RegistrySet` method on both arms. Called only behind the
    run-time-false guard."""
    var cs = _coords()
    for i in range(len(cs)):
        _ = rs.presence(cs[i], ContentIdentity.none())
        _ = rs.read_back(cs[i])
        _ = rs.fetch(cs[i])
        _ = rs.upload(PackageFile(cs[i].copy(), List[UInt8](), String("")), _names())


def test_the_production_types_elaborate() raises:
    var static_set = RegistrySet[_Http, StaticTokenCredential](
        _Http(_mk),
        StaticTokenCredential(SURFACE_PREFIX_DEV, String("prefix.dev"), SecretValue.from_string(String("t"))),
    )
    var oidc_set = RegistrySet[_Http, GithubOidcCredential[_Http]](
        _Http(_mk),
        GithubOidcCredential[_Http](
            _Http(_mk),
            String("https://token.example.invalid/idtoken?api-version=2.0"),
            SecretValue.from_string(String("r")),
            String("prefix.dev"),
            String("test.pypi.org"),
        ),
    )
    var anon_set = RegistrySet[_Http, AnonymousCredential](_Http(_mk), AnonymousCredential())
    # False at run time (no test runner passes a million argv entries), and not
    # foldable at compile time — so every call below is elaborated, none runs.
    if len(argv()) > 1_000_000:
        _drive(static_set)
        _drive(oidc_set)
        _drive(anon_set)
        _ = GithubOidcCredential[_Http].from_actions_env(
            _Http(_mk), String("prefix.dev"), String("")
        )
        _ = StaticTokenCredential.token_file(
            SURFACE_PREFIX_DEV, String("prefix.dev"), String("/nonexistent")
        )
    assert_true(True)
    print("  test_the_production_types_elaborate: PASS")


def main() raises:
    test_the_production_types_elaborate()
    print("test_pkg_upload_http_transport_elaborates: ALL PASS")
