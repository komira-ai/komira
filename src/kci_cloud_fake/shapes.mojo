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
#                 job -> identity, run, schedule; bucket -> bucket; service
#                 account -> identity; every grant -> `grant`.
#   * `aws`       service -> identity (AWS::IAM::Role), run
#                 (AWS::Lambda::Function), public (AWS::Lambda::Url);
#                 job -> identity, run (AWS::ECS::TaskDefinition), schedule
#                 (AWS::Scheduler::Schedule); bucket -> bucket
#                 (AWS::S3::Bucket); service account -> identity
#                 (AWS::IAM::Role, trusted by the compute service only).
#                 Grants: on a service, the function's resource policy
#                 (AWS::Lambda::Permission); on anything else, an inline
#                 policy of the principal's role (AWS::IAM::RolePolicy).
#   * `gcp`       service -> identity (iam.googleapis.com/ServiceAccount), run
#                 (run.googleapis.com/Service), public (an invoker member
#                 binding); job -> identity, run (run.googleapis.com/Job),
#                 schedule (cloudscheduler.googleapis.com/Job); bucket ->
#                 bucket (storage.googleapis.com/Bucket); service account ->
#                 identity. Every grant is a member binding on its target.
#                 GCP has no asset type for one binding: the kind id names
#                 the call that writes it, `setIamPolicy`.
#   * `azure`     service -> identity
#                 (Microsoft.ManagedIdentity/userAssignedIdentities), run
#                 (Microsoft.App/containerApps); job -> identity, run
#                 (Microsoft.App/jobs); bucket -> bucket
#                 (Microsoft.Storage/storageAccounts/blobServices/containers,
#                 in the cell's storage account); service account ->
#                 identity. Every grant is a
#                 Microsoft.Authorization/roleAssignments. There is NO public
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
# as nobody, it is only granted to. A grant resource has no row: its roles
# are its edge's (`grant`, and `rules` where the row names a helper).
#
# A shape is chosen by the constructor of a fake cloud, never from the
# cloud's id: the id stays opaque.
# =============================================================================

from kci_cloud import (
    FIELD_BUCKET,
    FIELD_JOB,
    FIELD_SERVICE,
    FIELD_SERVICE_ACCOUNT,
)


comptime ROLE_BUCKET = "bucket"
comptime ROLE_IDENTITY = "identity"
comptime ROLE_RUN = "run"
comptime ROLE_PUBLIC = "public"
comptime ROLE_SCHEDULE = "schedule"
comptime ROLE_ENDPOINT = "endpoint"
comptime ROLE_VAULT = "vault"
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
    type, the kind a grant edge lowers to."""

    var name: String
    var rows: List[ShapeRow]
    var grants: List[GrantRow]

    def __init__(out self, name: String, var rows: List[ShapeRow], var grants: List[GrantRow]):
        self.name = name
        self.rows = rows^
        self.grants = grants^

    def __init__(out self, *, copy: Self):
        self.name = copy.name.copy()
        self.rows = copy.rows.copy()
        self.grants = copy.grants.copy()

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
        r.append(ShapeRow(FIELD_BUCKET, String(ROLE_BUCKET), String("bucket")))
        r.append(ShapeRow(FIELD_SERVICE_ACCOUNT, String(ROLE_IDENTITY), String("identity")))
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
        r.append(ShapeRow(FIELD_BUCKET, String(ROLE_BUCKET), String("AWS::S3::Bucket")))
        r.append(ShapeRow(FIELD_SERVICE_ACCOUNT, String(ROLE_IDENTITY), String(_AWS_ROLE)))
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
        r.append(ShapeRow(FIELD_BUCKET, String(ROLE_BUCKET), String("storage.googleapis.com/Bucket")))
        r.append(ShapeRow(FIELD_SERVICE_ACCOUNT, String(ROLE_IDENTITY), String(_GCP_SA)))
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
                FIELD_BUCKET,
                String(ROLE_BUCKET),
                String("Microsoft.Storage/storageAccounts/blobServices/containers"),
            )
        )
        r.append(ShapeRow(FIELD_SERVICE_ACCOUNT, String(ROLE_IDENTITY), String(_AZURE_ID)))
        var g = List[GrantRow]()
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
        return ProviderShape(String("onprem"), r^, g^)


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
