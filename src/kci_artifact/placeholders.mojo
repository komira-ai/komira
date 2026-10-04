# =============================================================================
# kci_artifact/placeholders.mojo -- the placeholders and the rules of a build
#   kci holds every build system to, and the one substitution it performs.
# =============================================================================
#
# For each artifact kci creates an EMPTY output directory and runs
#
#   <executable> <build_system.args...> <artifact.args...>
#
# with every `{out_dir}` in any arg replaced by that directory's absolute
# path. ONE ARTIFACT PER ENTRY: the build leaves, at the top of that
# directory, EXACTLY ONE kci artifact manifest (//src/kci_artifact_manifest's
# format) named `KCI_MANIFEST_NAME` (`manifest.json`), plus the files it
# names. That is the layout of a `conda_package`'s `[release]` directory
# (`<name>-<version>-0.conda`, `manifest.json`, `metadata.json`). kci ships
# exactly what that manifest describes. Refused: a non-zero exit;
# `require_one_manifest`: no `manifest.json` at the top, or a listing naming
# it more than once (a directory cannot hold two, so that arm guards a
# listing that is not one directory's top level); `require_manifest_name`:
# a manifest whose `name` is not the artifact's, compared EXACTLY (byte
# for byte; no case folding, no trimming, no `-`/`_` equivalence).
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

comptime KCI_MANIFEST_NAME: String = "manifest.json"
"""The one kci artifact manifest a build leaves at the top of `{out_dir}`."""


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


def require_one_manifest(artifact: String, top_level: List[String]) raises:
    """Refuse unless `top_level` (the names at the top of the artifact's
    output directory) holds `KCI_MANIFEST_NAME` exactly once."""
    var n = 0
    for i in range(len(top_level)):
        if top_level[i] == KCI_MANIFEST_NAME:
            n += 1
    if n == 0:
        raise Error(
            String("artifact '")
            + artifact
            + String("': the build left no ")
            + String(KCI_MANIFEST_NAME)
            + String(" at the top of its output directory")
        )
    if n > 1:
        raise Error(
            String("artifact '")
            + artifact
            + String("': the output directory lists ")
            + String(KCI_MANIFEST_NAME)
            + String(" ")
            + String(n)
            + String(" times; one artifact per entry means exactly one")
        )


def require_manifest_name(artifact: String, manifest_name: String) raises:
    """Refuse unless the built manifest's `name` equals the artifact's
    name EXACTLY (byte for byte)."""
    if manifest_name != artifact:
        raise Error(
            String("artifact '")
            + artifact
            + String("': the built manifest's name '")
            + manifest_name
            + String("' is not the artifact's name (compared exactly)")
        )
