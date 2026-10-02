# =============================================================================
# komira_aws_core/shared_config.mojo -- the shared config and credentials files
# =============================================================================
#
# Parses the two AWS shared files the way the AWS SDKs do:
#   https://docs.aws.amazon.com/sdkref/latest/guide/file-format.html
#   https://docs.aws.amazon.com/sdkref/latest/guide/file-location.html
#
# Locations (file-location.html): the config file is AWS_CONFIG_FILE, else
# ~/.aws/config; the credentials file is AWS_SHARED_CREDENTIALS_FILE, else
# ~/.aws/credentials. "~" is the HOME variable. A file that does not exist is
# an empty file.
#
# Profile selection (file-format.html, "Format of the config file"): the
# explicit profile parameter, else AWS_PROFILE, else "default". A profile that
# was NAMED (parameter or AWS_PROFILE) and is in neither file is refused; a
# missing "default" just means the files supply nothing.
#
# Section rules (file-format.html):
#   config file:       [default] or [profile default]; [profile NAME] for any
#                      other profile. When both default spellings appear,
#                      [profile default] wins. A bare [NAME] for another
#                      profile, and the non-profile sections ([sso-session x],
#                      [services x]), hold no profile and are skipped.
#   credentials file:  [NAME], never the "profile " prefix; a [profile NAME]
#                      section there is skipped.
#   Both files may name one profile; its settings merge, and a setting in the
#   credentials file wins over the same setting in the config file.
#   A repeated section merges into the earlier one; a repeated key's last
#   value wins.
#
# Line rules: blank lines and lines starting with '#' or ';' are comments. On
# a property line, a '#' or ';' preceded by a space or tab starts a comment.
# A line that starts with whitespace continues the previous property's value
# (joined with "\n"). A property line without '=' or with an empty key, and a
# section header without its ']', are refused naming the file and line; the
# refusal never quotes the line, which may hold a secret. A property before
# the first section belongs to no profile and is skipped.
# =============================================================================

from .sources import EnvSource, FileSource
from ._text import is_space, split_lines, sub, trim


# The settings this package reads from a profile. Each is defined in the
# AWS SDKs and Tools Reference Guide; the page is cited where it is read.
comptime PROFILE_AWS_ACCESS_KEY_ID: StaticString = "aws_access_key_id"
comptime PROFILE_AWS_SECRET_ACCESS_KEY: StaticString = "aws_secret_access_key"
comptime PROFILE_AWS_SESSION_TOKEN: StaticString = "aws_session_token"
comptime PROFILE_ROLE_ARN: StaticString = "role_arn"
comptime PROFILE_SOURCE_PROFILE: StaticString = "source_profile"
comptime PROFILE_CREDENTIAL_SOURCE: StaticString = "credential_source"
comptime PROFILE_WEB_IDENTITY_TOKEN_FILE: StaticString = "web_identity_token_file"
comptime PROFILE_ROLE_SESSION_NAME: StaticString = "role_session_name"
comptime PROFILE_EXTERNAL_ID: StaticString = "external_id"
comptime PROFILE_DURATION_SECONDS: StaticString = "duration_seconds"
comptime PROFILE_REGION: StaticString = "region"
comptime PROFILE_CREDENTIAL_PROCESS: StaticString = "credential_process"
comptime PROFILE_SSO_SESSION: StaticString = "sso_session"
comptime PROFILE_SSO_START_URL: StaticString = "sso_start_url"
comptime PROFILE_LOGIN_SESSION: StaticString = "login_session"


