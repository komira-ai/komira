# =============================================================================
# src/kci_publish/verify.mojo -- contract steps 0.3, 0.4 and 0.5: the set as a
#   whole, checked before any read from a channel. Pure over the verified
#   members; every function RAISES once, listing every refusal it found.
# =============================================================================
#
# `require_conda_only` -- this unit publishes conda packages only. A PYTHON
#   member (a wheel) is refused by name: wheels are a design note.
#
# `require_lockstep(members, rv)` (0.3) -- every member, the metapackage
#   included, carries ONE `version`, `build`, `build_number`,
#   `source_commit`, `timestamp_ms` and `subdir`; those equal the
#   `--release-version` file's `version`, `build`, `build_number` and
#   `commit`; and every member is `stamped`.
#
# `require_closure(members)` (0.4) -- with G the platform guard of the set's
#   subdir (`GUARD_BY_SUBDIR`; a subdir with no row is refused), V the set's
#   version and B its build:
#   * a LIBRARY's `depends` is exactly: G, `mojo-compiler ==V`, and
#     `<n> ==V B` for set libraries `n` (each at most once, never itself),
#     and any of the conda-forge requirements of the system libraries a
#     library may open (kci_release_set's `is_system_lib_requirement`, held
#     to tools/build/package/system_libs.bzl: `zstd >=1.5.2,<2`), byte-equal,
#     each at most once. Anything else (an outside package, another version
#     or build, a pin on the metapackage, a system library at another range,
#     in another case or behind a `<channel>::` prefix) is refused naming
#     the entry;
#   * the set holds EXACTLY ONE metapackage, and its `members` are exactly
#     every library of the set: each row a set library at V and B whose
#     `sha256` equals that library's manifest sha256 (the bytes being
#     published), no row twice, no row a metapackage. Its `depends` is
#     exactly G plus `<m> ==V B` for every row.
#   "Exactly one metapackage, whose members are every library" is the rule
#   the design recommends for its open question Q2 (the artifacts no
#   longer say which artifacts are members). Until that question is settled
#   the rule is the strict one, which is the safe direction.
#
# The set hash (0.5) has no check here: `load_release` refuses a
#   `release.json` whose set hash is not what the member directories
#   recompute to, and the result records the recomputed one. There is no
#   approved-hash input to compare it with: what a release publishes is its
#   artifacts file's.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_release_channel import ARTIFACT_TYPE_CONDA
from kci_release_set.conda_metadata import KIND_LIBRARY, KIND_METAPACKAGE
from kci_release_set.closure import MOJO_COMPILER_PACKAGE
from kci_release_set.member import ReleaseMember
from kci_release_set.system_libs import is_system_lib_requirement

from .inputs import LoadedRelease
from .release_version import ReleaseVersion


def guard_for_subdir(subdir: String) -> String:
    """The platform guard requirement a package of `subdir` carries; EMPTY
    for a subdir this table has no row for (refused by `require_closure`).
    THE table: one row per subdir the packer writes."""
    if subdir == String("linux-64"):
        return String("__linux")
    return String("")


def _refuse(what: String, refusals: List[String]) raises:
    raise Error(
        String("PUBLISH step: ")
        + what
        + String(" refused:\n  ")
        + String("\n  ").join(refusals)
    )


def require_conda_only(members: List[ReleaseMember]) raises:
    var refusals = List[String]()
    for i in range(len(members)):
        if members[i].manifest.artifact_type != ARTIFACT_TYPE_CONDA:
            refusals.append(
                String("artifact '")
                + members[i].artifact
                + String("' is ")
                + members[i].manifest.artifact_type
                + String("; a PUBLISH step publishes CONDA packages only")
            )
    if len(refusals) > 0:
        _refuse(String("the release set is"), refusals)


def _differs(
    mut refusals: List[String],
    key: String,
    m: ReleaseMember,
    value: String,
    want: String,
    against: String,
):
    if value != want:
        refusals.append(
            String("artifact '")
            + m.artifact
            + String("': ")
            + key
            + String(" is '")
            + value
            + String("', ")
            + against
            + String(" '")
            + want
            + String("'")
        )


def require_lockstep(members: List[ReleaseMember], rv: ReleaseVersion) raises:
    """Contract 0.3 (see the file header). Expects CONDA members."""
    var refusals = List[String]()
    if len(members) == 0:
        refusals.append(String("the release set has no member"))
        _refuse(String("lockstep"), refusals)
    ref first = members[0].conda
    var the_set = String("the set's first member '") + members[0].artifact + String("' has")
    var the_file = String("--release-version (") + rv.source + String(") says")
    for i in range(len(members)):
        ref m = members[i]
        ref c = m.conda
        _differs(refusals, String("version"), m, c.version, first.version, the_set)
        _differs(refusals, String("build"), m, c.build, first.build, the_set)
        _differs(refusals, String("build_number"), m, String(c.build_number), String(first.build_number), the_set)
        _differs(refusals, String("source_commit"), m, c.source_commit, first.source_commit, the_set)
        _differs(refusals, String("timestamp_ms"), m, String(c.timestamp_ms), String(first.timestamp_ms), the_set)
        _differs(refusals, String("subdir"), m, c.subdir, first.subdir, the_set)
        _differs(refusals, String("version"), m, c.version, rv.version, the_file)
        _differs(refusals, String("build"), m, c.build, rv.build, the_file)
        _differs(refusals, String("build_number"), m, String(c.build_number), String(rv.build_number), the_file)
        _differs(refusals, String("source_commit"), m, c.source_commit, rv.commit, the_file)
        if not c.stamped:
            refusals.append(
                String("artifact '")
                + m.artifact
                + String("' is not stamped: an unstamped package never ships")
            )
    if len(refusals) > 0:
        _refuse(String("lockstep"), refusals)


