# param_resolve.mojo — RESOLVE `AppSpec.parameters` INTO CONTAINER ARGV.
#
# A deploy plumbs an app's declared parameters into its container as command-line
# arguments. This is the template->argv half of the parameter model. It takes an
# app's DECLARED parameters plus everything known at deploy time, and produces
# ZERO OR ONE argv token per parameter:
#
#       --<flag>=<value>
#
# ONE `=`-joined token, never `--flag value`. A two-token form is ambiguous the
# moment a value begins with `-`, and Cloud Run `args` is `repeated string` with
# no quoting layer to disambiguate it.
#
# BUNDLE DECLARATION ORDER, ALWAYS, AND NEVER SORTED. A Cloud Run revision's
# argv is part of the revision: two otherwise-identical deploys that order the
# tokens differently produce a NEW revision, a rollout and a cold start, for a
# change that does not exist.
#
# ═══════════════════════════════════════════════════════════════════════════
#  THE REFUSAL IS THE FEATURE
# ═══════════════════════════════════════════════════════════════════════════
#
# A REQUIRED parameter that resolves to nothing REFUSES THE DEPLOY, naming the
# parameter, at COMPOSE/PLAN time — before any cloud call. Not a 422 at the API:
# `kci <app> plan <env>` shows it, no partial deploy is reachable, and it covers
# the OPERATOR path that an API-tier check structurally cannot see.
#
# The failure this prevents: an env var that decodes empty cannot tell "empty"
# from "never configured", so the app runs misconfigured and fails far from the
# cause. A typed parameter with a required/optional contract fails at deploy
# with a NAME instead.

# ═══════════════════════════════════════════════════════════════════════════
#  THIS FILE DOES NOT RENDER ARGV. `kci_params` DOES.
# ═══════════════════════════════════════════════════════════════════════════
#
# `kci_params` is the generic parameter mechanism: obligations, kinds, the
# `--<name>=<value>` spelling, the declaration validator, the argv RENDER and
# the argv PARSE, and the `APP_PARAM:` config encoding.
#
# What this file adds is a way for an app to DECLARE its parameters IN ITS DEPLOY
# TEMPLATE (the bundle's `AppSpec.parameters`), and to resolve them against a
# deploy. So the division of labour is:
#   * `AppSpec.parameters` (app_bundle.proto)  — the TEMPLATE-side declaration;
#   * THIS FILE                                — resolve a declaration against a
#                                                deploy (supplied / per-wave
#                                                override / marker / literal /
#                                                default), and REFUSE a missing
#                                                required one at compose time;
#   * `kci_params.render_app_param_argv`       — the ONE renderer that turns
#                                                resolved values into argv;
#   * `kci_params.parse_app_params`            — the ONE reader the app boots on.
#
# There is deliberately NO second renderer and NO second parser here: two
# mechanisms for one concept is the defect, not the fix.

from kci_params import (
    AppParamValue,
    PARAM_KIND_LITERAL,
    PARAM_KIND_REFERENCE,
    PARAM_KIND_SECRET_REFERENCE,
    render_app_param_argv,
)
from komira_rpc_bundle.app_bundle import (
    AppParameter,
    AppSpec,
    ParamMarker,
    ParamType,
    ValueFrom,
)


# The process exit code a missing-required-parameter refusal uses. DISTINCT from
# 1 (a step failed) and from the lane gate's codes, so a caller can tell "your
# bundle is missing a value" from "the deploy broke".
comptime RC_MISSING_REQUIRED_PARAMETER: Int = 9

# The bundle-side secret handle scheme (`secret://<name>[:<version>]`).
comptime PARAM_SECRET_SCHEME: String = "secret://"
# The version used when a handle names none.
comptime PARAM_SECRET_DEFAULT_VERSION: String = "latest"


