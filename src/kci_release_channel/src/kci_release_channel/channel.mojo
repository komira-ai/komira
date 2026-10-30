# =============================================================================
# kci_release_channel/channel.mojo -- a `channel` entry.
# =============================================================================
#
# A release channel is a publish destination and nothing else:
#
#   name          the channel id: lowercase letters, digits and `-`, starting
#                 with a letter, not ending with `-`, at most 63 bytes.
#   visibility    PUBLIC or PRIVATE, for every repository of the channel.
#                 PUBLIC means anonymous read; PRIVATE grants no read at all
#                 (further read grants belong to whoever owns the repository).
#   repositories  one per artifact type. Each names its `location` (the
#                 address a push lands at), its `push_identity` (the only
#                 principal that may write it) and its `credential` (how that
#                 principal authenticates: a kind and, for API_TOKEN, the
#                 NAME of the secret; see `channel_credential.mojo`).
#                 An OIDC_TRUSTED_PUBLISHING repository may also name a
#                 `break_glass_push_identity`: the subject a BREAK-GLASS run
#                 publishes as (its own GitHub environment, a second trusted
#                 publisher of the same channel; kci_release_machine's
#                 `break_glass_environment`).
#
# Every function here takes the channel list as an argument, so adding a
# channel is adding one value.
#
# `validate_channels` states every rule the list must satisfy and
# refuses each with a message naming the offending channel, repository or
# location.
#
# Plain value types (Strings in Lists); nothing here allocates beyond them.
# =============================================================================

from .artifact_types import (
    ARTIFACT_TYPE_CONDA,
    ARTIFACT_TYPE_NPM,
    ARTIFACT_TYPE_OCI,
    ARTIFACT_TYPE_PYTHON,
    is_known_artifact_type,
    known_artifact_types,
)
from .channel_credential import ChannelCredential, validate_channel_credential


# ── Visibility. ──────────────────────────────────────────────────────────────
comptime VISIBILITY_PUBLIC: String = "PUBLIC"
comptime VISIBILITY_PRIVATE: String = "PRIVATE"

comptime _MAX_NAME_BYTES: Int = 63


def is_valid_channel_name(name: String) -> Bool:
    """`[a-z][a-z0-9-]*`, not ending with `-`, 1..63 bytes."""
    var b = name.as_bytes()
    var n = len(b)
    if n == 0 or n > _MAX_NAME_BYTES:
        return False
    for i in range(n):
        var c = Int(b[i])
        var lower = c >= 97 and c <= 122
        var digit = c >= 48 and c <= 57
        var dash = c == 45
        if i == 0 and not lower:
            return False
        if not (lower or digit or dash):
            return False
    return Int(b[n - 1]) != 45


struct ChannelRepository(Copyable, Movable):
    """One repository backing a channel for one artifact type."""

    var artifact_type: String
    var location: String
    var push_identity: String
    var credential: Optional[ChannelCredential]
    """None when the channel names no credential; validation refuses
    that, so a validated repository always carries one."""
    var break_glass_push_identity: String
    """The subject a break-glass run publishes as ("" for none; module
    header). Set by the parser after construction."""

    def __init__(
        out self,
        var artifact_type: String,
        var location: String,
        var push_identity: String,
        var credential: Optional[ChannelCredential],
    ):
        self.artifact_type = artifact_type^
        self.location = location^
        self.push_identity = push_identity^
        self.credential = credential^
        self.break_glass_push_identity = String("")

    def declared_credential(self) raises -> ChannelCredential:
        """The credential this repository declares. Raises when it declares
        none: a credential is never defaulted."""
        if not self.credential:
            raise Error(
                String("the ")
                + self.artifact_type
                + String(" repository declares no credential")
            )
        return self.credential.value().copy()


comptime _ENVIRONMENT_MARK: String = ":environment:"


def _environment_of(subject: String) -> String:
    var at = subject.rfind(String(_ENVIRONMENT_MARK))
    if at < 0:
        return String("")
    var env = String(subject[byte = at + String(_ENVIRONMENT_MARK).byte_length() :])
    if env.byte_length() == 0 or env.find(String(":")) >= 0:
        return String("")
    return env^