struct AwsProfile(Copyable, Movable):
    """One named profile: its settings, in first-seen order.

    Not `Writable`: a profile can hold a secret access key.
    """

    var name: String
    var keys: List[String]
    var values: List[String]

    def __init__(out self, name: String):
        self.name = name
        self.keys = List[String]()
        self.values = List[String]()

    def _index(self, key: String) -> Int:
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                return i
        return -1

    def has(self, key: String) -> Bool:
        """True when the setting is present with a non-empty value."""
        var i = self._index(key)
        return i >= 0 and self.values[i].byte_length() > 0

    def get(self, key: String) -> String:
        """The setting's value, "" when absent."""
        var i = self._index(key)
        if i < 0:
            return String("")
        return self.values[i]

    def set(mut self, key: String, value: String):
        var i = self._index(key)
        if i < 0:
            self.keys.append(key)
            self.values.append(value)
        else:
            self.values[i] = value

    def append_continuation(mut self, key: String, more: String):
        var i = self._index(key)
        if i >= 0:
            self.values[i] = self.values[i] + "\n" + more

    def merge_from(mut self, other: AwsProfile):
        for i in range(len(other.keys)):
            self.set(other.keys[i], other.values[i])


struct AwsProfileSet(Movable):
    """Every profile of the shared files, merged."""

    var profiles: List[AwsProfile]

    def __init__(out self):
        self.profiles = List[AwsProfile]()

    def index_of(self, name: String) -> Int:
        for i in range(len(self.profiles)):
            if self.profiles[i].name == name:
                return i
        return -1

    def has_profile(self, name: String) -> Bool:
        return self.index_of(name) >= 0

    def profile(self, name: String) raises -> AwsProfile:
        var i = self.index_of(name)
        if i < 0:
            raise Error("the AWS profile '" + name + "' is in neither shared file")
        return self.profiles[i].copy()

    def _merge(mut self, p: AwsProfile):
        var i = self.index_of(p.name)
        if i < 0:
            self.profiles.append(p.copy())
        else:
            self.profiles[i].merge_from(p)


# The name a bare [default] section is parked under while a config file is
# parsed, so [profile default] can win over it. Not a valid profile name.
comptime _BARE_DEFAULT: StaticString = " bare default"


def _strip_inline_comment(v: String) -> String:
    var b = v.as_bytes()
    for i in range(1, len(b)):
        if (b[i] == UInt8(0x23) or b[i] == UInt8(0x3B)) and (
            b[i - 1] == UInt8(0x20) or b[i - 1] == UInt8(0x09)
        ):
            return sub(v, 0, i)
    return v


def _section_name(inner: String, is_config: Bool) -> String:
    """The profile a section header names, "" for a section holding none."""
    var name = trim(inner)
    var b = name.as_bytes()
    var has_prefix = (
        len(b) > 7
        and sub(name, 0, 7) == "profile"
        and (b[7] == UInt8(0x20) or b[7] == UInt8(0x09))
    )
    if is_config:
        if has_prefix:
            return trim(sub(name, 8, len(b)))
        if name == "default":
            return String(_BARE_DEFAULT)
        return String("")
    if has_prefix:
        return String("")
    return name


def parse_profile_file(
    text: String, is_config: Bool, path: String
) raises -> AwsProfileSet:
    """Parses one shared file. `is_config` picks the config file's section
    rules over the credentials file's. Refusals name `path` and the line
    number, never the line."""
    var out = AwsProfileSet()
    var lines = split_lines(text)
    var current = -1  # index into out.profiles, -1 = no profile section
    var in_section = False
    var last_key = String("")
    for ln in range(len(lines)):
        var raw = lines[ln]
        var where = path + ":" + String(ln + 1)
        var line = trim(raw)
        if line.byte_length() == 0:
            continue
        var c0 = line.as_bytes()[0]
        if c0 == UInt8(0x23) or c0 == UInt8(0x3B):
            continue
        if c0 == UInt8(0x5B):  # '['
            var close = line.find("]")
            if close < 0:
                raise Error("malformed section header (no ']') at " + where)
            var rest = trim(sub(line, close + 1, line.byte_length()))
            if rest.byte_length() > 0:
                var r0 = rest.as_bytes()[0]
                if r0 != UInt8(0x23) and r0 != UInt8(0x3B):
                    raise Error("text after a section header at " + where)
            in_section = True
            last_key = String("")
            var name = _section_name(sub(line, 1, close), is_config)
            if name.byte_length() == 0:
                current = -1
                continue
            current = out.index_of(name)
            if current < 0:
                out.profiles.append(AwsProfile(name))
                current = len(out.profiles) - 1
            continue
        if is_space(raw.as_bytes()[0]):
            if not in_section:
                continue
            if last_key.byte_length() == 0:
                raise Error("a continuation line with no property at " + where)
            if current >= 0:
                out.profiles[current].append_continuation(last_key, line)
            continue
        var eq = line.find("=")
        if eq < 0:
            raise Error("expected 'key = value' at " + where)
        var key = trim(sub(line, 0, eq))
        if key.byte_length() == 0:
            raise Error("a property with an empty key at " + where)
        var value = trim(
            _strip_inline_comment(sub(line, eq + 1, line.byte_length()))
        )
        last_key = key
        if current >= 0:
            out.profiles[current].set(key, value)
    if is_config:
        var bare = out.index_of(String(_BARE_DEFAULT))
        if bare >= 0:
            if out.has_profile(String("default")):
                _ = out.profiles.pop(bare)
            else:
                out.profiles[bare].name = String("default")
    return out^


