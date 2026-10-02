# =============================================================================
# src/kci_publish/plan.mojo -- WHAT a publish run will do, decided before it
#   does anything: every artifact resolved to its channel repository, checked
#   against its bytes and the approved names, then planned as UPLOAD, SKIP or
#   REFUSE from what the registry already holds.
# =============================================================================
#
# THE ORDER IS THE CONTRACT. Every refusal below happens before the first
# upload of the run, so a run either refuses whole or starts uploading a set
# that was entirely checked:
#   1. `resolve_targets`: the channel's repository for each artifact's type
#      (a channel declaring none is refused naming the channel and the type);
#      the location and the push identity come from the channels file only.
#      The file name must be the artifact's name and version, and no file may
#      be listed twice.
#   2. `verify_target_files`: each file's sha256 is the manifest's.
#   3. `refuse_unapproved_names`: every name must be approved; otherwise ALL
#      are refused, naming every unapproved name at once.
#   4. `plan_from_presence` (pure): ABSENT plans UPLOAD, PRESENT_IDENTICAL
#      plans SKIP, anything else plans REFUSE with the registry's answer.
#      PRESENT_DIFFERENT and NO_COMMON_FIELD are definite (the name is taken by
#      other bytes, or cannot be compared); UNKNOWN, AUTH_REFUSED and
#      RATE_LIMITED mean the run cannot tell, and are marked so.
#
# Steps 1, 3 and 4 are pure functions of their arguments; step 2 reads the
# files. Reading the registry is `run.mojo`'s `plan_publish`.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.pathlib import Path

from kci_pkg_upload import (
    PRESENCE_ABSENT,
    PRESENCE_NO_COMMON_FIELD,
    PRESENCE_PRESENT_DIFFERENT,
    PRESENCE_PRESENT_IDENTICAL,
    SUBSTRATE_PREFIX_DEV_CONDA,
    SUBSTRATE_PUBLIC_PYPI,
    ApprovedNames,
    PackageCoordinate,
    Presence,
    content_identity_of,
    normalize_distribution_name,
    prefix_dev_repo_of_location,
    presence_kind_name,
)
from kci_pkg_upload.coordinate import repo_host, repo_path
from kci_pkg_upload.core_metadata import parse_wheel_name
from kci_pkg_upload.prefix_dev_registry import (
    refuse_malformed_conda_coordinate,
    refuse_name_not_the_files,
)
from kci_release_channel import (
    ARTIFACT_TYPE_CONDA,
    ARTIFACT_TYPE_PYTHON,
    ChannelDeclaration,
    find_channel,
)

from .manifest import ArtifactManifest


comptime ACTION_UPLOAD: Int = 0
comptime ACTION_SKIP: Int = 1
comptime ACTION_REFUSE: Int = 2


def action_name(action: Int) -> String:
    if action == ACTION_UPLOAD:
        return String("UPLOAD")
    if action == ACTION_SKIP:
        return String("SKIP")
    return String("REFUSE")


struct PublishTarget(Copyable, Movable, Deinitable):
    """One artifact, resolved to the repository it publishes to.

      artifact_type  CONDA or PYTHON (kci_release_channel's names).
      location       the repository's location, from the channels file.
      coordinate     where the file lands (kci_pkg_upload).
      sha256_hex     the manifest's sha256 of the file.
      file_path      the file to upload.
      metadata_path  PYTHON: the wheel's METADATA file; EMPTY otherwise.

    Layout: owned values only. No pointer field."""

    var artifact_type: String
    var location: String
    var coordinate: PackageCoordinate
    var sha256_hex: String
    var file_path: String
    var metadata_path: String

    def __init__(
        out self,
        var artifact_type: String,
        var location: String,
        var coordinate: PackageCoordinate,
        var sha256_hex: String,
        var file_path: String,
        var metadata_path: String,
    ):
        self.artifact_type = artifact_type^
        self.location = location^
        self.coordinate = coordinate^
        self.sha256_hex = sha256_hex^
        self.file_path = file_path^
        self.metadata_path = metadata_path^

    def where(self) -> String:
        """`<location>/<subdir>/<file>` (no subdir for PYTHON)."""
        var out = self.location + String("/")
        if self.coordinate.subdir.byte_length() > 0:
            out += self.coordinate.subdir + String("/")
        return out + self.coordinate.file_name


