"""`komira_deploy_bundle` — the AppBundle textproto authoring surface.

The customer/LLM-facing INTENT-BUNDLE toolchain. It parses, validates,
scaffolds, and patches the `komira.deploy.textproto` authoring surface — the
small textproto a customer (or their LLM) writes to state WHAT they want, which
the deploy tool's built-in compositions synthesize into a full manifest.
Everything here codes against the GENERATED `komira_rpc_bundle.app_bundle.AppBundle`
schema; there is no parallel model.

WHAT LIVES HERE (the four concerns):
  * tokenizer.mojo   — the position-carrying textproto lexer (shared by the
                       parser AND the comment-preserving patcher).
  * parse_error.mojo — precise `line N, col M` errors + Levenshtein "did you
                       mean" — the LLM self-correction surface.
  * parser.mojo      — recursive-descent textproto -> the generated AppBundle.
  * emit.mojo        — the canonical AppBundle -> textproto serializer (the
                       round-trip partner of the parser).
  * validate.mojo    — the semantic pass (from_build refs resolve, oneof arms,
                       wave env symbols, per-kind required fields).
  * scaffold.mojo    — `scaffold_bundle(kind, name, intent)` -> the full
                       per-kind package baseline (bundle + pixi + build
                       files + Dockerfiles + test stubs). One library function
                       that every frontend calls.
  * patch.mojo       — the comment-preserving set-field + append-block ops
                       (minimal-diff over the raw text, never a re-serialize).
  * trigger_cadence.mojo — the DECLARED cadence of a machine's SCHEDULE trigger,
                       resolved to microseconds (`machine_cadence_us(bundle)`).
                       ⚠ It DECLARES; it never schedules. See below.

THE RELEASE-CLI / CONTROL-PLANE SEAM FOR A SCHEDULED STEP.
`trigger_cadence.machine_cadence_us(bundle) -> Int64` is the ENTIRE release-CLI
side of a scheduled step (for example a weekly merge-from-live). The release CLI
(kci) is one-shot — no daemon, no timer, no process that outlives a verb — so it
DECLARES the cadence and stops there. The control plane EVALUATES it: its
promotion sweep advances a deployment track's next auto-update time by the
cadence, driven by the one cloud tick the install already has. There is
deliberately NO per-customer cloud timer — that would be N_orgs x M_apps
scheduler jobs to provision, bill and reconcile.

Tools that expose these operations (scaffold / validate / patch) wrap these
library functions.
"""

