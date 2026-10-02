# =============================================================================
# komira_aws_core/credential_chain.mojo -- the AWS default credential chain
# =============================================================================
#
# Finds an AWS credential the way the AWS SDKs' default credential provider
# chain does, in its order:
#   https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html
#
#   1. explicit parameters             -- `AwsCredentialParams.credential`
#   2. environment static keys         -- AWS_ACCESS_KEY_ID,
#                                         AWS_SECRET_ACCESS_KEY,
#                                         AWS_SESSION_TOKEN
#   3. web identity from the environment -- AWS_WEB_IDENTITY_TOKEN_FILE,
#                                         AWS_ROLE_ARN, AWS_ROLE_SESSION_NAME
#   4. the shared config and credentials files, selected profile
#   5. ECS / EKS container credentials -- AWS_CONTAINER_CREDENTIALS_*_URI
#   6. EC2 instance metadata (IMDSv2)  -- unless AWS_EC2_METADATA_DISABLED
#
# The first step that is CONFIGURED answers. A step that is configured but
# broken (a key id without its secret, a token file that cannot be read, a
# named profile that does not exist, an STS refusal) is refused naming the
# setting; the chain does not fall through to a later step and hand back a
# credential the operator did not choose. Only instance metadata, the last
# step, is allowed to be absent: no answer from it means "not on EC2".
#
# Every environment read goes through the `EnvSource`, every file read
# through the `FileSource`, every network exchange through the
# `CredentialTransport`, and the time through the `AwsClock`. komira reads
# only the standard AWS SDK variables, each cited below; its own settings are
# parameters. Refusals name the setting, never its value.
# =============================================================================

from .credential import AwsCredential
from .container_credentials import (
    build_container_request,
    container_endpoint_full,
    container_endpoint_relative,
    parse_container_credentials,
)
from .credential_transport import (
    CredentialHttpRequest,
    CredentialHttpResponse,
    CredentialTransport,
)
from .imds_credentials import (
    build_imds_credentials_request,
    build_imds_role_request,
    build_imds_token_request,
    imds_endpoint,
    parse_imds_credentials,
    parse_imds_role,
    parse_imds_token,
)
from .shared_config import (
    PROFILE_AWS_ACCESS_KEY_ID,
    PROFILE_AWS_SECRET_ACCESS_KEY,
    PROFILE_AWS_SESSION_TOKEN,
    PROFILE_CREDENTIAL_PROCESS,
    PROFILE_CREDENTIAL_SOURCE,
    PROFILE_DURATION_SECONDS,
    PROFILE_EXTERNAL_ID,
    PROFILE_LOGIN_SESSION,
    PROFILE_REGION,
    PROFILE_ROLE_ARN,
    PROFILE_ROLE_SESSION_NAME,
    PROFILE_SOURCE_PROFILE,
    PROFILE_SSO_SESSION,
    PROFILE_SSO_START_URL,
    PROFILE_WEB_IDENTITY_TOKEN_FILE,
    AwsProfile,
    AwsProfileSet,
    load_profiles,
    select_profile,
)
from .sources import AwsClock, EnvSource, FileSource, amz_date_from_unix
from .sts_credentials import (
    TemporaryAwsCredential,
    build_assume_role,
    build_assume_role_with_web_identity,
    check_region,
    check_sts_region,
    parse_sts_credentials,
)
from ._text import is_true_flag, trim


# The longest source_profile chain followed before refusing.
comptime MAX_SOURCE_PROFILE_DEPTH = 8


struct AwsCredentialParams(Copyable, Movable):
    """What the caller states. Each field, when set, wins over everything the
    chain would otherwise read.

    - `credential`: use this credential; the chain reads nothing.
    - `profile`: the shared-file profile, over AWS_PROFILE.
    - `region`: the region, over AWS_REGION and the profile.
    """

    var credential: Optional[AwsCredential]
    var profile: String
    var region: String

    def __init__(out self):
        self.credential = None
        self.profile = String("")
        self.region = String("")


