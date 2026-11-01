# =============================================================================
# src/kci_publish_oci/tests/test_publish_oci_grid.mojo
#   Every field of what the OCI image arm returns, against the file header of
#   arm.mojo, over grids rather than one example each:
#
#   - `publish_layout` over layouts (linux/amd64, linux/arm64, darwin/amd64,
#     missing) x expected digest (the layout's own, another) x revision (full,
#     abbreviated, empty) x platform (released, reserved, noarch, unknown) x
#     plan. The expected result of each cell comes from the header's check
#     order (revision, platform, layout reads, digest, layout platform, plan,
#     push), written here independently of the arm; the whole result (outcome,
#     error id, message, every artifact field) is compared, and every cell but
#     the one that pushes makes zero requests.
#   - Every PUSH_* end state through the arm, each compared whole (TAG_ADDED:
#     the tag is added to a manifest already there, still SUCCEEDED/UPLOADED).
#   - The mapping helpers over every PUSH_* code and codes komira_oci does not
#     define, `_hex_of` over prefixed and unprefixed digests, `ok()` and
#     `exit_code()` over every outcome word.
#   - `record_image_publish` over 0, 1 and 2 records of every kind: every
#     step row, every artifact row, and the FIRST error.
#
#   The expected artifact row is built from kci_api's `ResultArtifact()` and
#   literals, never with the arm's constructor or constants, so a change to
#   either goes red here. Error texts of kci_api and komira_oci (the
#   revision, platform and layout refusals the arm wraps) are read from those
#   packages, which the arm does not own.
# =============================================================================

from std.os import getenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_http_core.codec.types import HTTP_METHOD_HEAD, HTTP_METHOD_PUT

from komira_oci.oci_auth import OciAuth
from komira_oci.oci_fake_registry import FakeOciRegistry
from komira_oci.oci_layout_fixture import write_test_layout
from komira_oci.oci_layout_reader import read_oci_layout
from komira_oci.oci_push import (
    PUSH_FAILED,
    PUSH_INDETERMINATE,
    PUSH_NOOP,
    PUSH_PARTIAL,
    PUSH_REFUSED,
    PUSH_TAG_ADDED,
    PUSH_UPLOADED,
    LayoutPusher,
)

from kci_api import (
    ARTIFACT_ALREADY_PRESENT,
    ARTIFACT_NOT_REACHED,
    ARTIFACT_UPLOADED,
    ARTIFACT_WOULD_UPLOAD,
    ERROR_IMAGE_PLATFORM,
    ERROR_IMAGE_PUSH,
    ERROR_INTERNAL,
    ERROR_MEMBER,
    ERROR_PLATFORM,
    ERROR_REVISION,
    EXIT_INTERNAL,
    OUTCOME_FAILED,
    OUTCOME_INDETERMINATE,
    OUTCOME_NOOP,
    OUTCOME_PARTIAL,
    OUTCOME_REFUSED,
    OUTCOME_SUCCEEDED,
    ResultArtifact,
    RunResult,
    VERB_RUN,
    require_full_commit_id,
    require_release_platform,
)
from kci_publish_oci import ImagePublish, publish_layout, record_image_publish
from kci_publish_oci.arm import _effect_of, _hex_of, _outcome_of

comptime _HOST: String = "registry.example.test"
comptime _REPO: String = "example/kci-images/grid_image"
comptime _REV: String = "3f2a9c1d8b7e6f5a4c3b2a1908f7e6d5c4b3a291"
comptime _REV2: String = "0123456789abcdef0123456789abcdef01234567"
comptime _P: String = "PUBLISH step (image): "


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


def _dir(name: String) -> String:
    return getenv("TEST_TMPDIR", "/tmp") + String("/kci_publish_oci_grid_") + name


def _layout(name: String, os_name: String, arch: String) raises -> String:
    var dir = _dir(name)
    var layers = List[List[UInt8]]()
    layers.append(_bytes(String("grid-layer-one-") + name))
    layers.append(_bytes(String("grid-layer-two-") + name))
    _ = write_test_layout(dir, layers, os_name, arch)
    return dir^


