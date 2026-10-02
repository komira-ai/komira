# =============================================================================
# src/kci_publish/tests/test_publish_plan.mojo -- resolving artifacts to
#   channel repositories, the approved-names gate, and the pure plan.
# =============================================================================
#
# ROWS
#   (1) each artifact goes to its channel's repository for its type: the
#       coordinate's repo, substrate and location come from the declaration;
#   (2) refusals, all listed in ONE error: a channel with no repository for
#       the type (naming channel and type), a file name that is not the
#       artifact's name and version, a non-.conda file, a wheel of another
#       project, the same file listed twice, an unknown channel;
#   (3) the gate refuses ALL when any name is unapproved and names every
#       unapproved name once; PEP 503 applies to PYTHON names only;
#   (4) presence -> action: ABSENT UPLOAD, PRESENT_IDENTICAL SKIP,
#       PRESENT_DIFFERENT / NO_COMMON_FIELD a definite REFUSE, UNKNOWN /
#       AUTH_REFUSED / RATE_LIMITED a cannot-tell REFUSE; mismatched list
#       lengths raise.
#
# Hermetic: pure functions over values built here.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from kci_pkg_upload import (
    PRESENCE_ABSENT,
    PRESENCE_AUTH_REFUSED,
    PRESENCE_NO_COMMON_FIELD,
    PRESENCE_PRESENT_DIFFERENT,
    PRESENCE_PRESENT_IDENTICAL,
    PRESENCE_RATE_LIMITED,
    PRESENCE_UNKNOWN,
    SUBSTRATE_PREFIX_DEV_CONDA,
    SUBSTRATE_PUBLIC_PYPI,
    ApprovedNames,
    ContentIdentity,
    Presence,
)
from kci_release_channel import ChannelDeclaration, ChannelRepository

from kci_publish import (
    ACTION_REFUSE,
    ACTION_SKIP,
    ACTION_UPLOAD,
    ArtifactManifest,
    PublishTarget,
    plan_from_presence,
    refuse_unapproved_names,
    resolve_targets,
)


comptime _SHA: String = "d92ee691780d0dbc4dd45de1287d8980462041de9bd2fe3d7f8b89044a18cf52"


def _decls() -> List[ChannelDeclaration]:
    var repos = List[ChannelRepository]()
    repos.append(
        ChannelRepository(
            String("CONDA"),
            String("https://conda.example.invalid/example-stable"),
            String("publisher@example.invalid"),
        )
    )
    repos.append(
        ChannelRepository(
            String("PYTHON"),
            String("https://index.example.invalid"),
            String("publisher@example.invalid"),
        )
    )
    var conda_only = List[ChannelRepository]()
    conda_only.append(
        ChannelRepository(
            String("CONDA"),
            String("https://conda.example.invalid/example-nightly"),
            String("publisher@example.invalid"),
        )
    )
    var out = List[ChannelDeclaration]()
    out.append(ChannelDeclaration(String("example-stable"), String("PUBLIC"), repos^))
    out.append(
        ChannelDeclaration(String("example-nightly"), String("PUBLIC"), conda_only^)
    )
    return out^


def _conda(
    name: String = String("example-pkg"),
    subdir: String = String("linux-64"),
    file: String = String("example-pkg-1.2.3-h0_0.conda"),
) -> ArtifactManifest:
    var m = ArtifactManifest(String("manifests/") + subdir + String(".json"))
    m.artifact_type = String("CONDA")
    m.name = name.copy()
    m.version = String("1.2.3")
    m.subdir = subdir.copy()
    m.file_path = String("out/") + file
    m.sha256_hex = String(_SHA)
    return m^


def _wheel(name: String, file: String) -> ArtifactManifest:
    var m = ArtifactManifest(String("manifests/wheel.json"))
    m.artifact_type = String("PYTHON")
    m.name = name.copy()
    m.version = String("1.2.3")
    m.file_path = String("dist/") + file
    m.sha256_hex = String(_SHA)
    m.metadata_path = String("dist/METADATA")
    return m^


