//! komira_oci: lays out an image's tree, writes the image, and reads an OCI
//! image layout back (README.md).
//!
//!   komira_oci tree --out <dir> [--bundle <path/>=<dir>]... [--file <path>=<src>]...
//!   komira_oci image --tree <dir> --entrypoint </path> --name <n> --version <v>
//!       --repo <r> --manifest <base manifest> --manifest-digest sha256:<hex>
//!       --config <base config> [--layer <base layer blob>]... --busybox <exe>
//!       --out <dir> --archive <file> --digest <file>
//!   komira_oci layers --layout <dir> --busybox <exe> --out <file>
//!   komira_oci check --layout <dir> --busybox <exe> --layers <file>
//!       --entrypoint </path> [--exec <path>]... [--file <path>]...
//!       --out <file> [--expect-red <text>]
//!
//! `tree` lays bundles and files at paths in <out> (tree.rs: refused unless
//! every path is plain and none is inside another; modes 0755/0644).
//!
//! `image` writes an OCI image layout of the base plus one layer, the tree
//! at /, with Entrypoint [<entrypoint>] (pack.rs), the same as one tar plus
//! Docker's manifest.json at <archive>, and the manifest digest at <digest>.
//!
//! `layers` writes the manifest's layer digests, one per line, in order, and
//! refuses an image whose Entrypoint is not one absolute path naming a
//! regular file with mode 0755 in the image's last layer.
//!
//! `check` is red, naming each failure, unless: the layer list is the
//! manifest's layers in order; the config's Entrypoint is exactly
//! [<entrypoint>]; <entrypoint> and each `--exec` path is a regular file
//! with mode 0755, and each `--file` path a regular file of one byte or
//! more, in the image's filesystem (image.rs: layers applied in order,
//! whiteouts and symbolic links followed); and no entry of the last layer
//! changes the type of a path of the layers below. It writes <out>, what it
//! found, when green. With `--expect-red <text>` the answer is inverted: it
//! writes <out> only when the check is red and a failure contains <text>.
//!
//! Gzip goes through the pinned busybox (`<busybox> gzip -dc` to read a
//! layer, `<busybox> gzip -c` to write one, its header's time then zeroed);
//! nothing else runs.

mod image;
mod json;
mod pack;
mod sha256;
mod tar;
mod tree;

use image::{Fs, Want};
use json::Value;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};

struct Args {
    cmd: String,
    pairs: Vec<(String, String)>,
}

impl Args {
    fn parse(argv: Vec<String>) -> Result<Args, String> {
        let mut it = argv.into_iter().skip(1);
        let cmd = it.next().ok_or("no command (tree, image, layers, check)")?;
        let mut pairs = Vec::new();
        while let Some(flag) = it.next() {
            let v = it.next().ok_or_else(|| format!("{} needs a value", flag))?;
            pairs.push((flag, v));
        }
        Ok(Args { cmd, pairs })
    }

    fn allow(&self, flags: &[&str]) -> Result<(), String> {
        match self.pairs.iter().find(|(f, _)| !flags.contains(&f.as_str())) {
            Some((f, _)) => Err(format!("unknown flag {} for {}", f, self.cmd)),
            None => Ok(()),
        }
    }

    fn opt(&self, flag: &str) -> Result<Option<&str>, String> {
        let mut v = self.pairs.iter().filter(|(f, _)| f == flag).map(|(_, v)| v.as_str());
        let first = v.next();
        if v.next().is_some() {
            return Err(format!("{} given twice", flag));
        }
        Ok(first)
    }

    fn one(&self, flag: &str) -> Result<&str, String> {
        self.opt(flag)?.ok_or_else(|| format!("missing {}", flag))
    }

    fn all(&self, flag: &str) -> Vec<&str> {
        self.pairs.iter().filter(|(f, _)| f == flag).map(|(_, v)| v.as_str()).collect()
    }
}

fn read(p: &Path) -> Result<Vec<u8>, String> {
    std::fs::read(p).map_err(|e| format!("cannot read {}: {}", p.display(), e))
}

fn write(p: &str, data: &str) -> Result<(), String> {
    std::fs::write(p, data).map_err(|e| format!("cannot write {}: {}", p, e))
}

/// A `sha256:<64 lower-case hex>` digest; anything else could name a path
/// outside the layout.
fn digest(v: Option<&Value>, what: &str) -> Result<String, String> {
    let d = v.and_then(Value::as_str).ok_or_else(|| format!("{}: no digest", what))?;
    let hex = d.strip_prefix("sha256:").unwrap_or("");
    if hex.len() != 64 || !hex.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) {
        return Err(format!("{}: `{}` is not a sha256:<64 hex> digest", what, d));
    }
    Ok(d.to_string())
}

