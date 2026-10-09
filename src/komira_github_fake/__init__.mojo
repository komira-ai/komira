"""`komira_github_fake`: GitHub's REST subset (komira_github's route table)
answered in memory, for tests of code that uses komira_github.

`FakeGitHub` is a komira_github `GitHubTransport`: give it to a real
`GitHubAppClient` and every call is answered from the fake's state as GitHub
would answer it, credentials checked GitHub's way (the App JWT against the
App's public key and GitHub's 10-minute window; installation tokens by
expiry, installation, repository and permission). `install` enforces
GitHub's rule that only an administrator of a repository can install an App
on it. Rate limits are scripted (`arm_secondary_limit`,
`arm_primary_limit`); `signed_delivery_headers` signs a webhook delivery as
GitHub does.

Modules:
  - fake.mojo           `FakeGitHub`, `signed_delivery_headers`
  - state.mojo          the objects, `install` and the other set-up verbs
  - app_auth.mojo       the App JWT check, `app_public_key_from_pkcs8`
  - handlers.mojo       App routes and installation tokens
  - repo_handlers.mojo  installation routes
  - render.mojo         GitHub's JSON and its page and Link shape
  - model.mojo          the records
"""

from .app_auth import FakeAppPublicKey, app_public_key_from_pkcs8, check_app_jwt
from .fake import FAKE_LINK_BASE, FakeGitHub, default_app_permissions, signed_delivery_headers
from .handlers import TOKEN_LIFETIME_S
from .model import (
    FakeArtifact,
    FakeCheckRun,
    FakeFile,
    FakeInstallation,
    FakeJob,
    FakeRepo,
    FakeRun,
    FakeToken,
    grants,
)
from .state import FakeState
