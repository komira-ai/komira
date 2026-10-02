# =============================================================================
# kci_deploy_compose/manifest_input.mojo — THE DIRECT LOGICAL-MANIFEST INPUT.
#   A `FullManifest` supplied BY THE OPERATOR, admitted as UNTRUSTED input, and
#   handed to the physical builders without a bundle.
# =============================================================================
#
# The pipeline is bundle -> logical manifest -> physical manifest, and a user may
# also define the logical manifest directly.
#
# ── WHAT THIS IS ─────────────────────────────────────────────────────────────
# A `FullManifest` is otherwise only ever SYNTHESIZED — `compose(bundle, env)` is
# the sole producer, so the physical builders could only ever be driven over the
# node set some bundle happens to author. This module is the second producer: a
# manifest READ from a document.
#
# It matters for two different reasons and they are worth separating:
#   * THE PRODUCT reason — the logical manifest becomes a public input, so a
#     user who wants a graph our Compositions do not synthesize can state it.
#   * THE TEST reason — a hand-written manifest reaches node kinds NO BUNDLE
#     PRODUCES. That is what makes physical-builder tests tractable, the way a
#     directly-constructible logical plan makes physical-plan tests possible in
#     a query engine.
#
# ── THE REFUSALS ARE THE PRODUCT HERE, NOT THE HAPPY PATH ────────────────────
# A composed manifest is correct BY CONSTRUCTION: `compose` cannot emit a
# duplicate logical id, a dangling edge, a cycle, or a spec on the wrong oneof
# arm. A SUPPLIED manifest can do all four, and every downstream consumer was
# written against the composed guarantee. So this module re-establishes each
# invariant EXPLICITLY, as a NAMED refusal, BEFORE the first mutation — rather
# than letting it surface as a raise out of `topo_sort` (which runs after the
# mapper has already constructed every live cloud seam) or, worse, as a node
# nothing materializes.
#
# `--manifest` IS NOT A WAY TO SKIP A CHECK BUNDLE-AUTHORED INPUT GETS. Every
# invariant below is one `compose` already guarantees; the point is that a
# supplied manifest must EARN them rather than inherit them.
#
# ── THE FORMAT: proto3-canonical JSON, and why ───────────────────────────────
#  1. THE SCHEMA IS THE PARSER. `kci_manifest_proto` generates a real
#     proto3-JSON decoder from `full_manifest.proto`. A hand-rolled parser for a
#     22-arm oneof that grows ADDITIVELY would be a second grammar to keep in
#     sync, and the day it drifted the reader would silently mean something the
#     schema does not.
#  2. IT IS AUTHORABLE. A human or an LLM can write and diff it.
#  3. IT IS EMITTABLE. `emit_manifest_json` renders any composed manifest, so a
#     user's first manifest comes from `compose` and is then edited — the
#     round trip is the on-ramp, and it is also the test oracle.
#  4. IT IS NOT THE CONTENT-ADDRESS PREIMAGE. That stays protobuf-binary
#     (`content_address.mojo`), so admitting a JSON document changes nothing
#     about the addressing contract.
#
# ── WHAT THE DECODER ENFORCES, AND WHAT IS LEFT FOR THIS FILE ────────────────
# `komira_proto_codec`'s proto3-JSON decoder is STRICT:
#
#   * an unknown JSON key is a REFUSAL naming the key, its JSON path, its
#     source LINE and the message's accepted vocabulary.
#   * it accepts the ORIGINAL `.proto` field name as well as the proto3
#     `jsonName` (lowerCamel), as canonical proto3-JSON parsers do: a document
#     written `logical_id` / `depends_on` — copied out of `full_manifest.proto`,
#     the most natural way to author one — DECODES, rather than producing a node
#     with an empty logical id and no error.
#   * a document stating BOTH spellings of one field (`logicalId` AND
#     `logical_id`) is a REFUSAL naming both spellings, both source lines and
#     the field, rather than keeping whichever came LAST. It is a refusal in the
#     ignore-unknown mode too: ignoring a key this build cannot NAME is
#     forward-compat; choosing silently between two values of a field it CAN
#     name is not.
#
# SO `_refuse_unconsumed_keys` IS NOT THE UNKNOWN-KEY GUARD, AND IT IS NOT THE
# DUPLICATE-KEY GUARD FOR A MESSAGE EITHER. Its own coverage is narrower:
#
#   * a duplicate key inside a proto3 `map<K,V>` OBJECT. A map is not a
#     message: its keys are DATA, it has no field vocabulary, and the
#     generated decode calls `expect_fields` for the enclosing message only
#     — so `{"labels":{"a":1,"a":2}}` reaches the map reader with two entries
#     and nothing in the codec can see it. This walker does.
#   * a key the decoder ACCEPTED and then threw away for some other reason.
#     The round-trip echo is a genuinely different oracle from a field
#     vocabulary and can catch a defect the vocabulary agrees with.
#
# It must NOT report an accepted alias as unknown — see its own docstring.
#
# ── ENCAPSULATION ───────────────────────────────────────────────────────────
# Value-typed throughout: `String` in, `FullManifest` out, `raises` on every
# refusal. ZERO UnsafePointer, ZERO wildcard origin.
# =============================================================================

