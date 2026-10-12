# =============================================================================
# test_cloud_shape_lower_compute.mojo
# =============================================================================
#
# `lower_shape` (shape/lower.mojo) of the workloads, the identities, the
# triggers and the grant edges, on every built-in shape and the generic one,
# and the shapes as data (shape/shapes.mojo):
#
# 1. THE WORKLOADS: a public service with every modelled field (env and
#    secret_env in key order, a reference as an input, a GPU size, a scale,
#    a timeout with nanoseconds, a subnet) and a bare one (every default
#    written out); a service running as an account, an image by build step;
#    container jobs and workers with and without `run_as` (aws: the worker's
#    task is an object of its own); azure folds the exposure into the run,
#    onprem puts an endpoint in front of it and a vault beside the identity.
# 2. THE TRIGGERS: a schedule of a container job (folded into the job, its
#    nodes turned off, on azure and onprem), a schedule of a service, an
#    event trigger; their CALL edges.
# 3. THE EDGES: by the shape's row for the target's type, the helper of a
#    row that names one (onprem), a cell edge folded into the identity it is
#    for, and one that cannot fold (a grant resource's cell edge on onprem).
# 4. THE SHAPES AS DATA: the built-in list and its names, an unknown name,
#    a role a shape does not have, the helper role, which kinds are member
#    bindings; lower_run and lower_trigger refuse what is not theirs.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_proto_codec import decode_json
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud import (
    FIELD_BUCKET, FIELD_SERVICE, GrantEdge, LoweredNode, ProviderShape, body_field, builtin_shapes, edges_for,
    feeds_of, firings_of, lower_shape, shape_named,
)
from kci_cloud.firing import Firing
from kci_cloud.shape.shapes import helper_role
from kci_cloud.shape.triggers import lower_trigger
from kci_cloud.shape.workloads import lower_run


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](String('{"resource":[') + json + String("]}")).resource.copy()


def _node(n: LoweredNode) -> String:
    """`id kind[ (off)] <- deps | in: field=producer.OUTPUT | k=v ...`."""
    var s = n.id + String(" ") + n.kind
    if not n.wanted:
        s += String(" (off)")
    if len(n.depends_on) > 0:
        s += String(" <-")
        for d in n.depends_on:
            s += String(" ") + d
    for i in n.inputs:
        s += String(" | in: ") + i.field + String("=") + i.producer + String(".") + i.output
    for f in n.desired:
        s += String(" | ") + f.key + String("=") + f.value
    return s^


def _lowered(shape: ProviderShape, resources: List[Resource], only: List[String]) raises -> String:
    """The resources of `resources` named in `only` that the shape hosts,
    lowered, one node per line; `<id>: NOT_YET` for a type it does not host,
    `<id>: <error>` for a lowering that raises."""
    var feeds = feeds_of(resources)
    var firings = firings_of(resources)
    var out = String("")
    for r in resources:
        if r.id not in only:
            continue
        if not shape.hosts(body_field(r)):
            out += r.id + String(": NOT_YET\n")
            continue
        try:
            for n in lower_shape(r, edges_for(resources, r), feeds, firings, String("edge"), shape):
                out += _node(n) + String("\n")
        except e:
            out += r.id + String(": ") + String(e) + String("\n")
    return out^


def _diff(name: String, got: String, want: String) -> String:
    if got == want:
        return String("")
    return String("\n==== ") + name + String(" got:\n") + got