def _pusher() -> LayoutPusher[FakeOciRegistry]:
    return LayoutPusher[FakeOciRegistry](
        FakeOciRegistry(_HOST), OciAuth.basic(String("publisher"), String("grid-secret")), False, 0
    )


def _err_revision(rev: String) -> String:
    try:
        require_full_commit_id(String("--revision-id"), rev)
    except e:
        return String(e)
    return String("")


def _err_platform(platform: String) -> String:
    try:
        require_release_platform(platform)
    except e:
        return String(e)
    return String("")


def _err_read(dir: String) -> String:
    try:
        _ = read_oci_layout(dir)
    except e:
        return String(e)
    return String("")


def _artifact(
    effect: String, name: String, file: String, platform: String, revision: String, sha256: String
) -> ResultArtifact:
    """The expected image row: built from kci_api's empty row and literals."""
    var a = ResultArtifact()
    a.effect = effect.copy()
    a.artifact_type = String("OCI")
    a.name = name.copy()
    a.file = file.copy()
    a.platform = platform.copy()
    a.revision = revision.copy()
    a.sha256 = sha256.copy()
    return a^


def _unreached() -> ResultArtifact:
    return _artifact(String(ARTIFACT_NOT_REACHED), String(""), String(""), String(""), String(""), String(""))


def _assert_artifact(got: ResultArtifact, want: ResultArtifact, ctx: String) raises:
    """Every field of `ResultArtifact`."""
    assert_equal(got.effect, want.effect, ctx + String(" effect"))
    assert_equal(got.artifact_type, want.artifact_type, ctx + String(" artifact_type"))
    assert_equal(got.build, want.build, ctx + String(" build"))
    assert_equal(got.file, want.file, ctx + String(" file"))
    assert_equal(got.indexed, want.indexed, ctx + String(" indexed"))
    assert_equal(got.name, want.name, ctx + String(" name"))
    assert_equal(got.platform, want.platform, ctx + String(" platform"))
    assert_equal(got.revision, want.revision, ctx + String(" revision"))
    assert_equal(got.sha256, want.sha256, ctx + String(" sha256"))
    assert_equal(got.state_after, want.state_after, ctx + String(" state_after"))
    assert_equal(got.state_before, want.state_before, ctx + String(" state_before"))
    assert_equal(got.subdir, want.subdir, ctx + String(" subdir"))
    assert_equal(got.version, want.version, ctx + String(" version"))


def _assert_publish(
    got: ImagePublish, outcome: String, error_id: String, message: String, want: ResultArtifact, ctx: String
) raises:
    """Every field of `ImagePublish`, its artifact row field by field."""
    assert_equal(got.outcome, outcome, ctx + String(" outcome: ") + got.message)
    assert_equal(got.error_id, error_id, ctx + String(" error_id: ") + got.message)
    assert_equal(got.message, message, ctx + String(" message"))
    _assert_artifact(got.artifact, want, ctx)


def _hex(digest: String) raises -> String:
    """The oracle's own strip: every layout digest is `sha256:` + 64 hex."""
    assert_true(digest.startswith(String("sha256:")))
    return String(digest[byte=7:])


def _pushed_row(effect: String, revision: String, digest: String) raises -> ResultArtifact:
    return _artifact(
        effect,
        String(_REPO),
        String(_HOST) + String("/") + String(_REPO) + String("@") + digest,
        String("linux-x86_64"),
        revision,
        _hex(digest),
    )


