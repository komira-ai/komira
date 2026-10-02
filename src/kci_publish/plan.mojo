# =============================================================================
# src/kci_publish/plan.mojo -- the verified set resolved to where each file
#   lands, and what step 1's channel read means for the run. Pure.
# =============================================================================
#
# `resolve_targets(channel, members)` -- each member to its coordinate on the
#   channel's CONDA repository (`kci_release_channel`; a channel declaring
#   none is refused naming it). The file must be `.conda` and be
#   `<name>-<version>-<build>.conda` of its metadata. Order: libraries first,
#   by how many set-internal requirements each has (fewer first; a stable
#   sort key, never a correctness rule), the metapackage LAST.
#
# `plan_from_state(targets, channel_read, claims)` -- contract step 1's verdict, in
#   this order:
#   1. any file present with OTHER bytes (member or metapackage): STOP, exit 7,
#      naming every such file. Nothing is uploaded;
#   2. any file or name listing that could not be read: exit 5. A listing that
#      was not read never makes a name "new";
#   3. NEW NAMES. A set name is HELD when the channel has any file of it:
#      a listing (the set's subdir and `noarch`) names one, OR one of the
#      set's own files under that name read present-same / present-different
#      BY DOWNLOAD at step 1. The download counts because it is the
#      authoritative read: the repodata can lag an upload, and a re-run after
#      a partial publish must not see its own uploads as "new" just because
#      the index has not caught up. A set name that is not held is NEW, a
#      claim, and needs `--claim-new-name`; an unclaimed new name is STOP,
#      exit 8. A claim for a name not in the set is STOP, exit 8. A claim for
#      a HELD name is SATISFIED when everything the channel holds under it is
#      this set's own files, each read present-same (the claim was made by an
#      earlier run of this same release, which then stopped or finished), so
#      re-running the same command is stable whatever the index shows; a
#      claim for a name held by any OTHER file is STOP, exit 8 (it is not
#      new);
#   4. every file present and identical: nothing to do, exit 6;
#   5. otherwise PROCEED: the members still absent are uploaded, then the
#      metapackage.
#
# `approved_names_for(targets, channel_read, claims)` -- the uploader's last gate
#   (`kci_pkg_upload.ApprovedNames`), built from the set names the channel
#   already holds (the same HELD rule) plus the claims. Never read from a
#   file.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_pkg_upload import (
    SUBSTRATE_PREFIX_DEV_CONDA,
    ApprovedNames,
    PackageCoordinate,
    conda_package_name_of_file,
    prefix_dev_repo_of_location,
)
from kci_pkg_upload.identity import ascii_lower
from kci_pkg_upload.prefix_dev_registry import (
    refuse_malformed_conda_coordinate,
    refuse_name_not_the_files,
)
from kci_release_channel import ARTIFACT_TYPE_CONDA, ChannelDeclaration
from kci_release_set.conda_metadata import KIND_METAPACKAGE
from kci_release_set.member import ReleaseMember


comptime STATE_ABSENT: Int = 0
comptime STATE_SAME: Int = 1
comptime STATE_DIFFERENT: Int = 2
comptime STATE_CANNOT_TELL: Int = 3
comptime STATE_NOT_READ: Int = 4


def state_name(kind: Int) -> String:
    if kind == STATE_ABSENT:
        return String("absent")
    if kind == STATE_SAME:
        return String("present-same")
    if kind == STATE_DIFFERENT:
        return String("present-different")
    if kind == STATE_CANNOT_TELL:
        return String("cannot-tell")
    return String("not-read")


comptime VERDICT_PROCEED: Int = 0
comptime VERDICT_STOP_DIFFERENT: Int = 1
comptime VERDICT_CANNOT_TELL: Int = 2
comptime VERDICT_STOP_NEW_NAME: Int = 3
comptime VERDICT_ALREADY_PUBLISHED: Int = 4

comptime NOARCH_SUBDIR: String = "noarch"