comptime _GRAPH = (
    '{"id":"api","service":{"image":{"digest":"sha256:a1"},"port":8081,"public":{},'
    + '"env":{"B":{"literal":"2"},"A":{"ref":{"resource":"db","standard":"NAME"}},"C":{"literal":"3"}},'
    + '"secretEnv":{"Z":{"name":"tok","store":"vault","version":"3"},"Y":{"secret":{"resource":"s1"},"version":"7"},'
    + '"X":{"name":"plain"},"W":{"secret":{"resource":"s1"}}},'
    + '"size":{"cpuMillis":500,"memoryMb":256,"gpus":1},"scale":{"min":1,"max":3},"healthPath":"/h",'
    + '"requestTimeout":"30.500s","maxConcurrency":8,"command":["/bin/a"],"args":["x","y"],'
    + '"network":{"resource":"sn"}},"uses":[{"target":{"resource":"db"},"access":"READ"}]},'
    + '{"id":"web","service":{"image":{"output":{"step":"b","name":"img"}},"internal":{},'
    + '"runAs":{"resource":"sa"},"scale":{"max":4}}},'
    + '{"id":"bare","service":{}},'
    + '{"id":"sa","serviceAccount":{},"uses":[{"target":{"resource":"b1"},"access":"WRITE"}]},'
    + '{"id":"job","containerJob":{"image":{"digest":"sha256:j1","platform":"linux/arm64"},"maxRetries":2,'
    + '"timeout":"120s","command":["/bin/j"],"args":["-v"]}},'
    + '{"id":"job2","containerJob":{"image":{"digest":"sha256:j2"},"runAs":{"resource":"sa"}}},'
    + '{"id":"wk","worker":{"image":{"digest":"sha256:w1"},"replicas":2,"runAs":{"resource":"sa"}}},'
    + '{"id":"wk2","worker":{"image":{"digest":"sha256:w2"}}},'
    + '{"id":"sch","schedule":{"cron":"0 3 * * *","timezone":"Europe/Paris","target":{"resource":"job"}}},'
    + '{"id":"sch2","schedule":{"cron":"*/5 * * * *","target":{"resource":"api"}}},'
    + '{"id":"ev","eventTrigger":{"source":{"resource":"b1"},"event":"OBJECT_CREATED","target":{"resource":"api"}}},'
    + '{"id":"g","grant":{"principal":{"resource":"job"},"target":{"resource":"b1"},"access":"READ"}},'
    + '{"id":"g2","grant":{"principal":{"resource":"wk2"},"cell":"METRICS","access":"WRITE"}},'
    + '{"id":"db","table":{"key":{"name":"k","partition":{"name":"id","type":"STRING"}}}},'
    + '{"id":"b1","bucket":{}},{"id":"s1","secret":{}},'
    + '{"id":"net","network":{"ipv4Cidr":"198.51.100.0/24"}},'
    + '{"id":"sn","subnet":{"network":{"resource":"net"},"ipv4Cidr":"198.51.100.0/25","zone":1}}'
)


def _ids() -> List[String]:
    return [
        String("api"), String("web"), String("bare"), String("sa"), String("job"), String("job2"), String("wk"),
        String("wk2"), String("sch"), String("sch2"), String("ev"), String("g"), String("g2"),
    ]