def test_check_order_grid_whole_result() raises:
    """Catches: any check removed, moved after another or after the push,
    skipped under plan; a wrong error id, message part or artifact field in
    any refusal, the plan row or the pushed row; a request made by a refusal
    or by plan."""
    var dirs = List[String]()
    var oci = List[String]()  # the layout's OCI platform; "" when missing
    dirs.append(_layout(String("amd64"), String("linux"), String("amd64")))
    oci.append(String("linux/amd64"))
    dirs.append(_layout(String("arm64"), String("linux"), String("arm64")))
    oci.append(String("linux/arm64"))
    dirs.append(_layout(String("darwin"), String("darwin"), String("amd64")))
    oci.append(String("darwin/amd64"))
    dirs.append(_dir(String("missing")))
    oci.append(String(""))
    var revisions = List[String]()
    revisions.append(String(_REV))
    revisions.append(String("3f2a9c1"))
    revisions.append(String(""))
    var platforms = List[String]()
    platforms.append(String("linux-x86_64"))
    platforms.append(String("linux-arm64"))
    platforms.append(String("noarch"))
    platforms.append(String("linux-x86_6"))
    var other = String("sha256:") + String("0") * 64
    var cells = 0
    var pushes = 0
    for f in range(len(dirs)):
        var dir = dirs[f].copy()
        var own = String("")
        if oci[f].byte_length() > 0:
            own = read_oci_layout(dir).manifest_digest
        for d in range(2):
            var expected = own.copy() if d == 0 else other.copy()
            for rv in range(len(revisions)):
                var rev = revisions[rv].copy()
                for pl in range(len(platforms)):
                    var platform = platforms[pl].copy()
                    for k in range(2):
                        var plan = k == 1
                        var ctx = (
                            String("[layout ") + oci[f] + String(" digest ") + String(d) + String(" rev '")
                            + rev + String("' platform ") + platform + String(" plan ") + String(plan)
                            + String("]")
                        )
                        var pusher = _pusher()
                        var got = publish_layout(
                            pusher, dir, expected, String(_HOST), String(_REPO), rev, platform, plan
                        )
                        cells += 1
                        var pushed = False
                        if rv != 0:
                            _assert_publish(
                                got,
                                String("REFUSED"),
                                String(ERROR_REVISION),
                                String(_P) + _err_revision(rev) + String(" (the image's tag is the revision)"),
                                _unreached(),
                                ctx,
                            )
                        elif pl != 0:
                            _assert_publish(
                                got,
                                String("REFUSED"),
                                String(ERROR_PLATFORM),
                                String(_P) + _err_platform(platform),
                                _unreached(),
                                ctx,
                            )
                        elif oci[f].byte_length() == 0:
                            _assert_publish(
                                got,
                                String("REFUSED"),
                                String(ERROR_IMAGE_PUSH),
                                String(_P) + String("the image layout is refused: ") + _err_read(dir),
                                _unreached(),
                                ctx,
                            )
                        elif d != 0:
                            _assert_publish(
                                got,
                                String("REFUSED"),
                                String(ERROR_MEMBER),
                                String(_P) + String("the image layout '") + dir + String("' is ") + own
                                + String(", not ") + other
                                + String(", the digest the release set names for it: the layout changed")
                                + String(" after the set was verified. Nothing was sent."),
                                _unreached(),
                                ctx,
                            )
                        elif f != 0:
                            _assert_publish(
                                got,
                                String("REFUSED"),
                                String(ERROR_IMAGE_PLATFORM),
                                String(_P) + String("the image layout '") + dir + String("' is for ") + oci[f]
                                + String("; this step publishes linux-x86_64 (linux/amd64). Nothing was sent."),
                                _unreached(),
                                ctx,
                            )
                        elif plan:
                            _assert_publish(
                                got,
                                String("SUCCEEDED"),
                                String(""),
                                String(_P) + String("plan: would push ") + own + String(" to ") + String(_HOST)
                                + String("/") + String(_REPO) + String(":") + String(_REV)
                                + String("; nothing was sent"),
                                _pushed_row(String("WOULD_UPLOAD"), String(_REV), own),
                                ctx,
                            )
                        else:
                            pushed = True
                            pushes += 1
                            _assert_publish(
                                got,
                                String("SUCCEEDED"),
                                String(""),
                                String(_P) + String("UPLOADED ") + String(_HOST) + String("/") + String(_REPO)
                                + String("@") + own,
                                _pushed_row(String("UPLOADED"), String(_REV), own),
                                ctx,
                            )
                        if pushed:
                            assert_true(pusher.transport().call_count() > 0, ctx)
                            assert_equal(pusher.transport().tag_digest(_REPO, _REV), own, ctx)
                        else:
                            assert_equal(pusher.transport().call_count(), 0, ctx + String(" zero requests"))
    assert_equal(cells, 4 * 2 * 3 * 4 * 2)
    assert_equal(pushes, 1)


