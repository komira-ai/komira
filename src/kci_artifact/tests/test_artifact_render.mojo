# =============================================================================
# src/kci_artifact/tests/test_artifact_render.mojo
#   The argv kci runs for one artifact: the six placeholders substituted in
#   one pass, `{out_dir}` derived as `<release_dir>/<artifact>`, the stamp's
#   own refusals, the example artifacts file (two libraries' build system
#   plus the metapackage last), and the two refusals over what a build left
#   (exactly one `manifest.json`; its `name` the artifact's, exactly).
# =============================================================================
#
# `render_build_argv` is pure: these cases compare argv lists exactly and
# run nothing. The example file (staged as test data at its path from the
# cell root) is read and rendered too, so it cannot drift from the code.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from kci_artifact_proto.artifact import (
    Artifact,
    Artifacts,
    BuildSystem,
    Check,
)
from kci_artifact import (
    BUILD_NUMBER_PLACEHOLDER,
    KCI_MANIFEST_NAME,
    OUT_DIR_PLACEHOLDER,
    PLATFORM_PLACEHOLDER,
    RELEASE_DIR_PLACEHOLDER,
    REVISION_ID_PLACEHOLDER,
    SOURCE_COMMIT_PLACEHOLDER,
    TIMESTAMP_MS_PLACEHOLDER,
    ReleaseStamp,
    known_placeholders,
    parse_artifacts,
    placeholders_in,
    read_artifacts,
    render_build_argv,
    require_full_commit_id,
    require_manifest_name,
    require_one_manifest,
)

comptime _REV = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
comptime _SRC = "f0e1d2c3b4a5968778695a4b3c2d1e0f12345678"


def _parse(text: String) raises -> Artifacts:
    """`parse_artifacts` over `text` with `schema_version: 1`
    prepended on its FIRST line, so no line number a refusal names moves."""
    return parse_artifacts(String("schema_version: 1 ") + text, String("artifacts.textproto"))


def _stamp() raises -> ReleaseStamp:
    return ReleaseStamp(String(_REV), String(_SRC), 154, 1790994309000)


def _argv(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(String(x))
    return out^


def _expect_argv(got: List[String], want: List[String]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i])


def _refusal(arts: Artifacts, artifact: String, release_dir: String) raises -> String:
    try:
        _ = render_build_argv(arts, artifact, release_dir, String("linux-x86_64"), _stamp())
    except e:
        return String(e)
    return String("<rendered>")


def test_placeholder_words() raises:
    assert_equal(String(OUT_DIR_PLACEHOLDER), String("{out_dir}"))
    assert_equal(String(RELEASE_DIR_PLACEHOLDER), String("{release_dir}"))
    assert_equal(String(PLATFORM_PLACEHOLDER), String("{platform}"))
    assert_equal(String(REVISION_ID_PLACEHOLDER), String("{revision_id}"))
    assert_equal(String(SOURCE_COMMIT_PLACEHOLDER), String("{source_commit}"))
    assert_equal(String(BUILD_NUMBER_PLACEHOLDER), String("{build_number}"))
    assert_equal(String(TIMESTAMP_MS_PLACEHOLDER), String("{timestamp_ms}"))
    _expect_argv(
        known_placeholders(),
        _argv(
            "{out_dir}", "{release_dir}", "{platform}", "{revision_id}", "{source_commit}",
            "{build_number}", "{timestamp_ms}",
        ),
    )
    assert_equal(String(KCI_MANIFEST_NAME), String("manifest.json"))


def test_example_file_renders_the_stamped_library_then_the_metapackage() raises:
    var d = read_artifacts(String("src/kci_artifact/example.textproto"))
    # File order is build order: the library, then the metapackage last.
    assert_equal(len(d.artifacts), 2)
    assert_equal(d.artifacts[0].name, String("komira_encoding"))
    assert_equal(d.artifacts[1].name, String("komira_all"))
    _expect_argv(
        render_build_argv(d, String("komira_encoding"), String("/work/rel"), String("linux-x86_64"), _stamp()),
        _argv(
            "buck2",
            "build",
            "-c",
            "komira.package_stamp=154",
            "-c",
            "komira.package_commit=f0e1d2c3b4a5968778695a4b3c2d1e0f12345678",
            "-c",
            "komira.package_timestamp_ms=1790994309000",
            "//src/komira_encoding:komira_encoding_conda[release]",
            "--out",
            "/work/rel/komira_encoding",
        ),
    )
    _expect_argv(
        render_build_argv(d, String("komira_all"), String("/work/rel"), String("linux-x86_64"), _stamp()),
        _argv(
            "buck2",
            "run",
            "//tools/build/package:komira_pack",
            "--",
            "conda-meta",
            "--name",
            "komira_all",
            "--member-manifest",
            "/work/rel/komira_encoding/manifest.json",
            "--license",
            "Apache-2.0",
            "--summary",
            "Every komira library of one release.",
            "--home",
            "https://github.com/komira-ai/komira",
            "--extra-file",
            "info/licenses/LICENSE=LICENSE",
            "--label",
            "kci run a1b2c3d4e5f60718293a4b5c6d7e8f9012345678",
            "--out-dir",
            "/work/rel/komira_all",
        ),
    )