comptime _WANT_GENERIC = """api/identity identity
api/run run <- api/identity | in: service.env.A=db.NAME | in: service.secret_env.W=s1.NAME | in: service.secret_env.Y=s1.NAME | in: network=sn.NAME | img=sha256:a1@linux/amd64 | port=8081 | cmd=/bin/a | arg=x | arg=y | service.env.B=2 | service.env.C=3 | service.secret_env.X=plain | service.secret_env.Y.version=7 | service.secret_env.Z=vault/tok@3 | size=500m/256MB/1gpu | scale=1..3 | health=/h | timeout=30s500000000n | concurrency=8 | serves=true
api/public public <- api/run | mechanism=edge
api/u-zzkf7b grant <- api/identity db | principal=api | target=db | access=READ
api/u-gktqg5 grant <- api/identity | principal=api | cell=LOGS | access=WRITE
web/identity identity (off)
web/run run <- sa | img=@linux/amd64 | port=8080 | size=1000m/512MB | scale=0..4 | health= | timeout=60s0n | concurrency=0 | run_as=sa | serves=true
web/public public (off) <- web/run | mechanism=edge
bare/identity identity
bare/run run <- bare/identity | img= | port=8080 | size=1000m/512MB | scale=0..10 | health= | timeout=60s0n | concurrency=0 | serves=true
bare/public public (off) <- bare/run | mechanism=edge
bare/u-e2n42n grant <- bare/identity | principal=bare | cell=LOGS | access=WRITE
sa/identity identity | account=true
sa/u-oxohk4 grant <- sa/identity b1 | principal=sa | target=b1 | access=WRITE
sa/u-bqp2lo grant <- sa/identity | principal=sa | cell=LOGS | access=WRITE
job/identity identity
job/run run <- job/identity | img=sha256:j1@linux/arm64 | cmd=/bin/j | arg=-v | size=1000m/512MB | retries=2 | timeout=120s0n | serves=false
job/u-y2fktt grant <- job/identity | principal=job | cell=LOGS | access=WRITE
job2/identity identity (off)
job2/run run <- sa | img=sha256:j2@linux/amd64 | size=1000m/512MB | retries=0 | timeout=600s0n | run_as=sa | serves=false
wk/identity identity (off)
wk/run run <- sa | img=sha256:w1@linux/amd64 | size=1000m/512MB | replicas=2 | run_as=sa | serves=false
wk2/identity identity
wk2/run run <- wk2/identity | img=sha256:w2@linux/amd64 | size=1000m/512MB | replicas=1 | serves=false
wk2/u-4ztpuj grant <- wk2/identity | principal=wk2 | cell=LOGS | access=WRITE
sch/identity identity
sch/schedule schedule <- sch/identity job sch/u-t3xlqd | cron=0 3 * * * | timezone=Europe/Paris | target=job
sch/u-t3xlqd grant <- sch/identity job | principal=sch | target=job | access=CALL
sch2/identity identity
sch2/schedule schedule <- sch2/identity api sch2/u-zqmptk | cron=*/5 * * * * | timezone=UTC | target=api
sch2/u-zqmptk grant <- sch2/identity api | principal=sch2 | target=api | access=CALL
ev/identity identity
ev/trigger trigger <- ev/identity b1 api ev/u-kkqviy | source=b1 | event=OBJECT_CREATED | target=api
ev/u-kkqviy grant <- ev/identity api | principal=ev | target=api | access=CALL
g/grant grant <- job/identity b1 | principal=job | target=b1 | access=READ
g2/grant grant <- wk2/identity | principal=wk2 | cell=METRICS | access=WRITE
"""