def break_glass_push_identity_environment(repo: ChannelRepository) -> String:
    """The GitHub environment `repo`'s `break_glass_push_identity` names
    (as `push_identity_environment` reads `push_identity`), "" for none."""
    if not repo.credential or not repo.credential.value().is_oidc_trusted_publishing():
        return String("")
    return _environment_of(repo.break_glass_push_identity)


def push_identity_environment(repo: ChannelRepository) -> String:
    """The CI environment a trusted-publishing push identity names, or "".

    For OIDC_TRUSTED_PUBLISHING the push identity is the subject claim of the
    CI's identity token; GitHub's for a job in an environment is
    `repo:<owner>/<repo>:environment:<name>`. This returns `<name>`: the
    GitHub environment whose job may publish here. The stage that may publish
    here is the one whose `environment` (by default its name) equals it, so
    kci can refuse a publish from any other stage: stage `publish-staging` runs
    in environment `staging`, whose trusted publisher names `staging`. "" for an API_TOKEN repository, a
    repository with no credential, and a subject that names no environment
    (or an empty one, or one holding `:`)."""
    if not repo.credential:
        return String("")
    if not repo.credential.value().is_oidc_trusted_publishing():
        return String("")
    return _environment_of(repo.push_identity)


struct Channel(Copyable, Movable):
    """One release channel. See the module header."""

    var name: String
    var visibility: String
    var repositories: List[ChannelRepository]

    def __init__(
        out self,
        var name: String,
        var visibility: String,
        var repositories: List[ChannelRepository],
    ):
        self.name = name^
        self.visibility = visibility^
        self.repositories = repositories^

    def is_public(self) -> Bool:
        """True when the channel's repositories are anonymously readable."""
        return self.visibility == VISIBILITY_PUBLIC

    def repository_for(self, artifact_type: String) raises -> ChannelRepository:
        """The repository this channel declares for `artifact_type`. Raises
        when it declares none: a missing repository is never defaulted."""
        for i in range(len(self.repositories)):
            if self.repositories[i].artifact_type == artifact_type:
                return self.repositories[i].copy()
        raise Error(
            String("channel '")
            + self.name
            + String("' declares no ")
            + artifact_type
            + String(" repository")
        )


def channel_names(channels: List[Channel]) -> List[String]:
    """Every declared channel's name, in file order."""
    var out = List[String]()
    for i in range(len(channels)):
        out.append(channels[i].name.copy())
    return out^


def find_channel(
    channels: List[Channel], name: String
) raises -> Channel:
    """The channel named `name`. Raises on an unknown name; an unknown
    channel never falls back to another one."""
    for i in range(len(channels)):
        if channels[i].name == name:
            return channels[i].copy()
    raise Error(
        String("unknown release channel '")
        + name
        + String("' (declared: ")
        + String(", ").join(channel_names(channels))
        + String(")")
    )


def _refuse(name: String, rest: String) raises:
    raise Error(String("channel '") + name + String("' ") + rest)


def _is_blank(value: String) -> Bool:
    """True for an empty or whitespace-only value."""
    return value.strip().byte_length() == 0


def _check_break_glass_identity(name: String, r: ChannelRepository) raises:
    """A `break_glass_push_identity` (module header): only on an
    OIDC_TRUSTED_PUBLISHING repository, naming a GitHub environment, not
    the one `push_identity` names, and otherwise the same subject."""
    var what = String("declares break_glass_push_identity '") + r.break_glass_push_identity + String("' for its ")
    what += r.artifact_type + String(" repository")
    if not r.credential or not r.credential.value().is_oidc_trusted_publishing():
        _refuse(name, what + String(", which does not publish by OIDC trusted publishing"))
    var env = break_glass_push_identity_environment(r)
    var main_env = push_identity_environment(r)
    if env.byte_length() == 0:
        _refuse(name, what + String(": it names no environment (`...:environment:<env>`)"))
    if env == main_env:
        _refuse(name, what + String(": it names the push_identity's own environment '") + env + String("'"))
    var head = String(r.break_glass_push_identity[byte = 0 : r.break_glass_push_identity.byte_length() - env.byte_length()])
    if main_env.byte_length() == 0 or not r.push_identity.startswith(head) or (
        r.push_identity.byte_length() - main_env.byte_length() != head.byte_length()
    ):
        _refuse(
            name,
            what + String(": it is not push_identity '") + r.push_identity
            + String("' with another environment (the same repository and workflow, a break-glass environment)"),
        )


