// embed the framework tree as a tarball so the binary is self-contained. a
// tarball (not include_dir) is used deliberately: it preserves file modes, and
// the toolbox/initramfs scripts must stay executable after extraction.

use std::env;
use std::process::Command;

// framework assets carried inside the binary; a project overlays its own on top.
const ASSETS: &[&str] = &["overlay", "toolbox", "tests", "depends"];

fn main() {
    let manifest = env::var("CARGO_MANIFEST_DIR").unwrap();
    let out = env::var("OUT_DIR").unwrap();
    let tarball = format!("{out}/framework.tar");

    for a in ASSETS {
        println!("cargo:rerun-if-changed={manifest}/{a}");
    }

    let mut cmd = Command::new("tar");
    cmd.args(["--numeric-owner", "--owner=0", "--group=0"])
        .arg("--exclude=tests/.work")
        .arg("--exclude=*.img")
        .arg("--exclude=*.img.xz")
        .args(["-C", &manifest, "-cf", &tarball])
        .args(ASSETS);
    let status = cmd.status().expect("run tar to build the framework tarball");
    assert!(status.success(), "framework tarball build failed");
}
