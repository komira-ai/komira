# =============================================================================
# kci_release_channel/channel_credential.mojo -- how a repository is pushed to.
# =============================================================================
#
# Every repository of a channel declares exactly one credential: the means
# by which its push identity authenticates. The declaration carries only
# NAMES, never secret material:
#
#   kind          API_TOKEN or OIDC_TRUSTED_PUBLISHING.
#   secret_name   for API_TOKEN, the HANDLE a secret store resolves to the
#                 token (`[A-Za-z_][A-Za-z0-9_]*`, at most 128 bytes). For
#                 OIDC_TRUSTED_PUBLISHING it must be absent: trusted publishing
#                 exchanges a short-lived identity token and stores no secret.
#
# A credential is never defaulted. A repository that declares none is refused,
# so the channels file is the only place the push method is chosen; the
# publisher takes it from here rather than from a flag that could override it.
#
# The secret_name grammar is deliberately narrow: an env-var-shaped handle.
# Most pasted tokens contain a character outside it (`-`, `.`, `/`, `+`, `=`)
# or exceed the length, so a token written where its name belongs is refused.
# No refusal here quotes a secret_name, because a refused one may be exactly
# that pasted token.
#
# OIDC_TRUSTED_PUBLISHING is accepted only on artifact types whose registry
# exchange is implemented (`oidc_exchange_implemented`): CONDA and PYTHON.
# =============================================================================

from .artifact_types import ARTIFACT_TYPE_CONDA, ARTIFACT_TYPE_PYTHON


# ── Credential kinds. A closed set. ──────────────────────────────────────────
comptime CREDENTIAL_KIND_API_TOKEN: String = "API_TOKEN"
"""A long-lived registry token, resolved by `secret_name` through a secret
store at publish time."""

comptime CREDENTIAL_KIND_OIDC_TRUSTED_PUBLISHING: String = "OIDC_TRUSTED_PUBLISHING"
"""A CI identity token exchanged with the registry for a short-lived upload
token. Stores no secret."""

comptime _MAX_SECRET_NAME_BYTES: Int = 128


def is_known_credential_kind(kind: String) -> Bool:
    return (
        kind == CREDENTIAL_KIND_API_TOKEN
        or kind == CREDENTIAL_KIND_OIDC_TRUSTED_PUBLISHING
    )


def _known_credential_kinds() -> String:
    return (
        String(CREDENTIAL_KIND_API_TOKEN)
        + String(", ")
        + String(CREDENTIAL_KIND_OIDC_TRUSTED_PUBLISHING)
    )


def is_valid_secret_name(name: String) -> Bool:
    """`[A-Za-z_][A-Za-z0-9_]*`, 1..128 bytes."""
    var b = name.as_bytes()
    var n = len(b)
    if n == 0 or n > _MAX_SECRET_NAME_BYTES:
        return False
    for i in range(n):
        var c = Int(b[i])
        var letter = (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
        var digit = c >= 48 and c <= 57
        var underscore = c == 95
        if i == 0 and digit:
            return False
        if not (letter or digit or underscore):
            return False
    return True


def oidc_exchange_implemented(artifact_type: String) -> Bool:
    """True for the artifact types whose registry trusted-publishing exchange
    is implemented. Any other type must use API_TOKEN."""
    return (
        artifact_type == ARTIFACT_TYPE_CONDA
        or artifact_type == ARTIFACT_TYPE_PYTHON
    )


struct ChannelCredential(Copyable, Movable):
    """How one repository's push identity authenticates. Names only."""

    var kind: String
    var secret_name: String

    def __init__(out self, var kind: String, var secret_name: String):
        self.kind = kind^
        self.secret_name = secret_name^

    def is_api_token(self) -> Bool:
        return self.kind == CREDENTIAL_KIND_API_TOKEN

    def is_oidc_trusted_publishing(self) -> Bool:
        return self.kind == CREDENTIAL_KIND_OIDC_TRUSTED_PUBLISHING


def _refuse(channel: String, artifact_type: String, rest: String) raises:
    raise Error(
        String("channel '")
        + channel
        + String("' ")
        + rest
        + String(" for its ")
        + artifact_type
        + String(" repository")
    )


def validate_channel_credential(
    channel: String,
    artifact_type: String,
    credential: Optional[ChannelCredential],
) raises:
    """Every rule a repository's credential must satisfy, each refused by its
    own message naming the channel and the repository's artifact type. See
    the module header. Never quotes a secret_name or a kind: either field is
    where a secret gets pasted."""
    if not credential:
        _refuse(
            channel,
            artifact_type,
            String("declares no credential (a credential is never defaulted)"),
        )
    ref cred = credential.value()
    if cred.kind.strip().byte_length() == 0:
        _refuse(
            channel,
            artifact_type,
            String("declares a credential with no kind (expected ")
            + _known_credential_kinds()
            + String(")"),
        )
    if not is_known_credential_kind(cred.kind):
        _refuse(
            channel,
            artifact_type,
            String("declares an unknown credential kind (not quoted: it may")
            + String(" be a pasted secret; expected ")
            + _known_credential_kinds()
            + String(")"),
        )
    if cred.is_api_token():
        if cred.secret_name.byte_length() == 0:
            _refuse(
                channel,
                artifact_type,
                String("declares an API_TOKEN credential with no secret_name"),
            )
    else:
        if cred.secret_name.byte_length() > 0:
            _refuse(
                channel,
                artifact_type,
                String("declares an OIDC_TRUSTED_PUBLISHING credential with")
                + String(" a secret_name (trusted publishing stores no")
                + String(" secret)"),
            )
        if not oidc_exchange_implemented(artifact_type):
            _refuse(
                channel,
                artifact_type,
                String("declares an OIDC_TRUSTED_PUBLISHING credential, which")
                + String(" has no implemented exchange for ")
                + artifact_type
                + String(" (implemented: ")
                + String(ARTIFACT_TYPE_CONDA)
                + String(", ")
                + String(ARTIFACT_TYPE_PYTHON)
                + String(")"),
            )
        return
    if not is_valid_secret_name(cred.secret_name):
        _refuse(
            channel,
            artifact_type,
            String("declares an invalid secret_name (not quoted: it may be a")
            + String(" pasted secret; expected a handle matching")
            + String(" [A-Za-z_][A-Za-z0-9_]*, at most 128 bytes)"),
        )
