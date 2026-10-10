# Gamma validation: kci work and open decisions

This note is the second half of [gamma validation](gamma_validation.md),
which says what checks a release before prod, per package family. It lists
what kci must add before gamma can run a service validation, and the
questions left to the project owner. Section names and item numbers are
referred to from that document.

**Vocabulary.** This note and [gamma validation](gamma_validation.md)
predate the staged pipeline's [glossary](staged_pipeline.md#glossary). Here
"gamma" means today's stage that publishes to the conda channel `gamma` and
installs from it, which the glossary calls **beta** (the beta channel and
`beta_validate`); the glossary's gamma holds only real cloud resources.
Open decision 4 below already uses the glossary's words.

## What kci must add to run service validations in gamma

None of this exists. Each item is a change to `kci_api`,
`kci_release_machine`, `kci_validate` and `kci.yml`, with a golden test of
the `docker` argv, and gets a design note of its own first. An item that
changes the shape of `kci.yml`'s jobs also changes `kci_workflow_check`,
whose rules `kci run` applies to the workflow it runs under (item 7).

1. A `service` block on `CONDA_INSTALL_SMOKE`: a digest-pinned image, a
   port, readiness; kci starts it with the same hardening as the program's
   container, on a per-validation internal docker network, writes the
   endpoints to a file in `/work` (configuration is a file or a flag, not an
   environment variable), runs the program, and tears the service down.
2. The network check must learn service hosts, so a service that never
   answers is a FAIL or INDETERMINATE, never a pass.
3. For an interop leg: a closed-vocabulary way to install a pinned
   third-party package from `extra_channel` and a second `smoke` word.
4. For a build-mode README run: a `smoke` word or an automatic switch when
   the install holds a per-library archive.