def _tag_on_other_registry() -> FakeOciRegistry:
    var reg = FakeOciRegistry(_HOST)
    var other = reg.seed_manifest(
        _REPO, String("application/vnd.oci.image.manifest.v1+json"), _bytes(String('{"schemaVersion": 2, "x": 1}'))
    )
    reg.seed_tag(_REPO, _REV, other)
    return reg^


def _failing_message(got: ImagePublish, word: String, digest: String, ctx: String) raises:
    """`PUBLISH step (image): <PUSH word> <host>/<repo>@<digest>: <detail>`,
    the detail (komira_oci's words) not empty."""
    var head = String(_P) + word + String(" ") + String(_HOST) + String("/") + String(_REPO) + String("@") + digest
    assert_true(got.message.startswith(head + String(": ")), ctx + String(": ") + got.message)
    assert_true(got.message.byte_length() > head.byte_length() + 2, ctx + String(" detail: ") + got.message)


def test_every_push_end_state_whole_result() raises:
    """Catches: a PUSH_* code mapped to the wrong outcome, error id, effect or
    message word; the detail appended on success or dropped on failure; the
    reference or a row field written from the wrong value; TAG_ADDED (the
    manifest was already there under another tag) not a success."""
    var dir = _layout(String("states"), String("linux"), String("amd64"))
    var own = read_oci_layout(dir).manifest_digest

    # UPLOADED, then TAG_ADDED (same bytes, new tag), then NOOP (same tag)
    var pusher = _pusher()
    var up = publish_layout(
        pusher, dir, own, String(_HOST), String(_REPO), String(_REV), String("linux-x86_64"), False
    )
    _assert_publish(
        up,
        String("SUCCEEDED"),
        String(""),
        String(_P) + String("UPLOADED ") + String(_HOST) + String("/") + String(_REPO) + String("@") + own,
        _pushed_row(String("UPLOADED"), String(_REV), own),
        String("uploaded"),
    )
    var added = publish_layout(
        pusher, dir, own, String(_HOST), String(_REPO), String(_REV2), String("linux-x86_64"), False
    )
    _assert_publish(
        added,
        String("SUCCEEDED"),
        String(""),
        String(_P) + String("TAG_ADDED ") + String(_HOST) + String("/") + String(_REPO) + String("@") + own,
        _pushed_row(String("UPLOADED"), String(_REV2), own),
        String("tag added"),
    )
    assert_equal(pusher.transport().tag_digest(_REPO, _REV2), own)
    assert_equal(added.exit_code(), 0)
    var same = publish_layout(
        pusher, dir, own, String(_HOST), String(_REPO), String(_REV2), String("linux-x86_64"), False
    )
    _assert_publish(
        same,
        String("NOOP"),
        String(""),
        String(_P) + String("NOOP ") + String(_HOST) + String("/") + String(_REPO) + String("@") + own,
        _pushed_row(String("ALREADY_PRESENT"), String(_REV2), own),
        String("noop"),
    )

    # REFUSED: the tag names another manifest
    var refused_pusher = LayoutPusher[FakeOciRegistry](
        _tag_on_other_registry(), OciAuth.basic(String("publisher"), String("grid-secret")), False, 0
    )
    var refused = publish_layout(
        refused_pusher, dir, own, String(_HOST), String(_REPO), String(_REV), String("linux-x86_64"), False
    )
    assert_equal(refused.outcome, String("REFUSED"))
    assert_equal(refused.error_id, String(ERROR_IMAGE_PUSH))
    _failing_message(refused, String("REFUSED"), own, String("refused"))
    _assert_artifact(refused.artifact, _pushed_row(String("NOT_REACHED"), String(_REV), own), String("refused"))

    # FAILED: the credential is refused
    var reg_auth = FakeOciRegistry(_HOST)
    reg_auth.required_authorization = String("Basic c29tZW9uZS1lbHNl")
    var failed_pusher = LayoutPusher[FakeOciRegistry](
        reg_auth^, OciAuth.basic(String("publisher"), String("grid-secret")), False, 0
    )
    var failed = publish_layout(
        failed_pusher, dir, own, String(_HOST), String(_REPO), String(_REV), String("linux-x86_64"), False
    )
    assert_equal(failed.outcome, String("FAILED"))
    assert_equal(failed.error_id, String(ERROR_IMAGE_PUSH))
    _failing_message(failed, String("FAILED"), own, String("failed"))
    _assert_artifact(failed.artifact, _pushed_row(String("NOT_REACHED"), String(_REV), own), String("failed"))
    assert_equal(failed.message.find(String("grid-secret")), -1, failed.message)

    # INDETERMINATE: the tag PUT failed and the tag cannot be read back
    var reg_ind = FakeOciRegistry(_HOST)
    reg_ind.add_fault(HTTP_METHOD_PUT, _REV, 500, 1)
    reg_ind.add_fault(HTTP_METHOD_HEAD, String("/manifests/") + String(_REV), 503, 100, 1)
    var ind_pusher = LayoutPusher[FakeOciRegistry](
        reg_ind^, OciAuth.basic(String("publisher"), String("grid-secret")), False, 0
    )
    var ind = publish_layout(
        ind_pusher, dir, own, String(_HOST), String(_REPO), String(_REV), String("linux-x86_64"), False
    )
    assert_equal(ind.outcome, String("INDETERMINATE"))
    assert_equal(ind.error_id, String(ERROR_IMAGE_PUSH))
    _failing_message(ind, String("INDETERMINATE"), own, String("indeterminate"))
    _assert_artifact(ind.artifact, _pushed_row(String("NOT_REACHED"), String(_REV), own), String("indeterminate"))

    # PARTIAL: the bytes landed, the tag never did
    var reg_part = FakeOciRegistry(_HOST)
    reg_part.add_fault(HTTP_METHOD_PUT, _REV, 503, 100)
    var part_pusher = LayoutPusher[FakeOciRegistry](
        reg_part^, OciAuth.basic(String("publisher"), String("grid-secret")), False, 0
    )
    var part = publish_layout(
        part_pusher, dir, own, String(_HOST), String(_REPO), String(_REV), String("linux-x86_64"), False
    )
    assert_equal(part.outcome, String("PARTIAL"))
    assert_equal(part.error_id, String(ERROR_IMAGE_PUSH))
    _failing_message(part, String("PARTIAL"), own, String("partial"))
    _assert_artifact(part.artifact, _pushed_row(String("UPLOADED"), String(_REV), own), String("partial"))