def _expand_home(p: String, home: String) -> String:
    """"~/x" -> HOME + "/x"; "" when it needs HOME and HOME is unset."""
    if p == "~" or (p.byte_length() >= 2 and sub(p, 0, 2) == "~/"):
        if home.byte_length() == 0:
            return String("")
        return home + sub(p, 1, p.byte_length())
    return p


@fieldwise_init
struct SharedFilePaths(Copyable, Movable):
    """Where the shared files are; "" when no location can be formed."""

    var config_file: String
    var credentials_file: String


def shared_file_paths[E: EnvSource](mut env: E) -> SharedFilePaths:
    """file-location.html: AWS_CONFIG_FILE / AWS_SHARED_CREDENTIALS_FILE, else
    ~/.aws/config and ~/.aws/credentials, with "~" taken from HOME."""
    # https://docs.aws.amazon.com/sdkref/latest/guide/file-location.html
    var home = env.get("HOME")
    var cfg = env.get("AWS_CONFIG_FILE")
    var creds = env.get("AWS_SHARED_CREDENTIALS_FILE")
    if cfg.byte_length() == 0:
        cfg = String("~/.aws/config")
    if creds.byte_length() == 0:
        creds = String("~/.aws/credentials")
    return SharedFilePaths(_expand_home(cfg, home), _expand_home(creds, home))


def load_profiles[
    E: EnvSource, F: FileSource
](mut env: E, mut files: F) raises -> AwsProfileSet:
    """Both shared files, parsed and merged (credentials file wins)."""
    var paths = shared_file_paths(env)
    var out = AwsProfileSet()
    if paths.config_file.byte_length() > 0 and files.exists(paths.config_file):
        var cfg = parse_profile_file(
            files.read(paths.config_file), True, paths.config_file
        )
        for i in range(len(cfg.profiles)):
            out._merge(cfg.profiles[i])
    if paths.credentials_file.byte_length() > 0 and files.exists(
        paths.credentials_file
    ):
        var cr = parse_profile_file(
            files.read(paths.credentials_file), False, paths.credentials_file
        )
        for i in range(len(cr.profiles)):
            out._merge(cr.profiles[i])
    return out^


@fieldwise_init
struct ProfileChoice(Copyable, Movable):
    """The selected profile name, and whether it was named explicitly (by the
    parameter or AWS_PROFILE) rather than defaulted."""

    var name: String
    var named: Bool


def select_profile[E: EnvSource](explicit: String, mut env: E) -> ProfileChoice:
    """The explicit parameter, else AWS_PROFILE, else "default"."""
    if explicit.byte_length() > 0:
        return ProfileChoice(explicit, True)
    # https://docs.aws.amazon.com/sdkref/latest/guide/file-format.html#file-format-profile
    var p = trim(env.get("AWS_PROFILE"))
    if p.byte_length() > 0:
        return ProfileChoice(p, True)
    return ProfileChoice(String("default"), False)
