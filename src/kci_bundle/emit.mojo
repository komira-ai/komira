# =============================================================================
# kci_bundle/emit.mojo — the GENERATED AppBundle -> canonical textproto.
# =============================================================================
#
# The deterministic CANONICAL emitter: a fully-populated `AppBundle` struct ->
# a canonical `komira.deploy.textproto` string. It is the round-trip partner of
# `parser.mojo` — `emit(parse(canonical)) == canonical` byte-for-byte (a
# "byte-exact re-emit where unchanged" round-trip gate). Fields are
# emitted in proto field-number order, 2-space indented, one blank line between
# top-level sections; enum values as their FULL proto value name (schema-lock).
#
# NOT the patcher. This emitter is a from-scratch canonical serializer for
# round-trip + machine-generated bundles; a comment-preserving EDIT of an
# author's file is `patch.mojo` (a proto-canonical re-serialize would destroy
# the `#` prose the format exists for). Presence rules: singular
# message fields (image/scaling/spec) emit only when set; `compute`/`datastore`
# emit only when non-UNSPECIFIED (the proto3 default is "unset"); scalars
# (kind/name/port) always emit.
#
# ── THE INVARIANT, STATED ────────────────────────────────────────────────────
# EVERY FIELD `parse_bundle` ACCEPTS IS EMITTED HERE. Not "every field of
# AppBundle", but every field the parser can populate. It is a real invariant
# with a real gate: `tests/test_emit_completeness.mojo`
# reads each block's legal field set OUT OF THE PARSER's own unknown-field
# diagnostic at run time and fails if any authored field does not survive a
# parse->emit round trip.
#
# `services` (field 7) is covered too: `_parse_service_spec` authors it and
# `_emit_service_spec` is its twin.
#
# The invariant matters because a parser arm can be added with its own tests
# while nothing forces a change here. A dropped field is not a formatting
# difference — an authored `triggers {}` dropped on emit reduces a CONTINUOUS
# machine to a one-shot one, and a dropped `ensure: true` reduces a PROVISIONING
# secret binding to authorize-only, in both cases with no diff for a reviewer to
# see.
#
# ENCAPSULATION: borrowed message params (no copies), pure String building. No
# UnsafePointer, no wildcard origin. Mojo 1.0.0b2.
# =============================================================================

from kci_bundle_proto.app_bundle import (
    AppParameter,
    ParamType,
    AppBundle,
    # ★ WHOSE CLOUD ACCOUNT THIS WORKLOAD RUNS IN (`AppBundle.tenancy`, field
    # 15) — re-emitted so the canonical form is not lossy about a bundle's
    # declared trust boundary. See `emit_bundle`.
    Tenancy,
    OutputFormat,
    ImageRef,
    BundleEnvVar,
    # The THIRD `BundleEnvVar.val` oneof arm — a typed cross-service reference
    # (`service_ref { service: "<sibling>" }`). Was PARSED and never emitted.
    ServiceRef,
    Scaling,
    AppSpec,
    # ★ ONE NAMED SERVICE of a MULTI-SERVICE bundle (`AppBundle.services`, field
    # 7) — the round-trip twin of the parser's `_parse_service_spec`. Emitted by
    # `_emit_service_spec`; ZERO services emits nothing (the AUTO-LIFT signal).
    ServiceSpec,
    # `AppSpec.buckets` (20) + `AppSpec.web_route_rules` (22).
    BucketSpec,
    # `AppSpec.mail_transport` (34) — the mail spine (domain identity + inbound
    # queue + the DNS records that prove the domain). Emitted by
    # `_emit_mail_transport`; ABSENT emits nothing (byte-identical round trip).
    MailTransportSpec,
    # `AppSpec.datastore_collections` (35) — the collection shapes this app's
    # datastore holds, and the only surface on which a key schema may be
    # stated. Emitted by `_emit_datastore_collection`; an EMPTY list emits
    # nothing (byte-identical round trip for a bundle that authors none).
    CloudVariant,
    DatastoreCollection,
    DatastoreAccessPath,
    # `AppSpec.name_scope` (37) — whether the authored `name` IS the service name
    # or a BASE name the deploy TARGET qualifies. UNSPECIFIED emits nothing
    # (byte-identical round trip).
    NameScope,
    WebRouteRule,
    WebFrontendOverride,
    # `AppSpec.secured_inbound_routes` (26) — the ADDITIONAL inbound routes the
    # EDGE authenticates (federated callers).
    SecuredInboundRoute,
    HttpCheck,
    RunContainer,
    # The DIRECT VPC EGRESS attachment a validate step's JOB may carry
    # (`RunContainer.vpc_egress`, field 7). ABSENT => no `vpcAccess` on the
    # wire => the job egresses over the PUBLIC INTERNET.
    ValidateVpcEgress,
    # ★ The EPHEMERAL KOMIRA CALLER IDENTITIES a validate step declares
    # (`RunContainer.test_role`, field 9). Re-emitted so the canonical
    # form is not lossy about an identity the deploy will MINT and REVOKE — a
    # dropped block would silently delete a caller the step's whole assertion is
    # about, which is the loss class this file's header enumerates.
    TestRole,
    ValidateStep,
    Wave,
    # The continuous-deployment TRIGGER (`AppBundle.triggers`, field 6) — a named
    # trigger + a one-arm-per-kind payload oneof. Round-trip emitted, in
    # field-number order, between `waves` and `validation_sets`.
    TriggerSource,
    GitPush,
    Schedule,
    PackagePublished,
    # Named validation SETS + the
    # pipeline authoring surface (round-trip emitted only-when-present).
    ValidationSet,
    # ⛔ The ENV RESTRICTION a validation set carries.
    # Default-skipped at UNSPECIFIED so the field stays additive.
    ValidationSetEnvPolicy,
    PipelineStep,
    Pipeline,
    # `AppBundle.matrices` (10) — the NEUTRAL device/capability matrices. Parsed
    # + fail-closed validated, and dropped on every emit until now.
    Matrix,
    MatrixCell,
    # The named DEPLOY OUTPUTS — round-trip
    # emitted only-when-present (proto3 default-skip; a pre-outputs bundle re-emits
    # byte-identically).
    DeployOutput,
    # ── Four optional capabilities. Emitted only-when-authored, so a bundle
    #    that authors none round-trips byte-identically. ──────────────────────
    IngressSpec,
    JobSpec,
    ExecuteJob,
    CronSpec,
    EphemeralScope,
)
from kci_bundle_proto.deploy_model import (
    # The app-declared index shapes (`AppSpec.index_tables`, field 29) — the
    # bundle-declared alternative to compiled-in index manifests.
    # ⚠ The messages are declared in deploy_model.proto. `DeploymentSpec.datastore_index_tables`
    # carries the identical shapes so the CP pipeline engine can ensure a managed
    # app's indexes in the CUSTOMER project; app_bundle.proto imports deploy_model.proto
    # and not the reverse, so the shared messages live in the imported file.
    BundleIndexTable,
    SecretBinding,
)



def _ind(level: Int) -> String:
    var out = String("")
    for _ in range(level):
        out += String("  ")
    return out^


def quote(s: String) -> String:
    """Render `s` as a double-quoted textproto string literal with the closed
    escape set the tokenizer round-trips (`"`, `\\`, newline, tab, cr).

    ⛔ IT ACCUMULATES RAW BYTES, NOT `chr(Int(byte))` CODEPOINTS. Appending
    `chr(Int(c))` for every unescaped byte maps a byte >= 0x80 to the Unicode
    CODE POINT of that value and re-encodes it as TWO UTF-8 bytes. Paired with
    the identical trap on the tokenizer's side, a parse->emit round trip would
    DOUBLE the length of every non-ASCII string and turn it into mojibake — and
    since a patch splices emitted bytes back over the authored file, the
    document would be CORRUPTED a little more on each edit. Bundles carry
    em-dashes and `§` in their prose fields, so this is reachable by any patch
    of a real bundle. Nothing in the escape set is multi-byte, so a byte loop
    stays correct."""
    var buf = List[UInt8]()
    buf.append(UInt8(ord('"')))
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(ord('"')):
            buf.append(UInt8(ord("\\")))
            buf.append(UInt8(ord('"')))
        elif c == UInt8(ord("\\")):
            buf.append(UInt8(ord("\\")))
            buf.append(UInt8(ord("\\")))
        elif c == UInt8(ord("\n")):
            buf.append(UInt8(ord("\\")))
            buf.append(UInt8(ord("n")))
        elif c == UInt8(ord("\t")):
            buf.append(UInt8(ord("\\")))
            buf.append(UInt8(ord("t")))
        elif c == UInt8(ord("\r")):
            buf.append(UInt8(ord("\\")))
            buf.append(UInt8(ord("r")))
        else:
            buf.append(c)
    buf.append(UInt8(ord('"')))
    return String(StringSlice(unsafe_from_utf8=Span[UInt8](buf)))


def _emit_image(field: String, img: ImageRef, level: Int) -> String:
    var pad = _ind(level)
    var child = _ind(level + 1)
    var out = pad + field + String(" {\n")
    if img._oneof0_case == 1:
        out += child + String("digest: ") + quote(img.digest.value()) + String("\n")
    elif img._oneof0_case == 2:
        out += child + String("from_build: ") + quote(
            img.from_build.value()
        ) + String("\n")
    out += pad + String("}\n")
    return out^


def _emit_service_ref(sr: ServiceRef, level: Int) -> String:
    """Emit a `service_ref { service: "<name>" }` block — the typed CROSS-SERVICE
    reference (a LOGICAL sibling service name, never a vendor URL)."""
    var pad = _ind(level)
    var child = _ind(level + 1)
    var out = pad + String("service_ref {\n")
    out += child + String("service: ") + quote(sr.service) + String("\n")
    out += pad + String("}\n")
    return out^


