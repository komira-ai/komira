"""Execution platforms. Every action runs remotely; nothing runs on the client.

Each execution platform realizes one of the abstract configurations in
//tools/build/platforms (`exec-light`, `exec-mojo`, `exec-mojo-multi-numa`); the
worker property set behind it is read from `.buckconfig.local`
(`[komira_re] <key> = key=value,...`) so that no service address or pool name
is committed.
"""

def re_properties(key, required = True):
    """Parse `[komira_re] <key>` into a dict.

    Fails if unset and `required`; returns None if unset and not `required`.
    """
    raw = read_config("komira_re", key, "")
    if not raw.strip():
        if not required:
            return None
        fail(("`[komira_re] {}` is not set. Copy .buckconfig.local.example to " +
              ".buckconfig.local and fill in your remote-execution worker properties.").format(key))
    props = {}
    for pair in raw.split(","):
        pair = pair.strip()
        if not pair:
            continue
        if "=" not in pair:
            fail("`[komira_re] {}`: expected key=value, got `{}`".format(key, pair))
        k, v = pair.split("=", 1)
        props[k.strip()] = v.strip()
    return props

def _remote_platforms_impl(ctx):
    platforms = []
    for name, (constraints_dep, props) in zip(ctx.attrs.names, zip(ctx.attrs.constraints, ctx.attrs.properties)):
        platforms.append(ExecutionPlatformInfo(
            # Named after the abstract platform it realizes, not after this
            # target: the name keys the configuration of every exec dep (the
            # toolchain) and so appears in their output paths and in every
            # command that reads them. A repository mounting komira declares
            # its own execution platform; naming both after
            # `komira//tools/build/platforms:<name>` keeps its action keys
            # equal to a standalone checkout's.
            label = constraints_dep.label.raw_target(),
            configuration = constraints_dep[PlatformInfo].configuration,
            executor_config = CommandExecutorConfig(
                local_enabled = False,
                remote_enabled = True,
                remote_execution_properties = props,
                remote_execution_use_case = "buck2-default",
                remote_cache_enabled = True,
                allow_cache_uploads = False,
                use_limited_hybrid = False,
            ),
        ))
    return [DefaultInfo(), ExecutionPlatformRegistrationInfo(platforms = platforms)]

remote_execution_platforms = rule(
    impl = _remote_platforms_impl,
    attrs = {
        "constraints": attrs.list(attrs.dep(providers = [PlatformInfo])),
        "names": attrs.list(attrs.string()),
        "properties": attrs.list(attrs.dict(attrs.string(), attrs.string())),
    },
)

# Registration order matters: a target that states no execution constraint
# gets the first platform, so `exec-mojo` comes first (an unconstrained action
# lands on a worker able to run anything komira runs). Mojo targets state
# `mojo_compile` + `numa_single` through their toolchain; toolchain unpack and
# copy targets state `light`.
#
# The macOS arm64 platform comes LAST: a platform added later must never become
# the first match of an action that states no os. (Every komira target states
# its os through its toolchain; the order keeps it so for anything that does
# not.)
_EXEC_PLATFORMS = [
    ("mojo_compile", "komira//tools/build/platforms:exec-mojo"),
    ("light", "komira//tools/build/platforms:exec-light"),
    ("mojo_compile_multi_numa", "komira//tools/build/platforms:exec-mojo-multi-numa"),
    ("mojo_compile_darwin", "komira//tools/build/platforms:exec-mojo-darwin-arm64"),
]

# The property every macOS execution platform must carry: the identity of its
# workers' host toolchain, as mojo/darwin/host_identity.sh prints it on them
# (the SDK version, then a digest of the developer dir, the SDK version and
# build, the cc and ld builds, and the OS build). Those are the host's, not
# inputs of the action, so they must be part of the action key some other
# way; REAPI platform properties are part of the action digest, and workers
# match them exactly. The macOS toolchain also writes the value into every
# compile's inputs, and the compile refuses a host whose identity differs.
DARWIN_HOST_PROPERTY = "macos_host"

# `[komira_re]` key of the macOS arm64 execution platform's property set.
DARWIN_PROPERTIES_KEY = "darwin_mojo_compile_properties"