def substrate_of(artifact_type: String) raises -> Int:
    """The kci_pkg_upload substrate an artifact type publishes through."""
    if artifact_type == ARTIFACT_TYPE_CONDA:
        return SUBSTRATE_PREFIX_DEV_CONDA
    if artifact_type == ARTIFACT_TYPE_PYTHON:
        return SUBSTRATE_PUBLIC_PYPI
    raise Error(
        String("kci publish: artifact type '")
        + artifact_type
        + String("' has no publisher (CONDA or PYTHON)")
    )


def python_repo_of_location(location: String) raises -> String:
    """`https://<host>[/<path>]` as a coordinate's `repo`. RAISES unless the
    location is HTTPS with a host, no port and no trailing `/`."""
    var scheme = String("https://")
    if not location.startswith(scheme):
        raise Error(
            String("kci publish: python index location '")
            + location
            + String("' is not an https:// URL")
        )
    var repo = String(location[byte = scheme.byte_length() :])
    _ = repo_host(repo)
    _ = repo_path(repo)
    return repo^


def target_of(channel: ChannelDeclaration, m: ArtifactManifest) raises -> PublishTarget:
    """Resolve one manifest against the channel (step 1 of the header).
    RAISES naming the manifest."""
    var repository = channel.repository_for(m.artifact_type)
    var substrate = substrate_of(m.artifact_type)
    var repo: String
    if substrate == SUBSTRATE_PREFIX_DEV_CONDA:
        repo = prefix_dev_repo_of_location(repository.location)
    else:
        repo = python_repo_of_location(repository.location)
    var c = PackageCoordinate(
        substrate,
        repo^,
        m.name.copy(),
        m.version.copy(),
        m.subdir.copy(),
        m.file_name(),
    )
    if substrate == SUBSTRATE_PREFIX_DEV_CONDA:
        if not c.file_name.endswith(String(".conda")):
            raise Error(
                String("kci publish: '")
                + c.file_name
                + String("' is not a .conda file; only .conda is published")
            )
        refuse_malformed_conda_coordinate(c)
        refuse_name_not_the_files(c)
    else:
        var w = parse_wheel_name(c.file_name)
        if (
            normalize_distribution_name(w.distribution)
            != normalize_distribution_name(m.name)
            or w.version != m.version
        ):
            raise Error(
                String("kci publish: wheel '")
                + c.file_name
                + String("' is not ")
                + m.name
                + String(" ")
                + m.version
            )
    return PublishTarget(
        m.artifact_type.copy(),
        repository.location.copy(),
        c^,
        m.sha256_hex.copy(),
        m.file_path.copy(),
        m.metadata_path.copy(),
    )


def resolve_targets(
    decls: List[ChannelDeclaration],
    channel_name: String,
    manifests: List[ArtifactManifest],
) raises -> List[PublishTarget]:
    """Step 1 for every manifest. RAISES once, listing every refusal, so a
    run with three bad manifests names all three."""
    var channel = find_channel(decls, channel_name)
    var out = List[PublishTarget]()
    var refusals = List[String]()
    for i in range(len(manifests)):
        try:
            out.append(target_of(channel, manifests[i]))
        except e:
            refusals.append(
                manifests[i].source + String(": ") + String(e)
            )
    for i in range(len(out)):
        for j in range(i):
            if (
                out[j].location == out[i].location
                and out[j].coordinate.subdir == out[i].coordinate.subdir
                and out[j].coordinate.file_name == out[i].coordinate.file_name
            ):
                refusals.append(
                    String("'")
                    + out[i].where()
                    + String("' is listed by two manifests")
                )
    if len(refusals) > 0:
        raise Error(
            String("kci publish: refused before any upload:\n  ")
            + String("\n  ").join(refusals)
        )
    return out^


def refuse_file_bytes(t: PublishTarget, data: Span[UInt8, _]) raises:
    """RAISE unless `data` hashes to the manifest's sha256."""
    var id = content_identity_of(data)
    if id.sha256_hex != t.sha256_hex:
        raise Error(
            String("'")
            + t.file_path
            + String("' has sha256 ")
            + id.sha256_hex
            + String(", its manifest says ")
            + t.sha256_hex
        )


