# =============================================================================
# src/kci_release_set/tests/test_verify_member.mojo
#   `verify_member`: the real metapackage directory komira_pack wrote is
#   accepted, and each refusal is caused by one change to a good directory.
# =============================================================================
#
# The good directory is written under TEST_TMPDIR: a package file, its
# manifest (kci_artifact_manifest's format) and the real metadata.json of a
# library komira_pack wrote, with `size` set to the synthetic file's. A
# control case accepts it, so each refusal below is its one change.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs, remove
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_crypto import hex_lower_array_32, sha256_string
from komira_json import JsonValue, parse_json_value

from kci_release_set import member_platform, verify_member

comptime _NAME = "komira_name_registry"
comptime _FILE = "komira_name_registry-0.1.7-0.conda"
comptime _CONTENT = "the bytes of a conda package"
comptime _LIB = "src/kci_release_set/tests/data/library.metadata.json"
comptime _REAL = "src/kci_release_set/tests/data/komira"


def _write(path: String, text: String) raises:
    var f = open(path, "w")
    f.write_bytes(text.as_bytes())
    f.close()


def _hash(text: String) -> String:
    return hex_lower_array_32(sha256_string(text))


def _root(tag: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = (
        base + String("/vm_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    )
    makedirs(d, exist_ok=True)
    return d^


def _manifest(
    name: String = String(_NAME),
    file: String = String(_FILE),
    sha: String = String(""),
    artifact_type: String = String("CONDA"),
    metadata: String = String("metadata.json"),
) -> String:
    var digest = sha.copy() if sha.byte_length() > 0 else _hash(String(_CONTENT))
    var subdir = String('"subdir":"linux-64",') if artifact_type == "CONDA" else String("")
    var platform = String("linux-x86_64") if artifact_type == "CONDA" else String("noarch")
    return (
        String('{"format":"kci.artifact_manifest","schema_version":1,"artifact_type":"')
        + artifact_type + String('","name":"') + name
        + String('","version":"0.1.7","platform":"') + platform + String('",') + subdir
        + String('"file":"') + file
        + String('","sha256":"') + digest + String('","metadata":"') + metadata + String('"}\n')
    )


def _metadata(key: String = String(""), raw: String = String("")) raises -> String:
    """The real library metadata, `size` set to the content's, and `key`
    (if given) set to the JSON `raw`."""
    var doc = parse_json_value(Path(String(_LIB)).read_text())
    var out = JsonValue.empty_object()
    for i in range(doc.num_members()):
        var k = doc.key_at(i)
        if k == key:
            out.set_member(k^, parse_json_value(raw))
        elif k == "size":
            out.set_member(k^, JsonValue.from_i64(Int64(String(_CONTENT).byte_length())))
        else:
            out.set_member(k^, doc.value_at(i))
    return out.serialize()


def _good(tag: String) raises -> String:
    """A good artifact directory `<root>/<_NAME>`; returns it."""
    var d = _root(tag) + String("/") + String(_NAME)
    makedirs(d, exist_ok=True)
    _write(d + String("/") + String(_FILE), String(_CONTENT))
    _write(d + String("/manifest.json"), _manifest())
    _write(d + String("/metadata.json"), _metadata())
    return d^


def _symlink(target: String, link: String) raises:
    """`ln -s target link`, through libc (test-only FFI: the std has no
    symlink call)."""
    var t = target.copy()
    var l = link.copy()
    var rc = external_call["symlink", Int32](
        t.as_c_string_slice().unsafe_ptr(), l.as_c_string_slice().unsafe_ptr()
    )
    if rc != 0:
        raise Error(String("symlink(") + target + String(", ") + link + String(") failed"))


def _link_outside(d: String, entry: String, tag: String) raises:
    """Replace `d/entry` with a symlink to a file OUTSIDE `d` holding the
    same bytes, so only the link (never the bytes) can cause a refusal."""
    var outside = _root(String("outside_") + tag) + String("/") + entry
    var data = Path(d + String("/") + entry).read_text()
    _write(outside, data)
    remove(d + String("/") + entry)
    _symlink(outside, d + String("/") + entry)


def _refusal(dir: String, name: String = String(_NAME)) -> String:
    try:
        _ = verify_member(name, dir)
    except e:
        return String(e)
    return String("<verified>")


def _expect(dir: String, why: String) raises:
    assert_equal(_refusal(dir), String("artifact '") + String(_NAME) + String("': ") + why)


def test_control_good_directory_is_verified() raises:
    var d = _good(String("control"))
    var m = verify_member(String(_NAME), d)
    assert_equal(m.artifact, String(_NAME))
    assert_equal(m.dir, d)
    assert_equal(m.manifest.name, String(_NAME))
    assert_equal(m.manifest.sha256_hex, _hash(String(_CONTENT)))
    assert_equal(m.size, String(_CONTENT).byte_length())
    assert_true(m.has_conda)
    assert_equal(m.kind(), String("library"))
    assert_equal(m.build(), String("0"))
    assert_equal(m.conda.import_name, String(_NAME))


def test_real_metapackage_directory_is_verified() raises:
    var m = verify_member(String("komira"), String(_REAL))
    assert_equal(m.kind(), String("metapackage"))
    assert_equal(m.size, 17854)
    assert_equal(
        m.manifest.sha256_hex,
        String("2419f1b69621c0c607c4df2d6d0591e80e58d166841de2f32609868c2969c24f"),
    )
    assert_equal(len(m.conda.members), 2)


def test_refuses_a_missing_directory() raises:
    var d = _root(String("nodir")) + String("/absent")
    _expect(d, String("'") + d + String("' is not a directory"))


def test_refuses_no_manifest() raises:
    var d = _root(String("noman")) + String("/") + String(_NAME)
    makedirs(d, exist_ok=True)
    _write(d + String("/") + String(_FILE), String(_CONTENT))
    _expect(d, String("the build left no manifest.json at the top of its output directory"))


def test_refuses_a_manifest_that_does_not_parse() raises:
    var d = _good(String("badman"))
    _write(d + String("/manifest.json"), String("{"))
    assert_true(
        _refusal(d).startswith(
            String("artifact manifest '") + d + String("/manifest.json': not JSON: ")
        ),
        _refusal(d),
    )


def test_refuses_a_name_that_is_not_the_artifacts() raises:
    var d = _good(String("name"))
    _write(d + String("/manifest.json"), _manifest(name=String("komira_name_registry2")))
    _expect(
        d,
        String("the built manifest's name 'komira_name_registry2' is not the artifact's name")
        + String(" (compared exactly)"),
    )


def test_refuses_a_file_that_is_not_a_bare_name() raises:
    var d = _good(String("nonbare"))
    _write(d + String("/manifest.json"), _manifest(file=String("linux-64/") + String(_FILE)))
    _expect(
        d,
        String("the manifest's 'file' is 'linux-64/") + String(_FILE)
        + String("', not a file name in the artifact's directory"),
    )
    _write(d + String("/manifest.json"), _manifest(file=String("../") + String(_FILE)))
    _expect(
        d,
        String("the manifest's 'file' is '../") + String(_FILE)
        + String("', not a file name in the artifact's directory"),
    )


def test_refuses_a_file_naming_the_manifest_or_the_metadata() raises:
    var d = _good(String("self"))
    _write(
        d + String("/manifest.json"),
        _manifest(file=String("manifest.json"), artifact_type=String("PYTHON"), metadata=String("METADATA")),
    )
    _expect(d, String("the manifest's 'file' names the manifest itself"))
    _write(
        d + String("/manifest.json"),
        _manifest(file=String("METADATA"), artifact_type=String("PYTHON"), metadata=String("METADATA")),
    )
    _expect(d, String("the manifest's 'file' and 'metadata' are the same name 'METADATA'"))


def test_refuses_a_stray_top_level_entry() raises:
    var d = _good(String("stray"))
    _write(d + String("/BUILD_SUMMARY.txt"), String("x"))
    _expect(
        d,
        String("the directory holds 'BUILD_SUMMARY.txt', which its manifest does not name;")
        + String(" it holds exactly manifest.json, the file and the metadata"),
    )
    var e = _good(String("straydir"))
    makedirs(e + String("/linux-64"), exist_ok=True)
    _expect(
        e,
        String("the directory holds 'linux-64', which its manifest does not name;")
        + String(" it holds exactly manifest.json, the file and the metadata"),
    )


def test_refuses_a_missing_file_or_metadata() raises:
    var d = _root(String("nofile")) + String("/") + String(_NAME)
    makedirs(d, exist_ok=True)
    _write(d + String("/manifest.json"), _manifest())
    _write(d + String("/metadata.json"), _metadata())
    _expect(d, String("its file '") + String(_FILE) + String("' is not in the directory"))
    var e = _root(String("nometa")) + String("/") + String(_NAME)
    makedirs(e, exist_ok=True)
    _write(e + String("/manifest.json"), _manifest())
    _write(e + String("/") + String(_FILE), String(_CONTENT))
    _expect(e, String("its metadata 'metadata.json' is not in the directory"))


def _link_refusal(entry: String) -> String:
    return (
        String("the directory's '")
        + entry
        + String("' is a symlink: the directory holds regular files only, and a link")
        + String(" can name bytes outside the release directory")
    )


def test_refuses_a_file_symlinked_outside_the_directory() raises:
    var d = _good(String("linkfile"))
    _link_outside(d, String(_FILE), String("linkfile"))
    _expect(d, _link_refusal(String(_FILE)))


def test_refuses_metadata_symlinked_outside_the_directory() raises:
    var d = _good(String("linkmeta"))
    _link_outside(d, String("metadata.json"), String("linkmeta"))
    _expect(d, _link_refusal(String("metadata.json")))


def test_refuses_a_manifest_symlinked_outside_the_directory() raises:
    var d = _good(String("linkman"))
    _link_outside(d, String("manifest.json"), String("linkman"))
    _expect(d, _link_refusal(String("manifest.json")))


def test_refuses_a_directory_that_is_a_symlink() raises:
    var real = _good(String("linkdir_real"))
    var parent = _root(String("linkdir"))
    var d = parent + String("/") + String(_NAME)
    _symlink(real, d)
    var tail = String(
        "' is a symlink, not a directory: a link can name bytes outside the release directory"
    )
    _expect(d, String("'") + d + tail)
    # a trailing `/` would make lstat resolve the link; it is refused the same
    _expect(d + String("/"), String("'") + d + String("/") + tail)


def test_refuses_a_manifest_that_is_not_a_regular_file() raises:
    var d = _good(String("mandir"))
    remove(d + String("/manifest.json"))
    makedirs(d + String("/manifest.json"), exist_ok=True)
    _expect(d, String("its manifest.json is not a regular file"))


def test_refuses_a_file_that_is_a_directory() raises:
    # Only an OCI member's file is a directory (test_oci_member.mojo): a
    # CONDA package or a PYTHON wheel that is one is refused by name.
    var d = _good(String("filedir"))
    remove(d + String("/") + String(_FILE))
    makedirs(d + String("/") + String(_FILE), exist_ok=True)
    _expect(
        d,
        String("its file '") + String(_FILE)
        + String("' is a directory: only an OCI member's file is a directory (its image layout)"),
    )
    var p = _root(String("wheeldir")) + String("/") + String(_NAME)
    var wheel = String("komira_name_registry-0.1.7-py3-none-any.whl")
    makedirs(p + String("/") + wheel, exist_ok=True)
    _write(p + String("/METADATA"), String("Metadata-Version: 2.1\n"))
    _write(
        p + String("/manifest.json"),
        _manifest(file=wheel, artifact_type=String("PYTHON"), metadata=String("METADATA")),
    )
    _expect(
        p,
        String("its file '") + wheel
        + String("' is a directory: only an OCI member's file is a directory (its image layout)"),
    )


def test_refuses_an_empty_file() raises:
    var d = _good(String("empty"))
    _write(d + String("/") + String(_FILE), String(""))
    _write(d + String("/manifest.json"), _manifest(sha=_hash(String(""))))
    _expect(d, String("its file '") + String(_FILE) + String("' is EMPTY"))


def test_refuses_a_sha256_mismatch() raises:
    var d = _good(String("sha"))
    _write(d + String("/") + String(_FILE), String(_CONTENT) + String("!"))
    _expect(
        d,
        String("the sha256 of '") + String(_FILE) + String("' is ")
        + _hash(String(_CONTENT) + String("!")) + String(" but its manifest says ")
        + _hash(String(_CONTENT)),
    )


def test_refuses_metadata_that_does_not_parse() raises:
    var d = _good(String("badmeta"))
    _write(d + String("/metadata.json"), _metadata(String("schema_version"), String("2")))
    _expect(
        d,
        String("conda metadata '") + d
        + String("/metadata.json': schema_version 2 needs a newer kci (this kci reads")
        + String(" kci.conda_metadata up to major 1)"),
    )


def test_refuses_metadata_that_disagrees_with_the_manifest() raises:
    var d = _good(String("disagree"))
    _write(d + String("/metadata.json"), _metadata(String("name"), String('"komira_hash"')))
    _expect(d, String("its metadata says name 'komira_hash' but its manifest says '") + String(_NAME) + String("'"))
    _write(d + String("/metadata.json"), _metadata(String("version"), String('"0.1.8"')))
    _expect(d, String("its metadata says version '0.1.8' but its manifest says '0.1.7'"))
    _write(d + String("/metadata.json"), _metadata(String("subdir"), String('"osx-arm64"')))
    _expect(d, String("its metadata says subdir 'osx-arm64' but its manifest says 'linux-64'"))
    _write(d + String("/metadata.json"), _metadata(String("file_name"), String('"other-0.1.7-0.conda"')))
    _expect(
        d,
        String("its metadata says file_name 'other-0.1.7-0.conda' but its manifest says '")
        + String(_FILE) + String("'"),
    )
    _write(d + String("/metadata.json"), _metadata(String("size"), String("29")))
    _expect(
        d,
        String("its metadata says size ") + String(String(_CONTENT).byte_length() + 1)
        + String(" but '") + String(_FILE) + String("' is ")
        + String(String(_CONTENT).byte_length()) + String(" bytes"),
    )


def test_refuses_an_unstamped_package() raises:
    var d = _good(String("unstamped"))
    _write(d + String("/metadata.json"), _metadata(String("stamped"), String("false")))
    _expect(d, String("its metadata says stamped: false; an unstamped package is never released"))


def test_python_is_accepted_without_conda_metadata() raises:
    var d = _root(String("python")) + String("/") + String(_NAME)
    makedirs(d, exist_ok=True)
    var wheel = String("komira_name_registry-0.1.7-py3-none-any.whl")
    _write(d + String("/") + wheel, String(_CONTENT))
    _write(d + String("/METADATA"), String("Metadata-Version: 2.1\n"))
    _write(
        d + String("/manifest.json"),
        _manifest(file=wheel, artifact_type=String("PYTHON"), metadata=String("METADATA")),
    )
    var m = verify_member(String(_NAME), d)
    assert_false(m.has_conda)
    assert_equal(m.build(), String(""))
    assert_equal(m.kind(), String(""))


def test_a_members_platform_is_its_manifests() raises:
    # A PYTHON wheel whose manifest says `noarch` is a noarch member of a
    # linux-x86_64 release, not a linux-x86_64 one: the manifest states the
    # platform (kci_artifact_manifest), and release.json records that one.
    var d = _root(String("python_noarch")) + String("/") + String(_NAME)
    makedirs(d, exist_ok=True)
    var wheel = String("komira_name_registry-0.1.7-py3-none-any.whl")
    _write(d + String("/") + wheel, String(_CONTENT))
    _write(d + String("/METADATA"), String("Metadata-Version: 2.1\n"))
    _write(
        d + String("/manifest.json"),
        _manifest(file=wheel, artifact_type=String("PYTHON"), metadata=String("METADATA")),
    )
    var m = verify_member(String(_NAME), d)
    assert_equal(m.manifest.platform, String("noarch"))
    assert_equal(member_platform(m, String("linux-x86_64")), String("noarch"))
    # a CONDA member is its manifest's platform too
    var c = verify_member(String(_NAME), _good(String("conda_platform")))
    assert_equal(member_platform(c, String("linux-x86_64")), String("linux-x86_64"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