struct PublishTarget(Copyable, Movable):
    """One member, resolved to where its file lands.

    Layout: owned values only. No pointer field."""

    var declaration: String
    var is_metapackage: Bool
    var coordinate: PackageCoordinate
    var sha256_hex: String
    var file_path: String
    var internal_requirements: Int

    def __init__(
        out self,
        var declaration: String,
        is_metapackage: Bool,
        var coordinate: PackageCoordinate,
        var sha256_hex: String,
        var file_path: String,
        internal_requirements: Int,
    ):
        self.declaration = declaration^
        self.is_metapackage = is_metapackage
        self.coordinate = coordinate^
        self.sha256_hex = sha256_hex^
        self.file_path = file_path^
        self.internal_requirements = internal_requirements

    def where(self) -> String:
        return self.coordinate.subdir + String("/") + self.coordinate.file_name


struct FileState(Copyable, Movable):
    """What the channel holds under one file name. Layout: an Int and an
    owned String. No pointer field."""

    var kind: Int
    var detail: String

    def __init__(out self, kind: Int, var detail: String):
        self.kind = kind
        self.detail = detail^


struct ChannelRead(Copyable, Movable):
    """Step 1's reads: one state per target (same order), the package names
    the listed subdirs hold (lowercase) and every file they list
    (`<subdir>/<file>`). `names_read` False means some listing was not read;
    `names_detail` says which, and `names` and `listed_files` are then empty
    and mean nothing.

    Layout: owned values only. No pointer field."""

    var states: List[FileState]
    var names_read: Bool
    var names: List[String]
    var listed_files: List[String]
    var names_detail: String

    def __init__(out self):
        self.states = List[FileState]()
        self.names_read = True
        self.names = List[String]()
        self.listed_files = List[String]()
        self.names_detail = String("")

    def holds_name(self, name: String) -> Bool:
        var want = ascii_lower(name)
        for i in range(len(self.names)):
            if self.names[i] == want:
                return True
        return False


struct StepOneVerdict(Copyable, Movable):
    """`plan_from_state`'s answer: a VERDICT_* and the lines naming why.

    Layout: an Int and an owned list. No pointer field."""

    var verdict: Int
    var lines: List[String]

    def __init__(out self, verdict: Int):
        self.verdict = verdict
        self.lines = List[String]()


def _internal_count(m: ReleaseMember, members: List[ReleaseMember]) -> Int:
    var n = 0
    for d in range(len(m.conda.depends)):
        for j in range(len(members)):
            if members[j].conda.name.byte_length() > 0 and m.conda.depends[d].startswith(
                members[j].conda.name + String(" ==")
            ):
                n += 1
    return n


def resolve_targets(
    channel: ChannelDeclaration, members: List[ReleaseMember]
) raises -> List[PublishTarget]:
    """See the file header. RAISES once, listing every refusal."""
    var repository = channel.repository_for(String(ARTIFACT_TYPE_CONDA))
    var repo = prefix_dev_repo_of_location(repository.location)
    var libs = List[PublishTarget]()
    var metas = List[PublishTarget]()
    var refusals = List[String]()
    for i in range(len(members)):
        ref m = members[i]
        var c = PackageCoordinate(
            SUBSTRATE_PREFIX_DEV_CONDA,
            repo.copy(),
            m.conda.name.copy(),
            m.conda.version.copy(),
            m.conda.subdir.copy(),
            m.manifest.file.copy(),
        )
        try:
            if not c.file_name.endswith(String(".conda")):
                raise Error(String("'") + c.file_name + String("' is not a .conda file"))
            refuse_malformed_conda_coordinate(c)
            refuse_name_not_the_files(c)
        except e:
            refusals.append(String("artifact '") + m.declaration + String("': ") + String(e))
            continue
        var t = PublishTarget(
            m.declaration.copy(),
            m.conda.kind == KIND_METAPACKAGE,
            c^,
            m.manifest.sha256_hex.copy(),
            m.manifest.file_path.copy(),
            _internal_count(m, members),
        )
        if t.is_metapackage:
            metas.append(t^)
        else:
            var at = len(libs)
            for k in range(len(libs)):
                if t.internal_requirements < libs[k].internal_requirements:
                    at = k
                    break
            libs.insert(at, t^)
    if len(refusals) > 0:
        raise Error(
            String("kci publish: refused before any read:\n  ") + String("\n  ").join(refusals)
        )
    for i in range(len(metas)):
        libs.append(metas[i].copy())
    return libs^


