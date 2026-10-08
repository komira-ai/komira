# =============================================================================
# komira_gcp_secret_store/gcp_secret_ref.mojo: the handle grammar of the
#   Secret Manager adapters, and CRC32C.
# =============================================================================
#
# A handle (`secret_ref`) is a Secret Manager resource name, as the service
# spells it:
#
#   projects/<p>/secrets/<s>                             a global secret
#   projects/<p>/locations/<l>/secrets/<s>               a regional secret
#   ...followed by /versions/<v>                         one of its versions
#
# <v> is `latest` (an alias of the most recently created version) or a
# version number (a decimal without a leading zero). A handle that names a
# secret resolves to its `latest` version; a writer's handle names the
# secret (a write adds a version; a version number is the service's to
# assign). Which endpoint a regional secret is served at is the client's
# (`set_rest_host`), not the handle's. Each part has its shape:
#
#   <s>  1 to 255 of `[A-Za-z0-9_-]`, the characters CreateSecret's
#        `secretId` allows;
#   <p>  a project number (1 to 19 digits), or a project id: 6 to 30 bytes
#        of `[a-z0-9-]`, starting with a letter and not ending with a
#        hyphen, optionally after a `<domain>:` (a domain-scoped project:
#        1 to 253 bytes of `[a-z0-9.-]`, starting and ending with a letter or
#        digit);
#   <l>  1 to 63 bytes of `[a-z0-9-]`, starting with a letter (a location
#        id such as `us-central1`).
#
# A refusal never quotes the handle: a handle outside the grammar may be a
# value pasted into the wrong field.
#
# `crc32c` is CRC-32C (Castagnoli), the checksum Secret Manager keeps as a
# payload's `dataCrc32c`: the writer sends it with each version and the
# store checks it on each value it reads. The generated client carries the
# field and computes nothing.
# =============================================================================

comptime GCP_VERSION_LATEST = "latest"


@fieldwise_init
struct GcpSecretRef(Copyable, Movable, Writable):
    """A parsed Secret Manager handle. Names only; no value."""

    var project: String
    """The project id or number."""
    var location: String
    """The location of a regional secret; "" for a global one."""
    var secret_id: String
    """The secret's id within its project (and location)."""
    var version: String
    """`latest` or a version number; "" when the handle names the secret."""

    def is_regional(self) -> Bool:
        return self.location.byte_length() > 0

    def names_version(self) -> Bool:
        return self.version.byte_length() > 0

    def parent(self) -> String:
        """`projects/<p>` or `projects/<p>/locations/<l>`: where a secret is
        created."""
        var out = String("projects/") + self.project
        if self.is_regional():
            out += String("/locations/") + self.location
        return out^

    def secret_name(self) -> String:
        """The secret's resource name, without a version."""
        return self.parent() + "/secrets/" + self.secret_id

    def version_name(self) -> String:
        """The version a resolve reads: the handle's, or `latest`."""
        var v = self.version.copy() if self.names_version() else String(GCP_VERSION_LATEST)
        return self.secret_name() + "/versions/" + v

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.secret_name())
        if self.names_version():
            writer.write("/versions/", self.version)


def _lower(c: UInt8) -> Bool:
    return c >= UInt8(ord("a")) and c <= UInt8(ord("z"))


def _digit(c: UInt8) -> Bool:
    return c >= UInt8(ord("0")) and c <= UInt8(ord("9"))


def _secret_id_ok(s: String) -> Bool:
    """1 to 255 of `[A-Za-z0-9_-]`."""
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > 255:
        return False
    for i in range(len(b)):
        var c = b[i]
        if not (
            _lower(c)
            or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
            or _digit(c)
            or c == UInt8(ord("_"))
            or c == UInt8(ord("-"))
        ):
            return False
    return True


def _project_id_ok(s: String) -> Bool:
    """6 to 30 of `[a-z0-9-]`, a letter first, no hyphen last."""
    var b = s.as_bytes()
    if len(b) < 6 or len(b) > 30 or not _lower(b[0]) or b[len(b) - 1] == UInt8(ord("-")):
        return False
    for i in range(len(b)):
        if not (_lower(b[i]) or _digit(b[i]) or b[i] == UInt8(ord("-"))):
            return False
    return True


