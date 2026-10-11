# =============================================================================
# src/kci_pkg_upload/credential.mojo — credentials keyed by the SURFACE they
#   are presented to.
# =============================================================================
#
# ⭐ WHY A SURFACE. One secret can be presented in different SHAPES: a warehouse
# takes HTTP Basic `__token__:<token>`, a prefix.dev channel takes
# `Bearer <token>`. So a credential answers "what `Authorization` value for
# THIS surface?", and a credential that holds one secret states which surfaces
# it may be presented to.
#
# `komira_http_client`'s `AuthProvider` / `BearerTokenSource` cannot serve this:
# `AuthProvider.apply` takes an immutable `self`, so it cannot hold a lazily
# minted token, and neither trait renders a surface-specific shape. Those two
# facts are the whole justification for a separate vocabulary.
#
# ⛔ A SURFACE A CREDENTIAL CANNOT SERVE IS A LOCAL FAULT. `authorization`
# RAISES, and the registry clients call it BEFORE composing any request — so a
# misrouted credential is refused with the transport recording zero calls,
# never presented on a surface it was not issued for.
#
# ⛔ AND A HOST A CREDENTIAL WAS NOT ISSUED FOR IS A LOCAL FAULT TOO. The
# registry clients pass the host the request is about to go to, and a
# credential bound to a host (`StaticTokenCredential`, `GithubOidcCredential`)
# RAISES for any other one before minting or sending anything. Without this a
# channels file naming a different server than the credential's would hand a
# live upload token to that server. Only `AnonymousCredential`, which presents
# nothing, answers for every host.
#
# THE CREDENTIALS: `StaticTokenCredential` (one long-lived token, by file path
# or secret name), `GithubOidcCredential` (trusted publishing from a GitHub
# Actions job), `AnonymousCredential` (public reads) and `ScriptedCredential`
# (the test double).
#
# ⛔ A CREDENTIAL IS NEVER PRINTED. No type here is `Writable` / `Stringable`,
# and no refusal quotes a token.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from komira_encoding import base64_encode

from .identity import ascii_lower


# The surfaces a registry request is presented to.
comptime SURFACE_PYPI_UPLOAD: Int = 4  # a warehouse legacy upload: Basic __token__
comptime SURFACE_PREFIX_DEV: Int = 5  # a prefix.dev channel: Bearer token


def surface_name(surface: Int) -> String:
    if surface == SURFACE_PYPI_UPLOAD:
        return String("PYPI_UPLOAD")
    if surface == SURFACE_PREFIX_DEV:
        return String("PREFIX_DEV")
    return String("SURFACE(") + String(surface) + String(")")


trait RegistryCredential(Movable, Deinitable):
    """The `Authorization` value to present on `surface`.

    RAISES — a local fault, before any request — for a surface this credential
    cannot serve, and for a source that resolves no usable secret."""

    def authorization(mut self, surface: Int, host: String) raises -> String:
        """`host` is the registry the request is for: the host of the
        coordinate's repo, as `repo_host` returns it. For a prefix.dev channel
        that is the host the request goes to; for a warehouse it is the index
        (`pypi.org`) whose upload host (`upload.pypi.org`) takes the file."""
        ...


def refuse_surface(who: String, surface: Int) raises:
    """RAISE the refusal for a surface `who` cannot serve."""
    raise Error(
        who
        + String(" cannot serve the ")
        + surface_name(surface)
        + String(
            " surface. The request was not sent: a credential is presented only"
            " to the surface it was issued for"
        )
    )


def same_host(a: String, b: String) -> Bool:
    """Host names compare case-insensitively; nothing else is normalised."""
    return ascii_lower(a) == ascii_lower(b)


def refuse_other_host(who: String, surface: Int, host: String, bound: String) raises:
    """RAISE unless `host` is `bound`, the host `who` was issued for."""
    if same_host(host, bound):
        return
    raise Error(
        who
        + String(" was issued for '")
        + bound
        + String("' and will not present its ")
        + surface_name(surface)
        + String(" credential to '")
        + host
        + String("'. The request was not sent: check that the channel location")
        + String(" and the credential name the same server")
    )


# =============================================================================
# The warehouse upload shape.
# =============================================================================


comptime PYPI_TOKEN_USERNAME: String = "__token__"
"""The fixed Basic username a warehouse (PyPI, TestPyPI) expects beside an API
token or a trusted-publishing upload token."""


def pypi_upload_authorization(token: String) raises -> String:
    """`Basic base64("__token__:" + token)` — exactly what `uv publish` sends
    for `--username __token__ --password <token>` (measured against a loopback
    recorder; `tests/test_pkg_upload_uv_fidelity.mojo`). RAISES on an empty
    token."""
    if token.byte_length() == 0:
        raise Error(
            "pypi_upload_authorization: EMPTY upload token; the index would"
            " answer 403 as if the project were not yours"
        )
    var raw = String(PYPI_TOKEN_USERNAME) + String(":") + token
    return String("Basic ") + base64_encode(raw.as_bytes())


def bearer_authorization(token: String) raises -> String:
    """`Bearer <token>`, the prefix.dev shape. RAISES on an empty token."""
    if token.byte_length() == 0:
        raise Error(
            "bearer_authorization: EMPTY token; the channel would answer 401"
            " as if no credential were configured"
        )
    return String("Bearer ") + token


# =============================================================================
# AnonymousCredential — presents nothing.
# =============================================================================


struct AnonymousCredential(RegistryCredential, Deinitable):
    """Presents NO credential on any surface: `authorization` is EMPTY, which
    a read sends as no `Authorization` header at all. For reading a public
    registry without resolving a secret. Every upload arm refuses an EMPTY
    authorization before the request, so this credential can never upload.

    Layout: no fields."""

    def __init__(out self):
        pass

    def authorization(mut self, surface: Int, host: String) raises -> String:
        return String("")


# =============================================================================
# ScriptedCredential — the TEST DOUBLE.
# =============================================================================


struct ScriptedCredential(RegistryCredential, Deinitable):
    """A fixed `Authorization` value per surface; any other surface RAISES
    exactly as a real credential refuses one. Records every surface and host
    it was asked for, in order, so a test can assert which shape reached which
    request. It is bound to no host.

    Layout: owned lists. No pointer field."""

    var _surfaces: List[Int]
    var _values: List[String]
    var _asked: List[Int]
    var _asked_hosts: List[String]

    def __init__(out self):
        self._surfaces = List[Int]()
        self._values = List[String]()
        self._asked = List[Int]()
        self._asked_hosts = List[String]()

    def serve(mut self, surface: Int, var value: String):
        self._surfaces.append(surface)
        self._values.append(value^)

    def asked_count(self) -> Int:
        return len(self._asked)

    def asked(self, i: Int) -> Int:
        return self._asked[i]

    def asked_host(self, i: Int) -> String:
        return self._asked_hosts[i].copy()

    def authorization(mut self, surface: Int, host: String) raises -> String:
        self._asked.append(surface)
        self._asked_hosts.append(host.copy())
        for i in range(len(self._surfaces)):
            if self._surfaces[i] == surface:
                return self._values[i].copy()
        refuse_surface(String("ScriptedCredential"), surface)
        return String("")  # cov: unreachable refuse_surface above always raises
