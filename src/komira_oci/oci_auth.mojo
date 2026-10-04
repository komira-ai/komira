# =============================================================================
# oci_auth.mojo — the credential a registry client attaches to every request.
# =============================================================================
#
# One value, three shapes: NONE (an anonymous / public read), BEARER (a token
# the caller already holds — Artifact Registry accepts a Google access token this
# way, and the caller resolves it through its own credential chain), and BASIC
# (user + password — Artifact Registry's documented `oauth2accesstoken` form, and
# the shape ECR hands out). The secret never appears in an error message, a log
# line or a result value in this package.
#
# Encapsulation: owned String fields only.
# =============================================================================

from .oci_transport import OciRequest


comptime OCI_AUTH_NONE: Int = 0
comptime OCI_AUTH_BEARER: Int = 1
comptime OCI_AUTH_BASIC: Int = 2


struct OciAuth(Copyable, Movable, Deinitable):
    """How to authenticate to one registry. See the file header."""

    var kind: Int
    var user: String
    var secret: String

    def __init__(out self, kind: Int, var user: String, var secret: String):
        self.kind = kind
        self.user = user^
        self.secret = secret^

    @staticmethod
    def none() -> OciAuth:
        return OciAuth(OCI_AUTH_NONE, String(""), String(""))

    @staticmethod
    def bearer(var token: String) -> OciAuth:
        return OciAuth(OCI_AUTH_BEARER, String(""), token^)

    @staticmethod
    def basic(var user: String, var password: String) -> OciAuth:
        return OciAuth(OCI_AUTH_BASIC, user^, password^)

    def apply(self, mut request: OciRequest):
        """Attach the credential to `request` (a no-op for NONE or an empty
        secret, exactly like `with_bearer` / `with_basic`)."""
        if self.kind == OCI_AUTH_BEARER:
            request.with_bearer(self.secret)
        elif self.kind == OCI_AUTH_BASIC:
            request.with_basic(self.user, self.secret)

    def copy(self) -> Self:
        return OciAuth(self.kind, self.user.copy(), self.secret.copy())
