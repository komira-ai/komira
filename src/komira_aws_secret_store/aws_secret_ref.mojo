# =============================================================================
# komira_aws_secret_store/aws_secret_ref.mojo: the handle grammar of the
#   Secrets Manager adapters.
# =============================================================================
#
# A handle (`secret_ref`) names a Secrets Manager secret and, for a resolve,
# optionally one of its versions:
#
#   <SecretId>                      the version labelled AWSCURRENT
#   <SecretId>?versionStage=<label> the version that holds <label>
#   <SecretId>?versionId=<id>       that version
#
# <SecretId> is what GetSecretValue's `SecretId` takes, in one of two forms:
#
#   a name   1 to 512 bytes of `[A-Za-z0-9/_+=.@-]`, the characters
#            CreateSecret's `Name` allows;
#   an ARN   `arn:<partition>:secretsmanager:<region>:<account>:secret:<name>-<suffix>`:
#            <partition> `aws` or `aws-` and lower-case letters and hyphens,
#            <region> lower-case letters, digits and hyphens, <account> 12
#            digits, <name> a name as above, <suffix> the six letters or
#            digits the service appends. A partial ARN (no suffix) is
#            refused: the service matches it by prefix.
#
# Neither form can hold `?`, so the first `?` ends the SecretId. One
# selector at most. A `versionStage` label is 1 to 256 bytes of the name
# characters; a `versionId` is 32 to 64 bytes of letters, digits and
# hyphens (a ClientRequestToken, by default a UUID). The service documents
# lengths for both and no character set: the sets here are this adapter's
# choice, so a label outside them is refused before it is sent. A selector
# the grammar does not name, or an empty value, is refused. A writer's handle
# is the bare <SecretId>: a write makes the version the service labels
# AWSCURRENT, and the selectors name versions that already exist.
#
# A refusal never quotes the handle: a handle outside the grammar may be a
# value pasted into the wrong field, and the character sets above keep most
# such values out of the grammar, so out of every error text that names a
# handle.
# =============================================================================

comptime AWS_SELECTOR_VERSION_ID = "versionId"
comptime AWS_SELECTOR_VERSION_STAGE = "versionStage"
comptime AWS_STAGE_CURRENT = "AWSCURRENT"


@fieldwise_init
struct AwsSecretRef(Copyable, Movable, Writable):
    """A parsed Secrets Manager handle: the `SecretId` and at most one of a
    version id and a staging label. Names only; no value."""

    var secret_id: String
    """The secret's name or ARN, as GetSecretValue's `SecretId` takes it."""
    var version_id: Optional[String]
    """The version the handle pins by id, if any."""
    var version_stage: Optional[String]
    """The staging label the handle pins, if any."""

    def is_plain(self) -> Bool:
        """True when the handle names the secret only (no selector)."""
        return not self.version_id and not self.version_stage

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.secret_id)
        if self.version_id:
            writer.write("?", AWS_SELECTOR_VERSION_ID, "=", self.version_id.value())
        if self.version_stage:
            writer.write(
                "?", AWS_SELECTOR_VERSION_STAGE, "=", self.version_stage.value()
            )