def test_push_code_mapping_every_code() raises:
    """Catches: any row of the header's PUSH_* table changed, TAG_ADDED or
    PARTIAL dropped from the UPLOADED effect, a code komira_oci adds later
    mapped to anything but FAILED / NOT_REACHED."""
    assert_equal(PUSH_UPLOADED, 0)
    assert_equal(PUSH_NOOP, 1)
    assert_equal(PUSH_TAG_ADDED, 2)
    assert_equal(PUSH_REFUSED, 3)
    assert_equal(PUSH_FAILED, 4)
    assert_equal(PUSH_INDETERMINATE, 5)
    assert_equal(PUSH_PARTIAL, 6)
    var outcomes = List[String]()
    var effects = List[String]()
    outcomes.append(String("SUCCEEDED"))  # 0 UPLOADED
    effects.append(String("UPLOADED"))
    outcomes.append(String("NOOP"))  # 1 NOOP
    effects.append(String("ALREADY_PRESENT"))
    outcomes.append(String("SUCCEEDED"))  # 2 TAG_ADDED
    effects.append(String("UPLOADED"))
    outcomes.append(String("REFUSED"))  # 3 REFUSED
    effects.append(String("NOT_REACHED"))
    outcomes.append(String("FAILED"))  # 4 FAILED
    effects.append(String("NOT_REACHED"))
    outcomes.append(String("INDETERMINATE"))  # 5 INDETERMINATE
    effects.append(String("NOT_REACHED"))
    outcomes.append(String("PARTIAL"))  # 6 PARTIAL: usable by digest
    effects.append(String("UPLOADED"))
    for code in range(7):
        assert_equal(_outcome_of(code), outcomes[code], String("outcome of ") + String(code))
        assert_equal(_effect_of(code), effects[code], String("effect of ") + String(code))
    var unknown = List[Int]()
    unknown.append(-1)
    unknown.append(7)
    unknown.append(8)
    unknown.append(100)
    for i in range(len(unknown)):
        assert_equal(_outcome_of(unknown[i]), String("FAILED"), String("outcome of ") + String(unknown[i]))
        assert_equal(_effect_of(unknown[i]), String("NOT_REACHED"), String("effect of ") + String(unknown[i]))