def _emit_env_named(env: BundleEnvVar, field: String, level: Int) -> String:
    """Emit ONE BundleEnvVar as a `<field> { … }` block. `field` is `env` for a
    spec-level / RunContainer env var and `env_override` for a per-wave override
    (the SAME `BundleEnvVar` shape re-used by both — only the block NAME differs).

    ALL THREE `val` oneof arms are emitted. Without arm 3 (`service_ref`) an env
    var wired to a sibling service would parse, compose, and then come back from a
    round trip as a NAMELESS var with no value at all — the arm the compose path
    reads simply gone.

    ★ AND SO IS `service` (field 5) — the per-wave override's SERVICE AXIS,
    emitted immediately after `name` because it qualifies WHO the override is
    for. Default-skipped when empty, so every var that carries no axis re-emits
    byte-identically. It is emitted independently of `field`: the PARSER is what
    refuses a `service:` outside `env_override`, so a non-empty value here can
    only have come from a wave override — and an emitter that dropped it would be
    the `service_ref` loss above repeated, in a rewrite nobody reviews."""
    var pad = _ind(level)
    var child_level = level + 1
    var child = _ind(child_level)
    var out = pad + field + String(" {\n")
    out += child + String("name: ") + quote(env.name) + String("\n")
    if env.service.byte_length() > 0:
        out += child + String("service: ") + quote(env.service) + String("\n")
    if env._oneof0_case == 1:
        out += child + String("value: ") + quote(env.value.value()) + String("\n")
    elif env._oneof0_case == 2:
        out += child + String("value_from: ") + env.value_from.value().json_name() + String(
            "\n"
        )
    elif env._oneof0_case == 3:
        out += _emit_service_ref(env.service_ref.value(), child_level)
    out += pad + String("}\n")
    return out^


def _emit_app_parameter(prm: AppParameter, field: String, level: Int) -> String:
    """Emit ONE `AppParameter` as a `<field> { … }` block. `field` is
    `parameters` for the spec-level declaration and `parameter_override` for a
    per-wave binding (the SAME shape re-used by both — only the block NAME
    differs, exactly as `env` / `env_override` share `_emit_env_named`).

    EVERY field is proto3 default-skipped, so a parameter that states only a name
    and a type re-emits as exactly those two lines. `min`/`max` are gated on
    `has_min`/`has_max` rather than on non-zero: 0 is a legitimate bound, and
    emitting it only when non-zero would silently drop `min: 0` on a round
    trip — the absent-vs-empty confusion this schema exists to remove."""
    var pad = _ind(level)
    var child_level = level + 1
    var child = _ind(child_level)
    var out = pad + field + String(" {\n")
    out += child + String("name: ") + quote(prm.name) + String("\n")
    if prm.type.value != ParamType.PARAM_TYPE_UNSPECIFIED:
        out += child + String("type: ") + prm.type.json_name() + String("\n")
    if prm.required:
        out += child + String("required: true\n")
    if prm.default.byte_length() > 0:
        out += child + String("default: ") + quote(prm.default) + String("\n")
    if prm.description.byte_length() > 0:
        out += child + String("description: ") + quote(prm.description) + String("\n")
    if prm.flag.byte_length() > 0:
        out += child + String("flag: ") + quote(prm.flag) + String("\n")
    for ref a in prm.allowed_values:
        out += child + String("allowed_values: ") + quote(a) + String("\n")
    if prm.regex.byte_length() > 0:
        out += child + String("regex: ") + quote(prm.regex) + String("\n")
    if prm.has_min:
        out += child + String("min: ") + String(Int(prm.min)) + String("\n")
    if prm.has_max:
        out += child + String("max: ") + String(Int(prm.max)) + String("\n")
    # THE `source` ONEOF — exactly one arm, or none (the SUPPLIED case, which
    # emits no source line at all and is the common shape for a customer-filled
    # parameter).
    if prm._oneof0_case == 1:
        out += child + String("value: ") + quote(prm.value.value()) + String("\n")
    elif prm._oneof0_case == 2:
        out += child + String("secret_ref: ") + quote(
            prm.secret_ref.value()
        ) + String("\n")
    elif prm._oneof0_case == 3:
        out += child + String("marker: ") + prm.marker.value().json_name() + String(
            "\n"
        )
    elif prm._oneof0_case == 4:
        out += child + String("value_from: ") + prm.value_from.value().json_name(
        ) + String("\n")
    elif prm._oneof0_case == 5:
        out += _emit_service_ref(prm.service_ref.value(), child_level)
    elif prm._oneof0_case == 6:
        # ⭐ `from_build` (field 18). Re-emitted so the
        # canonical form is not lossy about a source `validate_bundle` names in
        # its refusal.
        out += child + String("from_build: ") + quote(
            prm.from_build.value()
        ) + String("\n")
    out += pad + String("}\n")
    return out^


def _emit_env(env: BundleEnvVar, level: Int) -> String:
    return _emit_env_named(env, String("env"), level)


def _emit_scaling(sc: Scaling, level: Int) -> String:
    var pad = _ind(level)
    var child = _ind(level + 1)
    var out = pad + String("scaling {\n")
    out += child + String("min: ") + String(Int(sc.min)) + String("\n")
    out += child + String("max: ") + String(Int(sc.max)) + String("\n")
    out += pad + String("}\n")
    return out^


def _emit_secret(s: SecretBinding, level: Int) -> String:
    var pad = _ind(level)
    var child = _ind(level + 1)
    var out = pad + String("secret_bindings {\n")
    out += child + String("handle: ") + quote(s.handle) + String("\n")
    out += child + String("capability_node: ") + quote(s.capability_node) + String(
        "\n"
    )
    # ENSURE-mode — emit only when TRUE (proto3
    # default-skip, so an authorize-only binding re-emits byte-identically).
    # Emitting it is not cosmetic: `ensure: true` is what makes the deploy CREATE
    # the secret container (the compose pass), so a dropped `ensure`
    # silently downgrades a PROVISIONING binding to authorize-only — the deploy
    # then authorizes a secret nothing ever created.
    if s.ensure:
        out += child + String("ensure: true\n")
    # CUSTODY (deploy_model.proto `SecretCustody`) — emit only when NON-ZERO
    # (proto3 default-skip, so a binding that named no custody re-emits
    # byte-identically). Dropping it would be the same class of silent downgrade
    # as a dropped `ensure`, but worse: an OPERATOR binding that re-emits without
    # custody becomes CUSTOMER, so a round-trip would quietly strip a handle's
    # ability to ever be seeded and the deploy would go back to authorizing a
    # secret that nothing ever puts a value in.
    if s.custody.number() != 0:
        out += child + String("custody: ") + s.custody.json_name() + String("\n")
    out += pad + String("}\n")
    return out^


def _emit_bucket(b: BucketSpec, level: Int) -> String:
    """Emit ONE `buckets { … }` block — an APP-PROVISIONED object-store bucket
    (`AppSpec.buckets`, field 20). Every field but `name` is proto3 default-skipped
    so a minimally-authored bucket re-emits as it was authored."""
    var pad = _ind(level)
    var child = _ind(level + 1)
    var out = pad + String("buckets {\n")
    out += child + String("name: ") + quote(b.name) + String("\n")
    if b.location.byte_length() > 0:
        out += child + String("location: ") + quote(b.location) + String("\n")
    if b.storage_class.byte_length() > 0:
        out += child + String("storage_class: ") + quote(b.storage_class) + String(
            "\n"
        )
    if b.uniform_bucket_level_access:
        out += child + String("uniform_bucket_level_access: true\n")
    if b.public_access_prevention.byte_length() > 0:
        out += child + String("public_access_prevention: ") + quote(
            b.public_access_prevention
        ) + String("\n")
    # The object-expiry lifetime, in days. proto3 default-skipped like the rest —
    # and here the skip is load-bearing rather than cosmetic: 0 means the bundle
    # makes NO lifetime claim, so emitting `object_expiry_days: 0` would write a
    # line that READS like a policy ("expire at age zero", which is what GCS would
    # do with it) into a file whose author never said it.
    if b.object_expiry_days != Int32(0):
        out += child + String("object_expiry_days: ") + String(
            Int(b.object_expiry_days)
        ) + String("\n")
    out += pad + String("}\n")
    return out^


def _emit_mail_transport(mt: MailTransportSpec, level: Int) -> String:
    """Emit the `mail_transport { … }` block — the app's mail spine
    (`AppSpec.mail_transport`, field 34).

    ⛔ `identity_ownership` IS EMITTED EVEN WHEN ZERO, and that asymmetry is the
    same one `_emit_secured_inbound_route` states for `policy`. The zero value is
    UNSPECIFIED, which the COMPOSER refuses by name; default-skipping it would let
    a re-emitted bundle read as though ownership were unstated-and-fine rather
    than unstated-and-refused, which is precisely the axis where a reader must not
    be able to mistake silence for a decision."""
    var pad = _ind(level)
    var child = _ind(level + 1)
    var out = pad + String("mail_transport {\n")
    out += child + String("domain: ") + quote(mt.domain) + String("\n")
    out += child + String("identity_ownership: ") + mt.identity_ownership.json_name() + String(
        "\n"
    )
    if mt.inbound_queue.byte_length() > 0:
        out += child + String("inbound_queue: ") + quote(
            mt.inbound_queue
        ) + String("\n")
    if mt.inbound_queue_logical_id.byte_length() > 0:
        out += child + String("inbound_queue_logical_id: ") + quote(
            mt.inbound_queue_logical_id
        ) + String("\n")
    for ref r in mt.dns_records:
        out += child + String("dns_records {\n")
        var gchild = _ind(level + 2)
        out += gchild + String("record_name: ") + quote(r.record_name) + String(
            "\n"
        )
        out += gchild + String("record_type: ") + quote(r.record_type) + String(
            "\n"
        )
        out += gchild + String("target: ") + quote(r.target) + String("\n")
        out += child + String("}\n")
    out += pad + String("}\n")
    return out^


def _emit_datastore_access_path(
    p: DatastoreAccessPath, key: String, level: Int
) -> String:
    """Emit ONE access-path block under `key` (`primary_access_path` or
    `secondary_access_paths`) — the two are the SAME message and therefore the
    same emitter, under a key the caller states. `key` is a parameter for the
    reason `_emit_validate_vpc_egress`'s is: one concept, two scopes, and a
    second function would mean a fix to one silently missing the other.

    ⛔ `partition_field` AND `partition_field_type` ARE EMITTED EVEN WHEN EMPTY,
    which is the asymmetry `_emit_mail_transport` states for `identity_ownership`
    and for the same reason. Both are REQUIRED and an arm REFUSES an empty one by
    name; default-skipping them would let a re-emitted bundle read as though the
    key were unstated-and-fine rather than unstated-and-refused — on the one axis
    where the wrong answer is permanent and destroys every item to correct.

    `name` and the `ordered_field` pair ARE default-skipped: the primary path has
    no name of its own on either cloud, and an absent ordered field is the
    ordinary shape (one row per partition value), so emitting either would write
    a line the author never wrote."""
    var pad = _ind(level)
    var child = _ind(level + 1)
    var out = pad + key + String(" {\n")
    if p.name.byte_length() > 0:
        out += child + String("name: ") + quote(p.name) + String("\n")
    out += child + String("partition_field: ") + quote(
        p.partition_field
    ) + String("\n")
    out += child + String("partition_field_type: ") + quote(
        p.partition_field_type
    ) + String("\n")
    if p.ordered_field.byte_length() > 0:
        out += child + String("ordered_field: ") + quote(
            p.ordered_field
        ) + String("\n")
    if p.ordered_field_type.byte_length() > 0:
        out += child + String("ordered_field_type: ") + quote(
            p.ordered_field_type
        ) + String("\n")
    out += pad + String("}\n")
    return out^


