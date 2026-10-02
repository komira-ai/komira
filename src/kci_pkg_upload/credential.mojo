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
# `komira_http`'s `AuthProvider` / `BearerTokenSource` cannot serve this:
# `AuthProvider.apply` takes an immutable `self`, so it cannot hold a lazily
# minted token, and neither trait renders a surface-specific shape. Those two
# facts are the whole justification for a separate vocabulary.
#
# ⛔ A SURFACE A CREDENTIAL CANNOT SERVE IS A LOCAL FAULT. `authorization`
# RAISES, and the registry clients call it BEFORE composing any request — so a
# misrouted credential is refused with the transport recording zero calls,
# never presented on a surface it was not issued for. ⚠ The dispatch is keyed
# on the surface, not the host: the warehouse arm takes any host, so a
# coordinate's substrate decides which surface is asked for.
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

    def authorization(mut self, surface: Int) raises -> String:
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

    def authorization(mut self, surface: Int) raises -> String:
        return String("")


# =============================================================================
# ScriptedCredential — the TEST DOUBLE.
# =============================================================================


struct ScriptedCredential(RegistryCredential, Deinitable):
    """A fixed `Authorization` value per surface; any other surface RAISES
    exactly as a real credential refuses one. Records every surface it was
    asked for, in order, so a test can assert which shape reached which
    request.

    Layout: owned lists. No pointer field."""

    var _surfaces: List[Int]
    var _values: List[String]
    var _asked: List[Int]

    def __init__(out self):
        self._surfaces = List[Int]()
        self._values = List[String]()
        self._asked = List[Int]()

    def serve(mut self, surface: Int, var value: String):
        self._surfaces.append(surface)
        self._values.append(value^)

    def asked_count(self) -> Int:
        return len(self._asked)

    def asked(self, i: Int) -> Int:
        return self._asked[i]

    def authorization(mut self, surface: Int) raises -> String:
        self._asked.append(surface)
        for i in range(len(self._surfaces)):
            if self._surfaces[i] == surface:
                return self._values[i].copy()
        refuse_surface(String("ScriptedCredential"), surface)
        return String("")
