use rustler::{Env, Error, NifResult, ResourceArc};
use std::io::{Read, Write};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use nix::sys::signal::{kill, Signal};
use nix::unistd::Pid;

pub struct ProcessResource {
    child: Mutex<Option<Child>>,
}

#[allow(non_local_definitions)]
fn load(env: Env, _info: rustler::Term) -> bool {
    rustler::resource!(ProcessResource, env)
}

#[rustler::nif]
fn spawn_nif(cmd: String, args: Vec<String>) -> NifResult<(ResourceArc<ProcessResource>, i32)> {
    let mut command = Command::new(cmd);
    command.args(args)
           .stdin(Stdio::piped())
           .stdout(Stdio::piped())
           .stderr(Stdio::piped());

    match command.spawn() {
        Ok(child) => {
            let pid = child.id() as i32;
            let resource = ResourceArc::new(ProcessResource {
                child: Mutex::new(Some(child)),
            });
            Ok((resource, pid))
        },
        Err(e) => Err(Error::Term(Box::new(format!("Failed to spawn: {}", e))))
    }
}

#[rustler::nif]
fn signal_nif(pid: i32, signal: i32) -> NifResult<()> {
    let signal = Signal::try_from(signal)
        .map_err(|_| Error::Term(Box::new("Invalid signal")))?;

    kill(Pid::from_raw(pid), signal)
        .map_err(|e| Error::Term(Box::new(format!("Kill failed: {}", e))))?;

    Ok(())
}

#[rustler::nif(schedule = "DirtyIo")]
fn wait_nif(resource: ResourceArc<ProcessResource>) -> NifResult<i32> {
    let mut child_lock = resource.child.lock().map_err(|e| Error::Term(Box::new(format!("Lock failed: {}", e))))?;

    if let Some(child) = child_lock.as_mut() {
        match child.wait() {
            Ok(status) => {
                if let Some(code) = status.code() {
                    Ok(code)
                } else {
                    #[cfg(unix)]
                    {
                        use std::os::unix::process::ExitStatusExt;
                        if let Some(signal) = status.signal() {
                            return Ok(128 + signal);
                        }
                    }
                    Ok(-1)
                }
            },
            Err(e) => Err(Error::Term(Box::new(format!("Failed to wait: {}", e))))
        }
    } else {
        Err(Error::Term(Box::new("Process already reaped")))
    }
}

#[rustler::nif]
fn alive_nif(resource: ResourceArc<ProcessResource>) -> NifResult<bool> {
    let mut child_lock = resource.child.lock().map_err(|e| Error::Term(Box::new(format!("Lock failed: {}", e))))?;

    if let Some(child) = child_lock.as_mut() {
        match child.try_wait() {
            Ok(Some(_)) => Ok(false),
            Ok(None) => Ok(true),
            Err(_) => Ok(false),
        }
    } else {
        Ok(false)
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn read_stdout_nif(resource: ResourceArc<ProcessResource>) -> NifResult<String> {
    let mut child_lock = resource.child.lock().map_err(|e| Error::Term(Box::new(format!("Lock failed: {}", e))))?;

    if let Some(child) = child_lock.as_mut() {
        if let Some(stdout) = child.stdout.as_mut() {
            let mut buf = [0; 1024];
            match stdout.read(&mut buf) {
                Ok(0) => Ok("".to_string()),
                Ok(n) => Ok(String::from_utf8_lossy(&buf[..n]).to_string()),
                Err(e) => Err(Error::Term(Box::new(format!("Read failed: {}", e))))
            }
        } else {
            Ok("".to_string())
        }
    } else {
        Err(Error::Term(Box::new("Process invalid")))
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn read_stderr_nif(resource: ResourceArc<ProcessResource>) -> NifResult<String> {
    let mut child_lock = resource.child.lock().map_err(|e| Error::Term(Box::new(format!("Lock failed: {}", e))))?;

    if let Some(child) = child_lock.as_mut() {
        if let Some(stderr) = child.stderr.as_mut() {
            let mut buf = [0; 1024];
            match stderr.read(&mut buf) {
                Ok(0) => Ok("".to_string()),
                Ok(n) => Ok(String::from_utf8_lossy(&buf[..n]).to_string()),
                Err(e) => Err(Error::Term(Box::new(format!("Read failed: {}", e))))
            }
        } else {
            Ok("".to_string())
        }
    } else {
        Err(Error::Term(Box::new("Process invalid")))
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn write_stdin_nif(resource: ResourceArc<ProcessResource>, data: String) -> NifResult<()> {
    let mut child_lock = resource.child.lock().map_err(|e| Error::Term(Box::new(format!("Lock failed: {}", e))))?;

    if let Some(child) = child_lock.as_mut() {
        if let Some(stdin) = child.stdin.as_mut() {
            stdin.write_all(data.as_bytes())
                .map_err(|e| Error::Term(Box::new(format!("Write failed: {}", e))))?;
            Ok(())
        } else {
            Err(Error::Term(Box::new("Stdin not available")))
        }
    } else {
        Err(Error::Term(Box::new("Process invalid")))
    }
}

rustler::init!("Elixir.P", load = load);