from komira_json import JsonValue, parse_json_value
from komira_proto_codec import decode_json, encode_json

from kci_manifest_proto.full_manifest import (
    FullManifest,
    ResourceKind,
    ResourceNode,
)

from kci_deploy_compose.content_address import content_address


# Every refusal below is prefixed with this so an operator reading a wall of
# deploy output can tell "the manifest YOU handed me is not admissible" from
# "the cloud said no". It names the FLAG, because the flag is the thing the
# operator typed.
comptime MANIFEST_REFUSAL_PREFIX: String = "kci --manifest: "


# =============================================================================
# §1 — THE KIND -> ONEOF-ARM CONTRACT.
# =============================================================================
#
# `full_manifest.proto` states it in prose on `ResourceNode.config`: *"Exactly
# one arm is set; the arm MUST correspond to `kind`."* Nothing enforced it,
# because nothing could construct a node except a builder that hardcoded both
# halves together. A supplied manifest can set kind 1 and arm 9, and every
# consumer keys on ONE of the two — `map_manifest_to_graph` dispatches on the
# KIND and then reads `node.<arm>`, so a mismatched node materializes over the
# right conformer with an unset spec.
#
# THREE KINDS CARRY **NO** ARM, AND THAT IS NOT A GAP. Kind 20
# (PROJECT_SERVICE), kind 22 (MAIL_DOMAIN_IDENTITY) and kind 27
# (IAM_CUSTOM_ROLE) carry their ENTIRE identity in `logical_id` — the API
# service name, the domain, the custom-role id — so the oneof has no arm for
# them and `_oneof0_case` is 0. See `compose_api._mail_domain_identity_node`
# ("NO oneof arm set (kind 22 carries its identity in logical_id)") and
# `run_scope._node_addressed_names`, which enumerates the same three
# EXPLICITLY rather than defaulting them.
#
# ⇒ so "no arm set" is legal for exactly those three and a refusal for every
# other kind, and "an arm set" is a refusal for exactly those three. A single
# `_oneof0_case != 0` check would have been wrong in both directions.
comptime KIND_CARRIES_NO_ARM: Int = 0


