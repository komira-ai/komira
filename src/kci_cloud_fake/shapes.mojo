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
# IDENTITY. Every shape has an `identity` row for each workload (a service, a
# container job, a worker) and a service account: the private identity of a
# workload (turned off under `run_as`), and the one object of a service
# account. The onprem shape
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
#                 container job -> identity, run; worker -> identity, run;
#                 table -> table; bucket -> bucket; service account ->
#                 identity; every grant -> `grant`.
#   * `aws`       service -> identity (AWS::IAM::Role), run
#                 (AWS::Lambda::Function), public (AWS::Lambda::Url);
#                 container job -> identity, run (AWS::ECS::TaskDefinition:
#                 each run is one RunTask of it, an execution, not a lowered
#                 object); worker -> identity, task
#                 (AWS::ECS::TaskDefinition: the container), run
#                 (AWS::ECS::Service: its replicas); table -> table
#                 (AWS::DynamoDB::Table: its indexes are GSIs and its TTL
#                 a setting, both inline); bucket -> bucket
#                 (AWS::S3::Bucket); service account -> identity
#                 (AWS::IAM::Role, trusted by the compute service only).
#                 Grants: on a service, the function's resource policy
#                 (AWS::Lambda::Permission); on anything else, an inline
#                 policy of the principal's role (AWS::IAM::RolePolicy).
#   * `gcp`       service -> identity (iam.googleapis.com/ServiceAccount), run
#                 (run.googleapis.com/Service), public (an invoker member
#                 binding); container job -> identity, run
#                 (run.googleapis.com/Job); worker -> identity, run
#                 (run.googleapis.com/WorkerPool); table ->
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
#                 (Microsoft.App/containerApps); container job -> identity,
#                 run (Microsoft.App/jobs); worker -> identity, run
#                 (Microsoft.App/containerApps, with no ingress); table -> table
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
#                 row: a container app's ingress is a setting of the run
#                 object, so it FOLDS into the run node's desired field
#                 `ingress` and is never a node of its own.
#   * `onprem`    the self-hosted cloud: Kubernetes + MinIO + Vault.
#                 service -> identity (v1/ServiceAccount), vault
#                 (vault:auth/kubernetes/role), run (apps/v1/Deployment),
#                 endpoint (v1/Service: the in-cluster address of the
#                 Deployment, always wanted), public
#                 (networking.k8s.io/v1/Ingress, which fronts the endpoint);
#                 container job -> identity, vault, run (batch/v1/CronJob,
#                 standing for the job's TEMPLATE: a run of it is a
#                 batch/v1/Job made from the template, an execution, not a
#                 lowered object); worker -> identity, vault, run
#                 (apps/v1/Deployment, with no Service in front); bucket ->
#                 bucket (minio/Bucket: an S3-API bucket on the cell's MinIO);
#                 service account -> identity, vault.
#                 Grants by the target's backing, one row per target type:
#                 a Kubernetes target (service, container job, service
#                 account) ->
#                 rbac.authorization.k8s.io/v1/RoleBinding with its helper
#                 rbac.authorization.k8s.io/v1/Role; a MinIO target (bucket)
#                 -> minio:policy (mapped to the service account's token
#                 claim); a Vault target (secret) -> vault:sys/policies/acl
#                 (a Vault ACL policy, attached to the principal's `vault`
#                 auth role). A cell resource has NO row: the edge folds
#                 into the identity (`cell.LOGS`).
#                 A TABLE IS NOT_YET on onprem: which datastore backs it is
#                 an open design question (Q17: PostgreSQL via
#                 CloudNativePG, CockroachDB, ScyllaDB or FoundationDB), so
#                 the shape declares it absent rather than pick one, and a
#                 graph with a table is refused on onprem before anything is
#                 lowered (a coverage finding naming the type and Q17).
#
# COMPUTE LIMITS, as data per shape (workloads.mojo refuses them at validate,
# as limits):
#   * `gpu_limit`: why no workload of the shape may ask for a GPU
#     (`Size.gpus` above 0), or empty where one may (generic). aws: a service
#     is a Lambda function, which runs on no GPU, and an ECS task (a container
#     job, a worker) has one only on a launch type with GPUs, which is not
#     decided. gcp, azure and onprem: which GPU each attaches to a workload
#     (and, on onprem, which device plugin offers it) is not decided. Each
#     shape takes none rather than pick one.
#   * `scale_to_zero_limit`: why a service there keeps one instance running
#     (a scale whose `min` is 0, written or by default, is refused), or empty
#     where a service scales to zero. onprem: a service is a plain Deployment
#     until the open question Q21 (a plain Deployment, Knative Serving or the
#     KEDA HTTP add-on) is answered.
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
# SECRET (secrets.mojo lowers it): one role on every shape, `secret`, the
# CONTAINER of a value (kci writes no value):
#   * `generic`   secret -> secret.
#   * `aws`       secret -> AWS::SecretsManager::Secret (created with no
#                 secret string, so it has no version).
#   * `gcp`       secret -> secretmanager.googleapis.com/Secret (a secret
#                 with no version).
#   * `azure`     secret -> Microsoft.KeyVault/vaults/secrets, in the cell's
#                 key vault (choosing another vault per secret is per-cloud
#                 tuning, held with every extension field).
#   * `onprem`    secret -> vault:kv-v2/metadata, a Vault KV v2 metadata
#                 entry on the cell's Vault: a value-less container, deleted
#                 with every version of its value. A grant to it is a Vault
#                 ACL policy (above).
# Every shape hosts it, so no shape declares it NOT_YET.
#
# NAMES (dns.mojo lowers them): a DNS zone has one role, `zone`; a DNS
# record one, `record`; a certificate `cert`, plus its validation helpers
# where they are objects of their own:
#   * `generic`   zone -> zone; record -> record; certificate -> cert.
#   * `aws`       zone -> AWS::Route53::HostedZone; record ->
#                 AWS::Route53::RecordSet; certificate ->
#                 AWS::CertificateManager::Certificate (DNS-validated in the
#                 zone; its validation records are written by the
#                 certificate's own validation settings, not as nodes).
#   * `gcp`       zone -> dns.googleapis.com/ManagedZone; record ->
#                 dns.googleapis.com/ResourceRecordSet; certificate ->
#                 dnsauth (certificatemanager.googleapis.com/DnsAuthorization,
#                 for the certificate's first name), authrec (the
#                 dns.googleapis.com/ResourceRecordSet that authorization
#                 asks for, in the zone) and cert
#                 (certificatemanager.googleapis.com/Certificate). The
#                 fake lowers ONE authorization per certificate (the
#                 cloud accepts several), and one authorization covers one
#                 name and its wildcard, so a certificate for any other
#                 name is a limit of this lowering.
#   * `azure`     zone -> Microsoft.Network/dnsZones; record ->
#                 Microsoft.Network/dnsZones/<TYPE> (the ARM type names the
#                 record type: `<TYPE>` is replaced by it, e.g.
#                 Microsoft.Network/dnsZones/CNAME); certificate ->
#                 Microsoft.App/managedEnvironments/managedCertificates, in
#                 the cell's environment. Such a certificate covers ONE name
#                 and no wildcard (`single_name_certificates`), so a
#                 certificate with more names, or a wildcard, is a limit.
#   * `onprem`    NOT_YET for all three: which DNS server an onprem cell
#                 owns (Q18) and which issuer signs its certificates (Q19)
#                 are open design questions, so the shape declares them
#                 absent rather than pick one.
#
# TRIGGERS (triggers.mojo lowers them): a schedule and an event trigger each
# have an `identity` (the private identity the cloud's scheduling or eventing
# service uses to reach the target: its one edge, CALL on the target, is
# lowered by the grant rows above) and one object, `schedule` or `trigger`:
#   * `generic`   schedule -> identity, schedule; event trigger -> identity,
#                 trigger.
#   * `aws`       schedule -> identity (AWS::IAM::Role, trusted by the
#                 scheduling service only), schedule
#                 (AWS::Scheduler::Schedule); event trigger -> identity
#                 (AWS::IAM::Role), trigger (AWS::Events::Rule, with the
#                 target in it). Its cron takes a day of the month or a day
#                 of the week, never both (`schedule_day_limit`).
#   * `gcp`       schedule -> identity (iam.googleapis.com/ServiceAccount),
#                 schedule (cloudscheduler.googleapis.com/Job); event trigger
#                 -> identity, trigger (eventarc.googleapis.com/Trigger).
#   * `azure`     schedule -> identity
#                 (Microsoft.ManagedIdentity/userAssignedIdentities), schedule
#                 (Microsoft.Logic/workflows, a recurrence); event trigger ->
#                 identity, trigger
#                 (Microsoft.EventGrid/systemTopics/eventSubscriptions, on the
#                 system topic of the cell's storage account). A schedule
#                 whose target is a CONTAINER JOB FOLDS (`schedule_folds`):
#                 it is the job's own schedule trigger, written into the
#                 job's run node (`schedule`, `cron`, `timezone`), and its
#                 identity, its CALL edge and its `schedule` node are lowered
#                 turned off. That schedule is read in UTC
#                 (`schedule_utc_limit`), and a job holds one.
#   * `onprem`    schedule -> identity (v1/ServiceAccount), schedule
#                 (batch/v1/CronJob: a caller that calls a service). A
#                 schedule whose target is a container job FOLDS into the
#                 job's CronJob as on azure (its `suspend` lifts and it gets
#                 the cron and the time zone), so a job holds one; a schedule
#                 that calls a SERVICE is a limit (`schedule_call_limit`):
#                 the caller image the cell pins is an open question (Q28).
#                 An EVENT TRIGGER IS NOT_YET: its event plumbing is an open
#                 question (Q22).
#
# NETWORKS (network.mojo lowers them): a network has one role, `network`; a
# subnet one, `subnet`; an IP address one, `address`:
#   * `generic`   network -> network; subnet -> subnet; IP address ->
#                 address.
#   * `aws`       network -> AWS::EC2::VPC; subnet -> AWS::EC2::Subnet (in
#                 one availability zone, so a subnet names its zone:
#                 `subnet_zone_limit`); IP address -> AWS::EC2::EIP.
#   * `gcp`       network -> compute.googleapis.com/Network (holding no range
#                 of its own, with no automatic subnets: `network_ranged`
#                 False); subnet -> compute.googleapis.com/Subnetwork (in
#                 the region, every zone); IP address ->
#                 compute.googleapis.com/Address (regional, external).
#   * `azure`     network -> Microsoft.Network/virtualNetworks; subnet ->
#                 Microsoft.Network/virtualNetworks/subnets (in the region);
#                 IP address -> Microsoft.Network/publicIPAddresses. A
#                 container app joins a network through the cell's
#                 environment, never one app at a time, so a service's
#                 `network` is a limit (`service_network_limit`).
#   * `onprem`    NOT_YET for all three: which backing an onprem cell has
#                 for an address space and a reserved address is an open
#                 question (Q23), so the shape declares them absent rather
#                 than pick one. A service's `network` names a subnet, so it
#                 is refused with the subnet.
# A service's `network` lowers to an input of its run node on the subnet's
# NAME, on every shape that takes it.
#
# REGISTRY (registry.mojo lowers it): one role, `registry`, the object that
# holds the artifacts; a grant to it (WRITE: push, READ: pull) is the
# shape's grant kind for any target:
#   * `generic`   registry -> registry.
#   * `aws`       registry -> AWS::ECR::Repository (an image repository;
#                 grants are inline policies of the principal's role).
#   * `gcp`       registry -> artifactregistry.googleapis.com/Repository (a
#                 Docker-format repository; grants are member bindings on it).
#   * `azure`     registry -> Microsoft.ContainerRegistry/registries (its
#                 repositories are implicit, so the registry is the object;
#                 grants are role assignments on it).
#   * `onprem`    NOT_YET: which registry an onprem cell runs is an open
#                 question (Q24), so the shape declares it absent rather than
#                 pick one.
#
# METADATA (metadata.mojo): per shape, how many labels an object carries and
# how each type's primary object may be named (`metadata`, a
# `MetadataLimits`): generic none, aws, gcp, azure and onprem their own.
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
    FIELD_CERTIFICATE,
    FIELD_DNS_RECORD,
    FIELD_DNS_ZONE,
    FIELD_CONTAINER_JOB,
    FIELD_EVENT_TRIGGER,
    FIELD_IP_ADDRESS,
    FIELD_NETWORK,
    FIELD_QUEUE,
    FIELD_REGISTRY,
    FIELD_SCHEDULE,
    FIELD_SECRET,
    FIELD_SERVICE,
    FIELD_SERVICE_ACCOUNT,
    FIELD_SUBNET,
    FIELD_SUBSCRIPTION,
    FIELD_TABLE,
    FIELD_TOPIC,
    FIELD_WORKER,
    NOT_YET,
)

