"""`komira_test_issuer`: an in-process token issuer for tests, and the
scenario table every issuer in the HTTP auth design must pass.

Test-only (no conda package): a library names it in `test_deps`, never in
`deps`. Modules:
  - issuer.mojo     : `TestIssuer`, a JWK Set document and a user-token mint
                      over a komira_jose `Keyring`, with key rotation that
                      publishes before it signs and keeps a former key until
                      the max lifetime plus the leeway have passed.
  - keys.mojo       : `derived_key`, the issuer's keys derived from a seed.
  - user_token.mojo : `user_token_claims`, the claims of a user access token.
  - under_test.mojo : `IssuerUnderTest`, the trait a scenario drives, and
                      `IssuerProfile`, what a relying party configures.
  - scenarios.mojo  : `issuer_scenarios()`, `run_issuer_scenario[I]`,
                      `run_issuer_scenarios[I]`, `verify_as_relying_party`
                      and `profile_of`.

The public API holds owned values only; no pointers.
"""

from .keys import derived_key
from .user_token import user_token_claims
from .under_test import IssuerProfile, IssuerUnderTest
from .issuer import TestIssuer
from .scenarios import (
    SCENARIO_CLAIMS,
    SCENARIO_IN_FLIGHT,
    SCENARIO_JTI_SAMPLES,
    SCENARIO_JTI_UNIQUE,
    SCENARIO_MINT_VERIFIES,
    SCENARIO_PUBLISH_BEFORE_SIGN,
    SCENARIO_SCOPE,
    SCENARIO_SUBJECT,
    SCENARIO_SUBJECT_REQUIRED,
    issuer_scenarios,
    profile_of,
    run_issuer_scenario,
    run_issuer_scenarios,
    verify_as_relying_party,
)
