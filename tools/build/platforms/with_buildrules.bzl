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

def _impl(ctx):
    base = ctx.attrs.base[ExecutionPlatformRegistrationInfo].platforms
    # Komira's linux-x86_64 comes first; the one exception is a local build on a Mac
    # (`komira_local_execution_platforms`), whose only platform is darwin-arm64.
    only_mac = len(base) == 1 and str(base[0].label).endswith("platforms:darwin-arm64")
    if len(base) == 0 or not (only_mac or str(base[0].label).endswith("platforms:linux-x86_64")):
        fail("{}: the first platform of {} must be komira's linux-x86_64 (or, alone, a local macOS build's darwin-arm64), got {}".format(
            ctx.label,
            ctx.attrs.base.label,
            [str(p.label) for p in base],
        ))
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
