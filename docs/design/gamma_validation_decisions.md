# Gamma validation: kci work and open decisions

This note is the second half of [gamma validation](gamma_validation.md),
which says what checks a release before prod, per package family. It lists
what kci must add before gamma can run a service validation, and the
questions left to the project owner. Section names and item numbers are
referred to from that document.

## What kci must add to run service validations in gamma

None of this exists. Each item is a change to `kci_api`,
`kci_release_machine`, `kci_validate` and `kci.yml`, with a golden test of
the `docker` argv, and gets a design note of its own first.

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
   [Identity and secrets](gamma_validation.md#identity-and-secrets)), and an
   INDETERMINATE outcome for a provider outage.
6. For the release revision: a run of every derived check
   (`release/ci/derive_checks.py`), not only the affected ones, before or
   alongside the `build` stage, so the standalone e2e and conformance checks
   gate a release and not only the pull requests that reached them.

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
   and a contributor without an account cannot reproduce a run locally. (A fork's pull request is not the argument: it
   gets no check whichever emulator is chosen.) *Recommendation:*
   do not adopt it for the public CI. Use moto server (Apache-2.0, no token)
   for broad AWS coverage, verifying fakes for the services where a
   signature check matters, and, if fidelity beyond moto is ever needed,
   apply for the open-source licence and run it only at build time on the
   farm.
3. **moto as the AWS emulator.** *Recommendation:* yes, pinned by digest or
   by package hash, after a probe shows that a corrupted signature turns a
   run red with authentication enabled; until then it proves the protocol,
   not the signature.
4. **Real gamma cloud projects (AWS, GCP, Azure).** Approve the spend and the
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
   #763's native link flags, and add the codec load-origin check in the same
   release that first ships `komira_compression`. That release first needs a
   ` ```mojo ` example in `komira_compression`'s README, which has none.
10. **Format interop in gamma.** *Recommendation:* both: breadth at build
    time with pinned pyarrow, one round trip per format in gamma.
11. **The `validate` job's hour.** Two index waits of 1800 s can use the
    whole 60-minute job, which GitHub then cancels with no verdict.
    *Recommendation:* set the second validation's `wait_for_index_seconds`
    to 600 in `release/machine.textproto` (the first wait has already
    covered a subdir's slow first index), so the waits sum to 40 minutes and
    leave 20 for the installs. A wait that runs out fails the validation
    with a logged reason, which is a verdict; a cancelled job is not. Raise
    `timeout-minutes` only if a measured install needs more.
