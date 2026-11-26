//! Forwards atmos-core-sys's link facts: the `atmos_core_mock_only` cfg (gates the tests that
//! call into libAtmosCore) and the library directory as an rpath for this crate's tests.

fn main() {
    println!("cargo::rustc-check-cfg=cfg(atmos_core_mock_only)");
    if std::env::var_os("DEP_ATMOSCORE_MOCK_ONLY").is_some() {
        println!("cargo::rustc-cfg=atmos_core_mock_only");
    }
    if let Some(dir) = std::env::var_os("DEP_ATMOSCORE_LIB_DIR") {
        println!("cargo::rustc-link-arg=-Wl,-rpath,{}", dir.to_string_lossy());
    }
}
