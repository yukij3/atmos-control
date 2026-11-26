//! The binary's rpaths for libAtmosCore (`@rpath/libAtmosCore.dylib`):
//! - `@executable_path/../Frameworks`: the app bundle (App/build-app.sh copies the dylib there);
//! - the SwiftPM build directory atmos-core-sys linked against, so `cargo run` works.
//!   App/build-app.sh deletes this absolute rpath from the bundled copy.

fn main() {
    println!("cargo::rerun-if-changed=build.rs");
    println!("cargo::rerun-if-changed=../../design/svg/glyph-on.svg");
    println!("cargo::rerun-if-changed=../../design/svg/glyph-off.svg");
    println!("cargo::rustc-link-arg-bins=-Wl,-rpath,@executable_path/../Frameworks");
    if let Some(dir) = std::env::var_os("DEP_ATMOSCORE_LIB_DIR") {
        println!("cargo::rustc-link-arg-bins=-Wl,-rpath,{}", dir.to_string_lossy());
    }
}
