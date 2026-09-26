use std::ffi::c_void;
use std::ptr;

pub struct SessionMachine {
    pub state: i32,
    pub zoom: f32,
    pub pan_x: f32,
    pub pan_y: f32,
}

#[no_mangle]
pub extern "C" fn lenny_session_new() -> *mut SessionMachine {
    let session = Box::new(SessionMachine {
        state: 0, // Disconnected
        zoom: 1.0,
        pan_x: 0.0,
        pan_y: 0.0,
    });
    Box::into_raw(session)
}

#[no_mangle]
pub extern "C" fn lenny_session_free(ptr: *mut SessionMachine) {
    if !ptr.is_null() {
        unsafe {
            let _ = Box::from_raw(ptr);
        }
    }
}

#[no_mangle]
pub extern "C" fn lenny_session_get_state(ptr: *const SessionMachine) -> i32 {
    if ptr.is_null() {
        return -1;
    }
    unsafe { (*ptr).state }
}

#[no_mangle]
pub extern "C" fn lenny_set_zoom_pan(ptr: *mut SessionMachine, zoom: f32, pan_x: f32, pan_y: f32) -> i32 {
    if ptr.is_null() {
        return -1;
    }
    unsafe {
        (*ptr).zoom = zoom;
        (*ptr).pan_x = pan_x;
        (*ptr).pan_y = pan_y;
    }
    0
}