struct Layout {
    dir: PathBuf,
    busybox: String,
    layers: Vec<String>,
    config: Value,
}

impl Layout {
    fn blob(&self, d: &str) -> PathBuf {
        self.dir.join("blobs/sha256").join(&d["sha256:".len()..])
    }

    fn open(dir: &str, busybox: &str) -> Result<Layout, String> {
        let mut l = Layout { dir: PathBuf::from(dir), busybox: busybox.to_string(), layers: Vec::new(), config: Value::Null };
        let index = json::parse(&read(&l.dir.join("index.json"))?).map_err(|e| format!("index.json: {}", e))?;
        let ms = index.get("manifests").and_then(Value::as_arr).ok_or("index.json: no `manifests` array")?;
        if ms.len() != 1 {
            return Err(format!("index.json names {} manifests, want 1", ms.len()));
        }
        let m = json::parse(&read(&l.blob(&digest(ms[0].get("digest"), "index.json manifest")?))?).map_err(|e| format!("manifest: {}", e))?;
        let c = digest(m.get("config").and_then(|c| c.get("digest")), "manifest config")?;
        for (i, d) in m.get("layers").and_then(Value::as_arr).ok_or("manifest: no `layers` array")?.iter().enumerate() {
            l.layers.push(digest(d.get("digest"), &format!("manifest layer {}", i))?);
        }
        if l.layers.is_empty() {
            return Err("the manifest names no layer".into());
        }
        l.config = json::parse(&read(&l.blob(&c))?).map_err(|e| format!("config: {}", e))?;
        Ok(l)
    }

    fn entrypoint(&self) -> Option<Vec<&str>> {
        let ep = self.config.get("config")?.get("Entrypoint")?.as_arr()?;
        ep.iter().map(Value::as_str).collect()
    }

    /// Layer `i`'s entries: a gzip stream through busybox, else a tar.
    fn entries(&self, i: usize) -> Result<Vec<tar::Entry>, String> {
        let p = self.blob(&self.layers[i]);
        let raw = read(&p)?;
        let data = if raw.starts_with(&[0x1f, 0x8b]) {
            let o = Command::new(&self.busybox).args(["gzip", "-dc"]).arg(&p).output().map_err(|e| format!("cannot run {}: {}", self.busybox, e))?;
            if !o.status.success() {
                return Err(format!("layer {}: gzip -dc failed: {}", self.layers[i], String::from_utf8_lossy(&o.stderr).trim()));
            }
            o.stdout
        } else {
            raw
        };
        tar::read(&data).map_err(|e| format!("layer {}: {}", self.layers[i], e))
    }
}

/// `<path>=<src>`: the path holds no `=`, so the first one splits.
fn place(v: &str, bundle: bool) -> Result<tree::Place, String> {
    let (path, src) = v.split_once('=').ok_or_else(|| format!("`{}` is not <path>=<source>", v))?;
    Ok(tree::Place { path: path.to_string(), src: src.to_string(), bundle })
}

fn tree_cmd(a: &Args) -> Result<(), String> {
    a.allow(&["--out", "--bundle", "--file"])?;
    let mut places = Vec::new();
    for (flag, bundle) in [("--bundle", true), ("--file", false)] {
        for v in a.all(flag) {
            places.push(place(v, bundle)?);
        }
    }
    let plan = tree::plan(places).map_err(|bad| format!("the tree is refused:\n  {}", bad.join("\n  ")))?;
    tree::lay(Path::new(a.one("--out")?), &plan)
}

/// `data` gzipped by `<busybox> gzip -c`, the header's modification time
/// zeroed so the bytes depend on `data` alone (the header is not in the
/// stream's CRC, which covers the uncompressed bytes).
fn gzip(busybox: &str, data: &[u8]) -> Result<Vec<u8>, String> {
    let mut child = Command::new(busybox).args(["gzip", "-c"]).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().map_err(|e| format!("cannot run {}: {}", busybox, e))?;
    let mut stdin = child.stdin.take().ok_or("gzip: no stdin")?;
    let o = std::thread::scope(|s| {
        let feed = s.spawn(move || stdin.write_all(data));
        let o = child.wait_with_output();
        (feed.join(), o)
    });
    let o = match o {
        (Ok(Ok(())), Ok(o)) => o,
        (_, Err(e)) => return Err(format!("gzip: {}", e)),
        (fed, _) => return Err(format!("gzip: cannot write its input: {:?}", fed)),
    };
    if !o.status.success() {
        return Err(format!("gzip -c failed: {}", String::from_utf8_lossy(&o.stderr).trim()));
    }
    zero_mtime(o.stdout)
}