def _emit_datastore_collection(c: DatastoreCollection, level: Int) -> String:
    """Emit ONE `datastore_collections { … }` block — one keyed collection
    inside this app's datastore (`AppSpec.datastore_collections`, field 35).

    ⛔ AN EMITTER THAT DROPPED A FIELD HERE WOULD DELETE A KEY SCHEMA FROM THE
    BUNDLE on the next re-emit (the patcher, the scaffolder), and the deletion
    would be invisible: the bundle still parses, still composes, still applies,
    and the collection it names is simply never shaped — or, worse, is shaped
    DIFFERENTLY and permanently. That is the loss class this file's header
    enumerates, at the one axis where it cannot be corrected."""
    var pad = _ind(level)
    var child = _ind(level + 1)
    var out = pad + String("datastore_collections {\n")
    out += child + String("name: ") + quote(c.name) + String("\n")
    if c.primary_access_path:
        out += _emit_datastore_access_path(
            c.primary_access_path.value(),
            String("primary_access_path"),
            level + 1,
        )
    for ref sp in c.secondary_access_paths:
        out += _emit_datastore_access_path(
            sp, String("secondary_access_paths"), level + 1
        )
    if c.expiry_field.byte_length() > 0:
        out += child + String("expiry_field: ") + quote(
            c.expiry_field
        ) + String("\n")
    # `referenced` is default-skipped: FALSE is "this graph owns it", which is
    # the ordinary case and what an absent line has always meant. TRUE is the
    # ADOPT arm and is always written.
    if c.referenced:
        out += child + String("referenced: true\n")
    out += pad + String("}\n")
    return out^


def _emit_secured_inbound_route(r: SecuredInboundRoute, level: Int) -> String:
    """Emit ONE `secured_inbound_routes { … }` block — an ADDITIONAL inbound route
    the EDGE authenticates (`AppSpec.secured_inbound_routes`, field 26).

    ⛔ NOTHING HERE IS DEFAULT-SKIPPED EXCEPT AN EMPTY `sa_email`, and the
    asymmetry is deliberate. `policy` is emitted EVEN WHEN ZERO: the zero value is
    UNSPECIFIED, which `validate` REFUSES, so skipping it would let a re-emitted
    bundle read as if it declared a policy while carrying none — a round trip that
    turns an authoring error into a silent one. Same for `route_path`, which has no
    meaningful empty form.

    ⛔ AND THERE IS NO `audience` LINE, because there is no field: the accepted
    `aud` is the serving edge's own origin, bound at apply time from the live
    gateway's `default_hostname` (proto field 4 is reserved; the parser REFUSES
    the spelling by name). An emitter that still wrote one would re-materialize
    the removed value into every round-tripped bundle."""
    var pad = _ind(level)
    var child = _ind(level + 1)
    var out = pad + String("secured_inbound_routes {\n")
    out += child + String("route_path: ") + quote(r.route_path) + String("\n")
    out += child + String("policy: ") + r.policy.json_name() + String("\n")
    if r.sa_email.byte_length() > 0:
        out += child + String("sa_email: ") + quote(r.sa_email) + String("\n")
    out += pad + String("}\n")
    return out^


def _emit_index_table(t: BundleIndexTable, level: Int) -> String:
    """Emit ONE `index_tables { … }` block — the composite indexes this bundle
    declares for ONE table of the database it OWNS (`AppSpec.index_tables`,
    field 29).

    ⛔ `col`, `name` and `table` ARE EMITTED EVEN WHEN EMPTY, and `scope` even
    when unauthored. Every one of them is REQUIRED by `validate`, so an emitter
    that default-skipped them would re-emit an invalid bundle as a bundle that
    merely omits a field — turning a refusal the author can read into a silent
    hole in the index set. `desc` and `array_contains` DO default-skip: false is
    their real meaning (an ASCENDING ordered key), and skipping them is what keeps
    a round trip of an ordinary index compact.

    `scope` re-emits the CANONICAL full token the parser resolved (an authored
    short alias `COLLECTION` re-emits as `SCOPE_COLLECTION`), matching the
    canonical-full emission rule every other enum-shaped field here follows."""
    var pad = _ind(level)
    var child = _ind(level + 1)
    var ix_pad = _ind(level + 2)
    var fld_pad = _ind(level + 3)
    var out = pad + String("index_tables {\n")
    out += child + String("table: ") + quote(t.table) + String("\n")
    for ref ix in t.indexes:
        out += child + String("indexes {\n")
        out += ix_pad + String("name: ") + quote(ix.name) + String("\n")
        for ref f in ix.fields:
            out += ix_pad + String("fields {\n")
            out += fld_pad + String("col: ") + quote(f.col) + String("\n")
            if f.desc:
                out += fld_pad + String("desc: true\n")
            if f.array_contains:
                out += fld_pad + String("array_contains: true\n")
            out += ix_pad + String("}\n")
        var scope = ix.scope if ix.scope.byte_length() > 0 else String(
            "SCOPE_COLLECTION"
        )
        out += ix_pad + String("scope: ") + scope + String("\n")
        out += child + String("}\n")
    out += pad + String("}\n")
    return out^


def _emit_web_route_rule(r: WebRouteRule, level: Int) -> String:
    """Emit ONE `web_route_rules { … }` block — a FULL url-map route rule
    (`AppSpec.web_route_rules`, field 22).

    `disposition` is emitted whenever NON-ZERO, and the zero value is
    `WEB_ROUTE_DISPOSITION_ROUTE` — so a DENY rule (a NEGATIVE route: these paths
    must reach NO backend) always survives, which is the case where losing the
    field would silently turn a containment rule into a routing one."""
    var pad = _ind(level)
    var child = _ind(level + 1)
    var out = pad + String("web_route_rules {\n")
    for ref p in r.paths:
        out += child + String("paths: ") + quote(p) + String("\n")
    if r.backend_role.byte_length() > 0:
        out += child + String("backend_role: ") + quote(r.backend_role) + String(
            "\n"
        )
    if r.error_404_path.byte_length() > 0:
        out += child + String("error_404_path: ") + quote(
            r.error_404_path
        ) + String("\n")
    if r.error_404_code != 0:
        out += child + String("error_404_code: ") + String(
            Int(r.error_404_code)
        ) + String("\n")
    if r.disposition.value != 0:
        out += child + String("disposition: ") + r.disposition.json_name() + String(
            "\n"
        )
    if r.deny_reason.byte_length() > 0:
        out += child + String("deny_reason: ") + quote(r.deny_reason) + String("\n")
    out += pad + String("}\n")
    return out^


def _emit_web_frontend_override(o: WebFrontendOverride, level: Int) -> String:
    """Emit ONE `web_override { … }` block — the PER-WAVE front-door topology
    (`Wave.web_override`, field 8).

    ⚠ IT RE-USES `_emit_web_route_rule` RATHER THAN RESTATING IT, on purpose.
    `WebRouteRule` is the same message under a different parent, and two copies of
    a route-rule emitter is how one of them stops carrying `disposition` — the
    field whose loss turns the repository's only security containment into an
    ordinary routing rule. One emitter, two call sites, and
    `test_emit_completeness` authors a DENY rule under BOTH parents so neither
    call site can hide the other's loss.

    Every scalar follows the default-skip discipline, so an override authoring a
    subset re-emits as that subset. ⛔ That is a ROUND-TRIP property, not a
    permission: `validate_bundle` REFUSES an override missing slug, domain or
    route table. The emitter's job is to reproduce what was written; refusing what
    should not have been written is the validator's."""
    var pad = _ind(level)
    var child = _ind(level + 1)
    var out = pad + String("web_override {\n")
    if o.web_slug.byte_length() > 0:
        out += child + String("web_slug: ") + quote(o.web_slug) + String("\n")
    if o.web_domain.byte_length() > 0:
        out += child + String("web_domain: ") + quote(o.web_domain) + String("\n")
    for ref d in o.web_additional_domains:
        out += child + String("web_additional_domains: ") + quote(d) + String(
            "\n"
        )
    for ref p in o.web_api_path_prefixes:
        out += child + String("web_api_path_prefixes: ") + quote(p) + String("\n")
    if o.web_api_service_logical_id.byte_length() > 0:
        out += child + String("web_api_service_logical_id: ") + quote(
            o.web_api_service_logical_id
        ) + String("\n")
    for ref r in o.web_route_rules:
        out += _emit_web_route_rule(r, level + 1)
    out += pad + String("}\n")
    return out^


def _emit_cloud_variant(v: CloudVariant, level: Int) -> String:
    """Re-emit ONE `cloud_variants { … }` block (`AppSpec.cloud_variants`, field
    36). The posture is emitted ALWAYS — including `CLOUD_UNSPECIFIED`, which
    compose refuses — because an emitter that dropped a zero here would turn an
    authored mistake into a silently different document, and a round trip must
    reproduce what was written, not what should have been.

    Each member is emitted only when PRESENT, which is what makes a variant
    naming one member re-emit as a variant naming one member."""
    var pad = _ind(level)
    var child_level = level + 1
    var child = _ind(child_level)
    var out = pad + String("cloud_variants {\n")
    out += child + String("cloud: ") + _cloud_variant_cloud_name(v.cloud) + String(
        "\n"
    )
    if v.image:
        out += _emit_image(String("image"), v.image.value(), child_level)
    if v.ingress:
        out += _emit_ingress(v.ingress.value(), child_level)
    for ref c in v.datastore_collections:
        out += _emit_datastore_collection(c, child_level)
    out += pad + String("}\n")
    return out^


def _cloud_variant_cloud_token(ordinal: Int32) -> StaticString:
    """The closed token set, or `""` for an ordinal outside it.

    ⚠ SPLIT OUT OF `_cloud_variant_cloud_name` SO THE LADDER RETURNS
    `StaticString`. A 3+-arm ladder
    RETURNING a `String` lowers into two independently-relocated
    (pointer, length) constant arrays the linker can cross-bind; the caller's
    runtime `String(Int(ordinal))` fallback is what forces the split rather than
    a plain retype."""
    if ordinal == Int32(1):
        return "CLOUD_GCP"
    if ordinal == Int32(2):
        return "CLOUD_AWS"
    if ordinal == Int32(3):
        return "CLOUD_AZURE"
    if ordinal == Int32(4):
        return "CLOUD_KUBERNETES"
    if ordinal == Int32(5):
        return "CLOUD_LOCAL"
    if ordinal == Int32(0):
        return "CLOUD_UNSPECIFIED"
    return ""


