# =============================================================================
# kci_artifact_declaration/validate.mojo -- the rules a declarations value
#   must satisfy, and the lookups kci build / kci publish read it through.
# =============================================================================
#
# `validate_artifact_declarations` refuses, naming the artifact:
#   * a file declaring no artifact;
#   * a name that is empty, not `[a-z][a-z0-9_]*`, or over 64 bytes; two
#     artifacts with one name (compared exactly, whatever their kinds);
#   * an artifact with no kind;
#   * no allowed channel, a channel name that is not a channel name, or one
#     named twice;
#   * a build rule (or a metapackage's packer) that is missing, names no
#     build system, or whose Buck2 label is not `//<pkg>:<name>` /
#     `<cell>//<pkg>:<name>` (a sub-target is refused: kci adds `[release]`);
#   * conda subdirs that are empty, malformed, `noarch` or repeated;
#   * a `depends_on` entry that is repeated, the artifact itself, undeclared,
#     or an artifact of another kind (a conda package depends on conda
#     packages, a wheel on wheels); a `depends_on` cycle, by its path;
#   * a `member_of` that names no declared conda_metapackage; a metapackage
#     with no member; a member missing a subdir or a channel of its
#     metapackage; a dependency missing a channel of its dependent (either
#     would publish a package its channel cannot resolve).
#
# `validate_declarations_against_channels` checks the same value against the
# channels file: every allowed channel is declared and has a repository for
# the artifact's type.
#
# The kind is the generated oneof discriminant (`_oneof0_case`), 1..4 in the
# order the .proto declares the arms; the KIND_* constants below are those
# values, and the welded round-trip test pins each against the wire.
#
# Owned values only; no pointer.
# =============================================================================

from kci_artifact_declaration_proto.artifact_declaration import (
    ArtifactDeclaration,
    ArtifactDeclarations,
    BuildRule,
)
from kci_release_channel import (
    ARTIFACT_TYPE_CONDA,
    ARTIFACT_TYPE_OCI,
    ARTIFACT_TYPE_PYTHON,
    ChannelDeclaration,
    find_channel,
    is_valid_channel_name,
)


comptime KIND_CONDA_PACKAGE: Int = 1
comptime KIND_CONDA_METAPACKAGE: Int = 2
comptime KIND_PYTHON_WHEEL: Int = 3
comptime KIND_OCI_IMAGE: Int = 4

comptime _MAX_NAME_BYTES: Int = 64
comptime _DEFAULT_SOURCE: String = "artifact declarations"


def known_kinds() -> String:
    return String("conda_package, conda_metapackage, python_wheel, oci_image")


def kind_name(d: ArtifactDeclaration) -> String:
    """The set kind arm's field name, or "" when none is set."""
    if d._oneof0_case == KIND_CONDA_PACKAGE:
        return String("conda_package")
    if d._oneof0_case == KIND_CONDA_METAPACKAGE:
        return String("conda_metapackage")
    if d._oneof0_case == KIND_PYTHON_WHEEL:
        return String("python_wheel")
    if d._oneof0_case == KIND_OCI_IMAGE:
        return String("oci_image")
    return String("")


def artifact_type(d: ArtifactDeclaration) raises -> String:
    """The release channel's artifact type for `d` (kci_release_channel's
    vocabulary, which is also the built manifest's `artifact_type`): the one
    bridge between the typed kinds and that closed set."""
    if (
        d._oneof0_case == KIND_CONDA_PACKAGE
        or d._oneof0_case == KIND_CONDA_METAPACKAGE
    ):
        return String(ARTIFACT_TYPE_CONDA)
    if d._oneof0_case == KIND_PYTHON_WHEEL:
        return String(ARTIFACT_TYPE_PYTHON)
    if d._oneof0_case == KIND_OCI_IMAGE:
        return String(ARTIFACT_TYPE_OCI)
    raise Error(String("artifact '") + d.name + String("' declares no kind"))


def _rule_of(d: ArtifactDeclaration) -> Optional[BuildRule]:
    if d._oneof0_case == KIND_CONDA_PACKAGE:
        return d.conda_package.value().build.copy()
    if d._oneof0_case == KIND_CONDA_METAPACKAGE:
        return d.conda_metapackage.value().packer.copy()
    if d._oneof0_case == KIND_PYTHON_WHEEL:
        return d.python_wheel.value().build.copy()
    if d._oneof0_case == KIND_OCI_IMAGE:
        return d.oci_image.value().build.copy()
    return None


