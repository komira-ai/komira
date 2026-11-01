# =============================================================================
# kci_artifact/validate.mojo -- the rules an artifacts value
#   must satisfy, and the lookups.
# =============================================================================
#
# `validate_artifacts` refuses, naming the build system or the
# artifact (by name, or by ordinal when it has none):
#   * a file declaring no artifact;
#   * a name that is empty or not `[a-z][a-z0-9_]*`; two build systems, or
#     two artifacts, with one name (the two lists are separate namespaces);
#   * a build system with no executable, an executable holding whitespace,
#     or a relative path for one (`./buck2`, `bin/buck2`: the file does not
#     state the directory it would resolve against);
#   * an empty entry in any args list;
#   * a placeholder that is not one of placeholders.mojo's seven (`{out_dir}`,
#     `{release_dir}`, `{platform}`, `{revision_id}`, `{source_commit}`,
#     `{build_number}`, `{timestamp_ms}`) in any arg: `{<identifier>}`, the identifier
#     `[A-Za-z_][A-Za-z0-9_]*`; any other brace is literal;
#   * an artifact whose `build_system` is empty or names no declared one;
#   * an artifact with no args;
#   * an artifact whose combined args (its build system's, then its own)
#     never contain `{out_dir}`: kci could not find what was built;
#   (a placeholder in an executable is not substituted and not checked: the
#   executable is a program name or an absolute path, never an arg);
# and for the per-change check (the .proto's header):
#   * a check named like an artifact, or two checks with one name: artifacts
#     and checks are ONE name space of units;
#   * a check whose `build_system` is empty or undeclared, or declares no
#     `build_targets` (kci could not build it), and a check with no targets;
#   * a target (an artifact's or a check's) that is empty, holds whitespace
#     or a placeholder, or is given twice in one unit;
#   * a `derive_checks` command breaking the executable rules, holding an
#     empty arg or a placeholder that is not an affected command's, or never
#     naming `{units_file}`; a build system declaring it without both
#     `affected` and `build_targets`;
#   * an `affected` or `build_targets` command breaking the executable rules
#     above, or holding an empty arg; an `affected` arg holding a placeholder
#     that is not one of its four (`{changed_files}`, `{units_file}`,
#     `{base_commit}`, `{revision_id}`), or args never naming
#     `{changed_files}` or `{units_file}`; a `build_targets` arg holding any
#     placeholder.
# `targets` and the two commands are optional here: `require_affected_ready`
# refuses, for a `--affected-by` run only, a unit without targets and a build
# system owning a unit without both commands.
#
# What a build LEFT (exactly one `manifest.json` at the top of `{out_dir}`,
# whose `name` is the artifact's, exactly) is checked by placeholders.mojo's
# `require_one_manifest` and `require_manifest_name`, after the build.
#
# Not here, by design (over the built manifests: the PUBLISH step, and for
# requirement closure by name also the BUILD step): every declared artifact
# built, versions in lockstep, exactly one metapackage whose members are
# every library (a recommendation the CEO has not answered;
# placeholders.mojo), requirement closure over the set.
#
# Owned values only; no pointer.
# =============================================================================

from kci_artifact_proto.artifact import (
    Artifact,
    Artifacts,
    BuildSystem,
    Check,
    Command,
)

from .placeholders import (
    CHANGED_FILES_PLACEHOLDER,
    OUT_DIR_PLACEHOLDER,
    UNITS_FILE_PLACEHOLDER,
    affected_placeholders,
    is_affected_placeholder,
    is_known_placeholder,
    known_placeholders,
    placeholders_in,
)

comptime _DEFAULT_SOURCE: String = "artifacts"


def find_build_system(arts: Artifacts, name: String) -> Int:
    """The index of the build system named exactly `name`, or -1."""
    for i in range(len(arts.build_systems)):
        if arts.build_systems[i].name == name:
            return i
    return -1


def find_artifact(arts: Artifacts, name: String) -> Int:
    """The index of the artifact named exactly `name`, or -1."""
    for i in range(len(arts.artifacts)):
        if arts.artifacts[i].name == name:
            return i
    return -1


def find_check(arts: Artifacts, name: String) -> Int:
    """The index of the check named exactly `name`, or -1."""
    for i in range(len(arts.checks)):
        if arts.checks[i].name == name:
            return i
    return -1


# ── Syntax. ──────────────────────────────────────────────────────────────────


def _lower(c: Int) -> Bool:
    return c >= 97 and c <= 122


def _digit(c: Int) -> Bool:
    return c >= 48 and c <= 57


def is_valid_artifact_name(name: String) -> Bool:
    """`[a-z][a-z0-9_]*`: the name of a build system or of an artifact."""
    var b = name.as_bytes()
    var n = len(b)
    if n == 0 or not _lower(Int(b[0])):
        return False
    for i in range(n):
        var c = Int(b[i])
        if not (_lower(c) or _digit(c) or c == 95):
            return False
    return True


def _has_whitespace(s: String) -> Bool:
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c == 32 or (c >= 9 and c <= 13):
            return True
    return False


# ── Validation. ─────────────────────────────────────────────────────────────