struct ResolvedAwsCredential(Copyable, Movable):
    """The chain's answer: the credential, its expiry ("" when it does not
    expire) and which step produced it (a label, never a secret). Not
    `Writable`."""

    var credential: AwsCredential
    var expiration: String
    var source: String

    def __init__(
        out self, credential: AwsCredential, expiration: String, source: String
    ):
        self.credential = credential
        self.expiration = expiration
        self.source = source


# -----------------------------------------------------------------------------
# Region
# -----------------------------------------------------------------------------


def resolve_aws_region[
    E: EnvSource, F: FileSource
](params: AwsCredentialParams, mut env: E, mut files: F) raises -> String:
    """The region, "" when none is configured.

    https://docs.aws.amazon.com/sdkref/latest/guide/feature-region.html
    Order: the explicit parameter, AWS_REGION, AWS_DEFAULT_REGION (the AWS
    CLI's and Python SDK's spelling), the selected profile's `region`.
    """
    return _resolve_region(params, env, files).region


@fieldwise_init
struct _RegionChoice(Copyable, Movable):
    """The resolved region and the setting it came from ("" when none), so a
    later refusal (the STS partition check) can name that setting."""

    var region: String
    var setting: String


def _resolve_region[
    E: EnvSource, F: FileSource
](params: AwsCredentialParams, mut env: E, mut files: F) raises -> _RegionChoice:
    if params.region.byte_length() > 0:
        check_region(params.region, "the region parameter")
        return _RegionChoice(params.region, String("the region parameter"))
    var r = trim(env.get("AWS_REGION"))
    if r.byte_length() > 0:
        check_region(r, "AWS_REGION")
        return _RegionChoice(r, String("AWS_REGION"))
    r = trim(env.get("AWS_DEFAULT_REGION"))
    if r.byte_length() > 0:
        check_region(r, "AWS_DEFAULT_REGION")
        return _RegionChoice(r, String("AWS_DEFAULT_REGION"))
    var choice = select_profile(params.profile, env)
    var profiles = load_profiles(env, files)
    if not profiles.has_profile(choice.name):
        if choice.named:
            raise Error(
                "the AWS profile '" + choice.name + "' is in neither shared file"
            )
        return _RegionChoice(String(""), String(""))
    r = profiles.profile(choice.name).get(String(PROFILE_REGION))
    var setting = "the region of profile '" + choice.name + "'"
    if r.byte_length() > 0:
        check_region(r, setting)
    return _RegionChoice(r, setting)


def _check_sts_region(region: _RegionChoice) raises:
    """The STS partition refusal, naming the region's setting. The global
    endpoint (no region) needs no check."""
    if region.region.byte_length() > 0:
        check_sts_region(region.region, region.setting)


# -----------------------------------------------------------------------------
# Steps
# -----------------------------------------------------------------------------


def _env_static[E: EnvSource](mut env: E) raises -> Optional[AwsCredential]:
    """Step 2.
    https://docs.aws.amazon.com/sdkref/latest/guide/feature-static-credentials.html
    """
    var key = trim(env.get("AWS_ACCESS_KEY_ID"))
    var secret = trim(env.get("AWS_SECRET_ACCESS_KEY"))
    if key.byte_length() == 0 and secret.byte_length() == 0:
        return None
    if key.byte_length() == 0:
        raise Error("AWS_SECRET_ACCESS_KEY is set but AWS_ACCESS_KEY_ID is not")
    if secret.byte_length() == 0:
        raise Error("AWS_ACCESS_KEY_ID is set but AWS_SECRET_ACCESS_KEY is not")
    var token = trim(env.get("AWS_SESSION_TOKEN"))
    return AwsCredential(key, secret, token)


def _default_session_name[C: AwsClock](mut clock: C) -> String:
    return "komira-aws-" + String(clock.now_unix_seconds())


def _web_identity[
    F: FileSource, T: CredentialTransport
](
    role_arn: String,
    token_file: String,
    session_name: String,
    region: _RegionChoice,
    token_setting: String,
    mut files: F,
    mut transport: T,
) raises -> TemporaryAwsCredential:
    _check_sts_region(region)
    var token = _read_or_refuse(
        files, token_file,
        "cannot read the web identity token file named by " + token_setting,
    )
    var req = build_assume_role_with_web_identity(
        role_arn, session_name, token, region.region
    )
    var resp = _send_or_refuse(
        transport, req, "STS AssumeRoleWithWebIdentity did not answer"
    )
    return parse_sts_credentials(String("AssumeRoleWithWebIdentity"), resp)