def arm_for_kind(kind: Int) raises -> Int:
    """The `_oneof0_case` arm index a node of `kind` MUST carry, or
    `KIND_CARRIES_NO_ARM` (0) for the three kinds whose identity is their
    `logical_id`.

    TOTAL over the DECLARED `ResourceKind` vocabulary, and it RAISES on an
    ordinal it does not know — the same fail-closed posture
    `run_scope._node_addressed_names` takes, for the same reason: a default arm
    would make a kind added to `full_manifest.proto` tomorrow SILENTLY
    admissible with any arm at all, which is precisely the check this function
    is.

    ⛔ RESOURCE_KIND_UNSPECIFIED (0) RAISES rather than mapping to "no arm".
    `from_json_name` maps an UNKNOWN enum name to the zero value (the proto3
    unknown-enum contract), so `"kind": "RESOURCE_KIND_SERVERLES_COMPUTE"` — a
    typo — decodes to 0 with no error. Treating 0 as a legal arm-less kind
    would admit every misspelling in the vocabulary."""
    if kind == ResourceKind.RESOURCE_KIND_SERVERLESS_COMPUTE:
        return 1
    elif kind == ResourceKind.RESOURCE_KIND_RUN_TO_COMPLETION_JOB:
        return 2
    elif kind == ResourceKind.RESOURCE_KIND_OBJECT_STORE:
        # DEPRECATED / consolidated into BUCKET (kind 13, arm 13). The arm is
        # retained-but-unemitted for the additive wire contract, so the
        # agreement is still stated — a manifest may legally carry one.
        return 3
    elif kind == ResourceKind.RESOURCE_KIND_DATASTORE:
        return 4
    elif kind == ResourceKind.RESOURCE_KIND_QUEUE:
        return 5
    elif kind == ResourceKind.RESOURCE_KIND_LOAD_BALANCER:
        return 6
    elif kind == ResourceKind.RESOURCE_KIND_DNS_RECORD:
        return 7
    elif kind == ResourceKind.RESOURCE_KIND_IAM_ROLE:
        return 8
    elif kind == ResourceKind.RESOURCE_KIND_SECRET:
        return 9
    elif kind == ResourceKind.RESOURCE_KIND_CONFIG:
        return 10
    elif kind == ResourceKind.RESOURCE_KIND_SERVICE_ACCOUNT:
        return 11
    elif kind == ResourceKind.RESOURCE_KIND_WIF_PROVIDER:
        return 12
    elif kind == ResourceKind.RESOURCE_KIND_BUCKET:
        return 13
    elif kind == ResourceKind.RESOURCE_KIND_ARTIFACT_REPOSITORY:
        return 14
    elif kind == ResourceKind.RESOURCE_KIND_TRIGGER:
        return 15
    elif kind == ResourceKind.RESOURCE_KIND_INVOKE_GRANT:
        # DEPRECATED / consolidated into GRANT (kind 17, arm 17); retained for
        # the same reason OBJECT_STORE is.
        return 16
    elif kind == ResourceKind.RESOURCE_KIND_GRANT:
        return 17
    elif kind == ResourceKind.RESOURCE_KIND_WEB_FRONTEND:
        return 18
    elif kind == ResourceKind.RESOURCE_KIND_API_EDGE:
        return 19
    elif kind == ResourceKind.RESOURCE_KIND_PROJECT_SERVICE:
        return KIND_CARRIES_NO_ARM
    elif kind == ResourceKind.RESOURCE_KIND_SCHEDULED_CALL:
        return 20
    elif kind == ResourceKind.RESOURCE_KIND_MAIL_DOMAIN_IDENTITY:
        return KIND_CARRIES_NO_ARM
    elif kind == ResourceKind.RESOURCE_KIND_NETWORK:
        return 21
    elif kind == ResourceKind.RESOURCE_KIND_INGRESS_POLICY:
        return 22
    elif kind == ResourceKind.RESOURCE_KIND_IAM_CUSTOM_ROLE:
        return KIND_CARRIES_NO_ARM
    raise Error(
        String(MANIFEST_REFUSAL_PREFIX)
        + String("ResourceKind ordinal ")
        + String(kind)
        + String(" has no case in `arm_for_kind` — a kind added to")
        + String(" full_manifest.proto must state WHICH `config` oneof arm it")
        + String(" carries (or that it carries none) before a supplied")
        + String(" manifest may name it. Refusing rather than admitting it")
        + String(" with any arm at all: the arm is what every conformer reads.")
    )


def kind_is_declared(kind: Int) -> Bool:
    """True iff `kind` is a DECLARED `ResourceKind` value.

    ⭐ DERIVED FROM THE GENERATED ENUM, not from a list here. The generated
    `json_name()` renders a declared value as its NAME and an UNDECLARED one as
    its DECIMAL NUMBER TEXT (the proto3 unknown-enum fallback the emitter
    states). So "the name is not the number" IS the declaration test, and a
    kind declared in `full_manifest.proto` tomorrow answers True here with no
    edit to this file."""
    return ResourceKind(kind).json_name() != String(kind)


