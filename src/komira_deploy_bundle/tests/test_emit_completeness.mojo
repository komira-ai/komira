# =============================================================================
# tests/test_emit_completeness.mojo
#   — THE EMITTER MUST NOT SILENTLY DROP A FIELD THE PARSER ACCEPTS.
# =============================================================================
#
# THE DEFECT. An emitter that omits a field `parse_bundle` accepts and populates
# (for example `triggers`, AppBundle field 6) makes an authored block VANISH on
# any parse->emit round trip, silently. The same defect can sit one frame in:
# `matrices` (AppBundle 10), `AppSpec.buckets` (20),
# `AppSpec.runtime_extra_capabilities` (21), `AppSpec.web_route_rules` (22),
# `AppSpec.keep_last_n` (25), `BundleEnvVar.service_ref` (the third oneof arm),
# `SecretBinding.ensure`, `PipelineStep.matrix_ref`. Every one is a field the
# parser reads and an emitter can forget. That is why this file is a TOTALITY
# gate and not a row per field: a row per field only ever catches the field
# somebody remembered to write a row for.
#
# ── HOW THE TOTALITY IS DERIVED, NOT RESTATED ───────────────────────────────
# The parser's own unknown-field diagnostic ENUMERATES each block's legal field
# set ("unknown field 'zzzzqqqq' in AppSpec (known fields: image, port, …)"), so
# the vocabulary this gate holds the emitter to is READ OUT OF THE PARSER at run
# time by feeding it a deliberately-unknown field per block. Nothing here is a
# copy of a list in parser.mojo — a field added there joins this gate with no edit
# to this file, and the fixture-totality leg goes RED naming it.
#
# Four legs, each answering "what wrong value would still make this pass?":
#   (a) THE FIXTURE IS TOTAL — every field name the parser accepts, in any block,
#       is authored by `_everything_bundle()`. Without this, (b) is vacuous for
#       any field the fixture forgot.
#   (b) NOTHING IS DROPPED — every (indent-depth, field-name) pair authored in the
#       fixture reappears in `emit_bundle`'s output at the SAME depth. Depth is
#       load-bearing: a `name` re-emitted one level up is not the same document.
#   (c) THE CONTENT SURVIVES, NOT JUST THE WORD — the re-parsed bundle is compared
#       against the authored literals. (b) alone is satisfied by an EMPTY
#       `triggers {}`, which is data loss that prints the right word.
#   (d) THE CANONICAL FORM IS A FIXPOINT — emit(parse(emit(parse(x)))) ==
#       emit(parse(x)). An emitter whose output this parser reads DIFFERENTLY
#       passes (b) and (c) and fails here.
#   (e) MIGRATION SAFETY — a bundle authoring none of the optional blocks gains
#       none of them.
#
# ── `services` (AppBundle field 7) ─────────────────────────────────────────
# The gate is keyed on what the PARSER ACCEPTS rather than on the AppBundle
# struct's field list, so a block joins it as soon as it has a parse arm: the
# probe reports a vocabulary, and leg (a) goes red naming the fields the fixture
# does not author. The mechanism finds a new block by itself, which is the
# property the file is built for.
#
# ⚠ AND THE EMPTY CASE IS STILL LOAD-BEARING. An EMPTY `services` is not an
# absent value — it is the AUTO-LIFT SIGNAL. Leg (e) therefore asserts a plain
# bundle gains no `services` block, because materializing the lifted service
# would rewrite every single-service bundle into a shape whose
# singular `name`/`spec` are ignored.
#
# Pure parse + emit. No cloud, no filesystem, no registry. Mojo 1.0.0b2 (def-only).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_deploy_bundle.parser import parse_bundle
from komira_deploy_bundle.emit import emit_bundle

# The NETWORK-REACH vocabulary (`AppSpec.network_ingress`, field 32). Imported so the round-trip assertion below compares against the
# ENUM rather than a hand-typed ordinal — a test that spelled `3` would keep
# passing through a renumbering, which is the same silent mis-stamp the
# conformer's arm-by-arm ordinal mapping refuses to risk.
from komira_rpc_bundle.deploy_model import NetworkIngress


# The field name fed to every block probe. Deliberately far (edit distance >= 6)
# from every legal field in every block, so `suggest()` finds no near-miss and the
# diagnostic takes its "(known fields: …)" arm — which is the arm that enumerates.
comptime _UNKNOWN_FIELD: String = "zzzzqqqq"