comptime _WANT_AWS = """api/identity AWS::IAM::Role
api/run AWS::Lambda::Function <- api/identity | in: service.env.A=db.NAME | in: service.secret_env.W=s1.NAME | in: service.secret_env.Y=s1.NAME | in: network=sn.NAME | img=sha256:a1@linux/amd64 | port=8081 | cmd=/bin/a | arg=x | arg=y | service.env.B=2 | service.env.C=3 | service.secret_env.X=plain | service.secret_env.Y.version=7 | service.secret_env.Z=vault/tok@3 | size=500m/256MB/1gpu | scale=1..3 | health=/h | timeout=30s500000000n | concurrency=8 | serves=true
api/public AWS::Lambda::Url <- api/run | mechanism=edge
api/u-zzkf7b AWS::IAM::RolePolicy <- api/identity db | principal=api | target=db | access=READ
api/u-gktqg5 AWS::IAM::RolePolicy <- api/identity | principal=api | cell=LOGS | access=WRITE
web/identity AWS::IAM::Role (off)
web/run AWS::Lambda::Function <- sa | img=@linux/amd64 | port=8080 | size=1000m/512MB | scale=0..4 | health= | timeout=60s0n | concurrency=0 | run_as=sa | serves=true
web/public AWS::Lambda::Url (off) <- web/run | mechanism=edge
bare/identity AWS::IAM::Role
bare/run AWS::Lambda::Function <- bare/identity | img= | port=8080 | size=1000m/512MB | scale=0..10 | health= | timeout=60s0n | concurrency=0 | serves=true
bare/public AWS::Lambda::Url (off) <- bare/run | mechanism=edge
bare/u-e2n42n AWS::IAM::RolePolicy <- bare/identity | principal=bare | cell=LOGS | access=WRITE
sa/identity AWS::IAM::Role | account=true
sa/u-oxohk4 AWS::IAM::RolePolicy <- sa/identity b1 | principal=sa | target=b1 | access=WRITE
sa/u-bqp2lo AWS::IAM::RolePolicy <- sa/identity | principal=sa | cell=LOGS | access=WRITE
job/identity AWS::IAM::Role
job/run AWS::ECS::TaskDefinition <- job/identity | img=sha256:j1@linux/arm64 | cmd=/bin/j | arg=-v | size=1000m/512MB | retries=2 | timeout=120s0n | serves=false
job/u-y2fktt AWS::IAM::RolePolicy <- job/identity | principal=job | cell=LOGS | access=WRITE
job2/identity AWS::IAM::Role (off)
job2/run AWS::ECS::TaskDefinition <- sa | img=sha256:j2@linux/amd64 | size=1000m/512MB | retries=0 | timeout=600s0n | run_as=sa | serves=false
wk/identity AWS::IAM::Role (off)
wk/task AWS::ECS::TaskDefinition <- sa | img=sha256:w1@linux/amd64 | size=1000m/512MB | run_as=sa
wk/run AWS::ECS::Service <- wk/task | replicas=2 | serves=false
wk2/identity AWS::IAM::Role
wk2/task AWS::ECS::TaskDefinition <- wk2/identity | img=sha256:w2@linux/amd64 | size=1000m/512MB
wk2/run AWS::ECS::Service <- wk2/task | replicas=1 | serves=false
wk2/u-4ztpuj AWS::IAM::RolePolicy <- wk2/identity | principal=wk2 | cell=LOGS | access=WRITE
sch/identity AWS::IAM::Role
sch/schedule AWS::Scheduler::Schedule <- sch/identity job sch/u-t3xlqd | cron=0 3 * * * | timezone=Europe/Paris | target=job
sch/u-t3xlqd AWS::IAM::RolePolicy <- sch/identity job | principal=sch | target=job | access=CALL
sch2/identity AWS::IAM::Role
sch2/schedule AWS::Scheduler::Schedule <- sch2/identity api sch2/u-zqmptk | cron=*/5 * * * * | timezone=UTC | target=api
sch2/u-zqmptk AWS::Lambda::Permission <- sch2/identity api | principal=sch2 | target=api | access=CALL
ev/identity AWS::IAM::Role
ev/trigger AWS::Events::Rule <- ev/identity b1 api ev/u-kkqviy | source=b1 | event=OBJECT_CREATED | target=api
ev/u-kkqviy AWS::Lambda::Permission <- ev/identity api | principal=ev | target=api | access=CALL
g/grant AWS::IAM::RolePolicy <- job/identity b1 | principal=job | target=b1 | access=READ
g2/grant AWS::IAM::RolePolicy <- wk2/identity | principal=wk2 | cell=METRICS | access=WRITE
"""


