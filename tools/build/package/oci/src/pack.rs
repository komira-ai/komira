//! `komira_oci image`: an OCI image layout of the pinned base plus one
//! layer, a tree (tree.rs) laid at /, with the entrypoint named.
//!
//! The base is exactly the pinned blobs: the manifest must hash to its pin
//! and name the given config and layers, in order, by digest and size. The
//! config is the base's with the layer's diff_id, the Entrypoint, no Cmd,
//! the version label and one history entry added. The bytes depend only on
//! the tree and the base: tar entries are sorted, mtime, uid and gid are 0,
//! modes 0755/0644 (tree.rs), JSON keys are sorted and every timestamp is
//! 1970-01-01T00:00:00Z. The layer's gzip stream is the caller's; this file
//! does no I/O but reading the tree.

use crate::json::{self, Value};
use crate::sha256;
use crate::tar::{self, Item};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

pub const MANIFEST_TYPE: &str = "application/vnd.oci.image.manifest.v1+json";
pub const CONFIG_TYPE: &str = "application/vnd.oci.image.config.v1+json";
pub const INDEX_TYPE: &str = "application/vnd.oci.image.index.v1+json";
pub const LAYER_TYPE: &str = "application/vnd.oci.image.layer.v1.tar+gzip";
const EPOCH: &str = "1970-01-01T00:00:00Z";

fn s(x: &str) -> Value {
    Value::Str(x.to_string())
}

fn num(n: usize) -> Value {
    Value::Num(n.to_string())
}

fn obj(members: Vec<(&str, Value)>) -> Value {
    Value::Obj(members.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
}

fn descriptor(media_type: &str, data: &[u8]) -> Value {
    obj(vec![("mediaType", s(media_type)), ("digest", s(&sha256::digest(data))), ("size", num(data.len()))])
}

/// What names the image: `name` and `version` (history, tag), `repo`, and
/// the absolute `entrypoint`.
pub struct Named {
    pub name: String,
    pub version: String,
    pub repo: String,
    pub entrypoint: String,
}

/// `s` if it is non-empty and holds only letters, digits, `_.+-` and `extra`.
pub fn plain<'a>(s: &'a str, what: &str, extra: &str) -> Result<&'a str, String> {
    if s.is_empty() {
        return Err(format!("{} is empty", what));
    }
    match s.chars().find(|&c| !(c.is_ascii_alphanumeric() || "_.+-".contains(c) || extra.contains(c))) {
        Some(c) => Err(format!("{} `{}` holds `{}`", what, s, c)),
        None => Ok(s),
    }
}

/// A repository name as docker spells it in full: a first component without
/// `.` or `:` (and not `localhost`) is on docker.io, and a single-component
/// name there is under `library/`.
pub fn normalized_repo(repo: &str) -> String {
    match repo.split_once('/') {
        None => format!("docker.io/library/{}", repo),
        Some((first, _)) if first.contains(['.', ':']) || first == "localhost" => repo.to_string(),
        Some(_) => format!("docker.io/{}", repo),
    }
}

/// The tree's directories and files as layer entries, under no prefix.
pub fn tree_items(root: &Path) -> Result<Vec<Item>, String> {
    fn walk(dir: &Path, rel: &str, out: &mut Vec<Item>) -> Result<(), String> {
        for e in fs::read_dir(dir).map_err(|e| format!("cannot read {}: {}", dir.display(), e))? {
            let e = e.map_err(|e| format!("cannot read {}: {}", dir.display(), e))?;
            let name = e.file_name().into_string().map_err(|n| format!("{}: a name that is not UTF-8: {:?}", dir.display(), n))?;
            let path = format!("{}{}", rel, name);
            let m = fs::symlink_metadata(e.path()).map_err(|err| format!("cannot read {}: {}", path, err))?;
            if m.is_dir() {
                out.push(Item { path: format!("{}/", path), mode: 0o755, data: Vec::new() });
                walk(&e.path(), &format!("{}/", path), out)?;
            } else if m.is_file() {
                let data = fs::read(e.path()).map_err(|err| format!("cannot read {}: {}", path, err))?;
                out.push(Item { path, mode: if m.permissions().mode() & 0o111 != 0 { 0o755 } else { 0o644 }, data });
            } else {
                return Err(format!("{}: not a regular file or directory", path));
            }
        }
        Ok(())
    }
    let mut out = Vec::new();
    walk(root, "", &mut out)?;
    if !out.iter().any(|i| !i.path.ends_with('/')) {
        return Err(format!("tree {} holds no files", root.display()));
    }
    Ok(out)
}

