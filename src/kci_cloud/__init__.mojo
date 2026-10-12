"""`kci_cloud`: the clouds of kci's deploy side.

The catalog (`kci_resource_proto`) says WHAT an author can deploy and the
engine (`kci_reconciler`) knows how to reconcile a graph of nodes; this
package sits between them. A CLOUD is the deploy target of a cell (`gcp`,
`aws`, `fake`): the id of a cloud adapter built into kci. It is not a
platform; a platform is an OS and a CPU (`Image.platform`). Every cloud is
built into kci, so the list of clouds is closed and nothing here is a plugin
interface. No type or branch here names a cloud; the built-in clouds' shapes
are values (`shape/`):

  * catalog.mojo     — the catalog's types as data (arm number, portability,
                       exposed outputs, accepted access, retention default,
                       primary role) and a resource's type, read from its
                       set arm (`body_field`, `body_is`).
  * cloud_id.mojo    — the opaque `CloudId` (equality and printing only).
  * adapter.mojo     — the `CloudAdapter` trait every built-in cloud
                       implements (an internal module boundary, not frozen):
                       coverage, `configure` with the cell's settings, the
                       public mechanism, limits, the artifact a resource
                       needs, lowering to DATA (`LoweredNode`) and `realize`,
                       bootstrap resources, the label rule, `list_owned`,
                       `whoami`, `trust_render` / `trust_check`; typed
                       absences (ABSENT_BY_DESIGN / NOT_YET) and `Finding`.
  * workload.mojo    — the three workload types (service, container job,
                       worker) as one view of their shared container fields
                       and identity.
  * compute.mojo     — the rules of the workloads: their graph findings
                       (image, run_as, env, command, a worker's replicas)
                       and a worker's versioned replicas default.
  * grants.mojo      — who a resource runs as (its identity owner), and
                       every grant edge it lowers (`uses` lines, a grant
                       resource, the implicit `cell LOGS WRITE`, a
                       trigger's implicit CALL on its target), each
                       with its role `u-<h>` (or `grant`) decided by kci.
  * data.mojo        — the rules of the data types (table, bucket): their
                       graph findings, a table's key as text, the index
                       role `ix-<h>`, and the refusal of a changed key.
  * feed.mojo        — the FEEDS: the list's subscriptions as (subscription,
                       topic, queue), handed to every adapter's `check` and
                       `lower`.
  * firing.mojo      — the FIRINGS: the list's schedules as (schedule,
                       target, target type, cron, time zone), handed to
                       every adapter's `check` and `lower`; and the
                       schedule's versioned time zone.
  * network.mojo     — the rules of the network types (network, subnet, IP
                       address) and of a service's `network`: their graph
                       findings and the IPv4 range form.
  * registry.mojo    — the rules of the registry type: its graph findings
                       (no `uses`; a format written and known).
  * triggers.mojo    — the rules of the trigger types (schedule, event
                       trigger): their graph findings, the portable cron
                       form and a time zone name's shape.
  * messaging.mojo   — the rules of the messaging types (queue, topic,
                       subscription): their graph findings and the queue's
                       versioned ack deadline.
  * secrets.mojo     — the rules of the secret type and of the `secret_env`
                       references to it: their graph findings (one of a
                       name and a secret; a secret resource read by the
                       identity that receives it).
  * values.mojo      — the checks of a configuration value (a literal, a
                       parameter, a reference to another resource's
                       output), shared by `env` and a DNS record's values.
  * dns.mojo         — the rules of the name types (DNS zone, DNS record,
                       certificate): their graph findings, the DNS name
                       grammar, and the record's versioned TTL.
  * labels.mojo      — the standard label rule (encode, decode, check), and
                       komira_validation_run's two marks: the retention
                       mark `kci-retention=<retain|delete>` on every object
                       kci creates or adopts, and the `kci-run-id=<id>`
                       label of an object created in a scope with a
                       validation run id (no kci verb sets one yet);
                       `create_labels` is every label a create writes; and
                       kci's adoption mark `kci_adopted=true`.
  * metadata.mojo    — the rules of every resource's metadata (`labels`,
                       `physical_name`, `adopt`): their
                       graph findings, the label fields kci lowers, the
                       adopted primary nodes, and the refusal of a changed
                       cloud name.
  * adoption.mojo    — safe adoption: an adopted object read and checked
                       before planning, the adoption mark, the refusal of
                       a replace of an adopted object and of a delete its
                       resource does not allow, the release of one whose
                       resource left the list, and the plan that says so
                       (`PlanReport`).
  * clouds.mojo      — `Clouds`, the closed list of built-in clouds:
                       `resolve` (with a typo suggestion), and the rule that
                       every cloud declares every catalog type.
  * compose_refs.mojo — the one walk over every reference of a resource
                       (`ref_sites`, `with_sites`), the guard that none of
                       the composite form is left (`unrewritten`), the id
                       and name grammars of resources and composites, and
                       the owner of a node or path (`owner_of_node`, its
                       first segment at any depth).
  * compose_bind.mojo — the input types of a composite, and BINDINGS: an
                       input written into a field of a primitive component
                       through its proto3 JSON (`bind_field`), the load
                       rules of bindings and presences.
  * compose_kci.mojo — the `kci` namespace: the definitions kci ships, by
                       name, version and digest.
  * compose_load.mojo — LOADING definitions: their checks, containment
                       cycles, the instances at the top of a list, and the
                       count the size guard reads (`Loader`).
  * compose.mojo     — EXPANSION: a list with composite instances -> a list
                       of primitives with path ids `top/c1/.../ck`
                       (`expand`): after a load with no finding and the
                       size guard, every reference rewritten to a full path
                       through exports and declared outputs, every binding
                       written, every absent component left out, and the
                       tree a plan prints (`Expansion`).
  * validate.mojo    — the validate phase: expansion first, then graph,
                       coverage and limit
                       findings, collected in one pass; on a graph with
                       no other finding, the role label budget over the
                       cloud's lowering; the refusal text.
  * deploy.mojo      — plan / apply / destroy in a cell: configure and
                       validate first, lower to data with the lowering
                       contract checked (`lowering_json` for golden tests),
                       add the roles `list_owned` says the file turned off,
                       realize, then the engine's owned scope; an apply
                       returns an `ApplyOutcome` (applied, landed, pending,
                       error, leftover, left behind, released); and the
                       plan grouped by authored resource, adopted nodes and
                       releases marked (`render_plan`).
  * derived.mojo     — the DERIVED stamp of a member binding (a grant that
                       carries no labels): its attribution to a node, from
                       the role table and the stamps of its member and its
                       target, and the table's injectivity.
  * shape/           — THE shared shape lowering of the built-in clouds
                       (`ProviderShape`, `lower_shape`, `shape_limits`): the
                       roles and provider kinds of each type per cloud, as
                       data. The fakes and every built-in adapter lower
                       through it. It is the one place that names the
                       built-in clouds, as values; no type or branch does.
  * conformance.mojo — the conformance kit every cloud runs (fifteen
                       steps, from label stamping to two interleaved
                       applies, the validation-run tag under the kit's own
                       run id, an adoption through `Resource.adopt`: the
                       mark kept on update, then the release; a foreign
                       member left alone; and every object born stamped).

The fake clouds (working in-memory clouds, not mocks) that exercise all of it live in
`kci_cloud_fake`.
"""