comptime _WANT_GCP = """api/identity iam.googleapis.com/ServiceAccount
api/run run.googleapis.com/Service <- api/identity | in: service.env.A=db.NAME | in: service.secret_env.W=s1.NAME | in: service.secret_env.Y=s1.NAME | in: network=sn.NAME | img=sha256:a1@linux/amd64 | port=8081 | cmd=/bin/a | arg=x | arg=y | service.env.B=2 | service.env.C=3 | service.secret_env.X=plain | service.secret_env.Y.version=7 | service.secret_env.Z=vault/tok@3 | size=500m/256MB/1gpu | scale=1..3 | health=/h | timeout=30s500000000n | concurrency=8 | serves=true
api/public setIamPolicy <- api/run | mechanism=edge
api/u-zzkf7b setIamPolicy <- api/identity db | principal=api | target=db | access=READ
api/u-gktqg5 setIamPolicy <- api/identity | principal=api | cell=LOGS | access=WRITE
web/identity iam.googleapis.com/ServiceAccount (off)
web/run run.googleapis.com/Service <- sa | img=@linux/amd64 | port=8080 | size=1000m/512MB | scale=0..4 | health= | timeout=60s0n | concurrency=0 | run_as=sa | serves=true
web/public setIamPolicy (off) <- web/run | mechanism=edge
bare/identity iam.googleapis.com/ServiceAccount
bare/run run.googleapis.com/Service <- bare/identity | img= | port=8080 | size=1000m/512MB | scale=0..10 | health= | timeout=60s0n | concurrency=0 | serves=true
bare/public setIamPolicy (off) <- bare/run | mechanism=edge
bare/u-e2n42n setIamPolicy <- bare/identity | principal=bare | cell=LOGS | access=WRITE
sa/identity iam.googleapis.com/ServiceAccount | account=true
sa/u-oxohk4 setIamPolicy <- sa/identity b1 | principal=sa | target=b1 | access=WRITE
sa/u-bqp2lo setIamPolicy <- sa/identity | principal=sa | cell=LOGS | access=WRITE
job/identity iam.googleapis.com/ServiceAccount
job/run run.googleapis.com/Job <- job/identity | img=sha256:j1@linux/arm64 | cmd=/bin/j | arg=-v | size=1000m/512MB | retries=2 | timeout=120s0n | serves=false
job/u-y2fktt setIamPolicy <- job/identity | principal=job | cell=LOGS | access=WRITE
job2/identity iam.googleapis.com/ServiceAccount (off)
job2/run run.googleapis.com/Job <- sa | img=sha256:j2@linux/amd64 | size=1000m/512MB | retries=0 | timeout=600s0n | run_as=sa | serves=false
wk/identity iam.googleapis.com/ServiceAccount (off)
wk/run run.googleapis.com/WorkerPool <- sa | img=sha256:w1@linux/amd64 | size=1000m/512MB | replicas=2 | run_as=sa | serves=false
wk2/identity iam.googleapis.com/ServiceAccount
wk2/run run.googleapis.com/WorkerPool <- wk2/identity | img=sha256:w2@linux/amd64 | size=1000m/512MB | replicas=1 | serves=false
wk2/u-4ztpuj setIamPolicy <- wk2/identity | principal=wk2 | cell=LOGS | access=WRITE
sch/identity iam.googleapis.com/ServiceAccount
sch/schedule cloudscheduler.googleapis.com/Job <- sch/identity job sch/u-t3xlqd | cron=0 3 * * * | timezone=Europe/Paris | target=job
sch/u-t3xlqd setIamPolicy <- sch/identity job | principal=sch | target=job | access=CALL
sch2/identity iam.googleapis.com/ServiceAccount
sch2/schedule cloudscheduler.googleapis.com/Job <- sch2/identity api sch2/u-zqmptk | cron=*/5 * * * * | timezone=UTC | target=api
sch2/u-zqmptk setIamPolicy <- sch2/identity api | principal=sch2 | target=api | access=CALL
ev/identity iam.googleapis.com/ServiceAccount
ev/trigger eventarc.googleapis.com/Trigger <- ev/identity b1 api ev/u-kkqviy | source=b1 | event=OBJECT_CREATED | target=api
ev/u-kkqviy setIamPolicy <- ev/identity api | principal=ev | target=api | access=CALL
g/grant setIamPolicy <- job/identity b1 | principal=job | target=b1 | access=READ
g2/grant setIamPolicy <- wk2/identity | principal=wk2 | cell=METRICS | access=WRITE
"""


