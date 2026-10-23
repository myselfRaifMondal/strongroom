//! Writes the VTF1 test vectors to `<repo>/vectors/`.
//!
//!     cargo run -p vtf-core --release --example gen_vectors

#[path = "../tests/common/mod.rs"]
mod common;

use std::fs;
use std::path::Path;

fn main() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../vectors");
    fs::create_dir_all(root.join("positive")).unwrap();
    fs::create_dir_all(root.join("negative")).unwrap();
    for p in common::positives() {
        fs::write(root.join(format!("positive/{}.vtf", p.name)), &p.file).unwrap();
        fs::write(root.join(format!("positive/{}.cbor", p.name)), &p.cbor).unwrap();
    }
    for n in common::negatives() {
        // Generation also asserts each vector is rejected by its named check.
        assert_eq!(common::reject(n), n.check, "vector {}", n.name);
        fs::write(root.join(format!("negative/{}.vtf", n.name)), &n.file).unwrap();
    }
    fs::write(root.join("manifest.json"), common::manifest_json()).unwrap();
    println!("vectors written to {}", root.display());
}