def _domain_ok(s: String) -> Bool:
    """1 to 253 of `[a-z0-9.-]`, a letter or digit first and last."""
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > 253:
        return False
    if not (_lower(b[0]) or _digit(b[0])) or not (
        _lower(b[len(b) - 1]) or _digit(b[len(b) - 1])
    ):
        return False
    for i in range(len(b)):
        if not (
            _lower(b[i]) or _digit(b[i]) or b[i] == UInt8(ord("-")) or b[i] == UInt8(ord("."))
        ):
            return False
    return True


def _project_ok(s: String) -> Bool:
    """A project number or a (possibly domain-scoped) project id."""
    var b = s.as_bytes()
    if len(b) == 0:
        return False
    var all_digits = len(b) <= 19
    for i in range(len(b)):
        if not _digit(b[i]):
            all_digits = False
    if all_digits:
        return True
    var colon = s.find(":")
    if colon < 0:
        return _project_id_ok(s)
    return _domain_ok(String(s[byte=0:colon])) and _project_id_ok(
        String(s[byte = colon + 1 : s.byte_length()])
    )


def _location_ok(s: String) -> Bool:
    """1 to 63 of `[a-z0-9-]`, a letter first."""
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > 63 or not _lower(b[0]):
        return False
    for i in range(len(b)):
        if not (_lower(b[i]) or _digit(b[i]) or b[i] == UInt8(ord("-"))):
            return False
    return True


def _version_ok(v: String) -> Bool:
    if v == GCP_VERSION_LATEST:
        return True
    var b = v.as_bytes()
    if len(b) == 0 or b[0] == UInt8(ord("0")):
        return False
    for i in range(len(b)):
        if b[i] < UInt8(ord("0")) or b[i] > UInt8(ord("9")):
            return False
    return True


def parse_gcp_secret_ref(secret_ref: String) raises -> GcpSecretRef:
    """Parse `secret_ref` under the grammar in this module's header. Raises,
    without quoting the handle, for any other shape."""
    var parts = List[String]()
    for piece in secret_ref.split("/"):
        parts.append(String(piece))
    var n = len(parts)
    var location = String("")
    var at = 2
    if n >= 2 and parts[0] == "projects" and n >= 4 and parts[2] == "locations":
        location = parts[3].copy()
        at = 4
    if (
        n < at + 2
        or parts[0] != "projects"
        or parts[at] != "secrets"
        or (n != at + 2 and n != at + 4)
        or (n == at + 4 and parts[at + 2] != "versions")
    ):
        raise Error(
            "secret_ref is not a Secret Manager name: write"
            " projects/<p>[/locations/<l>]/secrets/<s>[/versions/<v>]"
        )
    var project = parts[1].copy()
    var secret_id = parts[at + 1].copy()
    var version = parts[at + 3].copy() if n == at + 4 else String("")
    if not _project_ok(project):
        raise Error(
            "secret_ref's project is neither a project number nor a project id"
        )
    if at == 4 and not _location_ok(location):
        raise Error("secret_ref's location is not a location id")
    if not _secret_id_ok(secret_id):
        raise Error(
            "secret_ref's secret id is not 1 to 255 of the characters"
            " A-Z a-z 0-9 _ -"
        )
    if n == at + 4 and not _version_ok(version):
        raise Error("secret_ref's version is neither 'latest' nor a version number")
    return GcpSecretRef(project^, location^, secret_id^, version^)


def crc32c(data: Span[UInt8, _]) -> UInt32:
    """CRC-32C (Castagnoli, reflected polynomial 0x82F63B78), bit by bit:
    the checksum Secret Manager keeps as a payload's `dataCrc32c`. A secret
    is at most a few KiB, so no table."""
    var crc = UInt32(0xFFFFFFFF)
    for i in range(len(data)):
        crc ^= UInt32(data[i])
        for _ in range(8):
            if (crc & 1) == 1:
                crc = (crc >> 1) ^ UInt32(0x82F63B78)
            else:
                crc = crc >> 1
    return crc ^ UInt32(0xFFFFFFFF)