# =============================================================================
# THE ARGV ENDPOINT-REFERENCE MARKERS — the argv analogue of `<VAR>__SVCREF`.
#   An endpoint is an OUTPUT of a service, the way CloudFormation has outputs.
# =============================================================================
#
# ── THE PROBLEM THESE SOLVE, STATED AS A SEQUENCE ────────────────────────────
# `compose_api` is PURE: env-agnostic, no cloud call, no clock, byte-identical
# manifest out for the same bundle in. A deployed endpoint is the OPPOSITE of
# that — it is an OBSERVED fact that does not exist until the target service has
# that — it is an OBSERVED fact that does not exist until the target service has
# converged. So compose CANNOT know a URL.
#
# The unresolved state has a TYPED CARRIER, and the refusal lives at the tier
# that can actually observe the answer. An endpoint that cannot be resolved
# still REFUSES THE DEPLOY, BY NAME. There is no arm in this file, or below it,
# that turns an unknown endpoint into a string: emitting a placeholder now and
# rendering *something* meanwhile is how a placeholder ships as a live value.
# ── WHY A MARKER, AND WHY *THIS* MARKER ──────────────────────────────────────
# The env path solves the identical problem: for `VAR = ref("T")` compose emits a
# COMPANION Config entry `<VAR>__SVCREF -> T` carrying T's LOGICAL NAME (never a
# URL, never a vendor token), and a tier that CAN see the deployed world resolves
# it. These tokens are that mechanism, spelled for argv:
#
#     service_ref{service: T}      ->  ${svcref:T}
#     value_from: DEPLOY_URL       ->  ${deploy_url}
#     value_from: EDGE_URL         ->  ${edge_url}
#
# They deliberately reuse the `${…}` marker family `param_marker_token` emits
# (`${project}`, `${region}`) and that the mapper substitutes. That is the ENTIRE
# reason to spell them this way: the substitution tier, its refusal discipline,
# and its drop-vs-refuse rule are one mechanism. A second resolution mechanism
# for endpoints would mean two answers to "what does an unresolved marker do",
# and the two would drift on the day one of them grew a fallback.
#
# ── THE ONE PLACE argv AND env DELIBERATELY DIVERGE ──────────────────────────
# The env marker is resolved AT RUNTIME, IN THE APP, by the service-side
# `ServiceResolver`. These argv markers are resolved AT DEPLOY, BELOW
#
# ── ⚠ THE ONE PLACE argv AND env DELIBERATELY DIVERGE ────────────────────────
# The env marker is resolved AT RUNTIME, IN THE APP, by the service-side
# `ServiceResolver` (REG-2/4). These argv markers are resolved AT DEPLOY, BELOW
# THE LINE, against the SAME `service/<T>` registry records — and that difference
# is a feature, not an inconsistency:
#
#   1. IT KEEPS THE PROPERTY THAT JUSTIFIED argv. The stated reason to prefer
#      argv is that "the effective configuration of a running revision is legible
#      in its own command line". A command line reading `--api-url=${svcref:x}`
#      would forfeit exactly that: you would be back to reading a marker and
#      would forfeit exactly that: you would be back to reading a marker and
#      guessing what it became. Resolved below the line, `gcloud run services
#      describe` shows the REAL endpoint the container was given.
#   2. THE CONSUMER OFTEN CANNOT RESOLVE. A TEST container handed the endpoint
#      it tests has no ServiceResolver, no registry credentials, and no reason
#      to grow either.
#   3. IT MAKES "UNRESOLVABLE" A DEPLOY-TIME REFUSAL INSTEAD OF A BOOT-TIME ONE.
#      Runtime resolution can only fail after the revision exists; deploy-time
#      resolution fails before anything is created, naming the service.
#
# ── THE GRANT IS HALF THE MECHANISM, NOT A DETAIL ────────────────────────────
# A resolved URL the caller may not invoke is a 403 with extra steps. The env arm
# has always emitted an INVOKE_SERVICE grant alongside its marker
# (`_append_grant_nodes`), and a parameter-sourced `service_ref` emits the SAME
# grant from the SAME function — see the `spec.parameters` walk there. Adding the
# token without the grant would have produced a deploy that composes clean, maps
# clean, and 403s on first call.
#
# NAMING RESERVATION (the `SVCREF_MARKER_SUFFIX` precedent): `${svcref:…}`,
# `${deploy_url}` and `${edge_url}` are RESERVED argv value tokens. A parameter
# whose LITERAL value needs one of these strings cannot express it — the same
# closed-vocabulary trade `${project}` already made.
comptime PARAM_SVCREF_TOKEN_OPEN: String = "${svcref:"
comptime PARAM_SVCREF_TOKEN_CLOSE: String = "}"
comptime PARAM_DEPLOY_URL_TOKEN: String = "${deploy_url}"
comptime PARAM_EDGE_URL_TOKEN: String = "${edge_url}"


