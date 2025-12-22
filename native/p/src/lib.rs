use nix::fcntl::{fcntl, FcntlArg, OFlag};
use nix::sys::signal::{kill, Signal};
use nix::unistd::Pid;
use rustler::types::binary::OwnedBinary;
use rustler::{Binary, Encoder, Env, Error, NifResult, ResourceArc, Term};
use std::fs::File;
use std::io::{Read, Write};
use std::os::unix::io::AsRawFd;
use std::process::{Child, ChildStderr, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::Mutex;

#[cfg(target_os = "linux")]
use std::os::unix::process::CommandExt;

mod atoms {
    rustler::atoms! {
        ok,
        eof,
        would_block,
        error,
        partial,
        broken_pipe,
        not_piped,
        already_exited,
        // stdio config atoms
        null,
        pipe,
        file,
    }
}

/// Internal stdio configuration
#[derive(Debug)]
enum StdioConfig {
    Null,
    Pipe,
    Inherit,
    File(String),
}

/// Parse stdio config from mode string and optional path
/// mode is "null", "pipe", "inherit", or "file"
/// path is the file path (empty string if not file mode)
fn parse_stdio_config(mode: &str, path: &str) -> NifResult<StdioConfig> {
    match mode {
        "null" => Ok(StdioConfig::Null),
        "pipe" => Ok(StdioConfig::Pipe),
        "inherit" => Ok(StdioConfig::Inherit),
        "file" => {
            if path.is_empty() {
                return Err(Error::Term(Box::new("file mode requires a path")));
            }
            Ok(StdioConfig::File(path.to_string()))
        }
        _ => Err(Error::Term(Box::new(format!(
            "invalid stdio mode: {}, expected null, pipe, inherit, or file",
            mode
        )))),
    }
}

pub struct ProcessResource {
    child: Mutex<Option<Child>>,
    /// Cached exit code from try_wait, so alive? doesn't lose the status
    cached_exit_code: Mutex<Option<i32>>,
    /// Stdin pipe, held separately for independent locking
    stdin_pipe: Mutex<Option<ChildStdin>>,
    /// Stdout pipe, held separately for independent locking
    stdout_pipe: Mutex<Option<ChildStdout>>,
    /// Stderr pipe, held separately for independent locking
    stderr_pipe: Mutex<Option<ChildStderr>>,
}

/// Set O_NONBLOCK on a file descriptor
fn set_nonblocking<T: AsRawFd>(stream: &T) -> Result<(), nix::Error> {
    let fd = stream.as_raw_fd();
    let flags = fcntl(fd, FcntlArg::F_GETFL)?;
    let new_flags = OFlag::from_bits_truncate(flags) | OFlag::O_NONBLOCK;
    fcntl(fd, FcntlArg::F_SETFL(new_flags))?;
    Ok(())
}

/// Convert an ExitStatus to an exit code integer
fn exit_status_to_code(status: std::process::ExitStatus) -> i32 {
    if let Some(code) = status.code() {
        code
    } else {
        #[cfg(unix)]
        {
            use std::os::unix::process::ExitStatusExt;
            if let Some(signal) = status.signal() {
                return 128 + signal;
            }
        }
        -1
    }
}

#[allow(non_local_definitions)]
fn load(env: Env, _info: rustler::Term) -> bool {
    rustler::resource!(ProcessResource, env)
}

#[rustler::nif]
fn spawn_nif(
    cmd: String,
    arguments: Vec<String>,
    stdin_mode: String,
    stdin_path: String,
    stdout_mode: String,
    stdout_path: String,
    stderr_mode: String,
    stderr_path: String,
    env: Vec<(String, String)>,
    cd: String,
) -> NifResult<(ResourceArc<ProcessResource>, i32)> {
    let stdin_config = parse_stdio_config(&stdin_mode, &stdin_path)?;
    let stdout_config = parse_stdio_config(&stdout_mode, &stdout_path)?;
    let stderr_config = parse_stdio_config(&stderr_mode, &stderr_path)?;

    let mut command = Command::new(&cmd);
    command.args(&arguments);

    // Set environment variables (merged with inherited environment)
    for (key, value) in env {
        command.env(key, value);
    }

    if !cd.is_empty() {
        command.current_dir(&cd);
    }

    // Configure stdin
    match &stdin_config {
        StdioConfig::Null => {
            command.stdin(Stdio::null());
        }
        StdioConfig::Pipe => {
            command.stdin(Stdio::piped());
        }
        StdioConfig::Inherit => {
            command.stdin(Stdio::inherit());
        }
        StdioConfig::File(path) => {
            let file = File::open(path).map_err(|e| {
                Error::Term(Box::new(format!(
                    "Failed to open stdin file {}: {}",
                    path, e
                )))
            })?;
            command.stdin(Stdio::from(file));
        }
    }

    // Configure stdout
    match &stdout_config {
        StdioConfig::Null => {
            command.stdout(Stdio::null());
        }
        StdioConfig::Pipe => {
            command.stdout(Stdio::piped());
        }
        StdioConfig::Inherit => {
            command.stdout(Stdio::inherit());
        }
        StdioConfig::File(path) => {
            let file = File::create(path).map_err(|e| {
                Error::Term(Box::new(format!(
                    "Failed to create stdout file {}: {}",
                    path, e
                )))
            })?;
            command.stdout(Stdio::from(file));
        }
    }

    // Configure stderr
    match &stderr_config {
        StdioConfig::Null => {
            command.stderr(Stdio::null());
        }
        StdioConfig::Pipe => {
            command.stderr(Stdio::piped());
        }
        StdioConfig::Inherit => {
            command.stderr(Stdio::inherit());
        }
        StdioConfig::File(path) => {
            let file = File::create(path).map_err(|e| {
                Error::Term(Box::new(format!(
                    "Failed to create stderr file {}: {}",
                    path, e
                )))
            })?;
            command.stderr(Stdio::from(file));
        }
    }

    // On Linux, set PR_SET_PDEATHSIG so child gets SIGKILL when parent dies.
    // This prevents orphan processes if the BEAM crashes.
    #[cfg(target_os = "linux")]
    unsafe {
        command.pre_exec(|| {
            // PR_SET_PDEATHSIG = 1, SIGKILL = 9
            let result = libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL);
            if result == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }

    match command.spawn() {
        Ok(mut child) => {
            let pid = child.id() as i32;

            // Extract and configure pipes
            let stdin_pipe = child.stdin.take();
            let stdout_pipe = child.stdout.take();
            let stderr_pipe = child.stderr.take();

            // Set non-blocking on readable pipes
            if let Some(ref stdout) = stdout_pipe {
                if let Err(e) = set_nonblocking(stdout) {
                    return Err(Error::Term(Box::new(format!(
                        "Failed to set stdout non-blocking: {}",
                        e
                    ))));
                }
            }
            if let Some(ref stderr) = stderr_pipe {
                if let Err(e) = set_nonblocking(stderr) {
                    return Err(Error::Term(Box::new(format!(
                        "Failed to set stderr non-blocking: {}",
                        e
                    ))));
                }
            }
            // Set non-blocking on stdin too for non-blocking writes
            if let Some(ref stdin) = stdin_pipe {
                if let Err(e) = set_nonblocking(stdin) {
                    return Err(Error::Term(Box::new(format!(
                        "Failed to set stdin non-blocking: {}",
                        e
                    ))));
                }
            }

            let resource = ResourceArc::new(ProcessResource {
                child: Mutex::new(Some(child)),
                cached_exit_code: Mutex::new(None),
                stdin_pipe: Mutex::new(stdin_pipe),
                stdout_pipe: Mutex::new(stdout_pipe),
                stderr_pipe: Mutex::new(stderr_pipe),
            });
            Ok((resource, pid))
        }
        Err(e) => Err(Error::Term(Box::new(format!("Failed to spawn: {}", e)))),
    }
}

#[rustler::nif]
fn signal_nif<'a>(
    env: Env<'a>,
    resource: ResourceArc<ProcessResource>,
    signal: i32,
) -> NifResult<Term<'a>> {
    // Hold lock on cached_exit_code while we check and potentially signal.
    // This prevents alive_nif from reaping the zombie between our check and kill().
    let cached = resource
        .cached_exit_code
        .lock()
        .map_err(|e| Error::Term(Box::new(format!("Lock failed: {}", e))))?;

    if cached.is_some() {
        // Process has been reaped (by alive? or wait), PID may have been recycled.
        // Refuse to signal to avoid hitting an unrelated process.
        return Ok((atoms::error(), atoms::already_exited()).encode(env));
    }

    // Get PID from child (process is either running or a zombie we haven't reaped)
    let child_lock = resource
        .child
        .lock()
        .map_err(|e| Error::Term(Box::new(format!("Lock failed: {}", e))))?;

    let pid = if let Some(child) = child_lock.as_ref() {
        child.id() as i32
    } else {
        return Ok((atoms::error(), atoms::already_exited()).encode(env));
    };

    // Release child lock before syscall (keep cached lock to prevent race)
    drop(child_lock);

    let sig = Signal::try_from(signal).map_err(|_| Error::Term(Box::new("Invalid signal")))?;

    match kill(Pid::from_raw(pid), sig) {
        Ok(()) => Ok(atoms::ok().encode(env)),
        Err(e) => Ok((atoms::error(), format!("{}", e)).encode(env)),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn wait_nif(resource: ResourceArc<ProcessResource>) -> NifResult<i32> {
    // Check cache first
    {
        let cached = resource
            .cached_exit_code
            .lock()
            .map_err(|e| Error::Term(Box::new(format!("Lock failed: {}", e))))?;
        if let Some(code) = *cached {
            return Ok(code);
        }
    }

    let mut child_lock = resource
        .child
        .lock()
        .map_err(|e| Error::Term(Box::new(format!("Lock failed: {}", e))))?;

    if let Some(child) = child_lock.as_mut() {
        match child.wait() {
            Ok(status) => {
                let code = exit_status_to_code(status);
                // Cache the exit code
                let mut cached = resource
                    .cached_exit_code
                    .lock()
                    .map_err(|e| Error::Term(Box::new(format!("Lock failed: {}", e))))?;
                *cached = Some(code);
                Ok(code)
            }
            Err(e) => Err(Error::Term(Box::new(format!("Failed to wait: {}", e)))),
        }
    } else {
        // Check cache again - process may have been reaped by alive_nif
        let cached = resource
            .cached_exit_code
            .lock()
            .map_err(|e| Error::Term(Box::new(format!("Lock failed: {}", e))))?;
        if let Some(code) = *cached {
            return Ok(code);
        }
        Err(Error::Term(Box::new("Process already reaped")))
    }
}

#[rustler::nif]
fn alive_nif(resource: ResourceArc<ProcessResource>) -> NifResult<bool> {
    // Check cache first
    {
        let cached = resource
            .cached_exit_code
            .lock()
            .map_err(|e| Error::Term(Box::new(format!("Lock failed: {}", e))))?;
        if cached.is_some() {
            return Ok(false);
        }
    }

    let mut child_lock = resource
        .child
        .lock()
        .map_err(|e| Error::Term(Box::new(format!("Lock failed: {}", e))))?;

    if let Some(child) = child_lock.as_mut() {
        match child.try_wait() {
            Ok(Some(status)) => {
                let code = exit_status_to_code(status);
                let mut cached = resource
                    .cached_exit_code
                    .lock()
                    .map_err(|e| Error::Term(Box::new(format!("Lock failed: {}", e))))?;
                *cached = Some(code);
                Ok(false)
            }
            Ok(None) => Ok(true),
            Err(_) => Ok(false),
        }
    } else {
        Ok(false)
    }
}

#[rustler::nif]
fn write_stdin_nif<'a>(
    env: Env<'a>,
    resource: ResourceArc<ProcessResource>,
    data: Binary<'a>,
) -> NifResult<Term<'a>> {
    let mut stdin_lock = resource
        .stdin_pipe
        .lock()
        .map_err(|e| Error::Term(Box::new(format!("Lock failed: {}", e))))?;

    if let Some(stdin) = stdin_lock.as_mut() {
        match stdin.write(data.as_slice()) {
            Ok(n) if n == data.len() => Ok(atoms::ok().encode(env)),
            Ok(n) => Ok((atoms::partial(), n as i64).encode(env)),
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                Ok(atoms::would_block().encode(env))
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::BrokenPipe => {
                Ok((atoms::error(), atoms::broken_pipe()).encode(env))
            }
            Err(e) => Ok((atoms::error(), format!("{}", e)).encode(env)),
        }
    } else {
        Ok((atoms::error(), atoms::not_piped()).encode(env))
    }
}