5. For a real cloud project: a DEPLOY body, a cell field (both reserved:
   `src/kci_api/verbs.mojo`, `src/kci_release_machine/graph.mojo`), a verb
   that sets the validation run id, a bootstrap for the federated identity
   (described under
   [Identity and secrets](gamma_validation.md#identity-and-secrets)), an
   INDETERMINATE outcome for a provider outage, and two paths into the
   program under test that do not exist:
   - **A credential.** kci, in the job holding the identity token,
     exchanges it for a short-lived credential scoped to the gamma project
     and writes it to a file under `/work`. This relaxes the isolation
     `src/kci_validate/container.mojo` states at lines 40 to 44 (four fixed
     `-e` variables; "a CI job's token request variables and secrets never
     reach the consumer") and `src/kci_validate/env.mojo` at lines 28 to 37
     (the cleared environment): the program would hold a live, if
     short-lived and scoped, cloud credential.
   - **The validation run id.** kci writes it to a second file under
     `/work`, and the program stamps every resource it creates with
     `komira_validation_run`'s `kci-run-id` label, or names it under a
     run-scoped prefix where a type takes no label. `kci_cloud`'s stamping
     (`src/kci_cloud/adapter.mojo`) covers only objects `kci_cloud` creates,
     not those a program creates through `komira_aws_*`, `komira_gcp_*` or
     `komira_azure_*`. A resource stamped neither way is invisible to the
     sweeper and keeps billing, so the program's own cleanup (delete, list
     again, CLEAN or fail) is required, with the sweeper as the backstop.
6. For the release revision: a run of every derived check
   (`release/ci/derive_checks.py`), not only the affected ones, before or
   alongside the `build` stage, so the standalone e2e and conformance checks
   gate a release and not only the pull requests that reached them. It is
   unsized: the `build` job has `timeout-minutes: 120` (`kci.yml`) and its
   release builds took 402 to 1659 s in the five runs decision 11 cites,
   but every derived check builds every package's standalone tests, not
   only the released libraries, so its duration and farm cost need a
   measurement and a note of their own before it joins that job.
7. For any new job: amendments to the workflow rules of
   `src/kci_workflow_check/rules.mojo`, which `kci run` checks at start-up
   against the workflow it runs under (`check_running_workflow`), so a job
   the rules refuse cannot run kci at all. Today:
   - **R1**: every job is either the job named after a stage or a part job
     of one (`kci run --stage <S> --only ...`); there is no third kind.
   - **R2**: the job named after a stage runs in that stage's environment; a
     part job runs in **no** environment.
   - **R3**: a job's `needs` is exactly the jobs of its stage's `after`,
     the part jobs included, so `prod` needs every part job of `gamma`: a
     part job cannot be advisory. A part job's own `needs` is the job named
     after its stage plus that stage's `after` (R9, `_check_split`).
   - **R4**: `id-token: write` only on a job whose stage publishes by OIDC
     trusted publishing or is farm-connected; "No other job carries it".
   - **R9**: a part job runs validations only, holds no environment, no
     identity token and no farm connection, and the stage's jobs together
     run every step and validation exactly once.
   A service validation that needs none of these (item 1, emulator-only)
   fits today as a second part job of `gamma` with its own
   `timeout-minutes` (R9 as amended, which is itself pending a ruling), and
   then blocks prod. A real-cloud validation (item 5, open decision 4)
   needs a GitHub environment and an identity token and is meant to be
   advisory: as a part job it collides with R2, R4 and R9; as a stage of its
   own it needs a new R4 reason (validating against a cloud is neither
   publishing nor farm-connected), and to be advisory `prod`'s `after` must
   leave it out (R3). A job in a third workflow file is no way out: `kci
   run` holds any workflow other than the pull request's check to the
   release workflow's rules, and R1 then refuses a file without every
   stage's job. Every such job also carries R19's set hash and R20's `the
   prod line` (`src/kci_workflow_check/auto_promotion.mojo`). The
   amendments, or a ruling that the job does not run `kci run` and how it
   is then gated, come before any of these jobs.
8. For an installed native package: a check of the `.so` the channel
   serves, by the same rules as `tools/build/native/native_check.sh` (on the
   native stack's branches) plus the highest `GLIBC_` symbol version against
   the declared `__glibc` floor. Either a new `smoke` word that
   `kci_validate` runs on the installed file, or a `CONDA_INSTALL_SMOKE`
   program, which needs an ELF dynamic-symbol reader in Mojo (none exists)
   and a pinned image. Loading it beside OpenSSL also needs item 3.

## Open decisions (for the project owner)

Each is a question with a recommendation; none is decided by this document.

1. **Service validations in gamma, or at build time only?** Add a `service`
   sidecar to `CONDA_INSTALL_SMOKE`, or keep gamma install-only and put
   service tests on the farm at build time? *Recommendation:* build time
   first. Gamma's job is "what was published installs and works", which the
   README check proves; revisit when a service test against installed bytes
   would catch a defect class the build cannot. *Precondition:* this
   recommendation gates a release only once item 6 of "What kci must add"
   above exists. Today the release `build` stage runs no standalone e2e,
   conformance or service test, so accepting "build time" without item 6
   means those checks gate pull requests and not releases, and two pull
   requests that each passed alone can ship a broken combination.
   Accepting this decision is accepting item 6 as required work.
2. **LocalStack.** Current LocalStack for AWS images require an auth token
   to start, including for the services the former community image
   covered; earlier version tags still run without one but receive no
   service or security updates. The free Hobby plan is for non-commercial
   use; ECR and ECS are listed under paid plans (Base and above); an
   open-source licence is by application. (Checked 2026-10-07 against
   LocalStack's [auth token page](https://docs.localstack.cloud/aws/getting-started/auth-token/),
   [The road ahead for LocalStack](https://blog.localstack.cloud/the-road-ahead-for-localstack/),
   its [pricing page](https://www.localstack.cloud/pricing) (Hobby, and
   "Request Open Source Licensing"), and its
   [ECR](https://docs.localstack.cloud/aws/services/ecr/) and
   [ECS](https://docs.localstack.cloud/aws/services/ecs/) service pages.) A
   token is a secret: it cannot reach the `validate` job without weakening
   its isolation
   ([What constrains gamma?](gamma_validation.md#what-constrains-gamma)),
   and a contributor without an account cannot reproduce a run locally. (A
   fork's pull request is not the argument: it gets no check whichever
   emulator is chosen.) *Recommendation:* do not adopt it for the public
   CI. Use moto server (Apache-2.0, no token) for broad AWS coverage,
   verifying fakes for the services where a signature check matters, and,
   if fidelity beyond moto is ever needed, apply for the open-source licence
   and run it only at build time on the farm.
3. **moto as the AWS emulator.** *Recommendation:* yes, pinned by digest or
   by package hash, after a probe shows that a corrupted signature turns a
   run red with authentication enabled; until then it proves the protocol,
   not the signature.
4. **Real gamma cloud projects (AWS, GCP, Azure).** *Superseded:* the
   project owner ruled that the real-cloud tests are ordinary kci validations
   of the gamma stage, run with the `gamma` environment's federated (OIDC)
   credential, and that a red one **blocks** prod rather than advising:
   [the staged pipeline, e2](staged_pipeline.md#e2-gamma-real-cloud-tests-as-ordinary-validations).
   The spend is ruled. Under the vocabulary ruling the conda channel this
   document calls `gamma` becomes `beta` (the staged pipeline, section e3)
   and gamma holds only real cloud resources, so the `gamma` environment is
   trusted by the gamma accounts' roles and by no channel, which is what the
   separate environment proposed below was for. Locking `gamma` to `main`
   and retiring the old channel's trust of `gamma` come first. The keyless-identity prerequisites below still decide when GCP and
   Azure join (AWS first). The text below is the earlier recommendation, kept
   for its reasoning. Approve the spend and the
   one-time bootstrap? *Recommendation:* not yet. First land keyless identity
   (`external_account` in `komira_gcp_core`, a federated credential in
   `komira_azure_core`), the verb that sets the validation run id, and the
   billing-stop automation. Then start with GCP (most clients without an
   emulator), read-mostly, in its own job and environment, and advisory
   rather than blocking prod until it has a month of history. Proposed
   bounds for the owner to set: a monthly ceiling per cloud (for example
   USD 50), a budget alert at half of it, and the billing stop at the
   ceiling; the billing-stop automation is owned by whoever owns the
   bootstrap verb, and is created by it. The federated trust names a new
   GitHub environment (for example `gamma-cloud`) used only by that job, not
   `gamma` or `gamma-breakglass`: those two get different `sub` claims, and
   a trust naming either would hand cloud access to the publish job.
   *Accepting this accepts item 7:* a job with its own environment and an
   identity token that does not block prod is refused today by the workflow
   rules R2, R3, R4 and R9 (`src/kci_workflow_check/rules.mojo`), and the
   rules gate the publish jobs' token; the amendment needs its own ruling.
   It also accepts item 5's two new paths: a short-lived cloud credential
   reaching the program under test (relaxing
   `src/kci_validate/container.mojo` lines 40 to 44, or `env.mojo` lines 28
   to 37), and a program that stamps and deletes what it creates, since kci
   stamps only what `kci_cloud` creates.
5. **Emulator images and jars at build time.** May the pull request's check
   pull Google's emulator images and other service images? *Recommendation:*
   yes, by digest only, after a farm capability row proves Docker (or the
   chosen process form) works in a test action. Check the Firestore
   emulator's redistribution terms before pinning a copy anywhere komira
   publishes; pulling Google's image at test time is the lower-risk path.
6. **MinIO.** *Recommendation:* keep it for the existing opt-in S3 tests and
   plan its retirement; choose a maintained permissive S3-compatible server
   (moto, or SeaweedFS after a probe of `If-None-Match`/`If-Match`) for the
   `ConditionalWriteStore` suite.
7. **TLS in a README example.** A loopback TLS example needs a certificate,
   and a shipped README can neither link a fixture file nor carry one into a
   container. Options: an inline throwaway key in a public README, an
   in-process self-signed certificate helper in `komira_crypto` (none
   exists), or plaintext-only loopback examples. *Recommendation:* plaintext
   loopback in the README now; the certificate helper as follow-up work.
8. **The per-library archive.** *Recommendation:* add the build-mode README
   check before `komira_log`, or any library above it, is declared for
   release; otherwise `install-set` fails on the first such release.
9. **Codec origin and native link flags.** *Recommendation:* land open PR
   #763's native link flags with #761 or before it, never after: #761
   declares `komira_libc`, `komira_buffer`, `komira_async_api` and
   `komira_native`, and only #763 adds `-Xlinker -lkomira_native` to
   `kci_validate`'s README runs. If #761 merges and a push releases before
   #763, `install-set`'s `mojo run` of those READMEs cannot resolve the
   native symbols: gamma fails and prod is blocked (closed, not silent).
   So: merge the two together, or land #763's `kci_validate` change first.
   Add the codec load-origin check (a `CONDA_INSTALL_SMOKE` program; see
   the formats table of [gamma validation](gamma_validation.md)) in the same
   release that first ships `komira_compression`. That release first needs
   a ` ```mojo ` example in `komira_compression`'s README, which has none,
   a digest-pinned image for the kind, and the validation named in the
   `validate` job's `--only` list (R9).
10. **Format interop in gamma.** *Recommendation:* both: breadth at build
    time with pinned pyarrow, one round trip per format in gamma.
11. **The `validate` job's hour.** Two index waits of 1800 s can use the
    whole 60-minute job, which GitHub then cancels with no verdict.
    *Recommendation:* set the second validation's `wait_for_index_seconds`
    to 600 in `release/machine.textproto` (the first wait has already
    covered a subdir's slow first index), so the waits sum to 40 minutes and
    leave 20 for the installs. Measured: the whole `validate` job took 151
    to 208 s in five consecutive successful `kci.yml` runs on `main` on
    2026-10-07 (job `startedAt` to `completedAt`; run 37688200088 took
    192 s, of which its one `kci run` step took 181 s). That step holds
    both validations' waits, two pixi solves and the README runs of 37
    libraries, so they are not timed apart. It is far under 20 minutes
    today, and grows with each member (46 or more after #755 and #761). A wait that runs out fails the
    validation with a logged reason, which is a verdict; a cancelled job is
    not. Raise `timeout-minutes` only if a measured run needs more. The
    trade: `install-set` (`komira_all` and every member) pins a superset of
    `install-komira-encoding`'s files, so if the channel has indexed
    `komira_encoding` but not the rest, a 600 s second wait turns a slow
    index into a red verdict, a flake traded for the job's hour. The
    alternative is to give the long wait to `install-set` and the short one
    to `install-komira-encoding`, which only helps if the superset runs
    first; which order kci runs a step's validations in is not checked
    here.
