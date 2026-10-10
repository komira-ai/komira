# =============================================================================
# src/kci_artifact_manifest/tests/test_read_artifact_manifest.mojo
#   read_artifact_manifest: read a manifest file, parse it, resolve against
#   its directory, and refuse an unreadable path by name.
# =============================================================================
#
# The files live under TEST_TMPDIR, the per-run scratch the test runner makes
# and removes; nothing outside it is read or written. The parser's own cases
# are in test_artifact_manifest.mojo; these check only what reading adds: the
# path handed to the parser and the refusal for a file that cannot be read.
# =============================================================================

from std.os import getenv, makedirs
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_true

from kci_artifact_manifest import read_artifact_manifest

comptime _HASH = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"


def _scratch(tag: String) raises -> String:
    """A new directory under this run's TEST_TMPDIR (never a /tmp fallback)."""
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        raise Error("TEST_TMPDIR is not set: the test runner owns the scratch")
    var d = base + String("/kam_") + tag
    makedirs(d, exist_ok=True)
    return d


def _conda() -> String:
    return (
        String('{"format":"kci.artifact_manifest","schema_version":1,')
        + String('"artifact_type":"CONDA","name":"example-pkg","version":"1.2.3",')
        + String('"platform":"linux-x86_64",')
        + String('"subdir":"linux-64","file":"linux-64/example-pkg-1.2.3-h0_0.conda",')
        + String('"sha256":"')
        + String(_HASH)
        + String('","metadata":"metadata.json"}\n')
    )


def test_read_parses_the_file_and_resolves_against_its_directory() raises:
    var d = _scratch(String("ok"))
    var path = d + String("/m.json")
    Path(path).write_text(_conda())
    var m = read_artifact_manifest(path)
    # The file's own path is the source: it names the manifest and its
    # directory is where `file` and `metadata` resolve.
    assert_equal(m.source, path)
    assert_equal(m.name, String("example-pkg"))
    assert_equal(m.sha256_hex, String(_HASH))
    assert_equal(m.file_path, d + String("/linux-64/example-pkg-1.2.3-h0_0.conda"))
    assert_equal(m.metadata_path, d + String("/metadata.json"))


def test_read_refusals_from_the_parser_name_the_file() raises:
    var d = _scratch(String("bad"))
    var path = d + String("/m.json")
    Path(path).write_text(_conda().replace(String('"1.2.3"'), String("123")))
    var got = String("<parsed>")
    try:
        _ = read_artifact_manifest(path)
    except e:
        got = String(e)
    assert_equal(
        got,
        String("artifact manifest '") + path + String("': 'version' is not a string"),
    )


def test_read_refuses_a_missing_file_by_name() raises:
    var d = _scratch(String("missing"))
    var path = d + String("/absent.json")
    var got = String("<parsed>")
    try:
        _ = read_artifact_manifest(path)
    except e:
        got = String(e)
    var want = String("artifact manifest '") + path + String("' cannot be read: ")
    assert_true(got.startswith(want), got)
    # The OS's reason follows the prefix; it is not empty.
    assert_true(got.byte_length() > want.byte_length(), got)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