from kci_cloud_fake.metadata import MetadataLimits


comptime ROLE_BUCKET = "bucket"
comptime ROLE_TABLE = "table"
comptime ROLE_INDEX = "ix"
"""A shape row meaning "each secondary index is a node of its own", role
`ix-<h>` (`kci_cloud.index_role`); never a role itself."""
comptime ROLE_TTL = "ttl"
comptime ROLE_IDENTITY = "identity"
comptime ROLE_RUN = "run"
comptime ROLE_PUBLIC = "public"
comptime ROLE_TASK = "task"
"""A worker's container definition where it is an object of its own (aws:
the task definition its service runs)."""
comptime ROLE_ENDPOINT = "endpoint"
comptime ROLE_VAULT = "vault"
comptime ROLE_QUEUE = "queue"
comptime ROLE_TOPIC = "topic"
comptime ROLE_SUB = "sub"
comptime ROLE_SECRET = "secret"
comptime ROLE_ZONE = "zone"
comptime ROLE_RECORD = "record"
comptime ROLE_CERT = "cert"
comptime ROLE_DNS_AUTH = "dnsauth"
"""gcp: the DNS authorization a certificate is validated by."""
comptime ROLE_AUTH_RECORD = "authrec"
"""gcp: the record that DNS authorization asks for, in the zone."""
comptime RECORD_TYPE_SLOT = "<TYPE>"
"""In a record row's kind, replaced by the record's type."""
comptime ROLE_POLICY = "policy"
"""aws: the queue policy that lets the topics feeding a queue send to it."""
comptime ROLE_SCHEDULE = "schedule"
comptime ROLE_TRIGGER = "trigger"
comptime ROLE_NETWORK = "network"
comptime ROLE_SUBNET = "subnet"
comptime ROLE_ADDRESS = "address"
comptime ROLE_REGISTRY = "registry"
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
comptime _CLOUD_DNS_RECORD = "dns.googleapis.com/ResourceRecordSet"
comptime _ECS_TASK = "AWS::ECS::TaskDefinition"
comptime ONPREM_MESSAGING_REASON = (
    "the onprem message backing of a queue, a topic and a subscription is an"
    " open question (Q16: RabbitMQ, NATS JetStream, Apache Kafka or Redis"
    " Streams)"
)
comptime ONPREM_DNS_REASON = (
    "the onprem DNS server that holds a zone and its records is an open"
    " question (Q18: PowerDNS, CoreDNS, ExternalDNS with PowerDNS or RFC 2136,"
    " or the customer's own DNS)"
)
comptime ONPREM_CERTIFICATE_REASON = (
    "the onprem issuer of a managed certificate is an open question (Q19:"
    " cert-manager with an ACME issuer, a Vault PKI issuer, the customer's CA,"
    " or step-ca)"
)
comptime GPU_REASON_AWS = (
    "a service here is a Lambda function, which runs on no GPU, and an ECS"
    " task (a container job, a worker) has one only on a launch type with"
    " GPUs, which is not decided yet"
)
comptime GPU_REASON_UNDECIDED = (
    "which GPU this cloud attaches to a workload is not decided yet (a design"
    " decision that is still open), so no workload may ask for one"
)
comptime ONPREM_SCALE_TO_ZERO_REASON = (
    "a service is a plain Deployment, which keeps at least one instance:"
    " whether scaling to zero is part of a service's meaning is an open"
    " question (Q21: a plain Deployment, Knative Serving or the KEDA HTTP"
    " add-on)"
)
comptime SCHEDULE_DAY_REASON_AWS = (
    "EventBridge Scheduler's cron takes a day of the month or a day of the week, never both"
)
comptime SCHEDULE_UTC_REASON_AZURE = (
    "a container app job's schedule is a cron read in UTC, with no time zone of its own"
)
comptime ONPREM_SCHEDULE_CALL_REASON = (
    "a schedule that calls a service runs a caller image the cell pins, and what an onprem"
    " cell installs at bootstrap is an open question (Q28)"
)
comptime ONPREM_EVENT_TRIGGER_REASON = (
    "the onprem event plumbing of an event trigger is an open question (Q22: MinIO bucket"
    " notifications through the Q16 message backing and a dispatcher, Knative Eventing, or"
    " Argo Events)"
)
comptime SUBNET_ZONE_REASON_AWS = "an EC2 subnet is in one availability zone"
comptime SERVICE_NETWORK_REASON_AZURE = (
    "a container app joins a network through its environment, which the cell holds, never one app at a time"
)
comptime ONPREM_NETWORK_REASON = (
    "the onprem backing of a network, a subnet and an IP address is an open question (Q23: a Namespace"
    " with a default-deny NetworkPolicy, which has no address space; Kube-OVN VPCs and subnets; Cilium;"
    " a MetalLB or LB-IPAM address pool for an IP address)"
)
comptime ONPREM_REGISTRY_REASON = (
    "the onprem registry that holds a registry's artifacts is an open question (Q24: Harbor, Sonatype"
    " Nexus or JFrog Artifactory, Zot or the CNCF Distribution registry, or Gitea packages)"
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
    var single_name_certificates: Bool
    """A certificate covers one name and no wildcard on this shape."""
    var gpu_limit: String
    """Why no workload here may ask for a GPU; empty where one may."""
    var scale_to_zero_limit: String
    """Why a service here keeps one instance; empty where it scales to
    zero."""
    var schedule_folds: Bool
    """A schedule whose target is a container job is a setting of the job's
    own object here."""
    var schedule_day_limit: String
    """Why a cron here cannot name both a day of the month and a day of the
    week; empty where it can."""
    var schedule_utc_limit: String
    """Why a folded schedule here is read in UTC; empty where it takes a
    time zone."""
    var schedule_call_limit: String
    """Why a schedule here cannot call a service; empty where it can."""
    var network_ranged: Bool
    """The network object holds its IPv4 range here (else only its subnets
    do)."""
    var subnet_zone_limit: String
    """Why a subnet here names its zone (it is in one zone); empty where a
    subnet spans the region."""
    var service_network_limit: String
    """Why a service here cannot be placed in a subnet; empty where it
    can."""
    var metadata: MetadataLimits
    """How many labels an object carries here, and how a type's primary
    object may be named (metadata.mojo)."""

    def __init__(
        out self,
        name: String,
        var rows: List[ShapeRow],
        var grants: List[GrantRow],
        var not_yet: List[Absence] = List[Absence](),
        single_name_certificates: Bool = False,
        gpu_limit: String = String(""),
        scale_to_zero_limit: String = String(""),
        schedule_folds: Bool = False,
        schedule_day_limit: String = String(""),
        schedule_utc_limit: String = String(""),
        schedule_call_limit: String = String(""),
        network_ranged: Bool = True,
        subnet_zone_limit: String = String(""),
        service_network_limit: String = String(""),
        var metadata: MetadataLimits = MetadataLimits(),
    ):
        self.name = name
        self.rows = rows^
        self.grants = grants^
        self.not_yet = not_yet^
        self.single_name_certificates = single_name_certificates
        self.gpu_limit = gpu_limit
        self.scale_to_zero_limit = scale_to_zero_limit
        self.schedule_folds = schedule_folds
        self.schedule_day_limit = schedule_day_limit
        self.schedule_utc_limit = schedule_utc_limit
        self.schedule_call_limit = schedule_call_limit
        self.network_ranged = network_ranged
        self.subnet_zone_limit = subnet_zone_limit
        self.service_network_limit = service_network_limit
        self.metadata = metadata^

    def __init__(out self, *, copy: Self):
        self.name = copy.name.copy()
        self.rows = copy.rows.copy()
        self.grants = copy.grants.copy()
        self.not_yet = copy.not_yet.copy()
        self.single_name_certificates = copy.single_name_certificates
        self.gpu_limit = copy.gpu_limit.copy()
        self.scale_to_zero_limit = copy.scale_to_zero_limit.copy()
        self.schedule_folds = copy.schedule_folds
        self.schedule_day_limit = copy.schedule_day_limit.copy()
        self.schedule_utc_limit = copy.schedule_utc_limit.copy()
        self.schedule_call_limit = copy.schedule_call_limit.copy()
        self.network_ranged = copy.network_ranged
        self.subnet_zone_limit = copy.subnet_zone_limit.copy()
        self.service_network_limit = copy.service_network_limit.copy()
        self.metadata = copy.metadata.copy()

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
        r.append(ShapeRow(FIELD_CONTAINER_JOB, String(ROLE_IDENTITY), String("identity")))
        r.append(ShapeRow(FIELD_CONTAINER_JOB, String(ROLE_RUN), String("run")))
        r.append(ShapeRow(FIELD_WORKER, String(ROLE_IDENTITY), String("identity")))
        r.append(ShapeRow(FIELD_WORKER, String(ROLE_RUN), String("run")))
        r.append(ShapeRow(FIELD_TABLE, String(ROLE_TABLE), String("table")))
        r.append(ShapeRow(FIELD_BUCKET, String(ROLE_BUCKET), String("bucket")))
        r.append(ShapeRow(FIELD_SERVICE_ACCOUNT, String(ROLE_IDENTITY), String("identity")))
        r.append(ShapeRow(FIELD_QUEUE, String(ROLE_QUEUE), String("queue")))
        r.append(ShapeRow(FIELD_TOPIC, String(ROLE_TOPIC), String("topic")))
        r.append(ShapeRow(FIELD_SUBSCRIPTION, String(ROLE_SUB), String("subscription")))
        r.append(ShapeRow(FIELD_SECRET, String(ROLE_SECRET), String("secret")))
        r.append(ShapeRow(FIELD_DNS_ZONE, String(ROLE_ZONE), String("zone")))
        r.append(ShapeRow(FIELD_DNS_RECORD, String(ROLE_RECORD), String("record")))
        r.append(ShapeRow(FIELD_CERTIFICATE, String(ROLE_CERT), String("certificate")))
        r.append(ShapeRow(FIELD_SCHEDULE, String(ROLE_IDENTITY), String("identity")))
        r.append(ShapeRow(FIELD_SCHEDULE, String(ROLE_SCHEDULE), String("schedule")))
        r.append(ShapeRow(FIELD_EVENT_TRIGGER, String(ROLE_IDENTITY), String("identity")))
        r.append(ShapeRow(FIELD_EVENT_TRIGGER, String(ROLE_TRIGGER), String("trigger")))
        r.append(ShapeRow(FIELD_NETWORK, String(ROLE_NETWORK), String("network")))
        r.append(ShapeRow(FIELD_SUBNET, String(ROLE_SUBNET), String("subnet")))
        r.append(ShapeRow(FIELD_IP_ADDRESS, String(ROLE_ADDRESS), String("address")))
        r.append(ShapeRow(FIELD_REGISTRY, String(ROLE_REGISTRY), String("registry")))
        var g = List[GrantRow]()
        g.append(GrantRow(TARGET_ANY, String("grant"), String("")))
        return ProviderShape(String("generic"), r^, g^)

    @staticmethod
    def aws() -> ProviderShape:
        var r = List[ShapeRow]()
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_IDENTITY), String(_AWS_ROLE)))
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_RUN), String("AWS::Lambda::Function")))
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_PUBLIC), String("AWS::Lambda::Url")))
        r.append(ShapeRow(FIELD_CONTAINER_JOB, String(ROLE_IDENTITY), String(_AWS_ROLE)))
        r.append(ShapeRow(FIELD_CONTAINER_JOB, String(ROLE_RUN), String(_ECS_TASK)))
        r.append(ShapeRow(FIELD_WORKER, String(ROLE_IDENTITY), String(_AWS_ROLE)))
        r.append(ShapeRow(FIELD_WORKER, String(ROLE_TASK), String(_ECS_TASK)))
        r.append(ShapeRow(FIELD_WORKER, String(ROLE_RUN), String("AWS::ECS::Service")))
        r.append(ShapeRow(FIELD_TABLE, String(ROLE_TABLE), String("AWS::DynamoDB::Table")))
        r.append(ShapeRow(FIELD_BUCKET, String(ROLE_BUCKET), String("AWS::S3::Bucket")))
        r.append(ShapeRow(FIELD_SERVICE_ACCOUNT, String(ROLE_IDENTITY), String(_AWS_ROLE)))
        r.append(ShapeRow(FIELD_QUEUE, String(ROLE_QUEUE), String("AWS::SQS::Queue")))
        r.append(ShapeRow(FIELD_QUEUE, String(ROLE_POLICY), String("AWS::SQS::QueuePolicy")))
        r.append(ShapeRow(FIELD_TOPIC, String(ROLE_TOPIC), String("AWS::SNS::Topic")))
        r.append(ShapeRow(FIELD_SUBSCRIPTION, String(ROLE_SUB), String("AWS::SNS::Subscription")))
        r.append(ShapeRow(FIELD_SECRET, String(ROLE_SECRET), String("AWS::SecretsManager::Secret")))
        r.append(ShapeRow(FIELD_DNS_ZONE, String(ROLE_ZONE), String("AWS::Route53::HostedZone")))
        r.append(ShapeRow(FIELD_DNS_RECORD, String(ROLE_RECORD), String("AWS::Route53::RecordSet")))
        r.append(
            ShapeRow(FIELD_CERTIFICATE, String(ROLE_CERT), String("AWS::CertificateManager::Certificate"))
        )
        r.append(ShapeRow(FIELD_SCHEDULE, String(ROLE_IDENTITY), String(_AWS_ROLE)))
        r.append(ShapeRow(FIELD_SCHEDULE, String(ROLE_SCHEDULE), String("AWS::Scheduler::Schedule")))
        r.append(ShapeRow(FIELD_EVENT_TRIGGER, String(ROLE_IDENTITY), String(_AWS_ROLE)))
        r.append(ShapeRow(FIELD_EVENT_TRIGGER, String(ROLE_TRIGGER), String("AWS::Events::Rule")))
        r.append(ShapeRow(FIELD_NETWORK, String(ROLE_NETWORK), String("AWS::EC2::VPC")))
        r.append(ShapeRow(FIELD_SUBNET, String(ROLE_SUBNET), String("AWS::EC2::Subnet")))
        r.append(ShapeRow(FIELD_IP_ADDRESS, String(ROLE_ADDRESS), String("AWS::EC2::EIP")))
        r.append(ShapeRow(FIELD_REGISTRY, String(ROLE_REGISTRY), String("AWS::ECR::Repository")))
        var g = List[GrantRow]()
        g.append(GrantRow(FIELD_SERVICE, String("AWS::Lambda::Permission"), String("")))
        g.append(GrantRow(TARGET_ANY, String("AWS::IAM::RolePolicy"), String("")))
        return ProviderShape(
            String("aws"),
            r^,
            g^,
            gpu_limit=String(GPU_REASON_AWS),
            schedule_day_limit=String(SCHEDULE_DAY_REASON_AWS),
            subnet_zone_limit=String(SUBNET_ZONE_REASON_AWS),
            metadata=MetadataLimits.aws(),
        )

    @staticmethod
    def gcp() -> ProviderShape:
        var r = List[ShapeRow]()
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_IDENTITY), String(_GCP_SA)))
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_RUN), String("run.googleapis.com/Service")))
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_PUBLIC), String("setIamPolicy")))
        r.append(ShapeRow(FIELD_CONTAINER_JOB, String(ROLE_IDENTITY), String(_GCP_SA)))
        r.append(ShapeRow(FIELD_CONTAINER_JOB, String(ROLE_RUN), String("run.googleapis.com/Job")))
        r.append(ShapeRow(FIELD_WORKER, String(ROLE_IDENTITY), String(_GCP_SA)))
        r.append(ShapeRow(FIELD_WORKER, String(ROLE_RUN), String("run.googleapis.com/WorkerPool")))
        r.append(ShapeRow(FIELD_TABLE, String(ROLE_TABLE), String(_FIRESTORE_INDEX)))
        r.append(ShapeRow(FIELD_TABLE, String(ROLE_INDEX), String(_FIRESTORE_INDEX)))
        r.append(ShapeRow(FIELD_TABLE, String(ROLE_TTL), String("firestore.googleapis.com/Field")))
        r.append(ShapeRow(FIELD_BUCKET, String(ROLE_BUCKET), String("storage.googleapis.com/Bucket")))
        r.append(ShapeRow(FIELD_SERVICE_ACCOUNT, String(ROLE_IDENTITY), String(_GCP_SA)))
        r.append(ShapeRow(FIELD_QUEUE, String(ROLE_TOPIC), String(_PUBSUB_TOPIC)))
        r.append(ShapeRow(FIELD_QUEUE, String(ROLE_QUEUE), String(_PUBSUB_SUB)))
        r.append(ShapeRow(FIELD_TOPIC, String(ROLE_TOPIC), String(_PUBSUB_TOPIC)))
        r.append(ShapeRow(FIELD_SUBSCRIPTION, String(ROLE_SUB), String(_PUBSUB_SUB)))
        r.append(ShapeRow(FIELD_SECRET, String(ROLE_SECRET), String("secretmanager.googleapis.com/Secret")))
        r.append(ShapeRow(FIELD_DNS_ZONE, String(ROLE_ZONE), String("dns.googleapis.com/ManagedZone")))
        r.append(ShapeRow(FIELD_DNS_RECORD, String(ROLE_RECORD), String(_CLOUD_DNS_RECORD)))
        r.append(
            ShapeRow(
                FIELD_CERTIFICATE, String(ROLE_DNS_AUTH), String("certificatemanager.googleapis.com/DnsAuthorization")
            )
        )
        r.append(ShapeRow(FIELD_CERTIFICATE, String(ROLE_AUTH_RECORD), String(_CLOUD_DNS_RECORD)))
        r.append(
            ShapeRow(FIELD_CERTIFICATE, String(ROLE_CERT), String("certificatemanager.googleapis.com/Certificate"))
        )
        r.append(ShapeRow(FIELD_SCHEDULE, String(ROLE_IDENTITY), String(_GCP_SA)))
        r.append(ShapeRow(FIELD_SCHEDULE, String(ROLE_SCHEDULE), String("cloudscheduler.googleapis.com/Job")))
        r.append(ShapeRow(FIELD_EVENT_TRIGGER, String(ROLE_IDENTITY), String(_GCP_SA)))
        r.append(ShapeRow(FIELD_EVENT_TRIGGER, String(ROLE_TRIGGER), String("eventarc.googleapis.com/Trigger")))
        r.append(ShapeRow(FIELD_NETWORK, String(ROLE_NETWORK), String("compute.googleapis.com/Network")))
        r.append(ShapeRow(FIELD_SUBNET, String(ROLE_SUBNET), String("compute.googleapis.com/Subnetwork")))
        r.append(ShapeRow(FIELD_IP_ADDRESS, String(ROLE_ADDRESS), String("compute.googleapis.com/Address")))
        r.append(ShapeRow(FIELD_REGISTRY, String(ROLE_REGISTRY), String("artifactregistry.googleapis.com/Repository")))
        var g = List[GrantRow]()
        g.append(GrantRow(TARGET_ANY, String("setIamPolicy"), String("")))
        return ProviderShape(
            String("gcp"),
            r^,
            g^,
            gpu_limit=String(GPU_REASON_UNDECIDED),
            network_ranged=False,
            metadata=MetadataLimits.gcp(),
        )

    @staticmethod
    def azure() -> ProviderShape:
        var r = List[ShapeRow]()
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_IDENTITY), String(_AZURE_ID)))
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_RUN), String("Microsoft.App/containerApps")))
        r.append(ShapeRow(FIELD_CONTAINER_JOB, String(ROLE_IDENTITY), String(_AZURE_ID)))
        r.append(ShapeRow(FIELD_CONTAINER_JOB, String(ROLE_RUN), String("Microsoft.App/jobs")))
        r.append(ShapeRow(FIELD_WORKER, String(ROLE_IDENTITY), String(_AZURE_ID)))
        r.append(ShapeRow(FIELD_WORKER, String(ROLE_RUN), String("Microsoft.App/containerApps")))
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
        r.append(ShapeRow(FIELD_SECRET, String(ROLE_SECRET), String("Microsoft.KeyVault/vaults/secrets")))
        r.append(ShapeRow(FIELD_DNS_ZONE, String(ROLE_ZONE), String("Microsoft.Network/dnsZones")))
        r.append(
            ShapeRow(
                FIELD_DNS_RECORD, String(ROLE_RECORD), String("Microsoft.Network/dnsZones/") + String(RECORD_TYPE_SLOT)
            )
        )
        r.append(
            ShapeRow(
                FIELD_CERTIFICATE,
                String(ROLE_CERT),
                String("Microsoft.App/managedEnvironments/managedCertificates"),
            )
        )
        r.append(ShapeRow(FIELD_SCHEDULE, String(ROLE_IDENTITY), String(_AZURE_ID)))
        r.append(ShapeRow(FIELD_SCHEDULE, String(ROLE_SCHEDULE), String("Microsoft.Logic/workflows")))
        r.append(ShapeRow(FIELD_EVENT_TRIGGER, String(ROLE_IDENTITY), String(_AZURE_ID)))
        r.append(
            ShapeRow(
                FIELD_EVENT_TRIGGER,
                String(ROLE_TRIGGER),
                String("Microsoft.EventGrid/systemTopics/eventSubscriptions"),
            )
        )
        r.append(ShapeRow(FIELD_NETWORK, String(ROLE_NETWORK), String("Microsoft.Network/virtualNetworks")))
        r.append(ShapeRow(FIELD_SUBNET, String(ROLE_SUBNET), String("Microsoft.Network/virtualNetworks/subnets")))
        r.append(ShapeRow(FIELD_IP_ADDRESS, String(ROLE_ADDRESS), String("Microsoft.Network/publicIPAddresses")))
        r.append(ShapeRow(FIELD_REGISTRY, String(ROLE_REGISTRY), String("Microsoft.ContainerRegistry/registries")))
        var g = List[GrantRow]()
        g.append(
            GrantRow(
                FIELD_TABLE,
                String("Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments"),
                String(""),
            )
        )
        g.append(GrantRow(TARGET_ANY, String("Microsoft.Authorization/roleAssignments"), String("")))
        return ProviderShape(
            String("azure"),
            r^,
            g^,
            single_name_certificates=True,
            gpu_limit=String(GPU_REASON_UNDECIDED),
            schedule_folds=True,
            schedule_utc_limit=String(SCHEDULE_UTC_REASON_AZURE),
            service_network_limit=String(SERVICE_NETWORK_REASON_AZURE),
            metadata=MetadataLimits.azure(),
        )

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
        r.append(ShapeRow(FIELD_CONTAINER_JOB, String(ROLE_IDENTITY), String(_K8S_SA)))
        r.append(ShapeRow(FIELD_CONTAINER_JOB, String(ROLE_VAULT), String(_VAULT_ROLE)))
        r.append(ShapeRow(FIELD_CONTAINER_JOB, String(ROLE_RUN), String("batch/v1/CronJob")))
        r.append(ShapeRow(FIELD_WORKER, String(ROLE_IDENTITY), String(_K8S_SA)))
        r.append(ShapeRow(FIELD_WORKER, String(ROLE_VAULT), String(_VAULT_ROLE)))
        r.append(ShapeRow(FIELD_WORKER, String(ROLE_RUN), String("apps/v1/Deployment")))
        r.append(ShapeRow(FIELD_BUCKET, String(ROLE_BUCKET), String("minio/Bucket")))
        r.append(ShapeRow(FIELD_SERVICE_ACCOUNT, String(ROLE_IDENTITY), String(_K8S_SA)))
        r.append(ShapeRow(FIELD_SERVICE_ACCOUNT, String(ROLE_VAULT), String(_VAULT_ROLE)))
        r.append(ShapeRow(FIELD_SECRET, String(ROLE_SECRET), String("vault:kv-v2/metadata")))
        r.append(ShapeRow(FIELD_SCHEDULE, String(ROLE_IDENTITY), String(_K8S_SA)))
        r.append(ShapeRow(FIELD_SCHEDULE, String(ROLE_SCHEDULE), String("batch/v1/CronJob")))
        var g = List[GrantRow]()
        g.append(GrantRow(FIELD_SERVICE, String(_K8S_BINDING), String(_K8S_ROLE)))
        g.append(GrantRow(FIELD_CONTAINER_JOB, String(_K8S_BINDING), String(_K8S_ROLE)))
        g.append(GrantRow(FIELD_SERVICE_ACCOUNT, String(_K8S_BINDING), String(_K8S_ROLE)))
        g.append(GrantRow(FIELD_BUCKET, String("minio:policy"), String("")))
        g.append(GrantRow(FIELD_SECRET, String("vault:sys/policies/acl"), String("")))
        var later = List[Absence]()
        later.append(Absence(FIELD_TABLE, NOT_YET, String(ONPREM_TABLE_REASON)))
        later.append(Absence(FIELD_QUEUE, NOT_YET, String(ONPREM_MESSAGING_REASON)))
        later.append(Absence(FIELD_TOPIC, NOT_YET, String(ONPREM_MESSAGING_REASON)))
        later.append(Absence(FIELD_SUBSCRIPTION, NOT_YET, String(ONPREM_MESSAGING_REASON)))
        later.append(Absence(FIELD_DNS_ZONE, NOT_YET, String(ONPREM_DNS_REASON)))
        later.append(Absence(FIELD_DNS_RECORD, NOT_YET, String(ONPREM_DNS_REASON)))
        later.append(Absence(FIELD_CERTIFICATE, NOT_YET, String(ONPREM_CERTIFICATE_REASON)))
        later.append(Absence(FIELD_EVENT_TRIGGER, NOT_YET, String(ONPREM_EVENT_TRIGGER_REASON)))
        for f in [FIELD_NETWORK, FIELD_SUBNET, FIELD_IP_ADDRESS]:
            later.append(Absence(f, NOT_YET, String(ONPREM_NETWORK_REASON)))
        later.append(Absence(FIELD_REGISTRY, NOT_YET, String(ONPREM_REGISTRY_REASON)))
        return ProviderShape(
            String("onprem"),
            r^,
            g^,
            later^,
            gpu_limit=String(GPU_REASON_UNDECIDED),
            scale_to_zero_limit=String(ONPREM_SCALE_TO_ZERO_REASON),
            schedule_folds=True,
            schedule_call_limit=String(ONPREM_SCHEDULE_CALL_REASON),
            metadata=MetadataLimits.onprem(),
        )


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
