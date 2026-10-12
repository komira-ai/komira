# =============================================================================
# test_header_environment.mojo
# =============================================================================
#
# The pair (plan, environment image): optimized_plan_udf_runtime.md §10.11
# checks 1-3, which need only the manifest bytes, through
# `admit_plan_environment`.
# Each manifest is built here and digested with komira_crypto's sha256, so
# its digest is right unless a test makes it wrong. What each test proves,
# and the defect it catches:
#
#   test_released_base_admitted: an image built FROM a released base, and the
#     base image itself, are admitted and name that base. Catches a prefix
#     check that requires added layers or compares layer sets.
#   test_longest_base_wins: when a base and a base built FROM it both match,
#     the longer one is the image's base, whatever the release order.
#     Catches "first match wins".
#   test_base_unreleased: OPTIMIZED_ENV_BASE_UNRELEASED for a digest that is
#     not `sha256:` and 64 lower-case hex digits, a digest that is not the
#     manifest's sha256, a manifest that is not JSON, names `layers` twice,
#     has no `layers` array or a layer with no string digest, layers out of
#     order, fewer layers than the base, and a release with no layers.
#     Catches an unordered (set) prefix, a check of the first layer only, a
#     duplicate-key parser differential and an empty prefix that matches all.
#   test_engine_too_old: OPTIMIZED_ENV_ENGINE_TOO_OLD when the base lacks the
#     plan's format_version or its contract version, naming the base's sets
#     and the oldest release that accepts both (not one that accepts only
#     one), or that none does. With two releases that accept both, then a
#     newer r3, it names the first in `releases` order. Catches `or` for
#     `and`, `>=` membership, and a scan that lets the last match win.
#   Every refusal ends citing its check of optimized_plan_udf_runtime.md
#     §10.11. Catches a message citing another design file or check.
#   test_runtime_missing: OPTIMIZED_ENV_RUNTIME_MISSING for a runtime the
#     base lacks and for a runtime whose ABI tag differs, naming the pair, and
#     for the second of two needs. Catches a runtime-only comparison and a
#     check of the first need only.
#   test_header_fields_required: a header with no producer, or no needs,
#     is refused by name rather than read as empty.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_crypto import hex_lower_array_32, sha256
from komira_optimized_plan_header import (
    OPTIMIZED_ENV_BASE_UNRELEASED,
    OPTIMIZED_ENV_ENGINE_TOO_OLD,
    OPTIMIZED_ENV_RUNTIME_MISSING,
    OPTIMIZED_PLAN_NEEDS_MISSING,
    OPTIMIZED_PLAN_PRODUCER_MISSING,
    BaseRelease,
    PlanEnvironment,
    admit_plan_environment,
)
from komira_plan_proto.optimized_plan import DeclaredNeeds, OptimizedPlan, ProducerStamp, RuntimeNeed


def _rep(c: String, n: Int) -> String:
    var out = String("")
    for _ in range(n):
        out += c
    return out


def _layer(c: String) -> String:
    return "sha256:" + _rep(c, 64)


def _bytes(n: Int, v: UInt8) -> List[UInt8]:
    var b = List[UInt8]()
    for _ in range(n):
        b.append(v)
    return b^


def _utf8(s: String) -> List[UInt8]:
    var b = List[UInt8]()
    for c in s.as_bytes():
        b.append(c)
    return b^


def _manifest_text(layers: List[String]) -> String:
    var out = String('{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json",')
    out += '"config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"' + _layer("c") + '","size":7},'
    out += '"layers":['
    for i in range(len(layers)):
        if i > 0:
            out += ","
        out += '{"mediaType":"application/vnd.oci.image.layer.v1.tar+gzip","digest":"' + layers[i] + '","size":9}'
    return out + "]}"


def _env_of_text(text: String) -> PlanEnvironment:
    var bytes = _utf8(text)
    var digest = String("sha256:") + hex_lower_array_32(sha256(Span(bytes)))
    return PlanEnvironment(digest, bytes^)


def _env(layers: List[String]) -> PlanEnvironment:
    return _env_of_text(_manifest_text(layers))


def _python() -> List[RuntimeNeed]:
    return [RuntimeNeed("komira/native", ""), RuntimeNeed("komira/python", "cp312")]


def _release(name: String, layers: List[String], formats: List[UInt32], contracts: List[UInt32]) -> BaseRelease:
    return BaseRelease(name, layers.copy(), formats.copy(), contracts.copy(), _python())


def _releases() -> List[BaseRelease]:
    """Two releases of one base: r1 accepts {1}/{1}, r2 accepts {1, 2}/{1, 2}."""
    return [
        _release("base-py312 r1", [_layer("1"), _layer("2")], [UInt32(1)], [UInt32(1)]),
        _release("base-py312 r2", [_layer("1"), _layer("3")], [UInt32(1), 2], [UInt32(1), 2]),
    ]


