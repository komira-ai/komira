# =============================================================================
# kci_artifact_declaration/contract.mojo -- the words of the build contract
#   kci holds every build system to: the placeholders, the stamp, the order,
#   and the one substitution it performs.
# =============================================================================
#
# For each artifact kci creates an EMPTY output directory and runs
#
#   <executable> <build_system.args...> <artifact.args...>
#
# with every placeholder in any arg replaced by its value (below). ONE
# ARTIFACT PER DECLARATION: the build leaves, at the top of that directory, EXACTLY ONE kci artifact manifest (//src/kci_artifact_manifest's
# format) named `KCI_MANIFEST_NAME` (`manifest.json`), plus the files it
# names. That is the layout of a `conda_package`'s `[release]` directory
# (`<name>-<version>-0.conda`, `manifest.json`, `metadata.json`). kci ships
# exactly what that manifest describes. Refused: a non-zero exit;
# `require_one_manifest`: no `manifest.json` at the top, or a listing naming
# it more than once (a directory cannot hold two, so that arm guards a
# listing that is not one directory's top level); `require_manifest_name`:
# a manifest whose `name` is not the declaration's, compared EXACTLY (byte
# for byte; no case folding, no trimming, no `-`/`_` equivalence).
#
# A placeholder is `{<identifier>}`, the identifier `[A-Za-z_][A-Za-z0-9_]*`.
# The seven, every one a value kci knows before the build starts:
#
#   {out_dir}        this artifact's output directory, `{release_dir}/<name>`
#                    (absolute, EMPTY when the build starts)
#   {release_dir}    this platform's release directory (absolute),
#                    `<--release-dir>/<platform>` (kci_api's layout): it
#                    holds the output directory of every artifact declared
#                    ABOVE this one, each named by its declaration name and
#                    already verified, and nothing else that a declaration
#                    names. The same declaration text serves every platform
#   {platform}       the platform the release is built for, a name from
#                    kci_api's platform table (`linux-x86_64`)
#   {revision_id}    the release commit (`kci run --revision-id`): the full
#                    40-hex id of the commit checked out in the work dir
#   {source_commit}  the stamp's commit: the newest first-parent commit at
#                    or below the release commit that touches anything but
#                    documentation (`tools/build/package/release_version.sh`'s
#                    `commit=`; equal to {revision_id} unless the newest
#                    commits only change documentation)
#   {build_number}   the release iteration: the first-parent commit count of
#                    {source_commit}, a positive decimal
#   {timestamp_ms}   {source_commit}'s commit time in milliseconds, a
#                    positive decimal
#
# The last four are the STAMP: git-derived by kci, never typed and never
# read from the environment, so a declaration passes them to the build as
# plain args (buck2: `-c komira.package_stamp={build_number}`). Any other
# `{<identifier>}` is refused by the validator; a brace that does not
# enclose an identifier (`{}`, `{"k": 1}`) is literal text and passed
# through unchanged. Substitution is ONE pass over the arg as written, so a
# value that itself holds `{...}` (a directory named `{out_dir}`) is never
# substituted again. There is no escape: an arg cannot carry a literal
# placeholder.
#
# ORDER. kci builds the artifacts one at a time in declarations-file order,
# each only after the one above it built and was verified. That is what makes
# `{release_dir}` useful: a later declaration (a metapackage) reads the
# manifests of the earlier ones, e.g. `{release_dir}/komira_encoding/
# manifest.json`.
#
# ONE METAPACKAGE (a recommendation; the CEO has not answered it): a set holds
# exactly one metapackage per subdir, declared LAST, whose members are every
# library of the set. The BUILD step places it last by file order; the PUBLISH step
# refuses a set with zero or two metapackages, or one whose members are not
# every library.
#
# Pure functions over owned values; no pointer, no process.
# =============================================================================

from kci_api import ARTIFACT_MANIFEST_NAME, require_full_commit_id

comptime OUT_DIR_PLACEHOLDER: String = "{out_dir}"
"""This artifact's output directory, `{release_dir}/<name>`."""

comptime RELEASE_DIR_PLACEHOLDER: String = "{release_dir}"
"""This platform's release directory, `<--release-dir>/<platform>`: every
artifact declared above, already built."""

comptime PLATFORM_PLACEHOLDER: String = "{platform}"
"""The release's platform (kci_api's platform table)."""

comptime REVISION_ID_PLACEHOLDER: String = "{revision_id}"
"""The release commit, full 40 hex (`kci run --revision-id`)."""

comptime SOURCE_COMMIT_PLACEHOLDER: String = "{source_commit}"
"""The stamp's commit, full 40 hex (the newest non-documentation commit)."""

comptime BUILD_NUMBER_PLACEHOLDER: String = "{build_number}"
"""The release iteration: the first-parent commit count of the stamp's commit."""

comptime TIMESTAMP_MS_PLACEHOLDER: String = "{timestamp_ms}"
"""The stamp's commit time in milliseconds."""

comptime KCI_MANIFEST_NAME: String = ARTIFACT_MANIFEST_NAME
"""The one kci artifact manifest a build leaves at the top of `{out_dir}`
(kci_api's `ARTIFACT_MANIFEST_NAME`; this name stays for callers)."""