def verify_target_files(targets: List[PublishTarget]) raises:
    """Step 2: read every file and compare its sha256 with its manifest's.
    RAISES once, listing every file that is unreadable or different."""
    var refusals = List[String]()
    for i in range(len(targets)):
        try:
            var data = Path(targets[i].file_path).read_bytes()
            refuse_file_bytes(targets[i], Span(data))
        except e:
            refusals.append(String(e))
    if len(refusals) > 0:
        raise Error(
            String("kci publish: refused before any upload:\n  ")
            + String("\n  ").join(refusals)
        )


def refuse_unapproved_names(targets: List[PublishTarget], names: ApprovedNames) raises:
    """Step 3: RAISE, naming every unapproved name once, unless every
    target's name is approved for its substrate."""
    var unapproved = List[String]()
    for i in range(len(targets)):
        ref c = targets[i].coordinate
        if names.is_approved(c.distribution, c.substrate):
            continue
        var seen = False
        for j in range(len(unapproved)):
            if unapproved[j] == c.distribution:
                seen = True
        if not seen:
            unapproved.append(c.distribution.copy())
    if len(unapproved) > 0:
        raise Error(
            String("kci publish: refused before any upload: not in the")
            + String(" approved-names list (")
            + String(names.count())
            + String(" approved): ")
            + String(", ").join(unapproved)
            + String(". A published name is claimed for good, so it is")
            + String(" approved first, never published first")
        )


struct PlannedArtifact(Copyable, Movable, Deinitable):
    """One artifact's planned action. `reason` says why for SKIP and REFUSE;
    `cannot_tell` marks a REFUSE whose cause is an unanswered read (UNKNOWN,
    AUTH_REFUSED, RATE_LIMITED), not a definite conflict.

    Layout: owned values only. No pointer field."""

    var target: PublishTarget
    var action: Int
    var reason: String
    var cannot_tell: Bool

    def __init__(
        out self,
        var target: PublishTarget,
        action: Int,
        var reason: String,
        cannot_tell: Bool,
    ):
        self.target = target^
        self.action = action
        self.reason = reason^
        self.cannot_tell = cannot_tell


struct PublishPlan(Copyable, Movable, Deinitable):
    """The whole run's plan: the channel and one entry per artifact, in
    manifest order.

    Layout: owned values only. No pointer field."""

    var channel: String
    var visibility: String
    var entries: List[PlannedArtifact]

    def __init__(out self, var channel: String, var visibility: String):
        self.channel = channel^
        self.visibility = visibility^
        self.entries = List[PlannedArtifact]()

    def count(self, action: Int) -> Int:
        var n = 0
        for i in range(len(self.entries)):
            if self.entries[i].action == action:
                n += 1
        return n

    def has_definite_refusal(self) -> Bool:
        for i in range(len(self.entries)):
            ref e = self.entries[i]
            if e.action == ACTION_REFUSE and not e.cannot_tell:
                return True
        return False


def plan_from_presence(
    channel: ChannelDeclaration,
    targets: List[PublishTarget],
    presences: List[Presence],
) raises -> PublishPlan:
    """Step 4 (pure). `presences[i]` is the registry's answer for
    `targets[i]`. RAISES only when the two lists differ in length."""
    if len(targets) != len(presences):
        raise Error(
            String("kci publish: ")
            + String(len(targets))
            + String(" targets but ")
            + String(len(presences))
            + String(" presence answers")
        )
    var plan = PublishPlan(channel.name.copy(), channel.visibility.copy())
    for i in range(len(targets)):
        ref p = presences[i]
        var action = ACTION_REFUSE
        var reason = String("")
        var cannot_tell = False
        if p.kind == PRESENCE_ABSENT:
            action = ACTION_UPLOAD
        elif p.kind == PRESENCE_PRESENT_IDENTICAL:
            action = ACTION_SKIP
            reason = String("already present, identical")
        else:
            cannot_tell = not (
                p.kind == PRESENCE_PRESENT_DIFFERENT
                or p.kind == PRESENCE_NO_COMMON_FIELD
            )
            reason = (
                String("the registry answers ")
                + presence_kind_name(p.kind)
                + String(" (HTTP ")
                + String(p.status)
                + String(")")
            )
            if p.detail.byte_length() > 0:
                reason += String(": ") + p.detail
        plan.entries.append(
            PlannedArtifact(targets[i].copy(), action, reason^, cannot_tell)
        )
    return plan^