def _plan(format: UInt32, contract: UInt32, runtimes: List[RuntimeNeed]) -> OptimizedPlan:
    var stamp = ProducerStamp(_bytes(32, 0xAB), contract, List[UInt8](), "komira/python-sdk")
    var needs = DeclaredNeeds(List[String](), False, runtimes.copy())
    return OptimizedPlan(format, stamp^, _bytes(32, 0xCD), List[UInt8](), needs^, None, None, List[UInt8]())


def _r1_image() -> List[String]:
    """An image built FROM r1: its two layers, then a code layer."""
    return [_layer("1"), _layer("2"), _layer("9")]


def _refused(
    h: OptimizedPlan, env: PlanEnvironment, releases: List[BaseRelease], token: String, needle: String, what: String
) raises:
    var refused = False
    try:
        _ = admit_plan_environment(h, env, releases)
    except e:
        refused = True
        var text = String(e)
        assert_true(text.startswith(token + ":"), what + ": refused with another token: " + text)
        assert_true(needle in text, what + ": the refusal does not say `" + needle + "`: " + text)
    assert_true(refused, what + ": admitted, expected " + token)


def _unreleased(env: PlanEnvironment, needle: String, what: String) raises:
    _refused(_plan(1, 1, _python()), env, _releases(), OPTIMIZED_ENV_BASE_UNRELEASED, needle, what)


def test_released_base_admitted() raises:
    assert_equal(admit_plan_environment(_plan(1, 1, _python()), _env(_r1_image()), _releases()), 0, "FROM r1")
    var r2_image: List[String] = [_layer("1"), _layer("3"), _layer("8"), _layer("9")]
    assert_equal(admit_plan_environment(_plan(2, 2, _python()), _env(r2_image), _releases()), 1, "FROM r2")
    var bare: List[String] = [_layer("1"), _layer("2")]
    assert_equal(admit_plan_environment(_plan(1, 1, List[RuntimeNeed]()), _env(bare), _releases()), 0, "r1 itself")


def test_longest_base_wins() raises:
    var gpu = _release("base-py312 r1 gpu", [_layer("1"), _layer("2"), _layer("4")], [UInt32(1)], [UInt32(1)])
    var image: List[String] = [_layer("1"), _layer("2"), _layer("4"), _layer("9")]
    var forward = _releases()
    forward.append(gpu.copy())
    assert_equal(admit_plan_environment(_plan(1, 1, _python()), _env(image), forward), 2, "the gpu base, listed last")
    var backward: List[BaseRelease] = [gpu.copy()]
    backward.extend(_releases())
    assert_equal(admit_plan_environment(_plan(1, 1, _python()), _env(image), backward), 0, "the gpu base, listed first")


def test_base_unreleased() raises:
    var env = _env(_r1_image())
    var short = env.copy()
    short.image_digest = "sha256:" + _rep("a", 63)
    _unreleased(
        short,
        "is not sha256: and 64 lower-case hex digits (optimized_plan_udf_runtime.md §10.11 check 1)",
        "a 63-digit digest",
    )
    var long = env.copy()
    long.image_digest = "sha256:" + _rep("a", 65)
    _unreleased(long, "is not sha256: and 64 lower-case hex digits", "a 65-digit digest")
    var upper = env.copy()
    upper.image_digest = "sha256:" + _rep("A", 64)
    _unreleased(upper, "is not sha256: and 64 lower-case hex digits", "upper-case hex")
    var other = env.copy()
    other.image_digest = "sha512:" + _rep("a", 64)
    _unreleased(other, "is not sha256: and 64 lower-case hex digits", "another algorithm")
    var nonhex = env.copy()
    nonhex.image_digest = _layer("g")
    _unreleased(nonhex, "is not sha256: and 64 lower-case hex digits", "a non-hex digit")
    var colon = env.copy()
    colon.image_digest = _layer("/")
    _unreleased(colon, "is not sha256: and 64 lower-case hex digits", "a digit below 0")
    var mismatch = env.copy()
    mismatch.image_digest = _layer("a")
    _unreleased(mismatch, "the manifest's sha256 is " + env.image_digest + ", not image_digest", "a digest of other bytes")

    var not_layers = "the image manifest is not an image manifest with a `layers` array of digests"
    _unreleased(_env_of_text("not json"), not_layers, "not JSON")
    _unreleased(_env_of_text('{"layers":[{"digest":"' + _layer("1") + '"}],"layers":[]}'), not_layers, "layers twice")
    _unreleased(_env_of_text('{"schemaVersion":2,"manifests":[]}'), not_layers, "an image index")
    _unreleased(_env_of_text('{"layers":{}}'), not_layers, "layers not an array")
    _unreleased(_env_of_text('{"layers":[{"size":1}]}'), not_layers, "a layer with no digest")
    _unreleased(_env_of_text('{"layers":[{"digest":5}]}'), not_layers, "a layer digest that is a number")

    var no_base = "does not begin with the layers of any released base"
    var swapped: List[String] = [_layer("2"), _layer("1"), _layer("9")]
    _unreleased(_env(swapped), no_base, "the base's layers out of order")
    var second_differs: List[String] = [_layer("1"), _layer("7"), _layer("9")]
    _unreleased(_env(second_differs), no_base, "a different second layer")
    var shorter: List[String] = [_layer("1")]
    _unreleased(_env(shorter), no_base, "fewer layers than any base")
    var empty: List[BaseRelease] = [_release("nothing", List[String](), [UInt32(1)], [UInt32(1)])]
    _refused(_plan(1, 1, _python()), _env(_r1_image()), empty, OPTIMIZED_ENV_BASE_UNRELEASED, no_base, "a release with no layers")