#[rustler::nif]
fn close_stdin_nif<'a>(
    env: Env<'a>,
    resource: ResourceArc<ProcessResource>,
) -> NifResult<Term<'a>> {
    let mut stdin_lock = resource
        .stdin_pipe
        .lock()
        .map_err(|e| Error::Term(Box::new(format!("Lock failed: {}", e))))?;

    if stdin_lock.is_some() {
        *stdin_lock = None;
        Ok(atoms::ok().encode(env))
    } else {
        Ok((atoms::error(), atoms::not_piped()).encode(env))
    }
}

#[rustler::nif]
fn close_stdout_nif<'a>(
    env: Env<'a>,
    resource: ResourceArc<ProcessResource>,
) -> NifResult<Term<'a>> {
    let mut stdout_lock = resource
        .stdout_pipe
        .lock()
        .map_err(|e| Error::Term(Box::new(format!("Lock failed: {}", e))))?;

    if stdout_lock.is_some() {
        *stdout_lock = None;
        Ok(atoms::ok().encode(env))
    } else {
        Ok((atoms::error(), atoms::not_piped()).encode(env))
    }
}

#[rustler::nif]
fn close_stderr_nif<'a>(
    env: Env<'a>,
    resource: ResourceArc<ProcessResource>,
) -> NifResult<Term<'a>> {
    let mut stderr_lock = resource
        .stderr_pipe
        .lock()
        .map_err(|e| Error::Term(Box::new(format!("Lock failed: {}", e))))?;

    if stderr_lock.is_some() {
        *stderr_lock = None;
        Ok(atoms::ok().encode(env))
    } else {
        Ok((atoms::error(), atoms::not_piped()).encode(env))
    }
}

