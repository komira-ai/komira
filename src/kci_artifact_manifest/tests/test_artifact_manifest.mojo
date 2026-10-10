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
    # `metadata` is required on a CONDA manifest, so the fixture carries it,
    # last, where the renderer writes it; `extra` goes in before it.
    return (
        String('{"format":"kci.artifact_manifest","schema_version":1,')
        + String('"artifact_type":"CONDA","name":"example-pkg","version":"1.2.3",')
        + String('"platform":"linux-x86_64",')
        + String('"subdir":"linux-64","file":"linux-64/example-pkg-1.2.3-h0_0.conda",')
        + String('"sha256":"')
        + String(_HASH)
        + String('"')
        + extra
        + String(',"metadata":"metadata.json"}')
    )


def _python() -> String:
    return (
        String('{"format":"kci.artifact_manifest","schema_version":1,')
        + String('"artifact_type":"PYTHON","name":"example_pkg","version":"1.2.3","platform":"noarch",')
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
    assert_equal(m.metadata, String("metadata.json"))
    assert_equal(m.metadata_path, String("out/metadata.json"))


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
        _refusal(_conda().replace(String('"metadata.json"'), String('"sub/metadata.json"'))),
        String(
            "artifact manifest 'out/m.json': a CONDA 'metadata' is a file name"
            " next to the manifest, not a path"
        ),
    )
    assert_equal(
        _refusal(_conda().replace(String('"metadata.json"'), String('".."'))),
        String(
            "artifact manifest 'out/m.json': a CONDA 'metadata' is a file name"
            " next to the manifest, not a path"
        ),
    )
    assert_equal(
        _refusal(_conda().replace(String('"metadata.json"'), String('"."'))),
        String(
            "artifact manifest 'out/m.json': a CONDA 'metadata' is a file name"
            " next to the manifest, not a path"
        ),
    )
    assert_equal(
        _refusal(_conda().replace(String('"metadata.json"'), String('""'))),
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
            " published by the PUBLISH step (CONDA or PYTHON)"
        ),
    )
    assert_equal(
        _refusal(String("[1]")),
        String("artifact manifest 'out/m.json': not a JSON object"),
    )
    assert_true(_refusal(String("{")).startswith(String("artifact manifest 'out/m.json': not JSON: ")))


def test_format_and_major_are_read_first() raises:
    assert_equal(
        _refusal(_conda().replace(String('"schema_version":1'), String('"schema_version":2'))),
        String(
            "artifact manifest 'out/m.json': schema_version 2 needs a newer kci"
            " (this kci reads kci.artifact_manifest up to major 1)"
        ),
    )
    assert_equal(
        _refusal(_conda().replace(String('"format":"kci.artifact_manifest",'), String(""))),
        String(
            "artifact manifest 'out/m.json': no 'format' (a kci.artifact_manifest document"
            " names its format)"
        ),
    )
    assert_equal(
        _refusal(_conda().replace(String('"schema_version":1,'), String(""))),
        String("artifact manifest 'out/m.json': no 'schema_version'"),
    )
    assert_equal(
        _refusal(_conda().replace(String('"kci.artifact_manifest"'), String('"kci.result"'))),
        String("artifact manifest 'out/m.json': format 'kci.result' is not 'kci.artifact_manifest'"),
    )
    # A major-2 manifest is refused as such even when it carries a key this
    # kci does not know.
    assert_true(
        _refusal(
            _conda(String(',"provenance":"x"')).replace(String('"schema_version":1'), String('"schema_version":2'))
        ).find(String("needs a newer kci")) >= 0
    )


def test_an_unknown_key_of_a_known_major_is_ignored_and_listed() raises:
    var m = parse_artifact_manifest(_conda(String(',"provenance":"x","later":1')), String("out/m.json"))
    assert_equal(len(m.ignored_keys), 2)
    assert_equal(m.ignored_keys[0], String("provenance"))
    assert_equal(m.ignored_keys[1], String("later"))
    # the renderer writes only what it knows
    assert_equal(render_artifact_manifest(m), _conda() + String("\n"))


