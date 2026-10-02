# =============================================================================
# src/kci_publish/tests/test_publish_manifest.mojo -- the artifact manifest
#   and the approved-names file.
# =============================================================================
#
# ROWS
#   (1) a CONDA and a PYTHON manifest parse; relative paths resolve against
#       the manifest's directory, absolute ones stay;
#   (2) every manifest refusal names the manifest and the key: not JSON, not
#       an object, an unknown key, a missing key, a non-string, an empty
#       value, a sha256 that is not 64 lowercase hex, a key of the other
#       artifact type, a missing per-type key, `noarch`, an unknown type;
#   (3) the approved-names file: comments, blanks and surrounding space
#       ignored; an empty file approves nothing; a bad name is refused with
#       its line number.
#
# Hermetic: parses strings; no file read, no network.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from kci_pkg_upload import SUBSTRATE_PREFIX_DEV_CONDA, SUBSTRATE_PUBLIC_PYPI

from kci_publish import parse_approved_names, parse_artifact_manifest


comptime _SHA: String = "d92ee691780d0dbc4dd45de1287d8980462041de9bd2fe3d7f8b89044a18cf52"


def _conda(extra: String = String("")) -> String:
    return (
        String('{"artifact_type": "CONDA", "name": "example-pkg", "version": "1.2.3",')
        + String(' "subdir": "linux-64", "file": "out/example-pkg-1.2.3-h0_0.conda",')
        + String(' "sha256": "')
        + String(_SHA)
        + String('"')
        + extra
        + String("}")
    )


def test_conda_and_python_parse() raises:
    var m = parse_artifact_manifest(_conda(), String("build/m/linux-64.json"))
    assert_equal(m.artifact_type, String("CONDA"))
    assert_equal(m.name, String("example-pkg"))
    assert_equal(m.version, String("1.2.3"))
    assert_equal(m.subdir, String("linux-64"))
    assert_equal(m.file_path, String("build/m/out/example-pkg-1.2.3-h0_0.conda"))
    assert_equal(m.file_name(), String("example-pkg-1.2.3-h0_0.conda"))
    assert_equal(m.sha256_hex, String(_SHA))
    assert_equal(m.metadata_path, String(""))
    var bare = parse_artifact_manifest(_conda(), String("m.json"))
    assert_equal(bare.file_path, String("out/example-pkg-1.2.3-h0_0.conda"))
    var p = parse_artifact_manifest(
        String('{"artifact_type": "PYTHON", "name": "example_pkg", "version": "1.2.3",')
        + String(' "file": "/abs/example_pkg-1.2.3-py3-none-any.whl", "sha256": "')
        + String(_SHA)
        + String('", "metadata": "METADATA"}'),
        String("dist/wheel.json"),
    )
    assert_equal(p.artifact_type, String("PYTHON"))
    assert_equal(p.file_path, String("/abs/example_pkg-1.2.3-py3-none-any.whl"))
    assert_equal(p.metadata_path, String("dist/METADATA"))
    assert_equal(p.subdir, String(""))


def _refusal(text: String) -> String:
    try:
        _ = parse_artifact_manifest(text, String("m.json"))
    except e:
        return String(e)
    return String("")


def _assert_refused(text: String, needle: String) raises:
    var why = _refusal(text)
    assert_true(why.byte_length() > 0, String("not refused: ") + text)
    assert_true(why.find(String("artifact manifest 'm.json'")) >= 0, why)
    assert_true(why.find(needle) >= 0, why)


def test_manifest_refusals() raises:
    _assert_refused(String("{"), String("not JSON"))
    _assert_refused(String("[]"), String("not a JSON object"))
    _assert_refused(_conda(String(', "force": "true"')), String("unknown key 'force'"))
    _assert_refused(
        String('{"artifact_type": "CONDA", "name": "x", "version": "1", "file": "f"}'),
        String("missing 'sha256'"),
    )
    _assert_refused(
        String('{"artifact_type": "CONDA", "name": 7, "version": "1", "file": "f",')
        + String(' "sha256": "')
        + String(_SHA)
        + String('", "subdir": "linux-64"}'),
        String("'name' is not a string"),
    )
    _assert_refused(
        String('{"artifact_type": "CONDA", "name": " ", "version": "1", "file": "f",')
        + String(' "sha256": "')
        + String(_SHA)
        + String('", "subdir": "linux-64"}'),
        String("'name' is EMPTY"),
    )
    _assert_refused(
        String('{"artifact_type": "CONDA", "name": "x", "version": "1", "file": "f",')
        + String(' "sha256": "ABC", "subdir": "linux-64"}'),
        String("not 64 lowercase hex"),
    )
    _assert_refused(
        _conda(String(', "metadata": "METADATA"')),
        String("'metadata' belongs to a PYTHON artifact"),
    )
    _assert_refused(
        String('{"artifact_type": "CONDA", "name": "x", "version": "1", "file": "f",')
        + String(' "sha256": "')
        + String(_SHA)
        + String('"}'),
        String("a CONDA artifact needs 'subdir'"),
    )
    _assert_refused(
        String('{"artifact_type": "CONDA", "name": "x", "version": "1", "file": "f",')
        + String(' "sha256": "')
        + String(_SHA)
        + String('", "subdir": "noarch"}'),
        String("subdir 'noarch' is not published"),
    )
    _assert_refused(
        String('{"artifact_type": "PYTHON", "name": "x", "version": "1", "file": "f",')
        + String(' "sha256": "')
        + String(_SHA)
        + String('"}'),
        String("a PYTHON artifact needs 'metadata'"),
    )
    _assert_refused(
        String('{"artifact_type": "PYTHON", "name": "x", "version": "1", "file": "f",')
        + String(' "sha256": "')
        + String(_SHA)
        + String('", "metadata": "M", "subdir": "linux-64"}'),
        String("'subdir' belongs to a CONDA artifact"),
    )
    _assert_refused(
        String('{"artifact_type": "OCI", "name": "x", "version": "1", "file": "f",')
        + String(' "sha256": "')
        + String(_SHA)
        + String('"}'),
        String("artifact_type 'OCI' is not published by kci publish"),
    )


def test_approved_names_file() raises:
    var names = parse_approved_names(
        String("# the names we publish\n\n  example-pkg  \nExample_Tool\n"),
        String("names.txt"),
    )
    assert_equal(names.count(), 2)
    assert_true(names.is_approved(String("example-pkg"), SUBSTRATE_PREFIX_DEV_CONDA))
    assert_true(names.is_approved(String("example.tool"), SUBSTRATE_PUBLIC_PYPI))
    assert_false(names.is_approved(String("example.tool"), SUBSTRATE_PREFIX_DEV_CONDA))
    var empty = parse_approved_names(String("# nothing yet\n"), String("names.txt"))
    assert_equal(empty.count(), 0)
    assert_false(empty.is_approved(String("example-pkg"), SUBSTRATE_PREFIX_DEV_CONDA))
    var why = String("")
    try:
        _ = parse_approved_names(String("a\nb/c\n"), String("names.txt"))
    except e:
        why = String(e)
    assert_true(why.find(String("approved-names file 'names.txt': line 2")) >= 0, why)
    why = String("")
    try:
        _ = parse_approved_names(String("a\nA\n"), String("names.txt"))
    except e:
        why = String(e)
    assert_true(why.find(String("line 2")) >= 0, why)
    assert_true(why.find(String("approved twice")) >= 0, why)


def main() raises:
    test_conda_and_python_parse()
    test_manifest_refusals()
    test_approved_names_file()
    print("test_publish_manifest: ALL PASS")
