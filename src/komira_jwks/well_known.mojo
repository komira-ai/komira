# komira_jwks/well_known.mojo -- well-known JWKS paths.

# The path the identity-token issuer serves its PUBLIC signing keys (a JWKS
# document) at, relative to the issuer's origin. An edge or gateway that verifies
# identity tokens fetches the keys from here.
comptime IDENTITY_JWKS_PATH: String = "/.well-known/identity-jwks.json"