# =============================================================================
# §2 — THE UNCONSUMED-KEY GUARD (the leniency fix; see the header).
# =============================================================================
def _to_lower_camel(s: String) -> String:
    """`logical_id` -> `logicalId`. The proto3 `jsonName` derivation, used ONLY
    to make an unknown-key refusal actionable ("did you mean ...?"). Never used
    to accept anything — the accepted spelling is whatever the generated
    encoder emits, and this function's output is not consulted for that."""
    var out = String("")
    var up = False
    var bytes = s.as_bytes()
    for i in range(len(bytes)):
        var c = Int(bytes[i])
        if c == ord("_"):
            up = True
            continue
        if up and c >= ord("a") and c <= ord("z"):
            out += chr(c - 32)
        else:
            out += chr(c)
        up = False
    return out^


def _refuse_unconsumed_keys(
    supplied: JsonValue, echo: JsonValue, where: String
) raises:
    """RAISE if any object key in `supplied` is absent from `echo`.

    ⭐⭐ THE MECHANISM, AND WHY IT NEEDS **NO** FIELD VOCABULARY. `echo` is the
    supplied document decoded to a `FullManifest` and RE-ENCODED by the same
    generated encoder. A key the decoder CONSUMED round-trips into `echo`; a
    key it IGNORED does not. So "present in the input, absent from the echo" is
    exactly "the decoder threw this away", derived from the schema at every
    depth, with nothing here to keep in sync.

    ⛔ A HAND-WRITTEN KEY LIST WOULD BE WRONG THE DAY A FIELD IS ADDED, and it
    would be wrong in the FAIL-OPEN direction for a `<Kind>Spec` interior — 22
    spec messages, each with its own fields, is precisely the vocabulary nobody
    would maintain.

    WHY THE ECHO IS COMPLETE ENOUGH FOR THIS TO BE SOUND (read
    `src/proto-codegen/src/emit.rs:emit_encode_field` before changing it): a
    singular scalar / enum / message field is written UNCONDITIONALLY, and a
    repeated field always brackets its list — so a consumed field is always in
    the echo, even at its default value (`"nodes":[]`, `"environment":""`). The
    only omissions are an UNSET `Optional` and an UNSET oneof arm, and neither
    can correspond to a key that was present and consumed.

    A JSON `null` in the input is SKIPPED, not flagged: proto3 JSON treats null
    as absent and `JsonDecoder.next_field` already does, so the field is
    legitimately not in the echo.

    ⚠ IT ALSO CATCHES A DUPLICATE KEY, which the echo cannot: `{"a":1,"a":2}`
    round-trips to one `a`, and a set-membership test would pass it. A
    duplicate is refused directly.

    ⚠ THAT ARM IS NO LONGER THIS FILE'S ALONE, AND IS NOT REDUNDANT EITHER.
    Since the codec's `expect_fields` grew a group-ordinal comparison, a
    MESSAGE object stating one field twice — literally, or under its two
    accepted spellings — is refused by the decoder before this walker runs.
    What still reaches here is the case a field vocabulary structurally
    cannot have an opinion about: a duplicate key inside a proto3 `map<K,V>`
    object, whose keys are DATA rather than fields.

    AND A KEY MAY ROUND-TRIP UNDER A DIFFERENT SPELLING. The decoder
    accepts both the `jsonName` and the original `.proto` field name; the
    ENCODER only ever writes the `jsonName`. So `logical_id` in, `logicalId`
    out — consumed, and absent from the echo under its own name. The lookup
    below tries the lowerCamel derivation before concluding a key was
    dropped, or this guard refuses the exact spelling the codec fix exists
    to admit.

    AND IT IS NOT THE UNKNOWN-KEY GUARD. `komira_proto_codec`'s decoder
    refuses an unrecognised key itself now, with a better locator than this
    (token + JSON path + source LINE + the message's accepted vocabulary), so
    an unknown key never reaches here — nor does a message-level duplicate.
    What survives as this function's OWN coverage is a duplicate inside a
    `map<K,V>` object, and a key the decoder accepted and then dropped.

    `where` is the JSON path of the containing value (`""` at the document
    root), so the refusal names WHERE rather than just WHAT."""
    if supplied.is_object():
        if not echo.is_object():
            # The decoder did not take this as a message. Not this function's
            # question — a type mismatch surfaces from the decoder itself.
            return
        var n = supplied.num_members()
        for i in range(n):
            var key = supplied.key_at(i)
            for j in range(i + 1, n):
                if supplied.key_at(j) == key:
                    raise Error(
                        String(MANIFEST_REFUSAL_PREFIX)
                        + String("the key '")
                        + key
                        + String("' is stated TWICE in the same object at '")
                        + where
                        + String(
                            "'. Only one of them survives the decode and which"
                            " one is an accident of ordering — state it once."
                        )
                    )
            if supplied.value_at(i).is_null():
                # proto3 JSON: an explicit null means ABSENT. The decoder skips
                # it, so its absence from the echo is correct, not a drop.
                continue
            # THE ECHO CARRIES THE CANONICAL SPELLING. The decoder accepts the
            # ORIGINAL `.proto` field name as well as the `jsonName`, so a
            # CONSUMED `logical_id` re-encodes as `logicalId` and a bare
            # `echo.has(key)` would report the one spelling this reader most
            # wants to accept as UNKNOWN — a refusal that is FALSE about a
            # document the codec just decoded correctly. The alias is the same
            # derivation protoc uses.
            var echo_key = key
            if not echo.has(echo_key):
                var camel = _to_lower_camel(key)
                if camel != key and echo.has(camel):
                    echo_key = camel
            if not echo.has(echo_key):
                raise Error(
                    String(MANIFEST_REFUSAL_PREFIX)
                    + String("unknown key '")
                    + key
                    + String("' at '")
                    + where
                    + String(
                        "'. It survived the decode but contributed nothing to"
                        " the manifest — refusing rather than applying a graph"
                        " the document does not describe. Both the"
                        " proto3-JSON `jsonName` (lowerCamel) and the original"
                        " `.proto` field name are accepted spellings; check"
                        " this one against full_manifest.proto."
                    )
                )
            _refuse_unconsumed_keys(
                supplied.value_at(i),
                echo.get(echo_key),
                where + String(".") + key,
            )
    elif supplied.is_array():
        if not echo.is_array():
            return
        var n = supplied.array_len()
        if echo.array_len() < n:
            n = echo.array_len()
        for i in range(n):
            _refuse_unconsumed_keys(
                supplied.element_at(i),
                echo.element_at(i),
                where + String("[") + String(i) + String("]"),
            )