from kci_cloud.cloud_id import CloudId
from kci_cloud.catalog import (
    Catalog,
    CatalogType,
    PORTABLE,
    CLOUD_BOUND,
    FIELD_SERVICE,
    FIELD_CONTAINER_JOB,
    FIELD_WORKER,
    FIELD_TABLE,
    FIELD_BUCKET,
    FIELD_SERVICE_ACCOUNT,
    FIELD_GRANT,
    FIELD_QUEUE,
    FIELD_SECRET,
    FIELD_DNS_ZONE,
    FIELD_TOPIC,
    FIELD_DNS_RECORD,
    FIELD_CERTIFICATE,
    FIELD_SUBSCRIPTION,
    FIELD_SCHEDULE,
    FIELD_EVENT_TRIGGER,
    FIELD_COMPOSITE,
    FIELD_NETWORK,
    FIELD_SUBNET,
    FIELD_IP_ADDRESS,
    FIELD_REGISTRY,
    OUTPUT_URL,
    OUTPUT_HOST,
    OUTPUT_ADDRESS,
    OUTPUT_NAME,
    ACCESS_CALL,
    ACCESS_READ,
    ACCESS_WRITE,
    ACCESS_READ_WRITE,
    ACCESS_DESCRIBE,
    ACCESS_SEND,
    ACCESS_RECEIVE,
    RETENTION_NONE,
    RETENTION_DELETE,
    RETENTION_KEEP,
    ROLE_RUN,
    ROLE_TABLE,
    ROLE_BUCKET,
    ROLE_IDENTITY,
    ROLE_GRANT,
    ROLE_QUEUE,
    ROLE_SECRET,
    ROLE_TOPIC,
    ROLE_SUBSCRIPTION,
    ROLE_ZONE,
    ROLE_RECORD,
    ROLE_CERT,
    ROLE_SCHEDULE,
    ROLE_TRIGGER,
    ROLE_NETWORK,
    ROLE_SUBNET,
    ROLE_ADDRESS,
    ROLE_REGISTRY,
    BodyArm,
    body_arms,
    body_field,
    body_is,
    effective_retention,
    portability_word,
    primary_node,
    retention_word,
)
from kci_cloud.grants import (
    CELL_ARTIFACTS,
    CELL_LOGS,
    CELL_METRICS,
    CELL_PATH_PREFIX,
    EDGE_TARGET_CELL,
    EDGE_TARGET_UNKNOWN,
    GRANT_ROLE_PREFIX,
    GrantEdge,
    cell_accepts,
    cell_name,
    edges_for,
    edges_of,
    grant_hash,
    role_hash,
    holds_own_identity,
    identity_owner,
    is_trigger,
    trigger_target,
    principal_node,
    run_as_of,
    uses_role,
)
from kci_cloud.adapter import (
    CloudAdapter,
    RegistryLogin,
    Absence,
    Finding,
    Setting,
    ResolvedArtifact,
    CellContext,
    ArtifactNeed,
    BootstrapItem,
    OwnedRecord,
    ExistingObject,
    Principal,
    LoweredNode,
    retention_name,
    RUN_UNKNOWN,
    ABSENT_BY_DESIGN,
    NOT_YET,
    FINDING_GRAPH,
    FINDING_COVERAGE,
    FINDING_LIMIT,
    FINDING_CELL,
    FINDING_ADOPTION,
    absence_word,
)
from kci_cloud.data import (
    INDEX_ROLE_PREFIX,
    KEY_FIELD,
    data_findings,
    index_role,
    index_role_collisions,
    key_change_findings,
    path_text,
    table_key_text,
)
from kci_cloud.feed import Feed, feeds_into, feeds_of, field_of_id
from kci_cloud.firing import TIMEZONE_DEFAULT, Firing, firing_of, firings_into, firings_of, schedule_timezone
from kci_cloud.triggers import (
    EVENT_OBJECT_CREATED,
    EVENT_OBJECT_DELETED,
    cron_fields,
    cron_problem,
    timezone_problem,
    trigger_findings,
)
from kci_cloud.network import (
    CIDR_PREFIX_MAX,
    CIDR_PREFIX_MIN,
    ZONE_MAX,
    ZONE_MIN,
    contains,
    ipv4_cidr_problem,
    ipv4_text,
    is_private,
    network_findings,
    overlaps,
    service_network_findings,
    service_subnet,
)
from kci_cloud.registry import FORMAT_OCI, format_word, registry_findings, registry_format
from kci_cloud.workload import Workload, is_workload, workload_of
from kci_cloud.compute import (
    V1_IMAGE_PLATFORM,
    WORKER_REPLICAS_DEFAULT,
    image_platform,
    worker_replicas,
    workload_findings,
)
from kci_cloud.secrets import secret_env_findings, secret_findings, secret_of
from kci_cloud.values import check_value, check_value_ref
from kci_cloud.dns import (
    CERTIFICATE_DOMAINS_MAX,
    TTL_DEFAULT_SECONDS,
    TTL_MAX_SECONDS,
    TTL_MIN_SECONDS,
    dns_findings,
    dns_name_problem,
    in_zone,
    record_type_word,
    ttl_seconds,
    zone_name_of,
)
from kci_cloud.messaging import (
    ACK_DEADLINE_DEFAULT_SECONDS,
    ACK_DEADLINE_MAX_SECONDS,
    ACK_DEADLINE_MIN_SECONDS,
    MAX_DELIVERIES_MAX,
    MAX_DELIVERIES_MIN,
    ack_deadline_seconds,
    dead_letter_of,
    messaging_findings,
)
from kci_cloud.labels import (
    LABEL_VALUE_MAX,
    retain_labels,
    retention_label_key,
    retention_label_value,
    retained_by,
    encoded_label_bytes,
    encode_label_value,
    decode_label_value,
    standard_label_rule,
    standard_identity_of,
    label_problems,
    VALIDATION_RUN_TAG_PREFIX,
    create_labels,
    validation_run_label_key,
    validation_run_labels,
    validation_run_of,
    validation_run_problem,
    ADOPTED_LABEL_KEY,
    ADOPTED_LABEL_VALUE,
    adoption_labels,
    adopted_by,
    is_kci_label_key,
)
from kci_cloud.clouds import (
    Clouds,
    CloudEntry,
    describe,
    artifact_problems,
)
from kci_cloud.compose_refs import (
    COMPONENT_ID_MAX_BYTES,
    ID_MAX_BYTES,
    RefSite,
    SITE_REF,
    SITE_VALUE,
    component_id_problem,
    definition_name_problem,
    id_problem,
    literal_value,
    no_ref,
    owner_of_node,
    ref_sites,
    ref_value,
    unrewritten,
    with_sites,
)
from kci_cloud.compose_bind import (
    BindValue,
    INPUT_BOOL,
    INPUT_IMAGE,
    INPUT_INT,
    INPUT_REF,
    INPUT_STRING,
    INPUT_VALUE_MAP,
    bind_field,
    binding_problem,
)
from kci_cloud.compose_kci import KCI_NAMESPACE, ShippedDefinition, kci_definition_problem, shipped_definitions
from kci_cloud.compose_load import (
    MAX_EXPANDED_PRIMITIVES,
    definition_digest,
    definition_key,
    is_composite,
)
from kci_cloud.compose import Expansion, expand
from kci_cloud.validate import (
    graph_findings,
    edge_findings,
    validate_for,
    validate_expanded,
    refusal_text,
    node_role,
    lowered_budget_findings,
    role_budget_findings,
)
from kci_cloud.deploy import (
    ApplyOutcome,
    Removals,
    engine_retention,
    refuse_unless_valid,
    valid_expansion,
    lower_data,
    lowering_json,
    realize_graph,
    removals,
    lower_resources,
    plan_resources,
    plan_report,
    apply_resources,
    destroy_resources,
    group_plan,
    render_plan,
    with_adopted,
)
from kci_cloud.adoption import (
    AdoptionCheck,
    PlanReport,
    adopted_nodes_of,
    adoption_check,
    delete_findings,
    deletable,
    existing_mismatches,
    replace_findings,
    resource_of_node,
    unadopted_findings,
)
from kci_cloud.metadata import (
    KCI_LABELS_MAX,
    LABEL_FIELD_PREFIX,
    LABEL_MAX_BYTES,
    NAME_MAX_BYTES,
    PHYSICAL_NAME_FIELD,
    adopted_nodes,
    adopts,
    label_fields,
    label_key_problem,
    label_value_problem,
    metadata_findings,
    name_change_findings,
    physical_name_problem,
    shared_name_findings,
    sorted_label_keys,
)
from kci_cloud.conformance import (
    ConformanceTarget,
    MEMBER_CELL,
    MEMBER_FOREIGN,
    ROLE_MAPPED,
    ROLE_UNMAPPED,
    run_conformance,
)
from kci_cloud.derived import (
    ACCESS_PUBLIC,
    ALL_USERS,
    BindingEnd,
    DerivedStamp,
    ROLE_PUBLIC_NODE,
    RoleRow,
    attribute,
    role_for,
    role_table_problems,
)
from kci_cloud.shape import (
    DERIVED_CITATION,
    GRANTS_DERIVED,
    GRANTS_LABELLED,
    GrantRow,
    MetadataLimits,
    NameRule,
    ProviderShape,
    ShapeRow,
    builtin_shapes,
    derived_grant_limits,
    lower_shape,
    shape_limits,
    shape_named,
)
