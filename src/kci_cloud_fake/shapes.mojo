# =============================================================================
# kci_cloud_fake/shapes.mojo: the provider shapes a fake cloud can lower to.
# =============================================================================
#
# A primitive is 1:1 with a resource kind of the major clouds, and each cloud
# lowers it to its OWN fixed set of roles. A `ProviderShape` is that set, as
# data: per catalog field, the ordered roles the type lowers to, each with
# the provider kind id it stands for (the CloudFormation type, the GCP asset
# or API type, the ARM type, the Kubernetes apiVersion/kind, the Vault or
# MinIO API class); and per TARGET TYPE, the kind a grant edge to it lowers
# to (`GrantRow`).
#
# IDENTITY. Every shape has an `identity` row for a service, a job and a
# service account: the private identity of a service or a job (turned off
# under `run_as`), and the one object of a service account. The onprem shape
# adds a fixed helper, `vault`: the Vault `kubernetes` auth role bound to the
# Kubernetes service account, so the workload can log in to the cell's
# Vault with its service account token.
#
# GRANTS. One `GrantRow` per target type (`EDGE_TARGET_CELL` for a resource
# the cell provides, `TARGET_ANY` for every type without a row of its own).
# A row may name a HELPER kind: the permission object the grant binds,
# lowered as a second node of the edge (`r-<h>` beside `u-<h>`, `rules`
# beside `grant`) that the binding depends on. A target type with no row and
# no `TARGET_ANY` row FOLDS: the edge has no node of its own, and is a
# desired field `cell.<NAME>` of the identity it is for (only a cell edge of
# the resource's own identity can fold; the fake refuses any other at
# validate, as a limit).
#
#   * `generic`   the fake's own shape: service -> identity, run, public;
#                 job -> identity, run, schedule; table -> table; bucket ->
#                 bucket; service account -> identity; every grant ->
#                 `grant`.
#   * `aws`       service -> identity (AWS::IAM::Role), run
#                 (AWS::Lambda::Function), public (AWS::Lambda::Url);
#                 job -> identity, run (AWS::ECS::TaskDefinition), schedule
#                 (AWS::Scheduler::Schedule); table -> table
#                 (AWS::DynamoDB::Table: its indexes are GSIs and its TTL
#                 a setting, both inline); bucket -> bucket
#                 (AWS::S3::Bucket); service account -> identity
#                 (AWS::IAM::Role, trusted by the compute service only).
#                 Grants: on a service, the function's resource policy
#                 (AWS::Lambda::Permission); on anything else, an inline
#                 policy of the principal's role (AWS::IAM::RolePolicy).
#   * `gcp`       service -> identity (iam.googleapis.com/ServiceAccount), run
#                 (run.googleapis.com/Service), public (an invoker member
#                 binding); job -> identity, run (run.googleapis.com/Job),
#                 schedule (cloudscheduler.googleapis.com/Job); table ->
#                 Firestore has NO table object: a table is a collection
#                 group, and what kci creates for it is ONE COMPOSITE INDEX
#                 PER ACCESS PATH (firestore.googleapis.com/Index) and a TTL
#                 policy (firestore.googleapis.com/Field). The key's index is
#                 the role `table` (the catalog's primary role, so a
#                 reference to the table lands on it), each secondary index
#                 the role `ix-<h>` (`kci_cloud.index_role`: 5 base32
#                 characters of its name, one node per index, found through
#                 `list_owned` like a grant's `u-<h>`), and the TTL policy
#                 the role `ttl` (wanted iff `ttl_field` is set). Two index
#                 names whose roles collide are a limit. bucket ->
#                 bucket (storage.googleapis.com/Bucket); service account ->
#                 identity. Every grant is a member binding on its target.
#                 GCP has no asset type for one binding: the kind id names
#                 the call that writes it, `setIamPolicy`.
#   * `azure`     service -> identity
#                 (Microsoft.ManagedIdentity/userAssignedIdentities), run
#                 (Microsoft.App/containerApps); job -> identity, run
#                 (Microsoft.App/jobs); table -> table
#                 (Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers,
#                 in the cell's Cosmos account: indexes and TTL are settings
#                 of the container); bucket -> bucket
#                 (Microsoft.Storage/storageAccounts/blobServices/containers,
#                 in the cell's storage account); service account ->
#                 identity. Every grant is a
#                 Microsoft.Authorization/roleAssignments, except to a table:
#                 Cosmos data access is granted by its own role assignment
#                 (Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments),
#                 not by ARM RBAC. There is NO public
#                 row and NO schedule row: a container app's ingress and a
#                 job's schedule trigger are settings of the run object, so
#                 they FOLD into the run node's desired fields (`ingress`,
#                 `trigger`) and are never nodes of their own.
#   * `onprem`    the self-hosted cloud: Kubernetes + MinIO + Vault.
#                 service -> identity (v1/ServiceAccount), vault
#                 (vault:auth/kubernetes/role), run (apps/v1/Deployment),
#                 endpoint (v1/Service: the in-cluster address of the
#                 Deployment, always wanted), public
#                 (networking.k8s.io/v1/Ingress, which fronts the endpoint);
#                 job -> identity, vault, run (batch/v1/CronJob); bucket ->
#                 bucket (minio/Bucket: an S3-API bucket on the cell's MinIO);
#                 service account -> identity, vault. There is NO schedule
#                 row: a job is a CronJob, and its schedule FOLDS into it
#                 (`trigger`; an on-demand job is a suspended CronJob, and a
#                 run of it is a batch/v1/Job made from the CronJob's
#                 template, which is an execution, not a lowered object).
#                 Grants by the target's backing, one row per target type:
#                 a Kubernetes target (service, job, service account) ->
#                 rbac.authorization.k8s.io/v1/RoleBinding with its helper
#                 rbac.authorization.k8s.io/v1/Role; a MinIO target (bucket)
#                 -> minio:policy (mapped to the service account's token
#                 claim). A Vault target has no type yet: its row (a Vault
#                 policy attached to the `vault` auth role) arrives with the
#                 first Vault-backed type. A cell resource has NO row: the
#                 edge folds into the identity (`cell.LOGS`).
#                 A TABLE IS NOT_YET on onprem: which datastore backs it is
#                 an open design question (Q17: PostgreSQL via
#                 CloudNativePG, CockroachDB, ScyllaDB or FoundationDB), so
#                 the shape declares it absent rather than pick one, and a
#                 graph with a table is refused on onprem before anything is
#                 lowered (a coverage finding naming the type and Q17).
#
# THE BUILT-IN CLOUDS ARE DATA: `builtin_shapes()` is the list aws, gcp,
# azure, onprem, and `shape_named(name)` looks a cloud name up in it and
# refuses any other name. No type and no branch names a cloud. `generic` is
# the fake's own shape, not a cloud, so it is not in the list.
#
# A role the shape has but the file turns off is still lowered, with
# `wanted` False (the closed world). A FOLDED role has no node: turning it
# off is an update of the node it folds into.
#
# A bucket has ONE role on every shape, `bucket`, and no identity: it runs
# as nobody, it is only granted to. A table likewise runs as nobody; its
# roles are `table` on every shape that hosts it, plus `ix-<h>` and `ttl`
# where the indexes and the TTL are objects of their own (gcp).
#
# MESSAGING (queue, topic, subscription; messaging.mojo lowers them):
#   * `generic`   queue -> queue; topic -> topic; subscription -> sub.
#   * `aws`       queue -> queue (AWS::SQS::Queue, redrive to its dead-letter
#                 queue) and policy (AWS::SQS::QueuePolicy, wanted iff a
#                 subscription feeds the queue: ONE policy per queue lets
#                 every topic that feeds it send, because two policies on one
#                 queue overwrite each other); topic -> topic
#                 (AWS::SNS::Topic); subscription -> sub
#                 (AWS::SNS::Subscription, after the queue's policy).
#   * `gcp`       a queue is a PULL SUBSCRIPTION: queue -> topic (a private
#                 pubsub.googleapis.com/Topic, wanted iff no subscription
#                 feeds the queue) and queue (pubsub.googleapis.com/
#                 Subscription, on the private topic, or on the topic that
#                 feeds it); topic -> topic (pubsub.googleapis.com/Topic);
#                 subscription -> sub, ALWAYS TURNED OFF: it has no object of
#                 its own, it is the topic the queue's subscription is on. A
#                 queue fed by two topics, a direct SEND to a fed queue, and a
#                 dead-letter queue that is fed are limits (messaging.mojo).
#   * `azure`     queue -> queue (Microsoft.ServiceBus/namespaces/queues);
#                 topic -> topic (Microsoft.ServiceBus/namespaces/topics);
#                 subscription -> sub
#                 (Microsoft.ServiceBus/namespaces/topics/subscriptions,
#                 forwarding to the queue). All in the cell's namespace.
#   * `onprem`    NOT_YET for all three: which message backing an onprem cell
#                 runs is an open design question (Q16: RabbitMQ, NATS
#                 JetStream, Apache Kafka or Redis Streams), so the shape
#                 declares them absent rather than pick one.
#
# A shape's ABSENCES (`not_yet`) are the catalog types it does not host yet,
# each with its reason; the fake cloud built with the shape declares them,
# and is complete only when there are none. A grant resource has no row: its roles
# are its edge's (`grant`, and `rules` where the row names a helper).
#
# A shape is chosen by the constructor of a fake cloud, never from the
# cloud's id: the id stays opaque.
# =============================================================================