# =============================================================================
# §3 — admit_manifest — the invariant battery a COMPOSED manifest gets free.
# =============================================================================
def admit_manifest(manifest: FullManifest, expect_env: String) raises:
    """RAISE, naming the offending node, unless `manifest` satisfies every
    invariant `compose` guarantees by construction.

    Runs BEFORE the physical builders and therefore before any cloud seam is
    constructed — which is the whole point. `topo_sort` already raises on a
    dangling edge and on a cycle, but it runs INSIDE
    `map_manifest_to_graph`'s output, i.e. after every live API client the
    mapper needs has been built; and its message is written for a graph WE
    composed, so it sends the reader looking for a composer bug.

    `expect_env` is the operator's `--env`. It is REQUIRED (empty raises): the
    manifest's own `environment` says which env symbol it was synthesized for,
    but the concrete env BINDING (cloud / account / region) is a separate
    deployer input the manifest deliberately does not carry, so the flag
    is not redundant with the field — and the two disagreeing means the
    operator is about to apply the wrong graph."""
    if expect_env.byte_length() == 0:
        raise Error(
            String(MANIFEST_REFUSAL_PREFIX)
            + String(
                "a supplied manifest requires `--env <name>`. The manifest"
                " states WHICH env symbol it was synthesized for; the concrete"
                " binding (cloud / account / region) is a separate input it"
                " deliberately does not carry, so the flag is not redundant."
            )
        )
    if manifest.environment.byte_length() == 0:
        raise Error(
            String(MANIFEST_REFUSAL_PREFIX)
            + String(
                "the manifest states no `environment`. It is the one field"
                " that says which environment this graph is for, and an empty"
                " one would make the manifest apply anywhere `--env`"
                " pointed. State the `environment` key, with the value "
            )
            + expect_env
        )
    if manifest.environment != expect_env:
        raise Error(
            String(MANIFEST_REFUSAL_PREFIX)
            + String("the manifest was synthesized for environment '")
            + manifest.environment
            + String("' but `--env ")
            + expect_env
            + String(
                "` was given. Refusing rather than preferring either: the"
                " manifest's node set is env-specific (names, audiences,"
                " regions are resolved INTO it at synth time), so applying it"
                " under a different env deploys one env's graph into another."
            )
        )
    if len(manifest.nodes) == 0:
        raise Error(
            String(MANIFEST_REFUSAL_PREFIX)
            + String(
                "the manifest declares ZERO nodes. Every walk over it is a"
                " no-op, so it would apply nothing and report success —"
                " indistinguishable from a deploy that worked. If the intent"
                " is to tear an environment down, that is `kci delete`."
            )
        )

    # ---- per-node invariants ------------------------------------------------
    for i in range(len(manifest.nodes)):
        var lid = manifest.nodes[i].logical_id.copy()
        if lid.byte_length() == 0:
            raise Error(
                String(MANIFEST_REFUSAL_PREFIX)
                + String("node ")
                + String(i)
                + String(
                    " has an EMPTY `logicalId`. It is the graph-stable key —"
                    " the `dependsOn` edge target, the intent-adopt key, and"
                    " for several kinds the cloud resource name itself."
                )
            )
        for j in range(i + 1, len(manifest.nodes)):
            if manifest.nodes[j].logical_id == lid:
                raise Error(
                    String(MANIFEST_REFUSAL_PREFIX)
                    + String("nodes ")
                    + String(i)
                    + String(" and ")
                    + String(j)
                    + String(" share the logical id '")
                    + lid
                    + String(
                        "'. Every key must be unique: a `dependsOn` naming it"
                        " resolves to whichever one the scan reaches first, so"
                        " the edge means something the author cannot predict."
                    )
                )

        var kind = manifest.nodes[i].kind.value
        # ORDINAL 0 IS ITS OWN REFUSAL, AND SPLITTING IT OUT IS NOT
        # COSMETIC. `RESOURCE_KIND_UNSPECIFIED` IS a declared value, so the
        # undeclared-ordinal arm below does not fire on it, and `arm_for_kind`
        # would report it as "no case in arm_for_kind" — a message that sends
        # the reader to add a case to THIS FILE when what actually happened is
        # that they misspelled a kind NAME in their document. The generated
        # `from_json_name` ends `return Self(0)`, so every misspelling in the
        # vocabulary arrives here as 0 and there is no other signal.
        if kind == ResourceKind.RESOURCE_KIND_UNSPECIFIED:
            raise Error(
                String(MANIFEST_REFUSAL_PREFIX)
                + String("node '")
                + lid
                + String(
                    "' declares ResourceKind ordinal 0"
                    " (RESOURCE_KIND_UNSPECIFIED), which is not a resource."
                    " ⚠ A MISSPELLED kind NAME LANDS HERE: the proto3"
                    " unknown-enum contract maps an unknown name to the zero"
                    " value SILENTLY, so an unrecognised RESOURCE_KIND_* token"
                    " is indistinguishable from an omitted one. Check the"
                    " spelling against the vocabulary in full_manifest.proto."
                )
            )
        if not kind_is_declared(kind):
            raise Error(
                String(MANIFEST_REFUSAL_PREFIX)
                + String("node '")
                + lid
                + String("' declares ResourceKind ordinal ")
                + String(kind)
                + String(
                    ", which full_manifest.proto does not declare. An ordinal"
                    " can only arrive here from the BINARY wire (a JSON"
                    " document names a kind by NAME), so this manifest was"
                    " produced against a different schema revision."
                )
            )
        var want_arm = arm_for_kind(kind)
        var got_arm = manifest.nodes[i]._oneof0_case
        if got_arm != want_arm:
            if want_arm == KIND_CARRIES_NO_ARM:
                raise Error(
                    String(MANIFEST_REFUSAL_PREFIX)
                    + String("node '")
                    + lid
                    + String("' is kind ")
                    + ResourceKind(kind).json_name()
                    + String(", which carries its ENTIRE identity in its")
                    + String(" logical id and must set NO `config` arm — but")
                    + String(" arm ")
                    + String(got_arm)
                    + String(" is set. Drop the config block.")
                )
            raise Error(
                String(MANIFEST_REFUSAL_PREFIX)
                + String("node '")
                + lid
                + String("' is kind ")
                + ResourceKind(kind).json_name()
                + String(" (which requires `config` arm ")
                + String(want_arm)
                + String(") but carries arm ")
                + String(got_arm)
                + String(
                    ". The kind and the arm are read by DIFFERENT consumers —"
                    " the mapper dispatches on the KIND and then reads the"
                    " ARM — so a mismatched node materializes over the right"
                    " conformer with an unset spec, which is not a shape any"
                    " conformer was written against."
                )
            )

        # ---- edges: self, dangling. (The cycle check needs the whole set.) --
        var deps = manifest.nodes[i].depends_on.copy()
        for d in range(len(deps)):
            if deps[d] == lid:
                raise Error(
                    String(MANIFEST_REFUSAL_PREFIX)
                    + String("node '")
                    + lid
                    + String(
                        "' depends on ITSELF. Kahn's algorithm reports this as"
                        " part of a cycle; it is worth naming separately"
                        " because the fix is different — a self-edge is almost"
                        " always a copied `dependsOn` block."
                    )
                )
            var found = False
            for k in range(len(manifest.nodes)):
                if manifest.nodes[k].logical_id == deps[d]:
                    found = True
                    break
            if not found:
                raise Error(
                    String(MANIFEST_REFUSAL_PREFIX)
                    + String("node '")
                    + lid
                    + String("' depends on '")
                    + deps[d]
                    + String(
                        "', which is not a node in this manifest. A dangling"
                        " edge is a MISSING RESOURCE stated as an ordering"
                        " constraint: the applier would create this node"
                        " without the thing it was written to require."
                    )
                )

    _refuse_cycle(manifest)

    # ---- the stamped content address, if any --------------------------------
    _refuse_content_address_mismatch(manifest)


