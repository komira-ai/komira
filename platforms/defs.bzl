"""Execution platforms. Every action runs remotely; nothing runs on the client.

Each execution platform realizes one of the abstract configurations in
//platforms (`exec-light`, `exec-mojo`, `exec-mojo-multi-numa`); the worker
property set behind it is read from `.buckconfig.local`
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
            # `komira//platforms:<name>` keeps its action keys equal to a
            # standalone checkout's.
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
_EXEC_PLATFORMS = [
    ("mojo_compile", "komira//platforms:exec-mojo"),
    ("light", "komira//platforms:exec-light"),
    ("mojo_compile_multi_numa", "komira//platforms:exec-mojo-multi-numa"),
]

def komira_execution_platforms(name, light, mojo_compile, mojo_compile_multi_numa = None, visibility = None):
    """Registers komira's execution platforms, given their worker property sets.

    Each argument is the exact REAPI platform property dict of the workers that
    realize that configuration. `mojo_compile_multi_numa` is optional: when it
    is None no platform provides `numa_multi`, and a target that requires it
    fails to configure ("no compatible execution platform") instead of running
    on a single-NUMA worker. Give it only for workers that span more than one
    NUMA node.
    """
    if mojo_compile_multi_numa != None and mojo_compile_multi_numa == mojo_compile:
        # The same property set routes to the same workers: a numa_multi run
        # would land on the single-NUMA pool. (The run itself also refuses a
        # worker it finds with fewer nodes; this catches the mistake at load.)
        fail("komira_execution_platforms: `mojo_compile_multi_numa` must name workers " +
             "spanning more than one NUMA node, but it equals `mojo_compile` ({})".format(mojo_compile))
    props = {
        "light": light,
        "mojo_compile": mojo_compile,
        "mojo_compile_multi_numa": mojo_compile_multi_numa,
    }
    names = []
    constraints = []
    properties = []
    for key, platform in _EXEC_PLATFORMS:
        if props[key] == None:
            if key == "mojo_compile_multi_numa":
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