def _name_byte(c: UInt8) -> Bool:
    """A byte CreateSecret's `Name` allows: `[A-Za-z0-9/_+=.@-]`."""
    return (
        (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
        or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
        or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
        or c == UInt8(ord("/"))
        or c == UInt8(ord("_"))
        or c == UInt8(ord("+"))
        or c == UInt8(ord("="))
        or c == UInt8(ord("."))
        or c == UInt8(ord("@"))
        or c == UInt8(ord("-"))
    )


def _all_name_bytes(s: String, lo: Int, hi: Int) -> Bool:
    """Whether `s` is `lo` to `hi` bytes, each a `_name_byte`."""
    var b = s.as_bytes()
    if len(b) < lo or len(b) > hi:
        return False
    for i in range(len(b)):
        if not _name_byte(b[i]):
            return False
    return True


def _alnum(c: UInt8) -> Bool:
    return (
        (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
        or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
        or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
    )


def _lower_label(s: String, digits: Bool) -> Bool:
    """Non-empty lower-case letters and hyphens (and digits when
    `digits`)."""
    var b = s.as_bytes()
    if len(b) == 0:
        return False
    for i in range(len(b)):
        var c = b[i]
        var ok = (c >= UInt8(ord("a")) and c <= UInt8(ord("z"))) or c == UInt8(ord("-"))
        if digits and c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
            ok = True
        if not ok:
            return False
    return True


def _arn_ok(arn: String) -> Bool:
    """Whether `arn` is a full Secrets Manager secret ARN (module header)."""
    var parts = List[String]()
    for piece in arn.split(":"):
        parts.append(String(piece))
    if len(parts) != 7:
        return False
    if parts[0] != "arn" or parts[2] != "secretsmanager" or parts[5] != "secret":
        return False
    var partition = parts[1].copy()
    if partition != "aws" and not (
        partition.startswith("aws-") and _lower_label(partition, False)
    ):
        return False
    if not _lower_label(parts[3], True):
        return False
    var account = parts[4].as_bytes()
    if len(account) != 12:
        return False
    for i in range(len(account)):
        if account[i] < UInt8(ord("0")) or account[i] > UInt8(ord("9")):
            return False
    var tail = parts[6].copy()
    var n = tail.byte_length()
    # <name>-<six letters or digits>, the name at least one byte.
    if n < 8 or tail.as_bytes()[n - 7] != UInt8(ord("-")):
        return False
    for i in range(n - 6, n):
        if not _alnum(tail.as_bytes()[i]):
            return False
    return _all_name_bytes(String(tail[byte = 0 : n - 7]), 1, 512)


def _version_id_ok(v: String) -> Bool:
    var b = v.as_bytes()
    if len(b) < 32 or len(b) > 64:
        return False
    for i in range(len(b)):
        if not _alnum(b[i]) and b[i] != UInt8(ord("-")):
            return False
    return True


def _secret_id_checked(var secret_id: String) raises -> String:
    if secret_id.startswith("arn:"):
        if not _arn_ok(secret_id):
            raise Error(
                "secret_ref's ARN is not a full Secrets Manager secret ARN:"
                " write arn:<partition>:secretsmanager:<region>:<account>:secret:<name>-<suffix>"
            )
        return secret_id^
    if not _all_name_bytes(secret_id, 1, 512):
        raise Error(
            "secret_ref is not a secret name: 1 to 512 of the characters"
            " A-Z a-z 0-9 / _ + = . @ -"
        )
    return secret_id^


def parse_aws_secret_ref(secret_ref: String) raises -> AwsSecretRef:
    """Parse `secret_ref` under the grammar in this module's header. Raises,
    without quoting the handle, for an empty or malformed SecretId, more
    than one selector, a selector other than `versionId` and `versionStage`,
    or a selector value that is empty or outside its set."""
    var q = secret_ref.find("?")
    if q < 0:
        if secret_ref.byte_length() == 0:
            raise Error("secret_ref is empty: it must name a secret")
        return AwsSecretRef(
            _secret_id_checked(secret_ref.copy()),
            Optional[String](),
            Optional[String](),
        )
    var secret_id = String(secret_ref[byte=0:q])
    if secret_id.byte_length() == 0:
        raise Error("secret_ref names no secret before its '?'")
    secret_id = _secret_id_checked(secret_id^)
    var selector = String(secret_ref[byte = q + 1 : secret_ref.byte_length()])
    if selector.find("&") >= 0 or selector.find("?") >= 0:
        raise Error(
            "secret_ref holds more than one selector: it names at most one of"
            " versionId and versionStage"
        )
    var eq = selector.find("=")
    if eq < 0:
        raise Error("secret_ref's selector has no '=': write versionId=<id> or versionStage=<label>")
    var key = String(selector[byte=0:eq])
    var value = String(selector[byte = eq + 1 : selector.byte_length()])
    if key == AWS_SELECTOR_VERSION_ID:
        if value.byte_length() == 0:
            raise Error("secret_ref's versionId is empty")
        if not _version_id_ok(value):
            raise Error(
                "secret_ref's versionId is not 32 to 64 letters, digits and hyphens"
            )
        return AwsSecretRef(
            secret_id^, Optional[String](value^), Optional[String]()
        )
    if key == AWS_SELECTOR_VERSION_STAGE:
        if value.byte_length() == 0:
            raise Error("secret_ref's versionStage is empty")
        if not _all_name_bytes(value, 1, 256):
            raise Error(
                "secret_ref's versionStage is not 1 to 256 of the characters"
                " A-Z a-z 0-9 / _ + = . @ -"
            )
        return AwsSecretRef(
            secret_id^, Optional[String](), Optional[String](value^)
        )
    raise Error(
        "secret_ref's selector is neither versionId nor versionStage"
    )
