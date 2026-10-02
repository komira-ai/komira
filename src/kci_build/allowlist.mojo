# =============================================================================
# src/kci_build/allowlist.mojo -- the publishable list: which Buck2 targets
#   `kci build` builds, and as what artifact type.
# =============================================================================
#
# One entry per line, `<artifact_type> <target>`, separated by whitespace:
#
#   # comment
#   CONDA //src/kci_cli:kci_conda
#
# Blank lines and lines starting `#` are ignored. Each of these is refused,
# naming the file and the line, before any process is started:
#   - a line that is not exactly two fields;
#   - an artifact type outside kci_release_channel's closed set, or one that
#     `kci build` does not build yet (only CONDA has a build rule today);
#   - a target that is not a plain `//package:name` label (no cell prefix,
#     no `...` pattern, no `[sub-target]`, no whitespace);
#   - a target listed twice;
#   - a list with no entries at all: an empty list cannot be told apart from
#     a file that was not read properly, so it is never "nothing to do".
#
# `select_publishable` narrows the list to the `--only` targets; an `--only`
# target that is not on the list is refused.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.pathlib import Path

from kci_release_channel import ARTIFACT_TYPE_CONDA, is_known_artifact_type


struct PublishableEntry(Copyable, Movable):
    """One publishable target and the artifact type it builds.

    Layout: owned values only. No pointer field."""

    var artifact_type: String
    var target: String
    var line: Int

    def __init__(out self, var artifact_type: String, var target: String, line: Int):
        self.artifact_type = artifact_type^
        self.target = target^
        self.line = line


def _refuse(source: String, line: Int, why: String) raises:
    raise Error(
        String("publishable list '")
        + source
        + String("': line ")
        + String(line)
        + String(": ")
        + why
    )


def _fields(line: String) -> List[String]:
    """`line` split on runs of spaces and tabs."""
    var out = List[String]()
    var b = line.as_bytes()
    var start = -1
    for i in range(len(b) + 1):
        var blank = i == len(b) or b[i] == UInt8(32) or b[i] == UInt8(9)
        if blank:
            if start >= 0:
                out.append(String(line[byte = start:i]))
                start = -1
        elif start < 0:
            start = i
    return out^


def label_problem(target: String) -> String:
    """Why `target` is not a plain `//package:name` label, or "" if it is."""
    if not target.startswith(String("//")):
        return String("must start with '//' (no cell prefix)")
    if target.find(String("...")) >= 0:
        return String("is a pattern, not one target")
    if target.find(String("[")) >= 0 or target.find(String("]")) >= 0:
        return String("names a sub-target; list the target itself")
    var colon = target.find(String(":"))
    if colon < 0 or target.rfind(String(":")) != colon:
        return String("must have exactly one ':'")
    if colon == target.byte_length() - 1:
        return String("has no target name after ':'")
    var b = target.as_bytes()
    for i in range(len(b)):
        if b[i] <= UInt8(32) or b[i] == UInt8(127):
            return String("contains a space or control character")
    return String("")


def parse_publishable(text: String, source: String) raises -> List[PublishableEntry]:
    """Parse the publishable list's text (see the file header)."""
    var entries = List[PublishableEntry]()
    var lines = text.split(String("\n"))
    for i in range(len(lines)):
        var n = i + 1
        var line = String(String(lines[i]).strip())
        if line.byte_length() == 0 or line.startswith(String("#")):
            continue
        var f = _fields(line)
        if len(f) != 2:
            _refuse(
                source,
                n,
                String("expected '<artifact_type> <target>', got ")
                + String(len(f))
                + String(" fields"),
            )
        if not is_known_artifact_type(f[0]):
            _refuse(source, n, String("unknown artifact type '") + f[0] + String("'"))
        if f[0] != ARTIFACT_TYPE_CONDA:
            _refuse(
                source,
                n,
                String("kci build does not build ")
                + f[0]
                + String(" artifacts yet (CONDA only)"),
            )
        var problem = label_problem(f[1])
        if problem.byte_length() > 0:
            _refuse(source, n, String("target '") + f[1] + String("' ") + problem)
        for j in range(len(entries)):
            if entries[j].target == f[1]:
                _refuse(
                    source,
                    n,
                    String("target '")
                    + f[1]
                    + String("' is already listed on line ")
                    + String(entries[j].line),
                )
        entries.append(PublishableEntry(f[0].copy(), f[1].copy(), n))
    if len(entries) == 0:
        raise Error(
            String("publishable list '")
            + source
            + String("' lists no targets: an empty list is refused, never")
            + String(" read as nothing to build")
        )
    return entries^


def read_publishable(path: String) raises -> List[PublishableEntry]:
    var text: String
    try:
        text = Path(path).read_text()
    except e:
        raise Error(
            String("publishable list '") + path + String("' cannot be read: ") + String(e)
        )
    return parse_publishable(text, path)


def select_publishable(
    entries: List[PublishableEntry], only: List[String], source: String
) raises -> List[PublishableEntry]:
    """`entries` narrowed to `only`, in list order; all of them when `only`
    is empty. An `only` target not on the list is refused."""
    if len(only) == 0:
        return entries.copy()
    for i in range(len(only)):
        var found = False
        for j in range(len(entries)):
            if entries[j].target == only[i]:
                found = True
        if not found:
            raise Error(
                String("--only ")
                + only[i]
                + String(" is not on the publishable list '")
                + source
                + String("'")
            )
    var out = List[PublishableEntry]()
    for j in range(len(entries)):
        for i in range(len(only)):
            if entries[j].target == only[i]:
                out.append(entries[j].copy())
                break
    return out^