def param_svcref_token(service: String) raises -> String:
    """The `${svcref:<T>}` token a `service_ref` parameter renders into its argv
    value — T's LOGICAL NAME, never its URL (compose holds no deployed world).

    An EMPTY service name RAISES. `${svcref:}` would substitute to whatever a
    lookup of the empty name returned, and the honest answer to "which service?"
    when the bundle names none is a refusal, not a guess."""
    if service.byte_length() == 0:
        raise Error(
            String(
                "compose: a parameter's 'service_ref' names no service — the"
                " arm is set but `ServiceRef.service` is empty, so there is no"
                " endpoint to resolve. Name the sibling service whose endpoint"
                " this parameter should receive."
            )
        )
    return (
        String(PARAM_SVCREF_TOKEN_OPEN)
        + service
        + String(PARAM_SVCREF_TOKEN_CLOSE)
    )


def param_value_from_token(vf: ValueFrom) raises -> String:
    """The `${…}` token a `value_from` parameter renders into its argv value.

    `VALUE_FROM_DEPLOY_URL` is the SELF wave output (this service's own converged
    URL); `VALUE_FROM_EDGE_URL` is the discovered API-edge URL. Both are observed
    below the line, both are substituted by the same tier as every other marker.

    An UNSPECIFIED `value_from` RAISES, for the identical reason
    `param_marker_token` raises on `PARAM_MARKER_UNSPECIFIED`: an arm that names
    no producer has nothing to resolve to, and the only alternative to refusing
    is writing the literal text `${…}` onto a container's command line."""
    var v = vf.value
    if v == ValueFrom.VALUE_FROM_DEPLOY_URL:
        return String(PARAM_DEPLOY_URL_TOKEN)
    if v == ValueFrom.VALUE_FROM_EDGE_URL:
        return String(PARAM_EDGE_URL_TOKEN)
    # THE MESSAGE MUST NOT ASSERT *WHICH* ARM IT GOT: several arms reach here
    # (UNSPECIFIED, ENV_PROJECT, ENV_REGION, INTERNAL_ORIGIN_URL,
    # VALIDATION_RUN_ID), and an operator hunting a `value_from:` line they
    # never wrote is the cost of a refusal that guesses. State what THIS tier
    # can resolve; the per-arm reason belongs to `validate_bundle`, which
    # refuses each of them by name, offline, before this is reached.
    raise Error(
        String(
            "compose: a SERVED parameter's 'value_from' names something this"
            " tier cannot resolve. A service's argv is rendered at CREATE time,"
            " so the only wave outputs observable here are"
            " VALUE_FROM_DEPLOY_URL (this service's own converged URL, itself"
            " refused as circular below) and VALUE_FROM_EDGE_URL (the"
            " discovered API-edge URL).\n\n  VALUE_FROM_UNSPECIFIED names no"
            " producer at all.\n  VALUE_FROM_INTERNAL_ORIGIN_URL and"
            " VALUE_FROM_VALIDATION_RUN_ID are DIAGNOSTIC-ONLY: they resolve on"
            " a `validate { run_container { … } }` step and are refused on a"
            " served spec by `validate_bundle`, each for its own stated"
            " reason.\n\nNothing was deployed."
        )
    )


def param_flag_for(prm: AppParameter) -> String:
    """The argv long flag, WITHOUT `--`: an authored `flag`, else `name.lower()`
    with `_` -> `-`.

    THE SAME DERIVATION LIVES IN THREE PLACES, deliberately: deploy-time bundle
    validation and the in-process parameter reader compute the same thing, and
    the three live in packages that must not depend on each other — the reader
    is linked into every serving image and may not drag in the deploy schema.
    A test pins them equal, so the duplication cannot drift silently."""
    if prm.flag.byte_length() > 0:
        return prm.flag.copy()
    var out = String("")
    var b = prm.name.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(ord("_")):
            out += String("-")
        elif c >= UInt8(ord("A")) and c <= UInt8(ord("Z")):
            out += String(chr(Int(c) + 32))
        else:
            out += String(chr(Int(c)))
    return out^


