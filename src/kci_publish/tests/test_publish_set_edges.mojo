# =============================================================================
# src/kci_publish/tests/test_publish_set_edges.mojo -- the release set's
#   checks and the NEW NAMES read at their edges.
# =============================================================================
#
# ROWS
#   (1) a member that is not CONDA is refused by name and type;
#   (2) lockstep and the closure refuse an EMPTY set (never index into it);
#   (3) the closure refuses a metapackage that lists a member twice, and one
#       that requires a member's pin twice;
#   (4) NEW NAMES are not read for an empty set, for a target whose repo
#       names no channel, or when one of the set's files cannot be read
#       (named, with why);
#   (5) a release directory given with a trailing `/` loads the same set,
#       each member directory under it with ONE separator;
#   (6) the fixture: the sha256 of a name that is not a member is "", and a
#       metadata key the packer writes only sometimes is added.
#
# Hermetic: TEST_TMPDIR, ScriptedChannel; no network.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs

from komira_libc.posix import _read_env
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_pkg_upload import SUBSTRATE_PREFIX_DEV_CONDA, PackageCoordinate, RegistrySet
from kci_release_set.member import ReleaseMember
from kci_publish import (
    PublishCredential,
    PublishTarget,
    ScriptedChannel,
    load_release,
    parse_release_version,
    read_new_names,
    require_closure,
    require_conda_only,
    require_lockstep,
)
from kci_publish.release_fixture import (
    EXAMPLE_HOST,
    ExampleRelease,
    example_artifacts,
    example_channel,
    example_channel_path,
    example_loaded,
    example_targets,
)


def _root(tag: String) raises -> String:
    var base = _read_env("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = _read_env("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/pse_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


def _members(tag: String) raises -> List[ReleaseMember]:
    """komira_alpha, komira_beta, then the metapackage komira."""
    var r = ExampleRelease()
    var d = _root(tag)
    r.write(d)
    return example_loaded(r, d).members.copy()


def _closure_refusal(members: List[ReleaseMember]) -> String:
    try:
        require_closure(members)
    except e:
        return String(e)
    return String("")


def test_a_member_that_is_not_conda_is_refused() raises:
    var m = _members(String("oci"))
    require_conda_only(m)
    m[1].manifest.artifact_type = String("OCI")
    var text = String("")
    try:
        require_conda_only(m)
    except e:
        text = String(e)
    assert_equal(
        text,
        String("PUBLISH step: the release set is refused:\n  artifact 'komira_beta' is OCI; a PUBLISH step publishes CONDA packages only"),
    )


def test_an_empty_set_is_refused_not_indexed() raises:
    var r = ExampleRelease()
    var rv = parse_release_version(r.release_version_text(), String("rv.txt"))
    var text = String("")
    try:
        require_lockstep(List[ReleaseMember](), rv)
    except e:
        text = String(e)
    assert_equal(text, String("PUBLISH step: lockstep refused:\n  the release set has no member"))
    assert_equal(
        _closure_refusal(List[ReleaseMember]()),
        String("PUBLISH step: requirement closure refused:\n  the release set has no member"),
    )


def test_a_metapackage_member_listed_twice_is_refused() raises:
    var m = _members(String("twice_row"))
    assert_equal(_closure_refusal(m), String(""))
    m[2].conda.members.append(m[2].conda.members[0].copy())
    var text = _closure_refusal(m)
    assert_true(
        text.find(String("\n  metapackage 'komira': member '") + m[2].conda.members[0].name + String("' is listed twice")) > 0,
        text,
    )


def test_a_metapackage_pin_required_twice_is_refused() raises:
    var m = _members(String("twice_pin"))
    var pin = String("komira_alpha ==1.0.0 h01234567_3")
    var found = False
    for d in range(len(m[2].conda.depends)):
        if m[2].conda.depends[d] == pin:
            found = True
    assert_true(found, String("the metapackage pins komira_alpha"))
    m[2].conda.depends.append(pin.copy())
    var text = _closure_refusal(m)
    assert_true(
        text.find(String("\n  metapackage 'komira': does not require '") + pin + String("' exactly once")) > 0,
        text,
    )
    assert_false(text.find(String("is not the guard or a member pin")) >= 0, text)


def _registry() raises -> RegistrySet[ScriptedChannel, PublishCredential]:
    var ch = ScriptedChannel(String(EXAMPLE_HOST), example_channel_path(String("example-stable")), String("linux-64"))
    return RegistrySet[ScriptedChannel, PublishCredential](ch^, PublishCredential())


def test_new_names_not_read() raises:
    var channel = example_channel(String("example-stable"))
    # an empty set
    var reg = _registry()
    var empty = read_new_names(reg, channel, List[PublishTarget](), String("publish-prod"), String("publish"))
    assert_false(empty.read)
    assert_equal(empty.detail, String("the release set is empty"))
    assert_equal(reg.transport().call_count(), 0)
    # a repo with no channel path
    var bad = List[PublishTarget]()
    bad.append(
        PublishTarget(
            String("komira_alpha"),
            False,
            PackageCoordinate(
                SUBSTRATE_PREFIX_DEV_CONDA,
                String(EXAMPLE_HOST),
                String("komira_alpha"),
                String("1.0.0"),
                String("linux-64"),
                String("komira_alpha-1.0.0-h01234567_3.conda"),
            ),
            String("0000000000000000000000000000000000000000000000000000000000000000"),
            String("/nonexistent"),
            0,
        )
    )
    var norepo = read_new_names(reg, channel, bad, String("publish-prod"), String("publish"))
    assert_false(norepo.read)
    assert_true(norepo.detail.find(String("names no channel")) >= 0, norepo.detail)
    assert_equal(reg.transport().call_count(), 0)
    # one of the set's files cannot be read
    var r = ExampleRelease()
    var d = _root(String("nn_fetch"))
    r.write(d)
    var t = example_targets(r, d)
    var ch = ScriptedChannel(String(EXAMPLE_HOST), example_channel_path(String("example-stable")), String("linux-64"))
    ch.fail_fetch_once(String("linux-64"), t[1].coordinate.file_name)
    var reg2 = RegistrySet[ScriptedChannel, PublishCredential](ch^, PublishCredential())
    var unread = read_new_names(reg2, channel, t, String("publish-prod"), String("publish"))
    assert_false(unread.read)
    assert_equal(len(unread.names), 0)
    assert_true(
        unread.detail.startswith(String("cannot tell: linux-64/") + t[1].coordinate.file_name + String(": ")), unread.detail
    )


def test_a_release_dir_with_a_trailing_slash() raises:
    var r = ExampleRelease()
    var d = _root(String("slash"))
    r.write(d)
    var plain = load_release(example_artifacts(r), d)
    var slashed = load_release(example_artifacts(r), d + String("/"))
    assert_equal(slashed.dir, d + String("/"))
    assert_equal(slashed.set_hash(), plain.set_hash())
    assert_equal(len(slashed.members), 3)
    for i in range(3):
        assert_equal(slashed.members[i].dir, d + String("/") + r.members[i].name)


def test_the_fixture_edges() raises:
    var r = ExampleRelease()
    assert_equal(r.sha256_of(String("komira_none")), String(""))
    assert_true(r.sha256_of(String("komira_alpha")).byte_length() == 64)
    r.set_meta(String("komira_alpha"), String("doc_files"), String("[]"))
    var alpha = r.metadata_json(r.members[0])
    assert_true(alpha.find(String('"doc_files"')) >= 0, alpha)
    var beta = r.metadata_json(r.members[1])
    assert_false(beta.find(String('"doc_files"')) >= 0, beta)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