from kci_cloud import (
    Absence,
    FIELD_BUCKET,
    FIELD_JOB,
    FIELD_QUEUE,
    FIELD_SERVICE,
    FIELD_SERVICE_ACCOUNT,
    FIELD_SUBSCRIPTION,
    FIELD_TABLE,
    FIELD_TOPIC,
    NOT_YET,
)


comptime ROLE_BUCKET = "bucket"
comptime ROLE_TABLE = "table"
comptime ROLE_INDEX = "ix"
"""A shape row meaning "each secondary index is a node of its own", role
`ix-<h>` (`kci_cloud.index_role`); never a role itself."""
comptime ROLE_TTL = "ttl"
comptime ROLE_IDENTITY = "identity"
comptime ROLE_RUN = "run"
comptime ROLE_PUBLIC = "public"
comptime ROLE_SCHEDULE = "schedule"
comptime ROLE_ENDPOINT = "endpoint"
comptime ROLE_VAULT = "vault"
comptime ROLE_QUEUE = "queue"
comptime ROLE_TOPIC = "topic"
comptime ROLE_SUB = "sub"
comptime ROLE_POLICY = "policy"
"""aws: the queue policy that lets the topics feeding a queue send to it."""
comptime ROLE_RULES = "rules"
"""The helper of a `grant` resource's edge, where its row names one."""