def param_marker_token(m: ParamMarker) raises -> StaticString:
    """The `${…}` token a `marker` parameter renders into its argv value.

    WHY A TOKEN AND NOT THE VALUE. `compose_api` is ENV-AGNOSTIC — it has no
    project binding and no region. The marker VALUES are resolved one tier down
    by the mapper, which owns the resolver registry. So compose emits the token
    and the mapper substitutes, which is EXACTLY the seam the env path uses
    (`${project}` in a Config value). Reusing it means a parameter marker and an
    env marker cannot resolve differently.

    An UNSPECIFIED marker RAISES: a marker arm that names no producer would
    otherwise render the literal string `${…}` into a container's command line.

    The deploying caller's identity markers (an app-deployment id, an
    app-signing key set, an org id, an org mail domain) are not kci's to
    resolve: they are facts of whatever system deploys through kci, and that
    system supplies them as ordinary parameters (`supplied` or a per-wave
    literal). Their enum values RAISE here, by name."""
    var v = m.value
    if v == ParamMarker.PARAM_MARKER_PROJECT:
        return "${project}"
    if v == ParamMarker.PARAM_MARKER_REGION:
        return "${region}"
    if v == ParamMarker.PARAM_MARKER_DATASTORE_DATABASE:
        return "${datastore_database}"
    if (
        v == ParamMarker.PARAM_MARKER_APP_DEPLOYMENT_ID
        or v == ParamMarker.PARAM_MARKER_APP_SIGNING_JWKS
        or v == ParamMarker.PARAM_MARKER_ORG_MAIL_DOMAIN
        or v == ParamMarker.PARAM_MARKER_ORG_ID
    ):
        raise Error(
            String("compose: unsupported parameter marker ")
            + m.json_name()
            + String(
                ". kci resolves only markers whose value it can derive from the"
                " deploy target (PARAM_MARKER_PROJECT, PARAM_MARKER_REGION,"
                " PARAM_MARKER_DATASTORE_DATABASE). Supply this value as an"
                " ordinary parameter — `--param NAME=VALUE`, the caller's"
                " supplied map, or a per-wave `parameter_override` literal."
            )
        )
    raise Error(
        String(
            "compose: a parameter's 'marker' is PARAM_MARKER_UNSPECIFIED — it"
            " names no registered producer, so there is nothing to resolve it"
            " to. Naming one is the whole point of the enum: the alternative is"
            " rendering the literal text \"${…}\" into a container's command"
            " line, which is how a placeholder becomes a live value."
        )
    )


def param_secret_resource_name(handle: String) raises -> String:
    """Turn a bundle handle `secret://<name>[:<version>]` into the Secret-Manager
    RESOURCE NAME a secret-reference parameter carries on argv:

        projects/${project}/secrets/<name>/versions/<version>

    A RESOURCE NAME, NOT AN ENV INDIRECTION. Rendering an `env:<NAME>`
    indirection and mounting a `secretKeyRef` under a reserved derived name
    would be a SECOND secret-transport scheme: `kci_params.param_map_is_storable`
    already refuses a SECRET_REFERENCE whose value is not a `projects/` resource
    name, precisely so a deploying system stores references and never material.
    The existing convention needs no reserved env name, no mount and no
    in-process dereference — the app resolves the reference it is handed.

    The `${project}` token is left for the mapper to substitute, the same seam
    every other marker uses; compose holds no project binding."""
    var body = handle
    if body.startswith(String(PARAM_SECRET_SCHEME)):
        # `body = String(body[...])` ALIASES -- the initializer reads `body`
        # while the assignment constructs into it. Bind, then transfer.
        var stripped = String(body[byte=PARAM_SECRET_SCHEME.byte_length() :])
        body = stripped^
    var name = body
    var version = String(PARAM_SECRET_DEFAULT_VERSION)
    var colon = body.find(String(":"))
    if colon >= 0:
        name = String(body[byte=0:colon])
        version = String(body[byte = colon + 1 :])
    if name.byte_length() == 0:
        raise Error(
            String("compose: a secret parameter's handle '")
            + handle
            + String("' names no secret")
        )
    return (
        String("projects/${project}/secrets/")
        + name
        + String("/versions/")
        + version
    )


