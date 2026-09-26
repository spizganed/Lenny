//! Lenny broker (Windows service, LocalSystem, installed by the installer; architecture.md §7.3). Creating `Global\`
//! objects needs SeCreateGlobalPrivilege, which a normal app launch doesn't have, and the MF camera's media source
//! runs in Frame Server (session 0), which only sees `Global\`. This service creates the frame buffer mapping and
//! event there with the §7.3 DACL and holds them until it stops; the app and both cameras just open them.

#[cfg(not(windows))]
fn main() {
    eprintln!("lenny-broker is a Windows service");
}

#[cfg(windows)]
fn main() {
    service::run();
}

#[cfg(windows)]
mod service {
    use std::ffi::c_void;
    use std::sync::atomic::{AtomicPtr, Ordering};
    use windows::core::{w, PWSTR};
    use windows::Win32::System::Services::{
        RegisterServiceCtrlHandlerExW, SetServiceStatus, StartServiceCtrlDispatcherW, SERVICE_ACCEPT_STOP,
        SERVICE_CONTROL_STOP, SERVICE_RUNNING, SERVICE_STATUS, SERVICE_STATUS_CURRENT_STATE, SERVICE_STATUS_HANDLE,
        SERVICE_STOPPED, SERVICE_TABLE_ENTRYW, SERVICE_WIN32_OWN_PROCESS,
    };

    static STATUS: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

    pub fn run() {
        let table = [
            SERVICE_TABLE_ENTRYW {
                lpServiceName: PWSTR(w!("LennyBroker").as_ptr() as *mut _),
                lpServiceProc: Some(main),
            },
            SERVICE_TABLE_ENTRYW::default(),
        ];
        if let Err(e) = unsafe { StartServiceCtrlDispatcherW(table.as_ptr()) } {
            eprintln!("lenny-broker runs as the LennyBroker service (installed by the Lenny installer): {e}");
            std::process::exit(1);
        }
    }

    fn report(state: SERVICE_STATUS_CURRENT_STATE, exit_code: u32) {
        let status = SERVICE_STATUS {
            dwServiceType: SERVICE_WIN32_OWN_PROCESS,
            dwCurrentState: state,
            dwControlsAccepted: if state == SERVICE_RUNNING { SERVICE_ACCEPT_STOP } else { 0 },
            dwWin32ExitCode: exit_code,
            ..Default::default()
        };
        unsafe {
            let _ = SetServiceStatus(SERVICE_STATUS_HANDLE(STATUS.load(Ordering::SeqCst)), &status);
        }
    }

    unsafe extern "system" fn handler(control: u32, _: u32, _: *mut c_void, _: *mut c_void) -> u32 {
        if control == SERVICE_CONTROL_STOP {
            report(SERVICE_STOPPED, 0);
            std::process::exit(0); // the OS closes the objects with the process
        }
        0
    }

    unsafe extern "system" fn main(_: u32, _: *mut PWSTR) {
        let Ok(h) = (unsafe { RegisterServiceCtrlHandlerExW(w!("LennyBroker"), Some(handler), None) }) else { return };
        STATUS.store(h.0, Ordering::SeqCst);
        // Held (never closed) for the life of the service.
        match lenny_vcam::create_objects(lenny_framebuf::MAPPING_NAME, lenny_framebuf::EVENT_NAME) {
            Ok(_objects) => {
                report(SERVICE_RUNNING, 0);
                loop {
                    std::thread::park();
                }
            }
            Err(_) => report(SERVICE_STOPPED, 1), // ERROR_INVALID_FUNCTION: shows as a failed start in services.msc
        }
    }
}