def _refusal(
    channel: String, manifests: List[ArtifactManifest]
) -> String:
    try:
        _ = resolve_targets(_decls(), channel, manifests)
    except e:
        return String(e)
    return String("")


def test_artifacts_go_to_their_repository() raises:
    var ms = List[ArtifactManifest]()
    ms.append(_conda())
    ms.append(_conda(subdir=String("osx-arm64")))
    ms.append(_wheel(String("Example_Pkg"), String("example_pkg-1.2.3-py3-none-any.whl")))
    var ts = resolve_targets(_decls(), String("example-stable"), ms)
    assert_equal(len(ts), 3)
    assert_equal(ts[0].coordinate.substrate, SUBSTRATE_PREFIX_DEV_CONDA)
    assert_equal(ts[0].coordinate.repo, String("conda.example.invalid/example-stable"))
    assert_equal(ts[0].location, String("https://conda.example.invalid/example-stable"))
    assert_equal(ts[0].coordinate.file_name, String("example-pkg-1.2.3-h0_0.conda"))
    assert_equal(ts[0].file_path, String("out/example-pkg-1.2.3-h0_0.conda"))
    assert_equal(
        ts[1].where(),
        String("https://conda.example.invalid/example-stable/osx-arm64/example-pkg-1.2.3-h0_0.conda"),
    )
    assert_equal(ts[2].coordinate.substrate, SUBSTRATE_PUBLIC_PYPI)
    assert_equal(ts[2].coordinate.repo, String("index.example.invalid"))
    assert_equal(ts[2].metadata_path, String("dist/METADATA"))
    assert_equal(
        ts[2].where(),
        String("https://index.example.invalid/example_pkg-1.2.3-py3-none-any.whl"),
    )


def test_every_refusal_in_one_error() raises:
    var ms = List[ArtifactManifest]()
    ms.append(_wheel(String("example-pkg"), String("example_pkg-1.2.3-py3-none-any.whl")))
    ms.append(_conda(file=String("example-pkg-1.2.4-h0_0.conda")))
    ms.append(_conda(file=String("example-pkg-1.2.3-h0_0.tar.bz2")))
    var why = _refusal(String("example-nightly"), ms)
    assert_true(why.find(String("refused before any upload")) >= 0, why)
    assert_true(
        why.find(String("channel 'example-nightly' declares no PYTHON repository")) >= 0,
        why,
    )
    assert_true(why.find(String("does not name the file 'example-pkg-1.2.4-h0_0.conda'")) >= 0, why)
    assert_true(why.find(String("is not a .conda file")) >= 0, why)
    var ws = List[ArtifactManifest]()
    ws.append(_wheel(String("example-pkg"), String("other_pkg-1.2.3-py3-none-any.whl")))
    why = _refusal(String("example-stable"), ws)
    assert_true(why.find(String("is not example-pkg 1.2.3")) >= 0, why)
    var dup = List[ArtifactManifest]()
    dup.append(_conda())
    dup.append(_conda())
    why = _refusal(String("example-stable"), dup)
    assert_true(why.find(String("is listed by two manifests")) >= 0, why)
    var one = List[ArtifactManifest]()
    one.append(_conda())
    why = _refusal(String("example-beta"), one)
    assert_true(why.find(String("unknown release channel 'example-beta'")) >= 0, why)


def _targets() raises -> List[PublishTarget]:
    var ms = List[ArtifactManifest]()
    ms.append(_conda())
    ms.append(_conda(String("other-pkg"), String("linux-64"), String("other-pkg-1.2.3-h0_0.conda")))
    ms.append(_conda(String("third-pkg"), String("linux-64"), String("third-pkg-1.2.3-h0_0.conda")))
    ms.append(_conda(String("other-pkg"), String("osx-arm64"), String("other-pkg-1.2.3-h0_0.conda")))
    ms.append(_wheel(String("Example.Tool"), String("example_tool-1.2.3-py3-none-any.whl")))
    return resolve_targets(_decls(), String("example-stable"), ms)