def test_hex_of_strips_only_the_sha256_algorithm() raises:
    """The artifact row's `sha256` is the hex of `sha256:<hex>`; text that
    does not start with exactly `sha256:` is already not prefixed and is kept
    as it is. Catches: the prefix test loosened (no colon, any case), the
    slice off by one, the unprefixed text dropped or sliced."""
    var hex = String("a") * 32 + String("0") * 31 + String("f")
    assert_equal(_hex_of(String("sha256:") + hex), hex)
    assert_equal(_hex_of(String("sha256:a")), String("a"))
    assert_equal(_hex_of(String("sha256:")), String(""))
    assert_equal(_hex_of(hex), hex)
    assert_equal(_hex_of(String("")), String(""))
    assert_equal(_hex_of(String("sha256")), String("sha256"))
    assert_equal(_hex_of(String("sha256ab")), String("sha256ab"))
    assert_equal(_hex_of(String("SHA256:ab")), String("SHA256:ab"))
    assert_equal(_hex_of(String("xsha256:ab")), String("xsha256:ab"))
    assert_equal(_hex_of(String("sha512:ab")), String("sha512:ab"))


def test_new_image_publish_ok_and_exit_code_every_outcome() raises:
    """Catches: the default row's type or effect changed, any other field
    filled; ok() true for a non-success or false for NOOP or SUCCEEDED;
    exit_code() dropping the error id (KCI-E-INTERNAL exits 1 whatever the
    outcome, kci_api's table)."""
    var words = List[String]()
    var ok = List[Bool]()
    var code = List[Int]()
    words.append(String(OUTCOME_SUCCEEDED))
    ok.append(True)
    code.append(0)
    words.append(String(OUTCOME_NOOP))
    ok.append(True)
    code.append(0)
    words.append(String(OUTCOME_REFUSED))
    ok.append(False)
    code.append(3)
    words.append(String(OUTCOME_FAILED))
    ok.append(False)
    code.append(4)
    words.append(String(OUTCOME_INDETERMINATE))
    ok.append(False)
    code.append(5)
    words.append(String(OUTCOME_PARTIAL))
    ok.append(False)
    code.append(6)
    for i in range(len(words)):
        var p = ImagePublish(words[i].copy(), String(""), String("m") + String(i))
        _assert_publish(p, words[i], String(""), String("m") + String(i), _unreached(), words[i])
        assert_equal(p.ok(), ok[i], words[i])
        assert_equal(p.exit_code(), code[i], words[i])
        var internal = ImagePublish(words[i].copy(), String(ERROR_INTERNAL), String("x"))
        assert_equal(internal.exit_code(), EXIT_INTERNAL, words[i] + String(" with KCI-E-INTERNAL"))
    assert_equal(EXIT_INTERNAL, 1)


