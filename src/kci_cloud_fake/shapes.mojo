# =============================================================================
# kci_cloud_fake/shapes.mojo: the provider shapes a fake cloud can lower to.
# =============================================================================
#
# A primitive is 1:1 with a resource kind of the major clouds, and each cloud
# lowers it to its OWN fixed set of roles. A `ProviderShape` is that set, as
# data: per catalog field, the ordered roles the type lowers to, each with
# the provider kind id it stands for (the CloudFormation type, the GCP asset
# or API type, the ARM type, the Kubernetes apiVersion/kind), plus the kind
# a `uses` grant lowers to.
#
#   * `generic`   the fake's own shape: service -> run, public; job -> run,
#                 schedule; bucket -> bucket; grant -> grant. No identity
#                 role.
#   * `aws`       service -> identity (AWS::IAM::Role), run
#                 (AWS::Lambda::Function), public (AWS::Lambda::Url);
#                 job -> identity, run (AWS::ECS::TaskDefinition), schedule
#                 (AWS::Scheduler::Schedule); bucket -> bucket
#                 (AWS::S3::Bucket); grant -> AWS::IAM::RolePolicy.
#   * `gcp`       service -> identity (iam.googleapis.com/ServiceAccount), run
#                 (run.googleapis.com/Service), public (an invoker member
#                 binding); job -> identity, run (run.googleapis.com/Job),
#                 schedule (cloudscheduler.googleapis.com/Job); bucket ->
#                 bucket (storage.googleapis.com/Bucket); grant -> a
#                 member binding. GCP has no asset type for one binding: the
#                 kind id names the call that writes it, `setIamPolicy`.
#   * `azure`     service -> identity
#                 (Microsoft.ManagedIdentity/userAssignedIdentities), run
#                 (Microsoft.App/containerApps); job -> identity, run
#                 (Microsoft.App/jobs); bucket -> bucket
#                 (Microsoft.Storage/storageAccounts/blobServices/containers,
#                 in the cell's storage account); grant ->
#                 Microsoft.Authorization/roleAssignments. There is NO public
#                 row and NO schedule row: a container app's ingress and a
#                 job's schedule trigger are settings of the run object, so
#                 they FOLD into the run node's desired fields (`ingress`,
#                 `trigger`) and are never nodes of their own.
#   * `onprem`    the self-hosted cloud: Kubernetes + MinIO + Vault.
#                 service -> identity (v1/ServiceAccount), run
#                 (apps/v1/Deployment), endpoint (v1/Service: the in-cluster
#                 address of the Deployment, always wanted), public
#                 (networking.k8s.io/v1/Ingress, which fronts the endpoint);
#                 job -> identity, run (batch/v1/CronJob); bucket -> bucket
#                 (minio/Bucket: an S3-API bucket on the cell's MinIO);
#                 grant -> rbac.authorization.k8s.io/v1/RoleBinding. There
#                 is NO schedule row: a job is a CronJob, and its schedule
#                 FOLDS into it (`trigger`; an on-demand job is a suspended
#                 CronJob, and a run of it is a batch/v1/Job made from the
#                 CronJob's template, which is an execution, not a lowered
#                 object).
#
# THE BUILT-IN CLOUDS ARE DATA: `builtin_shapes()` is the list aws, gcp,
# azure, onprem, and `shape_named(name)` looks a cloud name up in it and
# refuses any other name. No type and no branch names a cloud. `generic` is
# the fake's own shape, not a cloud, so it is not in the list.
#
# A role the shape has but the file turns off is still lowered, with
# `wanted` False (the closed world). A FOLDED role has no node: turning it
# off is an update of the run node.
#
# A bucket has ONE role on every shape, `bucket`, and no identity: it runs
# as nobody, it is only granted to.
#
# The `identity` role is a compute primitive's PRIVATE identity: a helper
# object that exists only for that primitive and dies with it. The run node
# depends on it, and a `uses` grant hangs off it (on the generic shape, which
# has no identity role, off the run node).
#
# A shape is chosen by the constructor of a fake cloud, never from the
# cloud's id: the id stays opaque.
# =============================================================================

from kci_cloud import FIELD_BUCKET, FIELD_JOB, FIELD_SERVICE


comptime ROLE_BUCKET = "bucket"
comptime ROLE_IDENTITY = "identity"
comptime ROLE_RUN = "run"
comptime ROLE_PUBLIC = "public"
comptime ROLE_SCHEDULE = "schedule"
comptime ROLE_ENDPOINT = "endpoint"


@fieldwise_init
struct ShapeRow(Copyable, Movable, Deinitable):
    """One role a catalog type lowers to on a shape: the type's field, the
    role, and the provider kind id the role's object is."""

    var field: Int
    var role: String
    var kind: String