comptime _WANT_AZURE = """api/identity Microsoft.ManagedIdentity/userAssignedIdentities
api/run Microsoft.App/containerApps <- api/identity | in: service.env.A=db.NAME | in: service.secret_env.W=s1.NAME | in: service.secret_env.Y=s1.NAME | in: network=sn.NAME | img=sha256:a1@linux/amd64 | port=8081 | cmd=/bin/a | arg=x | arg=y | service.env.B=2 | service.env.C=3 | service.secret_env.X=plain | service.secret_env.Y.version=7 | service.secret_env.Z=vault/tok@3 | size=500m/256MB/1gpu | scale=1..3 | health=/h | timeout=30s500000000n | concurrency=8 | ingress=edge | serves=true
api/u-zzkf7b Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments <- api/identity db | principal=api | target=db | access=READ
api/u-gktqg5 Microsoft.Authorization/roleAssignments <- api/identity | principal=api | cell=LOGS | access=WRITE
web/identity Microsoft.ManagedIdentity/userAssignedIdentities (off)
web/run Microsoft.App/containerApps <- sa | img=@linux/amd64 | port=8080 | size=1000m/512MB | scale=0..4 | health= | timeout=60s0n | concurrency=0 | ingress=none | run_as=sa | serves=true
bare/identity Microsoft.ManagedIdentity/userAssignedIdentities
bare/run Microsoft.App/containerApps <- bare/identity | img= | port=8080 | size=1000m/512MB | scale=0..10 | health= | timeout=60s0n | concurrency=0 | ingress=none | serves=true
bare/u-e2n42n Microsoft.Authorization/roleAssignments <- bare/identity | principal=bare | cell=LOGS | access=WRITE
sa/identity Microsoft.ManagedIdentity/userAssignedIdentities | account=true
sa/u-oxohk4 Microsoft.Authorization/roleAssignments <- sa/identity b1 | principal=sa | target=b1 | access=WRITE
sa/u-bqp2lo Microsoft.Authorization/roleAssignments <- sa/identity | principal=sa | cell=LOGS | access=WRITE
job/identity Microsoft.ManagedIdentity/userAssignedIdentities
job/run Microsoft.App/jobs <- job/identity | img=sha256:j1@linux/arm64 | cmd=/bin/j | arg=-v | size=1000m/512MB | retries=2 | timeout=120s0n | schedule=sch | cron=0 3 * * * | timezone=Europe/Paris | serves=false
job/u-y2fktt Microsoft.Authorization/roleAssignments <- job/identity | principal=job | cell=LOGS | access=WRITE
job2/identity Microsoft.ManagedIdentity/userAssignedIdentities (off)
job2/run Microsoft.App/jobs <- sa | img=sha256:j2@linux/amd64 | size=1000m/512MB | retries=0 | timeout=600s0n | run_as=sa | serves=false
wk/identity Microsoft.ManagedIdentity/userAssignedIdentities (off)
wk/run Microsoft.App/containerApps <- sa | img=sha256:w1@linux/amd64 | size=1000m/512MB | replicas=2 | run_as=sa | serves=false
wk2/identity Microsoft.ManagedIdentity/userAssignedIdentities
wk2/run Microsoft.App/containerApps <- wk2/identity | img=sha256:w2@linux/amd64 | size=1000m/512MB | replicas=1 | serves=false
wk2/u-4ztpuj Microsoft.Authorization/roleAssignments <- wk2/identity | principal=wk2 | cell=LOGS | access=WRITE
sch/identity Microsoft.ManagedIdentity/userAssignedIdentities (off)
sch/schedule Microsoft.Logic/workflows (off) <- sch/identity job sch/u-t3xlqd | cron=0 3 * * * | timezone=Europe/Paris | target=job
sch/u-t3xlqd Microsoft.Authorization/roleAssignments (off) <- sch/identity job | principal=sch | target=job | access=CALL
sch2/identity Microsoft.ManagedIdentity/userAssignedIdentities
sch2/schedule Microsoft.Logic/workflows <- sch2/identity api sch2/u-zqmptk | cron=*/5 * * * * | timezone=UTC | target=api
sch2/u-zqmptk Microsoft.Authorization/roleAssignments <- sch2/identity api | principal=sch2 | target=api | access=CALL
ev/identity Microsoft.ManagedIdentity/userAssignedIdentities
ev/trigger Microsoft.EventGrid/systemTopics/eventSubscriptions <- ev/identity b1 api ev/u-kkqviy | source=b1 | event=OBJECT_CREATED | target=api
ev/u-kkqviy Microsoft.Authorization/roleAssignments <- ev/identity api | principal=ev | target=api | access=CALL
g/grant Microsoft.Authorization/roleAssignments <- job/identity b1 | principal=job | target=b1 | access=READ
g2/grant Microsoft.Authorization/roleAssignments <- wk2/identity | principal=wk2 | cell=METRICS | access=WRITE
"""


