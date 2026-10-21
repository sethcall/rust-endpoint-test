// Build scripts are compiled and executed during every cargo build.
// This exercises the "freshly built executable runs immediately" path.
fn main() {
    let rustc = std::env::var("RUSTC").unwrap_or_else(|_| "rustc".into());
    let out = std::process::Command::new(rustc).arg("--version").output().expect("run rustc");
    let ver = String::from_utf8_lossy(&out.stdout).trim().to_string();
    println!("cargo:rustc-env=BUILT_WITH={ver}");
}