/// The pinned base: its manifest's bytes and pinned digest, its config's
/// bytes, and each layer blob in the manifest's order.
pub struct Base {
    pub manifest: Vec<u8>,
    pub pin: String,
    pub config: Vec<u8>,
    pub layers: Vec<Vec<u8>>,
}

fn field<'a>(v: &'a Value, key: &str, what: &str) -> Result<&'a Value, String> {
    v.get(key).ok_or_else(|| format!("{}: no `{}`", what, key))
}

fn field_str<'a>(v: &'a Value, key: &str, what: &str) -> Result<&'a str, String> {
    field(v, key, what)?.as_str().ok_or_else(|| format!("{}: `{}` is not a string", what, key))
}

fn field_num<'a>(v: &'a Value, key: &str, what: &str) -> Result<&'a str, String> {
    match field(v, key, what)? {
        Value::Num(n) => Ok(n),
        _ => Err(format!("{}: `{}` is not a number", what, key)),
    }
}

/// The base manifest's layer descriptors, refused unless the base is
/// exactly the pinned blobs.
pub fn check_base(b: &Base) -> Result<Vec<Value>, String> {
    if sha256::digest(&b.manifest) != b.pin {
        return Err(format!("base manifest does not hash to its pin {}", b.pin));
    }
    let m = json::parse(&b.manifest).map_err(|e| format!("base manifest: {}", e))?;
    let mt = field_str(&m, "mediaType", "base manifest")?;
    if mt != MANIFEST_TYPE {
        return Err(format!("base manifest: mediaType {}, want {}", mt, MANIFEST_TYPE));
    }
    if field_num(&m, "schemaVersion", "base manifest")? != "2" {
        return Err("base manifest: schemaVersion is not 2".into());
    }
    let c = field(&m, "config", "base manifest")?;
    let want = field_str(c, "digest", "base manifest config")?;
    if sha256::digest(&b.config) != want {
        return Err(format!("base config does not hash to {}", want));
    }
    if field_num(c, "size", "base manifest config")? != b.config.len().to_string() {
        return Err("base config: size differs".into());
    }
    let ls = field(&m, "layers", "base manifest")?.as_arr().ok_or("base manifest: `layers` is not an array")?;
    if ls.len() != b.layers.len() {
        return Err(format!("base manifest names {} layers, {} given", ls.len(), b.layers.len()));
    }
    for (i, (d, blob)) in ls.iter().zip(&b.layers).enumerate() {
        let want = field_str(d, "digest", "base layer")?;
        if sha256::digest(blob) != want {
            return Err(format!("base layer {} does not hash to {}", i, want));
        }
        if field_num(d, "size", "base layer")? != blob.len().to_string() {
            return Err(format!("base layer {}: size differs", i));
        }
        if field_str(d, "mediaType", "base layer")? != LAYER_TYPE {
            return Err(format!("base layer {}: not {}", i, LAYER_TYPE));
        }
    }
    Ok(ls.to_vec())
}