def test_engine_too_old() raises:
    var env = _env(_r1_image())
    _refused(
        _plan(2, 1, _python()),
        env,
        _releases(),
        OPTIMIZED_ENV_ENGINE_TOO_OLD,
        "the plan has format_version 2 and optimizer_contract_version 1; the image's base base-py312 r1 accepts"
        " format_version {1} and optimizer_contract_version {1}; the oldest released base that accepts both is"
        " base-py312 r2. Rebuild the environment on a newer base (optimized_plan_udf_runtime.md §10.11 check 2)",
        "format_version 2 on r1",
    )
    _refused(
        _plan(1, 2, _python()),
        env,
        _releases(),
        OPTIMIZED_ENV_ENGINE_TOO_OLD,
        "optimizer_contract_version 2; the image's base base-py312 r1",
        "contract 2 on r1",
    )
    _refused(_plan(3, 1, _python()), env, _releases(), OPTIMIZED_ENV_ENGINE_TOO_OLD, "no released base accepts both", "format 3")
    # A release that accepts the format but not the contract is not the oldest that accepts both.
    var rs = _releases()
    var three: List[BaseRelease] = [
        rs[0].copy(),
        _release("base-py312 r1.5", [_layer("1"), _layer("5")], [UInt32(1), 2], [UInt32(1)]),
        rs[1].copy(),
    ]
    _refused(_plan(2, 2, _python()), env, three, OPTIMIZED_ENV_ENGINE_TOO_OLD, "accepts both is base-py312 r2", "r1.5 skipped")
    # Two releases accept both, then a newer r3 that does too: the oldest, the first listed, is named.
    var oldest_first: List[BaseRelease] = [
        rs[0].copy(),
        _release("base-py312 r2", [_layer("1"), _layer("3")], [UInt32(1), 2], [UInt32(1), 2]),
        _release("base-py312 r2.1", [_layer("1"), _layer("6")], [UInt32(1), 2], [UInt32(1), 2]),
        _release("base-py312 r3", [_layer("1"), _layer("7")], [UInt32(1), 2, 3], [UInt32(1), 2, 3]),
    ]
    _refused(
        _plan(2, 2, _python()),
        env,
        oldest_first,
        OPTIMIZED_ENV_ENGINE_TOO_OLD,
        "the oldest released base that accepts both is base-py312 r2. Rebuild",
        "the first of three that accept both",
    )


def test_runtime_missing() raises:
    var env = _env(_r1_image())
    var cp313: List[RuntimeNeed] = [RuntimeNeed("komira/python", "cp313")]
    _refused(
        _plan(1, 1, cp313),
        env,
        _releases(),
        OPTIMIZED_ENV_RUNTIME_MISSING,
        "the plan needs runtime `komira/python` with ABI `cp313`, which the image's base base-py312 r1 does not carry"
        " (optimized_plan_udf_runtime.md §10.11 check 3)",
        "another ABI tag",
    )
    var second: List[RuntimeNeed] = [RuntimeNeed("komira/python", "cp312"), RuntimeNeed("komira/node", "node22")]
    _refused(_plan(1, 1, second), env, _releases(), OPTIMIZED_ENV_RUNTIME_MISSING, "runtime `komira/node`", "the second need")


def test_header_fields_required() raises:
    var env = _env(_r1_image())
    var no_producer = _plan(1, 1, _python())
    no_producer.producer = None
    _refused(no_producer, env, _releases(), OPTIMIZED_PLAN_PRODUCER_MISSING, "engine_build", "no producer")
    var no_needs = _plan(1, 1, _python())
    no_needs.needs = None
    _refused(no_needs, env, _releases(), OPTIMIZED_PLAN_NEEDS_MISSING, "needs", "no needs")


def main() raises:
    test_released_base_admitted()
    test_longest_base_wins()
    test_base_unreleased()
    test_engine_too_old()
    test_runtime_missing()
    test_header_fields_required()
    print("every environment refusal of the header library, by name")
