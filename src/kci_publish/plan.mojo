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
# `plan_from_state(targets, channel_read)` -- contract step 1's verdict, in
#   this order:
#   1. any file present with OTHER bytes (member or metapackage): STOP, exit 3,
#      naming every such file. Nothing is uploaded;
#   2. any file or name listing that could not be read: exit 5. A listing that
#      was not read never makes a name "new";
#   3. every file present and identical: nothing to do, NOOP, exit 0;
#   4. otherwise PROCEED: the members still absent are uploaded, then the
#      metapackage.
#
# NEW NAMES are reported, never refused. A set name is HELD when the channel
#   has any file of it: a listing (the set's subdir and `noarch`) names one, OR
#   one of the set's own files under that name read present-same /
#   present-different BY DOWNLOAD at step 1. The download counts because it is
#   the authoritative read: the repodata can lag an upload, and a re-run after
#   a partial publish must not report its own uploads as "new" just because
#   the index has not caught up. A set name that is not held is NEW
#   (`new_names`). Which names a release publishes is its artifacts
#   file's; the approver of the publishing stage reads the NEW NAMES report
#   before approving, and a dry run shows the same report.
#
# `superseding_files(targets, listed_files)` -- NEVER BACKWARD: every file
#   the channel lists (`<subdir>/<file>`, step 1's listings), of ANY name and
#   ANY version, whose build number (the digits after the build string's
#   last `_`, `h<8 hex>_<N>`; the build string is the file name's last
#   `-`-separated part) is HIGHER than the release's. The rule this holds:
#   a never-backward channel (prod) is only ever published from a push to
#   main, and N counts main's first-parent history, so a release whose N is
#   lower than ANY build the channel holds does not descend from what the
#   channel has. Across a version bump (a new compiler version re-versions
#   every package) and for a name the channel never listed, the release is
#   refused the same way. `run.mojo` refuses a run that would upload when
#   the stage never goes backward and this is not empty
#   (KCI-E-SUPERSEDED). An equal number is not higher (a re-run of the same
#   number publishes the same bytes, or NOOP); a build string without a
#   number after its last `_` is not read as one.
#
# `previous_build_number(targets, listed_files)` -- what a never-backward
#   publish CARRIES: the highest build number the channel lists, of any
#   name and version, that is LOWER than the release's; -1 when it lists
#   none. kci_cli reports the
#   commits between that build and this one (they rode in this release: the
#   runs that would have published them were replaced or skipped).
#
# `approved_names_for(targets)` -- the uploader's last gate
#   (`kci_pkg_upload.ApprovedNames`): every name of the declared set, so an
#   undeclared name cannot be uploaded even by a bug above this layer. Never
#   read from a file or a flag.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_pkg_upload import (
    SUBSTRATE_PREFIX_DEV_CONDA,
    ApprovedNames,
    PackageCoordinate,
        prefix_dev_repo_of_location,
)
from kci_pkg_upload.identity import ascii_lower
from kci_pkg_upload.prefix_dev_registry import (
    refuse_malformed_conda_coordinate,
    refuse_name_not_the_files,
)
from kci_release_channel import ARTIFACT_TYPE_CONDA, Channel
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
comptime VERDICT_ALREADY_PUBLISHED: Int = 4

comptime NOARCH_SUBDIR: String = "noarch"


