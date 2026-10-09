# komira_github_fake

GitHub's REST subset (the routes of `komira_github`) answered in memory, for
tests of code that uses `komira_github`. A fake, not a mock: `FakeGitHub`
holds repositories, installations, tokens, workflow runs, jobs, artifacts,
check runs and files, and is a `komira_github` `GitHubTransport`, so the real
`GitHubAppClient` runs against it unchanged.

It checks credentials the way GitHub does:

- **the App JWT** against the App's public key (`app_public_key_from_pkcs8`
  gives it the half of a test key): RS256 signature, `iss`, and GitHub's
  window (expired at `exp`, at most 10 minutes ahead, not issued in the
  future);
- **installation tokens** by expiry, installation (403 when suspended),
  repository (404 for one the token does not cover) and permission (403);
- **installing**: `install(account, installed_by, repo_ids, permissions)`
  is GitHub's web flow, and refuses a person who does not administer every
  chosen repository, a repository of another account, and a permission the
  App does not ask for.

Pages follow GitHub (`per_page`, `page`, a `Link` header with `next` and
`last` under `/repositories/<id>/...`). Rate limits are scripted:
`arm_secondary_limit` and `arm_primary_limit` answer the next request as
GitHub does. Every request is recorded (`requests`, `count_route`), and one
outside the subset is a 404 counted in `unrouted_requests`.
`signed_delivery_headers` signs a webhook delivery as GitHub does.

## Examples

Installing is allowed only to an administrator of every chosen repository:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_github_fake import FakeAppPublicKey, FakeGitHub

var fake = FakeGitHub(String("12345"), FakeAppPublicKey(List[UInt8](), 65537), 1_790_856_000)
var admins = List[String]()
admins.append(String("alice"))
var repo = fake.state.add_repo(String("alice"), String("app"), admins^)
fake.state.set_collaborator(repo, String("bob"), String("write"))
var repos = List[Int64]()
repos.append(repo)
var permissions = List[String]()
permissions.append(String("contents:read"))

var why = String("")
try:
    _ = fake.state.install(String("alice"), String("bob"), repos.copy(), permissions.copy())
except e:
    why = String(e)
assert_true(why.find("bob does not administer alice/app") >= 0)
var installation = fake.state.install(String("alice"), String("alice"), repos^, permissions^)
assert_true(installation > 0)
```

A webhook delivery signed as GitHub signs it verifies with `komira_github`:

```mojo
from komira_github import verify_webhook_delivery
from komira_github_fake import signed_delivery_headers

var secret = String("test-only-secret")
var body = String('{"action":"completed"}')
var headers = signed_delivery_headers(secret.as_bytes(), body.as_bytes(), String("workflow_run"), String("d-1"))
verify_webhook_delivery(secret.as_bytes(), body.as_bytes(), headers)
assert_equal(headers[3].name, "X-Hub-Signature-256")
```
