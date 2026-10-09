# =============================================================================
# src/kci_release_set/tests/test_oci_member.mojo
#   An OCI member (an image) of a release set: `verify_member` over the real
#   //tools/build/examples:hello_image[release], its digest in the set hash,
#   and each refusal of the OCI arm caused by one change.
# =============================================================================
#
# Test data (BUCK): `hello/` is hello_image[release] as the build wrote it (its
# manifest.json and the layout `hello_image.oci/`), and `hello_image.digest`
# is hello_image[digest], the digest komira_pack wrote. The digest file is
# read independently of the artifact manifest, so a manifest that carried
# another hash, or a set hash that left it out, does not compare equal.
#
# A refusal case changes one thing in a COPY of `hello/` under TEST_TMPDIR
# (the staged data stays as built), or in a small layout written by
# komira_oci's `write_test_layout`.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, listdir, makedirs, remove
from std.os.path import isdir
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_true

from komira_crypto import hex_lower_array_32, sha256
from komira_json import parse_json_value

from komira_oci import write_test_layout

from kci_artifact_manifest import render_artifact_manifest
from kci_release_set import (
    ReleaseIdentity,
    ReleaseMember,
    SetHashLine,
    member_platform,
    release_manifest_of,
    set_hash_of_lines,
    set_hash_text,
    verify_member,
)

comptime _HELLO = "hello"
comptime _LAYOUT = "hello_image.oci"
comptime _DIGEST_FILE = "hello_image.digest"
comptime _REV = "0123456789abcdef0123456789abcdef01234567"
comptime _PLATFORM = "linux-x86_64"


