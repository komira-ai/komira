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
# <v> is `latest` (the highest-numbered version) or a version number (a
# decimal without a leading zero). A handle that names a secret resolves to
# its `latest` version; a writer's handle names the secret (a write adds a
# version; a version number is the service's to assign). <p> may be the
# project id or its number. Each of <p>, <l> and <s> is non-empty and is
# neither `.` nor `..`. Which endpoint a regional secret is served at is
# the client's (`set_rest_endpoint`), not the handle's.
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


def _segment_ok(s: String) -> Bool:
    return s.byte_length() > 0 and s != "." and s != ".."


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
    if not _segment_ok(project) or not _segment_ok(secret_id) or (
        at == 4 and not _segment_ok(location)
    ):
        raise Error("secret_ref has an empty, '.' or '..' project, location or secret id")
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