comptime TARGET_ANY: Int = -1
"""A `GrantRow` for every target type without a row of its own."""

comptime _AWS_ROLE = "AWS::IAM::Role"
comptime _GCP_SA = "iam.googleapis.com/ServiceAccount"
comptime _AZURE_ID = "Microsoft.ManagedIdentity/userAssignedIdentities"
comptime _K8S_SA = "v1/ServiceAccount"
comptime _VAULT_ROLE = "vault:auth/kubernetes/role"
comptime _K8S_BINDING = "rbac.authorization.k8s.io/v1/RoleBinding"
comptime _K8S_ROLE = "rbac.authorization.k8s.io/v1/Role"
comptime _FIRESTORE_INDEX = "firestore.googleapis.com/Index"
comptime _PUBSUB_TOPIC = "pubsub.googleapis.com/Topic"
comptime _PUBSUB_SUB = "pubsub.googleapis.com/Subscription"
comptime ONPREM_MESSAGING_REASON = (
    "the onprem message backing of a queue, a topic and a subscription is an"
    " open question (Q16: RabbitMQ, NATS JetStream, Apache Kafka or Redis"
    " Streams)"
)
comptime ONPREM_TABLE_REASON = (
    "the onprem datastore that backs a table is an open question (Q17:"
    " PostgreSQL via CloudNativePG, CockroachDB, ScyllaDB or FoundationDB)"
)


@fieldwise_init
struct ShapeRow(Copyable, Movable, Deinitable):
    """One role a catalog type lowers to on a shape: the type's field, the
    role, and the provider kind id the role's object is."""

    var field: Int
    var role: String
    var kind: String


@fieldwise_init
struct GrantRow(Copyable, Movable, Deinitable):
    """The kind a grant edge to a target of type `target` lowers to (a
    catalog field, `EDGE_TARGET_CELL` or `TARGET_ANY`), and the kind of its
    helper (the permission object the grant binds), empty for none."""

    var target: Int
    var kind: String
    var helper: String


