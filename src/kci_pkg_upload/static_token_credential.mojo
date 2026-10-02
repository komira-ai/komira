# =============================================================================
# src/kci_pkg_upload/static_token_credential.mojo — `StaticTokenCredential`:
#   one long-lived registry token, read from a FILE or resolved by NAME from a
#   secret store, presented on the one surface it was issued for.
# =============================================================================
#
# ⛔ NEVER A VALUE IN ARGV. A token on a command line is world-readable
# (`/proc/<pid>/cmdline`, `ps`, a CI log of the invocation). So the two ways in
# are a PATH (`token_file`) and a secret-store NAME (`token_secret`); there is
# no constructor that takes the token text from a caller-supplied string a
# flag could have carried.
#
# ⛔ ONE CREDENTIAL, ONE SURFACE. A token issued by one registry is presented
# only there: every other surface is refused before any request
# (`refuse_surface`). The shape is the surface's — Basic `__token__:<token>` on
# PYPI_UPLOAD, `Bearer <token>` on PREFIX_DEV.
#
# The token is held in a zeroizing `SecretValue` and is never printed; a
# refusal names the path or the secret name, never the content.
#
# A token FILE holds the token and at most one trailing line ending. Any other
# whitespace inside it is refused rather than trimmed: a token with a space in
# it is a file holding something else.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.pathlib import Path

from komira_secret_store import SecretStore, SecretValue

from .credential import (
    SURFACE_PREFIX_DEV,
    SURFACE_PYPI_UPLOAD,
    RegistryCredential,
    bearer_authorization,
    pypi_upload_authorization,
    refuse_surface,
    surface_name,
)


def _refuse_unservable(surface: Int) raises:
    if surface != SURFACE_PYPI_UPLOAD and surface != SURFACE_PREFIX_DEV:
        raise Error(
            String("StaticTokenCredential: no token shape for the ")
            + surface_name(surface)
            + String(" surface")
        )


def _token_length(raw: Span[UInt8, _], what: String) raises -> Int:
    """The token's length in `raw`: every byte up to one trailing `\\n` or
    `\\r\\n`. RAISES naming `what` (never the content) for an empty token or
    any other whitespace, control or non-ASCII byte."""
    var n = len(raw)
    if n > 0 and raw[n - 1] == UInt8(10):
        n -= 1
        if n > 0 and raw[n - 1] == UInt8(13):
            n -= 1
    if n == 0:
        raise Error(String("StaticTokenCredential: ") + what + String(" is EMPTY"))
    for i in range(n):
        var c = raw[i]
        if c <= UInt8(32) or c >= UInt8(127):
            raise Error(
                String("StaticTokenCredential: ")
                + what
                + String(
                    " holds whitespace, a control byte or a non-ASCII byte"
                    " inside the token; it must hold the token alone"
                )
            )
    return n


def _read_token_file(path: String) raises -> List[UInt8]:
    try:
        return Path(path).read_bytes()
    except e:
        raise Error(
            String("StaticTokenCredential: cannot read the token file '")
            + path
            + String("': ")
            + String(e)
        )


def _resolve_named[S: SecretStore](mut store: S, name: String) raises -> SecretValue:
    try:
        return store.resolve(name)
    except e:
        raise Error(
            String("StaticTokenCredential: the secret '")
            + name
            + String("' did not resolve: ")
            + String(e)
        )


struct StaticTokenCredential(RegistryCredential, Deinitable):
    """One token for one surface (see the file header).

    Layout: an Int and a zeroizing `SecretValue`. No pointer field."""

    var _surface: Int
    var _token: SecretValue

    def __init__(out self, surface: Int, var token: SecretValue) raises:
        """From a token already resolved into a `SecretValue`. RAISES for a
        surface with no token shape or an empty token."""
        _refuse_unservable(surface)
        _ = _token_length(token.revealed_bytes(), String("the token"))
        self._surface = surface
        self._token = token^

    @staticmethod
    def token_file(surface: Int, path: String) raises -> StaticTokenCredential:
        """The token held in the file at `path`. RAISES naming the path when it
        cannot be read or does not hold one token."""
        var raw = _read_token_file(path)
        var what = String("the token file '") + path + String("'")
        var n = _token_length(Span(raw), what)
        var token = SecretValue(Span(raw)[:n])
        for i in range(len(raw)):
            raw[i] = UInt8(0)
        return StaticTokenCredential(surface, token^)

    @staticmethod
    def token_secret[S: SecretStore](
        surface: Int, mut store: S, name: String
    ) raises -> StaticTokenCredential:
        """The token the secret store resolves for `name`. RAISES naming the
        secret when the store cannot resolve it or it does not hold one
        token."""
        var value = _resolve_named(store, name)
        var what = String("the secret '") + name + String("'")
        var n = _token_length(value.revealed_bytes(), what)
        if n != value.len():
            var trimmed = SecretValue(value.revealed_bytes()[:n])
            return StaticTokenCredential(surface, trimmed^)
        return StaticTokenCredential(surface, value^)

    def surface(self) -> Int:
        return self._surface

    def authorization(mut self, surface: Int) raises -> String:
        if surface != self._surface:
            refuse_surface(String("StaticTokenCredential"), surface)
        var token = String(unsafe_from_utf8=self._token.revealed_bytes())
        if surface == SURFACE_PYPI_UPLOAD:
            return pypi_upload_authorization(token)
        return bearer_authorization(token)