def _cloud_variant_cloud_name(ordinal: Int32) -> String:
    """The canonical `Cloud` token for a mirrored ordinal — the emit-side inverse
    of `parser.cloud_variant_cloud_ordinal`. An ordinal outside the closed set
    re-emits as its NUMBER rather than as a guessed token: the round trip then
    fails loudly at the re-parse instead of silently renaming somebody's cloud."""
    var token = _cloud_variant_cloud_token(ordinal)
    if token.byte_length() != 0:
        return String(token)
    return String(Int(ordinal))


def _emit_spec(sp: AppSpec, level: Int) -> String:
    var pad = _ind(level)
    var child_level = level + 1
    var child = _ind(child_level)
    var out = pad + String("spec {\n")
    if sp.image:
        out += _emit_image(String("image"), sp.image.value(), child_level)
    out += child + String("port: ") + String(Int(sp.port)) + String("\n")
    for ref e in sp.env:
        out += _emit_env(e, child_level)
    if sp.scaling:
        out += _emit_scaling(sp.scaling.value(), child_level)
    if sp.compute.value != 0:
        out += child + String("compute: ") + sp.compute.json_name() + String("\n")
    if sp.datastore.value != 0:
        out += child + String("datastore: ") + sp.datastore.json_name() + String("\n")
    for ref s in sp.secret_bindings:
        out += _emit_secret(s, child_level)
    # runtime_identity (field 8) — emit only when AUTHORED (proto3 default-skip, like
    # compute/datastore above), so a plain bundle re-emits byte-identically.
    if sp.runtime_identity.byte_length() > 0:
        out += child + String("runtime_identity: ") + quote(
            sp.runtime_identity
        ) + String("\n")
    # STATIC_FRONTEND authoring (fields 13-17) — emit only when AUTHORED
    # (proto3 default-skip; the repeated fields use the repeated-scalar form the
    # parser reads — one line per element), so a plain bundle re-emits
    # byte-identically.
    if sp.web_slug.byte_length() > 0:
        out += child + String("web_slug: ") + quote(sp.web_slug) + String("\n")
    if sp.web_domain.byte_length() > 0:
        out += child + String("web_domain: ") + quote(sp.web_domain) + String(
            "\n"
        )
    for ref d in sp.web_additional_domains:
        out += child + String("web_additional_domains: ") + quote(d) + String(
            "\n"
        )
    for ref p in sp.web_api_path_prefixes:
        out += child + String("web_api_path_prefixes: ") + quote(p) + String(
            "\n"
        )
    if sp.web_api_service_logical_id.byte_length() > 0:
        out += child + String("web_api_service_logical_id: ") + quote(
            sp.web_api_service_logical_id
        ) + String("\n")
    # API-EDGE authoring (fields 18-19) — emit only when AUTHORED (proto3
    # default-skip), so a plain bundle re-emits byte-identically.
    if sp.inbound.value != 0:
        out += child + String("inbound: ") + sp.inbound.json_name() + String(
            "\n"
        )
    if sp.inbound_route_path.byte_length() > 0:
        out += child + String("inbound_route_path: ") + quote(
            sp.inbound_route_path
        ) + String("\n")
    # APP-PROVISIONED BUCKETS (field 20) — one `buckets { … }` block per element.
    # An EMPTY list emits nothing (a bundle that provisions no bucket re-emits
    # byte-identically).
    for ref b in sp.buckets:
        out += _emit_bucket(b, child_level)
    # EXTRA runtime CAPABILITY ORDINALS (field 21) — the repeated-scalar form (one
    # line per element, the `web_additional_domains` shape). Each is a raw
    # `Capability` ordinal, so an emitter that dropped these silently narrowed the
    # deployed service's grants.
    for ref c in sp.runtime_extra_capabilities:
        out += child + String("runtime_extra_capabilities: ") + String(
            Int(c)
        ) + String("\n")
    # FULL url-map ROUTE TABLE (field 22) — one `web_route_rules { … }` block per
    # rule.
    for ref r in sp.web_route_rules:
        out += _emit_web_route_rule(r, child_level)
    # PER-BUNDLE DEPLOY-REGION OVERRIDE (field 23) — emit only when
    # AUTHORED (proto3 default-skip, like runtime_identity above), so a bundle that
    # authors no region override re-emits byte-identically.
    if sp.region.byte_length() > 0:
        out += child + String("region: ") + quote(sp.region) + String("\n")
    # ★ THE NAME SCOPE (field 37) — emit only when AUTHORED non-zero (proto3
    # default-skip, like `region` above). UNSPECIFIED means "the authored `name`
    # IS the service name", so a bundle that authors none re-emits byte-identically.
    if sp.name_scope.value != NameScope.NAME_SCOPE_UNSPECIFIED:
        out += child + String("name_scope: ") + String(
            sp.name_scope.json_name()
        ) + String("\n")
    # PUBLIC (allUsers) INVOKER (field 24) — emit only
    # when AUTHORED true (proto3 default-skip), so a bundle that stays PRIVATE (the
    # default) re-emits byte-identically.
    if sp.public_invoker:
        out += child + String("public_invoker: true\n")
    # RETENTION (field 25; keep-last-N Cloud Run revisions) — PRESENCE-typed
    # (`Optional[Int32]`), so the emit is keyed on presence, not on a zero test:
    # UNSET means "the mapper applies the default 5", which is a DIFFERENT
    # statement from any authored value, and the parser refuses `keep_last_n: 0`
    # outright. Emitting on presence keeps those three states distinct through a
    # round trip.
    if sp.keep_last_n:
        out += child + String("keep_last_n: ") + String(
            Int(sp.keep_last_n.value())
        ) + String("\n")
    # ★ THE APP'S OWN COMPUTE ALLOCATION (fields 38-39) —
    # PRESENCE-typed (`Optional[String]`), and the emit is keyed on PRESENCE, NOT
    # on a non-empty test. `keep_last_n` above is the precedent; here the
    # distinction is load-bearing for a different reason: an authored `cpu: ""` is
    # a REFUSAL at compose, and a `byte_length() > 0` emit would silently DROP the
    # empty on a round trip — turning a bundle the composer refuses into one it
    # accepts, which is the quiet direction. Emitting on presence keeps the three
    # states (omitted / authored-empty / authored-value) distinct end to end, and
    # a bundle that omits the field re-emits byte-identically.
    if sp.cpu:
        out += child + String("cpu: ") + quote(sp.cpu.value()) + String("\n")
    if sp.memory:
        out += child + String("memory: ") + quote(
            sp.memory.value()
        ) + String("\n")
    # ★★ THE APP'S HEALTHCHECK ENDPOINT (field 40) — emitted on
    # PRESENCE, not on non-empty, for the reason `cpu`/`memory` above are: an
    # authored `health_check_path: ""` is a REFUSAL at compose, and a
    # `byte_length() > 0` emit would silently DROP it on a round trip, turning a
    # bundle the composer refuses into one it accepts. A bundle that omits the
    # field re-emits byte-identically.
    if sp.health_check_path:
        out += child + String("health_check_path: ") + quote(
            sp.health_check_path.value()
        ) + String("\n")
    # EDGE-SECURED ADDITIONAL ROUTES (field 26; federated callers) — one `secured_inbound_routes { … }` block per route. An EMPTY
    # list emits nothing, so every bundle authored before the field existed
    # re-emits byte-identically.
    for ref sr in sp.secured_inbound_routes:
        out += _emit_secured_inbound_route(sr, child_level)
    # THE DATASTORE'S DATABASE NAME (field 27) — emit only when
    # AUTHORED (proto3 default-skip, like `region` above), so a bundle with no
    # datastore re-emits byte-identically. For a datastore-bearing bundle the field
    # is REQUIRED at validate, so "authored" and "present" coincide there.
    if sp.datastore_database.byte_length() > 0:
        out += child + String("datastore_database: ") + quote(
            sp.datastore_database
        ) + String("\n")
    # THE REFERENCED DATABASE (field 28; reference-not-own) — the
    # same authored-only rule. Exactly ONE of 27/28 is ever set on a datastore-bearing
    # service, so a round-trip re-emits whichever arm the author wrote and never both.
    if sp.datastore_database_ref.byte_length() > 0:
        out += child + String("datastore_database_ref: ") + quote(
            sp.datastore_database_ref
        ) + String("\n")
    # THE APP-DECLARED INDEX SHAPES (field 29) — one
    # `index_tables { … }` block per table. An EMPTY list emits nothing, so every
    # bundle authored before the field existed re-emits byte-identically.
    for ref t in sp.index_tables:
        out += _emit_index_table(t, child_level)
    # THE INGRESS REALIZATION INPUTS (field 30) — emitted only when the bundle
    # AUTHORED an `ingress {}` block, so a bundle without one re-emits
    # byte-identically.
    if sp.ingress:
        out += _emit_ingress(sp.ingress.value(), child_level)
    # ★ THE MANAGED-APP PARAMETERS (field 31) — one
    # `parameters { … }` block per declared parameter, in AUTHORED ORDER (argv is
    # emitted in that order, so re-emission must not reorder). An EMPTY list emits
    # nothing, so every bundle authored before the field existed re-emits
    # byte-identically.
    for ref prm in sp.parameters:
        out += _emit_app_parameter(prm, String("parameters"), child_level)
    # ★ THE NETWORK REACH (field 32) — emitted only when AUTHORED
    # (proto3 default-skip, the `inbound` shape), so every bundle that names no
    # `network_ingress` re-emits byte-identically. An emitter that dropped this
    # would silently widen a service's network surface on the next round trip —
    # the same class of loss the `runtime_extra_capabilities` comment names, and
    # the reason this is emitted beside the field it belongs to rather than
    # inferred anywhere downstream.
    if sp.network_ingress.value != 0:
        out += child + String(
            "network_ingress: "
        ) + sp.network_ingress.json_name() + String("\n")
    # ★ THE SERVED SERVICE'S OUTBOUND PATH (field 33) — the `network_ingress`
    # SIBLING, emitted only when the block is AUTHORED so every bundle that names
    # none re-emits byte-identically (the round-trip gate compares exact bytes).
    # Emitted through the SAME `_emit_validate_vpc_egress` the job scope uses,
    # under THIS scope's key — see that function for why the key is a parameter.
    #
    # An emitter that dropped this would silently take a service OFF the VPC on
    # the next round trip, which is the same class of loss the `network_ingress`
    # comment above names and the reason both are emitted beside the fields they
    # belong to rather than inferred anywhere downstream.
    if sp.network_egress:
        out += _emit_validate_vpc_egress(
            sp.network_egress.value(), child_level, String("network_egress")
        )
    # ★ THE MAIL-TRANSPORT SPINE (field 34) — emitted only when AUTHORED, so every
    # bundle that names none re-emits BYTE-IDENTICALLY. An emitter that dropped it
    # would delete a domain identity, a queue and N DNS records from the bundle on
    # the next round trip, which is the loss class this file's header enumerates.
    if sp.mail_transport:
        out += _emit_mail_transport(sp.mail_transport.value(), child_level)
    # ★ THE COLLECTION SHAPES (field 35) — one `datastore_collections { … }`
    # block per authored collection, in AUTHORED ORDER and never sorted (the
    # composed manifest's content address is a hash over these bytes). An EMPTY
    # list emits nothing, so a bundle without them re-emits BYTE-IDENTICALLY.
    for ref c in sp.datastore_collections:
        out += _emit_datastore_collection(c, child_level)
    # ★ THE PER-CLOUD SPEC VARIANTS (field 36) — one `cloud_variants { … }` block
    # per authored variant, in AUTHORED ORDER. An EMPTY list emits nothing, so
    # a bundle without them re-emits BYTE-IDENTICALLY.
    for ref v in sp.cloud_variants:
        out += _emit_cloud_variant(v, child_level)
    out += pad + String("}\n")
    return out^


