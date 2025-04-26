use rustler::{Error, NifResult};
use std::process::{Command, Stdio};
use nix::sys::signal::{kill, Signal};
use nix::unistd::Pid;
use nix::sys::wait::{waitpid, WaitStatus};


#[rustler::nif]
fn spawn_nif(cmd: String, args: Vec<String>) -> NifResult<i32> {
    let mut command = Command::new(cmd);
    command.args(args)
           .stdin(Stdio::null())
           .stdout(Stdio::null())
           .stderr(Stdio::null());

    match command.spawn() {
        Ok(child) => Ok(child.id() as i32),
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
fn wait_nif(pid: i32) -> NifResult<i32> {
    let child_pid = Pid::from_raw(pid);

    match waitpid(child_pid, None) {
        Ok(WaitStatus::Exited(_, status)) => Ok(status),
        Ok(WaitStatus::Signaled(_, sig, _)) => Ok(128 + sig as i32),
        Ok(_) => Ok(-1),
        Err(err) => Err(Error::Term(Box::new(format!("waitpid failed: {err}")))),
    }
}

rustler::init!("Elixir.P");