def _file() -> String:
    return (
        String("build_systems {\n  name: \"tool\"\n  executable: \"/opt/tool/bin/tool\"\n")
        + String("  args: \"--root={out_dir}/root\"\n  args: \"run\"\n}\n")
        + String("artifacts {\n  name: \"a\"\n  build_system: \"tool\"\n")
        + String("  args: \"x{out_dir}y{out_dir}z\"\n  args: \"{}\"\n  args: \"{k: 1}\"\n")
        + String("  args: \"{out_dir\"\n}\n")
        + String("artifacts {\n  name: \"b\"\n  build_system: \"tool\"\n  args: \"plain\"\n")
        + String("  args: \"{release_dir}|{platform}|{revision_id}|{source_commit}|{build_number}|{timestamp_ms}\"\n")
        + String("  args: \"{{build_number}}\"\n}\n")
    )


def test_substitution_in_build_system_and_artifact_args() raises:
    var d = _parse(_file())
    _expect_argv(
        render_build_argv(d, String("a"), String("/r"), String("linux-x86_64"), _stamp()),
        _argv("/opt/tool/bin/tool", "--root=/r/a/root", "run", "x/r/ay/r/az", "{}", "{k: 1}", "{out_dir"),
    )
    # The executable and the order are the build system's; only the
    # artifact's own args differ between artifacts. Every stamp value lands
    # as written; a doubled brace keeps its outer braces.
    _expect_argv(
        render_build_argv(d, String("b"), String("/p q"), String("linux-x86_64"), _stamp()),
        _argv(
            "/opt/tool/bin/tool",
            "--root=/p q/b/root",
            "run",
            "plain",
            "/p q|linux-x86_64|a1b2c3d4e5f60718293a4b5c6d7e8f9012345678|f0e1d2c3b4a5968778695a4b3c2d1e0f12345678"
            "|154|1790994309000",
            "{154}",
        ),
    )


def test_substitution_is_one_pass() raises:
    # A release directory whose own name holds placeholders: substituted
    # once, never again.
    var d = _parse(_file())
    _expect_argv(
        render_build_argv(d, String("b"), String("/x{out_dir}{build_number}"), String("linux-x86_64"), _stamp()),
        _argv(
            "/opt/tool/bin/tool",
            "--root=/x{out_dir}{build_number}/b/root",
            "run",
            "plain",
            "/x{out_dir}{build_number}|linux-x86_64|a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
            "|f0e1d2c3b4a5968778695a4b3c2d1e0f12345678|154|1790994309000",
            "{154}",
        ),
    )