def _emit_http_check(hc: HttpCheck, level: Int) -> String:
    var pad = _ind(level)
    var child = _ind(level + 1)
    var out = pad + String("http_check {\n")
    out += child + String("path: ") + quote(hc.path) + String("\n")
    out += child + String("expect_status: ") + String(Int(hc.expect_status)) + String(
        "\n"
    )
    # ★ `max_latency_ms` (field 3) — EMITTED ONLY WHEN AUTHORED. Zero is the
    # proto3 default AND the "not checked" meaning, so writing `max_latency_ms:
    # 0` on every step would (a) change the bytes of every bundle this emitter
    # round-trips and (b) state a budget where none was declared.
    # Same conditional shape as `RunContainer.gate_on`'s `!= 0` guard above.
    if Int(hc.max_latency_ms) != 0:
        out += (
            child
            + String("max_latency_ms: ")
            + String(Int(hc.max_latency_ms))
            + String("\n")
        )
    out += pad + String("}\n")
    return out^


def _emit_run_container(rc: RunContainer, level: Int) -> String:
    var pad = _ind(level)
    var child_level = level + 1
    var child = _ind(child_level)
    var out = pad + String("run_container {\n")
    if rc.image:
        out += _emit_image(String("image"), rc.image.value(), child_level)
    if rc.gate_on.value != 0:
        out += child + String("gate_on: ") + rc.gate_on.json_name() + String("\n")
    for ref e in rc.env:
        out += _emit_env(e, child_level)
    # `reads_secret` — the self-fetched Secret Manager names. One line per element, AFTER `env`, and proto3-default-skipped: a step
    # that declares none re-emits byte-identical to before the field existed.
    for ref s in rc.reads_secret:
        out += child + String("reads_secret: ") + quote(s) + String("\n")
    # ★ `args` (field 5) — the argv the validator's entrypoint
    # receives, one `args { … }` block per entry, in AUTHORED ORDER (the argv
    # render walks the list in order, so re-emission must not reorder). Emitted
    # through the SAME `_emit_app_parameter` as `spec.parameters` /
    # `parameter_override`: one message, one emitter, no second spelling to keep
    # in step. An EMPTY list emits nothing, so every bundle authored before the
    # field existed re-emits byte-identically.
    for ref a in rc.args:
        out += _emit_app_parameter(a, String("args"), child_level)
    # ★ `runtime_identity` (field 6) — the SA the step's JOB runs as.
    # EMITTED ONLY WHEN SET, so every bundle authored before the field existed
    # re-emits BYTE-IDENTICALLY (the round-trip gate compares exact bytes).
    if rc.runtime_identity.byte_length() > 0:
        out += (
            child
            + String("runtime_identity: ")
            + quote(rc.runtime_identity)
            + String("\n")
        )
    # ★ `vpc_egress` (field 7) — the DIRECT VPC EGRESS attachment this
    # step's JOB carries. EMITTED ONLY WHEN THE BLOCK IS PRESENT, so every bundle
    # authored before the field existed re-emits BYTE-IDENTICALLY (the round-trip
    # gate compares exact bytes) — and so the ABSENCE of the block stays a
    # READABLE fact rather than a block of defaults nobody chose. Absent means the
    # job egresses over the public internet and cannot reach a private-ingress
    # peer; that is worth being able to see at a glance.
    if rc.vpc_egress:
        out += _emit_validate_vpc_egress(rc.vpc_egress.value(), child_level)
    # ★ `reads_telemetry` (field 8) — the read-only observability
    # planes this step's container queries for itself. One line per element, in
    # AUTHORED ORDER, and proto3-default-skipped: a step that declares none
    # re-emits byte-identical to before the field existed (the round-trip gate
    # compares exact bytes).
    for ref tr in rc.reads_telemetry:
        out += (
            child + String("reads_telemetry: ") + tr.json_name() + String("\n")
        )
    # ★ `test_role` (field 9) — the EPHEMERAL KOMIRA CALLER IDENTITIES
    # this step presents. One `test_role { … }` block per entry, in AUTHORED ORDER
    # and never sorted (the argv render walks the list in order). An EMPTY list
    # emits nothing, so every bundle authored before the field existed re-emits
    # BYTE-IDENTICALLY.
    for ref trole in rc.test_role:
        out += _emit_test_role(trole, child_level)
    # ⭐ `own_identity` (field 10) — EMITTED ONLY WHEN SET, so
    # every step authored before it re-emits byte-identically.
    if rc.own_identity.byte_length() > 0:
        out += (
            child
            + String("own_identity: ")
            + quote(rc.own_identity)
            + String("\n")
        )
    out += pad + String("}\n")
    return out^


def _emit_test_role(tr: TestRole, level: Int) -> String:
    """Emit a `test_role { … }` block. EVERY field is proto3 default-skipped, so a
    role that names only the three flags it actually wants re-emits exactly those
    lines rather than acquiring five empty flag names it never wrote — and an
    UNSPECIFIED `level` emits NOTHING, which keeps the canonical form of an
    invalid role distinguishable from one that authored READ.

    ⚠ A DROPPED FIELD HERE IS NOT A FORMATTING DIFFERENCE. `identity_secret_flag`
    lost on a round trip means the validator is never handed the address of its own
    signing key and self-mints nothing; `org_id` lost means the caller is
    provisioned into whatever the deploy's `--org-id` says instead of the tenancy
    the assertion is about. Both are green deploys."""
    var pad = _ind(level)
    var child = _ind(level + 1)
    var out = pad + String("test_role {\n")
    if tr.name.byte_length() > 0:
        out += child + String("name: ") + quote(tr.name) + String("\n")
    if tr.org_id.byte_length() > 0:
        out += child + String("org_id: ") + quote(tr.org_id) + String("\n")
    if tr.grants_on_service.byte_length() > 0:
        out += (
            child
            + String("grants_on_service: ")
            + quote(tr.grants_on_service)
            + String("\n")
        )
    if tr.level.value != 0:
        out += child + String("level: ") + tr.level.json_name() + String("\n")
    if tr.deployment_id_flag.byte_length() > 0:
        out += (
            child
            + String("deployment_id_flag: ")
            + quote(tr.deployment_id_flag)
            + String("\n")
        )
    if tr.identity_secret_flag.byte_length() > 0:
        out += (
            child
            + String("identity_secret_flag: ")
            + quote(tr.identity_secret_flag)
            + String("\n")
        )
    if tr.org_id_flag.byte_length() > 0:
        out += (
            child
            + String("org_id_flag: ")
            + quote(tr.org_id_flag)
            + String("\n")
        )
    if tr.issuer_flag.byte_length() > 0:
        out += (
            child
            + String("issuer_flag: ")
            + quote(tr.issuer_flag)
            + String("\n")
        )
    # ★ `granted_on_flag` (field 9) — the TARGET deployment's flag. Losing it
    # on a round trip is the same class as losing `identity_secret_flag`: the
    # validator is handed a caller and no resource, presents an identity to
    # nothing, and the deploy stays green.
    if tr.granted_on_flag.byte_length() > 0:
        out += (
            child
            + String("granted_on_flag: ")
            + quote(tr.granted_on_flag)
            + String("\n")
        )
    out += pad + String("}\n")
    return out^


def _emit_validate_vpc_egress(
    ve: ValidateVpcEgress, level: Int, key: String = String("vpc_egress")
) -> String:
    """Emit a `ValidateVpcEgress` block. EVERY field is proto3 default-skipped, so
    an author who names only a network and a subnetwork re-emits exactly those two
    lines rather than acquiring an empty tag list and a `private_ranges_only:
    false` they never wrote.

    ★ ONE MESSAGE, TWO SCOPES, SO THE BLOCK KEY IS A PARAMETER. The same payload
    is carried by `RunContainer.vpc_egress` (field 7 — ONE VALIDATE STEP'S JOB)
    and by `AppSpec.network_egress` (field 33 — the SERVED SERVICE), and the
    round-trip gate compares EXACT BYTES, so the emitted key must be the one the
    parser will read back at that scope. `key` DEFAULTS to the job spelling, which
    is what keeps the job call site and every existing bundle byte-identical."""
    var pad = _ind(level)
    var child = _ind(level + 1)
    var out = pad + key + String(" {\n")
    if ve.network.byte_length() > 0:
        out += child + String("network: ") + quote(ve.network) + String("\n")
    if ve.subnetwork.byte_length() > 0:
        out += (
            child + String("subnetwork: ") + quote(ve.subnetwork) + String("\n")
        )
    for ref t in ve.network_tags:
        out += child + String("network_tags: ") + quote(t) + String("\n")
    if ve.private_ranges_only:
        out += child + String("private_ranges_only: true\n")
    out += pad + String("}\n")
    return out^