def _missing_required_error(
    app: String, env: String, prm: AppParameter, tried: String
) -> String:
    """The rc=9 refusal.

    THIS TEXT IS A PRODUCT SURFACE, NOT A LOG LINE. It is what an operator
    reads when a deploy stops, and the entire justification for the parameter
    model is that they read THIS instead of chasing a downstream symptom while
    the real cause is an unset value. So it names the app, the parameter, the
    flag it would have rendered, the declared type, the author's own
    `description` VERBATIM, every source that was tried IN ORDER, and the fact
    that nothing was deployed."""
    var ty = prm.type.json_name()
    var req = String("required")
    if prm.default.byte_length() > 0:
        req += String(", default \"") + prm.default + String("\"")
    else:
        req += String(", no default")
    var purpose = prm.description.copy()
    if purpose.byte_length() == 0:
        purpose = String("(the bundle declares no description for it)")
    return (
        String("kci ")
        + app
        + String(" deploy ")
        + env
        + String(": MISSING REQUIRED PARAMETER\n\n")
        + String("  app        ")
        + app
        + String("\n")
        + String("  parameter  ")
        + prm.name
        + String("  (--")
        + param_flag_for(prm)
        + String(")\n")
        + String("  type       ")
        + ty
        + String(", ")
        + req
        + String("\n")
        + String("  purpose    ")
        + purpose
        + String("\n")
        + String("  sources    tried, in order: ")
        + tried
        + String("\n\nNothing was deployed.")
    )


