# =============================================================================
# header_environment.mojo: the pair (plan, environment image), checks 1-3 of
# optimized_plan_udf_runtime.md §10.11, which need only the image manifest's
# bytes, so a scheduler never pulls a layer (docs/design/optimized_plan.md
# §7.2 step 3).
# =============================================================================
#
# The environment travels beside the plan, never inside it, and is not in
# `plan_digest`. The caller passes it (`PlanEnvironment`: the image digest and
# the manifest bytes) with the release records of the released bases
# (`BaseRelease`), which are published with each release and never read from
# image labels, which a user can write. Nothing here fetches either.
#
#   1. Released base. sha256(image_manifest) is `image_digest`
#      ("sha256:" and 64 lower-case hex digits), and the manifest's leading
#      layers are exactly the layer list of a released base, in order:
#      OPTIMIZED_ENV_BASE_UNRELEASED. When two released bases match, the one
#      with the longer layer list is the base (a base built FROM another
#      begins with that one's layers). A manifest that does not parse, names
#      a member twice, or has no `layers` array of digests matches no base.
#   2. The engine is new enough. The plan's `format_version` and
#      `optimizer_contract_version` are members of that base's accepted sets:
#      OPTIMIZED_ENV_ENGINE_TOO_OLD, naming the base's sets and the oldest
#      released base that accepts both (the first in `releases` order), or
#      that none does.
#   3. Runtimes present. Every `needs.runtimes` pair `(runtime, runtime_abi)`
#      is in the base's runtime registry: OPTIMIZED_ENV_RUNTIME_MISSING, naming
#      the pair.
#
# Not here: a runtime declared by an added runtime layer (check 3's second
# clause). udf_runtime_interface.md §8.3 leaves to the image design how a
# scheduler identifies such a layer from the manifest, and lists third-party
# runtime layers as later work; until then only the base's registry counts.
# Checks 4-7 need the layers and are the host's.
# =============================================================================

from komira_crypto import hex_lower_array_32, sha256
from komira_json import parse_json_bytes, refuse_duplicate_keys
from komira_plan_proto.optimized_plan import OptimizedPlan, RuntimeNeed

from .header_admit import require_header_needs, require_header_producer
from .header_codec import version_set_text

comptime OPTIMIZED_ENV_BASE_UNRELEASED: String = "OPTIMIZED_ENV_BASE_UNRELEASED"
"""The environment image is not built FROM a released base, or its digest is
not the sha256 of its manifest (§10.11 check 1)."""

comptime OPTIMIZED_ENV_ENGINE_TOO_OLD: String = "OPTIMIZED_ENV_ENGINE_TOO_OLD"
"""The image's base does not accept the plan's `format_version` or
`optimizer_contract_version` (§10.11 check 2)."""

comptime OPTIMIZED_ENV_RUNTIME_MISSING: String = "OPTIMIZED_ENV_RUNTIME_MISSING"
"""A `needs.runtimes` pair is not in the base's runtime registry (§10.11
check 3)."""


@fieldwise_init
struct PlanEnvironment(Copyable, Movable):
    """The environment image beside a plan (§10.11 `PlanEnvironment`)."""

    var image_digest: String
    """"sha256:<64 lower-case hex>" of the OCI image manifest."""
    var image_manifest: List[UInt8]
    """The manifest's bytes."""


@fieldwise_init
struct BaseRelease(Copyable, Movable):
    """The release record of one released base image."""

    var name: String
    """How refusals name the base."""
    var layers: List[String]
    """The base's layer digests, in manifest order."""
    var format_versions: List[UInt32]
    """The `format_version` set its engine accepts."""
    var contract_versions: List[UInt32]
    """The `optimizer_contract_version` set its engine accepts."""
    var runtimes: List[RuntimeNeed]
    """Its runtime registry: every `(runtime, runtime_abi)` pair it carries."""


def _unreleased(why: String) -> Error:
    return Error(
        OPTIMIZED_ENV_BASE_UNRELEASED + ": " + why + " (optimized_plan_udf_runtime.md §10.11 check 1)"
    )


