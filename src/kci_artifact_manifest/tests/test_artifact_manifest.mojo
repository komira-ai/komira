# =============================================================================
# src/kci_artifact_manifest/tests/test_artifact_manifest.mojo
#   Parse, resolve, render and refuse artifact manifests, in memory.
# =============================================================================
#
# A control case parses each well-formed manifest, so every refusal below is
# caused by its one change. The render cases parse what was rendered and
# compare every field, so a key the renderer drops or renames is caught.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_artifact_manifest import (
    ArtifactManifest,
    is_sha256_hex,
    parse_artifact_manifest,
    render_artifact_manifest,
)

comptime _HASH = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"


def _conda(extra: String = String("")) -> String:
    return (
        String('{"artifact_type":"CONDA","name":"example-pkg","version":"1.2.3",')
        + String('"subdir":"linux-64","file":"linux-64/example-pkg-1.2.3-h0_0.conda",')
        + String('"sha256":"')
        + String(_HASH)
        + String('"')
        + extra
        + String("}")
    )


def _python() -> String:
    return (
        String('{"artifact_type":"PYTHON","name":"example_pkg","version":"1.2.3",')
        + String('"file":"example_pkg-1.2.3-py3-none-any.whl","sha256":"')
        + String(_HASH)
        + String('","metadata":"METADATA"}')
    )


def _refusal(text: String) -> String:
    try:
        _ = parse_artifact_manifest(text, String("out/m.json"))
    except e:
        return String(e)
    return String("<parsed>")


def test_control_conda_parses_and_resolves() raises:
    var m = parse_artifact_manifest(_conda(), String("out/m.json"))
    assert_equal(m.artifact_type, String("CONDA"))
    assert_equal(m.name, String("example-pkg"))
    assert_equal(m.version, String("1.2.3"))
    assert_equal(m.subdir, String("linux-64"))
    assert_equal(m.file, String("linux-64/example-pkg-1.2.3-h0_0.conda"))
    assert_equal(m.file_path, String("out/linux-64/example-pkg-1.2.3-h0_0.conda"))
    assert_equal(m.file_name(), String("example-pkg-1.2.3-h0_0.conda"))
    assert_equal(m.sha256_hex, String(_HASH))


def test_control_python_parses_and_resolves() raises:
    var m = parse_artifact_manifest(_python(), String("/abs/dir/m.json"))
    assert_equal(m.file_path, String("/abs/dir/example_pkg-1.2.3-py3-none-any.whl"))
    assert_equal(m.metadata_path, String("/abs/dir/METADATA"))


def test_an_absolute_file_is_not_re_rooted() raises:
    var text = _conda().replace(
        String('"linux-64/example-pkg'), String('"/pkgs/linux-64/example-pkg')
    )
    var m = parse_artifact_manifest(text, String("out/m.json"))
    assert_equal(m.file_path, String("/pkgs/linux-64/example-pkg-1.2.3-h0_0.conda"))


def test_refusals_name_the_manifest_and_the_key() raises:
    assert_equal(
        _refusal(_conda(String(',"extra":"x"'))),
        String("artifact manifest 'out/m.json': unknown key 'extra'"),
    )
    assert_equal(
        _refusal(_conda(String(',"name":"again"'))),
        String("artifact manifest 'out/m.json': 'name' is given twice"),
    )
    assert_equal(
        _refusal(_conda().replace(String('"version":"1.2.3",'), String(""))),
        String("artifact manifest 'out/m.json': missing 'version'"),
    )
    assert_equal(
        _refusal(_conda().replace(String('"1.2.3"'), String("123"))),
        String("artifact manifest 'out/m.json': 'version' is not a string"),
    )
    assert_equal(
        _refusal(_conda().replace(String('"example-pkg"'), String('" "'))),
        String("artifact manifest 'out/m.json': 'name' is EMPTY"),
    )
    assert_equal(
        _refusal(_conda().replace(String(_HASH), String(_HASH).upper())),
        String(
            "artifact manifest 'out/m.json': 'sha256' is not 64 lowercase hex characters"
        ),
    )
    assert_equal(
        _refusal(_conda().replace(String('"subdir":"linux-64",'), String(""))),
        String("artifact manifest 'out/m.json': a CONDA artifact needs 'subdir'"),
    )
    assert_equal(
        _refusal(_conda().replace(String('"linux-64",'), String('"noarch",'))),
        String(
            "artifact manifest 'out/m.json': subdir 'noarch' is not published:"
            " a compiled package names its platform subdir"
        ),
    )
    assert_equal(
        _refusal(_conda().replace(String("h0_0.conda"), String("h0_0.tar.bz2"))),
        String("artifact manifest 'out/m.json': a CONDA 'file' must end in .conda"),
    )
    assert_equal(
        _refusal(_conda(String(',"metadata":"sub/metadata.json"'))),
        String(
            "artifact manifest 'out/m.json': a CONDA 'metadata' is a file name"
            " next to the manifest, not a path"
        ),
    )
    assert_equal(
        _refusal(_conda(String(',"metadata":".."'))),
        String(
            "artifact manifest 'out/m.json': a CONDA 'metadata' is a file name"
            " next to the manifest, not a path"
        ),
    )
    assert_equal(
        _refusal(_conda(String(',"metadata":""'))),
        String("artifact manifest 'out/m.json': 'metadata' is EMPTY"),
    )
    assert_equal(
        _refusal(_python().replace(String('"file"'), String('"subdir":"x","file"'))),
        String("artifact manifest 'out/m.json': 'subdir' belongs to a CONDA artifact"),
    )
    assert_equal(
        _refusal(_conda().replace(String('"CONDA"'), String('"OCI"'))),
        String(
            "artifact manifest 'out/m.json': artifact_type 'OCI' is not"
            " published by kci publish (CONDA or PYTHON)"
        ),
    )
    assert_equal(
        _refusal(String("[1]")),
        String("artifact manifest 'out/m.json': not a JSON object"),
    )
    assert_true(_refusal(String("{")).startswith(String("artifact manifest 'out/m.json': not JSON: ")))