/// The base config with the layer (`diff_id`, the digest of its tar), the
/// entrypoint, the version label and a history entry added, Cmd removed.
pub fn config(base: &[u8], diff_id: &str, n: &Named) -> Result<Value, String> {
    let mut c = json::parse(base).map_err(|e| format!("base config: {}", e))?;
    if field_str(&c, "architecture", "base config")? != "amd64" || field_str(&c, "os", "base config")? != "linux" {
        return Err("base config is not linux/amd64".into());
    }
    let mut rootfs = field(&c, "rootfs", "base config")?.clone();
    let mut ids = field(&rootfs, "diff_ids", "base config rootfs")?.as_arr().ok_or("base config: `diff_ids` is not an array")?.to_vec();
    ids.push(s(diff_id));
    rootfs.set("diff_ids", Value::Arr(ids))?;
    c.set("rootfs", rootfs)?;
    let mut cc = c.get("config").cloned().unwrap_or(Value::Obj(Vec::new()));
    cc.set("Entrypoint", Value::Arr(vec![s(&n.entrypoint)])).map_err(|e| format!("base config: `config`: {}", e))?;
    cc.remove("Cmd");
    let mut labels = cc.get("Labels").cloned().unwrap_or(Value::Obj(Vec::new()));
    labels.set("org.opencontainers.image.version", s(&n.version)).map_err(|e| format!("base config: `Labels`: {}", e))?;
    cc.set("Labels", labels)?;
    c.set("config", cc)?;
    let mut history = match c.get("history") {
        None => Vec::new(),
        Some(h) => h.as_arr().ok_or("base config: `history` is not an array")?.to_vec(),
    };
    history.push(obj(vec![("created", s(EPOCH)), ("created_by", s(&format!("komira oci_tree {} {}", n.name, n.version)))]));
    c.set("history", Value::Arr(history))?;
    c.set("created", s(EPOCH))?;
    Ok(c)
}

/// An image's files: the layout's blobs and JSON, and Docker's manifest.json.
pub struct Image {
    /// Every blob, base layers first, then the layer, config and manifest.
    pub blobs: Vec<Vec<u8>>,
    pub index: Vec<u8>,
    pub docker_manifest: Vec<u8>,
    pub manifest_digest: String,
}

/// The image of `base` plus the layer `layer_tar` (gzipped: `layer_gz`).
pub fn image(base: &Base, layer_tar: &[u8], layer_gz: &[u8], n: &Named) -> Result<Image, String> {
    let mut layers = check_base(base)?;
    let config_bytes = config(&base.config, &sha256::digest(layer_tar), n)?.to_json().into_bytes();
    layers.push(descriptor(LAYER_TYPE, layer_gz));
    let manifest = obj(vec![
        ("schemaVersion", num(2)),
        ("mediaType", s(MANIFEST_TYPE)),
        ("config", descriptor(CONFIG_TYPE, &config_bytes)),
        ("layers", Value::Arr(layers)),
    ]);
    let manifest_bytes = manifest.to_json().into_bytes();
    // index.json: one manifest, tagged <version> and named with the full
    // reference in io.containerd.image.name, which `docker load` (containerd
    // image store) names the image by, verbatim; so it is normalized as
    // docker does (`komira/base` -> `docker.io/komira/base`).
    let mut mdesc = descriptor(MANIFEST_TYPE, &manifest_bytes);
    mdesc.set("platform", obj(vec![("architecture", s("amd64")), ("os", s("linux"))]))?;
    mdesc.set(
        "annotations",
        obj(vec![
            ("io.containerd.image.name", s(&format!("{}:{}", normalized_repo(&n.repo), n.version))),
            ("org.opencontainers.image.ref.name", s(&n.version)),
        ]),
    )?;
    let index = obj(vec![("schemaVersion", num(2)), ("mediaType", s(INDEX_TYPE)), ("manifests", Value::Arr(vec![mdesc]))]);
    let blob_path = |b: &[u8]| s(&format!("blobs/sha256/{}", sha256::hex(b)));
    let mut dlayers: Vec<Value> = base.layers.iter().map(|b| blob_path(b)).collect();
    dlayers.push(blob_path(layer_gz));
    let docker = Value::Arr(vec![obj(vec![
        ("Config", blob_path(&config_bytes)),
        ("Layers", Value::Arr(dlayers)),
        ("RepoTags", Value::Arr(vec![s(&format!("{}:{}", n.repo, n.version))])),
    ])]);
    let mut blobs = base.layers.clone();
    blobs.push(layer_gz.to_vec());
    blobs.push(config_bytes);
    let manifest_digest = sha256::digest(&manifest_bytes);
    blobs.push(manifest_bytes);
    Ok(Image { blobs, index: index.to_json().into_bytes(), docker_manifest: docker.to_json().into_bytes(), manifest_digest })
}

pub const OCI_LAYOUT: &[u8] = b"{\"imageLayoutVersion\":\"1.0.0\"}";