def darwin_macos_host():
    """The host identity the root cell's macOS property set promises, or "".

    Read from the ROOT cell's config: the toolchain lives in another cell, and
    the property set is configured where the execution platforms are. This is
    the value the macOS toolchain writes into every compile; the execution
    platform's property is whatever dict its caller passes, and
    `komira_execution_platforms` refuses the two when they disagree.
    """
    for pair in read_root_config("komira_re", DARWIN_PROPERTIES_KEY, "").split(","):
        kv = pair.split("=", 1)
        if len(kv) == 2 and kv[0].strip() == DARWIN_HOST_PROPERTY:
            return kv[1].strip()
    return ""

def darwin_properties_refusal(props, toolchain_host):
    """Why a macOS property set cannot be registered, or None.

    `props` is the property dict of the macOS execution platform,
    `toolchain_host` the value the toolchain promises (`darwin_macos_host()`).
    They come from two places when a repository passes the dict itself, and a
    platform whose property differs from the toolchain's would file results
    under one host identity while the compile checks another.
    """
    host = props.get(DARWIN_HOST_PROPERTY, "")
    if not host:
        return ("`mojo_compile_darwin` must carry `{}=<value>`, what mojo/darwin/host_identity.sh " +
                "prints on its workers; got {}").format(DARWIN_HOST_PROPERTY, props)
    if host != toolchain_host:
        return ("`mojo_compile_darwin` carries `{}={}`, but the macOS toolchain promises `{}` " +
                "(read from `[komira_re] {}` of the root cell). Set both to the same value.").format(
            DARWIN_HOST_PROPERTY,
            host,
            toolchain_host or "<unset>",
            DARWIN_PROPERTIES_KEY,
        )
    return None

def komira_execution_platforms(name, light, mojo_compile, mojo_compile_multi_numa = None, mojo_compile_darwin = None, visibility = None):
    """Registers komira's execution platforms, given their worker property sets.

    Each argument is the exact REAPI platform property dict of the workers that
    realize that configuration. `mojo_compile_multi_numa` is optional: when it
    is None no platform provides `numa_multi`, and a target that requires it
    fails to configure ("no compatible execution platform") instead of running
    on a single-NUMA worker. Give it only for workers that span more than one
    NUMA node. `mojo_compile_darwin` is optional too: macOS arm64 workers
    that build darwin-arm64 targets. It must carry `macos_host` (see
    DARWIN_HOST_PROPERTY), equal to the one in the root cell's
    `[komira_re] darwin_mojo_compile_properties`, and without it no
    darwin-arm64 Mojo target can configure.
    """
    if mojo_compile_multi_numa != None and mojo_compile_multi_numa == mojo_compile:
        # The same property set routes to the same workers: a numa_multi run
        # would land on the single-NUMA pool. (The run itself also refuses a
        # worker it finds with fewer nodes; this catches the mistake at load.)
        fail("komira_execution_platforms: `mojo_compile_multi_numa` must name workers " +
             "spanning more than one NUMA node, but it equals `mojo_compile` ({})".format(mojo_compile))
    if mojo_compile_darwin != None:
        # A macOS action must never match a linux worker, nor the reverse.
        if mojo_compile_darwin in (light, mojo_compile, mojo_compile_multi_numa):
            fail("komira_execution_platforms: `mojo_compile_darwin` must name macOS workers, " +
                 "but it equals a linux property set ({})".format(mojo_compile_darwin))
        refusal = darwin_properties_refusal(mojo_compile_darwin, darwin_macos_host())
        if refusal:
            fail("komira_execution_platforms: " + refusal)
    props = {
        "light": light,
        "mojo_compile": mojo_compile,
        "mojo_compile_darwin": mojo_compile_darwin,
        "mojo_compile_multi_numa": mojo_compile_multi_numa,
    }
    names = []
    constraints = []
    properties = []
    for key, platform in _EXEC_PLATFORMS:
        if props[key] == None:
            if key in ("mojo_compile_multi_numa", "mojo_compile_darwin"):
                continue
            fail("komira_execution_platforms: `{}` is required".format(key))
        names.append(key)
        constraints.append(platform)
        properties.append(props[key])
    remote_execution_platforms(
        name = name,
        names = names,
        constraints = constraints,
        properties = properties,
        visibility = visibility,
    )