/// `gz` with its header's modification time zeroed, refused unless it is
/// a whole gzip stream's plain header: ID1 ID2, deflate, no flags (no name,
/// no comment, no header CRC), and room for the 8-byte trailer.
fn zero_mtime(mut gz: Vec<u8>) -> Result<Vec<u8>, String> {
    if gz.len() < 18 || gz[..4] != [0x1f, 0x8b, 8, 0] {
        return Err(format!("gzip -c wrote no plain gzip header: {:02x?}", &gz[..gz.len().min(4)]));
    }
    gz[4..8].fill(0);
    Ok(gz)
}

fn image_cmd(a: &Args) -> Result<(), String> {
    a.allow(&["--tree", "--entrypoint", "--name", "--version", "--repo", "--manifest", "--manifest-digest", "--config", "--layer", "--busybox", "--out", "--archive", "--digest"])?;
    let entrypoint = a.one("--entrypoint")?;
    if entrypoint.len() < 2 || !entrypoint.starts_with('/') {
        return Err(format!("entrypoint `{}` is not an absolute path", entrypoint));
    }
    let n = pack::Named {
        name: pack::plain(a.one("--name")?, "name", "")?.to_string(),
        version: pack::plain(a.one("--version")?, "version", "~")?.to_string(),
        repo: pack::plain(a.one("--repo")?, "repo", "/:")?.to_string(),
        entrypoint: entrypoint.to_string(),
    };
    let base = pack::Base {
        manifest: read(Path::new(a.one("--manifest")?))?,
        pin: a.one("--manifest-digest")?.to_string(),
        config: read(Path::new(a.one("--config")?))?,
        layers: a.all("--layer").into_iter().map(|p| read(Path::new(p))).collect::<Result<_, _>>()?,
    };
    let layer_tar = tar::write(pack::tree_items(Path::new(a.one("--tree")?))?)?;
    let layer_gz = gzip(a.one("--busybox")?, &layer_tar)?;
    let img = pack::image(&base, &layer_tar, &layer_gz, &n)?;
    pack::write(&img, Path::new(a.one("--out")?), Path::new(a.one("--archive")?), Path::new(a.one("--digest")?))
}

fn layers(a: &Args) -> Result<(), String> {
    a.allow(&["--layout", "--busybox", "--out"])?;
    let l = Layout::open(a.one("--layout")?, a.one("--busybox")?)?;
    let ep = match l.entrypoint().as_deref() {
        Some([p]) if p.len() > 1 && p.starts_with('/') => p.to_string(),
        other => return Err(format!("the config's Entrypoint is not one absolute path: {:?}", other)),
    };
    let last = l.entries(l.layers.len() - 1)?;
    let ok = last.iter().any(|e| image::normalize(&e.path) == image::normalize(&ep) && e.kind == tar::Kind::File && e.mode == 0o755);
    if !ok {
        return Err(format!("entrypoint {} is not a regular file with mode 0755 in the image's last layer", ep));
    }
    write(a.one("--out")?, &l.layers.iter().map(|d| format!("{}\n", d)).collect::<String>())
}

/// Green only when the config's Entrypoint is exactly `[want]`: one
/// element, spelled the same (another path to the same file is red).
fn entrypoint_finding(got: Option<&[&str]>, want: &str) -> Result<String, String> {
    match got {
        Some([ep]) if *ep == want => Ok(format!("entrypoint {}", want)),
        other => Err(format!("the config's Entrypoint is not [\"{}\"]: {:?}", want, other)),
    }
}

/// Every path the check reads: the entrypoint and each `--exec` as an
/// executable, each `--file` as a file, in that order.
fn wants(entrypoint: &str, execs: &[&str], files: &[&str]) -> Vec<(Want, String)> {
    let mut w = vec![(Want::Exec, entrypoint.to_string())];
    w.extend(execs.iter().map(|p| (Want::Exec, p.to_string())));
    w.extend(files.iter().map(|p| (Want::File, p.to_string())));
    w
}

