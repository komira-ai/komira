"""The hermetic Node.js of the tests: the runtime and the npm packages, each pinned twice.

Read by this package's BUCK, which declares the downloads and the unpacked
targets, and by the tests that hold the runtime to its pin
(src/tests/helpers/komira_test_node). Every file is pinned by sha256 and size
(`pinned_file`, checked when it is fetched). The Node archive's sha256 is the
one its release's signed `SHASUMS256.txt` lists; each npm tarball also carries
the registry's `dist.integrity` (`sha512-<base64>`), which `npm_package`
checks again before it unpacks the tarball. `license` is the SPDX expression
README.md records (Licences); `deps` are the packages a package imports at run
time, by `name`.
"""

NODE = {
    "name": "node",
    # Node 24, the active LTS line ("Krypton"), released 2026-09-07; the
    # newest 24.x release in nodejs.org's release index (dist/index.json).
    "version": "24.21.0",
    "archive": "node-v24.21.0-linux-x64.tar.gz",
    "top": "node-v24.21.0-linux-x64",
    "url": "https://nodejs.org/dist/v24.21.0/node-v24.21.0-linux-x64.tar.gz",
    "sha256": "6e1db87ef58b8819e5d5402eff1536491b18edd8eb7bee5ef7897876e88dc5ff",
    "size": 58088022,
    "license": "MIT",
}

def _npm(name, version, url, sha256, size, integrity, license, deps = [], exe = None):
    return {
        "deps": deps,
        "exe": exe,
        "file": "npm-" + url.rsplit("/", 1)[1],
        "integrity": integrity,
        "license": license,
        "name": name,
        "sha256": sha256,
        "size": size,
        "url": url,
        "version": version,
    }

NPM = [
    # esbuild's linux x86_64 binary (a static Go executable), the package the
    # `esbuild` npm package installs on that platform; `exe` must print the
    # version.
    _npm(
        "@esbuild/linux-x64",
        "0.28.2",
        "https://registry.npmjs.org/@esbuild/linux-x64/-/linux-x64-0.28.2.tgz",
        "9573bb2233aab0f9ea7647d5cca9726113cc1768de61d66b17267f4db84488f6",
        4741809,
        "sha512-4xTZr1FUmSoQW4XIWmit3tzQrUTZM+N3P0XV8xROKYF50XfI7xeO90+1bZvNwxIufQ9hDQVRJH5YhgPVF8A/HQ==",
        "MIT",
        exe = "bin/esbuild",
    ),
    _npm(
        "apache-arrow",
        "21.2.0",
        "https://registry.npmjs.org/apache-arrow/-/apache-arrow-21.2.0.tgz",
        "dd63a3a4c380eddeb00c718740414ff33c4ded015c8720798afdfcc61b5dac41",
        1019102,
        "sha512-Hxe6Agq26gQOM954qpzYSllJBPJl+e16U5CkfuMUhLrNba+5nKkttIVlflaovN6oaTratqMGAO8H5u/aNhmHWQ==",
        "Apache-2.0",
        deps = ["flatbuffers", "json-with-bigint", "tslib"],
    ),
    _npm(
        "flatbuffers",
        "25.9.23",
        "https://registry.npmjs.org/flatbuffers/-/flatbuffers-25.9.23.tgz",
        "484129ef89da43decec3d004810863a70fad9b2aa6df6246602e58d9ba207d26",
        50936,
        "sha512-MI1qs7Lo4Syw0EOzUl0xjs2lsoeqFku44KpngfIduHBYvzm8h2+7K8YMQh1JtVVVrUvhLpNwqVi4DERegUJhPQ==",
        "Apache-2.0",
    ),
    _npm(
        "json-with-bigint",
        "3.5.12",
        "https://registry.npmjs.org/json-with-bigint/-/json-with-bigint-3.5.12.tgz",
        "608af3ce68ceba88a6cec4cdbd2fb35f1ac219a3b038f995344d0881b73b86ae",
        20336,
        "sha512-uwbF/wSSuOgC7qqlq27Xp5B6a2MHVug3t0idZdTqu0JnlFvgJuH7ju+KAk/J06C7GfhoYy2gnb9wz2INqcne7w==",
        "MIT",
    ),
    _npm(
        "tslib",
        "2.8.1",
        "https://registry.npmjs.org/tslib/-/tslib-2.8.1.tgz",
        "66f635d5eeabae44807534976913a102cf615b9a045368359c9f79ae6ee2119e",
        18477,
        "sha512-oJFu94HQb+KVduSUQL7wnpmqnfmLsOA/nAh6b6EH0wCEoK0/mPeXU6c3wKDV83MkOuHPRHtSXKKU99IBazS/2w==",
        "0BSD",
    ),
]

def npm_target(name):
    """The target name of an npm package: its name without the scope's `@`, `/` as `_` (`@esbuild/linux-x64` -> `esbuild_linux-x64`)."""
    return (name[1:] if name.startswith("@") else name).replace("/", "_")