def _pin(name: String, version: String, build: String) -> String:
    return name + String(" ==") + version + String(" ") + build


def _library_index(members: List[ReleaseMember], name: String) -> Int:
    for i in range(len(members)):
        if members[i].conda.kind == KIND_LIBRARY and members[i].conda.name == name:
            return i
    return -1


def _count(items: List[String], x: String) -> Int:
    var n = 0
    for i in range(len(items)):
        if items[i] == x:
            n += 1
    return n


def require_closure(members: List[ReleaseMember]) raises:
    """Contract 0.4 (see the file header). Expects CONDA members in
    lockstep (call `require_lockstep` first)."""
    var refusals = List[String]()
    if len(members) == 0:
        refusals.append(String("the release set has no member"))
        _refuse(String("requirement closure"), refusals)
    var subdir = members[0].conda.subdir.copy()
    var version = members[0].conda.version.copy()
    var build = members[0].conda.build.copy()
    var guard = guard_for_subdir(subdir)
    if guard.byte_length() == 0:
        refusals.append(
            String("subdir '") + subdir + String("' has no platform guard in the PUBLISH step's table")
        )
        _refuse(String("requirement closure"), refusals)
    var compiler_pin = String(MOJO_COMPILER_PACKAGE) + String(" ==") + version
    var metas = List[Int]()
    for i in range(len(members)):
        ref c = members[i].conda
        var who = String("artifact '") + members[i].artifact + String("': ")
        if c.kind == KIND_METAPACKAGE:
            metas.append(i)
            continue
        for d in range(len(c.depends)):
            var dep = c.depends[d].copy()
            if _count(c.depends, dep) > 1:
                refusals.append(who + String("requirement '") + dep + String("' is listed twice"))
                continue
            if dep == guard or dep == compiler_pin:
                continue
            if is_system_lib_requirement(dep):
                continue
            var sp = dep.find(String(" =="))
            var ok = False
            if sp > 0:
                var n = String(dep[byte=:sp])
                var j = _library_index(members, n)
                if j >= 0 and j != i and dep == _pin(n, version, build):
                    ok = True
            if not ok:
                refusals.append(
                    who
                    + String("requirement '")
                    + dep
                    + String("' is not the guard '")
                    + guard
                    + String("', '")
                    + compiler_pin
                    + String("', another library of this set at '==")
                    + version
                    + String(" ")
                    + build
                    + String("', or a system library requirement of tools/build/package/system_libs.bzl")
                )
        if _count(c.depends, guard) != 1:
            refusals.append(who + String("does not require the platform guard '") + guard + String("'"))
        if _count(c.depends, compiler_pin) != 1:
            refusals.append(who + String("does not require exactly '") + compiler_pin + String("'"))
    if len(metas) != 1:
        refusals.append(
            String("the release set holds ")
            + String(len(metas))
            + String(" metapackages; it must hold exactly one, whose members are every library")
        )
        _refuse(String("requirement closure"), refusals)
    ref meta_m = members[metas[0]]
    ref meta = meta_m.conda
    var who = String("metapackage '") + meta_m.artifact + String("': ")
    var want = List[String]()
    want.append(guard.copy())
    var rows_seen = List[String]()
    for r in range(len(meta.members)):
        ref row = meta.members[r]
        if _count(rows_seen, row.name) > 0:
            refusals.append(who + String("member '") + row.name + String("' is listed twice"))
            continue
        rows_seen.append(row.name.copy())
        var j = _library_index(members, row.name)
        if j < 0:
            refusals.append(
                who + String("member '") + row.name + String("' is not a library of this set")
            )
            continue
        if row.version != version or not row.has_build or row.build != build:
            refusals.append(
                who
                + String("member '")
                + row.name
                + String("' is at '")
                + row.version
                + String(" ")
                + row.build
                + String("', the set is at '")
                + version
                + String(" ")
                + build
                + String("'")
            )
        if row.sha256_hex != members[j].manifest.sha256_hex:
            refusals.append(
                who
                + String("member '")
                + row.name
                + String("' has sha256 ")
                + row.sha256_hex
                + String(", the set's file has ")
                + members[j].manifest.sha256_hex
            )
        want.append(_pin(row.name, version, build))
    for i in range(len(members)):
        if members[i].conda.kind == KIND_LIBRARY and _count(rows_seen, members[i].conda.name) == 0:
            refusals.append(
                who
                + String("library '")
                + members[i].conda.name
                + String("' of this set is not a member: the metapackage would not install it")
            )
    for d in range(len(meta.depends)):
        if _count(want, meta.depends[d]) == 0:
            refusals.append(
                who + String("requirement '") + meta.depends[d] + String("' is not the guard or a member pin")
            )
    for w in range(len(want)):
        if _count(meta.depends, want[w]) != 1:
            refusals.append(
                who + String("does not require '") + want[w] + String("' exactly once")
            )
    if len(refusals) > 0:
        _refuse(String("requirement closure"), refusals)