# =============================================================================
# THE FIXTURE — one authored instance of EVERY field the parser accepts.
#
# Written at the depths `emit_bundle` uses (top-level blocks at column 0, 2 spaces
# per level) so leg (b)'s (depth, name) census compares like with like.
#
# Values are deliberately DISTINCT per field: a field re-emitted with a
# neighbour's value fails leg (c). Enum + bool + repeated fields carry NON-DEFAULT
# values on purpose — the emitter skips proto3 defaults by design, so a fixture
# authoring `compute: COMPUTE_INTENT_UNSPECIFIED` would "round-trip" through an
# emitter that never learned the field.
#
# NOT semantically valid as a deploy (`validate_bundle` is never called here): it
# authors an API app with web-route rules and a public invoker. That is the point
# — this gate is about SERIALIZATION TOTALITY, and restricting it to a plausible
# app would restrict it to the fields a plausible app happens to use.
# =============================================================================
def _everything_bundle() -> String:
    return String(
        "kind: APP_KIND_API\n"
        # ★ TENANCY (AppBundle field 15) — WHOSE CLOUD ACCOUNT THIS RUNS IN.
        # Authored here because leg (a) demands every field the parser accepts:
        # a parse arm with no emitter twin is the defect this file exists for.
        #
        # CUSTOMER rather than CONTROL_PLANE on purpose: it is the value the
        # deploy path has to be able to branch on, so a fixture carrying the
        # other one would still round-trip while proving less.
        "tenancy: TENANCY_CUSTOMER\n"
        'name: "machine-under-test"\n'
        "\n"
        "build {\n"
        '  name: "svc"\n'
        '  dockerfile: "Dockerfile.svc"\n'
        '  context: "src/cmd/svc"\n'
        "  output_format: OUTPUT_FORMAT_STATIC_TARGZ\n"
        '  output: "dist/svc.tar.gz"\n'
        # ⭐ THE TWO JOB-VM BUILD-TARGET ROLES (fields 6/7). Both
        # NON-ZERO, because the emitter skips the zero of each and a zero here
        # would exercise only the silent arm. Not semantically paired with the
        # output_format above and not needed to be: `validate_bundle` is never
        # called on this fixture, and it REFUSES both by name anyway (declared,
        # not yet honoured).
        "  file_role: FILE_ROLE_POD_LOADER_BUNDLE\n"
        "  repository_role: REPOSITORY_ROLE_JOB_IMAGES\n"
        "}\n"
        "\n"
        "spec {\n"
        "  image {\n"
        '    from_build: "svc"\n'
        "  }\n"
        "  port: 8080\n"
        "  env {\n"
        '    name: "LITERAL_ARM"\n'
        '    value: "literal-value"\n'
        "  }\n"
        "  env {\n"
        '    name: "VALUE_FROM_ARM"\n'
        "    value_from: VALUE_FROM_DEPLOY_URL\n"
        "  }\n"
        "  env {\n"
        '    name: "SERVICE_REF_ARM"\n'
        "    service_ref {\n"
        '      service: "sibling-service"\n'
        "    }\n"
        "  }\n"
        "  scaling {\n"
        "    min: 1\n"
        "    max: 9\n"
        "  }\n"
        "  compute: COMPUTE_INTENT_SERVERLESS\n"
        "  datastore: DATASTORE_NEED_SERVERLESS\n"
        "  secret_bindings {\n"
        '    handle: "mailer-key"\n'
        '    capability_node: "mailer-key-cap"\n'
        "    ensure: true\n"
        # CUSTODY (deploy_model.proto `SecretCustody`, field 4) — OPERATOR, and
        # the value is chosen, not incidental. It must be NON-DEFAULT at all:
        # `emit.mojo` default-skips custody 0, so a fixture authoring
        # SECRET_CUSTODY_UNSPECIFIED would go red in leg (b) against an emitter
        # that is behaving correctly. Between the two non-zero values, OPERATOR
        # is the one whose loss the emitter's own comment names as the damage
        # this gate exists to catch — "an OPERATOR binding that re-emits without
        # custody becomes CUSTOMER, so a round-trip would quietly strip a
        # handle's ability to ever be seeded" — and it is the value that pairs
        # coherently with this binding's `ensure: true`: container provisioned
        # AND value writable.
        "    custody: SECRET_CUSTODY_OPERATOR\n"
        "  }\n"
        '  runtime_identity: "svc-runtime"\n'
        '  web_slug: "svc-web"\n'
        '  web_domain: "svc.example.test"\n'
        '  web_additional_domains: "alt.example.test"\n'
        '  web_api_path_prefixes: "/api/"\n'
        '  web_api_service_logical_id: "svc-api"\n'
        "  inbound: INBOUND_NEED_WEBHOOK\n"
        '  inbound_route_path: "/hooks/svc"\n'
        "  buckets {\n"
        '    name: "svc-cas-bucket"\n'
        '    location: "us-central1"\n'
        '    storage_class: "STANDARD"\n'
        "    uniform_bucket_level_access: true\n"
        '    public_access_prevention: "enforced"\n'
        # The object-expiry lifetime (GCS Object Lifecycle Delete-at-age). A
        # NON-DEFAULT value on purpose: `_emit_bucket` proto3-default-skips 0, so
        # authoring 0 here would prove nothing about whether emit carries it.
        "    object_expiry_days: 30\n"
        "  }\n"
        "  runtime_extra_capabilities: 7\n"
        "  web_route_rules {\n"
        '    paths: "/admin/*"\n'
        '    backend_role: "svc-api"\n'
        '    error_404_path: "/404.html"\n'
        "    error_404_code: 404\n"
        "    disposition: WEB_ROUTE_DISPOSITION_DENY\n"
        '    deny_reason: "admin is control-plane only"\n'
        "  }\n"
        '  region: "us-east1"\n'
        "  public_invoker: true\n"
        "  keep_last_n: 3\n"
        # AppSpec.network_ingress (32) — the NETWORK reach. Authored here for
        # this file's exact purpose: an emitter that dropped it would re-emit a
        # bundle whose service is PUBLIC, because the unstamped Cloud Run
        # default is `all` — a silent widening on a canonical round trip, and
        # the widening no one would look for.
        "  network_ingress: NETWORK_INGRESS_INTERNAL_AND_LOAD_BALANCER\n"
        # AppSpec.network_egress (33) — the OUTBOUND path, the sibling of
        # the reach above. Authored here for this file's exact purpose: an
        # emitter that dropped it would re-emit a bundle whose service has
        # NO VPC attachment, i.e. one that egresses over the public
        # internet and is refused at the edge by the very peer the reach
        # above makes private. All four leaves are authored because the
        # block-probe demands totality over the message's vocabulary.
        "  network_egress {\n"
        '    network: "default"\n'
        '    subnetwork: "projects/p/regions/us-east1/subnetworks/default"\n'
        '    network_tags: "cp-egress"\n'
        "    private_ranges_only: true\n"
        "  }\n"
        # ★ AppSpec.mail_transport (34) — THE MAIL SPINE: the domain this app may
        # send as and receive for, the queue accepted inbound mail lands in, and
        # the DNS records that PROVE that domain to the mail provider.
        #
        # Authored here because leg (a) demands every field the parser accepts.
        #
        # ALL FIVE LEAVES plus a full `dns_records` sub-block are authored,
        # because the two block probes below demand totality over BOTH
        # vocabularies. Three of the values are chosen, not filler:
        #   * `identity_ownership` carries EXTERNAL rather than OURS. The two
        #     answers are destructive in OPPOSITE directions — deleting an
        #     identity a third party verified stops THEIR mail, refusing to send
        #     from one we own stops OURS — so a round trip that silently
        #     re-emitted the other arm is the sharpest loss this block has, and
        #     it is invisible to a fixture authoring the ordinary arm. It is
        #     also NON-DEFAULT, which UNSPECIFIED (0) is not.
        #   * `inbound_queue_logical_id` is DISTINCT from the derived
        #     `<inbound_queue>-queue` default. An emitter that dropped it
        #     re-emits a bundle whose next apply stands a SECOND queue beside
        #     the live one instead of ADOPTING it — a clean plan, a clean apply
        #     and a queue nothing consumes.
        #   * `dns_records` is a REPEATED sub-message with its own vocabulary,
        #     so nothing outside it can see a field dropped inside it; the
        #     record is a DKIM CNAME, i.e. the record class whose loss makes
        #     mail that still sends start failing authentication silently.
        "  mail_transport {\n"
        '    domain: "mail.example.test"\n'
        "    identity_ownership: MAIL_IDENTITY_OWNERSHIP_EXTERNAL\n"
        '    inbound_queue: "svc-inbound-mail"\n'
        '    inbound_queue_logical_id: "svc-inbound-mail-node"\n'
        "    dns_records {\n"
        '      record_name: "mail._domainkey.mail.example.test"\n'
        '      record_type: "CNAME"\n'
        '      target: "dkim.provider.example.test"\n'
        "    }\n"
        "  }\n"
        # ★ AppSpec.datastore_collections (35) — THE COLLECTION SHAPES this app's
        # datastore holds, and the ONLY surface on which a key schema may be
        # stated.
        #
        # Authored here because leg (a) demands it, as for `mail_transport`
        # above: a field needs a parse arm, an emitter twin, and a fixture line.
        #
        # ⛔ THE LOSS THIS WATCHES IS THE WORST ONE IN THE FILE, AND IT IS THE
        # ONLY ONE THAT CANNOT BE UNDONE. On the arm that materializes these
        # values, a key schema is IMMUTABLE: there is no update form that
        # changes a partition key, a sort key or an attribute type, and the only
        # path between two designs is destroy-and-recreate, which loses every
        # row. So an emitter that dropped a leaf here does not merely re-emit a
        # bundle missing a line — it re-emits a bundle that names a DIFFERENT and
        # PERMANENT collection, and the operator finds out when the first read
        # comes back empty.
        #
        # ALL FIVE LEAVES plus BOTH access-path sub-blocks are authored, because
        # the block probes demand totality over each vocabulary and because the
        # two paths are the SAME message reached through DIFFERENT keys — a
        # fixture with only a primary path cannot see an emitter that drops the
        # secondary key. Three values are chosen, not filler:
        #   * `ordered_field`/`ordered_field_type` are present, so a dropped
        #     sort key is visible. A `(pk, sk)` collection and a `(pk)` one are
        #     different collections and neither can become the other.
        #   * `referenced: true` is the NON-DEFAULT arm and the ADOPT one. An
        #     emitter that dropped it re-emits a bundle that CREATES over
        #     somebody else's live data instead of adopting it.
        #   * `partition_field_type` carries a NEUTRAL token (`string`/`number`),
        #     never a vendor attribute letter — the arm maps it and RAISES on
        #     anything else.
        "  datastore_collections {\n"
        '    name: "everything_widget"\n'
        "    primary_access_path {\n"
        '      partition_field: "widget_id"\n'
        '      partition_field_type: "string"\n'
        '      ordered_field: "revision"\n'
        '      ordered_field_type: "number"\n'
        "    }\n"
        "    secondary_access_paths {\n"
        '      name: "by_owner"\n'
        '      partition_field: "owner"\n'
        '      partition_field_type: "string"\n'
        '      ordered_field: "created_at"\n'
        '      ordered_field_type: "number"\n'
        "    }\n"
        '    expiry_field: "expires_at"\n'
        "    referenced: true\n"
        "  }\n"
        # ★ AppSpec.cloud_variants (36) — THE PER-CLOUD SPEC VARIANT. Authored
        # here because leg (a) demands it, as for `mail_transport` and
        # `datastore_collections` above.
        #
        # ⛔ WHAT A DROPPED VARIANT COSTS, AND IT IS NOT "A MISSING LINE". The
        # variant is what puts the LAMBDA image on the AWS deploy of a bundle
        # whose spec-level image is a Cloud Run one. A round trip that lost it
        # re-emits a bundle that deploys the Cloud Run image to Lambda — which
        # CreateFunction accepts and which fails at the FIRST INVOKE, in
        # somebody else's account, with the bundle on disk looking correct.
        #
        # ALL FOUR MEMBERS are authored because the block probe demands totality
        # over the `CloudVariant` vocabulary, and because each is a different
        # loss: the posture (an emitter that dropped `cloud` re-emits a variant
        # no deploy can select), the image (above), the ingress (an edge
        # realized with the other cloud's inputs) and the collection shapes (a
        # key schema, which on the arm that materializes it is IMMUTABLE).
        "  cloud_variants {\n"
        "    cloud: CLOUD_AWS\n"
        '    image { from_build: "everything_lambda_image" }\n'
        "    ingress {\n"
        '      gateway_service_account: "gw-aws@p.iam.gserviceaccount.com"\n'
        '      gateway_region: "us-east-1"\n'
        '      allowed_sources: "10.0.0.0/8"\n'
        "      enable_required_services: true\n"
        "      caller_class: EDGE_CALLER_CLASS_PEER_INTERNAL\n"
        '      peer_identity_audience: "https://aws.example.test"\n'
        "    }\n"
        "    datastore_collections {\n"
        '      name: "everything_widget_aws"\n'
        "      primary_access_path {\n"
        '        partition_field: "widget_id"\n'
        '        partition_field_type: "string"\n'
        "      }\n"
        "    }\n"
        "  }\n"
        # ★ AppSpec.name_scope (37) — HOW THE SERVICE NAME RELATES TO THE BUNDLE
        # NAME. Authored here because leg (a) demands it, as for
        # `cloud_variants` above.
        #
        # ⛔ WHAT A DROPPED SCOPE COSTS. `NAME_SCOPE_REGIONAL` says the authored
        # `name` is a BASE name and the real service name is composed from the
        # deploy target (`orders-api` -> `orders-api-gcp-us-central1`). An
        # emitter that dropped it re-emits a bundle that reads as
        # `NAME_SCOPE_UNSPECIFIED` — i.e. one that composes the BARE name — and a
        # bare name may already be a running service, with a service-registry
        # row keyed on PROJECT ALONE. The round trip would therefore turn a
        # correct bundle into one whose deploy claims a running service's
        # registry row, with the file on disk looking correct.
        "  name_scope: NAME_SCOPE_REGIONAL\n"
        # ★ AppSpec.cpu (38) / AppSpec.memory (39) — THE APP'S OWN COMPUTE
        # ALLOCATION. Authored here because leg (a) DEMANDS it,
        # for the same reason `name_scope` above is.
        #
        # ⛔ WHAT A DROPPED ALLOCATION COSTS, AND IT IS THE WORST ONE IN THIS
        # FIXTURE. These two strings are the ONLY statement of how much compute a
        # served app asked for; `billable_cpu_quantity()` multiplies a usage
        # interval by the cpu one. An emitter that dropped them re-emits a bundle
        # that declares NO allocation — which composes an UNSET node field, which
        # the bill refuses — so the round trip would turn a billable app into an
        # unbillable one with the file on disk looking correct. A silent zero is
        # an un-billed customer and is byte-identical to an idle one.
        '  cpu: "1000m"\n'
        '  memory: "512Mi"\n'
        # ★★ AppSpec.health_check_path (40) — THE APP'S HEALTHCHECK ENDPOINT.
        # Authored with a DISTINCTIVE path, not `/healthz`:
        # `/healthz` is the value a bundle commonly carries in its
        # `DEPLOY_STARTUP_PROBE_PATH` env var, so a fixture using it could not
        # tell a carried declaration from a coincidence.
        #
        # ⛔ WHAT A DROPPED HEALTHCHECK COSTS. This one string is the ONLY
        # statement of what the JOB MANAGER should ask the app before calling it
        # ACTIVE. An emitter that dropped it re-emits a bundle declaring NO
        # healthcheck — which composes an UNSET node field, which is the
        # NOT_GATED policy — so the round trip silently converts a GATED app
        # into one whose resource reaches ACTIVE the moment the cloud accepts
        # the create. A Cloud Run service has a URL, and enumerates, before the
        # revision is READY and before the container has opened a socket, so the
        # file on disk would look correct while the control plane published
        # "this app is serving" for a service answering 503.
        '  health_check_path: "/internal/ready-for-traffic"\n'
        # AppSpec.secured_inbound_routes (26) — the ADDITIONAL inbound route the
        # EDGE authenticates. Authored here because this file's whole job is to
        # notice a field the parser accepts and the emitter drops: a dropped
        # secured route is a bundle that re-emits as one WITHOUT the SES route,
        # and the symptom of that is a 404 per delivered message.
        "  secured_inbound_routes {\n"
        '    route_path: "/hooks/federated"\n'
        "    policy: EDGE_AUTH_POLICY_KIND_FEDERATED_SA_JWT\n"
        '    sa_email: "caller@p.iam.gserviceaccount.com"\n'
        # NO `audience:` — the parser REFUSES that spelling by name (proto field
        # 4, reserved). See test_validate.mojo's not-authorable falsifier.
        "  }\n"
        # AppSpec.datastore_database (27) — the database this app's documents live
        # in. Authored here for this file's usual reason, and the
        # consequence of dropping it is the sharpest in the set: a bundle that
        # re-emits WITHOUT its database name is a bundle whose next deploy has no
        # database to ensure, and the value it used to carry is the one thing
        # standing between the app and a database created with zero indexes.
        '  datastore_database: "everything-db"\n'
        # AppSpec.datastore_database_ref (28; the reference-not-own concept) —
        # the database this service OPENS but does not OWN.
        #
        # Authored ALONGSIDE `datastore_database` above even though the two are
        # MUTUALLY EXCLUSIVE on a real datastore-bearing service. That is
        # deliberate and is the header's rule, not an exception to it: the pair is
        # judged by `datastore_identity.resolve_datastore_identity` — "the parser
        # stores both verbatim and judges neither" — and this file calls neither
        # that resolver nor `validate_bundle`. Restricting the fixture to a
        # semantically-legal combination is precisely the "restrict it to the
        # fields a plausible app happens to use" move the header refuses, and here
        # it would leave field 28 the one AppSpec field no emit-drop leg watches.
        '  datastore_database_ref: "borrowed-db"\n'
        # AppSpec.index_tables (29; the app declares its OWN index shapes) — so
        # the control plane need not compile an index manifest for somebody
        # else's database into its own binaries.
        #
        # THREE THINGS ARE AUTHORED THAT A ONE-INDEX FIXTURE WOULD NOT REACH, and
        # each one is a distinct emit-drop this file has to be able to see:
        #   * a DESCENDING key — `desc` default-skips on false, so an emitter that
        #     dropped the line entirely would still round-trip an all-ASCENDING
        #     index and look correct;
        #   * an ARRAY-MEMBERSHIP key — a DISTINCT Firestore field mode, not a
        #     direction. Losing it yields an ORDERED index on an array column,
        #     which the cloud CREATES, marks READY, and never uses to serve an
        #     `array-contains` query;
        #   * TWO indexes on one table, so a `break`-after-first emitter is
        #     visible.
        "  index_tables {\n"
        '    table: "everything_row"\n'
        "    indexes {\n"
        '      name: "ix_everything_owner_created"\n'
        "      fields {\n"
        '        col: "owner_id"\n'
        "      }\n"
        "      fields {\n"
        '        col: "created_at"\n'
        "        desc: true\n"
        "      }\n"
        "      scope: SCOPE_COLLECTION\n"
        "    }\n"
        "    indexes {\n"
        '      name: "ix_everything_owner_labels"\n'
        "      fields {\n"
        '        col: "labels"\n'
        "        array_contains: true\n"
        "      }\n"
        "      scope: SCOPE_COLLECTION_GROUP\n"
        "    }\n"
        "  }\n"
        # AppSpec.ingress (30) — the ingress REALIZATION inputs.
        # ALL of them are authored; they are the ingress provisioning inputs a
        # bundle states. `enable_required_services` is authored TRUE because
        # `emit.mojo` default-skips a false bool — a fixture authoring false
        # would leave the field the one nothing in leg (b) watches.
        # ⛔ SIX, not four: `caller_class` + `peer_identity_audience` are the
        # peer-only edge's intent-tier answer, and need an emitter twin like
        # every other parse arm.
        #
        # ⚠ THIS FIXTURE IS A PARSE/EMIT TOTALITY FIXTURE AND IS DELIBERATELY NOT
        # A COMPOSE-VALID BUNDLE. `caller_class` on an `INBOUND_NEED_WEBHOOK`
        # spec is a compose-pass REFUSAL (the webhook arm reads neither
        # field, so honouring it would compose a pass-through edge while the
        # bundle says peer-only). The refusal is about COMPOSITION; the emitter
        # must still round-trip every field the parser accepts, or a bundle that
        # IS compose-valid loses it silently on the way through.
        "  ingress {\n"
        '    gateway_service_account: "edge-gw@p.iam.gserviceaccount.com"\n'
        '    gateway_region: "us-central1"\n'
        '    allowed_sources: "203.0.113.0/24"\n'
        "    enable_required_services: true\n"
        "    caller_class: EDGE_CALLER_CLASS_PEER_INTERNAL\n"
        '    peer_identity_audience: "svc-fixture"\n'
        "  }\n"
        # ★ AppSpec.parameters (field 31) — the typed managed-app input contract.
        #   FIVE blocks because `source` is a ONEOF: one block can author exactly
        #   one arm, so a single block would leave four arms unwatched — which is
        #   precisely the blind spot that lost `service_ref` on `BundleEnvVar`.
        #   The first block authors every NON-oneof field, `min`/`max` included
        #   (emit gates those on has_min/has_max, so a bound of 0 would vanish).
        "  parameters {\n"
        '    name: "MAX_BATCH"\n'
        "    type: PARAM_TYPE_INT\n"
        "    required: true\n"
        '    default: "1000"\n'
        '    description: "Rows per flush."\n'
        '    flag: "max-batch"\n'
        "    min: 1\n"
        "    max: 5000000\n"
        "  }\n"
        "  parameters {\n"
        '    name: "MAIL_MODE"\n'
        "    type: PARAM_TYPE_ENUM\n"
        '    allowed_values: "relay"\n'
        '    allowed_values: "full"\n'
        '    value: "relay"\n'
        "  }\n"
        "  parameters {\n"
        '    name: "RELAY_TOKEN"\n'
        "    type: PARAM_TYPE_SECRET\n"
        '    secret_ref: "secret://orders-relay-token"\n'
        "  }\n"
        "  parameters {\n"
        '    name: "LOCAL_DOMAINS"\n'
        "    type: PARAM_TYPE_STRING\n"
        '    regex: "^[a-z0-9.-]+$"\n'
        "    marker: PARAM_MARKER_ORG_MAIL_DOMAIN\n"
        "  }\n"
        "  parameters {\n"
        '    name: "SELF_URL"\n'
        "    type: PARAM_TYPE_STRING\n"
        "    value_from: VALUE_FROM_DEPLOY_URL\n"
        "  }\n"
        "  parameters {\n"
        '    name: "PEER_URL"\n'
        "    type: PARAM_TYPE_STRING\n"
        "    service_ref {\n"
        '      service: "worker"\n'
        "    }\n"
        "  }\n"
        # ⭐ THE SIXTH `source` ARM, `from_build` (field 18).
        # Its OWN parameter because the arms are a oneof.
        "  parameters {\n"
        '    name: "BOOT_BUNDLE_URL"\n'
        "    type: PARAM_TYPE_STRING\n"
        '    from_build: "svc"\n'
        "  }\n"
        "}\n"
        "\n"
        "waves {\n"
        '  env: "gamma"\n'
        # ★ Wave.parameter_override (field 5) — the per-ENV parameter BINDING.
        #   Authored so leg (b) watches the WAVE arm too: `env_override` and
        #   `parameter_override` are separate repeated fields, and an emitter that
        #   emitted one and dropped the other would otherwise go unseen.
        "  parameter_override {\n"
        '    name: "LOCAL_DOMAINS"\n'
        "    type: PARAM_TYPE_STRING\n"
        '    value: "gamma.example.com"\n'
        "  }\n"
        "  validate {\n"
        '    name: "up"\n'
        "    http_check {\n"
        '      path: "/healthz"\n'
        "      expect_status: 200\n"
        # ★ `max_latency_ms` (HttpCheck field 3) — the LATENCY
        #   BUDGET. Authored here because this file's whole job is to prove the
        #   emitter drops nothing, and the emitter writes this line ONLY when
        #   the value is non-zero (zero == UNAUTHORED == latency not checked,
        #   the contract that keeps a bundle without it byte-identical). A
        #   zero here would exercise the SILENT arm and see nothing.
        "      max_latency_ms: 1500\n"
        "    }\n"
        "  }\n"
        "  validate {\n"
        '    name: "integ"\n'
        "    run_container {\n"
        "      image {\n"
        '        digest: "sha256:deadbeef"\n'
        "      }\n"
        "      gate_on: GATE_ON_EXIT_CODE\n"
        "      env {\n"
        '        name: "TARGET_URL"\n'
        "        value_from: VALUE_FROM_DEPLOY_URL\n"
        "      }\n"
        # `RunContainer.reads_secret` — the step DECLARES the secret
        # it reads. Authored here because this file cannot see whether emit drops
        # a field the fixture never states. Repeated, so a single-element emit
        # cannot pass for a list one.
        '      reads_secret: "orders-managed-app-signing-seed"\n'
        '      reads_secret: "orders-relay-token"\n'
        # ★ `RunContainer.args` (field 5) — the ARGV the validator's
        # entrypoint receives, so the same binary can be pointed at any endpoint.
        # `repeated AppParameter`, i.e. a BLOCK per entry with `AppParameter`'s OWN
        # 15-field vocabulary — and note what that means for THIS file: the
        # AppParameter probe below fires under `spec.parameters` and
        # `waves.parameter_override`, so a field dropped by the emitter ONLY on this
        # third parent would be invisible without an entry here. Authored TWICE, so
        # a single-element emit cannot pass for a list one, and with DIFFERENT
        # source arms (a typed wave-output ref and a literal) so neither arm can
        # hide the other's loss.
        "      args {\n"
        '        name: "TARGET_URL"\n'
        "        type: PARAM_TYPE_STRING\n"
        "        required: true\n"
        '        description: "the endpoint under test"\n'
        '        flag: "target-url"\n'
        "        value_from: VALUE_FROM_DEPLOY_URL\n"
        "      }\n"
        "      args {\n"
        '        name: "FIXTURE_ID"\n'
        "        type: PARAM_TYPE_STRING\n"
        '        default: "smoke"\n'
        '        value: "golden"\n'
        "      }\n"
        # ★ `RunContainer.runtime_identity` (field 6) — the SA the step's JOB runs
        # as. A bare scalar, so the emitter's default-skip is the only thing
        # between an authored value and silent loss.
        '      runtime_identity: "gate-runner@example.iam.gserviceaccount.com"\n'
        # ★ `RunContainer.vpc_egress` (field 7) — the DIRECT VPC EGRESS
        # attachment, with its OWN 4-field vocabulary, so this is the only parent
        # under which those four names can be seen to survive.
        #
        # ⛔ AND IT IS THE FIELD WHOSE LOSS WOULD BE HARDEST TO NOTICE. Every other
        # dropped field shows up as a container missing something it was told. Drop
        # this one and the deploy still runs, the job still starts, the gate still
        # reports — it just reports over the PUBLIC INTERNET instead of the VPC,
        # which for a private-ingress target is an unattributable 404 and for a
        # public one is a PASS that proves nothing about the path anybody intended.
        #
        # `private_ranges_only: true` is authored deliberately: `false` is the proto
        # default and the emitter skips it, so the `false` arm would leave leg (b)
        # unable to see the field name at all.
        "      vpc_egress {\n"
        '        network: "default"\n'
        '        subnetwork: "default"\n'
        '        network_tags: "validate-egress"\n'
        '        network_tags: "gamma"\n'
        "        private_ranges_only: true\n"
        "      }\n"
        # ★ `RunContainer.reads_telemetry` (field 8) — the read-only
        # observability planes this step's container queries for itself. Each line
        # composes ONE project-scoped read grant for the identity the job runs as,
        # so a dropped line is a validator that reports `precond_…_authorized ->
        # 403` naming a role the bundle believes it asked for — the failure the
        # field exists to end, re-created by an emitter bug.
        #
        # BOTH values are authored, which is also the only way to state a REPEATED
        # enum here: `validate_bundle` refuses a duplicate (two entries compose two
        # nodes binding one triple under read-modify-write SetIamPolicy), so the
        # list cannot be lengthened by repeating one value. Two DISTINCT values
        # still prove a single-element emit cannot pass for a list one.
        "      reads_telemetry: TELEMETRY_READ_LOGS\n"
        "      reads_telemetry: TELEMETRY_READ_METRICS\n"
        # ⭐ The job-VM observe read (value 3) — a THIRD distinct value,
        # so an emitter that re-emitted only the first two is red at (c).
        "      reads_telemetry: TELEMETRY_READ_JOB_VM_STATE\n"
        # ★ `RunContainer.test_role` (field 9) — the EPHEMERAL KOMIRA
        # CALLER IDENTITIES this step presents to the app under test. A dropped
        # block is a validator that is never handed the address of its own signing
        # key and therefore self-mints NOTHING — a green deploy whose cross-tenant
        # assertion silently stopped having a caller.
        #
        # TWO roles, in TWO orgs, with DISJOINT flags, because that is the shape
        # the first real consumer needs and it is the only way to state several
        # properties at once: the LIST is a list (a single-element emit cannot
        # pass for it), each role's own nine fields survive, and AUTHORED ORDER
        # is preserved (`_emit_test_role` must not sort — the argv render walks
        # this list in order).
        #
        # ★ `granted_on_flag` (field 9) IS ON ROLE A ONLY, AND THAT ASYMMETRY
        # IS THE POINT TWICE OVER. It is the authoring shape a shared target
        # forces — no flag may be claimed twice across a step's roles — AND it
        # makes the fixture state the default-skip property for a NEW field: role
        # b must re-emit WITHOUT the line, so an emitter that wrote it
        # unconditionally is red here rather than in a bundle nobody re-emits.
        #
        # ⚠ THE VALUES ARE NOT SEMANTICALLY VALID HERE and do not need to be:
        # this bundle is `tenancy: TENANCY_CUSTOMER` and `validate_bundle` is
        # never called on it (see this file's header). The refusals those values
        # would trip are asserted in `test_validate.mojo`, over bundles built for
        # that purpose.
        "      test_role {\n"
        '        name: "caller-a"\n'
        '        org_id: "11111111-1111-7111-8111-11111111111a"\n'
        '        grants_on_service: "relay"\n'
        "        level: TEST_ROLE_LEVEL_READ\n"
        '        deployment_id_flag: "caller-a-deployment"\n'
        '        identity_secret_flag: "caller-a-secret"\n'
        '        org_id_flag: "caller-a-org"\n'
        '        issuer_flag: "caller-a-issuer"\n'
        '        granted_on_flag: "caller-target"\n'
        "      }\n"
        "      test_role {\n"
        '        name: "caller-b"\n'
        '        org_id: "11111111-1111-7111-8111-11111111111b"\n'
        '        grants_on_service: "relay"\n'
        "        level: TEST_ROLE_LEVEL_WRITE\n"
        '        deployment_id_flag: "caller-b-deployment"\n'
        '        identity_secret_flag: "caller-b-secret"\n'
        '        org_id_flag: "caller-b-org"\n'
        '        issuer_flag: "caller-b-issuer"\n'
        "      }\n"
        # ⭐ `RunContainer.own_identity` (field 10) — the SA
        # account id this step OWNS. A bare scalar; the emitter's default-skip is
        # the only thing between an authored value and silent loss.
        '      own_identity: "jm-vm-validator"\n'
        "    }\n"
        '    depends_on: "up"\n'
        '    excluded_because: "the integ image is not built yet"\n'
        "  }\n"
        # The THIRD `ValidateStep.check` arm — EXECUTE a declared
        # job and gate on its exit code. It is its OWN step and not a field on the
        # `integ` step above because the three arms are a oneof: a fixture that
        # tried to author two arms on one step would not parse, and the emitter
        # would then never be asked about this arm at all.
        "  validate {\n"
        '    name: "relay-gate"\n'
        "    execute_job {\n"
        '      job: "relay-e2e"\n'
        "      gate_on: GATE_ON_EXIT_CODE\n"
        "    }\n"
        "  }\n"
        "  api_edge_enabled: true\n"
        # ⭐ `Wave.api_edge_services` (field 9) — TWO values,
        # so a single-element emit cannot pass for a list one. (It is exclusive
        # with `api_edge_enabled` in the design; validate is never called here.)
        '  api_edge_services: "orders-api-gcp-us-central1"\n'
        '  api_edge_services: "orders-email"\n'
        "  env_override {\n"
        '    name: "LITERAL_ARM"\n'
        '    value: "gamma-override"\n'
        "  }\n"
        # ★ THE TWO PEER-EDGE WAVE FIELDS (6, 7). This wave is
        # a non-production env, which is where authoring the developer principal
        # is legal.
        '  peer_identity_issuer: "https://cp-fixture.uc.gateway.dev"\n'
        '  developer_access_principal: "dev@p.iam.gserviceaccount.com"\n'
        # ★ `Wave.web_override` (field 8) — the PER-WAVE front-door TOPOLOGY, and
        # the field that lets ONE bundle carry two environments' front doors.
        #
        # ⛔ IT IS ITS OWN MESSAGE WITH ITS OWN SIX-FIELD VOCABULARY, so no
        # pre-existing probe under `spec` can see a field dropped INSIDE it — the
        # same argument that brought `vpc_egress` and `test_role` here.
        # `WebRouteRule` is REUSED from `spec.web_route_rules`, but the emitter
        # reaches it through a DIFFERENT parent, and a helper that emitted the
        # rule list only under `spec` would pass every pre-existing leg here.
        #
        # AUTHORED SO EACH LEG HAS SOMETHING TO SEE:
        #   * TWO `web_additional_domains` and TWO `web_api_path_prefixes`, so a
        #     single-element emit cannot pass for a list one;
        #   * TWO `web_route_rules`, one ROUTE and one DENY — the DENY arm is the
        #     one whose loss is silent and expensive (a
        #     `WEB_ROUTE_DISPOSITION_DENY` is a security containment), and
        #     `deny_reason` rides with it because compose REFUSES an unexplained
        #     deny, so an emitter that dropped the reason would emit a document
        #     that no longer composes;
        #   * `web_api_service_logical_id`.
        #
        # ⚠ THE VALUES ARE DELIBERATELY NOT A REAL FRONT DOOR. This fixture is
        # `tenancy: TENANCY_CUSTOMER` and `validate_bundle` is never called on it
        # (see this file's header), so the TOTAL-override refusals — spec and
        # override may not BOTH author topology — are asserted in
        # `test_validate.mojo`, over bundles built for that purpose.
        "  web_override {\n"
        '    web_slug: "fixture-gamma"\n'
        '    web_domain: "gamma.fixture.example"\n'
        '    web_additional_domains: "gamma-alt.fixture.example"\n'
        '    web_additional_domains: "gamma-legacy.fixture.example"\n'
        '    web_api_path_prefixes: "/api"\n'
        '    web_api_path_prefixes: "/v1"\n'
        '    web_api_service_logical_id: "orders-api-svc"\n'
        "    web_route_rules {\n"
        '      paths: "/orgs"\n'
        '      paths: "/orgs/*"\n'
        '      backend_role: "api"\n'
        "    }\n"
        "    web_route_rules {\n"
        '      paths: "/crm/*"\n'
        "      disposition: WEB_ROUTE_DISPOSITION_DENY\n"
        '      deny_reason: "an exposed admin path"\n'
        "    }\n"
        "  }\n"
        "}\n"
        "\n"
        "triggers {\n"
        '  name: "external-release"\n'
        "  git_push {\n"
        "    source_kind: SOURCE_KIND_GIT_EXTERNAL\n"
        '    repo_ref: "example/orders-fixture"\n'
        '    ref: "release-branch"\n'
        "  }\n"
        "}\n"
        "\n"
        "triggers {\n"
        '  name: "weekly-merge-from-live"\n'
        "  schedule {\n"
        '    cron: "0 6 * * 1"\n'
        '    timezone: "America/Chicago"\n'
        "  }\n"
        "}\n"
        "\n"
        "triggers {\n"
        '  name: "upstream-widget"\n'
        "  package_published {\n"
        "    registry_kind: REGISTRY_KIND_GITHUB_PACKAGES\n"
        '    package_ref: "acme/widget"\n'
        '    version_range: "^2.0.0"\n'
        "  }\n"
        "}\n"
        "\n"
        # ★ AppBundle.services (field 7) — N NAMED SERVICES IN ONE BUNDLE.
        #
        # Covered like every other block: `_parse_service_spec` authors it, so
        # leg (a) demands the block be authored here.
        #
        # TWO services, and the pair is chosen rather than incidental: an API
        # service that REFERENCES a sibling, plus a SHARED_INFRASTRUCTURE service
        # that owns a database and serves nothing. That is the shape a
        # consolidated control-plane bundle authors, and it is the shape that proves the
        # emitter is not quietly collapsing per-service `kind` — a one-service
        # fixture, or two services of the same kind, would round-trip through an
        # emitter that hard-coded APP_KIND_API and never say so.
        #
        # ⚠ `kind` ON THE SECOND SERVICE IS THE ASSERTION, NOT DECORATION. Both
        # services carry a NON-DEFAULT kind so leg (b) can see the field at all;
        # they carry DIFFERENT kinds so leg (c) can see whether the SECOND one's
        # value survived, which is the failure an emitter that emitted
        # `services[0].kind` twice would otherwise pass.
        "services {\n"
        '  name: "front-door"\n'
        "  kind: APP_KIND_API\n"
        "  spec {\n"
        "    image {\n"
        '      digest: "sha256:5e12ed"\n'
        "    }\n"
        "    port: 9443\n"
        "    env {\n"
        '      name: "OWNER_URL"\n'
        "      service_ref {\n"
        '        service: "resource-owner"\n'
        "      }\n"
        "    }\n"
        "    compute: COMPUTE_INTENT_SERVERLESS\n"
        "  }\n"
        "}\n"
        "\n"
        "services {\n"
        '  name: "resource-owner"\n'
        "  kind: APP_KIND_SHARED_INFRASTRUCTURE\n"
        "  spec {\n"
        "    port: 0\n"
        "    datastore: DATASTORE_NEED_SERVERLESS\n"
        '    datastore_database: "owned-by-the-service"\n'
        "  }\n"
        "}\n"
        "\n"
        "validation_sets {\n"
        '  name: "smoke"\n'
        # ⛔ The ENV RESTRICTION. Authored here because
        # leg (a) is a TOTALITY gate: every field name the parser accepts must
        # appear in this fixture, so a new `ValidationSet` field that the emitter
        # forgets goes red on leg (b) instead of vanishing on a round trip. The
        # ALLOWLIST also has to cover the `envs: "gamma"` pipeline step below, or
        # `validate_bundle` refuses the fixture outright.
        "  env_policy: VALIDATION_SET_ENV_POLICY_ENV_ALLOWLIST\n"
        '  envs: "gamma"\n'
        "  steps {\n"
        '    name: "ping"\n'
        "    http_check {\n"
        '      path: "/ping"\n'
        "      expect_status: 204\n"
        "    }\n"
        "  }\n"
        "}\n"
        "\n"
        "pipeline {\n"
        "  steps {\n"
        "    step_kind: STEP_KIND_DEPLOY_AND_VALIDATE\n"
        '    envs: "gamma"\n'
        '    validation_set_refs: "smoke"\n'
        '    matrix_ref: "desktop-support"\n'
        "  }\n"
        "}\n"
        "\n"
        "matrices {\n"
        '  name: "desktop-support"\n'
        "  cell {\n"
        '    name: "mac-arm64"\n'
        '    os: "macos"\n'
        '    arch: "arm64"\n'
        '    artifact_kind: "dmg"\n'
        '    os_version_min: "14.0"\n'
        '    os_version_max: "15.9"\n'
        '    from_build: "svc"\n'
        "  }\n"
        "  cell {\n"
        '    name: "web-chromium"\n'
        '    browser: "chromium"\n'
        "  }\n"
        "}\n"
        "\n"
        "outputs {\n"
        '  name: "endpoint"\n'
        '  from_served: "machine-under-test"\n'
        "}\n"
        "\n"
        # AppBundle.jobs (12) — a run-to-completion container the
        # deploy SHIPS. Every field is authored, and `max_retries: 0` is the one
        # that matters most: it is proto3-optional precisely because an authored
        # zero ("a failure is a verdict, do not retry") equals the proto3 default,
        # so an emitter that value-skipped it would drop the field while looking
        # correct — and the job would come back with platform-default retries, i.e.
        # a gate that passes on its second attempt.
        "jobs {\n"
        '  name: "relay-e2e"\n'
        "  image {\n"
        '    digest: "sha256:cafebabe"\n'
        "  }\n"
        "  env {\n"
        '    name: "MAIL_URL"\n'
        "    value_from: VALUE_FROM_DEPLOY_URL\n"
        "  }\n"
        "  secret_bindings {\n"
        '    handle: "signing-seed"\n'
        '    capability_node: "signing-seed-cap"\n'
        "  }\n"
        '  runtime_identity: "job-runner"\n'
        "  max_retries: 0\n"
        "  task_timeout_seconds: 600\n"
        '  region: "us-south1"\n'
        # ★ `JobSpec.args` (field 9) — the job's ARGV. It exists because a
        # binary's configuration is command-line flags, a job's included:
        # without this field a bundle author could configure a job ONLY by
        # environment variable. TWO entries, because a single-element
        # list cannot see an emitter that drops ORDER, and an emitter that wrote
        # one `args:` line for a two-element list would still satisfy the census.
        '  args: "--exit-code=0"\n'
        '  args: "--emit-marker=MC_JOB_PROBE_RAN"\n'
        "}\n"
        "\n"
        # AppBundle.crons (13) — a scheduled call into a SIBLING
        # service. No `uri` and no `audience` are authored because there are no
        # such fields: the parser refuses both BY NAME, and the url + OIDC
        # audience are derived from the target's observed address at apply time.
        "crons {\n"
        '  name: "reconcile-backstop"\n'
        '  cron: "*/2 * * * *"\n'
        '  timezone: "UTC"\n'
        "  target {\n"
        '    service: "machine-under-test"\n'
        "  }\n"
        '  path: "/reconcile"\n'
        '  http_method: "POST"\n'
        '  invoker_identity: "scheduler@p.iam.gserviceaccount.com"\n'
        "  attempt_deadline_seconds: 300\n"
        "}\n"
        "\n"
        # AppBundle.ephemeral (14) — the bundle's PERMISSION to be
        # deployed and destroyed as a throwaway run. Dropping
        # `keep_overridden_because` on a round trip would produce a bundle that
        # still claims the permission while carrying no justification for it, and
        # `validate` would then refuse a document the emitter itself wrote.
        "ephemeral {\n"
        '  keep_overridden_because: "a conformance run owns every byte it creates"\n'
        "  max_lifetime_seconds: 3600\n"
        "}\n"
    )