def _emit_ingress(ing: IngressSpec, level: Int) -> String:
    """Emit the `ingress { … }` block — the ingress REALIZATION inputs
    (`AppSpec.ingress`, field 30). EVERY field is proto3
    default-skipped, and every default means "today's behaviour", so a bundle
    that authors an `ingress {}` for one reason re-emits carrying only that one
    reason rather than a full block of values it never chose."""
    var pad = _ind(level)
    var child = _ind(level + 1)
    var out = pad + String("ingress {\n")
    if ing.gateway_service_account.byte_length() > 0:
        out += child + String("gateway_service_account: ") + quote(
            ing.gateway_service_account
        ) + String("\n")
    if ing.gateway_region.byte_length() > 0:
        out += child + String("gateway_region: ") + quote(
            ing.gateway_region
        ) + String("\n")
    for ref a in ing.allowed_sources:
        out += child + String("allowed_sources: ") + quote(a) + String("\n")
    if ing.enable_required_services:
        out += child + String("enable_required_services: true\n")
    # ⛔ WHO MAY CALL THIS APP (field 5) + THE `aud` A PEER MUST CARRY (field 6).
    # A parse arm with no emitter twin is the exact defect this emitter's own
    # `tenancy` comment describes; `test_emit_completeness` catches it.
    #
    # ⚠ AND THE LOSS WOULD FAIL OPEN, WHICH MOST DROPPED FIELDS DO NOT.
    # `caller_class` dropping to its zero value does not degrade to "unset" — it
    # degrades to UNSPECIFIED, which the compose pass reads as THE DEFAULT BEHAVIOUR: a
    # `CLIENT_PASSTHROUGH` edge. A peer-only service round-tripped through this
    # function would come back a public one, so the canonical form must not be
    # lossy here.
    if ing.caller_class.value != 0:
        out += child + String("caller_class: ") + ing.caller_class.json_name()
        out += String("\n")
    if ing.peer_identity_audience.byte_length() > 0:
        out += child + String("peer_identity_audience: ") + quote(
            ing.peer_identity_audience
        ) + String("\n")
    out += pad + String("}\n")
    return out^


def _emit_job_spec(j: JobSpec, level: Int) -> String:
    """Emit ONE `jobs { … }` block — a run-to-completion job this bundle ships
    (`AppBundle.jobs`, field 12).

    ⚠ `max_retries` IS EMITTED ON PRESENCE, NOT ON NON-ZERO, AND THAT ASYMMETRY
    IS THE POINT. It is proto3-optional precisely because an authored
    `max_retries: 0` ("a failure is a verdict, do not retry") is a real demand
    that happens to equal the zero value. A default-skip keyed on the VALUE would
    drop it on the round trip, and the job would come back with platform-default
    retries — a gate that starts passing on its second attempt. `task_timeout_
    seconds` is a plain int and IS value-skipped, because its 0 genuinely means
    "the platform default" and nothing else."""
    var pad = _ind(level)
    var child_level = level + 1
    var child = _ind(child_level)
    var out = pad + String("jobs {\n")
    out += child + String("name: ") + quote(j.name) + String("\n")
    if j.image:
        out += _emit_image(String("image"), j.image.value(), child_level)
    for ref e in j.env:
        out += _emit_env(e, child_level)
    for ref sb in j.secret_bindings:
        out += _emit_secret(sb, child_level)
    if j.runtime_identity.byte_length() > 0:
        out += child + String("runtime_identity: ") + quote(
            j.runtime_identity
        ) + String("\n")
    if j.max_retries:
        out += child + String("max_retries: ") + String(
            Int(j.max_retries.value())
        ) + String("\n")
    if Int(j.task_timeout_seconds) != 0:
        out += child + String("task_timeout_seconds: ") + String(
            Int(j.task_timeout_seconds)
        ) + String("\n")
    if j.region.byte_length() > 0:
        out += child + String("region: ") + quote(j.region) + String("\n")
    # ★ `args` (field 9) — ONE LINE PER ELEMENT, IN AUTHORED ORDER. An empty
    # list emits nothing (the repeated-field rule the env/secret loops above
    # follow), so every bundle authoring no argv is byte-identical.
    #
    # ⛔ THE FIXPOINT GATE CANNOT SEE THIS ARM GOING MISSING. parse->emit->parse
    # is still a fixed point when a field is dropped UNIFORMLY, so a deleted
    # `args` loop leaves `test_canonical_form_is_a_stable_fixpoint` green while
    # every authored argv silently vanishes on any write-back. What sees it is
    # `test_dropped_field_content_survives_the_round_trip`, which asserts the
    # LIST, its ORDER and its ARITY against the authored literals.
    for ref a in j.args:
        out += child + String("args: ") + quote(a) + String("\n")
    out += pad + String("}\n")
    return out^


def _emit_execute_job(ej: ExecuteJob, level: Int) -> String:
    """Emit the `execute_job { … }` check arm — execute a declared job and gate on
    its exit code. `job` unconditionally (an empty one is an authoring error the
    validator rejects, not a default to elide — the `_emit_schedule` rule);
    `gate_on` default-skipped like `run_container`'s."""
    var pad = _ind(level)
    var child = _ind(level + 1)
    var out = pad + String("execute_job {\n")
    out += child + String("job: ") + quote(ej.job) + String("\n")
    if ej.gate_on.value != 0:
        out += child + String("gate_on: ") + ej.gate_on.json_name() + String("\n")
    out += pad + String("}\n")
    return out^


def _emit_cron_spec(c: CronSpec, level: Int) -> String:
    """Emit ONE `crons { … }` block — a scheduled call into a sibling service
    (`AppBundle.crons`, field 13). `name` + `cron` unconditionally
    (both are validator-required and have no meaningful empty form); everything
    else default-skipped. `target` is emitted whenever PRESENT even if its inner
    `service` is empty, because an empty target is a validator refusal and
    dropping the block would turn that refusal into a silently target-less cron."""
    var pad = _ind(level)
    var child_level = level + 1
    var child = _ind(child_level)
    var out = pad + String("crons {\n")
    out += child + String("name: ") + quote(c.name) + String("\n")
    out += child + String("cron: ") + quote(c.cron) + String("\n")
    if c.timezone.byte_length() > 0:
        out += child + String("timezone: ") + quote(c.timezone) + String("\n")
    if c.target:
        out += child + String("target {\n")
        out += _ind(child_level + 1) + String("service: ") + quote(
            c.target.value().service
        ) + String("\n")
        out += child + String("}\n")
    if c.path.byte_length() > 0:
        out += child + String("path: ") + quote(c.path) + String("\n")
    if c.http_method.byte_length() > 0:
        out += child + String("http_method: ") + quote(c.http_method) + String(
            "\n"
        )
    if c.invoker_identity.byte_length() > 0:
        out += child + String("invoker_identity: ") + quote(
            c.invoker_identity
        ) + String("\n")
    if Int(c.attempt_deadline_seconds) != 0:
        out += child + String("attempt_deadline_seconds: ") + String(
            Int(c.attempt_deadline_seconds)
        ) + String("\n")
    out += pad + String("}\n")
    return out^


def _emit_ephemeral(e: EphemeralScope, level: Int) -> String:
    """Emit the `ephemeral { … }` block — the bundle's PERMISSION to be deployed
    and destroyed as a throwaway run (`AppBundle.ephemeral`, field 14).

    ⛔ `keep_overridden_because` IS EMITTED UNCONDITIONALLY, INCLUDING EMPTY. It
    is the written justification for ignoring a data-protecting retention, and
    validate REFUSES an empty one — so default-skipping it would hand back a block
    that reads as a complete, valid ephemeral declaration while carrying no
    justification at all, turning an authoring error into a silent one. Same rule
    as `SecuredInboundRoute.policy`."""
    var pad = _ind(level)
    var child = _ind(level + 1)
    var out = pad + String("ephemeral {\n")
    out += child + String("keep_overridden_because: ") + quote(
        e.keep_overridden_because
    ) + String("\n")
    if Int(e.max_lifetime_seconds) != 0:
        out += child + String("max_lifetime_seconds: ") + String(
            Int(e.max_lifetime_seconds)
        ) + String("\n")
    out += pad + String("}\n")
    return out^


def _emit_validate_named(v: ValidateStep, field: String, level: Int) -> String:
    """Emit ONE validation step as a `<field> { … }` block. `field` is `validate`
    for a `Wave.validate` step and `steps` for a `ValidationSet.steps` step — the
    SAME `ValidateStep` shape re-used by both the env-keyed wave and the named set."""
    var pad = _ind(level)
    var child_level = level + 1
    var child = _ind(child_level)
    var out = pad + field + String(" {\n")
    out += child + String("name: ") + quote(v.name) + String("\n")
    # ★ THE SERVICE AXIS — emitted ONLY when non-empty (proto3 default-skip), so a
    # single-service bundle re-emits byte-identically. Emitting it when set is
    # load-bearing rather than cosmetic: a step that named its service, parsed,
    # then lost the name on the round trip would silently revert to probing
    # `observed_served_urls[0]` — the exact defect the field exists to end.
    if v.service.byte_length() > 0:
        out += child + String("service: ") + quote(v.service) + String("\n")
    if v._oneof0_case == 1:
        out += _emit_http_check(v.http_check.value(), child_level)
    elif v._oneof0_case == 2:
        out += _emit_run_container(v.run_container.value(), child_level)
    elif v._oneof0_case == 3:
        out += _emit_execute_job(v.execute_job.value(), child_level)
    # The step-DAG edges (the parallel validation scheduler orders by these).
    # Emit ONE `depends_on` line per dep; an EMPTY list emits nothing (round-trip
    # stable — an authored bundle with no deps re-emits byte-identically).
    for ref d in v.depends_on:
        out += child + String("depends_on: ") + quote(d) + String("\n")
    # The EXCLUSION MARKER — emitted ONLY when non-empty (proto3 default-skip), so
    # a bundle that excludes nothing re-emits byte-identically. Emitting it when
    # set is load-bearing, not cosmetic: an exclusion that survived a parse but
    # vanished on the round trip would silently RE-ARM an excluded step the next
    # time the bundle is written back.
    if v.excluded_because.byte_length() > 0:
        out += (
            child
            + String("excluded_because: ")
            + quote(v.excluded_because)
            + String("\n")
        )
    out += pad + String("}\n")
    return out^


def _emit_validate(v: ValidateStep, level: Int) -> String:
    return _emit_validate_named(v, String("validate"), level)