def buck2_label(d: ArtifactDeclaration) raises -> String:
    """The Buck2 label kci builds `[release]` of (for a conda_metapackage:
    the packer it runs)."""
    var rule = _rule_of(d)
    if not rule or rule.value()._oneof0_case != 1:
        raise Error(String("artifact '") + d.name + String("' has no Buck2 build rule"))
    return rule.value().buck2.value().label.copy()


def _subdirs(d: ArtifactDeclaration) -> List[String]:
    if d._oneof0_case == KIND_CONDA_PACKAGE:
        return d.conda_package.value().subdirs.copy()
    if d._oneof0_case == KIND_CONDA_METAPACKAGE:
        return d.conda_metapackage.value().subdirs.copy()
    return List[String]()


def _depends_on(d: ArtifactDeclaration) -> List[String]:
    if d._oneof0_case == KIND_CONDA_PACKAGE:
        return d.conda_package.value().depends_on.copy()
    if d._oneof0_case == KIND_PYTHON_WHEEL:
        return d.python_wheel.value().depends_on.copy()
    return List[String]()


def _member_of(d: ArtifactDeclaration) -> String:
    if d._oneof0_case == KIND_CONDA_PACKAGE:
        return d.conda_package.value().member_of.copy()
    return String("")


def find_declaration(decls: ArtifactDeclarations, name: String) -> Int:
    """The index of the artifact named exactly `name`, or -1."""
    for i in range(len(decls.artifact)):
        if decls.artifact[i].name == name:
            return i
    return -1


def members_of(decls: ArtifactDeclarations, name: String) -> List[String]:
    """The names of the conda packages whose `member_of` is `name`, in
    declaration order."""
    var out = List[String]()
    for i in range(len(decls.artifact)):
        if _member_of(decls.artifact[i]) == name:
            out.append(decls.artifact[i].name.copy())
    return out^


# ── Syntax. ──────────────────────────────────────────────────────────────────


def _lower(c: Int) -> Bool:
    return c >= 97 and c <= 122


def _digit(c: Int) -> Bool:
    return c >= 48 and c <= 57


def _alnum(c: Int) -> Bool:
    return _lower(c) or _digit(c) or (c >= 65 and c <= 90)


def is_valid_artifact_name(name: String) -> Bool:
    """`[a-z][a-z0-9_]*`, 1..64 bytes. No `-` or `.`: conda and wheel
    indexes treat names differing only there as one or as two, so neither
    may appear."""
    var b = name.as_bytes()
    var n = len(b)
    if n == 0 or n > _MAX_NAME_BYTES:
        return False
    if not _lower(Int(b[0])):
        return False
    for i in range(n):
        var c = Int(b[i])
        if not (_lower(c) or _digit(c) or c == 95):
            return False
    return True


def is_valid_conda_subdir(subdir: String) -> Bool:
    """`<os>-<arch>`: `[a-z][a-z0-9]*-[a-z0-9_]+` (`linux-64`, `osx-arm64`)."""
    var b = subdir.as_bytes()
    var n = len(b)
    if n == 0 or not _lower(Int(b[0])):
        return False
    var dash = -1
    for i in range(n):
        var c = Int(b[i])
        if c == 45:
            if dash >= 0:
                return False
            dash = i
        elif not (_lower(c) or _digit(c) or (c == 95 and dash >= 0)):
            return False
    return dash > 0 and dash < n - 1


def _package_segment_ok(seg: String) -> Bool:
    var b = seg.as_bytes()
    if len(b) == 0 or seg == "." or seg == "..":
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        if not (_alnum(c) or c == 95 or c == 45 or c == 46 or c == 43):
            return False
    return True


def is_buck2_label(label: String) -> Bool:
    """`//<package>:<name>` or `<cell>//<package>:<name>`. The package is
    `/`-separated segments of `[A-Za-z0-9_.+-]` (never `.` or `..`) and may
    be empty; the name is `[A-Za-z0-9_.,=+-]+`. No sub-target, no pattern."""
    var root = label.find(String("//"))
    if root < 0:
        return False
    var cell = String(label[byte = :root])
    var cb = cell.as_bytes()
    for i in range(len(cb)):
        var c = Int(cb[i])
        if not (_alnum(c) or c == 95):
            return False
    var rest = String(label[byte = root + 2 :])
    var colon = rest.find(String(":"))
    if colon < 0 or rest.find(String(":"), colon + 1) >= 0:
        return False
    var package = String(rest[byte = :colon])
    var name = String(rest[byte = colon + 1 :])
    if package.byte_length() > 0:
        var segs = package.split(String("/"))
        for i in range(len(segs)):
            if not _package_segment_ok(String(segs[i])):
                return False
    var nb = name.as_bytes()
    if len(nb) == 0:
        return False
    for i in range(len(nb)):
        var c = Int(nb[i])
        if not (
            _alnum(c) or c == 95 or c == 46 or c == 44 or c == 61 or c == 43 or c == 45
        ):
            return False
    return True


