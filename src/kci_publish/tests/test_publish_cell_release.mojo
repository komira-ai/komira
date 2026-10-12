# =============================================================================
# src/kci_publish/tests/test_publish_cell_release.mojo
#   `load_cell_release`: the release set of a PUBLISH step into a cell.
# =============================================================================
#
# The release directory is `ExampleRelease`'s (three CONDA members) plus one
# OCI member `web` (a layout komira_oci's `write_test_layout` writes and its
# artifact manifest), with `release.json` recomputed over all four. Each case
# asserts the returned error id, and the images:
#
#   1. The set loads: one image, `web`, whose digest is `sha256:` + the hex
#      in its artifact manifest (the digest `write_test_layout` returned,
#      compared here as that independent value), whose layout directory is
#      the member's `web.oci`; the three CONDA members are `skipped`, not
#      images.
#   2. A set of CONDA members only: KCI-E-MEMBER, no image.
#   3. `release.json` naming another revision: KCI-E-REVISION-MISMATCH.
#   4. A handed set hash the members do not recompute to: KCI-E-SET-HASH.
#      And a step platform other than `release.json`'s:
#      KCI-E-PLATFORM-MISMATCH.
#   5. One flipped byte in the image's layer: KCI-E-MEMBER (`verify_member`
#      hashes every blob at load).
# =============================================================================

from std.ffi import external_call
from std.os import getenv, listdir, makedirs
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_true

from komira_oci import write_test_layout

from kci_release_set import ReleaseIdentity, ReleaseMember, release_manifest_of, render_release_manifest, verify_member

from kci_publish import CellRelease, load_cell_release
from kci_publish.release_fixture import ExampleRelease, write_text_file

comptime _OTHER_HASH: String = "0000000000000000000000000000000000000000000000000000000000000000"


