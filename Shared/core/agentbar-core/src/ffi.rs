//! Narrow metadata-only C ABI v1. Separate from production Swift integration.
use crate::parser::{adapter, ParseContext, ParserState, UsageAdapter};
use std::{
    ffi::{c_char, CStr, CString},
    panic::{catch_unwind, AssertUnwindSafe},
};
#[no_mangle]
pub extern "C" fn agentbar_core_abi_version() -> u32 {
    1
}
/// # Safety
/// input must point to a valid NUL-terminated UTF-8 JSON request for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn agentbar_core_parse_json(input: *const c_char) -> *mut c_char {
    if input.is_null() {
        return std::ptr::null_mut();
    }
    let r = catch_unwind(AssertUnwindSafe(|| -> crate::Result<serde_json::Value> {
        let req: serde_json::Value = serde_json::from_str(CStr::from_ptr(input).to_str()?)?;
        let agent = req["agent"].as_str().ok_or("Agent missing")?;
        let parser = adapter(agent)?;
        let mut state: ParserState = if req.get("state").is_some() {
            serde_json::from_value(req["state"].clone())?
        } else {
            ParserState::default()
        };
        let mut ctx = ParseContext::fixture(agent, "fixture");
        if let Some(s) = req["session"].as_str() {
            ctx.kimi_session = Some(s.into());
        }
        let event = parser.parse(
            req["line"].as_str().ok_or("Line missing")?.as_bytes(),
            &mut state,
            &ctx,
        )?;
        Ok(serde_json::json!({"abiVersion":1,"event":event,"state":state}))
    }));
    let text = match r {
        Ok(Ok(v)) => v.to_string(),
        Ok(Err(_)) => "{\"abiVersion\":1,\"error\":\"INVALID_METADATA_REQUEST\"}".into(),
        Err(_) => "{\"abiVersion\":1,\"error\":\"PANIC_CONTAINED\"}".into(),
    };
    CString::new(text)
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}
/// # Safety
/// pointer must be NULL or a still-owned buffer returned by agentbar_core_parse_json, freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn agentbar_core_free(pointer: *mut c_char) {
    if !pointer.is_null() {
        drop(CString::from_raw(pointer))
    }
}