/// The check's findings: what was found, and the failures.
fn findings(a: &Args) -> Result<(Vec<String>, Vec<String>), String> {
    let l = Layout::open(a.one("--layout")?, a.one("--busybox")?)?;
    let want_ep = a.one("--entrypoint")?;
    let (mut ok, mut bad) = (Vec::new(), Vec::new());
    let list = String::from_utf8(read(Path::new(a.one("--layers")?))?).map_err(|_| "the layer list is not UTF-8")?;
    let listed: Vec<&str> = list.lines().collect();
    if listed != l.layers {
        bad.push(format!("the layer list is not the manifest's layers in order: list {} | manifest {}", listed.join(" "), l.layers.join(" ")));
    }
    match entrypoint_finding(l.entrypoint().as_deref(), want_ep) {
        Ok(f) => ok.push(f),
        Err(f) => bad.push(f),
    }
    let mut fs = Fs::default();
    for i in 0..l.layers.len() {
        let entries = l.entries(i)?;
        if i == l.layers.len() - 1 {
            bad.extend(image::type_changes(&fs, &entries));
        }
        fs.apply(&entries).map_err(|e| format!("layer {}: {}", l.layers[i], e))?;
    }
    ok.push(format!("layers {}", l.layers.len()));
    let (found, failed) = image::check_paths(&fs, &wants(want_ep, &a.all("--exec"), &a.all("--file")));
    ok.extend(found);
    bad.extend(failed);
    Ok((ok, bad))
}

fn check(a: &Args) -> Result<(), String> {
    a.allow(&["--layout", "--busybox", "--layers", "--entrypoint", "--exec", "--file", "--out", "--expect-red"])?;
    let out = a.one("--out")?;
    let expect = a.opt("--expect-red")?;
    let (ok, bad) = match findings(a) {
        Ok(r) => r,
        // An image that cannot be read is red too.
        Err(e) => (Vec::new(), vec![e]),
    };
    let listed = bad.iter().map(|b| format!("\n  {}", b)).collect::<String>();
    match expect {
        None if bad.is_empty() => write(out, &ok.iter().map(|s| format!("{}\n", s)).collect::<String>()),
        None => Err(format!("{}:{}", a.one("--layout")?, listed)),
        Some(t) if t.is_empty() => Err("--expect-red is empty".into()),
        Some(t) if bad.iter().any(|b| b.contains(t)) => write(out, &format!("red as expected, naming `{}`:{}\n", t, listed)),
        Some(t) if bad.is_empty() => Err(format!("green, want red naming `{}`", t)),
        Some(t) => Err(format!("red, but no failure names `{}`:{}", t, listed)),
    }
}

fn run(argv: Vec<String>) -> Result<(), String> {
    let a = Args::parse(argv)?;
    match a.cmd.as_str() {
        "tree" => tree_cmd(&a),
        "image" => image_cmd(&a),
        "layers" => layers(&a),
        "check" => check(&a),
        c => Err(format!("unknown command `{}` (tree, image, layers, check)", c)),
    }
}

