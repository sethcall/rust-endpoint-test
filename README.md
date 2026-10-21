# rust-endpoint-test

A minimal Rust "hello world" that builds with both Cargo and Bazel.

It includes a `build.rs` build script and a unit test, so a build compiles
and runs a few small executables, just like a normal Rust project.

## Cargo

```sh
cargo run
cargo test
cargo +nightly run   # any installed toolchain
```

## Bazel

```sh
bazel run //:hello
bazel test //:hello_test
```

Bazel downloads its own Rust toolchain through `rules_rust`
(version set in `MODULE.bazel`). `.bazelversion` pins the Bazel version for Bazelisk.

## Scripts

`scripts/test-macos.sh` and `scripts/test-windows.ps1` install rustup, a few
Rust toolchains and Bazelisk, then build, test and run this project with each.