def test_platform() raises:
    var m = parse_artifact_manifest(_conda(), String("out/m.json"))
    assert_equal(m.platform, String("linux-x86_64"))
    assert_equal(parse_artifact_manifest(_python(), String("out/m.json")).platform, String("noarch"))
    assert_equal(
        _refusal(_conda().replace(String('"platform":"linux-x86_64",'), String(""))),
        String("artifact manifest 'out/m.json': missing 'platform'"),
    )
    assert_equal(
        _refusal(_conda().replace(String('"linux-x86_64"'), String('"linux-64"'))),
        String(
            "artifact manifest 'out/m.json': platform 'linux-64' is not one of:"
            " linux-x86_64 darwin-arm64 linux-arm64 noarch"
        ),
    )
    assert_equal(
        _refusal(_conda().replace(String('"linux-x86_64"'), String('"darwin-arm64"'))),
        String(
            "artifact manifest 'out/m.json': platform 'darwin-arm64' is not released:"
            " kci releases linux-x86_64 only for now; darwin-arm64 is reserved"
        ),
    )
    # a CONDA subdir is its platform's conda subdir
    assert_equal(
        _refusal(_conda().replace(String('"linux-x86_64"'), String('"noarch"'))),
        String("artifact manifest 'out/m.json': subdir 'linux-64' is not platform noarch's conda subdir 'noarch'"),
    )


def test_render_round_trips_conda() raises:
    var m = parse_artifact_manifest(_conda(), String("out/m.json"))
    var text = render_artifact_manifest(m)
    assert_equal(text, _conda() + String("\n"))
    var back = parse_artifact_manifest(text, String("out/m.json"))
    assert_equal(back.file_path, m.file_path)
    assert_equal(back.subdir, m.subdir)
    assert_equal(back.sha256_hex, m.sha256_hex)


def test_conda_metadata_is_required_and_found_next_to_the_manifest() raises:
    # Without the key a CONDA manifest is refused, naming the manifest and
    # the key, like a PYTHON manifest without it.
    assert_equal(
        _refusal(_conda().replace(String(',"metadata":"metadata.json"'), String(""))),
        String("artifact manifest 'out/m.json': a CONDA artifact needs 'metadata'"),
    )
    # With it, the name resolves in the manifest's own directory, and the
    # renderer writes it back last, in the header's key order.
    var text = _conda()
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
    m.platform = String("linux-x86_64")
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


def test_a_bare_source_resolves_against_the_current_directory() raises:
    # A manifest named with no directory ("m.json") has no directory to
    # resolve against: `file` and `metadata` stay as written, not re-rooted
    # under "/" or "./".
    var m = parse_artifact_manifest(_conda(), String("m.json"))
    assert_equal(m.file_path, String("linux-64/example-pkg-1.2.3-h0_0.conda"))
    assert_equal(m.metadata_path, String("metadata.json"))
    var p = parse_artifact_manifest(_python(), String("m.json"))
    assert_equal(p.file_path, String("example_pkg-1.2.3-py3-none-any.whl"))
    assert_equal(p.metadata_path, String("METADATA"))


def test_python_metadata_is_required() raises:
    # Refused by its own check, naming the artifact type, not by the generic
    # "'metadata' is not a string" a missing key would otherwise give.
    assert_equal(
        _refusal(_python().replace(String(',"metadata":"METADATA"'), String(""))),
        String("artifact manifest 'out/m.json': a PYTHON artifact needs 'metadata'"),
    )


def test_is_sha256_hex() raises:
    assert_true(is_sha256_hex(String(_HASH)))
    assert_false(is_sha256_hex(String(String(_HASH)[byte = 1 :])))
    assert_false(is_sha256_hex(String(_HASH).replace(String("a"), String("g"))))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