comptime _WANT_ONPREM = """api: fake: shape "onprem" folds this edge of "api" into an identity it does not hold; validate refuses it
web/identity v1/ServiceAccount (off)
web/vault vault:auth/kubernetes/role (off) <- web/identity
web/run apps/v1/Deployment <- sa | img=@linux/amd64 | port=8080 | size=1000m/512MB | scale=0..4 | health= | timeout=60s0n | concurrency=0 | run_as=sa | serves=true
web/endpoint v1/Service <- web/run | port=8080
web/public networking.k8s.io/v1/Ingress (off) <- web/endpoint | mechanism=edge
bare/identity v1/ServiceAccount | cell.LOGS=WRITE
bare/vault vault:auth/kubernetes/role <- bare/identity
bare/run apps/v1/Deployment <- bare/identity | img= | port=8080 | size=1000m/512MB | scale=0..10 | health= | timeout=60s0n | concurrency=0 | serves=true
bare/endpoint v1/Service <- bare/run | port=8080
bare/public networking.k8s.io/v1/Ingress (off) <- bare/endpoint | mechanism=edge
sa/identity v1/ServiceAccount | account=true | cell.LOGS=WRITE
sa/vault vault:auth/kubernetes/role <- sa/identity
sa/u-oxohk4 minio:policy <- sa/identity b1 | principal=sa | target=b1 | access=WRITE
job/identity v1/ServiceAccount | cell.LOGS=WRITE
job/vault vault:auth/kubernetes/role <- job/identity
job/run batch/v1/CronJob <- job/identity | img=sha256:j1@linux/arm64 | cmd=/bin/j | arg=-v | size=1000m/512MB | retries=2 | timeout=120s0n | schedule=sch | cron=0 3 * * * | timezone=Europe/Paris | serves=false
job2/identity v1/ServiceAccount (off)
job2/vault vault:auth/kubernetes/role (off) <- job2/identity
job2/run batch/v1/CronJob <- sa | img=sha256:j2@linux/amd64 | size=1000m/512MB | retries=0 | timeout=600s0n | run_as=sa | serves=false
wk/identity v1/ServiceAccount (off)
wk/vault vault:auth/kubernetes/role (off) <- wk/identity
wk/run apps/v1/Deployment <- sa | img=sha256:w1@linux/amd64 | size=1000m/512MB | replicas=2 | run_as=sa | serves=false
wk2/identity v1/ServiceAccount | cell.LOGS=WRITE
wk2/vault vault:auth/kubernetes/role <- wk2/identity
wk2/run apps/v1/Deployment <- wk2/identity | img=sha256:w2@linux/amd64 | size=1000m/512MB | replicas=1 | serves=false
sch/identity v1/ServiceAccount (off)
sch/schedule batch/v1/CronJob (off) <- sch/identity job sch/u-t3xlqd | cron=0 3 * * * | timezone=Europe/Paris | target=job
sch/r-t3xlqd rbac.authorization.k8s.io/v1/Role (off) <- job | target=job | access=CALL
sch/u-t3xlqd rbac.authorization.k8s.io/v1/RoleBinding (off) <- sch/identity job sch/r-t3xlqd | principal=sch | target=job | access=CALL
sch2/identity v1/ServiceAccount
sch2/schedule batch/v1/CronJob <- sch2/identity api sch2/u-zqmptk | cron=*/5 * * * * | timezone=UTC | target=api
sch2/r-zqmptk rbac.authorization.k8s.io/v1/Role <- api | target=api | access=CALL
sch2/u-zqmptk rbac.authorization.k8s.io/v1/RoleBinding <- sch2/identity api sch2/r-zqmptk | principal=sch2 | target=api | access=CALL
ev: NOT_YET
g/grant minio:policy <- job/identity b1 | principal=job | target=b1 | access=READ
g2: fake: shape "onprem" folds this edge of "g2" into an identity it does not hold; validate refuses it
"""