/// The layout's files (path, bytes): each blob once, `oci-layout`,
/// `index.json`; and the archive's items, the same plus `manifest.json`.
pub fn files(img: &Image) -> (Vec<(String, Vec<u8>)>, Vec<Item>) {
    let mut layout: Vec<(String, Vec<u8>)> = Vec::new();
    for b in &img.blobs {
        let p = format!("blobs/sha256/{}", sha256::hex(b));
        // The same blob twice (two identical base layers) is one file.
        if !layout.iter().any(|(q, _)| *q == p) {
            layout.push((p, b.clone()));
        }
    }
    layout.push(("oci-layout".into(), OCI_LAYOUT.to_vec()));
    layout.push(("index.json".into(), img.index.clone()));
    let mut items = vec![Item { path: "blobs/".into(), mode: 0o755, data: Vec::new() }, Item { path: "blobs/sha256/".into(), mode: 0o755, data: Vec::new() }];
    items.extend(layout.iter().map(|(p, d)| Item { path: p.clone(), mode: 0o644, data: d.clone() }));
    items.push(Item { path: "manifest.json".into(), mode: 0o644, data: img.docker_manifest.clone() });
    (layout, items)
}

/// Writes the layout under `out`, the archive at `archive` and the digest.
pub fn write(img: &Image, out: &Path, archive: &Path, digest: &Path) -> Result<(), String> {
    let (layout, items) = files(img);
    let w = |p: &Path, d: &[u8]| fs::write(p, d).map_err(|e| format!("cannot write {}: {}", p.display(), e));
    fs::create_dir_all(out.join("blobs/sha256")).map_err(|e| format!("cannot create {}: {}", out.display(), e))?;
    for (p, d) in &layout {
        w(&out.join(p), d)?;
    }
    w(archive, &tar::write(items)?)?;
    w(digest, format!("{}\n", img.manifest_digest).as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    const BASE_CONFIG: &str = r#"{"architecture":"amd64","os":"linux","config":{"Cmd":["/bin/x"],"User":"65532","Labels":{"k":"v"}},"rootfs":{"type":"layers","diff_ids":["sha256:aa"]},"history":[{"created_by":"base"}],"created":"the base time"}"#;

    fn named() -> Named {
        Named { name: "floor".into(), version: "0.1.0".into(), repo: "komira/base".into(), entrypoint: "/komira/bin/supervisor".into() }
    }

    fn base() -> Base {
        let layer = b"gzip bytes of a base layer".to_vec();
        let manifest = format!(
            r#"{{"schemaVersion":2,"mediaType":"{}","config":{{"mediaType":"{}","digest":"{}","size":{}}},"layers":[{{"mediaType":"{}","digest":"{}","size":{}}}]}}"#,
            MANIFEST_TYPE,
            CONFIG_TYPE,
            sha256::digest(BASE_CONFIG.as_bytes()),
            BASE_CONFIG.len(),
            LAYER_TYPE,
            sha256::digest(&layer),
            layer.len()
        );
        Base { pin: sha256::digest(manifest.as_bytes()), manifest: manifest.into_bytes(), config: BASE_CONFIG.as_bytes().to_vec(), layers: vec![layer] }
    }

    #[test]
    fn the_config_names_the_entrypoint_layer_and_version() {
        let c = config(BASE_CONFIG.as_bytes(), "sha256:bb", &named()).unwrap();
        assert_eq!(
            c.to_json(),
            concat!(
                r#"{"architecture":"amd64","config":{"Entrypoint":["/komira/bin/supervisor"],"Labels":{"k":"v","org.opencontainers.image.version":"0.1.0"},"User":"65532"},"#,
                r#""created":"1970-01-01T00:00:00Z","history":[{"created_by":"base"},{"created":"1970-01-01T00:00:00Z","created_by":"komira oci_tree floor 0.1.0"}],"#,
                r#""os":"linux","rootfs":{"diff_ids":["sha256:aa","sha256:bb"],"type":"layers"}}"#
            )
        );
        let arm = BASE_CONFIG.replace("amd64", "arm64");
        assert_eq!(config(arm.as_bytes(), "sha256:bb", &named()).unwrap_err(), "base config is not linux/amd64");
    }

    #[test]
    fn the_base_must_be_exactly_the_pinned_blobs() {
        assert_eq!(check_base(&base()).unwrap().len(), 1);
        let mut b = base();
        b.pin = sha256::digest(b"other");
        assert!(check_base(&b).unwrap_err().contains("does not hash to its pin"));
        let mut b = base();
        b.config.push(b' ');
        assert!(check_base(&b).unwrap_err().contains("base config does not hash"));
        let mut b = base();
        b.layers[0].push(0);
        assert_eq!(check_base(&b).unwrap_err(), format!("base layer 0 does not hash to {}", sha256::digest(&base().layers[0])));
        let mut b = base();
        b.layers.push(Vec::new());
        assert_eq!(check_base(&b).unwrap_err(), "base manifest names 1 layers, 2 given");
        // A size off by one under a correct digest, with the pin recomputed, so
        // only the size check can refuse it.
        let resized = |from: String, to: String| {
            let mut b = base();
            let m = String::from_utf8(b.manifest.clone()).unwrap();
            assert_eq!(m.matches(&from).count(), 1, "{}", from);
            b.manifest = m.replace(&from, &to).into_bytes();
            b.pin = sha256::digest(&b.manifest);
            b
        };
        let n = BASE_CONFIG.len();
        let b = resized(format!(r#""size":{}}},"layers""#, n), format!(r#""size":{}}},"layers""#, n + 1));
        assert_eq!(check_base(&b).unwrap_err(), "base config: size differs");
        let n = base().layers[0].len();
        let b = resized(format!(r#""size":{}}}]"#, n), format!(r#""size":{}}}]"#, n - 1));
        assert_eq!(check_base(&b).unwrap_err(), "base layer 0: size differs");
    }

    #[test]
    fn the_image_adds_one_layer_and_tags_the_version() {
        let img = image(&base(), b"layer tar", b"layer gz", &named()).unwrap();
        let m = json::parse(img.blobs.last().unwrap()).unwrap();
        let layers = m.get("layers").unwrap().as_arr().unwrap();
        assert_eq!(layers.len(), 2);
        assert_eq!(layers[1].get("digest").unwrap().as_str(), Some(sha256::digest(b"layer gz").as_str()));
        assert_eq!(img.manifest_digest, sha256::digest(img.blobs.last().unwrap()));
        let c = json::parse(&img.blobs[2]).unwrap();
        assert_eq!(m.get("config").unwrap().get("digest").unwrap().as_str(), Some(sha256::digest(&img.blobs[2]).as_str()));
        let ids = c.get("rootfs").unwrap().get("diff_ids").unwrap().as_arr().unwrap();
        assert_eq!(ids[1].as_str(), Some(sha256::digest(b"layer tar").as_str()));
        let index = String::from_utf8(img.index.clone()).unwrap();
        assert!(index.contains(r#""io.containerd.image.name":"docker.io/komira/base:0.1.0""#), "{}", index);
        assert!(String::from_utf8(img.docker_manifest.clone()).unwrap().contains(r#""RepoTags":["komira/base:0.1.0"]"#));
        let (layout, items) = files(&img);
        let names: Vec<&str> = layout.iter().map(|(p, _)| p.as_str()).collect();
        assert_eq!(names.len(), 6);
        assert_eq!(&names[4..], ["oci-layout", "index.json"]);
        assert_eq!(items.len(), 9);
        // Same inputs, same bytes.
        assert_eq!(image(&base(), b"layer tar", b"layer gz", &named()).unwrap().manifest_digest, img.manifest_digest);
    }

    #[test]
    fn names_are_plain_and_repositories_normalized() {
        assert_eq!(normalized_repo("hello"), "docker.io/library/hello");
        assert_eq!(normalized_repo("komira/base"), "docker.io/komira/base");
        assert_eq!(normalized_repo("ghcr.io/a/b"), "ghcr.io/a/b");
        assert_eq!(normalized_repo("localhost/a"), "localhost/a");
        assert_eq!(plain("0.1.0~rc1", "version", "~"), Ok("0.1.0~rc1"));
        assert_eq!(plain("a b", "name", ""), Err("name `a b` holds ` `".into()));
        assert_eq!(plain("", "name", ""), Err("name is empty".into()));
    }
}
