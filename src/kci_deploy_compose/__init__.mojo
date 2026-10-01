"""`kci_deploy_compose` — the API-composition tier of the deploy tool.

The built-in Compositions (plain, value-typed Mojo functions) that synthesize
the FullManifest resource graph (`full_manifest.proto`) from the authored
intent bundle (`app_bundle.proto`) — tier-1 of the two-tier model. No customer
code, no compiler on the synth path.

Public surface (import directly from the flat package modules):
  from kci_deploy_compose.compose_api import compose_api, compose
  from kci_deploy_compose.content_address import content_address

Pure + deterministic + side-effect-free (synth-once): the SAME bundle+env in
yields a byte-identical manifest + content-address out.
"""