def _emit_git_push(g: GitPush, level: Int) -> String:
    """Emit the `git_push { … }` arm. Every field UNCONDITIONALLY, including a
    proto3-zero enum — deliberately unlike the default-skip rule the optional
    scalars follow. `SOURCE_KIND_UNSPECIFIED` is an AUTHORING ERROR (fail-fast,
    stated in the proto), so a round trip must hand it back to the validator to
    REJECT rather than quietly drop it into a shape that reads as "unset"."""
    var pad = _ind(level)
    var child = _ind(level + 1)
    var out = pad + String("git_push {\n")
    out += child + String("source_kind: ") + g.source_kind.json_name() + String("\n")
    out += child + String("repo_ref: ") + quote(g.repo_ref) + String("\n")
    # The proto field is `ref`; the generated Mojo field escapes to `ref_` (`ref`
    # is a Mojo keyword). The AUTHORED/wire name stays `ref` — emit that.
    out += child + String("ref: ") + quote(g.ref_) + String("\n")
    out += pad + String("}\n")
    return out^


def _emit_schedule(s: Schedule, level: Int) -> String:
    """Emit the `schedule { … }` arm. `cron` unconditionally (an empty cron is an
    authoring error the validator rejects, not a default to elide); `timezone`
    default-skipped since EMPTY means UTC by construction."""
    var pad = _ind(level)
    var child = _ind(level + 1)
    var out = pad + String("schedule {\n")
    out += child + String("cron: ") + quote(s.cron) + String("\n")
    if s.timezone.byte_length() > 0:
        out += child + String("timezone: ") + quote(s.timezone) + String("\n")
    out += pad + String("}\n")
    return out^


def _emit_package_published(p: PackagePublished, level: Int) -> String:
    """Emit the `package_published { … }` arm. `registry_kind` + `package_ref`
    unconditionally (both are authoring errors when unset); `version_range` is
    default-skipped since EMPTY means "any published version" by construction."""
    var pad = _ind(level)
    var child = _ind(level + 1)
    var out = pad + String("package_published {\n")
    out += child + String("registry_kind: ") + p.registry_kind.json_name() + String(
        "\n"
    )
    out += child + String("package_ref: ") + quote(p.package_ref) + String("\n")
    if p.version_range.byte_length() > 0:
        out += child + String("version_range: ") + quote(p.version_range) + String(
            "\n"
        )
    out += pad + String("}\n")
    return out^


def _emit_trigger_source(t: TriggerSource, level: Int) raises -> String:
    """Emit ONE `triggers { … }` block — a NAMED trigger plus exactly one payload
    arm (`AppBundle.triggers`, field 6).

    WHY THIS FUNCTION MATTERS. Without it an authored trigger block would VANISH on
    any parse -> emit round trip: a machine declared CONTINUOUS would come back out
    declared one-shot, with no error. The PRESENCE of >=1 trigger IS the
    continuous-vs-one-shot identifier (see `app_bundle.proto`), so dropping the
    block does not merely lose a detail — it inverts the deployment mode.

    ARM DISCIPLINE. `_oneof0_case` is the 1-BASED ARM INDEX in declaration order
    (git_push=1, schedule=2, package_published=3), NOT the proto field number
    (6/7/8). A WRONG index here is a SILENT wrong-arm emit, not a compile error,
    which is why the round-trip guard asserts per-arm rather than only asserting
    that *something* came back.

    AN UNSET ARM RAISES. A `TriggerSource` with `_oneof0_case == 0` names no
    firing condition, so re-emitting it would produce a block the parser reads
    back as a still-armless trigger while the author believes they declared one.
    That is the same silent-loss class this whole function exists to close, one
    level down — so it fails loudly instead."""
    var pad = _ind(level)
    var child_level = level + 1
    var child = _ind(child_level)
    var out = pad + String("triggers {\n")
    out += child + String("name: ") + quote(t.name) + String("\n")
    if t._oneof0_case == 1:
        out += _emit_git_push(t.git_push.value(), child_level)
    elif t._oneof0_case == 2:
        out += _emit_schedule(t.schedule.value(), child_level)
    elif t._oneof0_case == 3:
        out += _emit_package_published(t.package_published.value(), child_level)
    else:
        raise Error(
            "emit_bundle: trigger '"
            + t.name
            + "' has NO payload arm set (TriggerSource.on is unset) — it names no"
            " firing condition. Emitting it would hand back a document the parser"
            " reads as a still-armless trigger. Author exactly one of `git_push`,"
            " `schedule`, `package_published`."
        )
    out += pad + String("}\n")
    return out^


def _emit_validation_set(vs: ValidationSet, level: Int) -> String:
    """Emit ONE `validation_sets { name: "…" env_policy: … envs: "…" steps { … }
    }` block — a NAMED validation set (defined once, referenced by name).

    ⚠ `env_policy` IS DEFAULT-SKIPPED AT UNSPECIFIED, and that is not laziness:
    every bundle that declares no policy must round-trip byte-
    identically, or this field stops being additive and becomes a migration.
    Emitting `env_policy: VALIDATION_SET_ENV_POLICY_UNSPECIFIED` into every
    document would also write the word "policy" into files that state none —
    text that reads as a decision nobody made. `envs` is repeated, so the empty
    list emits nothing on its own."""
    var pad = _ind(level)
    var child_level = level + 1
    var child = _ind(child_level)
    var out = pad + String("validation_sets {\n")
    out += child + String("name: ") + quote(vs.name) + String("\n")
    if (
        vs.env_policy.value
        != ValidationSetEnvPolicy.VALIDATION_SET_ENV_POLICY_UNSPECIFIED
    ):
        out += (
            child
            + String("env_policy: ")
            + vs.env_policy.json_name()
            + String("\n")
        )
    for ref e in vs.envs:
        out += child + String("envs: ") + quote(e) + String("\n")
    for ref s in vs.steps:
        out += _emit_validate_named(s, String("steps"), child_level)
    out += pad + String("}\n")
    return out^


def _emit_pipeline_step(ps: PipelineStep, level: Int) -> String:
    """Emit ONE `steps { step_kind: … envs: "…" validation_set_refs: "…"
    matrix_ref: "…" }` block — a single pipeline STEP.

    `matrix_ref` is emitted only when non-empty (proto3 default-skip). It is
    parsed and fail-closed validated (`validate.mojo` refuses a ref naming no
    declared matrix); dropping it here would UN-FAN the step on a round trip, and
    the validation that would catch a dangling ref would pass precisely because
    the ref was gone."""
    var pad = _ind(level)
    var child = _ind(level + 1)
    var out = pad + String("steps {\n")
    out += child + String("step_kind: ") + ps.step_kind.json_name() + String("\n")
    for ref e in ps.envs:
        out += child + String("envs: ") + quote(e) + String("\n")
    for ref r in ps.validation_set_refs:
        out += child + String("validation_set_refs: ") + quote(r) + String("\n")
    if ps.matrix_ref.byte_length() > 0:
        out += child + String("matrix_ref: ") + quote(ps.matrix_ref) + String("\n")
    out += pad + String("}\n")
    return out^


def _emit_matrix_cell(c: MatrixCell, level: Int) -> String:
    """Emit ONE `cell { … }` block of a device/capability matrix. `name` always;
    every axis only when authored (an empty axis means ANY, which is a DIFFERENT
    statement from a named one)."""
    var pad = _ind(level)
    var child = _ind(level + 1)
    var out = pad + String("cell {\n")
    out += child + String("name: ") + quote(c.name) + String("\n")
    if c.os.byte_length() > 0:
        out += child + String("os: ") + quote(c.os) + String("\n")
    if c.arch.byte_length() > 0:
        out += child + String("arch: ") + quote(c.arch) + String("\n")
    if c.artifact_kind.byte_length() > 0:
        out += child + String("artifact_kind: ") + quote(
            c.artifact_kind
        ) + String("\n")
    if c.os_version_min.byte_length() > 0:
        out += child + String("os_version_min: ") + quote(
            c.os_version_min
        ) + String("\n")
    if c.os_version_max.byte_length() > 0:
        out += child + String("os_version_max: ") + quote(
            c.os_version_max
        ) + String("\n")
    if c.from_build.byte_length() > 0:
        out += child + String("from_build: ") + quote(c.from_build) + String("\n")
    if c.browser.byte_length() > 0:
        out += child + String("browser: ") + quote(c.browser) + String("\n")
    out += pad + String("}\n")
    return out^


def _emit_matrix(m: Matrix, level: Int) -> String:
    """Emit ONE `matrices { name: "…" cell { … } … }` block — a NAMED
    device/capability matrix (`AppBundle.matrices`, field 10), referenced by a
    `PipelineStep.matrix_ref`."""
    var pad = _ind(level)
    var child_level = level + 1
    var child = _ind(child_level)
    var out = pad + String("matrices {\n")
    out += child + String("name: ") + quote(m.name) + String("\n")
    for ref c in m.cell:
        out += _emit_matrix_cell(c, child_level)
    out += pad + String("}\n")
    return out^


def _emit_pipeline(p: Pipeline, level: Int) -> String:
    """Emit the `pipeline { steps { … } … }` block — the ordered list of steps."""
    var pad = _ind(level)
    var child_level = level + 1
    var out = pad + String("pipeline {\n")
    for ref s in p.steps:
        out += _emit_pipeline_step(s, child_level)
    out += pad + String("}\n")
    return out^


def _emit_deploy_output(o: DeployOutput, level: Int) -> String:
    """Emit ONE `outputs { name: "…" from_served: "…" }` block — a named DEPLOY
    OUTPUT. `from_served` is emitted only
    when non-empty (proto3 default-skip)."""
    var pad = _ind(level)
    var child = _ind(level + 1)
    var out = pad + String("outputs {\n")
    out += child + String("name: ") + quote(o.name) + String("\n")
    if o.from_served.byte_length() > 0:
        out += child + String("from_served: ") + quote(o.from_served) + String("\n")
    out += pad + String("}\n")
    return out^