struct PublishTarget(Copyable, Movable):
    """One member, resolved to where its file lands.

    Layout: owned values only. No pointer field."""

    var artifact: String
    var is_metapackage: Bool
    var coordinate: PackageCoordinate
    var sha256_hex: String
    var file_path: String
    var internal_requirements: Int

    def __init__(
        out self,
        var artifact: String,
        is_metapackage: Bool,
        var coordinate: PackageCoordinate,
        var sha256_hex: String,
        var file_path: String,
        internal_requirements: Int,
    ):
        self.artifact = artifact^
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
    """`plan_from_state`'s answer: a VERDICT_* and the lines naming why, and
    the set names new to the channel (`names_known` False when the channel
    was not read well enough to say: a CANNOT_TELL verdict).

    Layout: an Int, a Bool and owned lists. No pointer field."""

    var verdict: Int
    var lines: List[String]
    var names_known: Bool
    var new_names: List[String]

    def __init__(out self, verdict: Int):
        self.verdict = verdict
        self.lines = List[String]()
        self.names_known = False
        self.new_names = List[String]()


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
    channel: Channel, members: List[ReleaseMember]
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
            refusals.append(String("artifact '") + m.artifact + String("': ") + String(e))
            continue
        var t = PublishTarget(
            m.artifact.copy(),
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
            String("PUBLISH step: refused before any read:\n  ") + String("\n  ").join(refusals)
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


def plan_from_state(targets: List[PublishTarget], channel_read: ChannelRead) raises -> StepOneVerdict:
    """Step 1's verdict and the new names (see the file header). RAISES only
    when the states and the targets differ in number."""
    if len(channel_read.states) != len(targets):
        raise Error(
            String("PUBLISH step: ")
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
    if not channel_read.names_read:
        cannot.lines.append(
            String("CANNOT TELL which names the channel holds: ") + channel_read.names_detail
        )
    if len(cannot.lines) > 0 and len(different.lines) == 0:
        return cannot^
    var fresh = List[String]()
    var known = len(cannot.lines) == 0
    if known:
        fresh = new_names(targets, channel_read)
    var res: StepOneVerdict
    if len(different.lines) > 0:
        res = different^
    else:
        var all_same = True
        for i in range(len(channel_read.states)):
            if channel_read.states[i].kind != STATE_SAME:
                all_same = False
        if all_same:
            res = StepOneVerdict(VERDICT_ALREADY_PUBLISHED)
            res.lines.append(String("already published: every file is in the channel, identical"))
        else:
            res = StepOneVerdict(VERDICT_PROCEED)
    res.names_known = known
    for i in range(len(fresh)):
        res.lines.append(
            String("NEW NAME '") + fresh[i] + String("': the channel holds no file of it yet;")
            + String(" this release publishes it for the first time")
        )
    res.new_names = fresh^
    return res^


def approved_names_for(targets: List[PublishTarget]) raises -> ApprovedNames:
    """The names an upload may carry: every name of the declared set (see
    the file header)."""
    var names = ApprovedNames()
    var added = List[String]()
    for i in range(len(targets)):
        var n = ascii_lower(targets[i].coordinate.distribution)
        var seen = False
        for j in range(len(added)):
            if added[j] == n:
                seen = True
        if not seen:
            added.append(n.copy())
            names.approve(n^)
    return names^


def _build_number(build: String) -> Int:
    """The digits after the last `_` of a build string (`h<8 hex>_<N>`), or
    -1 when there are none (or they are not all digits)."""
    var at = build.rfind(String("_"))
    if at < 0:
        return -1
    var b = build.as_bytes()
    if at + 1 >= len(b) or len(b) - at - 1 > 9:
        return -1
    var n = 0
    for i in range(at + 1, len(b)):
        var c = Int(b[i])
        if c < 48 or c > 57:
            return -1
        n = n * 10 + (c - 48)
    return n


def _build_of(file_name: String, distribution: String, version: String) -> String:
    """The build string of `file_name` when it is
    `<distribution>-<version>-<build>.conda` with no `-` in the build; else
    ""."""
    var head = distribution + String("-") + version + String("-")
    var tail = String(".conda")
    if not file_name.startswith(head) or not file_name.endswith(tail):
        return String("")
    var n = file_name.byte_length()
    if n <= head.byte_length() + tail.byte_length():
        return String("")
    var build = String(file_name[byte = head.byte_length() : n - tail.byte_length()])
    if build.find(String("-")) >= 0:
        return String("")
    return build^


def _listed_build_number(listed: String) -> Int:
    """The build number of a listed `<subdir>/<name>-<version>-<build>.conda`
    (or `.tar.bz2`), whatever its name and version; -1 when it has none."""
    var at = listed.rfind(String("/"))
    var name = String(listed[byte = at + 1 :]) if at >= 0 else listed.copy()
    var stem: String
    if name.endswith(String(".conda")):
        stem = String(name[byte = 0 : name.byte_length() - String(".conda").byte_length()])
    elif name.endswith(String(".tar.bz2")):
        stem = String(name[byte = 0 : name.byte_length() - String(".tar.bz2").byte_length()])
    else:
        return -1
    var dash = stem.rfind(String("-"))
    if dash < 0:
        return -1
    return _build_number(String(stem[byte = dash + 1 :]))


def _release_build_number(targets: List[PublishTarget]) -> Int:
    """The release's build number: its targets', the first that has one."""
    for i in range(len(targets)):
        var n = build_number_of(targets[i])
        if n >= 0:
            return n
    return -1


def superseding_files(targets: List[PublishTarget], listed_files: List[String]) -> List[String]:
    """The file header's NEVER BACKWARD reading: one line per listed file
    that supersedes the release, naming both."""
    var out = List[String]()
    var ours = _release_build_number(targets)
    if ours < 0:
        return out^
    for k in range(len(listed_files)):
        ref f = listed_files[k]
        var theirs = _listed_build_number(f)
        if theirs > ours:
            out.append(
                String("SUPERSEDED ") + targets[0].where() + String(" (build number ") + String(ours)
                + String(") by ") + f + String(" (build number ") + String(theirs) + String(")")
            )
    return out^


def build_number_of(target: PublishTarget) -> Int:
    """The target's own build number (`h<8 hex>_<N>`), -1 when its build
    string has none."""
    ref c = target.coordinate
    return _build_number(_build_of(c.file_name, c.distribution, c.version))


def previous_build_number(targets: List[PublishTarget], listed_files: List[String]) -> Int:
    """The file header's `previous_build_number`."""
    var best = -1
    var ours = _release_build_number(targets)
    if ours < 0:
        return -1
    for k in range(len(listed_files)):
        var theirs = _listed_build_number(listed_files[k])
        if theirs >= 0 and theirs < ours and theirs > best:
            best = theirs
    return best