def listed_subdirs(targets: List[PublishTarget]) -> List[String]:
    """The subdirs whose listings say which names exist: the set's, then
    `noarch`, each once."""
    var out = List[String]()
    for i in range(len(targets)):
        var s = targets[i].coordinate.subdir.copy()
        var seen = False
        for j in range(len(out)):
            if out[j] == s:
                seen = True
        if not seen:
            out.append(s^)
    var has_noarch = False
    for j in range(len(out)):
        if out[j] == String(NOARCH_SUBDIR):
            has_noarch = True
    if not has_noarch:
        out.append(String(NOARCH_SUBDIR))
    return out^


def is_held(targets: List[PublishTarget], channel_read: ChannelRead, name: String) -> Bool:
    """Whether the channel has any file of `name` (see the file header): a
    listing names it, or one of the set's files under it read present by
    download at step 1."""
    if channel_read.holds_name(name):
        return True
    var want = ascii_lower(name)
    for i in range(len(targets)):
        if ascii_lower(targets[i].coordinate.distribution) != want:
            continue
        var k = channel_read.states[i].kind
        if k == STATE_SAME or k == STATE_DIFFERENT:
            return True
    return False


def holds_only_ours(targets: List[PublishTarget], channel_read: ChannelRead, name: String) -> Bool:
    """Whether everything the channel holds under `name` is this set's own
    files, each read present-same by download: every listed file of `name`
    is one of the set's files, and every set file of `name` is present-same.
    """
    var want = ascii_lower(name)
    var ours = List[String]()
    for i in range(len(targets)):
        if ascii_lower(targets[i].coordinate.distribution) != want:
            continue
        if channel_read.states[i].kind != STATE_SAME:
            return False
        ours.append(targets[i].where())
    if len(ours) == 0:
        return False
    for f in range(len(channel_read.listed_files)):
        ref p = channel_read.listed_files[f]
        var slash = p.rfind(String("/"))
        var file = String(p[byte = slash + 1 :]) if slash >= 0 else p.copy()
        if conda_package_name_of_file(file) != want:
            continue
        var mine = False
        for k in range(len(ours)):
            if ours[k] == p:
                mine = True
        if not mine:
            return False
    return True


def new_names(targets: List[PublishTarget], channel_read: ChannelRead) -> List[String]:
    """The set names the channel holds no file of, by listing or by download
    (lowercase, each once). Meaningful only when `read.names_read`."""
    var out = List[String]()
    for i in range(len(targets)):
        var n = ascii_lower(targets[i].coordinate.distribution)
        if is_held(targets, channel_read, n):
            continue
        var seen = False
        for j in range(len(out)):
            if out[j] == n:
                seen = True
        if not seen:
            out.append(n^)
    return out^


def _in_set(targets: List[PublishTarget], name: String) -> Bool:
    var want = ascii_lower(name)
    for i in range(len(targets)):
        if ascii_lower(targets[i].coordinate.distribution) == want:
            return True
    return False


