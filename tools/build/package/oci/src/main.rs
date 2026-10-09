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
    let mut gz = o.stdout;
    // ID1 ID2, deflate, no flags (no name, no comment, no header CRC).
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

fn main() -> ExitCode {
    let r = Args::parse(std::env::args().collect()).and_then(|a| match a.cmd.as_str() {
        "tree" => tree_cmd(&a),
        "image" => image_cmd(&a),
        "layers" => layers(&a),
        "check" => check(&a),
        c => Err(format!("unknown command `{}` (tree, image, layers, check)", c)),
    });
    match r {
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
}