def _container[
    E: EnvSource, F: FileSource, T: CredentialTransport
](mut env: E, mut files: F, mut transport: T) raises -> Optional[
    TemporaryAwsCredential
]:
    """Step 5.
    https://docs.aws.amazon.com/sdkref/latest/guide/feature-container-credentials.html
    """
    var rel = trim(env.get("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"))
    var full = trim(env.get("AWS_CONTAINER_CREDENTIALS_FULL_URI"))
    if rel.byte_length() == 0 and full.byte_length() == 0:
        return None
    var ep = (
        container_endpoint_relative(rel)
        if rel.byte_length() > 0
        else container_endpoint_full(full)
    )
    var auth = String("")
    if rel.byte_length() == 0:
        var token_file = trim(env.get("AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE"))
        if token_file.byte_length() > 0:
            auth = _read_or_refuse(
                files,
                token_file,
                "cannot read the file named by"
                " AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE",
            )
        else:
            auth = trim(env.get("AWS_CONTAINER_AUTHORIZATION_TOKEN"))
    var resp = _send_or_refuse(
        transport,
        build_container_request(ep, auth),
        "the container credentials endpoint did not answer",
    )
    return parse_container_credentials(resp)


def _read_or_refuse[F: FileSource](
    mut files: F, path: String, refusal: String
) raises -> String:
    try:
        return trim(files.read(path))
    except:
        raise Error(refusal)


def _send_or_refuse[T: CredentialTransport](
    mut transport: T, req: CredentialHttpRequest, refusal: String
) raises -> CredentialHttpResponse:
    try:
        return transport.send(req)
    except:
        raise Error(refusal)


def _imds[
    E: EnvSource, T: CredentialTransport
](mut env: E, mut transport: T, mut why_not: String) raises -> Optional[
    TemporaryAwsCredential
]:
    """Step 6. Returns None, with `why_not` set, when the metadata service is
    disabled or does not answer the token request.
    https://docs.aws.amazon.com/sdkref/latest/guide/feature-imds-credentials.html
    https://docs.aws.amazon.com/sdkref/latest/guide/feature-imds-client.html
    """
    if is_true_flag(env.get("AWS_EC2_METADATA_DISABLED")):
        why_not = String("disabled by AWS_EC2_METADATA_DISABLED")
        return None
    var ep = imds_endpoint(
        env.get("AWS_EC2_METADATA_SERVICE_ENDPOINT"),
        env.get("AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE"),
    )
    var session = String("")
    try:
        session = parse_imds_token(transport.send(build_imds_token_request(ep)))
    except:
        why_not = String("no answer to the IMDSv2 token request")
        return None
    var role = parse_imds_role(transport.send(build_imds_role_request(ep, session)))
    return parse_imds_credentials(
        transport.send(build_imds_credentials_request(ep, session, role))
    )


def _unsupported_setting(p: AwsProfile) -> String:
    if p.has(String(PROFILE_CREDENTIAL_PROCESS)):
        return String(PROFILE_CREDENTIAL_PROCESS)
    if p.has(String(PROFILE_SSO_SESSION)):
        return String(PROFILE_SSO_SESSION)
    if p.has(String(PROFILE_SSO_START_URL)):
        return String(PROFILE_SSO_START_URL)
    if p.has(String(PROFILE_LOGIN_SESSION)):
        return String(PROFILE_LOGIN_SESSION)
    return String("")


def _profile_static(p: AwsProfile) raises -> Optional[AwsCredential]:
    var key = p.get(String(PROFILE_AWS_ACCESS_KEY_ID))
    var secret = p.get(String(PROFILE_AWS_SECRET_ACCESS_KEY))
    if key.byte_length() == 0 and secret.byte_length() == 0:
        return None
    if key.byte_length() == 0 or secret.byte_length() == 0:
        raise Error(
            "profile '" + p.name + "' sets only one of aws_access_key_id and"
            " aws_secret_access_key"
        )
    return AwsCredential(key, secret, p.get(String(PROFILE_AWS_SESSION_TOKEN)))


