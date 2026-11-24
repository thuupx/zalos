#![cfg_attr(target_arch = "wasm32", feature(thread_local))]

#[cfg(target_arch = "wasm32")]
#[thread_local]
pub static _FORCE_TLS: u8 = 0;

#[cfg(target_arch = "wasm32")]
#[no_mangle]
pub extern "C" fn _force_tls_addr() -> usize {
    &_FORCE_TLS as *const u8 as usize
}

pub mod api;
pub mod frb_generated;