def _refuse_cycle(manifest: FullManifest) raises:
    """RAISE if the `dependsOn` edges contain a cycle, naming every node in the
    unorderable residual.

    Kahn's algorithm over LOGICAL IDS (not over a built `ResourceGraph`), which
    is the point: the IaC engine's `topo_sort` answers the same question but
    only after `map_manifest_to_graph` has constructed a live conformer per
    node. Assumes the dangling/self checks above already passed, so an
    unresolved dep here cannot happen."""
    var n = len(manifest.nodes)
    var in_degree = List[Int]()
    var emitted = List[Bool]()
    for _i in range(n):
        in_degree.append(0)
        emitted.append(False)
    for i in range(n):
        in_degree[i] = len(manifest.nodes[i].depends_on)

    var emitted_count = 0
    while emitted_count < n:
        var pick = -1
        for i in range(n):
            if (not emitted[i]) and in_degree[i] == 0:
                pick = i
                break
        if pick < 0:
            var ids = String("")
            var first = True
            for i in range(n):
                if not emitted[i]:
                    if not first:
                        ids += String(", ")
                    ids += String("'") + manifest.nodes[i].logical_id + String(
                        "'"
                    )
                    first = False
            raise Error(
                String(MANIFEST_REFUSAL_PREFIX)
                + String("the `dependsOn` edges form a CYCLE among [")
                + ids
                + String(
                    "]. There is no order in which these can be created, so"
                    " there is nothing for the applier to do but pick one and"
                    " be wrong."
                )
            )
        emitted[pick] = True
        emitted_count += 1
        # Decrement every node that depends on `pick`.
        var pid = manifest.nodes[pick].logical_id.copy()
        for i in range(n):
            if emitted[i]:
                continue
            var deps = manifest.nodes[i].depends_on.copy()
            for d in range(len(deps)):
                if deps[d] == pid:
                    in_degree[i] -= 1