# =============================================================================
# The BLOCK PROBES — how to REACH each block, one per `known`-field arm in
# parser.mojo. This table names PATHS, never field sets: the field set is what
# the parser reports back. A block added to the parser without a probe here is
# invisible to leg (a), which is the one residual this gate carries and is
# stated rather than hidden.
# =============================================================================
def _block_probes() -> List[String]:
    var p = List[String]()
    p.append(String("") + _UNKNOWN_FIELD + String(": \"x\"\n"))  # AppBundle
    p.append(String("build { ") + _UNKNOWN_FIELD + String(": \"x\" }\n"))
    p.append(String("spec { ") + _UNKNOWN_FIELD + String(": \"x\" }\n"))
    p.append(
        String("spec { image { ") + _UNKNOWN_FIELD + String(": \"x\" } }\n")
    )
    p.append(String("spec { env { ") + _UNKNOWN_FIELD + String(": \"x\" } }\n"))
    p.append(
        String("spec { env { service_ref { ")
        + _UNKNOWN_FIELD
        + String(": \"x\" } } }\n")
    )
    p.append(
        String("spec { scaling { ") + _UNKNOWN_FIELD + String(": \"x\" } }\n")
    )
    p.append(
        String("spec { secret_bindings { ")
        + _UNKNOWN_FIELD
        + String(": \"x\" } }\n")
    )
    p.append(
        String("spec { buckets { ") + _UNKNOWN_FIELD + String(": \"x\" } }\n")
    )
    p.append(
        String("spec { web_route_rules { ")
        + _UNKNOWN_FIELD
        + String(": \"x\" } }\n")
    )
    p.append(String("waves { ") + _UNKNOWN_FIELD + String(": \"x\" }\n"))
    p.append(
        String("waves { validate { ") + _UNKNOWN_FIELD + String(": \"x\" } }\n")
    )
    p.append(
        String("waves { validate { http_check { ")
        + _UNKNOWN_FIELD
        + String(": \"x\" } } }\n")
    )
    p.append(
        String("waves { validate { run_container { ")
        + _UNKNOWN_FIELD
        + String(": \"x\" } } }\n")
    )
    # ── The five blocks the four capabilities added. Each is
    #    its OWN message with its own vocabulary, so no existing probe can see a
    #    field dropped inside it. ────────────────────────────────────────────
    p.append(
        String("spec { ingress { ") + _UNKNOWN_FIELD + String(": \"x\" } }\n")
    )
    # ★ `spec.network_egress` (field 33) — the SERVED SERVICE'S Direct VPC egress
    #   attachment. `ValidateVpcEgress` is its OWN message with its own 4-field
    #   vocabulary, so no pre-existing probe can see a field dropped inside it.
    #   It is REUSED at two scopes (`RunContainer.vpc_egress` is the same message
    #   under a different key), and the emitter takes the block key as a
    #   PARAMETER — so this probe also guards the key-parameterisation: an
    #   emitter that hardcoded `vpc_egress {` would re-emit this service block
    #   under a key the AppSpec parser does not accept.
    p.append(
        String("spec { network_egress { ")
        + _UNKNOWN_FIELD
        + String(": \"x\" } }\n")
    )
    # ★ `spec.mail_transport` (field 34) — the MAIL SPINE. TWO probes, because
    #   there are TWO messages: `MailTransportSpec` (domain / ownership / queue /
    #   queue logical id / records) and `MailTransportDnsRecord` (name / type /
    #   target), each with its own vocabulary and its own `known fields` arm in
    #   parser.mojo. One probe would report only the outer five and could not see
    #   a field dropped INSIDE a record — the exact blind spot that lost
    #   `service_ref` on `BundleEnvVar`, and that the three `TriggerSource.on`
    #   arm probes above exist to refuse. A dropped `record_type` re-emits a DNS
    #   record whose type is empty, which the conformer refuses BY NAME — so the
    #   round trip turns a deployable bundle into one that is refused at apply.
    p.append(
        String("spec { mail_transport { ")
        + _UNKNOWN_FIELD
        + String(": \"x\" } }\n")
    )
    p.append(
        String("spec { mail_transport { dns_records { ")
        + _UNKNOWN_FIELD
        + String(": \"x\" } } }\n")
    )
    # ★ The two AppParameter blocks. `AppParameter` is its OWN
    #   message with its own 15-field vocabulary, so no pre-existing probe can see
    #   a field dropped inside it — and it appears under TWO different parents
    #   (`spec.parameters` and `waves.parameter_override`), which are separate
    #   repeated fields sharing one emitter. Both are probed.
    p.append(
        String("spec { parameters { ") + _UNKNOWN_FIELD + String(": \"x\" } }\n")
    )
    p.append(
        String("waves { parameter_override { ")
        + _UNKNOWN_FIELD
        + String(": \"x\" } }\n")
    )
    p.append(String("jobs { ") + _UNKNOWN_FIELD + String(": \"x\" }\n"))
    p.append(
        String("waves { validate { execute_job { ")
        + _UNKNOWN_FIELD
        + String(": \"x\" } } }\n")
    )
    p.append(String("crons { ") + _UNKNOWN_FIELD + String(": \"x\" }\n"))
    p.append(String("ephemeral { ") + _UNKNOWN_FIELD + String(": \"x\" }\n"))
    p.append(String("triggers { ") + _UNKNOWN_FIELD + String(": \"x\" }\n"))
    # The three `TriggerSource.on` ARM blocks. Each is its own message with its own
    # vocabulary, so the `triggers { … }` probe above reports only `name` + the
    # three arm names and CANNOT see whether emit drops a field INSIDE an arm.
    # Without these three probes the payload oneof would be exactly the kind of
    # blind spot this file exists to refuse.
    p.append(
        String("triggers { git_push { ")
        + _UNKNOWN_FIELD
        + String(": \"x\" } }\n")
    )
    p.append(
        String("triggers { schedule { ")
        + _UNKNOWN_FIELD
        + String(": \"x\" } }\n")
    )
    p.append(
        String("triggers { package_published { ")
        + _UNKNOWN_FIELD
        + String(": \"x\" } }\n")
    )
    p.append(
        String("validation_sets { ") + _UNKNOWN_FIELD + String(": \"x\" }\n")
    )
    p.append(String("pipeline { ") + _UNKNOWN_FIELD + String(": \"x\" }\n"))
    p.append(
        String("pipeline { steps { ") + _UNKNOWN_FIELD + String(": \"x\" } }\n")
    )
    p.append(String("matrices { ") + _UNKNOWN_FIELD + String(": \"x\" }\n"))
    p.append(
        String("matrices { cell { ") + _UNKNOWN_FIELD + String(": \"x\" } }\n")
    )
    p.append(String("outputs { ") + _UNKNOWN_FIELD + String(": \"x\" }\n"))
    # ★ `services { … }` (AppBundle field 7) — the MULTI-SERVICE authoring block.
    # ONE probe, not two: its `spec` sub-block REUSES `_parse_app_spec` verbatim,
    # so `spec { … }`'s existing probe already reports that vocabulary and a second
    # probe would report the same list from a second path. The reuse is exactly why
    # this is one arm — a parallel per-service AppSpec grammar is what would need
    # its own probe, and would be the drift this file exists to refuse.
    p.append(String("services { ") + _UNKNOWN_FIELD + String(": \"x\" }\n"))
    return p^