def validate_channels(channels: List[Channel]) raises:
    """Every rule a channel list must satisfy, each refused by its own message:

      * a non-empty name of the allowed charset, declared once;
      * a visibility of PUBLIC or PRIVATE;
      * at least one repository, each of a known artifact type, with a
        location and push_identity that are not empty or whitespace-only, at
        most one per artifact type, and a valid credential
        (`validate_channel_credential`);
      * no location used by two repositories, in one channel or across two.
        Locations compare byte for byte: no case folding, no trailing-`/`
        trimming, so write each location in one canonical spelling.
    """
    var locations = List[String]()
    var owners = List[String]()
    var owner_types = List[String]()
    for i in range(len(channels)):
        ref d = channels[i]
        if d.name.byte_length() == 0:
            raise Error(
                String("channel #") + String(i + 1) + String(" has no name")
            )
        if not is_valid_channel_name(d.name):
            raise Error(
                String("channel name '")
                + d.name
                + String("' is invalid: use lowercase letters, digits and '-',")
                + String(" starting with a letter, not ending with '-',")
                + String(" at most 63 bytes")
            )
        for k in range(i):
            if channels[k].name == d.name:
                _refuse(d.name, String("is declared twice"))
        if d.visibility.byte_length() == 0:
            _refuse(
                d.name,
                String("declares no visibility (expected PUBLIC or PRIVATE)"),
            )
        if (
            d.visibility != VISIBILITY_PUBLIC
            and d.visibility != VISIBILITY_PRIVATE
        ):
            _refuse(
                d.name,
                String("declares unknown visibility '")
                + d.visibility
                + String("' (expected PUBLIC or PRIVATE)"),
            )
        if len(d.repositories) == 0:
            _refuse(
                d.name,
                String("declares no repository; it would publish nowhere"),
            )
        for j in range(len(d.repositories)):
            ref r = d.repositories[j]
            if not is_known_artifact_type(r.artifact_type):
                _refuse(
                    d.name,
                    String("declares a repository of unknown artifact type '")
                    + r.artifact_type
                    + String("' (known: ")
                    + known_artifact_types()
                    + String(")"),
                )
            for k in range(j):
                if d.repositories[k].artifact_type == r.artifact_type:
                    _refuse(
                        d.name,
                        String("declares more than one ")
                        + r.artifact_type
                        + String(" repository; a channel has one per")
                        + String(" artifact type"),
                    )
            if _is_blank(r.location):
                _refuse(
                    d.name,
                    String("declares an empty location for its ")
                    + r.artifact_type
                    + String(" repository"),
                )
            if _is_blank(r.push_identity):
                _refuse(
                    d.name,
                    String("declares an empty push_identity for its ")
                    + r.artifact_type
                    + String(" repository; every repository has exactly")
                    + String(" one writer"),
                )
            validate_channel_credential(d.name, r.artifact_type, r.credential)
            if r.break_glass_push_identity.byte_length() > 0:
                _check_break_glass_identity(d.name, r)
            for k in range(len(locations)):
                if locations[k] != r.location:
                    continue
                if owners[k] == d.name:
                    _refuse(
                        d.name,
                        String("declares location '")
                        + r.location
                        + String("' for both its ")
                        + owner_types[k]
                        + String(" and its ")
                        + r.artifact_type
                        + String(" repository; each repository has its own")
                        + String(" location"),
                    )
                raise Error(
                    String("location '")
                    + r.location
                    + String("' is declared by both channel '")
                    + owners[k]
                    + String("' and channel '")
                    + d.name
                    + String("'; each repository has its own location")
                )
            locations.append(r.location.copy())
            owners.append(d.name.copy())
            owner_types.append(r.artifact_type.copy())