def _refuse(source: String, who: String, rest: String) raises:
    raise Error(source + String(": ") + who + String(" ") + rest)


def _who(kind: String, name: String, ordinal: Int) -> String:
    if name.byte_length() > 0:
        return kind + String(" '") + name + String("'")
    return kind + String(" #") + String(ordinal)


def _contains(xs: List[String], x: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


def _check_name(source: String, who: String, name: String) raises:
    if name.byte_length() == 0:
        _refuse(source, who, String("has an EMPTY name"))
    if not is_valid_artifact_name(name):
        _refuse(source, who, String("name is not [a-z][a-z0-9_]*"))


def _known_text() -> String:
    var known = known_placeholders()
    var s = String("")
    for i in range(len(known)):
        if i > 0:
            s += String(" ")
        s += known[i]
    return s^


def _check_args(source: String, who: String, args: List[String]) raises:
    for i in range(len(args)):
        if args[i].byte_length() == 0:
            _refuse(source, who, String("arg #") + String(i + 1) + String(" is empty"))
        var ph = placeholders_in(args[i])
        for k in range(len(ph)):
            if not is_known_placeholder(ph[k]):
                _refuse(
                    source,
                    who,
                    String("arg '")
                    + args[i]
                    + String("' holds the unknown placeholder '")
                    + ph[k]
                    + String("' (known: ")
                    + _known_text()
                    + String(")"),
                )


def _names_out_dir(args: List[String]) -> Bool:
    for i in range(len(args)):
        if args[i].find(String(OUT_DIR_PLACEHOLDER)) >= 0:
            return True
    return False


def _check_build_system(source: String, arts: Artifacts, i: Int) raises:
    ref b = arts.build_systems[i]
    var who = _who(String("build system"), b.name, i + 1)
    _check_name(source, who, b.name)
    if find_build_system(arts, b.name) != i:
        _refuse(source, who, String("is declared twice"))
    _check_executable(source, who, b.executable)
    _check_args(source, who, b.args)
    if b.affected:
        _check_affected(source, who, b.affected.value())
    if b.build_targets:
        _check_build_targets(source, who, b.build_targets.value())
    if b.derive_checks:
        _check_derive_checks(source, who, b.derive_checks.value())
        if not b.affected or not b.build_targets:
            _refuse(
                source, who,
                String("declares derive_checks but not both affected and build_targets: kci could not")
                + String(" select or build the checks it derives"),
            )


def _check_artifact(source: String, arts: Artifacts, i: Int) raises:
    ref a = arts.artifacts[i]
    var who = _who(String("artifact"), a.name, i + 1)
    _check_name(source, who, a.name)
    if find_artifact(arts, a.name) != i:
        _refuse(source, who, String("is declared twice"))
    if a.build_system.byte_length() == 0:
        _refuse(source, who, String("names no build_system"))
    var b = find_build_system(arts, a.build_system)
    if b < 0:
        _refuse(source, who, String("build_system '") + a.build_system + String("' is not declared"))
    if len(a.args) == 0:
        _refuse(source, who, String("has no args (they say what to build)"))
    _check_args(source, who, a.args)
    if not _names_out_dir(arts.build_systems[b].args) and not _names_out_dir(a.args):
        _refuse(
            source,
            who,
            String("has no '")
            + String(OUT_DIR_PLACEHOLDER)
            + String("' in its args or in the args of build system '")
            + a.build_system
            + String("': kci could not find what the build made"),
        )
    if find_check(arts, a.name) >= 0:
        _refuse(source, who, String("is also the name of a check (artifacts and checks are one name space)"))
    _check_targets(source, who, a.targets)


def _check_targets(source: String, who: String, targets: List[String]) raises:
    for i in range(len(targets)):
        ref t = targets[i]
        var where = String("target #") + String(i + 1)
        if t.byte_length() == 0:
            _refuse(source, who, where + String(" is empty"))
        if _has_whitespace(t):
            _refuse(source, who, where + String(" '") + t + String("' holds whitespace"))
        if len(placeholders_in(t)) > 0:
            _refuse(
                source, who,
                where + String(" '") + t + String("' holds a placeholder (a target is substituted by nothing)"),
            )
        for j in range(i):
            if targets[j] == t:
                _refuse(source, who, String("target '") + t + String("' is given twice"))


def _check_executable(source: String, who: String, executable: String) raises:
    if executable.byte_length() == 0:
        _refuse(source, who, String("has no executable"))
    if _has_whitespace(executable):
        _refuse(source, who, String("executable '") + executable + String("' holds whitespace"))
    if not executable.startswith(String("/")) and executable.find(String("/")) >= 0:
        _refuse(
            source,
            who,
            String("executable '")
            + executable
            + String("' is a relative path (expected a program name found on PATH, or an absolute path)"),
        )


def _names(args: List[String], placeholder: String) -> Bool:
    for i in range(len(args)):
        if args[i].find(placeholder) >= 0:
            return True
    return False


def _check_affected(source: String, who: String, c: Command) raises:
    var me = String("the affected command of ") + who
    _check_executable(source, me, c.executable)
    for i in range(len(c.args)):
        if c.args[i].byte_length() == 0:
            _refuse(source, me, String("arg #") + String(i + 1) + String(" is empty"))
        var ph = placeholders_in(c.args[i])
        for k in range(len(ph)):
            if not is_affected_placeholder(ph[k]):
                var known = affected_placeholders()
                var text = String("")
                for j in range(len(known)):
                    if j > 0:
                        text += String(" ")
                    text += known[j]
                _refuse(
                    source, me,
                    String("arg '") + c.args[i] + String("' holds the placeholder '") + ph[k]
                    + String("', which is not an affected command's (known: ") + text + String(")"),
                )
    for p in [String(CHANGED_FILES_PLACEHOLDER), String(UNITS_FILE_PLACEHOLDER)]:
        if not _names(c.args, p):
            _refuse(source, me, String("never names '") + p + String("': the tool could not know what to answer"))


def _check_derive_checks(source: String, who: String, c: Command) raises:
    var me = String("the derive_checks command of ") + who
    _check_executable(source, me, c.executable)
    for i in range(len(c.args)):
        if c.args[i].byte_length() == 0:
            _refuse(source, me, String("arg #") + String(i + 1) + String(" is empty"))
        var ph = placeholders_in(c.args[i])
        for k in range(len(ph)):
            if not is_affected_placeholder(ph[k]):
                _refuse(
                    source, me,
                    String("arg '") + c.args[i] + String("' holds the placeholder '") + ph[k]
                    + String("', which is not an affected command's"),
                )
    if not _names(c.args, String(UNITS_FILE_PLACEHOLDER)):
        _refuse(
            source, me,
            String("never names '") + String(UNITS_FILE_PLACEHOLDER)
            + String("': the tool could not know what the declared units already name"),
        )


def _check_build_targets(source: String, who: String, c: Command) raises:
    var me = String("the build_targets command of ") + who
    _check_executable(source, me, c.executable)
    for i in range(len(c.args)):
        if c.args[i].byte_length() == 0:
            _refuse(source, me, String("arg #") + String(i + 1) + String(" is empty"))
        if len(placeholders_in(c.args[i])) > 0:
            _refuse(
                source, me,
                String("arg '") + c.args[i] + String("' holds a placeholder (this command is run unstamped,")
                + String(" with no output directory)"),
            )


def _check_check(source: String, arts: Artifacts, i: Int) raises:
    ref c = arts.checks[i]
    var who = _who(String("check"), c.name, i + 1)
    _check_name(source, who, c.name)
    if find_check(arts, c.name) != i:
        _refuse(source, who, String("is declared twice"))
    if find_artifact(arts, c.name) >= 0:
        _refuse(source, who, String("is also the name of an artifact (artifacts and checks are one name space)"))
    if c.build_system.byte_length() == 0:
        _refuse(source, who, String("names no build_system"))
    var b = find_build_system(arts, c.build_system)
    if b < 0:
        _refuse(source, who, String("build_system '") + c.build_system + String("' is not declared"))
    if not arts.build_systems[b].build_targets:
        _refuse(
            source, who,
            String("build_system '") + c.build_system
            + String("' declares no build_targets command: kci could not build the check"),
        )
    if len(c.targets) == 0:
        _refuse(source, who, String("has no targets (they are what the check builds)"))
    _check_targets(source, who, c.targets)


def require_affected_ready(arts: Artifacts, source: String = String(_DEFAULT_SOURCE)) raises:
    """What a `--affected-by` run needs beyond `validate_artifacts`: every
    unit names its targets, and every build system owning a unit declares
    both the `affected` and the `build_targets` command. Raises on the first
    miss, naming it."""
    for i in range(len(arts.artifacts)):
        ref a = arts.artifacts[i]
        if len(a.targets) == 0:
            _refuse(
                source, _who(String("artifact"), a.name, i + 1),
                String("has no targets: the per-change check cannot tell whether a change reaches it"),
            )
    for i in range(len(arts.build_systems)):
        ref b = arts.build_systems[i]
        var owns = False
        for k in range(len(arts.artifacts)):
            if arts.artifacts[k].build_system == b.name:
                owns = True
        for k in range(len(arts.checks)):
            if arts.checks[k].build_system == b.name:
                owns = True
        if not owns:
            continue
        var who = _who(String("build system"), b.name, i + 1)
        if not b.affected:
            _refuse(source, who, String("owns a unit and declares no affected command (--affected-by needs one)"))
        if not b.build_targets:
            _refuse(source, who, String("owns a unit and declares no build_targets command (--affected-by needs one)"))


def validate_artifacts(
    arts: Artifacts, source: String = String(_DEFAULT_SOURCE)
) raises:
    """Every rule in this file's header. Raises on the first refusal, by a
    message starting with `source`: build systems first, then artifacts,
    then checks, each in file order."""
    if len(arts.artifacts) == 0:
        raise Error(source + String(": declares no artifact"))
    for i in range(len(arts.build_systems)):
        _check_build_system(source, arts, i)
    for i in range(len(arts.artifacts)):
        _check_artifact(source, arts, i)
    for i in range(len(arts.checks)):
        _check_check(source, arts, i)