fn main() -> ExitCode {
    match run(std::env::args().collect()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("komira_oci: {}", e);
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_entrypoint_must_be_exactly_the_one_named() {
        assert_eq!(entrypoint_finding(Some(&["/bin/sh"]), "/bin/sh"), Ok("entrypoint /bin/sh".into()));
        for got in [Some(&["/bin/other"][..]), Some(&["/bin/./sh"][..]), Some(&["/bin/sh", "-c"][..]), Some(&[][..]), None] {
            let e = entrypoint_finding(got, "/bin/sh").unwrap_err();
            assert!(e.starts_with("the config's Entrypoint is not [\"/bin/sh\"]: "), "{}", e);
        }
    }

    #[test]
    fn every_exec_and_file_is_wanted() {
        let w = wants("/e", &["a", "b", "c"], &["x", "y"]);
        let got: Vec<(Want, &str)> = w.iter().map(|(k, p)| (*k, p.as_str())).collect();
        assert_eq!(got, [(Want::Exec, "/e"), (Want::Exec, "a"), (Want::Exec, "b"), (Want::Exec, "c"), (Want::File, "x"), (Want::File, "y")]);
    }

    #[test]
    fn a_place_splits_at_the_first_equals() {
        assert_eq!(place("bin/sh=out/a=b", false).unwrap(), tree::Place { path: "bin/sh".into(), src: "out/a=b".into(), bundle: false });
        assert!(place("bin/sh", false).is_err());
    }

    use std::fs;

    fn argv(v: &[&str]) -> Vec<String> {
        std::iter::once("komira_oci").chain(v.iter().copied()).map(String::from).collect()
    }

    fn args(v: &[&str]) -> Args {
        Args::parse(argv(v)).unwrap()
    }

    /// A directory of its own under this run's TMPDIR.
    fn scratch(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("main_{}_{}", name, std::process::id()));
        fs::create_dir_all(&d).unwrap();
        d
    }

    fn p(d: &Path) -> &str {
        d.to_str().unwrap()
    }

    /// `data` written as a blob of the layout at `dir`; its digest.
    fn blob(dir: &Path, data: &[u8]) -> String {
        fs::create_dir_all(dir.join("blobs/sha256")).unwrap();
        fs::write(dir.join("blobs/sha256").join(sha256::hex(data)), data).unwrap();
        sha256::digest(data)
    }

    fn index(dir: &Path, manifests: &[&str]) {
        let ds: Vec<String> = manifests.iter().map(|m| format!(r#"{{"digest":"{}"}}"#, blob(dir, m.as_bytes()))).collect();
        fs::write(dir.join("index.json"), format!(r#"{{"manifests":[{}]}}"#, ds.join(","))).unwrap();
    }

    fn manifest(config: &str, layers: &[String]) -> String {
        let ls: Vec<String> = layers.iter().map(|d| format!(r#"{{"digest":"{}"}}"#, d)).collect();
        format!(r#"{{"config":{{"digest":"{}"}},"layers":[{}]}}"#, config, ls.join(","))
    }

    /// A layout of `layers` (uncompressed tars, read without busybox) and a
    /// config whose Entrypoint is the JSON `ep`; its directory and the layer
    /// digests.
    fn layout(name: &str, layers: &[Vec<u8>], ep: &str) -> (PathBuf, Vec<String>) {
        let dir = scratch(name);
        let c = blob(&dir, format!(r#"{{"config":{{"Entrypoint":{}}}}}"#, ep).as_bytes());
        let ls: Vec<String> = layers.iter().map(|l| blob(&dir, l)).collect();
        index(&dir, &[&manifest(&c, &ls)]);
        (dir, ls)
    }

    fn base_layer() -> Vec<u8> {
        tar::write::tar(&[("etc/", b'5', 0o755, b"", ""), ("etc/f", b'0', 0o644, b"x", "")])
    }

    fn sh_layer(mode: u32) -> Vec<u8> {
        tar::write::tar(&[("bin/", b'5', 0o755, b"", ""), ("bin/sh", b'0', mode, b"sh", "")])
    }

    #[test]
    fn arguments_are_flag_value_pairs_each_allowed_and_counted() {
        assert_eq!(Args::parse(argv(&[])).err().unwrap(), "no command (tree, image, layers, check)");
        assert_eq!(Args::parse(argv(&["check", "--out"])).err().unwrap(), "--out needs a value");
        let a = args(&["check", "--out", "o", "--x", "1"]);
        assert_eq!(a.allow(&["--out"]), Err("unknown flag --x for check".into()));
        assert_eq!(a.allow(&["--out", "--x"]), Ok(()));
        let a = args(&["check", "--out", "a", "--out", "b"]);
        assert_eq!(a.opt("--out"), Err("--out given twice".into()));
        assert_eq!(a.opt("--layout"), Ok(None));
        assert_eq!(a.one("--layout"), Err("missing --layout".into()));
        let a = args(&["check", "--exec", "a", "--file", "f", "--exec", "b", "--exec", "c"]);
        assert_eq!(a.all("--exec"), ["a", "b", "c"]);
        assert_eq!(a.one("--file"), Ok("f"));
        assert_eq!(run(argv(&["bogus"])), Err("unknown command `bogus` (tree, image, layers, check)".into()));
        for cmd in ["tree", "image", "layers", "check"] {
            assert_eq!(run(argv(&[cmd, "--nope", "x"])), Err(format!("unknown flag --nope for {}", cmd)));
        }
    }

    #[test]
    fn a_digest_is_sha256_and_64_lower_case_hex() {
        let hex = "0123456789abcdef".repeat(4);
        let good = format!("sha256:{}", hex);
        assert_eq!(digest(Some(&Value::Str(good.clone())), "w"), Ok(good));
        assert_eq!(digest(None, "w"), Err("w: no digest".into()));
        assert_eq!(digest(Some(&Value::Num("1".into())), "w"), Err("w: no digest".into()));
        for bad in [hex[..63].to_string(), format!("{}0", hex), hex.replace('a', "A"), hex.replace('f', "g"), hex.replace('0', "/")] {
            let d = format!("sha256:{}", bad);
            assert_eq!(digest(Some(&Value::Str(d.clone())), "w"), Err(format!("w: `{}` is not a sha256:<64 hex> digest", d)));
        }
        let d = format!("sha512:{}", hex);
        assert_eq!(digest(Some(&Value::Str(d.clone())), "w"), Err(format!("w: `{}` is not a sha256:<64 hex> digest", d)));
    }

    #[test]
    fn image_refuses_an_entrypoint_that_is_not_absolute() {
        for ep in ["/", "bin/sh", "", "x"] {
            assert_eq!(image_cmd(&args(&["image", "--entrypoint", ep])), Err(format!("entrypoint `{}` is not an absolute path", ep)));
        }
        // An absolute one gets as far as the next flag.
        assert_eq!(image_cmd(&args(&["image", "--entrypoint", "/x"])), Err("missing --name".into()));
    }

    #[test]
    fn tree_names_every_refusal_and_lays_files() {
        let t = |v: &[&str]| tree_cmd(&args(v));
        assert_eq!(t(&["tree", "--out", "o", "--file", "/abs=src"]), Err("the tree is refused:\n  file path `/abs` must be a plain relative path".into()));
        assert_eq!(
            t(&["tree", "--out", "o", "--bundle", "b=src", "--file", "a/../b=s"]),
            Err("the tree is refused:\n  bundle path `b` must be a plain relative path ending in /\n  file path `a/../b` must be a plain relative path".into())
        );
        assert_eq!(t(&["tree", "--out", "o", "--file", "nosplit"]), Err("`nosplit` is not <path>=<source>".into()));
        let d = scratch("tree");
        fs::write(d.join("src"), b"s").unwrap();
        let out = d.join("out");
        let file = format!("bin/sh={}", p(&d.join("src")));
        assert_eq!(t(&["tree", "--out", p(&out), "--file", &file]), Ok(()));
        assert_eq!(fs::read(out.join("bin/sh")).unwrap(), b"s");
    }

    #[test]
    fn the_gzip_header_must_be_plain_and_whole() {
        let mut ok = vec![0x1f, 0x8b, 8, 0, 1, 2, 3, 4, 0, 3];
        ok.resize(18, 7);
        let mut want = ok.clone();
        want[4..8].fill(0);
        assert_eq!(zero_mtime(ok.clone()), Ok(want));
        let refused = |gz: Vec<u8>| zero_mtime(gz).unwrap_err();
        assert_eq!(refused(ok[..17].to_vec()), "gzip -c wrote no plain gzip header: [1f, 8b, 08, 00]");
        assert_eq!(refused(Vec::new()), "gzip -c wrote no plain gzip header: []");
        for (i, b) in [(0, 0x1e), (1, 0x8c), (2, 9), (3, 8)] {
            let mut gz = ok.clone();
            gz[i] = b;
            assert!(refused(gz).starts_with("gzip -c wrote no plain gzip header: "));
        }
        let run_as = |name: &str| gzip(p(&applet(name)), b"").unwrap_err();
        assert!(run_as("false").starts_with("gzip -c failed"), "{}", run_as("false"));
        assert_eq!(run_as("true"), "gzip -c wrote no plain gzip header: []");
        assert!(gzip("/nonexistent/busybox", b"").unwrap_err().starts_with("cannot run /nonexistent/busybox: "));
    }

    /// A program standing in for busybox: busybox's own `false` or `true`
    /// applet, from this run's PATH (the test runner puts them there).
    fn applet(name: &str) -> PathBuf {
        let path = std::env::var("PATH").expect("PATH");
        path.split(':').map(|d| Path::new(d).join(name)).find(|p| p.exists()).unwrap_or_else(|| panic!("no {} in PATH {}", name, path))
    }

    #[test]
    fn only_a_gzip_layer_goes_through_busybox() {
        let mut gz = vec![0x1f, 0x8b];
        gz.extend(base_layer());
        let (d, ls) = layout("gunzip", &[base_layer(), gz], r#"["/bin/sh"]"#);
        let entries = |bb: &str, i: usize| match Layout::open(p(&d), bb) {
            Ok(l) => l.entries(i),
            Err(e) => panic!("{}", e),
        };
        // A plain tar is read as it is: `false` never runs.
        assert_eq!(entries(p(&applet("false")), 0).unwrap().len(), 2);
        assert!(entries(p(&applet("false")), 1).unwrap_err().starts_with(&format!("layer {}: gzip -dc failed", ls[1])));
        assert_eq!(entries(p(&applet("true")), 1), Err(format!("layer {}: tar: the archive ends without a zero block", ls[1])));
        assert!(entries("/nonexistent/busybox", 1).unwrap_err().starts_with("cannot run /nonexistent/busybox: "));
    }

    fn open_err(dir: &Path) -> String {
        match Layout::open(p(dir), "unused") {
            Ok(_) => panic!("{} opened", dir.display()),
            Err(e) => e,
        }
    }

    #[test]
    fn a_layout_is_one_manifest_of_digests_and_layers() {
        let d = scratch("open_none");
        assert!(open_err(&d).starts_with(&format!("cannot read {}: ", p(&d.join("index.json")))));
        fs::write(d.join("index.json"), "{}").unwrap();
        assert_eq!(open_err(&d), "index.json: no `manifests` array");
        fs::write(d.join("index.json"), "{").unwrap();
        assert!(open_err(&d).starts_with("index.json: JSON: "));
        index(&d, &[]);
        assert_eq!(open_err(&d), "index.json names 0 manifests, want 1");
        let c = blob(&d, b"{}");
        let l = blob(&d, &base_layer());
        index(&d, &[&manifest(&c, &[l.clone()]), &manifest(&c, &[])]);
        assert_eq!(open_err(&d), "index.json names 2 manifests, want 1");
        fs::write(d.join("index.json"), r#"{"manifests":[{"digest":"sha256:../../x"}]}"#).unwrap();
        assert_eq!(open_err(&d), "index.json manifest: `sha256:../../x` is not a sha256:<64 hex> digest");
        index(&d, &["{"]);
        assert!(open_err(&d).starts_with("manifest: JSON: "));
        index(&d, &[&manifest("sha256:zz", &[l.clone()])]);
        assert_eq!(open_err(&d), "manifest config: `sha256:zz` is not a sha256:<64 hex> digest");
        index(&d, &[&format!(r#"{{"config":{{"digest":"{}"}}}}"#, c)]);
        assert_eq!(open_err(&d), "manifest: no `layers` array");
        index(&d, &[&manifest(&c, &[])]);
        assert_eq!(open_err(&d), "the manifest names no layer");
        index(&d, &[&manifest(&c, &[l.clone(), "sha256:x".into()])]);
        assert_eq!(open_err(&d), "manifest layer 1: `sha256:x` is not a sha256:<64 hex> digest");
        let bad = blob(&d, b"not json");
        index(&d, &[&manifest(&bad, &[l.clone()])]);
        assert!(open_err(&d).starts_with("config: JSON: "));
        index(&d, &[&manifest(&c, &[l.clone(), l])]);
        assert!(Layout::open(p(&d), "unused").is_ok());
    }

    fn layers_of(dir: &Path) -> Result<String, String> {
        let out = dir.join("layers.out");
        layers(&args(&["layers", "--layout", p(dir), "--busybox", "unused", "--out", p(&out)]))?;
        Ok(fs::read_to_string(out).unwrap())
    }

    #[test]
    fn layers_writes_every_digest_and_wants_the_entrypoint_in_the_last_layer() {
        let (d, ls) = layout("layers_ok", &[base_layer(), sha_layer_dot()], r#"["/bin/sh"]"#);
        assert_eq!(layers_of(&d), Ok(format!("{}\n{}\n", ls[0], ls[1])));
        for ep in [r#"["/"]"#, r#"["bin/sh"]"#, r#"["/bin/sh","-c"]"#, "[]", r#""/bin/sh""#, "[1]"] {
            let (d, _) = layout("layers_ep", &[base_layer(), sh_layer(0o755)], ep);
            assert!(layers_of(&d).unwrap_err().starts_with("the config's Entrypoint is not one absolute path: "), "{}", ep);
        }
        let not_there = Err("entrypoint /bin/sh is not a regular file with mode 0755 in the image's last layer".to_string());
        // In the first layer only.
        let (d, _) = layout("layers_first", &[sh_layer(0o755), base_layer()], r#"["/bin/sh"]"#);
        assert_eq!(layers_of(&d), not_there);
        for (name, last) in [
            ("layers_644", sh_layer(0o644)),
            ("layers_4755", sh_layer(0o4755)),
            ("layers_dir", tar::write::tar(&[("bin/", b'5', 0o755, b"", ""), ("bin/sh/", b'5', 0o755, b"", "")])),
            ("layers_link", tar::write::tar(&[("bin/", b'5', 0o755, b"", ""), ("bin/sh", b'2', 0o755, b"", "busybox")])),
        ] {
            let (d, _) = layout(name, &[base_layer(), last], r#"["/bin/sh"]"#);
            assert_eq!(layers_of(&d), not_there, "{}", name);
        }
    }

    /// bin/sh, mode 0755, spelled `./bin/sh` as many tars do.
    fn sha_layer_dot() -> Vec<u8> {
        tar::write::tar(&[("./bin/", b'5', 0o755, b"", ""), ("./bin/sh", b'0', 0o755, b"sh", "")])
    }

    /// `check` of the layout at `d` with the layer list `list` and the
    /// arguments `more`: its result and what it wrote.
    fn check_of(d: &Path, list: &[String], more: &[&str]) -> (Result<(), String>, Option<String>) {
        let lf = d.join("list");
        fs::write(&lf, list.iter().map(|l| format!("{}\n", l)).collect::<String>()).unwrap();
        let out = d.join("check.out");
        let _ = fs::remove_file(&out);
        let mut v = vec!["check", "--layout", p(d), "--busybox", "unused", "--layers", p(&lf), "--out", p(&out)];
        v.extend_from_slice(more);
        let r = check(&args(&v));
        (r, fs::read_to_string(&out).ok())
    }

    #[test]
    fn check_is_green_only_with_no_failure() {
        let (d, ls) = layout("check_ok", &[base_layer(), sh_layer(0o755)], r#"["/bin/sh"]"#);
        let ep = ["--entrypoint", "/bin/sh", "--file", "etc/f"];
        assert_eq!(check_of(&d, &ls, &ep), (Ok(()), Some("entrypoint /bin/sh\nlayers 2\nok exec /bin/sh -> bin/sh\nok file etc/f -> etc/f\n".into())));
        // The layer list short of its last digest, and reversed.
        let order = "the layer list is not the manifest's layers in order";
        for list in [vec![ls[0].clone()], vec![ls[1].clone(), ls[0].clone()]] {
            let (r, out) = check_of(&d, &list, &ep);
            assert!(r.unwrap_err().contains(order));
            assert_eq!(out, None);
        }
        // Red without --expect-red: the layout, then each failure.
        let (r, _) = check_of(&d, &ls, &["--entrypoint", "/bin/other", "--file", "etc/nope"]);
        assert_eq!(
            r,
            Err(format!(
                "{}:\n  the config's Entrypoint is not [\"/bin/other\"]: Some([\"/bin/sh\"])\n  exec /bin/other: not in the image\n  file etc/nope: not in the image",
                p(&d)
            ))
        );
    }

    #[test]
    fn only_the_last_layer_may_not_change_a_type() {
        let to_dir = || tar::write::tar(&[("etc/f/", b'5', 0o755, b"", "")]);
        let (d, ls) = layout("type_last", &[base_layer(), sh_layer(0o755), to_dir()], r#"["/bin/sh"]"#);
        let (r, _) = check_of(&d, &ls, &["--entrypoint", "/bin/sh"]);
        assert_eq!(r, Err(format!("{}:\n  the last layer turns etc/f from type - into type d", p(&d))));
        // The same change in a layer below the last is how layers work.
        let (d, ls) = layout("type_mid", &[base_layer(), to_dir(), sh_layer(0o755)], r#"["/bin/sh"]"#);
        assert_eq!(check_of(&d, &ls, &["--entrypoint", "/bin/sh"]).0, Ok(()));
        // A layer that cannot be applied is red, naming it.
        let wh = tar::write::tar(&[("etc/.wh.", b'0', 0o644, b"", "")]);
        let (d, ls) = layout("type_wh", &[base_layer(), wh], r#"["/bin/sh"]"#);
        assert_eq!(check_of(&d, &ls, &["--entrypoint", "/bin/sh"]).0, Err(format!("{}:\n  layer {}: a whiteout `etc/.wh.` names no entry", p(&d), ls[1])));
    }

    #[test]
    fn expect_red_writes_only_when_a_failure_names_the_text() {
        let (d, ls) = layout("expect", &[base_layer(), sh_layer(0o755)], r#"["/bin/sh"]"#);
        let green = ["--entrypoint", "/bin/sh"];
        let red = ["--entrypoint", "/bin/other", "--file", "etc/nope"];
        let with = |base: &[&'static str], t: &'static str| {
            let mut v = base.to_vec();
            v.extend(["--expect-red", t]);
            check_of(&d, &ls, &v)
        };
        assert_eq!(with(&green, "x"), (Err("green, want red naming `x`".into()), None));
        assert_eq!(with(&red, ""), (Err("--expect-red is empty".into()), None));
        assert_eq!(with(&green, ""), (Err("--expect-red is empty".into()), None));
        // The text names the second failure, not the first.
        let (r, out) = with(&red, "file etc/nope");
        assert_eq!(r, Ok(()));
        assert!(out.unwrap().starts_with("red as expected, naming `file etc/nope`:\n  the config's Entrypoint"));
        let (r, out) = with(&red, "nothing like this");
        assert!(r.unwrap_err().starts_with("red, but no failure names `nothing like this`:\n  the config's Entrypoint"));
        assert_eq!(out, None);
        let mut twice = red.to_vec();
        twice.extend(["--expect-red", "a", "--expect-red", "b"]);
        assert_eq!(check_of(&d, &ls, &twice).0, Err("--expect-red given twice".into()));
        // A layout that cannot be read is red too.
        let gone = d.join("gone");
        let out = d.join("gone.out");
        let v = ["check", "--layout", p(&gone), "--busybox", "unused", "--layers", "nolist", "--out", p(&out), "--entrypoint", "/bin/sh"];
        let mut e = v.to_vec();
        e.extend(["--expect-red", "cannot read"]);
        assert_eq!(check(&args(&e)), Ok(()));
        assert!(check(&args(&v)).unwrap_err().starts_with(&format!("{}:\n  cannot read ", p(&gone))));
    }
}