#[rustler::nif]
fn read_stdout_nif<'a>(
    env: Env<'a>,
    resource: ResourceArc<ProcessResource>,
) -> NifResult<Term<'a>> {
    let mut stdout_lock = resource
        .stdout_pipe
        .lock()
        .map_err(|e| Error::Term(Box::new(format!("Lock failed: {}", e))))?;

    if let Some(stdout) = stdout_lock.as_mut() {
        let mut buf = [0u8; 4096];
        match stdout.read(&mut buf) {
            Ok(0) => Ok(atoms::eof().encode(env)),
            Ok(n) => {
                let mut binary = OwnedBinary::new(n)
                    .ok_or_else(|| Error::Term(Box::new("Failed to allocate binary")))?;
                binary.as_mut_slice().copy_from_slice(&buf[..n]);
                Ok((atoms::ok(), binary.release(env)).encode(env))
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                Ok(atoms::would_block().encode(env))
            }
            Err(e) => Ok((atoms::error(), format!("{}", e)).encode(env)),
        }
    } else {
        Ok((atoms::error(), atoms::not_piped()).encode(env))
    }
}

#[rustler::nif]
fn read_stderr_nif<'a>(
    env: Env<'a>,
    resource: ResourceArc<ProcessResource>,
) -> NifResult<Term<'a>> {
    let mut stderr_lock = resource
        .stderr_pipe
        .lock()
        .map_err(|e| Error::Term(Box::new(format!("Lock failed: {}", e))))?;

    if let Some(stderr) = stderr_lock.as_mut() {
        let mut buf = [0u8; 4096];
        match stderr.read(&mut buf) {
            Ok(0) => Ok(atoms::eof().encode(env)),
            Ok(n) => {
                let mut binary = OwnedBinary::new(n)
                    .ok_or_else(|| Error::Term(Box::new("Failed to allocate binary")))?;
                binary.as_mut_slice().copy_from_slice(&buf[..n]);
                Ok((atoms::ok(), binary.release(env)).encode(env))
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                Ok(atoms::would_block().encode(env))
            }
            Err(e) => Ok((atoms::error(), format!("{}", e)).encode(env)),
        }
    } else {
        Ok((atoms::error(), atoms::not_piped()).encode(env))
    }
}

rustler::init!("Elixir.P", load = load);