def _is_sha256_digest(s: String) -> Bool:
    """`sha256:` and 64 lower-case hex digits."""
    var b = s.as_bytes()
    if len(b) != 71 or not s.startswith("sha256:"):
        return False
    for i in range(7, 71):
        if not ((b[i] >= 48 and b[i] <= 57) or (b[i] >= 97 and b[i] <= 102)):
            return False
    return True


def _manifest_layers(manifest: List[UInt8]) raises -> List[String]:
    """The layer digests of an OCI image manifest, in order."""
    var layers = List[String]()
    try:
        var doc = parse_json_bytes(manifest)
        refuse_duplicate_keys(doc)
        var array = doc.get("layers")
        if not array.is_array():
            raise Error("`layers` is not an array")
        for i in range(array.array_len()):
            layers.append(array.element_at(i).get("digest").as_string())
    except e:
        raise _unreleased("the image manifest is not an image manifest with a `layers` array of digests: " + String(e))
    return layers^


def _member(v: List[UInt32], x: UInt32) -> Bool:
    for i in range(len(v)):
        if v[i] == x:
            return True
    return False


def _begins_with(layers: List[String], base: List[String]) -> Bool:
    if len(base) == 0 or len(base) > len(layers):
        return False
    for i in range(len(base)):
        if layers[i] != base[i]:
            return False
    return True


def admit_plan_environment(header: OptimizedPlan, env: PlanEnvironment, releases: List[BaseRelease]) raises -> Int:
    """§10.11 checks 1-3 for `header` and the environment beside it, against
    the release records `releases`, oldest first. Returns the index in
    `releases` of the image's base."""
    var digest = env.image_digest
    if not _is_sha256_digest(digest):
        raise _unreleased("image_digest `" + digest + "` is not sha256: and 64 lower-case hex digits")
    var actual = String("sha256:") + hex_lower_array_32(sha256(Span(env.image_manifest)))
    if actual != digest:
        raise _unreleased("the manifest's sha256 is " + actual + ", not image_digest " + digest)
    var layers = _manifest_layers(env.image_manifest)
    var base = -1
    for i in range(len(releases)):
        if _begins_with(layers, releases[i].layers):
            if base < 0 or len(releases[i].layers) > len(releases[base].layers):
                base = i
    if base < 0:
        raise _unreleased("the image " + digest + " does not begin with the layers of any released base")

    require_header_producer(header)
    ref producer = header.producer.value()
    ref r = releases[base]
    if not _member(r.format_versions, header.format_version) or not _member(
        r.contract_versions, producer.optimizer_contract_version
    ):
        var oldest = String("no released base accepts both")
        for i in range(len(releases)):
            if _member(releases[i].format_versions, header.format_version) and _member(
                releases[i].contract_versions, producer.optimizer_contract_version
            ):
                oldest = "the oldest released base that accepts both is " + releases[i].name
                break
        raise Error(
            OPTIMIZED_ENV_ENGINE_TOO_OLD
            + ": the plan has format_version "
            + String(Int(header.format_version))
            + " and optimizer_contract_version "
            + String(Int(producer.optimizer_contract_version))
            + "; the image's base "
            + r.name
            + " accepts format_version "
            + version_set_text(r.format_versions)
            + " and optimizer_contract_version "
            + version_set_text(r.contract_versions)
            + "; "
            + oldest
            + ". Rebuild the environment on a newer base"
            + " (optimized_plan_udf_runtime.md §10.11 check 2)"
        )

    require_header_needs(header)
    ref needs = header.needs.value()
    for i in range(len(needs.runtimes)):
        ref want = needs.runtimes[i]
        var found = False
        for j in range(len(r.runtimes)):
            if r.runtimes[j].runtime == want.runtime and r.runtimes[j].runtime_abi == want.runtime_abi:
                found = True
                break
        if not found:
            raise Error(
                OPTIMIZED_ENV_RUNTIME_MISSING
                + ": the plan needs runtime `"
                + want.runtime
                + "` with ABI `"
                + want.runtime_abi
                + "`, which the image's base "
                + r.name
                + " does not carry (optimized_plan_udf_runtime.md §10.11 check 3)"
            )
    return base