def _refuse_content_address_mismatch(manifest: FullManifest) raises:
    """RAISE if the manifest carries a stamped `contentAddress` that does not
    verify against its own bytes.

    THIS IS THE ONE CHECK THAT COVERS EVERYTHING THE DECODER SILENTLY DROPS
    — for a manifest that carries an address. `_refuse_unconsumed_keys` catches
    an unknown KEY; this catches an unknown or reordered VALUE, a truncated
    node list, a re-typed enum, anything. A manifest emitted by `compose` +
    `emit_manifest_json` carries one, so machine-produced input is
    tamper-evident end to end.

    EMPTY IS LEGAL AND IS NOT A WEAKENING. A hand-authored manifest has no
    address to state (the field is stamped at synth/pin time), and
    demanding one would mean demanding the author compute a SHA-256 of a
    protobuf encoding by hand. What is refused is a WRONG one — a stated fact
    that is false is worse than an unstated one.

    AND IT IS AN ADDRESS OVER **OUR** CANONICAL ENCODING. The preimage is
    `encode_proto` with the field cleared; a foreign encoder that orders map
    entries differently (protoc sorts them; `komira_proto_codec` preserves insertion
    order) produces a different address for the same logical manifest, and
    editing the key ORDER of a `config.values` map in the JSON changes it too.
    The refusal says so rather than implying tampering."""
    if manifest.content_address.byte_length() == 0:
        return
    var recomputed = content_address(manifest)
    if recomputed == manifest.content_address:
        return
    raise Error(
        String(MANIFEST_REFUSAL_PREFIX)
        + String("the manifest states contentAddress '")
        + manifest.content_address
        + String("' but its bytes address to '")
        + recomputed
        + String(
            "'. Either the document was edited after it was stamped, or it was"
            " produced by an encoder that orders bytes differently from ours"
            " (the preimage is our protobuf encoding with the field cleared,"
            " and map entries are emitted in INSERTION order, not sorted)."
            " Clear the field to author a manifest by hand; do not restamp it"
            " to make this pass."
        )
    )


