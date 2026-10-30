"""One more execution platform, for the buildrules rules, after komira's.

`[build] execution_platforms` names one target (komira//tools/build/platforms/default:default), so
the platform buildrules' rules need is registered by wrapping komira's registration, not by a
second setting.

buildrules' rules say `exec_compatible_with = [buildrules//platforms:linux, :x86_64]`. Komira's
linux execution platform carries komira's own constraints, so it does not match them and komira's
targets are placed exactly as before (its platform stays first, with the same label,
configuration and action keys). The platform added here has buildrules' configuration
(buildrules//platforms:linux_x86_64) and the executor of komira's linux platform: the same
worker property set, or the same local execution, whichever komira's registration chose.

macOS arm64 is the same, one platform over. buildrules' Mojo rules place a package built for macOS
arm64 on `buildrules//platforms:macos_aarch64` (buildrules' docs/contract.md, section 14). Komira's
macOS execution platform (`platforms:darwin-arm64`, registered only when `[komira_re]
darwin_arm64_properties` names workers) carries komira's constraints, which do not match, so
`extra_darwin` names the buildrules platform that gets the executor of komira's macOS platform: the
same worker property set. Without macOS workers komira registers no macOS platform and nothing is
added, as buildrules itself registers none while `[buildrules_re] macos_aarch64_properties` is empty.
That key is what buildrules reads to decide whether the platform exists; the committed `.buckconfig`
points it at `[komira_re] darwin_arm64_properties` (`$(config ...)`), so it is set exactly when komira's
macOS platform is registered and holds no value of its own. (Komira's `darwin-arm64` target platform carries
only the prelude's os and cpu constraints, and no value of buildrules' own: buildrules' Mojo rules choose the
unit graph, the toolchain and the execution platform from those too, so a package built for `darwin-arm64`
selects the macOS graph and this platform.)
"""

def first_platform_refusal(labels, first_remote):
    """Why komira's registration cannot take buildrules' platforms, or None.

    `labels` are the labels of the registered platforms in order, `first_remote`
    whether the first one executes remotely. Komira's linux-x86_64 comes first.
    The one exception is a local build on a Mac (`komira_local_execution_platforms`),
    whose only platform is darwin-arm64 and runs on this machine: a lone REMOTE
    darwin-arm64 (a Mac client with only macOS workers) is still refused, since
    buildrules' linux-labelled platforms would silently get the macOS executor.
    """
    if len(labels) == 0:
        return "no platform"
    if labels[0].endswith("platforms:linux-x86_64"):
        return None
    if len(labels) == 1 and labels[0].endswith("platforms:darwin-arm64") and not first_remote:
        return None
    return "the first platform must be komira's linux-x86_64 (or, alone and local, a local macOS build's darwin-arm64)"

def _impl(ctx):
    base = ctx.attrs.base[ExecutionPlatformRegistrationInfo].platforms
    labels = [str(p.label) for p in base]
    refusal = first_platform_refusal(labels, len(base) > 0 and base[0].executor_config.remote_enabled)
    if refusal:
        fail("{}: {} (of {}), got {}".format(ctx.label, refusal, ctx.attrs.base.label, labels))
    linux = base[0]
    extra = [
        ExecutionPlatformInfo(
            label = p.label.raw_target(),
            configuration = p[PlatformInfo].configuration,
            executor_config = linux.executor_config,
        )
        for p in ctx.attrs.extra
    ]
    darwin = [p for p in base if str(p.label).endswith("platforms:darwin-arm64")]
    if darwin:
        extra += [
            ExecutionPlatformInfo(
                label = p.label.raw_target(),
                configuration = p[PlatformInfo].configuration,
                executor_config = darwin[0].executor_config,
            )
            for p in ctx.attrs.extra_darwin
        ]
    return [DefaultInfo(), ExecutionPlatformRegistrationInfo(platforms = base + extra)]

execution_platforms_plus = rule(
    impl = _impl,
    attrs = {
        "base": attrs.dep(providers = [ExecutionPlatformRegistrationInfo]),
        "extra": attrs.list(attrs.dep(providers = [PlatformInfo])),
        # Platforms that get the executor of komira's macOS arm64 platform, when komira registers one.
        "extra_darwin": attrs.list(attrs.dep(providers = [PlatformInfo]), default = []),
    },
)