struct ProviderShape(Copyable, Movable, Deinitable):
    """Per catalog field, the ordered roles and provider kinds; and the kind
    a `uses` grant lowers to."""

    var name: String
    var rows: List[ShapeRow]
    var grant_kind: String

    def __init__(out self, name: String, var rows: List[ShapeRow], grant_kind: String):
        self.name = name
        self.rows = rows^
        self.grant_kind = grant_kind

    def __init__(out self, *, copy: Self):
        self.name = copy.name.copy()
        self.rows = copy.rows.copy()
        self.grant_kind = copy.grant_kind.copy()

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

    @staticmethod
    def generic() -> ProviderShape:
        var r = List[ShapeRow]()
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_RUN), String("run")))
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_PUBLIC), String("public")))
        r.append(ShapeRow(FIELD_JOB, String(ROLE_RUN), String("run")))
        r.append(ShapeRow(FIELD_JOB, String(ROLE_SCHEDULE), String("schedule")))
        r.append(ShapeRow(FIELD_BUCKET, String(ROLE_BUCKET), String("bucket")))
        return ProviderShape(String("generic"), r^, String("grant"))

    @staticmethod
    def aws() -> ProviderShape:
        var r = List[ShapeRow]()
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_IDENTITY), String("AWS::IAM::Role")))
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_RUN), String("AWS::Lambda::Function")))
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_PUBLIC), String("AWS::Lambda::Url")))
        r.append(ShapeRow(FIELD_JOB, String(ROLE_IDENTITY), String("AWS::IAM::Role")))
        r.append(ShapeRow(FIELD_JOB, String(ROLE_RUN), String("AWS::ECS::TaskDefinition")))
        r.append(ShapeRow(FIELD_JOB, String(ROLE_SCHEDULE), String("AWS::Scheduler::Schedule")))
        r.append(ShapeRow(FIELD_BUCKET, String(ROLE_BUCKET), String("AWS::S3::Bucket")))
        return ProviderShape(String("aws"), r^, String("AWS::IAM::RolePolicy"))

    @staticmethod
    def gcp() -> ProviderShape:
        var r = List[ShapeRow]()
        r.append(
            ShapeRow(FIELD_SERVICE, String(ROLE_IDENTITY), String("iam.googleapis.com/ServiceAccount"))
        )
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_RUN), String("run.googleapis.com/Service")))
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_PUBLIC), String("setIamPolicy")))
        r.append(
            ShapeRow(FIELD_JOB, String(ROLE_IDENTITY), String("iam.googleapis.com/ServiceAccount"))
        )
        r.append(ShapeRow(FIELD_JOB, String(ROLE_RUN), String("run.googleapis.com/Job")))
        r.append(
            ShapeRow(FIELD_JOB, String(ROLE_SCHEDULE), String("cloudscheduler.googleapis.com/Job"))
        )
        r.append(ShapeRow(FIELD_BUCKET, String(ROLE_BUCKET), String("storage.googleapis.com/Bucket")))
        return ProviderShape(String("gcp"), r^, String("setIamPolicy"))

    @staticmethod
    def azure() -> ProviderShape:
        var r = List[ShapeRow]()
        r.append(
            ShapeRow(
                FIELD_SERVICE,
                String(ROLE_IDENTITY),
                String("Microsoft.ManagedIdentity/userAssignedIdentities"),
            )
        )
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_RUN), String("Microsoft.App/containerApps")))
        r.append(
            ShapeRow(
                FIELD_JOB,
                String(ROLE_IDENTITY),
                String("Microsoft.ManagedIdentity/userAssignedIdentities"),
            )
        )
        r.append(ShapeRow(FIELD_JOB, String(ROLE_RUN), String("Microsoft.App/jobs")))
        r.append(
            ShapeRow(
                FIELD_BUCKET,
                String(ROLE_BUCKET),
                String("Microsoft.Storage/storageAccounts/blobServices/containers"),
            )
        )
        return ProviderShape(
            String("azure"), r^, String("Microsoft.Authorization/roleAssignments")
        )

    @staticmethod
    def onprem() -> ProviderShape:
        var r = List[ShapeRow]()
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_IDENTITY), String("v1/ServiceAccount")))
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_RUN), String("apps/v1/Deployment")))
        r.append(ShapeRow(FIELD_SERVICE, String(ROLE_ENDPOINT), String("v1/Service")))
        r.append(
            ShapeRow(FIELD_SERVICE, String(ROLE_PUBLIC), String("networking.k8s.io/v1/Ingress"))
        )
        r.append(ShapeRow(FIELD_JOB, String(ROLE_IDENTITY), String("v1/ServiceAccount")))
        r.append(ShapeRow(FIELD_JOB, String(ROLE_RUN), String("batch/v1/CronJob")))
        r.append(ShapeRow(FIELD_BUCKET, String(ROLE_BUCKET), String("minio/Bucket")))
        return ProviderShape(
            String("onprem"), r^, String("rbac.authorization.k8s.io/v1/RoleBinding")
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