def plan_from_state(
    targets: List[PublishTarget], channel_read: ChannelRead, claims: List[String]
) raises -> StepOneVerdict:
    """Step 1's verdict (see the file header). RAISES only when the states
    and the targets differ in number."""
    if len(channel_read.states) != len(targets):
        raise Error(
            String("kci publish: ")
            + String(len(targets))
            + String(" targets but ")
            + String(len(channel_read.states))
            + String(" channel states")
        )
    var different = StepOneVerdict(VERDICT_STOP_DIFFERENT)
    var cannot = StepOneVerdict(VERDICT_CANNOT_TELL)
    for i in range(len(targets)):
        ref s = channel_read.states[i]
        if s.kind == STATE_DIFFERENT:
            different.lines.append(
                String("STOP different bytes: ")
                + targets[i].where()
                + String(" is in the channel with other bytes than ours (sha256 ")
                + targets[i].sha256_hex
                + String(")")
            )
        elif s.kind != STATE_ABSENT and s.kind != STATE_SAME:
            cannot.lines.append(
                String("CANNOT TELL ") + targets[i].where() + String(": ") + s.detail
            )
    if len(different.lines) > 0:
        return different^
    if not channel_read.names_read:
        cannot.lines.append(
            String("CANNOT TELL which names the channel holds: ") + channel_read.names_detail
        )
    if len(cannot.lines) > 0:
        return cannot^
    var stop = StepOneVerdict(VERDICT_STOP_NEW_NAME)
    var satisfied = List[String]()
    var fresh = new_names(targets, channel_read)
    for i in range(len(fresh)):
        var claimed = False
        for j in range(len(claims)):
            if ascii_lower(claims[j]) == fresh[i]:
                claimed = True
        if not claimed:
            stop.lines.append(
                String("STOP new name: '")
                + fresh[i]
                + String("' has no file in the channel. Publishing it claims the name for")
                + String(" good; pass --claim-new-name ")
                + fresh[i]
                + String(" if that is intended")
            )
    for j in range(len(claims)):
        if not _in_set(targets, claims[j]):
            stop.lines.append(
                String("STOP claim: --claim-new-name '")
                + claims[j]
                + String("' is not a package of this release set")
            )
        elif is_held(targets, channel_read, claims[j]):
            if holds_only_ours(targets, channel_read, claims[j]):
                satisfied.append(
                    String("CLAIM --claim-new-name '")
                    + claims[j]
                    + String("' is satisfied: the channel holds only this release's own file(s)")
                    + String(" of it, identical (an earlier run of this release claimed it)")
                )
            else:
                stop.lines.append(
                    String("STOP claim: --claim-new-name '")
                    + claims[j]
                    + String("' is already in the channel; it is not new")
                )
    if len(stop.lines) > 0:
        return stop^
    var all_same = True
    for i in range(len(channel_read.states)):
        if channel_read.states[i].kind != STATE_SAME:
            all_same = False
    if all_same:
        var done = StepOneVerdict(VERDICT_ALREADY_PUBLISHED)
        for k in range(len(satisfied)):
            done.lines.append(satisfied[k].copy())
        done.lines.append(String("already published: every file is in the channel, identical"))
        return done^
    var go = StepOneVerdict(VERDICT_PROCEED)
    for k in range(len(satisfied)):
        go.lines.append(satisfied[k].copy())
    return go^


def approved_names_for(
    targets: List[PublishTarget], channel_read: ChannelRead, claims: List[String]
) raises -> ApprovedNames:
    """The names an upload may claim: set names the channel already holds,
    plus the claims (see the file header)."""
    var names = ApprovedNames()
    var added = List[String]()
    for i in range(len(targets)):
        var n = ascii_lower(targets[i].coordinate.distribution)
        if not is_held(targets, channel_read, n):
            continue
        var seen = False
        for j in range(len(added)):
            if added[j] == n:
                seen = True
        if not seen:
            added.append(n.copy())
            names.approve(n^)
    for j in range(len(claims)):
        var n = ascii_lower(claims[j])
        var seen = False
        for k in range(len(added)):
            if added[k] == n:
                seen = True
        if not seen:
            added.append(n.copy())
            names.approve(n^)
    return names^