def _root(tag: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/kci_cell_release_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


struct _Set(Movable):
    """A written release directory: its artifacts file, its platform
    directory, its set hash and the image's digest ("" when it has none)."""

    var artifacts: String
    var dir: String
    var set_hash: String
    var digest: String

    def __init__(out self, var artifacts: String, var dir: String, var set_hash: String, var digest: String):
        self.artifacts = artifacts^
        self.dir = dir^
        self.set_hash = set_hash^
        self.digest = digest^


def _write(tag: String, with_image: Bool) raises -> _Set:
    var r = ExampleRelease()
    var root = _root(tag)
    var dir = root + String("/linux-x86_64")
    r.write(dir)
    var arts = r.artifacts_text()
    var digest = String("")
    if with_image:
        var layers = List[List[UInt8]]()
        layers.append(_bytes(String("web-layer-") + tag))
        digest = write_test_layout(dir + String("/web/web.oci"), layers, String("linux"), String("amd64"))
        write_text_file(
            dir + String("/web/manifest.json"),
            String('{"format":"kci.artifact_manifest","schema_version":1,"artifact_type":"OCI",')
            + String('"name":"web","version":"0.1.0","platform":"linux-x86_64",')
            + String('"file":"web.oci","sha256":"') + String(digest[byte=7:]) + String('"}\n'),
        )
        arts += String(
            'artifacts {\n  name: "web"\n  build_system: "buck2"\n  args: "//src/web:release"\n'
            '  args: "--out"\n  args: "{out_dir}"\n}\n'
        )
        var members = List[ReleaseMember]()
        for i in range(len(r.members)):
            members.append(verify_member(r.members[i].name, dir + String("/") + r.members[i].name))
        members.append(verify_member(String("web"), dir + String("/web")))
        write_text_file(
            dir + String("/release.json"),
            render_release_manifest(
                release_manifest_of(members, ReleaseIdentity(r.revision.copy(), r.platform.copy(), String("gh-1"), 1))
            ),
        )
    var artifacts = root + String("/artifacts.textproto")
    write_text_file(artifacts, arts)
    return _Set(artifacts^, dir^, r.set_hash(dir), digest^)


def _load(
    s: _Set, revision: String = String(""), hash: String = String(""), platform: String = String("linux-x86_64")
) -> CellRelease:
    var rev = ExampleRelease().revision.copy() if revision.byte_length() == 0 else revision.copy()
    var h = s.set_hash.copy() if hash.byte_length() == 0 else hash.copy()
    return load_cell_release(s.artifacts, s.dir, rev, platform, h)


def test_the_images_of_the_set_with_the_sets_digest() raises:
    """Catches: a CONDA member returned as an image; the digest taken from
    anywhere but the member's manifest; the wrong layout directory."""
    var s = _write(String("mixed"), True)
    var c = _load(s)
    assert_equal(c.error_id, String(""), c.message)
    assert_equal(len(c.images), 1)
    assert_equal(c.images[0].name, String("web"))
    assert_equal(c.images[0].digest, s.digest)
    assert_equal(c.images[0].platform, String("linux-x86_64"))
    assert_equal(c.images[0].layout_dir, s.dir + String("/web/web.oci"))
    assert_equal(c.set_hash, s.set_hash)
    assert_equal(len(c.skipped), 3)
    for want in ["komira_alpha", "komira_beta", "komira"]:
        var n = 0
        for i in range(len(c.skipped)):
            if c.skipped[i] == String(want):
                n += 1
        assert_equal(n, 1, String(want))


def test_a_set_with_no_image_is_refused() raises:
    """Catches: an empty push reported as success."""
    var c = _load(_write(String("conda"), False))
    assert_equal(c.error_id, String("KCI-E-MEMBER"))
    assert_true(c.message.find(String("holds no OCI member")) >= 0, c.message)
    assert_equal(len(c.images), 0)


def test_another_revision_is_refused() raises:
    """Catches: an image built from another commit tagged with this one."""
    var c = _load(_write(String("rev"), True), revision=String("ffffffffffffffffffffffffffffffffffffffff"))
    assert_equal(c.error_id, String("KCI-E-REVISION-MISMATCH"))
    assert_equal(len(c.images), 0)


def test_another_platform_is_refused() raises:
    """Catches: `release.json`'s platform not held to the step's (its
    release.json names linux-x86_64, the step publishes linux-aarch64)."""
    var c = _load(_write(String("platform"), True), platform=String("linux-aarch64"))
    assert_equal(c.error_id, String("KCI-E-PLATFORM-MISMATCH"))
    assert_true(c.message.find(String("is for platform linux-x86_64")) >= 0, c.message)
    assert_equal(len(c.images), 0)


def test_another_set_hash_is_refused() raises:
    """Catches: the handed set hash not compared with the recomputed one."""
    var s = _write(String("hash"), True)
    var c = _load(s, hash=String(_OTHER_HASH))
    assert_equal(c.error_id, String("KCI-E-SET-HASH"))
    assert_true(c.message.find(s.set_hash) >= 0, c.message)
    assert_equal(len(c.images), 0)


def test_a_flipped_layer_byte_is_refused_at_load() raises:
    """Catches: the set loaded without re-verifying each image's blobs."""
    var s = _write(String("flip"), True)
    var layer = _bytes(String("web-layer-flip"))
    var blobs = s.dir + String("/web/web.oci/blobs/sha256/")
    var entries = listdir(blobs)
    var flipped = 0
    for i in range(len(entries)):
        var path = blobs + String(entries[i])
        var data = Path(path).read_bytes()
        if len(data) != len(layer):
            continue
        var same = True
        for k in range(len(data)):
            if data[k] != layer[k]:
                same = False
        if same:
            data[0] = data[0] ^ UInt8(1)
            Path(path).write_bytes(Span(data))
            flipped += 1
    assert_equal(flipped, 1, "the layer blob was found and one byte flipped")
    var c = _load(s)
    assert_equal(c.error_id, String("KCI-E-MEMBER"))
    assert_true(c.message.find(String("does not verify")) >= 0, c.message)
    assert_equal(len(c.images), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
