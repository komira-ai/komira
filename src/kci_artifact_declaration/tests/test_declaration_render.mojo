# =============================================================================
# src/kci_artifact_declaration/tests/test_declaration_render.mojo
#   The argv kci runs for one artifact, `{out_dir}` substitution, the
#   example declarations file, and the two refusals over what a build left
#   (exactly one `manifest.json`; its `name` the declaration's, exactly).
# =============================================================================
#
# `render_build_argv` is pure: these cases compare argv lists exactly and
# run nothing. The example file (staged as test data at its path from the
# cell root) is read and rendered too, so it cannot drift from the code.
# =============================================================================

from std.testing import TestSuite, assert_equal

from kci_artifact_declaration_proto.artifact_declaration import (
    ArtifactDeclaration,
    ArtifactDeclarations,
    BuildSystem,
)
from kci_artifact_declaration import (
    KCI_MANIFEST_NAME,
    OUT_DIR_PLACEHOLDER,
    parse_artifact_declarations,
    placeholders_in,
    read_artifact_declarations,
    render_build_argv,
    require_manifest_name,
    require_one_manifest,
)


def _argv(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(String(x))
    return out^


def _expect_argv(got: List[String], want: List[String]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i])


def _refusal(decls: ArtifactDeclarations, artifact: String, out_dir: String) -> String:
    try:
        _ = render_build_argv(decls, artifact, out_dir)
    except e:
        return String(e)
    return String("<rendered>")


def test_contract_words() raises:
    assert_equal(String(OUT_DIR_PLACEHOLDER), String("{out_dir}"))
    assert_equal(String(KCI_MANIFEST_NAME), String("manifest.json"))


def test_example_file_renders_the_buck2_build() raises:
    var d = read_artifact_declarations(String("src/kci_artifact_declaration/example.textproto"))
    _expect_argv(
        render_build_argv(d, String("komira_encoding"), String("/work/out/komira_encoding")),
        _argv(
            "buck2",
            "build",
            "--config-file",
            "/etc/kci/remote.buckconfig",
            "//src/komira_encoding:komira_encoding_conda[release]",
            "--out",
            "/work/out/komira_encoding",
        ),
    )


def _file() -> String:
    return (
        String("build_systems {\n  name: \"tool\"\n  executable: \"/opt/tool/bin/tool\"\n")
        + String("  args: \"--root={out_dir}/root\"\n  args: \"run\"\n}\n")
        + String("artifacts {\n  name: \"a\"\n  build_system: \"tool\"\n")
        + String("  args: \"x{out_dir}y{out_dir}z\"\n  args: \"{}\"\n  args: \"{k: 1}\"\n")
        + String("  args: \"{out_dir\"\n}\n")
        + String("artifacts {\n  name: \"b\"\n  build_system: \"tool\"\n  args: \"plain\"\n}\n")
    )


def test_substitution_in_build_system_and_artifact_args() raises:
    var d = parse_artifact_declarations(_file(), String("decl.textproto"))
    _expect_argv(
        render_build_argv(d, String("a"), String("/o")),
        _argv("/opt/tool/bin/tool", "--root=/o/root", "run", "x/oy/oz", "{}", "{k: 1}", "{out_dir"),
    )
    # The executable and the order are the build system's; only the
    # artifact's own args differ between artifacts.
    _expect_argv(
        render_build_argv(d, String("b"), String("/p q")),
        _argv("/opt/tool/bin/tool", "--root=/p q/root", "run", "plain"),
    )


def test_render_refusals() raises:
    var d = parse_artifact_declarations(_file(), String("decl.textproto"))
    assert_equal(_refusal(d, String("a"), String("out")), String("out_dir 'out' is not an absolute path"))
    assert_equal(_refusal(d, String("a"), String("")), String("out_dir '' is not an absolute path"))
    assert_equal(_refusal(d, String("nope"), String("/o")), String("no artifact 'nope' is declared"))
    # A value that never went through the validator.
    var systems = List[BuildSystem]()
    var artifacts = List[ArtifactDeclaration]()
    artifacts.append(ArtifactDeclaration(String("a"), String("zz"), _argv("{out_dir}")))
    var raw = ArtifactDeclarations(systems^, artifacts^)
    assert_equal(
        _refusal(raw, String("a"), String("/o")),
        String("artifact 'a': build_system 'zz' is not declared"),
    )


def test_placeholders_in() raises:
    _expect_argv(
        placeholders_in(String("{a}{out_dir}{}{1x}{_b}{c d}{out_dir")),
        _argv("{a}", "{out_dir}", "{_b}"),
    )
    _expect_argv(placeholders_in(String("{{out_dir}}")), _argv("{out_dir}"))


def _one_manifest_refusal(declaration: String, top_level: List[String]) -> String:
    try:
        require_one_manifest(declaration, top_level)
    except e:
        return String(e)
    return String("<accepted>")


def _name_refusal(declaration: String, manifest_name: String) -> String:
    try:
        require_manifest_name(declaration, manifest_name)
    except e:
        return String(e)
    return String("<accepted>")


def test_exactly_one_manifest_at_the_top() raises:
    # The layout of a conda_package's [release] directory.
    assert_equal(
        _one_manifest_refusal(
            String("komira_encoding"),
            _argv("komira_encoding-0.1.0-0.conda", "manifest.json", "metadata.json"),
        ),
        String("<accepted>"),
    )
    var none = String(
        "artifact 'komira_encoding': the build left no manifest.json at the top"
        " of its output directory"
    )
    assert_equal(_one_manifest_refusal(String("komira_encoding"), List[String]()), none)
    # The retired naming is not a manifest any more, and neither is a
    # near-miss or a manifest one level down.
    assert_equal(
        _one_manifest_refusal(
            String("komira_encoding"),
            _argv("komira_encoding.kci_manifest.json", "Manifest.json", "manifest.json ", "pkg/manifest.json"),
        ),
        none,
    )
    assert_equal(
        _one_manifest_refusal(String("a"), _argv("manifest.json", "x", "manifest.json")),
        String(
            "artifact 'a': the output directory lists manifest.json 2 times;"
            " one artifact per declaration means exactly one"
        ),
    )


def test_manifest_name_is_the_declaration_name_exactly() raises:
    assert_equal(_name_refusal(String("komira_encoding"), String("komira_encoding")), String("<accepted>"))
    var wrong = List[String]()
    wrong.append(String("komira_json"))
    wrong.append(String("Komira_encoding"))
    wrong.append(String("komira-encoding"))
    wrong.append(String(" komira_encoding"))
    wrong.append(String("komira_encoding "))
    wrong.append(String("komira_encodin"))
    wrong.append(String("komira_encoding_conda"))
    wrong.append(String(""))
    for i in range(len(wrong)):
        assert_equal(
            _name_refusal(String("komira_encoding"), wrong[i]),
            String("artifact 'komira_encoding': the built manifest's name '")
            + wrong[i]
            + String("' is not the declaration's name (compared exactly)"),
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
