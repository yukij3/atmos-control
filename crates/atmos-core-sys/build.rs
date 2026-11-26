//! Links libAtmosCore.dylib, the Swift engine (SwiftPM product `AtmosCore`).
//!
//! Where it looks, in order:
//! 1. `ATMOS_CORE_LIB_DIR` (a directory holding libAtmosCore.dylib);
//! 2. `<repo>/.build/<profile>/` for this cargo profile (`release` or `debug`);
//! 3. the other SwiftPM configuration, with a warning.
//!
//! `ATMOS_CORE_MOCK_ONLY=1` builds without the Swift library: the real engine is then
//! unavailable at run time and only the mock engine works (enough for headless view work).
//!
//! The directory goes to dependents as `DEP_ATMOSCORE_LIB_DIR` (this crate `links =
//! "AtmosCore"`); the app crate's build script turns it into the binary's rpaths, since a
//! library's build script can't pass link arguments to other packages' binaries.

use std::env;
use std::path::{Path, PathBuf};

const LIB: &str = "libAtmosCore.dylib";

fn main() {
    println!("cargo::rustc-check-cfg=cfg(atmos_core_mock_only)");
    println!("cargo::rerun-if-env-changed=ATMOS_CORE_LIB_DIR");
    println!("cargo::rerun-if-env-changed=ATMOS_CORE_MOCK_ONLY");

    if env::var_os("ATMOS_CORE_MOCK_ONLY").is_some_and(|v| !v.is_empty() && v != "0") {
        println!("cargo::rustc-cfg=atmos_core_mock_only");
        println!("cargo::metadata=mock_only=1");
        println!("cargo::warning=ATMOS_CORE_MOCK_ONLY: building without libAtmosCore; only the mock engine will work");
        return;
    }

    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let repo = manifest.join("../..");
    let repo = repo.canonicalize().unwrap_or(repo);
    let profile = env::var("PROFILE").unwrap_or_else(|_| "debug".into());
    let (own, other) = if profile == "release" { ("release", "debug") } else { ("debug", "release") };

    let dir = if let Some(dir) = env::var_os("ATMOS_CORE_LIB_DIR") {
        let dir = PathBuf::from(dir);
        if !dir.join(LIB).is_file() {
            fail(&format!("ATMOS_CORE_LIB_DIR={} has no {LIB}", dir.display()));
        }
        dir.canonicalize().unwrap_or(dir)
    } else if let Some(dir) = found(&repo.join(".build").join(own)) {
        dir
    } else if let Some(dir) = found(&repo.join(".build").join(other)) {
        println!(
            "cargo::warning=using the Swift {other} build of {LIB} for a cargo {profile} build ({})",
            dir.display()
        );
        dir
    } else {
        fail(&format!(
            "{LIB} not found in {}/.build/{own} (or .build/{other}).\n\
             Build the Swift engine first:\n\
             \n    swift build -c {own} --product AtmosCore\n\n\
             (App/build-app.sh does both builds), or set ATMOS_CORE_LIB_DIR, or build the UI \
             against the mock engine only with ATMOS_CORE_MOCK_ONLY=1.",
            repo.display()
        ));
    };
    println!("cargo::rerun-if-changed={}", dir.join(LIB).display());
    println!("cargo::rustc-link-search=native={}", dir.display());
    println!("cargo::rustc-link-lib=dylib=AtmosCore");
    println!("cargo::metadata=lib_dir={}", dir.display());
    // Only this package's linked targets (its unit tests) get this; they load the dylib via @rpath.
    println!("cargo::rustc-link-arg=-Wl,-rpath,{}", dir.display());
}

fn found(dir: &Path) -> Option<PathBuf> {
    dir.join(LIB).is_file().then(|| dir.to_path_buf())
}

fn fail(msg: &str) -> ! {
    // A panic message from a build script shows in full; keep it the only error.
    eprintln!("\nerror: {msg}\n");
    panic!("{msg}");
}