def _emit_service_spec(svc: ServiceSpec, level: Int) -> String:
    """Emit ONE `services { name: … kind: … spec { … } }` block — one named
    service of a MULTI-SERVICE bundle (`AppBundle.services`, field 7).

    ★ THE ROUND-TRIP TWIN of `parser.mojo`'s `_parse_service_spec`. It emits all three
    of the proto's fields and REUSES `_emit_spec` for the nested intent, so a
    service's `spec {}` is byte-for-byte the SAME grammar as the singular one —
    the same reuse the parser makes, for the same reason: two parallel AppSpec
    serializers would drift the first time a field landed on one and not the other,
    and nothing would say so.

    ⚠ `kind` IS EMITTED UNCONDITIONALLY, breaking this emitter's default-skip
    habit, and the exception is the point. Everywhere else a proto3 zero means
    "the author said nothing" and skipping it is how a bundle re-emits
    byte-identically. Here the zero is APP_KIND_UNSPECIFIED on a service that a
    services-block author had to write down, and a re-emit that dropped it would
    turn a bundle `compose()` REFUSES BY NAME into one that parses clean and
    refuses later somewhere else. There is no byte-identity cost: a bundle with no
    `services {}` block emits none of this at all.

    `spec` is emitted only when present — a `ServiceSpec` with no spec is a
    validate-time error (`validate.mojo` reports it per element), not a
    serialization one, and inventing an empty `spec {}` here would make the
    canonical form ASSERT something the author did not."""
    var pad = _ind(level)
    var child_level = level + 1
    var child = _ind(child_level)
    var out = pad + String("services {\n")
    out += child + String("name: ") + quote(svc.name) + String("\n")
    out += child + String("kind: ") + svc.kind.json_name() + String("\n")
    if svc.spec:
        out += _emit_spec(svc.spec.value(), child_level)
    out += pad + String("}\n")
    return out^


def _emit_wave(w: Wave, level: Int) -> String:
    var pad = _ind(level)
    var child_level = level + 1
    var child = _ind(child_level)
    var out = pad + String("waves {\n")
    out += child + String("env: ") + quote(w.env) + String("\n")
    for ref v in w.validate:
        out += _emit_validate(v, child_level)
    # The per-wave api-edge staging toggle (field 3) — emit only when ON
    # (proto3 default-skip), so a plain bundle re-emits byte-identically.
    if w.api_edge_enabled:
        out += child + String("api_edge_enabled: true\n")
    # The per-wave env-var overrides (field 4) — the per-ENV deploy config that is
    # NOT `${project}`-derivable. Re-emit each as an `env_override { … }` block via
    # the SAME `_emit_env` the spec-level `env {}` uses (only the field NAME differs).
    # An EMPTY list emits nothing — a bundle with no override re-emits byte-identically.
    for ref e in w.env_override:
        out += _emit_env_named(e, String("env_override"), child_level)
    # ★ THE PER-WAVE PARAMETER OVERRIDES (field 5) — the per-ENV parameter
    # binding, re-emitted through the SAME `_emit_app_parameter` the spec-level
    # `parameters {}` uses (only the block NAME differs). EMPTY emits nothing.
    for ref prm in w.parameter_override:
        out += _emit_app_parameter(prm, String("parameter_override"), child_level)
    # ★ THE CONTROL PLANE THIS ENV'S PEER EDGES TRUST (field 6) and ★★ THE
    # AUTHENTICATED DEVELOPER-ACCESS PRINCIPAL (field 7). Each parse arm needs
    # this emitter twin; `test_emit_completeness` reds without it.
    #
    # ⚠ THE SECOND ONE IS EMITTED, NOT SUPPRESSED, AND THAT IS DELIBERATE. It is
    # tempting to drop a non-production credential name from the canonical form
    # "so it cannot travel". It is a NAME, never a secret, and a form that drops
    # it silently is one an operator diffs against their bundle and believes
    # agrees. What keeps it out of production is `compose_api`'s per-env
    # allow-list, which is a gate; an emitter that lies is not.
    if w.peer_identity_issuer.byte_length() > 0:
        out += child + String("peer_identity_issuer: ") + quote(
            w.peer_identity_issuer
        ) + String("\n")
    if w.developer_access_principal.byte_length() > 0:
        out += child + String("developer_access_principal: ") + quote(
            w.developer_access_principal
        ) + String("\n")
    # ★★ THE PER-WAVE WEB FRONT-DOOR TOPOLOGY (field 8).
    #
    # ⚠ THE SKIP IS ON `Optional`-ABSENCE, NOT ON EMPTINESS, and that distinction
    # is the whole reason the field is `Optional[WebFrontendOverride]` rather than
    # a bare message. NO OVERRIDE means "this wave's front door comes from the
    # bundle-level spec". AN OVERRIDE AUTHORING NOTHING is a REFUSAL at
    # `validate_bundle` — the override is TOTAL, so an empty one would compose a
    # front door with no slug, no domain and no routes. An emitter that collapsed
    # the two would turn a refusal into a fallback on every round trip, which is
    # exactly the direction `patch` walks.
    if w.web_override:
        out += _emit_web_frontend_override(w.web_override.value(), child_level)
    # ⭐ THE PER-SERVICE API-EDGE ALLOW-LIST (field 9). One
    # line per element, in AUTHORED ORDER; EMPTY emits nothing (byte-identical).
    for ref svc in w.api_edge_services:
        out += child + String("api_edge_services: ") + quote(svc) + String("\n")
    out += pad + String("}\n")
    return out^


def emit_bundle(bundle: AppBundle) raises -> String:
    """Serialize `bundle` to the canonical `komira.deploy.textproto` form.
    Deterministic, proto-field-number ordered, 2-space indented, one blank line
    between top-level sections — the round-trip partner of `parse_bundle`."""
    var out = String("kind: ") + bundle.kind.json_name() + String("\n")
    # ★ TENANCY (field 15) — emitted ONLY when the bundle carries a CONCRETE
    # value, so a bundle that authors none re-emits byte-identically (the
    # default-skip discipline every field on this emitter follows).
    #
    # ⛔ EMITTING IT AT ALL IS THE POINT. A parse arm with no emitter twin is
    # exactly the defect `tests/test_emit_completeness.mojo` exists to catch, and
    # its totality leg reads the legal field set OUT OF THE PARSER at run time.
    # `emit_bundle` is the parser's declared round-trip partner; a field it
    # accepts and this drops makes the canonical form lossy.
    #
    # ⚠ THE POSITION IS NOT THE FIELD-NUMBER POSITION, AND THAT IS ON PURPOSE.
    # Field 15 would sort last, after every block. Bundles author `tenancy:` on
    # the line after `kind:`, and the two scalars that head
    # a bundle are read together — `kind` is the TOPOLOGY, `tenancy` the TRUST
    # BOUNDARY, and separating them by the whole document is how a reader comes
    # to believe one implies the other.
    #
    # ⚠ NOT A PATCH HAZARD, though it looks like one: the patch verb is the
    # comment-preserving BYTE splicer (`patch.mojo`), which never round-trips a
    # document through this function.
    if bundle.tenancy.value != Tenancy.TENANCY_UNSPECIFIED:
        out += String("tenancy: ") + bundle.tenancy.json_name() + String("\n")
    out += String("name: ") + quote(bundle.name) + String("\n")
    for ref b in bundle.build:
        out += String("\n") + _ind(0) + String("build {\n")
        out += _ind(1) + String("name: ") + quote(b.name) + String("\n")
        out += _ind(1) + String("dockerfile: ") + quote(b.dockerfile) + String("\n")
        # These fields are emitted ONLY when non-default so an IMAGE bundle
        # round-trips byte-identically (context "" / output "" / output_format
        # IMAGE=0 are the zero-migration defaults).
        if b.context.byte_length() > 0:
            out += _ind(1) + String("context: ") + quote(b.context) + String("\n")
        if b.output_format.value != OutputFormat.OUTPUT_FORMAT_IMAGE:
            out += (
                _ind(1)
                + String("output_format: ")
                + b.output_format.json_name()
                + String("\n")
            )
        if b.output.byte_length() > 0:
            out += _ind(1) + String("output: ") + quote(b.output) + String("\n")
        # ⭐ Fields 6/7 — emitted ONLY when non-zero, so every
        # target authored before them re-emits byte-identically. A dropped role
        # on a round trip would stage a pod-loader bundle nowhere / stage a
        # customer job image into the operator's registry — both silent.
        if b.file_role.value != 0:
            out += (
                _ind(1)
                + String("file_role: ")
                + b.file_role.json_name()
                + String("\n")
            )
        if b.repository_role.value != 0:
            out += (
                _ind(1)
                + String("repository_role: ")
                + b.repository_role.json_name()
                + String("\n")
            )
        out += String("}\n")
    if bundle.spec:
        out += String("\n") + _emit_spec(bundle.spec.value(), 0)
    for ref w in bundle.waves:
        out += String("\n") + _emit_wave(w, 0)
    # The CONTINUOUS-DEPLOYMENT TRIGGERS (field 6). ZERO triggers emits nothing
    # (one-shot), so a bundle with no trigger re-emits byte-identically.
    #
    for ref t in bundle.triggers:
        out += String("\n") + _emit_trigger_source(t, 0)
    # ★ THE MULTI-SERVICE LIST (field 7). The parser authors it
    # (`_parse_service_spec`), so this emitter must too, under the invariant it
    # holds: EVERYTHING THE PARSER ACCEPTS, not every field of the struct. A parse
    # arm with no emitter twin is exactly the defect `test_emit_completeness`
    # exists to catch.
    #
    # ZERO services emits NOTHING, which is what keeps every single-service
    # bundle a byte-identical round trip: an empty `services` is
    # the AUTO-LIFT signal, not an absent value, and materializing the lifted
    # one-element list here would rewrite each of those bundles into a shape whose
    # singular `name`/`spec` are suddenly ignored.
    for ref svc in bundle.services:
        out += String("\n") + _emit_service_spec(svc, 0)
    # Named validation SETS + the
    # pipeline. Emitted only-when-present (proto3 default-skip), so a pre-reshape
    # bundle re-emits byte-identically.
    for ref vs in bundle.validation_sets:
        out += String("\n") + _emit_validation_set(vs, 0)
    if bundle.pipeline:
        out += String("\n") + _emit_pipeline(bundle.pipeline.value(), 0)
    # The NEUTRAL device/capability MATRICES (field 10) — emitted only when
    # authored, so a pre-matrix bundle re-emits byte-identically.
    for ref m in bundle.matrices:
        out += String("\n") + _emit_matrix(m, 0)
    # The named DEPLOY OUTPUTS. Emitted only-when-present (proto3 default-skip),
    # so a bundle without outputs re-emits byte-identically.
    for ref o in bundle.outputs:
        out += String("\n") + _emit_deploy_output(o, 0)
    # Four optional capabilities. Each is emitted ONLY when authored, so a bundle
    # that authors none of them round-trips byte-identically.
    for ref j in bundle.jobs:
        out += String("\n") + _emit_job_spec(j, 0)
    for ref c in bundle.crons:
        out += String("\n") + _emit_cron_spec(c, 0)
    if bundle.ephemeral:
        out += String("\n") + _emit_ephemeral(bundle.ephemeral.value(), 0)
    return out^