def _known_fields_of(probe: String) raises -> List[String]:
    """The field names the PARSER ITSELF reports as legal for the block `probe`
    reaches, read out of its unknown-field diagnostic.

    Fail-loud on every way this could silently return an empty set: a probe that
    parses clean, or an error without the enumerating arm, RAISES — an empty
    vocabulary would make leg (a) vacuously green, which is the failure shape this
    whole file exists to refuse."""
    var msg = String("")
    try:
        _ = parse_bundle(probe)
    except e:
        msg = String(e)
    if msg.byte_length() == 0:
        raise Error(
            String("the block probe parsed CLEAN, so it reported no vocabulary: ")
            + probe
        )
    var marker = String("(known fields: ")
    var at = msg.find(marker)
    if at < 0:
        raise Error(
            String(
                "the parser's diagnostic did not take its enumerating arm (it"
                " offered a 'did you mean' suggestion instead, so `"
            )
            + _UNKNOWN_FIELD
            + String("` is no longer far enough from every legal field): ")
            + msg
        )
    var start = at + marker.byte_length()
    var end = msg.rfind(String(")"))
    if end <= start:
        raise Error(String("malformed known-fields diagnostic: ") + msg)
    var out = List[String]()
    for part in String(msg[byte=start:end]).split(String(", ")):
        var f = String(String(part).strip())
        if f.byte_length() > 0:
            out.append(f^)
    if len(out) == 0:
        raise Error(String("the parser reported ZERO known fields for: ") + probe)
    return out^