def _root(tag: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = (
        base + String("/oci_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    )
    makedirs(d, exist_ok=True)
    return d^


def _write(path: String, text: String) raises:
    var f = open(path, "w")
    f.write_bytes(text.as_bytes())
    f.close()


def _copy_tree(src: String, dst: String) raises:
    makedirs(dst, exist_ok=True)
    var names = listdir(src)
    for i in range(len(names)):
        var name = String(names[i])
        var s = src + String("/") + name
        var d = dst + String("/") + name
        if isdir(s):
            _copy_tree(s, d)
        else:
            var data = Path(s).read_bytes()
            Path(d).write_bytes(Span(data))


def _hello_copy(tag: String) raises -> String:
    """A copy of the staged hello_image[release], named `hello` like the
    artifact."""
    var d = _root(tag) + String("/") + String(_HELLO)
    _copy_tree(String(_HELLO), d)
    return d^


def _digest() raises -> String:
    """hello_image[digest]: `sha256:<hex>`."""
    return String(Path(String(_DIGEST_FILE)).read_text().strip())


def _hex_of(digest: String) -> String:
    return String(digest[byte = 7 :])


def _refusal(dir: String, name: String = String(_HELLO)) -> String:
    try:
        _ = verify_member(name, dir)
    except e:
        return String(e)
    return String("<verified>")


def _expect(dir: String, why: String, name: String = String(_HELLO)) raises:
    assert_equal(_refusal(dir, name), String("artifact '") + name + String("': ") + why)


def _oci_manifest(name: String, file: String, hex: String, platform: String = String("linux-x86_64")) -> String:
    return (
        String('{"format":"kci.artifact_manifest","schema_version":1,"artifact_type":"OCI",')
        + String('"name":"') + name + String('","version":"0.1.0","platform":"') + platform + String('",')
        + String('"file":"') + file + String('","sha256":"') + hex + String('"}\n')
    )


# ---- the real image --------------------------------------------------------


def test_hello_image_release_verifies_and_its_digest_is_in_the_set_hash() raises:
    var digest = _digest()
    assert_true(digest.startswith(String("sha256:")), digest)
    var hex = _hex_of(digest)
    var m = verify_member(String(_HELLO), String(_HELLO))
    assert_equal(m.manifest.artifact_type, String("OCI"))
    assert_equal(m.manifest.name, String("hello"))
    assert_equal(m.manifest.version, String("0.1.0"))
    assert_equal(m.manifest.platform, String(_PLATFORM))
    assert_equal(m.manifest.file, String(_LAYOUT))
    assert_equal(m.manifest.sha256_hex, hex)
    assert_equal(m.build(), String(""))
    assert_equal(m.kind(), String(""))
    assert_equal(member_platform(m, String(_PLATFORM)), String(_PLATFORM))
    # What oci_image[release] wrote is byte for byte what kci's writer writes.
    assert_equal(
        Path(String(_HELLO) + String("/manifest.json")).read_text(),
        render_artifact_manifest(m.manifest),
    )
    # The set hash is the hash of exactly this line: the digest komira_pack
    # wrote, under type OCI, with no build, kind or subdir.
    var members = List[ReleaseMember]()
    members.append(m.copy())
    var r = release_manifest_of(
        members, ReleaseIdentity(String(_REV), String(_PLATFORM), String("gh-1"), 1)
    )
    var lines = List[SetHashLine]()
    lines.append(
        SetHashLine(
            String("hello"), String(_PLATFORM), String("0.1.0"), String(""), String(""),
            String("OCI"), hex.copy(),
        )
    )
    assert_equal(r.set_hash, set_hash_of_lines(String(_REV), String(_PLATFORM), lines))
    assert_true(
        set_hash_text(String(_REV), String(_PLATFORM), lines).find(
            String("\tOCI\t") + hex + String("\n")
        ) >= 0
    )
    assert_equal(len(r.entries), 1)
    assert_equal(r.entries[0].sha256_hex, hex)
    assert_equal(r.entries[0].artifact_type, String("OCI"))


def _blob_path(layout: String, digest: String) -> String:
    return layout + String("/blobs/sha256/") + _hex_of(digest)


def _flip_one_byte(path: String) raises -> String:
    """Flip the low bit of the middle byte of `path`; return the new
    `sha256:` digest of its bytes."""
    var data = Path(path).read_bytes()
    var at = len(data) // 2
    data[at] = data[at] ^ UInt8(1)
    Path(path).write_bytes(Span(data))
    return String("sha256:") + hex_lower_array_32(sha256(Span(data)))


def _layer_digests(layout: String) raises -> List[String]:
    """The layer digests the layout's manifest lists, in order, read with
    komira_json alone: the case's expectation does not come from the
    reader under test."""
    var index = parse_json_value(Path(layout + String("/index.json")).read_text())
    var manifest_digest = index.get(String("manifests")).element_at(0).get(String("digest")).as_string()
    var manifest = parse_json_value(Path(_blob_path(layout, manifest_digest)).read_text())
    var layers = manifest.get(String("layers"))
    var out = List[String]()
    for i in range(layers.array_len()):
        out.append(layers.element_at(i).get(String("digest")).as_string())
    return out^


def test_a_layer_with_one_byte_flipped_is_refused() raises:
    # Layer 0, a layer of the base. A flip in the LAST layer is the small
    # layout's case below.
    var layers = _layer_digests(String(_HELLO) + String("/") + String(_LAYOUT))
    assert_true(len(layers) >= 2, String("hello_image has ") + String(len(layers)) + String(" layers"))
    var d = _hello_copy(String("flip"))
    var layout = d + String("/") + String(_LAYOUT)
    var now = _flip_one_byte(_blob_path(layout, layers[0]))
    _expect(
        d,
        String("its image layout '") + String(_LAYOUT) + String("' does not verify: ")
        + String("oci layout: DIGEST MISMATCH for blob ") + layers[0]
        + String(" — its bytes content-address to ") + now,
    )


# ---- the OCI arm, over small layouts ----------------------------------------


def _layers() -> List[List[UInt8]]:
    var out = List[List[UInt8]]()
    var a = List[UInt8]()
    for i in range(300):
        a.append(UInt8(i % 251))
    var b = List[UInt8]()
    for i in range(700):
        b.append(UInt8((i * 7) % 253))
    var c = List[UInt8]()
    for i in range(50):
        c.append(UInt8(i + 1))
    out.append(a^)
    out.append(b^)
    out.append(c^)
    return out^


def _small(tag: String, architecture: String = String("amd64")) raises -> String:
    """A good OCI member `<root>/img` holding `img.oci`; returns it."""
    var d = _root(tag) + String("/img")
    makedirs(d, exist_ok=True)
    var digest = write_test_layout(d + String("/img.oci"), _layers(), architecture=architecture)
    _write(d + String("/manifest.json"), _oci_manifest(String("img"), String("img.oci"), _hex_of(digest)))
    return d^


def _expect_img(dir: String, why: String) raises:
    _expect(dir, why, String("img"))


def test_control_small_layout_is_verified_and_sized() raises:
    var d = _small(String("control"))
    var m = verify_member(String("img"), d)
    assert_equal(m.manifest.artifact_type, String("OCI"))
    assert_true(not m.has_conda)
    # The size is the image's: every blob the layout holds (the manifest, the
    # config and the three layers), summed from the files themselves.
    var blobs = d + String("/img.oci/blobs/sha256")
    var names = listdir(blobs)
    assert_equal(len(names), 5)
    var total = 0
    for i in range(len(names)):
        total += len(Path(blobs + String("/") + String(names[i])).read_bytes())
    assert_equal(m.size, total)


def test_a_flipped_byte_in_the_last_layer_is_refused() raises:
    var d = _small(String("lastflip"))
    var layout = d + String("/img.oci")
    var layers = _layers()
    var last = String("sha256:") + hex_lower_array_32(sha256(Span(layers[len(layers) - 1])))
    var now = _flip_one_byte(_blob_path(layout, last))
    _expect_img(
        d,
        String("its image layout 'img.oci' does not verify: oci layout: DIGEST MISMATCH for blob ")
        + last + String(" — its bytes content-address to ") + now,
    )


def test_a_digest_the_layout_does_not_hold_is_refused() raises:
    # A second, valid layout where the one the manifest (and so the set hash)
    # names should be: it verifies blob by blob, and is still refused.
    var named = write_test_layout(_root(String("digest_named")) + String("/img.oci"), _layers())
    var other_layers = _layers()
    other_layers[1].append(UInt8(42))
    var d = _root(String("digest_held")) + String("/img")
    makedirs(d, exist_ok=True)
    var held = write_test_layout(d + String("/img.oci"), other_layers)
    assert_true(held != named)
    _write(d + String("/manifest.json"), _oci_manifest(String("img"), String("img.oci"), _hex_of(named)))
    _expect_img(
        d,
        String("the image manifest digest of 'img.oci' is ") + held
        + String(" but its manifest says ") + named,
    )


def test_refuses_a_layout_that_is_missing_or_not_a_directory() raises:
    var d = _root(String("nolayout")) + String("/img")
    makedirs(d, exist_ok=True)
    _write(d + String("/manifest.json"), _oci_manifest(String("img"), String("img.oci"), String("ab") * 32))
    _expect_img(d, String("its file 'img.oci' is not in the directory"))
    _write(d + String("/img.oci"), String("a file, not a layout"))
    _expect_img(d, String("its file 'img.oci' is not a directory: an OCI member's file is its image layout"))


def test_refuses_a_stray_top_level_entry() raises:
    # One stray per directory, three directories: `listdir` order is the file
    # system's, so a check that looked at fewer entries than the directory
    # holds would miss a stray that is not listed first.
    var strays = List[String]()
    strays.append(String("metadata.json"))
    strays.append(String("index.json"))
    strays.append(String("img.oci.bak"))
    for i in range(len(strays)):
        var d = _small(String("stray") + String(i))
        _write(d + String("/") + strays[i], String("{}"))
        _expect_img(
            d,
            String("the directory holds '") + strays[i] + String("', which its manifest does not name;")
            + String(" an OCI member holds exactly manifest.json and the image layout"),
        )


def test_refuses_a_layout_that_does_not_read() raises:
    var d = _small(String("nomarker"))
    remove(d + String("/img.oci/oci-layout"))
    var got = _refusal(d, String("img"))
    assert_true(
        got.startswith(String("artifact 'img': its image layout 'img.oci' does not verify: oci layout: ")),
        got,
    )


def test_refuses_a_file_that_is_not_a_bare_name_or_is_the_manifest() raises:
    var d = _small(String("bare"))
    _write(d + String("/manifest.json"), _oci_manifest(String("img"), String("manifest.json"), String("ab") * 32))
    _expect_img(d, String("the manifest's 'file' names the manifest itself"))
    _write(d + String("/manifest.json"), _oci_manifest(String("img"), String("x/img.oci"), String("ab") * 32))
    _expect_img(d, String("the manifest's 'file' is 'x/img.oci', not a file name in the artifact's directory"))


# ---- platform, links and strays inside the layout, size ---------------------


def test_refuses_a_layout_for_another_platform() raises:
    var d = _small(String("arm64"), architecture=String("arm64"))
    _expect_img(
        d,
        String("its image layout 'img.oci' is for linux/arm64 but its manifest says platform")
        + String(" linux-x86_64 (linux/amd64)"),
    )


def test_refuses_a_noarch_oci_member() raises:
    var d = _small(String("noarch"))
    var text = Path(d + String("/manifest.json")).read_text()
    _write(d + String("/manifest.json"), text.replace(String('"linux-x86_64"'), String('"noarch"')))
    _expect_img(d, String("an OCI member's platform is 'noarch': an image is built for one platform"))


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


def _digest_of(data: List[UInt8]) -> String:
    return String("sha256:") + hex_lower_array_32(sha256(Span(data)))


def test_refuses_a_layer_blob_that_is_a_symlink() raises:
    # The middle layer replaced by a link to a file OUTSIDE the release
    # directory holding the same bytes: only the link can cause the refusal,
    # and the message names the link, not a hash of what it points at.
    var d = _small(String("bloblink"))
    var layers = _layers()
    var middle = _digest_of(layers[1])
    var blob = _blob_path(d + String("/img.oci"), middle)
    var outside = _root(String("bloblink_outside")) + String("/blob")
    Path(outside).write_bytes(Span(layers[1]))
    remove(blob)
    _symlink(outside, blob)
    _expect_img(
        d,
        String("its image layout 'img.oci' holds a symlink at 'blobs/sha256/") + _hex_of(middle)
        + String("': a link can name bytes outside the release directory"),
    )


def test_refuses_an_unreferenced_blob_in_the_middle() raises:
    # A content-named blob nothing references, whose name sorts strictly
    # between the layout's first and last blob: entries are checked in
    # bytewise order, so it is neither the first nor the last checked.
    var d = _small(String("strayblob"))
    var blobs = d + String("/img.oci/blobs/sha256")
    var names = listdir(blobs)
    var lo = String(names[0])
    var hi = String(names[0])
    for i in range(len(names)):
        var n = String(names[i])
        if n < lo:
            lo = n
        if n > hi:
            hi = n
    var stray = String("")
    var data = List[UInt8]()
    for k in range(1000):
        data = List[UInt8]()
        var text = String("unreferenced ") + String(k)
        var bs = text.as_bytes()
        for j in range(len(bs)):
            data.append(bs[j])
        var hex = hex_lower_array_32(sha256(Span(data)))
        if hex > lo and hex < hi:
            stray = hex^
            break
    assert_true(stray.byte_length() == 64, String("no stray name between ") + lo + String(" and ") + hi)
    Path(blobs + String("/") + stray).write_bytes(Span(data))
    _expect_img(
        d,
        String("its image layout 'img.oci' holds 'blobs/sha256/") + stray
        + String("', which its index and manifest do not reference"),
    )


def test_refuses_an_extra_file_at_the_layout_root() raises:
    # `extra.txt` sorts after every `blobs/` entry and before `index.json`.
    var d = _small(String("strayroot"))
    _write(d + String("/img.oci/extra.txt"), String("x"))
    _expect_img(
        d,
        String("its image layout 'img.oci' holds 'extra.txt', which its index and manifest")
        + String(" do not reference"),
    )


def test_a_layer_listed_twice_is_counted_once() raises:
    var layers = _layers()
    var twice = List[List[UInt8]]()
    twice.append(layers[0].copy())
    twice.append(layers[1].copy())
    twice.append(layers[0].copy())
    var d = _root(String("twice")) + String("/img")
    makedirs(d, exist_ok=True)
    var digest = write_test_layout(d + String("/img.oci"), twice)
    _write(d + String("/manifest.json"), _oci_manifest(String("img"), String("img.oci"), _hex_of(digest)))
    var m = verify_member(String("img"), d)
    # four files: the manifest, the config and the two distinct layers
    var blobs = d + String("/img.oci/blobs/sha256")
    var names = listdir(blobs)
    assert_equal(len(names), 4)
    var total = 0
    for i in range(len(names)):
        total += len(Path(blobs + String("/") + String(names[i])).read_bytes())
    assert_equal(m.size, total)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
