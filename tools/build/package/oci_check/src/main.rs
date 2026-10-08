//! oci_check: reads an OCI image layout back (README.md).
//!
//!   oci_check layers --layout <dir> --busybox <exe> --out <file>
//!   oci_check check --layout <dir> --busybox <exe> --layers <file>
//!       --entrypoint </path> [--exec <path>]... [--file <path>]...
//!       --out <file> [--expect-red <text>]
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
//! A gzip layer is decompressed by `<busybox> gzip -dc`; nothing else runs.

mod image;
mod json;
mod tar;

use image::{Fs, Want};
use json::Value;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

struct Args {
    cmd: String,
    pairs: Vec<(String, String)>,
}

impl Args {
    fn parse(argv: Vec<String>) -> Result<Args, String> {
        let mut it = argv.into_iter().skip(1);
        let cmd = it.next().ok_or("no command (layers, check)")?;
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
    match l.entrypoint() {
        Some(ep) if ep == [want_ep] => ok.push(format!("entrypoint {}", want_ep)),
        other => bad.push(format!("the config's Entrypoint is not [\"{}\"]: {:?}", want_ep, other)),
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
    let mut wants = vec![(Want::Exec, want_ep.to_string())];
    wants.extend(a.all("--exec").into_iter().map(|p| (Want::Exec, p.to_string())));
    wants.extend(a.all("--file").into_iter().map(|p| (Want::File, p.to_string())));
    let (found, failed) = image::check_paths(&fs, &wants);
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
        "layers" => layers(&a),
        "check" => check(&a),
        c => Err(format!("unknown command `{}` (layers, check)", c)),
    });
    match r {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("oci_check: {}", e);
            ExitCode::FAILURE
        }
    }
}