# =============================================================================
# §4 — THE FRONT DOOR. Read + parse + admit, as ONE call.
# =============================================================================
def admit_manifest_text(text: String, expect_env: String) raises -> FullManifest:
    """Parse `text` as a proto3-canonical-JSON `FullManifest` and ADMIT it.

    THERE IS DELIBERATELY NO EXPORTED PARSE-WITHOUT-ADMIT. Two functions
    where one is the safe one is a decision every caller has to get right; a
    caller that took the raw parse would silently skip every invariant in §3,
    and nothing would go red. Text-in so the hermetic tests need no
    filesystem (the `parse_graph_fixture` precedent)."""
    var supplied = parse_json_value(text)
    if not supplied.is_object():
        raise Error(
            String(MANIFEST_REFUSAL_PREFIX)
            + String(
                "the document is not a JSON object. A FullManifest renders"
                " as an object with an `environment` key and a `nodes` array —"
                " emit one from a bundle rather than authoring the shape blind."
            )
        )
    var manifest = decode_json[FullManifest](text)
    var echo = parse_json_value(encode_json[FullManifest](manifest))
    _refuse_unconsumed_keys(supplied, echo, String(""))
    admit_manifest(manifest, expect_env)
    return manifest^


def load_manifest_input(path: String, expect_env: String) raises -> FullManifest:
    """Read the manifest document at `path` and admit it. THE front door the
    CLI calls; the file wrapper around `admit_manifest_text`."""
    var text: String
    with open(path, "r") as f:
        text = f.read()
    return admit_manifest_text(text, expect_env)


def emit_manifest_json(manifest: FullManifest) raises -> String:
    """Render `manifest` as the proto3-canonical-JSON document
    `admit_manifest_text` reads back.

    The on-ramp AND the oracle: a user's first hand-authored manifest is a
    composed one, emitted here and edited; and a test asserting the round trip
    proves the reader and the writer agree about the schema rather than about
    each other's bugs."""
    return encode_json[FullManifest](manifest)