def resolve_parameter_args(
    app: String,
    env: String,
    spec: AppSpec,
    overrides: Dict[String, String],
    supplied: Dict[String, String],
) raises -> List[String]:
    """Resolve every declared parameter into ZERO OR ONE `--flag=value` token.

    RESOLUTION ORDER, first that applies:
      1. SUPPLIED — the deploying caller's opaque parameter map, or `--param
         NAME=VALUE` on an operator deploy.
      2. `Wave.parameter_override` for the target env.
      3. `marker` / `secret_ref` / `value_from` / `service_ref` — the typed
         deploy-time producers. The last two render an ENDPOINT MARKER
         (`${deploy_url}` / `${edge_url}` / `${svcref:T}`) that the below-the-line
         tier substitutes against the observed deployed world; see the marker
         block above for why the resolution happens THERE and not here.
      4. `value` — the bundle literal.
      5. `default` — only when `required` is false.
      6. REFUSE, when `required` is true.

    AND WHEN NOTHING APPLIES AND THE PARAMETER IS *OPTIONAL*, THE FLAG IS
    OMITTED — not rendered empty. `--x=` says "configured to nothing"; an absent
    flag says "never configured". `getenv` cannot express that distinction and
    argv can, which is the technical reason configuration is passed as flags."""
    # Resolved VALUES, not argv strings. The argv spelling is `kci_params`'
    # business — this file decides WHAT each parameter resolves to, and that
    # module decides how a resolved value is written on a command line.
    var resolved = List[AppParamValue]()
    for ref prm in spec.parameters:
        if prm.name.byte_length() == 0:
            raise Error(
                String("compose: app '")
                + app
                + String("' declares a parameter with no 'name'")
            )
        var flag = param_flag_for(prm)

        # (1) SUPPLIED — the caller's generic map / operator --param.
        if prm.name in supplied:
            resolved.append(
                AppParamValue(flag, supplied[prm.name], PARAM_KIND_LITERAL)
            )
            continue
        # (2) the selected wave's per-ENV binding.
        if prm.name in overrides:
            resolved.append(
                AppParamValue(flag, overrides[prm.name], PARAM_KIND_LITERAL)
            )
            continue
        # (3) the typed deploy-time producers.
        if prm._oneof0_case == 3:  # marker
            resolved.append(
                AppParamValue(
                    flag, param_marker_token(prm.marker.value()),
                    PARAM_KIND_LITERAL,
                )
            )
            continue
        if prm._oneof0_case == 2:  # secret_ref
            # A REFERENCE, NEVER THE CREDENTIAL. What rides argv is the
            # Secret-Manager RESOURCE NAME; the app resolves it. A literal secret
            # here would sit in /proc/self/cmdline (mode 0444), in every `gcloud
            # run services describe` output, and in deploy audit logs.
            resolved.append(
                AppParamValue(
                    flag,
                    param_secret_resource_name(prm.secret_ref.value()),
                    # TAGGED AS A SECRET REFERENCE so `param_map_is_storable` (via
                    # the renderer) enforces that what travels is a `projects/`
                    # RESOURCE NAME and not secret material — the NO LEAK property,
                    # for free, from the mechanism that already owns it.
                    PARAM_KIND_SECRET_REFERENCE,
                )
            )
            continue
        if prm._oneof0_case == 4:  # value_from — the SELF wave output
            # THE ENDPOINT REFERENCE, AS A TYPED MARKER. Compose is env-agnostic
            # and pure, so THIS tier can never know a URL, and inventing one here
            # is how a placeholder ships as a live value. What it emits is the
            # LOGICAL marker `${deploy_url}` / `${edge_url}` — the argv analogue
            # of the env path's `<VAR>__SVCREF` — and the tier that CAN observe
            # a deployed endpoint substitutes it, or refuses by name.
            resolved.append(
                AppParamValue(
                    flag,
                    param_value_from_token(prm.value_from.value()),
                    # PARAM_KIND_REFERENCE, not LITERAL: what travels is a
                    # reference to a value, not the value. The kind is what lets
                    # a reader downstream tell "this was authored as an endpoint
                    # reference" from "somebody typed a URL".
                    PARAM_KIND_REFERENCE,
                )
            )
            continue
        if prm._oneof0_case == 5:  # service_ref — a SIBLING/PEER endpoint
            # THE CROSS-SERVICE ENDPOINT REFERENCE. Same mechanism as above,
            # carrying T's LOGICAL NAME (`${svcref:T}`) exactly as the env arm's
            # `<VAR>__SVCREF -> T` companion entry does — no URL, no vendor
            # token, nothing this pure tier is not entitled to know.
            #
            # THE MATCHING INVOKE_SERVICE GRANT IS EMITTED BY
            # `compose_api._append_grant_nodes`, WHICH WALKS `spec.parameters`
            # FOR THIS ARM. A resolved URL without the grant is a 403 with extra
            # steps, so the two are emitted from one pass over one bundle and
            # cannot come apart.
            resolved.append(
                AppParamValue(
                    flag,
                    param_svcref_token(prm.service_ref.value().service),
                    PARAM_KIND_REFERENCE,
                )
            )
            continue
        if prm._oneof0_case == 1:  # bundle literal
            resolved.append(
                AppParamValue(flag, prm.value.value(), PARAM_KIND_LITERAL)
            )
            continue
        if prm._oneof0_case == 6:  # from_build (field 18)
            # REFUSED, NOT FALLEN THROUGH. `validate_bundle` refuses it by name
            # first; this is the compose-side twin for a bundle that reached
            # compose without it. Falling through would resolve an OPTIONAL
            # `from_build` parameter to NOTHING and omit its flag — a service
            # booting without a value its bundle says it has.
            raise Error(
                String("compose: app '")
                + app
                + String("' parameter '")
                + prm.name
                + String(
                    "' is sourced `from_build`, which this tier cannot resolve."
                    " Nothing was deployed."
                )
            )
        # (5) the default — OPTIONAL parameters only (validate refuses the pair).
        if prm.default.byte_length() > 0 and not prm.required:
            resolved.append(
                AppParamValue(flag, prm.default, PARAM_KIND_LITERAL)
            )
            continue
        # (6) nothing applied.
        if prm.required:
            raise Error(
                _missing_required_error(
                    app,
                    env,
                    prm,
                    String("--param ")
                    + prm.name
                    + String("=…, wave '")
                    + env
                    + String(
                        "' parameter_override, the declared source (marker /"
                        " secret_ref / literal value), default"
                    ),
                )
            )
        # OPTIONAL AND UNRESOLVED ⇒ THE FLAG IS OMITTED. Not `--flag=`.
    # ONE renderer, and it is not this file's. `render_app_param_argv` is the
    # declaration-free render — the same spelling `parse_app_params` reads — and
    # it additionally enforces NO LEAK (a SECRET_REFERENCE row must carry a
    # reference) and refuses an EMPTY transported value, which is the same
    # absent-vs-empty rule stated one tier down.
    return render_app_param_argv(resolved)