def test_the_gate_refuses_all_naming_every_name() raises:
    var ts = _targets()
    var names = ApprovedNames()
    names.approve(String("example-pkg"))
    names.approve(String("example-tool"))
    var why = String("")
    try:
        refuse_unapproved_names(ts, names)
    except e:
        why = String(e)
    assert_true(why.find(String("not in the approved-names list (2 approved): other-pkg, third-pkg.")) >= 0, why)
    names.approve(String("OTHER-pkg"))
    names.approve(String("third-pkg"))
    refuse_unapproved_names(ts, names)
    var conda_strict = ApprovedNames()
    conda_strict.approve(String("example_pkg"))
    why = String("")
    var one = List[PublishTarget]()
    one.append(ts[0].copy())
    try:
        refuse_unapproved_names(one, conda_strict)
    except e:
        why = String(e)
    assert_true(why.find(String(": example-pkg.")) >= 0, why)


def _p(kind: Int) -> Presence:
    return Presence(kind, 200, ContentIdentity.none(), String("detail"))


def test_presence_to_action() raises:
    var ts = _targets()
    var decls = _decls()
    var kinds = List[Int]()
    kinds.append(PRESENCE_ABSENT)
    kinds.append(PRESENCE_PRESENT_IDENTICAL)
    kinds.append(PRESENCE_PRESENT_DIFFERENT)
    kinds.append(PRESENCE_NO_COMMON_FIELD)
    kinds.append(PRESENCE_UNKNOWN)
    var ps = List[Presence]()
    for i in range(len(kinds)):
        ps.append(_p(kinds[i]))
    var plan = plan_from_presence(decls[0], ts, ps)
    assert_equal(plan.channel, String("example-stable"))
    assert_equal(plan.entries[0].action, ACTION_UPLOAD)
    assert_equal(plan.entries[1].action, ACTION_SKIP)
    assert_equal(plan.entries[2].action, ACTION_REFUSE)
    assert_false(plan.entries[2].cannot_tell)
    assert_true(plan.entries[2].reason.find(String("PRESENT_DIFFERENT")) >= 0, plan.entries[2].reason)
    assert_equal(plan.entries[3].action, ACTION_REFUSE)
    assert_false(plan.entries[3].cannot_tell)
    assert_equal(plan.entries[4].action, ACTION_REFUSE)
    assert_true(plan.entries[4].cannot_tell)
    assert_true(plan.has_definite_refusal())
    assert_equal(plan.count(ACTION_REFUSE), 3)
    var unreadable = List[Int]()
    unreadable.append(PRESENCE_UNKNOWN)
    unreadable.append(PRESENCE_AUTH_REFUSED)
    unreadable.append(PRESENCE_RATE_LIMITED)
    unreadable.append(PRESENCE_ABSENT)
    unreadable.append(PRESENCE_ABSENT)
    var qs = List[Presence]()
    for i in range(len(unreadable)):
        qs.append(_p(unreadable[i]))
    var p2 = plan_from_presence(decls[0], ts, qs)
    assert_equal(p2.count(ACTION_REFUSE), 3)
    assert_false(p2.has_definite_refusal())
    var short = List[Presence]()
    short.append(_p(PRESENCE_ABSENT))
    var why = String("")
    try:
        _ = plan_from_presence(decls[0], ts, short)
    except e:
        why = String(e)
    assert_true(why.find(String("5 targets but 1 presence answers")) >= 0, why)


def main() raises:
    test_artifacts_go_to_their_repository()
    test_every_refusal_in_one_error()
    test_the_gate_refuses_all_naming_every_name()
    test_presence_to_action()
    print("test_publish_plan: ALL PASS")