def helper_role(role: String) -> String:
    """The role of an edge's helper node: `r-<h>` beside `u-<h>`, `rules`
    beside `grant`."""
    if role.startswith("u-"):
        return String("r-") + String(role[byte = 2 : role.byte_length()])
    return String(ROLE_RULES)


struct ProviderShape(Copyable, Movable, Deinitable):
    """Per catalog field, the ordered roles and provider kinds; per target
    type, the kind a grant edge lowers to; and the types not hosted yet."""

    var name: String
    var rows: List[ShapeRow]
    var grants: List[GrantRow]
    var not_yet: List[Absence]

    def __init__(
        out self,
        name: String,
        var rows: List[ShapeRow],
        var grants: List[GrantRow],
        var not_yet: List[Absence] = List[Absence](),
    ):
        self.name = name
        self.rows = rows^
        self.grants = grants^
        self.not_yet = not_yet^

    def __init__(out self, *, copy: Self):
        self.name = copy.name.copy()
        self.rows = copy.rows.copy()
        self.grants = copy.grants.copy()
        self.not_yet = copy.not_yet.copy()

    def hosts(self, field: Int) -> Bool:
        """False for a type the shape declares NOT_YET."""
        for i in range(len(self.not_yet)):
            if self.not_yet[i].field == field:
                return False
        return True

    def roles_of(self, field: Int) -> List[ShapeRow]:
        """The rows of `field`, in lowering order."""
        var out = List[ShapeRow]()
        for i in range(len(self.rows)):
            if self.rows[i].field == field:
                out.append(self.rows[i].copy())
        return out^

    def has(self, field: Int, role: String) -> Bool:
        for i in range(len(self.rows)):
            if self.rows[i].field == field and self.rows[i].role == role:
                return True
        return False

    def kind_of(self, field: Int, role: String) raises -> String:
        """The provider kind of `role` of `field`; raises for a role the
        shape does not have (a folded role has no kind)."""
        for i in range(len(self.rows)):
            if self.rows[i].field == field and self.rows[i].role == role:
                return self.rows[i].kind.copy()
        raise Error(
            String("shape \"")
            + self.name
            + String("\" has no role \"")
            + role
            + String("\" for field ")
            + String(field)
        )

    def grant_row(self, target: Int) -> Optional[GrantRow]:
        """The row for a grant edge to a target of type `target`: its own
        row, else the `TARGET_ANY` row, else None (the edge folds)."""
        for i in range(len(self.grants)):
            if self.grants[i].target == target:
                return self.grants[i].copy()
        for i in range(len(self.grants)):
            if self.grants[i].target == TARGET_ANY:
                return self.grants[i].copy()
        return None

    @staticmethod
    def generic() -> ProviderShape:
        var r = List[ShapeRow]()
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_IDENTITY), String("identity")))
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_RUN), String("run")))
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_PUBLIC), String("public")))
        r.append(ShapeRow(FIELD_JOB, String(ROLE_IDENTITY), String("identity")))
        r.append(ShapeRow(FIELD_JOB, String(ROLE_RUN), String("run")))
        r.append(ShapeRow(FIELD_JOB, String(ROLE_SCHEDULE), String("schedule")))
        r.append(ShapeRow(FIELD_TABLE, String(ROLE_TABLE), String("table")))
        r.append(ShapeRow(FIELD_BUCKET, String(ROLE_BUCKET), String("bucket")))
        r.append(ShapeRow(FIELD_SERVICE_ACCOUNT, String(ROLE_IDENTITY), String("identity")))
        r.append(ShapeRow(FIELD_QUEUE, String(ROLE_QUEUE), String("queue")))
        r.append(ShapeRow(FIELD_TOPIC, String(ROLE_TOPIC), String("topic")))
        r.append(ShapeRow(FIELD_SUBSCRIPTION, String(ROLE_SUB), String("subscription")))
        var g = List[GrantRow]()
        g.append(GrantRow(TARGET_ANY, String("grant"), String("")))
        return ProviderShape(String("generic"), r^, g^)

    @staticmethod
    def aws() -> ProviderShape:
        var r = List[ShapeRow]()
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_IDENTITY), String(_AWS_ROLE)))
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_RUN), String("AWS::Lambda::Function")))
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_PUBLIC), String("AWS::Lambda::Url")))
        r.append(ShapeRow(FIELD_JOB, String(ROLE_IDENTITY), String(_AWS_ROLE)))
        r.append(ShapeRow(FIELD_JOB, String(ROLE_RUN), String("AWS::ECS::TaskDefinition")))
        r.append(ShapeRow(FIELD_JOB, String(ROLE_SCHEDULE), String("AWS::Scheduler::Schedule")))
        r.append(ShapeRow(FIELD_TABLE, String(ROLE_TABLE), String("AWS::DynamoDB::Table")))
        r.append(ShapeRow(FIELD_BUCKET, String(ROLE_BUCKET), String("AWS::S3::Bucket")))
        r.append(ShapeRow(FIELD_SERVICE_ACCOUNT, String(ROLE_IDENTITY), String(_AWS_ROLE)))
        r.append(ShapeRow(FIELD_QUEUE, String(ROLE_QUEUE), String("AWS::SQS::Queue")))
        r.append(ShapeRow(FIELD_QUEUE, String(ROLE_POLICY), String("AWS::SQS::QueuePolicy")))
        r.append(ShapeRow(FIELD_TOPIC, String(ROLE_TOPIC), String("AWS::SNS::Topic")))
        r.append(ShapeRow(FIELD_SUBSCRIPTION, String(ROLE_SUB), String("AWS::SNS::Subscription")))
        var g = List[GrantRow]()
        g.append(GrantRow(FIELD_SERVICE, String("AWS::Lambda::Permission"), String("")))
        g.append(GrantRow(TARGET_ANY, String("AWS::IAM::RolePolicy"), String("")))
        return ProviderShape(String("aws"), r^, g^)

    @staticmethod
    def gcp() -> ProviderShape:
        var r = List[ShapeRow]()
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_IDENTITY), String(_GCP_SA)))
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_RUN), String("run.googleapis.com/Service")))
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_PUBLIC), String("setIamPolicy")))
        r.append(ShapeRow(FIELD_JOB, String(ROLE_IDENTITY), String(_GCP_SA)))
        r.append(ShapeRow(FIELD_JOB, String(ROLE_RUN), String("run.googleapis.com/Job")))
        r.append(
            ShapeRow(FIELD_JOB, String(ROLE_SCHEDULE), String("cloudscheduler.googleapis.com/Job"))
        )
        r.append(ShapeRow(FIELD_TABLE, String(ROLE_TABLE), String(_FIRESTORE_INDEX)))
        r.append(ShapeRow(FIELD_TABLE, String(ROLE_INDEX), String(_FIRESTORE_INDEX)))
        r.append(ShapeRow(FIELD_TABLE, String(ROLE_TTL), String("firestore.googleapis.com/Field")))
        r.append(ShapeRow(FIELD_BUCKET, String(ROLE_BUCKET), String("storage.googleapis.com/Bucket")))
        r.append(ShapeRow(FIELD_SERVICE_ACCOUNT, String(ROLE_IDENTITY), String(_GCP_SA)))
        r.append(ShapeRow(FIELD_QUEUE, String(ROLE_TOPIC), String(_PUBSUB_TOPIC)))
        r.append(ShapeRow(FIELD_QUEUE, String(ROLE_QUEUE), String(_PUBSUB_SUB)))
        r.append(ShapeRow(FIELD_TOPIC, String(ROLE_TOPIC), String(_PUBSUB_TOPIC)))
        r.append(ShapeRow(FIELD_SUBSCRIPTION, String(ROLE_SUB), String(_PUBSUB_SUB)))
        var g = List[GrantRow]()
        g.append(GrantRow(TARGET_ANY, String("setIamPolicy"), String("")))
        return ProviderShape(String("gcp"), r^, g^)

    @staticmethod
    def azure() -> ProviderShape:
        var r = List[ShapeRow]()
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_IDENTITY), String(_AZURE_ID)))
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_RUN), String("Microsoft.App/containerApps")))
        r.append(ShapeRow(FIELD_JOB, String(ROLE_IDENTITY), String(_AZURE_ID)))
        r.append(ShapeRow(FIELD_JOB, String(ROLE_RUN), String("Microsoft.App/jobs")))
        r.append(
            ShapeRow(
                FIELD_TABLE,
                String(ROLE_TABLE),
                String("Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers"),
            )
        )
        r.append(
            ShapeRow(
                FIELD_BUCKET,
                String(ROLE_BUCKET),
                String("Microsoft.Storage/storageAccounts/blobServices/containers"),
            )
        )
        r.append(ShapeRow(FIELD_SERVICE_ACCOUNT, String(ROLE_IDENTITY), String(_AZURE_ID)))
        r.append(ShapeRow(FIELD_QUEUE, String(ROLE_QUEUE), String("Microsoft.ServiceBus/namespaces/queues")))
        r.append(ShapeRow(FIELD_TOPIC, String(ROLE_TOPIC), String("Microsoft.ServiceBus/namespaces/topics")))
        r.append(
            ShapeRow(
                FIELD_SUBSCRIPTION,
                String(ROLE_SUB),
                String("Microsoft.ServiceBus/namespaces/topics/subscriptions"),
            )
        )
        var g = List[GrantRow]()
        g.append(
            GrantRow(
                FIELD_TABLE,
                String("Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments"),
                String(""),
            )
        )
        g.append(GrantRow(TARGET_ANY, String("Microsoft.Authorization/roleAssignments"), String("")))
        return ProviderShape(String("azure"), r^, g^)

    @staticmethod
    def onprem() -> ProviderShape:
        var r = List[ShapeRow]()
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_IDENTITY), String(_K8S_SA)))
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_VAULT), String(_VAULT_ROLE)))
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_RUN), String("apps/v1/Deployment")))
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_ENDPOINT), String("v1/Service")))
        r.append(
            ShapeRow(FIELD_SERVICE, String(ROLE_PUBLIC), String("networking.k8s.io/v1/Ingress"))
        )
        r.append(ShapeRow(FIELD_JOB, String(ROLE_IDENTITY), String(_K8S_SA)))
        r.append(ShapeRow(FIELD_JOB, String(ROLE_VAULT), String(_VAULT_ROLE)))
        r.append(ShapeRow(FIELD_JOB, String(ROLE_RUN), String("batch/v1/CronJob")))
        r.append(ShapeRow(FIELD_BUCKET, String(ROLE_BUCKET), String("minio/Bucket")))
        r.append(ShapeRow(FIELD_SERVICE_ACCOUNT, String(ROLE_IDENTITY), String(_K8S_SA)))
        r.append(ShapeRow(FIELD_SERVICE_ACCOUNT, String(ROLE_VAULT), String(_VAULT_ROLE)))
        var g = List[GrantRow]()
        g.append(GrantRow(FIELD_SERVICE, String(_K8S_BINDING), String(_K8S_ROLE)))
        g.append(GrantRow(FIELD_JOB, String(_K8S_BINDING), String(_K8S_ROLE)))
        g.append(GrantRow(FIELD_SERVICE_ACCOUNT, String(_K8S_BINDING), String(_K8S_ROLE)))
        g.append(GrantRow(FIELD_BUCKET, String("minio:policy"), String("")))
        var later = List[Absence]()
        later.append(Absence(FIELD_TABLE, NOT_YET, String(ONPREM_TABLE_REASON)))
        later.append(Absence(FIELD_QUEUE, NOT_YET, String(ONPREM_MESSAGING_REASON)))
        later.append(Absence(FIELD_TOPIC, NOT_YET, String(ONPREM_MESSAGING_REASON)))
        later.append(Absence(FIELD_SUBSCRIPTION, NOT_YET, String(ONPREM_MESSAGING_REASON)))
        return ProviderShape(String("onprem"), r^, g^, later^)


def builtin_shapes() -> List[ProviderShape]:
    """The built-in clouds, as data, in order: aws, gcp, azure, onprem."""
    var l = List[ProviderShape]()
    l.append(ProviderShape.aws())
    l.append(ProviderShape.gcp())
    l.append(ProviderShape.azure())
    l.append(ProviderShape.onprem())
    return l^


def shape_named(name: String) raises -> ProviderShape:
    """The built-in cloud called `name`; raises, naming the built-in list,
    for any other name (the match is exact: no case folding, no aliases)."""
    var shapes = builtin_shapes()
    var names = String("")
    for i in range(len(shapes)):
        if shapes[i].name == name:
            return shapes[i].copy()
        if i > 0:
            names += String(", ")
        names += shapes[i].name
    raise Error(
        String("\"") + name + String("\" is not a built-in cloud (the built-in clouds are ")
        + names + String(")")
    )
