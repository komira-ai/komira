# =============================================================================
# komira_aws_secret_store/aws_secret_ref.mojo: the handle grammar of the
#   Secrets Manager adapters, and the error code of a generated-client error.
# =============================================================================
#
# A handle (`secret_ref`) names a Secrets Manager secret and, for a resolve,
# optionally one of its versions:
#
#   <SecretId>                      the version labelled AWSCURRENT
#   <SecretId>?versionStage=<label> the version that holds <label>
#   <SecretId>?versionId=<id>       that version
#
# <SecretId> is what GetSecretValue's `SecretId` takes: the secret's name or
# its full ARN. Neither can hold `?` (a name is `[A-Za-z0-9/_+=.@-]`, and an
# ARN is `arn:<partition>:secretsmanager:...:secret:<name>-<suffix>`), so the
# first `?` ends it. One selector at most; a selector the grammar does not
# name, or an empty value, is refused. A writer's handle is the bare
# <SecretId>: a write makes the version the service labels AWSCURRENT, and the
# selectors name versions that already exist.
#
# A refusal never quotes the handle: a handle outside the grammar may be a
# value pasted into the wrong field.
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


def parse_aws_secret_ref(secret_ref: String) raises -> AwsSecretRef:
    """Parse `secret_ref` under the grammar in this module's header. Raises,
    without quoting the handle, for an empty SecretId, more than one selector,
    a selector other than `versionId` and `versionStage`, or an empty
    selector value."""
    var q = secret_ref.find("?")
    if q < 0:
        if secret_ref.byte_length() == 0:
            raise Error("secret_ref is empty: it must name a secret")
        return AwsSecretRef(
            secret_ref.copy(), Optional[String](), Optional[String]()
        )
    var secret_id = String(secret_ref[byte=0:q])
    if secret_id.byte_length() == 0:
        raise Error("secret_ref names no secret before its '?'")
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
    if value.byte_length() == 0:
        raise Error(String("secret_ref's ") + key + " is empty")
    if key == AWS_SELECTOR_VERSION_ID:
        return AwsSecretRef(
            secret_id^, Optional[String](value^), Optional[String]()
        )
    if key == AWS_SELECTOR_VERSION_STAGE:
        return AwsSecretRef(
            secret_id^, Optional[String](), Optional[String](value^)
        )
    raise Error(
        "secret_ref's selector is neither versionId nor versionStage"
    )


def _error_code(operation: String, text: String) -> String:
    """The awsJson error code in an error the generated client raised for
    `operation` (`SecretsManager.<operation> failed: HTTP <status> <code>
    <message>`), or "" when `text` is not such an error: a transport failure,
    a request the client refused before sending, another operation's error."""
    var head = String("SecretsManager.") + operation + " failed: HTTP "
    if not text.startswith(head):
        return String("")
    var b = text.as_bytes()
    var i = head.byte_length()
    var digits = 0
    while i < len(b) and b[i] >= UInt8(ord("0")) and b[i] <= UInt8(ord("9")):
        i += 1
        digits += 1
    if digits == 0 or i >= len(b) or b[i] != UInt8(ord(" ")):
        return String("")
    i += 1
    var start = i
    while i < len(b) and b[i] != UInt8(ord(" ")):
        i += 1
    return String(text[byte=start:i])