def _census(text: String) -> List[String]:
    """Every `<depth>:<field>` pair in a textproto document, deduplicated.

    DEPTH IS PART OF THE KEY on purpose: a `name` re-emitted one nesting level up
    is not the same document, and a depth-blind census would call it equal. Depth
    is `leading spaces / 2` (both the fixture and `emit_bundle` are 2-space
    indented). A line's field is the text before its `:` or its ` {`."""
    var out = List[String]()
    for line in text.split(String("\n")):
        var s = String(line)
        if s.byte_length() == 0:
            continue
        var lead = 0
        var b = s.as_bytes()
        while lead < len(b) and b[lead] == UInt8(ord(" ")):
            lead += 1
        var body = String(s[byte=lead:])
        if body.byte_length() == 0 or body.startswith(String("}")):
            continue
        var colon = body.find(String(":"))
        var brace = body.find(String(" {"))
        var cut = -1
        if colon >= 0 and (brace < 0 or colon < brace):
            cut = colon
        elif brace >= 0:
            cut = brace
        if cut <= 0:
            continue
        var key = String(lead // 2) + String(":") + String(body[byte=0:cut])
        var seen = False
        for ref k in out:
            if k == key:
                seen = True
        if not seen:
            out.append(key^)
    return out^


def _has(xs: List[String], needle: String) -> Bool:
    for ref x in xs:
        if x == needle:
            return True
    return False


def _names_only(census: List[String]) -> List[String]:
    var out = List[String]()
    for ref c in census:
        var at = c.find(String(":"))
        var n = String(c[byte = at + 1 :])
        if not _has(out, n):
            out.append(n^)
    return out^


# =============================================================================
# (a) THE FIXTURE IS TOTAL over every vocabulary the parser reports.
# =============================================================================
def test_fixture_authors_every_field_the_parser_accepts() raises:
    var authored = _names_only(_census(_everything_bundle()))
    var probes = _block_probes()
    # One probe per known-field arm in parser.mojo, including spec.ingress, jobs,
    # waves.validate.execute_job, crons, ephemeral, the AppParameter blocks
    # (spec.parameters, waves.parameter_override), `services`, and the mail
    # spine's two messages (spec.mail_transport and its dns_records).
    assert_equal(len(probes), 35, "one probe per known-field arm in parser.mojo")
    var checked = 0
    for ref probe in probes:
        for ref f in _known_fields_of(probe):
            checked += 1
            assert_true(
                _has(authored, f),
                String("_everything_bundle() does not author the field '")
                + f
                + String("', which the parser ACCEPTS (probe: ")
                + String(String(probe).strip())
                + String(
                    "). Author it — otherwise this file cannot see whether"
                    " emit_bundle drops it, which is how eight fields were lost."
                ),
            )
    assert_true(
        checked >= 70,
        String("the probes reported a real vocabulary (got ")
        + String(checked)
        + String(" field slots across 21 blocks)"),
    )
    print("  test_fixture_authors_every_field_the_parser_accepts: PASS")


# =============================================================================
# (b) NOTHING IS DROPPED — every authored (depth, field) survives the emit.
#
# ⚠ EXPECTED RED BEFORE THE FIX, one line per dropped field, starting with
#    `emit_bundle dropped 'service_ref' (depth 2)`.
# =============================================================================
def test_emit_drops_no_authored_field() raises:
    var emitted = _census(emit_bundle(parse_bundle(_everything_bundle())))
    for ref key in _census(_everything_bundle()):
        var at = key.find(String(":"))
        assert_true(
            _has(emitted, key),
            String("emit_bundle dropped '")
            + String(key[byte = at + 1 :])
            + String("' (depth ")
            + String(key[byte=0:at])
            + String(
                ") — an authored field that parses and then VANISHES on any"
                " parse->emit write-back. Emit it in proto field-number order."
            ),
        )
    print("  test_emit_drops_no_authored_field: PASS")


# =============================================================================
# (c) THE CONTENT SURVIVES — field by field, against the authored literals.
#     This is the leg that refuses an EMPTY `triggers {}` / `matrices {}`.
# =============================================================================
def test_dropped_field_content_survives_the_round_trip() raises:
    var b2 = parse_bundle(emit_bundle(parse_bundle(_everything_bundle())))

    # --- AppBundle.tenancy (field 15) — the value, not just the word ----------
    #
    # ⚠ THIS IS THE LEG THAT MATTERS FOR AN ENUM, and it is why (b) alone is not
    # enough. Leg (b) is satisfied by an emitter that writes the WORD `tenancy:`
    # with the proto3 zero value beside it — and `TENANCY_UNSPECIFIED` is
    # precisely the reading that means "this bundle declared nothing". An emitter
    # that degraded CUSTOMER to UNSPECIFIED would pass (b), pass the fixpoint leg
    # (d), and hand the deploy path a managed app with no trust boundary.
    assert_equal(
        b2.tenancy.json_name(),
        String("TENANCY_CUSTOMER"),
        "tenancy survived as the AUTHORED value, not the zero default",
    )

    # --- ⭐ THE JOB-VM FIELDS — each VALUE, not just its word ----------------
    assert_equal(
        b2.build[0].file_role.json_name(),
        String("FILE_ROLE_POD_LOADER_BUNDLE"),
        "BuildTarget.file_role (6) survived as the authored value",
    )
    assert_equal(
        b2.build[0].repository_role.json_name(),
        String("REPOSITORY_ROLE_JOB_IMAGES"),
        "BuildTarget.repository_role (7) survived as the authored value",
    )
    var saw_from_build = False
    for ref prm in b2.spec.value().parameters:
        if prm.name == String("BOOT_BUNDLE_URL"):
            saw_from_build = True
            assert_equal(prm._oneof0_case, 6, "from_build is oneof arm 6")
            assert_equal(
                prm.from_build.value(), String("svc"), "from_build (18) value"
            )
    assert_true(saw_from_build, "the from_build parameter survived")
    var saw_own = False
    var saw_vm_state = False
    for ref w in b2.waves:
        for ref v in w.validate:
            if v.run_container:
                ref rc = v.run_container.value()
                if rc.own_identity == String("jm-vm-validator"):
                    saw_own = True
                for ref tr in rc.reads_telemetry:
                    if tr.json_name() == String("TELEMETRY_READ_JOB_VM_STATE"):
                        saw_vm_state = True
    assert_true(saw_own, "RunContainer.own_identity (10) survived")
    assert_true(saw_vm_state, "TELEMETRY_READ_JOB_VM_STATE (3) survived")
    assert_equal(
        len(b2.waves[0].api_edge_services), 2, "Wave.api_edge_services (9) — both"
    )
    assert_equal(
        b2.waves[0].api_edge_services[1],
        String("orders-email"),
        "Wave.api_edge_services keeps AUTHORED ORDER",
    )

    # --- AppBundle.triggers (field 6) ------------------------------------------
    #
    # The git fields live inside `git_push`. All THREE arms are authored and
    # asserted, so an emitter that dropped an arm kind, or flattened every arm to
    # the first one, fails.
    assert_equal(len(b2.triggers), 3, "all three triggers survived")

    ref t0 = b2.triggers[0]
    assert_equal(t0.name, String("external-release"), "trigger0 name survived")
    ref gp = t0.git_push.value()
    assert_equal(
        gp.source_kind.json_name(),
        String("SOURCE_KIND_GIT_EXTERNAL"),
        "trigger source_kind survived (not the proto3 zero default)",
    )
    assert_equal(gp.repo_ref, String("example/orders-fixture"), "trigger repo_ref")
    assert_equal(gp.ref_, String("release-branch"), "trigger ref")

    ref t1 = b2.triggers[1]
    assert_equal(
        t1.name, String("weekly-merge-from-live"), "trigger1 name survived"
    )
    ref sc = t1.schedule.value()
    assert_equal(sc.cron, String("0 6 * * 1"), "schedule cron survived")
    assert_equal(
        sc.timezone, String("America/Chicago"), "schedule timezone survived"
    )

    ref t2 = b2.triggers[2]
    assert_equal(t2.name, String("upstream-widget"), "trigger2 name survived")
    ref pp = t2.package_published.value()
    assert_equal(
        pp.registry_kind.json_name(),
        String("REGISTRY_KIND_GITHUB_PACKAGES"),
        "package_published registry_kind survived",
    )
    assert_equal(pp.package_ref, String("acme/widget"), "package_ref survived")
    assert_equal(pp.version_range, String("^2.0.0"), "version_range survived")

    # --- AppBundle.matrices (field 10) ---------------------------------------
    assert_equal(len(b2.matrices), 1, "one matrix survived")
    ref mx = b2.matrices[0]
    assert_equal(mx.name, String("desktop-support"), "matrix name")
    assert_equal(len(mx.cell), 2, "both cells survived")
    assert_equal(mx.cell[0].name, String("mac-arm64"), "cell 0 name")
    assert_equal(mx.cell[0].os, String("macos"), "cell 0 os")
    assert_equal(mx.cell[0].arch, String("arm64"), "cell 0 arch")
    assert_equal(mx.cell[0].artifact_kind, String("dmg"), "cell 0 artifact_kind")
    assert_equal(mx.cell[0].os_version_min, String("14.0"), "cell 0 floor")
    assert_equal(mx.cell[0].os_version_max, String("15.9"), "cell 0 ceiling")
    assert_equal(mx.cell[0].from_build, String("svc"), "cell 0 from_build")
    assert_equal(mx.cell[1].browser, String("chromium"), "cell 1 browser")
    # An UNAUTHORED field must not ACQUIRE a value on the way through.
    assert_equal(mx.cell[1].from_build, String(""), "cell 1 stays web-only")
    assert_equal(mx.cell[0].browser, String(""), "cell 0 stays native-only")

    ref sp = b2.spec.value()

    # --- AppSpec.buckets (20) / runtime_extra_capabilities (21) /
    #     web_route_rules (22) / keep_last_n (25) --------------------------
    assert_equal(len(sp.buckets), 1, "the bucket survived")
    assert_equal(sp.buckets[0].name, String("svc-cas-bucket"), "bucket name")
    assert_equal(sp.buckets[0].location, String("us-central1"), "bucket location")
    assert_equal(
        sp.buckets[0].storage_class, String("STANDARD"), "bucket storage_class"
    )
    assert_true(
        sp.buckets[0].uniform_bucket_level_access, "bucket UBLA stayed true"
    )
    assert_equal(
        sp.buckets[0].public_access_prevention,
        String("enforced"),
        "bucket public_access_prevention",
    )
    assert_equal(
        sp.buckets[0].object_expiry_days,
        Int32(30),
        "bucket object_expiry_days survived the emit -> reparse round trip — a"
        " retention policy dropped by the emitter is a bucket that keeps"
        " customer data forever the next time a bundle is machine-rewritten",
    )
    assert_equal(
        len(sp.runtime_extra_capabilities), 1, "the extra capability survived"
    )
    assert_equal(
        Int(sp.runtime_extra_capabilities[0]), 7, "the capability ORDINAL survived"
    )
    assert_equal(len(sp.web_route_rules), 1, "the route rule survived")
    ref rr = sp.web_route_rules[0]
    assert_equal(len(rr.paths), 1, "the rule's path survived")
    assert_equal(rr.paths[0], String("/admin/*"), "route path")
    assert_equal(rr.backend_role, String("svc-api"), "route backend_role")
    assert_equal(rr.error_404_path, String("/404.html"), "route error_404_path")
    assert_equal(Int(rr.error_404_code), 404, "route error_404_code")
    assert_equal(
        rr.disposition.json_name(),
        String("WEB_ROUTE_DISPOSITION_DENY"),
        "route disposition survived as DENY, not the ROUTE default",
    )
    assert_equal(
        rr.deny_reason,
        String("admin is control-plane only"),
        "route deny_reason",
    )
    assert_true(Bool(sp.keep_last_n), "keep_last_n presence survived")
    assert_equal(Int(sp.keep_last_n.value()), 3, "keep_last_n value")

    # --- AppSpec.network_ingress (32) --------------------------------------
    # Compared against the ENUM, never a hand-typed 3: a test that spelled the
    # ordinal would keep passing after a renumbering, which is precisely the
    # silent mis-stamp the conformer's explicit mapping refuses to risk.
    assert_equal(
        Int(sp.network_ingress.value),
        NetworkIngress.NETWORK_INGRESS_INTERNAL_AND_LOAD_BALANCER,
        "the AUTHORED network reach survived the canonical round trip — an\n"
        "        emitter that dropped it would re-emit the service as PUBLIC,\n"
        "        since an unstamped Cloud Run service defaults to `all`",
    )

    # --- AppSpec.network_egress (33) ----------------------------------------
    # ★ THE OUTBOUND PATH survived the canonical round trip. An emitter that
    # dropped this re-emits a bundle whose service has NO VPC attachment —
    # which is not "no opinion", it is "egress over the public internet",
    # and therefore refused AT THE EDGE by the private-ingress peer the
    # `network_ingress` assertion above just proved was preserved. Losing
    # one half of the pair on a round trip is the failure mode that reads as
    # an application 404.
    assert_true(
        Bool(sp.network_egress), "the authored VPC attachment survived"
    )
    ref _ne = sp.network_egress.value()
    assert_equal(_ne.network, String("default"), "the network survived")
    assert_equal(
        _ne.subnetwork,
        String("projects/p/regions/us-east1/subnetworks/default"),
        "and the REGION-COUPLED subnetwork survived verbatim",
    )
    assert_equal(len(_ne.network_tags), 1, "and the network tag survived")
    assert_equal(_ne.network_tags[0], String("cp-egress"), "by value")
    assert_true(
        _ne.private_ranges_only,
        "and the EXPLICIT narrow arm survived. This is the leaf a round trip\n"
        "        is most likely to lose silently: `private_ranges_only` is\n"
        "        proto3-default-skipped, and dropping it flips the attachment\n"
        "        to ALL_TRAFFIC — a WIDENING that still deploys green",
    )

    # --- AppSpec.mail_transport (34) ----------------------------------------
    # ★ THE MAIL SPINE survived the canonical round trip. Leg (b) alone is
    # satisfied by an EMPTY `mail_transport {}` that prints the right words, and
    # an empty one is not a neutral value here: `identity_ownership` reads back
    # UNSPECIFIED, which the composer REFUSES by name, so a round trip would turn
    # a deployable bundle into one that is refused at compose.
    assert_true(Bool(sp.mail_transport), "the authored mail spine survived")
    ref _mt = sp.mail_transport.value()
    assert_equal(_mt.domain, String("mail.example.test"), "the mail domain")
    assert_equal(
        _mt.identity_ownership.json_name(),
        String("MAIL_IDENTITY_OWNERSHIP_EXTERNAL"),
        "the OWNERSHIP arm survived verbatim — compared against the json name\n"
        "        and never an ordinal, because the two legal arms are\n"
        "        destructive in OPPOSITE directions (delete a third party's\n"
        "        identity, or refuse to send from our own) and a renumbering\n"
        "        that swapped them would keep an ordinal assertion green",
    )
    assert_equal(
        _mt.inbound_queue, String("svc-inbound-mail"), "the inbound queue name"
    )
    assert_equal(
        _mt.inbound_queue_logical_id,
        String("svc-inbound-mail-node"),
        "and the queue's LOGICAL ID survived as a SEPARATE literal — dropping"
        " it falls back to the derived `<inbound_queue>-queue`, which lands on"
        " a different node key and stands a second queue beside the live one"
        " instead of adopting it",
    )
    assert_equal(len(_mt.dns_records), 1, "the DNS record survived")
    ref _dr = _mt.dns_records[0]
    assert_equal(
        _dr.record_name,
        String("mail._domainkey.mail.example.test"),
        "the record NAME",
    )
    assert_equal(
        _dr.record_type,
        String("CNAME"),
        "and the record TYPE — the conformer refuses an unrecognised type BY"
        " NAME, so a dropped type is a bundle that stops applying",
    )
    assert_equal(
        _dr.target,
        String("dkim.provider.example.test"),
        "and the TARGET, asserted as its own literal: a record re-emitted with"
        " its neighbour's value publishes cleanly and resolves to nothing",
    )
    # --- AppSpec.secured_inbound_routes (26) --------------------------------
    assert_equal(
        len(sp.secured_inbound_routes), 1, "the secured inbound route survived"
    )
    ref sir = sp.secured_inbound_routes[0]
    assert_equal(sir.route_path, String("/hooks/federated"), "secured route_path")
    assert_equal(
        sir.policy.json_name(),
        String("EDGE_AUTH_POLICY_KIND_FEDERATED_SA_JWT"),
        "the secured route's POLICY survived — dropping it would re-emit an"
        " UNSPECIFIED policy, which validate refuses, so the round trip would"
        " turn a valid bundle into an invalid one",
    )
    # --- AppSpec.datastore_database (27) ------------------------------------
    assert_equal(
        sp.datastore_database,
        String("everything-db"),
        "the datastore database name survived the round trip — a dropped one is a"
        " deploy with no database to ensure",
    )
    # --- AppSpec.datastore_database_ref (28) --------------------------------
    # A SEPARATE literal from field 27's on purpose: the two are adjacent string
    # fields emitted back to back, so a fixture that gave them the same value
    # would call an emitter that writes 27's value into 28 correct.
    assert_equal(
        sp.datastore_database_ref,
        String("borrowed-db"),
        "the REFERENCED database name survived the round trip — dropping it"
        " turns a service that borrows someone else's database into one that"
        " names no database at all, which is the arm that then gets refused",
    )
    # --- AppSpec.index_tables (29) ------------------------------------------
    # ⚠ ASSERTED FIELD BY FIELD, NOT BY COUNT. An emitter that wrote the right
    # number of blocks with the wrong MODES would pass a count check and ship two
    # indexes the cloud creates and never uses.
    assert_equal(
        len(sp.index_tables), 1, "the app-declared index table survived"
    )
    ref it = sp.index_tables[0]
    assert_equal(String(it.table), String("everything_row"))
    assert_equal(
        len(it.indexes),
        2,
        "BOTH declared indexes survived — one is the `break`-after-first guard",
    )
    assert_equal(String(it.indexes[0].name), String("ix_everything_owner_created"))
    assert_equal(
        len(it.indexes[0].fields),
        2,
        "the composite key kept both members — ORDER IS THE INDEX PREFIX, so a"
        " dropped key is a different index, not a smaller one",
    )
    assert_equal(String(it.indexes[0].fields[0].col), String("owner_id"))
    assert_false(it.indexes[0].fields[0].desc, "key 0 stayed ASCENDING")
    assert_equal(String(it.indexes[0].fields[1].col), String("created_at"))
    assert_true(
        it.indexes[0].fields[1].desc,
        "the DESCENDING direction survived — `desc` default-skips on false, so"
        " an emitter that dropped the line would round-trip every ASCENDING"
        " index correctly and silently reverse this one",
    )
    assert_equal(String(it.indexes[0].scope), String("SCOPE_COLLECTION"))
    assert_equal(String(it.indexes[1].name), String("ix_everything_owner_labels"))
    assert_true(
        it.indexes[1].fields[0].array_contains,
        "the ARRAY-MEMBERSHIP mode survived — losing it yields an ORDERED index"
        " on an array column, which Firestore CREATES and marks READY and never"
        " uses to serve an `array-contains` query",
    )
    assert_equal(
        String(it.indexes[1].scope),
        String("SCOPE_COLLECTION_GROUP"),
        "the NON-default query scope survived — the default is COLLECTION, so"
        " only a non-default value can catch an emitter that hardcodes one",
    )
    assert_equal(
        sir.sa_email,
        String("caller@p.iam.gserviceaccount.com"),
        "the secured route's caller service account survived — it is BOTH the"
        " edge issuer and the account whose key set the edge fetches",
    )
    # ⛔ NO `audience` ASSERTION — there is no field (proto field 4, reserved). The accepted `aud` is the serving edge's own origin, which the
    # cloud assigns at Gateway CREATE, after the ApiConfig that carries it; it is
    # bound at apply time from the live `Gateway.default_hostname` and cannot be
    # authored. See `test_secured_route_audience_is_not_authorable` in
    # test_validate.mojo for the round-trip
    # falsifier: a bundle that spells `audience:` is REFUSED, and an emitted
    # bundle never contains the word.

    # --- BundleEnvVar.service_ref (the THIRD oneof arm) ----------------------
    assert_equal(len(sp.env), 3, "all three env arms survived")
    assert_true(Bool(sp.env[2].service_ref), "the service_ref arm is set")
    assert_equal(
        sp.env[2].service_ref.value().service,
        String("sibling-service"),
        "the referenced sibling service survived",
    )
    # The other two arms must NOT have been rewritten into it.
    assert_equal(sp.env[0].value.value(), String("literal-value"), "literal arm")
    assert_equal(
        sp.env[1].value_from.value().json_name(),
        String("VALUE_FROM_DEPLOY_URL"),
        "value_from arm",
    )

    # --- SecretBinding.ensure ------------------------------------------------
    assert_equal(len(sp.secret_bindings), 1, "the secret binding survived")
    assert_true(
        sp.secret_bindings[0].ensure,
        "ensure: true survived — a dropped `ensure` silently downgrades a"
        " PROVISIONING binding to authorize-only",
    )

    # --- SecretBinding.custody ----------------------------------------------
    # Leg (b) sees only the WORD `custody` at depth 2, so an emitter that wrote a
    # constant would satisfy it. Custody is the one field where the wrong VALUE
    # is worse than the missing field: OPERATOR->anything-else strips the
    # handle's ability to ever be seeded, CUSTOMER->anything-else authorises a
    # write of somebody else's credential.
    assert_equal(
        sp.secret_bindings[0].custody.json_name(),
        String("SECRET_CUSTODY_OPERATOR"),
        "custody: SECRET_CUSTODY_OPERATOR survived the round trip",
    )

    # --- PipelineStep.matrix_ref --------------------------------------------
    ref pl = b2.pipeline.value()
    assert_equal(len(pl.steps), 1, "the pipeline step survived")
    assert_equal(
        pl.steps[0].matrix_ref, String("desktop-support"), "step matrix_ref"
    )

    # --- AppBundle.services (field 7) — the MULTI-SERVICE list ----------------
    #
    # ⚠ THE CARDINALITY IS THE FIRST ASSERTION, and it is the one leg (b) cannot
    # make. A `_census` is a SET of (depth, field) pairs, so an emitter that wrote
    # the FIRST service and stopped produces a census identical to one that wrote
    # both — every field name still appears, at every depth. Emitting N-1 services
    # is the exact shape of data loss this block is most exposed to, because
    # `services` is the only top-level repeated block whose elements carry a whole
    # nested `spec`, and it is silent: the bundle still composes, one service short.
    assert_equal(len(b2.services), 2, "BOTH services survived the round trip")

    # Service 0 — API, with the cross-service reference intact.
    assert_equal(b2.services[0].name, String("front-door"), "services[0] name")
    assert_equal(
        b2.services[0].kind.json_name(),
        String("APP_KIND_API"),
        "services[0] kind survived as the AUTHORED value",
    )
    assert_true(Bool(b2.services[0].spec), "services[0] kept its spec")
    ref s0 = b2.services[0].spec.value()
    assert_equal(Int(s0.port), 9443, "services[0] spec.port — the nested AppSpec")
    assert_equal(len(s0.env), 1, "services[0] kept its env entry")
    assert_equal(
        s0.env[0]._oneof0_case,
        3,
        "services[0] env stayed on the service_ref arm (case 3)",
    )
    assert_equal(
        s0.env[0].service_ref.value().service,
        String("resource-owner"),
        "the cross-service reference names the sibling it named — the whole"
        " reason a multi-service bundle is one bundle",
    )

    # Service 1 — SHARED_INFRASTRUCTURE, a DIFFERENT kind and its own database.
    #
    # ⚠ THIS IS THE ROW THAT REFUSES A HARD-CODED KIND. An emitter that wrote
    # `APP_KIND_API` for every service passes leg (b) (the word `kind` is present
    # at depth 1) and passes the fixpoint leg (d) (its output re-parses to itself),
    # and hands `compose()` a resource owner that would be composed as a served
    # service — five nodes and a container for a machine that serves nothing.
    assert_equal(b2.services[1].name, String("resource-owner"), "services[1] name")
    assert_equal(
        b2.services[1].kind.json_name(),
        String("APP_KIND_SHARED_INFRASTRUCTURE"),
        "services[1] kind is its OWN value, not services[0]'s",
    )
    assert_true(Bool(b2.services[1].spec), "services[1] kept its spec")
    ref s1 = b2.services[1].spec.value()
    assert_equal(
        s1.datastore.json_name(),
        String("DATASTORE_NEED_SERVERLESS"),
        "services[1] datastore intent survived",
    )
    assert_equal(
        s1.datastore_database,
        String("owned-by-the-service"),
        "services[1] OWNS the database it named — the field whose loss leaves the"
        " next deploy with no database to ensure",
    )
    # --- JobSpec.args (field 9) — THE LIST, ITS ORDER AND ITS ARITY ----------
    #
    # ⛔ THE CENSUS (leg b) CANNOT SEE ANY OF THE THREE. It keys on `<depth>:<field>`
    # and deduplicates, so an emitter that wrote the FIRST arg and dropped the
    # second, or wrote them reversed, satisfies it exactly. parse->emit->parse
    # stays a FIXPOINT while a field
    # silently never round-trips, because the loss is uniform.
    #
    # ⛔ AND ARGV ORDER IS SEMANTIC. `--exit-code=0 --emit-marker=X` and its
    # reverse are the same census and different programs. This job's whole
    # contract is that its exit code is the verdict, so an argv the round trip
    # reorders is a gate that can silently stop testing what it says it tests.
    assert_equal(
        len(b2.jobs), 1, "the fixture authors exactly one job"
    )
    assert_equal(
        len(b2.jobs[0].args),
        2,
        "BOTH authored args survived — a one-element result passes the census",
    )
    assert_equal(
        b2.jobs[0].args[0],
        String("--exit-code=0"),
        "argv[0] survived IN POSITION — the token the negative case flips",
    )
    assert_equal(
        b2.jobs[0].args[1],
        String("--emit-marker=MC_JOB_PROBE_RAN"),
        "argv[1] survived IN POSITION",
    )
    print("  test_dropped_field_content_survives_the_round_trip: PASS")


# =============================================================================
# (d) THE CANONICAL FORM IS A FIXPOINT.
# =============================================================================
def test_canonical_form_is_a_stable_fixpoint() raises:
    var canonical = emit_bundle(parse_bundle(_everything_bundle()))
    assert_equal(
        emit_bundle(parse_bundle(canonical)),
        canonical,
        "the canonical form of an every-field bundle is a parse->emit fixpoint",
    )
    print("  test_canonical_form_is_a_stable_fixpoint: PASS")


# =============================================================================
# (e) MIGRATION SAFETY — a bundle authoring none of the newly-emitted blocks
#     gains none of them.
# =============================================================================
def test_bundle_without_the_new_blocks_gains_none_of_them() raises:
    var plain = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "svc" dockerfile: "Dockerfile.svc" }\n'
        'spec { image { from_build: "svc" } port: 8080 }\n'
        # ⭐ A run_container step, so the RunContainer default-skips (incl. the
        # job-VM `own_identity`) are exercised by this leg at all.
        'waves { env: "gamma" validate { name: "v" run_container {'
        ' image { digest: "sha256:ab" } gate_on: GATE_ON_EXIT_CODE } } }\n'
    )
    var canonical = emit_bundle(parse_bundle(plain))
    var names = _names_only(_census(canonical))
    for ref absent in [
        String("triggers"),
        String("matrices"),
        String("buckets"),
        String("runtime_extra_capabilities"),
        String("web_route_rules"),
        String("keep_last_n"),
        String("secured_inbound_routes"),
        String("datastore_database"),
        # Its own row: `_has` is exact equality, so the `datastore_database`
        # row above does NOT cover the `_ref` spelling.
        String("datastore_database_ref"),
        # AppSpec.index_tables (29) — the app-declared composite-index shapes.
        String("index_tables"),
        # AppSpec.network_ingress (32) — a plain bundle authors no reach, and
        # the emitter must not invent one. Emitting UNSPECIFIED here would turn
        # "this bundle says nothing" into "this bundle chose the default", which
        # are different statements about who owns the service's exposure.
        String("network_ingress"),
        # AppSpec.network_egress (33) — likewise. Emitting an empty
        # `network_egress {}` would turn "this bundle says nothing about
        # its outbound path" into "this bundle authored a half-filled
        # attachment", which `validate` REFUSES — so a re-emitted plain
        # bundle would stop parsing.
        String("network_egress"),
        # AppSpec.mail_transport (34) — likewise, and this row is the one whose
        # absence is least recoverable. `_emit_mail_transport` emits
        # `identity_ownership` EVEN WHEN ZERO by design, so an emitter that
        # materialized an unauthored spine would write
        # `MAIL_IDENTITY_OWNERSHIP_UNSPECIFIED` into every bundle — a value the
        # composer REFUSES by name, i.e. a canonical round trip that makes every
        # bundle undeployable.
        String("mail_transport"),
        String("service_ref"),
        String("ensure"),
        String("matrix_ref"),
        # ★ `services` (field 7) — THE AUTO-LIFT GUARD, and the sharpest row here.
        # An EMPTY `services` list is not an absent value: it is the SIGNAL that
        # `_auto_lifted_services` reads to synthesize a one-element list from the
        # singular `kind`/`name`/`spec`. An emitter that materialized that lifted
        # service would rewrite every single-service bundle into a
        # shape where `services` is AUTHORITATIVE and their singular `name`/`spec`
        # are IGNORED — a canonical round trip that changes what the document means
        # while every field name still round-trips.
        String("services"),
        # ⭐ THE JOB-VM FIELDS. Each is default-skipped; an emitter that wrote
        # `file_role: FILE_ROLE_UNSPECIFIED` or `own_identity: ""` into every
        # document would change every bundle's canonical form for a field no author wrote — and `validate_bundle` refuses a
        # non-zero one by name, so a wrong-way default would not even parse
        # back as the same bundle.
        String("file_role"),
        String("repository_role"),
        String("own_identity"),
        String("api_edge_services"),
    ]:
        assert_true(
            not _has(names, absent),
            String("a plain bundle must NOT gain a '")
            + absent
            + String("' — the newly-emitted fields are proto3 default-skipped"),
        )
    assert_equal(
        emit_bundle(parse_bundle(canonical)),
        canonical,
        "a plain bundle stays a stable parse->emit fixpoint",
    )
    print("  test_bundle_without_the_new_blocks_gains_none_of_them: PASS")


def main() raises:
    test_fixture_authors_every_field_the_parser_accepts()
    test_emit_drops_no_authored_field()
    test_dropped_field_content_survives_the_round_trip()
    test_canonical_form_is_a_stable_fixpoint()
    test_bundle_without_the_new_blocks_gains_none_of_them()
    print("PASS test_emit_completeness")