# ── Validation. ─────────────────────────────────────────────────────────────


def _refuse(source: String, what: String, rest: String) raises:
    raise Error(source + String(": ") + what + String(" ") + rest)


def _who(d: ArtifactDeclaration, ordinal: Int) -> String:
    if d.name.byte_length() > 0:
        return String("artifact '") + d.name + String("'")
    return String("artifact #") + String(ordinal)


def _contains(xs: List[String], x: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


def _check_rule(source: String, who: String, field: String, rule: Optional[BuildRule]) raises:
    if not rule:
        _refuse(source, who, String("has no '") + field + String("' (its build rule)"))
    if rule.value()._oneof0_case != 1:
        _refuse(source, who, String("'") + field + String("' names no build system (expected buck2)"))
    var label = rule.value().buck2.value().label.copy()
    if label.find(String("[")) >= 0:
        _refuse(
            source,
            who,
            String("Buck2 label '")
            + label
            + String("' names a sub-target; kci builds '[release]' of the target itself"),
        )
    if not is_buck2_label(label):
        _refuse(
            source,
            who,
            String("Buck2 label '")
            + label
            + String("' is not a target label (//<package>:<name> or <cell>//<package>:<name>)"),
        )


def _check_names(source: String, who: String, field: String, xs: List[String]) raises:
    for i in range(len(xs)):
        for j in range(i):
            if xs[j] == xs[i]:
                _refuse(source, who, String("names '") + xs[i] + String("' twice in ") + field)


def _check_subdirs(source: String, who: String, subdirs: List[String]) raises:
    if len(subdirs) == 0:
        _refuse(source, who, String("has no subdirs (a conda artifact names its platforms)"))
    for i in range(len(subdirs)):
        if subdirs[i] == "noarch":
            _refuse(source, who, String("subdir 'noarch' is not published: a compiled package names its platform subdir"))
        if not is_valid_conda_subdir(subdirs[i]):
            _refuse(source, who, String("subdir '") + subdirs[i] + String("' is not <os>-<arch>"))
    _check_names(source, who, String("subdirs"), subdirs)


def _visit(
    i: Int,
    decls: ArtifactDeclarations,
    source: String,
    mut state: List[Int],
    mut path: List[Int],
    mut order: List[Int],
) raises:
    """Depth-first over the edges `depends_on` and (for a metapackage) its
    members. state: 0 unseen, 1 on the path, 2 done."""
    if state[i] == 2:
        return
    if state[i] == 1:
        var cycle = String("")
        var start = 0
        for k in range(len(path)):
            if path[k] == i:
                start = k
        for k in range(start, len(path)):
            cycle += decls.artifact[path[k]].name + String(" -> ")
        cycle += decls.artifact[i].name
        raise Error(source + String(": depends_on cycle: ") + cycle)
    state[i] = 1
    path.append(i)
    var d = decls.artifact[i].copy()
    var deps = _depends_on(d)
    if d._oneof0_case == KIND_CONDA_METAPACKAGE:
        deps = members_of(decls, d.name)
    for k in range(len(deps)):
        _visit(find_declaration(decls, deps[k]), decls, source, state, path, order)
    _ = path.pop()
    state[i] = 2
    order.append(i)


def build_order(decls: ArtifactDeclarations) raises -> List[String]:
    """Every artifact name, each after everything it depends on and every
    metapackage after all its members; otherwise in declaration order.
    Assumes references resolve (a validated value); raises on a cycle."""
    var n = len(decls.artifact)
    var state = List[Int]()
    for _ in range(n):
        state.append(0)
    var path = List[Int]()
    var order = List[Int]()
    for i in range(n):
        _visit(i, decls, String(_DEFAULT_SOURCE), state, path, order)
    var out = List[String]()
    for k in range(len(order)):
        out.append(decls.artifact[order[k]].name.copy())
    return out^


def validate_artifact_declarations(
    decls: ArtifactDeclarations, source: String = String(_DEFAULT_SOURCE)
) raises:
    """Every rule in this file's header. Raises on the first refusal, by a
    message starting with `source` and naming the artifact."""
    var n = len(decls.artifact)
    if n == 0:
        raise Error(source + String(": declares no artifact"))

    # Per artifact: name, kind, channels, build rule, kind fields.
    for i in range(n):
        var d = decls.artifact[i].copy()
        var who = _who(d, i + 1)
        if d.name.strip().byte_length() == 0:
            _refuse(source, who, String("has an EMPTY name"))
        if not is_valid_artifact_name(d.name):
            _refuse(source, who, String("name is not [a-z][a-z0-9_]* of at most 64 bytes"))
        for j in range(i):
            if decls.artifact[j].name == d.name:
                _refuse(source, who, String("is declared twice (names are unique whatever the kind)"))
        if d._oneof0_case < KIND_CONDA_PACKAGE or d._oneof0_case > KIND_OCI_IMAGE:
            _refuse(source, who, String("declares no kind (expected one of ") + known_kinds() + String(")"))
        if len(d.allowed_channels) == 0:
            _refuse(source, who, String("has no allowed_channels (an artifact names every channel it may go to)"))
        for k in range(len(d.allowed_channels)):
            if not is_valid_channel_name(d.allowed_channels[k]):
                _refuse(source, who, String("allowed channel '") + d.allowed_channels[k] + String("' is not a channel name"))
        _check_names(source, who, String("allowed_channels"), d.allowed_channels)
        var field = String("packer") if d._oneof0_case == KIND_CONDA_METAPACKAGE else String("build")
        _check_rule(source, who, field, _rule_of(d))
        if d._oneof0_case == KIND_CONDA_PACKAGE or d._oneof0_case == KIND_CONDA_METAPACKAGE:
            _check_subdirs(source, who, _subdirs(d))

    # References: depends_on and member_of resolve, to the right kind.
    for i in range(n):
        var d = decls.artifact[i].copy()
        var who = _who(d, i + 1)
        var deps = _depends_on(d)
        _check_names(source, who, String("depends_on"), deps)
        for k in range(len(deps)):
            if deps[k] == d.name:
                _refuse(source, who, String("depends on itself"))
            var j = find_declaration(decls, deps[k])
            if j < 0:
                _refuse(source, who, String("depends on '") + deps[k] + String("', which is not declared"))
            var dep = decls.artifact[j].copy()
            if dep._oneof0_case != d._oneof0_case:
                _refuse(
                    source,
                    who,
                    String("is a ")
                    + kind_name(d)
                    + String(" and depends on '")
                    + deps[k]
                    + String("', a ")
                    + kind_name(dep)
                    + String(" (a dependency is of the same kind)"),
                )
            for c in range(len(d.allowed_channels)):
                if not _contains(dep.allowed_channels, d.allowed_channels[c]):
                    _refuse(
                        source,
                        who,
                        String("may go to channel '")
                        + d.allowed_channels[c]
                        + String("' but its dependency '")
                        + deps[k]
                        + String("' may not"),
                    )
        var meta = _member_of(d)
        if meta.byte_length() > 0:
            var j = find_declaration(decls, meta)
            if j < 0 or decls.artifact[j]._oneof0_case != KIND_CONDA_METAPACKAGE:
                _refuse(source, who, String("is a member of '") + meta + String("', which is not a declared conda_metapackage"))
            var m = decls.artifact[j].copy()
            var mine = _subdirs(d)
            var theirs = _subdirs(m)
            for s in range(len(theirs)):
                if not _contains(mine, theirs[s]):
                    _refuse(source, who, String("is a member of '") + meta + String("' but is not built for its subdir '") + theirs[s] + String("'"))
            for c in range(len(m.allowed_channels)):
                if not _contains(d.allowed_channels, m.allowed_channels[c]):
                    _refuse(source, who, String("is a member of '") + meta + String("' but may not go to its channel '") + m.allowed_channels[c] + String("'"))
        if d._oneof0_case == KIND_CONDA_METAPACKAGE and len(members_of(decls, d.name)) == 0:
            _refuse(source, who, String("is a conda_metapackage with no member (no conda_package says member_of: \"") + d.name + String("\")"))

    # Cycles, by path.
    var state = List[Int]()
    for _ in range(n):
        state.append(0)
    var path = List[Int]()
    var order = List[Int]()
    for i in range(n):
        _visit(i, decls, source, state, path, order)


def validate_declarations_against_channels(
    decls: ArtifactDeclarations, channels: List[ChannelDeclaration]
) raises:
    """Every allowed channel of every artifact is declared in `channels` and
    has a repository for the artifact's type."""
    for i in range(len(decls.artifact)):
        var d = decls.artifact[i].copy()
        var t = artifact_type(d)
        for k in range(len(d.allowed_channels)):
            var ch: ChannelDeclaration
            try:
                ch = find_channel(channels, d.allowed_channels[k])
            except e:
                raise Error(String("artifact '") + d.name + String("': ") + String(e))
            try:
                _ = ch.repository_for(t)
            except e:
                raise Error(String("artifact '") + d.name + String("': ") + String(e))
