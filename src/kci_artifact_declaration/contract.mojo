# =============================================================================
# kci_artifact_declaration/contract.mojo -- the words of the build contract
#   kci holds every build system to, and the one substitution it performs.
# =============================================================================
#
# For each artifact kci creates an EMPTY output directory and runs
#
#   <executable> <build_system.args...> <artifact.args...>
#
# with every `{out_dir}` in any arg replaced by that directory's absolute
# path. The build leaves the artifact files there, plus one kci artifact
# manifest per artifact (//src/kci_artifact_manifest's format), each named
# `<anything>` + `KCI_MANIFEST_SUFFIX`. kci ships exactly what those
# manifests describe; a non-zero exit, or no manifest, is a refusal.
#
# A placeholder is `{<identifier>}`, the identifier `[A-Za-z_][A-Za-z0-9_]*`.
# `{out_dir}` is the only one; a brace that does not enclose an identifier
# (`{}`, `{"k": 1}`) is literal text and passed through unchanged. There is
# no escape: an arg cannot carry a literal `{out_dir}`.
#
# Pure functions over owned values; no pointer, no process.
# =============================================================================

comptime OUT_DIR_PLACEHOLDER: String = "{out_dir}"
"""The one placeholder: replaced by the output directory's absolute path."""

comptime KCI_MANIFEST_SUFFIX: String = ".kci_manifest.json"
"""How kci finds the manifests a build left in its output directory."""


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
        if Int(b[i]) == 123 and i + 1 < n and _ident_start(Int(b[i + 1])):
            var j = i + 2
            while j < n and _ident(Int(b[j])):
                j += 1
            if j < n and Int(b[j]) == 125:
                out.append(String(arg[byte = i : j + 1]))
                i = j + 1
                continue
        i += 1
    return out^


def substitute_out_dir(arg: String, out_dir: String) -> String:
    """`arg` with every `{out_dir}` replaced by `out_dir`."""
    return arg.replace(String(OUT_DIR_PLACEHOLDER), out_dir)