def _kind_publish(kind: Int, i: Int) -> ImagePublish:
    """kind 0: SUCCEEDED; 1: REFUSED KCI-E-MEMBER; 2: FAILED KCI-E-IMAGE-PUSH.
    Every artifact field distinct per record, so a row copied from the wrong
    record or a field dropped goes red."""
    var p: ImagePublish
    if kind == 0:
        p = ImagePublish(String(OUTCOME_SUCCEEDED), String(""), String("ok-") + String(i))
    elif kind == 1:
        p = ImagePublish(String(OUTCOME_REFUSED), String(ERROR_MEMBER), String("member-") + String(i))
    else:
        p = ImagePublish(String(OUTCOME_FAILED), String(ERROR_IMAGE_PUSH), String("push-") + String(i))
    var s = String(i) + String("-") + String(kind)
    p.artifact.effect = String("effect-") + s
    p.artifact.artifact_type = String("type-") + s
    p.artifact.build = String("build-") + s
    p.artifact.file = String("file-") + s
    p.artifact.indexed = i % 2 == 1
    p.artifact.name = String("name-") + s
    p.artifact.platform = String("aplat-") + s
    p.artifact.revision = String("rev-") + s
    p.artifact.sha256 = String("sha-") + s
    p.artifact.state_after = String("after-") + s
    p.artifact.state_before = String("before-") + s
    p.artifact.subdir = String("subdir-") + s
    p.artifact.version = String("version-") + s
    return p^


def test_record_zero_one_two_of_every_kind() raises:
    """Catches: a step row with the wrong name, kind, platform, outcome or
    selection; the artifact row not appended or not the record's; the error
    set for a success (no id), not set for a failure, or a later error
    replacing the first; another record's values used."""
    var cases = 0
    for n in range(3):
        var combos = 1
        for _ in range(n):
            combos *= 3
        for c in range(combos):
            var kinds = List[Int]()
            var rest = c
            for _ in range(n):
                kinds.append(rest % 3)
                rest //= 3
            var r = RunResult(String(VERB_RUN), String(VERB_RUN))
            var recs = List[ImagePublish]()
            for i in range(n):
                recs.append(_kind_publish(kinds[i], i))
                record_image_publish(recs[i], String("step-") + String(i), String("plat-") + String(i), r)
            cases += 1
            var ctx = String("n=") + String(n) + String(" combo ") + String(c)
            assert_equal(len(r.steps), n, ctx)
            assert_equal(len(r.artifacts), n, ctx)
            var first = -1
            for i in range(n):
                var ictx = ctx + String(" record ") + String(i)
                assert_equal(r.steps[i].name, String("step-") + String(i), ictx)
                assert_equal(r.steps[i].kind, String("PUBLISH"), ictx)
                assert_equal(r.steps[i].platform, String("plat-") + String(i), ictx)
                assert_true(r.steps[i].selected, ictx)
                assert_equal(r.steps[i].outcome, recs[i].outcome, ictx)
                assert_equal(r.steps[i].credential_probe, String(""), ictx)
                _assert_artifact(r.artifacts[i], recs[i].artifact, ictx)
                if first < 0 and kinds[i] != 0:
                    first = i
            if first < 0:
                assert_false(r.has_error, ctx)
                assert_equal(r.error.id, String(""), ctx)
                assert_equal(r.error.message, String(""), ctx)
            else:
                assert_true(r.has_error, ctx)
                assert_equal(r.error.id, recs[first].error_id, ctx)
                assert_equal(r.error.message, recs[first].message, ctx)
    assert_equal(cases, 1 + 3 + 9)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