def wave_parameter_overrides(
    waves_env: List[String], waves_params: List[List[AppParameter]], env: String
) raises -> Dict[String, String]:
    """The per-ENV parameter-override map for the wave whose `env` matches.

    Only the LITERAL `value` arm is honored, mirroring `_wave_env_override`
    exactly: a `marker` / `value_from` / `service_ref` override is a dynamic
    source, not a per-env literal, and honoring one here would mean two places
    decide the same value. No matching wave, or no overrides, ⇒ an EMPTY map ⇒
    the spec-level declaration stands."""
    var out = Dict[String, String]()
    for i in range(len(waves_env)):
        if waves_env[i] == env:
            ref ps = waves_params[i]
            for j in range(len(ps)):
                if ps[j]._oneof0_case == 1:
                    out[ps[j].name.copy()] = ps[j].value.value().copy()
            break
    return out^


# ═══════════════════════════════════════════════════════════════════════════
#  THE ENDPOINT-MARKER RESOLVER — ONE AUTHOR ONLY
# ═══════════════════════════════════════════════════════════════════════════
#
# `${svcref:T}` reaches TWO sinks: a service's container ARGV (the GCP arm) and
# a LAMBDA'S ENVIRONMENT plus an API edge's `identity_issuer` (the AWS arm).
# Both must refuse an unresolvable reference with the SAME sentence, because the
# sentence is the whole product of the refusal — it names the service, says what
# would have happened, and lists the three things an absent record can mean.
#
# The two arms do not import each other, so a copy in each would be two authors
# of one refusal text — two things to keep in agreement, with the drift
# invisible until an operator reads the wrong half. `param_resolve` is where the
# tokens it keys on are DECLARED (`PARAM_SVCREF_TOKEN_OPEN` and its siblings,
# above), it is a pure String/Dict transform with no store and no cloud, and
# both arms depend on this package. The resolver and the vocabulary it resolves
# live in one file, which is the only arrangement in which "the tokens and their
# meaning cannot come apart" is structural rather than a convention.
def resolve_endpoint_arg_marker(
    where: String,
    value: String,
    edge_url: String,
    endpoint_refs: Dict[String, String],
) raises -> String:
    """SUBSTITUTE THE ENDPOINT MARKERS in ONE argv VALUE. Returns the value with
    `${svcref:T}` / `${edge_url}` replaced by the OBSERVED endpoint; RAISES,
    naming the reference, when it cannot.

    ── THERE IS NO ARM HERE THAT INVENTS A URL, AND THAT IS THE FEATURE ────────
    Every failure path in this function is a `raise`. Not a placeholder, not an
    empty flag, not a plausible-looking default. The refusal reappears HERE, at
    the tier that can actually observe an answer: it names the service, and it
    says what would have happened.

    An unresolvable ENDPOINT is never a correct deploy: the container's entire
    job is to talk to that endpoint, and dropping the flag would start it with
    no target (empty rendered as configured). So endpoints raise. The question
    is always "is nothing a legitimate answer here", and for an endpoint it
    never is.

    `endpoint_refs` maps a LOGICAL service name -> its observed URL, resolved by
    the caller from the `service/<name>` registry records the deploy writes
    post-converge — the SAME store `kci outputs` reads. An EMPTY map is the
    honest state of a caller that has not wired the lookup: every reference then
    refuses BY NAME rather than silently rendering something."""
    var out = value.copy()

    # ── `${deploy_url}` — SELF, and REFUSED HERE ON PURPOSE ──────────────────
    # THIS IS A CIRCULARITY, NOT A MISSING FEATURE, and saying so precisely is
    # worth more than a resolver that half-works. `VALUE_FROM_DEPLOY_URL` names
    # the SERVICE'S OWN converged URL, and this tier renders the argv the service
    # is CREATED with — the URL does not exist yet, because assigning it is what
    # creating the service does. No ordering of these two operations exists.
    #
    # A validate STEP has no such problem (it runs after its subject converged),
    # which is exactly why the validate driver resolves `VALUE_FROM_DEPLOY_URL`
    # and this function cannot. The message says which of the two an author
    # wanted.
    if out.find(String(PARAM_DEPLOY_URL_TOKEN)) >= 0:
        raise Error(
            String("map_manifest_to_graph: ")
            + where
            + String(
                " asks for `value_from: VALUE_FROM_DEPLOY_URL`, which is THIS"
                " service's OWN converged URL — and a service cannot be handed"
                " its own URL on the command line it is created with, because"
                " the URL is assigned BY that creation. This is circular, not"
                " unimplemented.\n\n  If you want a PEER's endpoint, use"
                " `service_ref { service: \"<name>\" }` — it resolves from the"
                " deploy's service registry and emits the INVOKE_SERVICE grant"
                " too.\n  If you want THIS service's URL inside a TEST, declare"
                " the arg on the wave's `validate { run_container { args {} } }`"
                " — a validate step runs after convergence, so"
                " VALUE_FROM_DEPLOY_URL resolves there.\n\nNothing was deployed."
            )
        )

    # ── `${edge_url}` — the DISCOVERED API-edge URL ──────────────────────────
    if out.find(String(PARAM_EDGE_URL_TOKEN)) >= 0:
        if edge_url.byte_length() == 0:
            raise Error(
                String("map_manifest_to_graph: ")
                + where
                + String(
                    " asks for `value_from: VALUE_FROM_EDGE_URL`, and no API-edge"
                    " URL was discovered for this environment. Refusing rather"
                    " than rendering the flag empty: a container told its target"
                    " is the empty string treats that as authoritative and fails"
                    " later as an unattributable error. Nothing was deployed."
                )
            )
        out = out.replace(String(PARAM_EDGE_URL_TOKEN), edge_url)

    # ── `${svcref:T}` — a PEER service's endpoint, by LOGICAL NAME ───────────
    # PARAMETRIC, which is why these markers are NOT in the mapper's fixed
    # marker registry and must not be added to it. That registry's contract is
    # "one fixed token <-> one mapper String parameter <-> one named producer
    # symbol"; `${svcref:T}` has no fixed spelling and no single scalar producer
    # — it is a LOOKUP keyed by a name. Kinds that differ should not share a
    # mechanism.
    while True:
        var open_at = out.find(String(PARAM_SVCREF_TOKEN_OPEN))
        if open_at < 0:
            break
        var name_at = open_at + len(String(PARAM_SVCREF_TOKEN_OPEN).as_bytes())
        var rest = String(out[byte=name_at:])
        var close_rel = rest.find(String(PARAM_SVCREF_TOKEN_CLOSE))
        if close_rel < 0:
            raise Error(
                String("map_manifest_to_graph: ")
                + where
                + String(" carries a malformed service reference '")
                + out
                + String(
                    "' — a `${svcref:<service>}` marker with no closing brace."
                    " Refusing: the alternative is stamping the literal marker"
                    " text onto a container's command line."
                )
            )
        var target = String(rest[byte=0:close_rel])
        if target.byte_length() == 0:
            raise Error(
                String("map_manifest_to_graph: ")
                + where
                + String(
                    " carries a `${svcref:}` marker naming no service. Refusing:"
                    " there is no endpoint to look up."
                )
            )
        if target not in endpoint_refs:
            raise Error(
                String("map_manifest_to_graph: ")
                + where
                + String(" references the endpoint of service '")
                + target
                + String("', and no deployed URL is recorded for '")
                + target
                + String(
                    "' in this environment's service registry"
                    " (`service/<name>`).\n\nThat means one of three things, and"
                    " the deploy refuses rather than guess between them:\n  * '"
                )
                + target
                + String(
                    "' has never been deployed into this environment — deploy it"
                    " first;\n  * it is deployed by a bundle in THIS graph that"
                    " has not converged yet — a same-graph forward reference"
                    " cannot be resolved on argv, use an env `service_ref`"
                    " (runtime-resolved) for that;\n  * the name is a typo.\n\n"
                    "Refusing is the point: rendering a plausible URL here is"
                    " exactly how a hand-typed hostname goes stale silently, and"
                    " rendering the flag EMPTY would start the container with no"
                    " target. Nothing was deployed."
                )
            )
        var url = endpoint_refs[target].copy()
        if url.byte_length() == 0:
            raise Error(
                String("map_manifest_to_graph: ")
                + where
                + String(" resolved the endpoint of service '")
                + target
                + String(
                    "' to the EMPTY STRING. A recorded-but-empty URL is a"
                    " corrupt registry record, not a configuration choice."
                    " Nothing was deployed."
                )
            )
        out = (
            String(out[byte=0:open_at])
            + url
            + String(
                out[
                    byte = name_at
                    + close_rel
                    + len(String(PARAM_SVCREF_TOKEN_CLOSE).as_bytes()) :
                ]
            )
        )
    return out^

