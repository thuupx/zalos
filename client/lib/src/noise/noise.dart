// Thin Dart facade over the generated flutter_rust_bridge bindings.
// All Noise logic lives in the Rust crate; this file only re-exports it
// behind a stable import path for app code.
export '../rust_lib/api/noise.dart';
export '../rust_lib/frb_generated.dart' show RustLib;
