# =============================================================================
# kci_artifact_declaration/validate.mojo -- the rules a declarations value
#   must satisfy, and the lookups.
# =============================================================================
#
# `validate_artifact_declarations` refuses, naming the build system or the
# artifact (by name, or by ordinal when it has none):
#   * a file declaring no artifact;
#   * a name that is empty or not `[a-z][a-z0-9_]*`; two build systems, or
#     two artifacts, with one name (the two lists are separate namespaces);
#   * a build system with no executable, an executable holding whitespace,
#     or a relative path for one (`./buck2`, `bin/buck2`: the file does not
#     state the directory it would resolve against);
#   * an empty entry in any args list;
#   * a placeholder that is not one of contract.mojo's six (`{out_dir}`,
#     `{release_dir}`, `{revision_id}`, `{source_commit}`, `{build_number}`,
#     `{timestamp_ms}`) in any arg: `{<identifier>}`, the identifier
#     `[A-Za-z_][A-Za-z0-9_]*`; any other brace is literal;
#   * an artifact whose `build_system` is empty or names no declared one;
#   * an artifact with no args;
#   * an artifact whose combined args (its build system's, then its own)
#     never contain `{out_dir}`: kci could not find what was built;
#   (a placeholder in an executable is not substituted and not checked: the
#   executable is a program name or an absolute path, never an arg).
#
# What a build LEFT (exactly one `manifest.json` at the top of `{out_dir}`,
# whose `name` is the declaration's, exactly) is checked by contract.mojo's
# `require_one_manifest` and `require_manifest_name`, after the build.
#
# Not here, by design (kci publish, over the built manifests): every
# declared artifact built, versions in lockstep, exactly one metapackage
# whose members are every library (a recommendation the CEO has not
# answered; contract.mojo), requirement closure over the set.
#
# Owned values only; no pointer.
# =============================================================================

from kci_artifact_declaration_proto.artifact_declaration import (
    ArtifactDeclaration,
    ArtifactDeclarations,
    BuildSystem,
)

from .contract import OUT_DIR_PLACEHOLDER, is_known_placeholder, known_placeholders, placeholders_in

comptime _DEFAULT_SOURCE: String = "artifact declarations"


def find_build_system(decls: ArtifactDeclarations, name: String) -> Int:
    """The index of the build system named exactly `name`, or -1."""
    for i in range(len(decls.build_systems)):
        if decls.build_systems[i].name == name:
            return i
    return -1


def find_artifact(decls: ArtifactDeclarations, name: String) -> Int:
    """The index of the artifact named exactly `name`, or -1."""
    for i in range(len(decls.artifacts)):
        if decls.artifacts[i].name == name:
            return i
    return -1


# ── Syntax. ──────────────────────────────────────────────────────────────────


def _lower(c: Int) -> Bool:
    return c >= 97 and c <= 122


def _digit(c: Int) -> Bool:
    return c >= 48 and c <= 57


def is_valid_declaration_name(name: String) -> Bool:
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
    if not is_valid_declaration_name(name):
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


def _check_build_system(source: String, decls: ArtifactDeclarations, i: Int) raises:
    ref b = decls.build_systems[i]
    var who = _who(String("build system"), b.name, i + 1)
    _check_name(source, who, b.name)
    if find_build_system(decls, b.name) != i:
        _refuse(source, who, String("is declared twice"))
    if b.executable.byte_length() == 0:
        _refuse(source, who, String("has no executable"))
    if _has_whitespace(b.executable):
        _refuse(source, who, String("executable '") + b.executable + String("' holds whitespace"))
    if not b.executable.startswith(String("/")) and b.executable.find(String("/")) >= 0:
        _refuse(
            source,
            who,
            String("executable '")
            + b.executable
            + String("' is a relative path (expected a program name found on PATH, or an absolute path)"),
        )
    _check_args(source, who, b.args)


def _check_artifact(source: String, decls: ArtifactDeclarations, i: Int) raises:
    ref a = decls.artifacts[i]
    var who = _who(String("artifact"), a.name, i + 1)
    _check_name(source, who, a.name)
    if find_artifact(decls, a.name) != i:
        _refuse(source, who, String("is declared twice"))
    if a.build_system.byte_length() == 0:
        _refuse(source, who, String("names no build_system"))
    var b = find_build_system(decls, a.build_system)
    if b < 0:
        _refuse(source, who, String("build_system '") + a.build_system + String("' is not declared"))
    if len(a.args) == 0:
        _refuse(source, who, String("has no args (they say what to build)"))
    _check_args(source, who, a.args)
    if not _names_out_dir(decls.build_systems[b].args) and not _names_out_dir(a.args):
        _refuse(
            source,
            who,
            String("has no '")
            + String(OUT_DIR_PLACEHOLDER)
            + String("' in its args or in the args of build system '")
            + a.build_system
            + String("': kci could not find what the build made"),
        )


def validate_artifact_declarations(
    decls: ArtifactDeclarations, source: String = String(_DEFAULT_SOURCE)
) raises:
    """Every rule in this file's header. Raises on the first refusal, by a
    message starting with `source`: build systems first, then artifacts,
    each in file order."""
    if len(decls.artifacts) == 0:
        raise Error(source + String(": declares no artifact"))
    for i in range(len(decls.build_systems)):
        _check_build_system(source, decls, i)
    for i in range(len(decls.artifacts)):
        _check_artifact(source, decls, i)