def test_render_round_trips_conda() raises:
    var m = parse_artifact_manifest(_conda(), String("out/m.json"))
    var text = render_artifact_manifest(m)
    assert_equal(text, _conda() + String("\n"))
    var back = parse_artifact_manifest(text, String("out/m.json"))
    assert_equal(back.file_path, m.file_path)
    assert_equal(back.subdir, m.subdir)
    assert_equal(back.sha256_hex, m.sha256_hex)


def test_conda_metadata_is_optional_and_found_next_to_the_manifest() raises:
    # Without the key a CONDA manifest parses as before, both fields empty.
    var bare = parse_artifact_manifest(_conda(), String("out/m.json"))
    assert_equal(bare.metadata, String(""))
    assert_equal(bare.metadata_path, String(""))
    # With it, the name resolves in the manifest's own directory, and the
    # renderer writes it back last, in the header's key order.
    var text = _conda(String(',"metadata":"metadata.json"'))
    var m = parse_artifact_manifest(text, String("out/m.json"))
    assert_equal(m.metadata, String("metadata.json"))
    assert_equal(m.metadata_path, String("out/metadata.json"))
    var rendered = render_artifact_manifest(m)
    assert_equal(rendered, text + String("\n"))
    var back = parse_artifact_manifest(rendered, String("/abs/dir/m.json"))
    assert_equal(back.metadata_path, String("/abs/dir/metadata.json"))


def test_render_round_trips_python() raises:
    var m = parse_artifact_manifest(_python(), String("out/m.json"))
    var back = parse_artifact_manifest(render_artifact_manifest(m), String("out/m.json"))
    assert_equal(back.metadata, String("METADATA"))
    assert_equal(back.subdir, String(""))
    assert_equal(back.file, m.file)


def test_render_refuses_what_the_parser_would() raises:
    var m = ArtifactManifest(String("out/m.json"))
    m.artifact_type = String("CONDA")
    m.name = String("example-pkg")
    m.version = String("1.2.3")
    m.subdir = String("linux-64")
    m.file = String("linux-64/example-pkg-1.2.3-h0_0.conda")
    m.sha256_hex = String("not-a-hash")
    var refused = False
    try:
        _ = render_artifact_manifest(m)
    except e:
        refused = String(e).find(String("'sha256'")) >= 0
    assert_true(refused)


def test_file_name_reads_file_path_when_file_is_unset() raises:
    # kci_publish's plan tests build a manifest by hand and set only
    # `file_path`; the registry name must still come out of it.
    var m = ArtifactManifest(String("hand"))
    m.artifact_type = String("CONDA")
    m.file_path = String("/pkgs/linux-64/example-pkg-1.2.3-h0_0.conda")
    assert_equal(m.file_name(), String("example-pkg-1.2.3-h0_0.conda"))
    var bare = ArtifactManifest(String("hand"))
    bare.file_path = String("example_pkg-1.2.3-py3-none-any.whl")
    assert_equal(bare.file_name(), String("example_pkg-1.2.3-py3-none-any.whl"))


def test_is_sha256_hex() raises:
    assert_true(is_sha256_hex(String(_HASH)))
    assert_false(is_sha256_hex(String(String(_HASH)[byte = 1 :])))
    assert_false(is_sha256_hex(String(_HASH).replace(String("a"), String("g"))))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