def _ident_start(c: Int) -> Bool:
    return (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95


def _ident(c: Int) -> Bool:
    return _ident_start(c) or (c >= 48 and c <= 57)


def placeholders_in(arg: String) -> List[String]:
    """Every `{<identifier>}` in `arg`, braces included, in order."""
    var out = List[String]()
    var b = arg.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        var end = _placeholder_end(arg, i)
        if end < 0:
            i += 1
            continue
        out.append(String(arg[byte = i:end]))
        i = end
    return out^


def known_placeholders() -> List[String]:
    """The seven placeholders, in the order of this file's header."""
    var out = List[String]()
    out.append(String(OUT_DIR_PLACEHOLDER))
    out.append(String(RELEASE_DIR_PLACEHOLDER))
    out.append(String(PLATFORM_PLACEHOLDER))
    out.append(String(REVISION_ID_PLACEHOLDER))
    out.append(String(SOURCE_COMMIT_PLACEHOLDER))
    out.append(String(BUILD_NUMBER_PLACEHOLDER))
    out.append(String(TIMESTAMP_MS_PLACEHOLDER))
    return out^


def is_known_placeholder(p: String) -> Bool:
    var known = known_placeholders()
    for i in range(len(known)):
        if known[i] == p:
            return True
    return False


struct ReleaseStamp(Copyable, Movable):
    """The git-derived values of the four stamp placeholders. Built only
    through the checking constructor, so a value of this type is a valid
    stamp: both ids full 40-hex, both numbers positive.

    Layout: owned values only. No pointer field."""

    var revision_id: String
    var source_commit: String
    var build_number: Int
    var timestamp_ms: Int

    def __init__(
        out self,
        var revision_id: String,
        var source_commit: String,
        build_number: Int,
        timestamp_ms: Int,
    ) raises:
        require_full_commit_id(String("revision_id"), revision_id)
        require_full_commit_id(String("source_commit"), source_commit)
        if build_number <= 0:
            raise Error(
                String("build_number ") + String(build_number) + String(" is not positive")
            )
        if timestamp_ms <= 0:
            raise Error(
                String("timestamp_ms ") + String(timestamp_ms) + String(" is not positive")
            )
        self.revision_id = revision_id^
        self.source_commit = source_commit^
        self.build_number = build_number
        self.timestamp_ms = timestamp_ms


struct BuildValues(Copyable, Movable):
    """What the placeholders of ONE artifact's argv stand for. `out_dir` is
    always `release_dir + "/" + artifact` (render_build_argv derives it);
    `release_dir` is already the platform's release directory.

    Layout: owned values only. No pointer field."""

    var out_dir: String
    var release_dir: String
    var platform: String
    var stamp: ReleaseStamp

    def __init__(
        out self, var out_dir: String, var release_dir: String, var platform: String, var stamp: ReleaseStamp
    ):
        self.out_dir = out_dir^
        self.release_dir = release_dir^
        self.platform = platform^
        self.stamp = stamp^

    def value_of(self, placeholder: String) raises -> String:
        """The value `placeholder` (braces included) stands for; raises on
        one that is not among the seven."""
        if placeholder == OUT_DIR_PLACEHOLDER:
            return self.out_dir.copy()
        if placeholder == RELEASE_DIR_PLACEHOLDER:
            return self.release_dir.copy()
        if placeholder == PLATFORM_PLACEHOLDER:
            return self.platform.copy()
        if placeholder == REVISION_ID_PLACEHOLDER:
            return self.stamp.revision_id.copy()
        if placeholder == SOURCE_COMMIT_PLACEHOLDER:
            return self.stamp.source_commit.copy()
        if placeholder == BUILD_NUMBER_PLACEHOLDER:
            return String(self.stamp.build_number)
        if placeholder == TIMESTAMP_MS_PLACEHOLDER:
            return String(self.stamp.timestamp_ms)
        raise Error(String("unknown placeholder '") + placeholder + String("'"))


def _placeholder_end(arg: String, i: Int) -> Int:
    """If a placeholder starts at byte `i`, the index just past its `}`;
    else -1. The one lexer `placeholders_in` and the substitution share."""
    var b = arg.as_bytes()
    var n = len(b)
    if Int(b[i]) == 123 and i + 1 < n and _ident_start(Int(b[i + 1])):
        var j = i + 2
        while j < n and _ident(Int(b[j])):
            j += 1
        if j < n and Int(b[j]) == 125:
            return j + 1
    return -1


def substitute_placeholders(arg: String, values: BuildValues) raises -> String:
    """`arg` with every placeholder replaced by its value, in ONE pass over
    `arg` as written (a value is never substituted again). Raises on an
    unknown placeholder (a validated declaration holds none)."""
    var b = arg.as_bytes()
    var n = len(b)
    var out = String("")
    var lit = 0
    var i = 0
    while i < n:
        var end = _placeholder_end(arg, i)
        if end < 0:
            i += 1
            continue
        out += String(arg[byte = lit:i])
        out += values.value_of(String(arg[byte = i:end]))
        i = end
        lit = end
    out += String(arg[byte = lit:n])
    return out^


def require_one_manifest(declaration: String, top_level: List[String]) raises:
    """Refuse unless `top_level` (the names at the top of the declaration's
    output directory) holds `KCI_MANIFEST_NAME` exactly once."""
    var n = 0
    for i in range(len(top_level)):
        if top_level[i] == KCI_MANIFEST_NAME:
            n += 1
    if n == 0:
        raise Error(
            String("artifact '")
            + declaration
            + String("': the build left no ")
            + String(KCI_MANIFEST_NAME)
            + String(" at the top of its output directory")
        )
    if n > 1:
        raise Error(
            String("artifact '")
            + declaration
            + String("': the output directory lists ")
            + String(KCI_MANIFEST_NAME)
            + String(" ")
            + String(n)
            + String(" times; one artifact per declaration means exactly one")
        )


def require_manifest_name(declaration: String, manifest_name: String) raises:
    """Refuse unless the built manifest's `name` equals the declaration's
    name EXACTLY (byte for byte)."""
    if manifest_name != declaration:
        raise Error(
            String("artifact '")
            + declaration
            + String("': the built manifest's name '")
            + manifest_name
            + String("' is not the declaration's name (compared exactly)")
        )