def _profile_credential[
    E: EnvSource, F: FileSource, T: CredentialTransport, C: AwsClock
](
    profiles: AwsProfileSet,
    name: String,
    mut visited: List[String],
    region: _RegionChoice,
    mut env: E,
    mut files: F,
    mut transport: T,
    mut clock: C,
) raises -> Optional[TemporaryAwsCredential]:
    """The credential profile `name` yields, None when it holds no credential
    setting.
    https://docs.aws.amazon.com/sdkref/latest/guide/feature-assume-role-credentials.html
    https://docs.aws.amazon.com/sdkref/latest/guide/feature-static-credentials.html
    """
    var p = profiles.profile(name)
    var role_arn = p.get(String(PROFILE_ROLE_ARN))
    var session = p.get(String(PROFILE_ROLE_SESSION_NAME))
    if session.byte_length() == 0:
        session = _default_session_name(clock)
    if role_arn.byte_length() > 0:
        # Refuse an unsupported STS partition before reaching any source.
        _check_sts_region(region)
        var src = p.get(String(PROFILE_SOURCE_PROFILE))
        var csrc = p.get(String(PROFILE_CREDENTIAL_SOURCE))
        var wif = p.get(String(PROFILE_WEB_IDENTITY_TOKEN_FILE))
        var n = 0
        if src.byte_length() > 0:
            n += 1
        if csrc.byte_length() > 0:
            n += 1
        if wif.byte_length() > 0:
            n += 1
        if n != 1:
            raise Error(
                "profile '" + name + "' sets role_arn and must set exactly one"
                " of source_profile, credential_source, web_identity_token_file"
            )
        if wif.byte_length() > 0:
            return _web_identity(
                role_arn, wif, session, region,
                "web_identity_token_file of profile '" + name + "'",
                files, transport,
            )
        var source: AwsCredential
        if src.byte_length() > 0:
            if src == name:
                var own = _profile_static(p)
                if not own:
                    raise Error(
                        "profile '" + name + "' is its own source_profile but"
                        " has no static keys"
                    )
                source = own.value()
            else:
                for i in range(len(visited)):
                    if visited[i] == src:
                        raise Error(
                            "the source_profile chain of profile '" + name
                            + "' loops back to '" + src + "'"
                        )
                if len(visited) >= MAX_SOURCE_PROFILE_DEPTH:
                    raise Error("the source_profile chain is too long")
                if not profiles.has_profile(src):
                    raise Error(
                        "profile '" + name + "' names source_profile '" + src
                        + "', which is in neither shared file"
                    )
                visited.append(name)
                var got = _profile_credential(
                    profiles, src, visited, region, env, files, transport, clock
                )
                if not got:
                    raise Error(
                        "source_profile '" + src + "' of profile '" + name
                        + "' yields no credential"
                    )
                source = got.value().credential
        else:
            source = _credential_source(csrc, name, env, files, transport)
        var req = build_assume_role(
            role_arn,
            session,
            p.get(String(PROFILE_EXTERNAL_ID)),
            p.get(String(PROFILE_DURATION_SECONDS)),
            region.region,
            source,
            amz_date_from_unix(clock.now_unix_seconds()),
        )
        var resp = _send_or_refuse(transport, req, "STS AssumeRole did not answer")
        return parse_sts_credentials(String("AssumeRole"), resp)
    var unsupported = _unsupported_setting(p)
    if unsupported.byte_length() > 0:
        raise Error(
            "profile '" + name + "' uses " + unsupported
            + ", which komira_aws_core does not support"
        )
    var st = _profile_static(p)
    if st:
        return TemporaryAwsCredential(st.value(), String(""))
    return None