def test_workloads_triggers_and_edges_lower_by_their_shape() raises:
    var res = _list(String(_GRAPH))
    var miss = String("")
    miss += _diff(String("generic"), _lowered(ProviderShape.generic(), res, _ids()), String(_WANT_GENERIC))
    miss += _diff(String("aws"), _lowered(shape_named(String("aws")), res, _ids()), String(_WANT_AWS))
    miss += _diff(String("gcp"), _lowered(shape_named(String("gcp")), res, _ids()), String(_WANT_GCP))
    miss += _diff(String("azure"), _lowered(shape_named(String("azure")), res, _ids()), String(_WANT_AZURE))
    miss += _diff(String("onprem"), _lowered(shape_named(String("onprem")), res, _ids()), String(_WANT_ONPREM))
    assert_equal(miss, "")


def test_the_shapes_as_data() raises:
    var names = String("")
    for s in builtin_shapes():
        names += s.name + String(" ")
    assert_equal(names, "aws gcp azure onprem ")
    var e = String("it found one")
    try:
        _ = shape_named(String("AWS"))
    except err:
        e = String(err)
    assert_equal(e, "\"AWS\" is not a built-in cloud (the built-in clouds are aws, gcp, azure, onprem)")
    e = String("it has one")
    try:
        _ = shape_named(String("onprem")).kind_of(FIELD_BUCKET, String("index"))
    except err:
        e = String(err)
    assert_equal(e, "shape \"onprem\" has no role \"index\" for field " + String(FIELD_BUCKET))
    assert_equal(helper_role(String("u-abc123")), "r-abc123")
    assert_equal(helper_role(String("grant")), "rules")
    var gcp = shape_named(String("gcp"))
    assert_true(gcp.is_binding(String("setIamPolicy")))
    assert_false(gcp.is_binding(String("run.googleapis.com/Service")))
    assert_false(shape_named(String("aws")).is_binding(String("AWS::IAM::RolePolicy")))
    var roles = String("")
    for r in shape_named(String("onprem")).roles_of(FIELD_SERVICE):
        roles += r.role + String("=") + r.kind + String(" ")
    assert_equal(
        roles,
        "identity=v1/ServiceAccount vault=vault:auth/kubernetes/role run=apps/v1/Deployment endpoint=v1/Service"
        + " public=networking.k8s.io/v1/Ingress ",
    )


def test_a_lowering_refuses_what_is_not_its_own() raises:
    var res = _list(String('{"id":"b1","bucket":{}},{"id":"sch","schedule":{"cron":"0 3 * * *","target":{"resource":"b1"}}}'))
    var generic = ProviderShape.generic()
    var got = String("")
    try:
        _ = lower_run(res[0], True, String(""), generic, List[Firing]())
    except err:
        got += String(err) + String("\n")
    try:
        _ = lower_trigger(res[0], List[GrantEdge](), generic, True)
    except err:
        got += String(err) + String("\n")
    try:
        _ = lower_trigger(res[1], List[GrantEdge](), generic, True)
    except err:
        got += String(err) + String("\n")
    assert_equal(
        got,
        "fake: resource \"b1\" is not a workload\nfake: resource \"b1\" is not a trigger\n"
        + "fake: trigger \"sch\" was handed no CALL edge\n",
    )


def main() raises:
    test_workloads_triggers_and_edges_lower_by_their_shape()
    test_the_shapes_as_data()
    test_a_lowering_refuses_what_is_not_its_own()
