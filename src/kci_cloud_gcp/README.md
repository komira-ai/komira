# kci_cloud_gcp

The GCP cloud adapter for kci: `GcpCloud[C, TS]`, a kci_cloud `CloudAdapter`
that deploys a cell's resources into one GCP project and region. It talks to
IAM, Cloud Resource Manager and Cloud Run through komira's generated REST
clients, each on a connector of type `C` (`GcpConnectors`), all asking one
token source of type `TS`, and it lowers through kci_cloud's shared shape
lowering on the gcp shape. It hosts:

- `service_account`: an IAM service account whose description carries kci's
  lines;
- `container_job`: a Cloud Run job, stamped with labels;
- the member bindings of grant edges on a service account and on the
  project, attributed back to their edge through the IAM role table
  (`gcp_role_table`).

| module | what it holds |
|---|---|
| `cloud.mojo` | `GcpCloud` and what each `CloudAdapter` method answers |
| `names.mojo` | the objects' names (`derived_name`, `object_name`, `account_email`, ...) and `gcp_role_table` |
| `session.mojo` | `GcpConnectors`, `GcpEndpoints`, `SharedTokenSource`: the clients and the token source a deploy shares |
| `node_account.mojo`, `node_job.mojo`, `node_binding.mojo` | the engine node of each provider kind |
| `job_model.mojo` | a run node as a Cloud Run job, and back |
| `owned.mojo` | listing the objects a cell owns |
| `credentials.mojo` | the reader a deploy's `GOOGLE_APPLICATION_CREDENTIALS` file goes to |

No public function takes or returns a pointer. The adapter's wire behaviour
is exercised against a stateful GCP emulator in the repository's test
helpers, which runs kci_cloud's conformance kit over this adapter.

## Examples

Every example below runs as a test when the package is built, so it cannot
go stale. None of them touches the network.

### Names and the role table

An object the author did not name gets a derived name: `kci-` and ten
base32 characters of a hash of machine, cell and node id. It is the same
for the same node, different in another cell, and inside IAM's account-id
rule (6 to 30 of `[a-z0-9-]`, a letter first). The role table maps each
(target, access) to exactly one IAM role, so a binding reads back to one
edge.

```mojo
from kci_cloud import role_table_problems
from kci_cloud_gcp import (
    account_email,
    account_member,
    derived_name,
    gcp_role_table,
    job_resource,
    object_name,
)
from std.testing import assert_equal, assert_true

var id = derived_name("shop", "staging", "peer/identity")
assert_true(id.startswith("kci-"), id)
assert_equal(id.byte_length(), 14)
assert_equal(id, derived_name("shop", "staging", "peer/identity"))
assert_true(id != derived_name("shop", "prod", "peer/identity"))
assert_equal(object_name("shop", "staging", "peer/identity", ""), id)
assert_equal(object_name("shop", "staging", "peer/identity", "runner-01"), "runner-01")

var email = account_email("runner-01", "demo-project")
assert_equal(email, String("runner-01") + "@" + "demo-project.iam.gserviceaccount.com")
assert_equal(account_member(email), "serviceAccount:" + email)
assert_equal(
    job_resource("demo-project", "europe-west1", "report-1"),
    "projects/demo-project/locations/europe-west1/jobs/report-1",
)

var rows = gcp_role_table()
assert_equal(len(role_table_problems(rows)), 0)
for i in range(len(rows)):
    assert_true(rows[i].role.startswith("roles/"), rows[i].role)
```

### Which credentials a deploy reads

A deploy reads the file `GOOGLE_APPLICATION_CREDENTIALS` names, and nothing
else: no gcloud login file, no metadata server. Its `type` chooses the
reader; a person's own `authorized_user` login is refused. The variable and
the file are read through komira_gcp_core's `EnvSource` and `FileSource`
seams, here the `MapEnv` and `MapFiles` doubles.

```mojo
from komira_gcp_core import MapEnv, MapFiles
from kci_cloud_gcp import deploy_credentials_type
from std.testing import assert_equal, assert_true

var env = MapEnv()
env.set("GOOGLE_APPLICATION_CREDENTIALS", "/run/secrets/deploy.json")
var files = MapFiles()
files.put("/run/secrets/deploy.json", '{"type":"external_account","audience":"//iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/p/providers/q"}')
assert_equal(deploy_credentials_type(env, files), "external_account")

files.put("/run/secrets/deploy.json", '{"type":"authorized_user","client_id":"1","refresh_token":"r"}')
var refused = String()
try:
    _ = deploy_credentials_type(env, files)
except e:
    refused = String(e)
assert_true(refused.startswith("kci: REFUSED:"), refused)
assert_true("authorized_user" in refused, refused)

var unset = MapEnv()
var missing = String()
try:
    _ = deploy_credentials_type(unset, files)
except e:
    missing = String(e)
assert_true(missing.startswith("kci: REFUSED: a GCP deploy needs GOOGLE_APPLICATION_CREDENTIALS"), missing)
```