def _credential_source[
    E: EnvSource, F: FileSource, T: CredentialTransport
](
    csrc: String, name: String, mut env: E, mut files: F, mut transport: T
) raises -> AwsCredential:
    """credential_source = Environment | Ec2InstanceMetadata | EcsContainer."""
    if csrc == "Environment":
        var c = _env_static(env)
        if not c:
            raise Error(
                "profile '" + name + "' has credential_source Environment but"
                " AWS_ACCESS_KEY_ID is not set"
            )
        return c.value()
    if csrc == "EcsContainer":
        var c = _container(env, files, transport)
        if not c:
            raise Error(
                "profile '" + name + "' has credential_source EcsContainer but"
                " no AWS_CONTAINER_CREDENTIALS_RELATIVE_URI or _FULL_URI is set"
            )
        return c.value().credential
    if csrc == "Ec2InstanceMetadata":
        var why = String("")
        var c = _imds(env, transport, why)
        if not c:
            raise Error(
                "profile '" + name + "' has credential_source"
                " Ec2InstanceMetadata but instance metadata is unavailable: "
                + why
            )
        return c.value().credential
    raise Error(
        "profile '" + name + "' has an unknown credential_source (expected"
        " Environment, Ec2InstanceMetadata or EcsContainer)"
    )


# -----------------------------------------------------------------------------
# The chain
# -----------------------------------------------------------------------------


def resolve_aws_credentials[
    E: EnvSource, F: FileSource, T: CredentialTransport, C: AwsClock
](
    params: AwsCredentialParams,
    mut env: E,
    mut files: F,
    mut transport: T,
    mut clock: C,
) raises -> ResolvedAwsCredential:
    """Runs the default chain; see the module header for the order."""
    # 1. explicit parameters
    if params.credential:
        return ResolvedAwsCredential(
            params.credential.value(), String(""), String("parameter")
        )
    # 2. environment static keys
    var st = _env_static(env)
    if st:
        return ResolvedAwsCredential(st.value(), String(""), String("environment"))
    # 3. web identity from the environment
    # https://docs.aws.amazon.com/sdkref/latest/guide/feature-assume-role-credentials.html
    var token_file = trim(env.get("AWS_WEB_IDENTITY_TOKEN_FILE"))
    var role_arn = trim(env.get("AWS_ROLE_ARN"))
    if token_file.byte_length() > 0 or role_arn.byte_length() > 0:
        if token_file.byte_length() == 0:
            raise Error("AWS_ROLE_ARN is set but AWS_WEB_IDENTITY_TOKEN_FILE is not")
        if role_arn.byte_length() == 0:
            raise Error("AWS_WEB_IDENTITY_TOKEN_FILE is set but AWS_ROLE_ARN is not")
        var session = trim(env.get("AWS_ROLE_SESSION_NAME"))
        if session.byte_length() == 0:
            session = _default_session_name(clock)
        var region = _resolve_region(params, env, files)
        var t = _web_identity(
            role_arn, token_file, session, region,
            String("AWS_WEB_IDENTITY_TOKEN_FILE"), files, transport,
        )
        return ResolvedAwsCredential(
            t.credential, t.expiration, String("web-identity")
        )
    # 4. the shared files
    var choice = select_profile(params.profile, env)
    var profiles = load_profiles(env, files)
    if profiles.has_profile(choice.name):
        var region = _resolve_region(params, env, files)
        var visited = List[String]()
        var got = _profile_credential(
            profiles, choice.name, visited, region, env, files, transport, clock
        )
        if got:
            return ResolvedAwsCredential(
                got.value().credential,
                got.value().expiration,
                "profile " + choice.name,
            )
    elif choice.named:
        raise Error(
            "the AWS profile '" + choice.name + "' is in neither shared file"
        )
    # 5. container credentials
    var c = _container(env, files, transport)
    if c:
        return ResolvedAwsCredential(
            c.value().credential, c.value().expiration, String("container")
        )
    # 6. instance metadata
    var why = String("")
    var m = _imds(env, transport, why)
    if m:
        return ResolvedAwsCredential(
            m.value().credential, m.value().expiration,
            String("instance-metadata"),
        )
    raise Error(
        "no AWS credentials found: no explicit credential; neither"
        " AWS_ACCESS_KEY_ID nor AWS_WEB_IDENTITY_TOKEN_FILE is set; profile '"
        + choice.name + "' holds no credential; neither"
        " AWS_CONTAINER_CREDENTIALS_RELATIVE_URI nor _FULL_URI is set;"
        " instance metadata: " + why
    )