def test_render_refusals() raises:
    var d = _parse(_file())
    var tail = String("' is not an absolute path (other than '/', with no trailing '/')")
    assert_equal(_refusal(d, String("a"), String("out")), String("release_dir 'out") + tail)
    assert_equal(_refusal(d, String("a"), String("")), String("release_dir '") + tail)
    assert_equal(_refusal(d, String("a"), String("/")), String("release_dir '/") + tail)
    assert_equal(_refusal(d, String("a"), String("/r/")), String("release_dir '/r/") + tail)
    assert_equal(_refusal(d, String("nope"), String("/o")), String("no artifact 'nope' is declared"))
    # A platform kci does not release is refused before anything is rendered.
    var refused = String("<rendered>")
    try:
        _ = render_build_argv(d, String("a"), String("/o"), String("darwin-arm64"), _stamp())
    except e:
        refused = String(e)
    assert_equal(
        refused,
        String("platform 'darwin-arm64' is not released: kci releases linux-x86_64 only for now; darwin-arm64 is reserved"),
    )
    refused = String("<rendered>")
    try:
        _ = render_build_argv(d, String("a"), String("/o"), String("noarch"), _stamp())
    except e:
        refused = String(e)
    assert_true(refused.find(String("never a release's")) >= 0, refused)
    # A value that never went through the validator.
    var systems = List[BuildSystem]()
    var artifacts = List[Artifact]()
    artifacts.append(Artifact(String("a"), String("zz"), _argv("{out_dir}"), List[String]()))
    var raw = Artifacts(systems^, artifacts^, Int32(1), List[Check]())
    assert_equal(
        _refusal(raw, String("a"), String("/o")),
        String("artifact 'a': build_system 'zz' is not declared"),
    )
    # An unknown placeholder in a value that never went through the
    # validator is refused, not passed through.
    var systems2 = List[BuildSystem]()
    systems2.append(BuildSystem(String("t"), String("t"), List[String](), None, None))
    var artifacts2 = List[Artifact]()
    artifacts2.append(Artifact(String("a"), String("t"), _argv("{out_dir}", "{nope}"), List[String]()))
    var raw2 = Artifacts(systems2^, artifacts2^, Int32(1), List[Check]())
    assert_equal(_refusal(raw2, String("a"), String("/o")), String("unknown placeholder '{nope}'"))


def _stamp_refusal(rev: String, src: String, n: Int, ts: Int) -> String:
    try:
        _ = ReleaseStamp(rev, src, n, ts)
    except e:
        return String(e)
    return String("<accepted>")


def test_stamp_refusals() raises:
    assert_equal(_stamp_refusal(String(_REV), String(_SRC), 1, 1), String("<accepted>"))
    var bad = List[String]()
    bad.append(String("a1b2c3d"))  # abbreviated
    bad.append(String(String(_REV)[byte = 0:39]))  # 39
    bad.append(String(_REV) + String("0"))  # 41
    bad.append(String("A1B2C3D4E5F60718293A4B5C6D7E8F9012345678"))  # upper case
    bad.append(String("g1b2c3d4e5f60718293a4b5c6d7e8f9012345678"))  # not hex
    bad.append(String(""))
    for i in range(len(bad)):
        var why = (
            String("' is not a full commit id (exactly 40 lowercase hex digits; an")
            + String(" abbreviated id is refused)")
        )
        assert_equal(
            _stamp_refusal(bad[i], String(_SRC), 1, 1), String("revision_id '") + bad[i] + why
        )
        assert_equal(
            _stamp_refusal(String(_REV), bad[i], 1, 1), String("source_commit '") + bad[i] + why
        )
    assert_equal(_stamp_refusal(String(_REV), String(_SRC), 0, 1), String("build_number 0 is not positive"))
    assert_equal(_stamp_refusal(String(_REV), String(_SRC), -3, 1), String("build_number -3 is not positive"))
    assert_equal(_stamp_refusal(String(_REV), String(_SRC), 1, 0), String("timestamp_ms 0 is not positive"))


def test_full_commit_id() raises:
    require_full_commit_id(String("x"), String(_SRC))
    try:
        require_full_commit_id(String("--revision-id"), String("f0e1d2c"))
        assert_equal(String("accepted"), String("refused"))
    except e:
        assert_equal(
            String(e),
            String(
                "--revision-id 'f0e1d2c' is not a full commit id (exactly 40 lowercase hex"
                " digits; an abbreviated id is refused)"
            ),
        )


def test_placeholders_in() raises:
    _expect_argv(
        placeholders_in(String("{a}{out_dir}{}{1x}{_b}{c d}{out_dir")),
        _argv("{a}", "{out_dir}", "{_b}"),
    )
    _expect_argv(placeholders_in(String("{{out_dir}}")), _argv("{out_dir}"))


def _one_manifest_refusal(artifact: String, top_level: List[String]) -> String:
    try:
        require_one_manifest(artifact, top_level)
    except e:
        return String(e)
    return String("<accepted>")


def _name_refusal(artifact: String, manifest_name: String) -> String:
    try:
        require_manifest_name(artifact, manifest_name)
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
            " one artifact per entry means exactly one"
        ),
    )


def test_manifest_name_is_the_artifact_name_exactly() raises:
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
            + String("' is not the artifact's name (compared exactly)"),
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
