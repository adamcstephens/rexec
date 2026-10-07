//! Linux 5.3 or newer, a mounted /proc, child subreapers, and pidfd syscalls are
//! required. The runner owns and reaps the complete command tree, including
//! descendants that leave the command's process group or session.

use std::env;
use std::io::{self, Read, Write};
use std::sync::Arc;

const TAG_PID: u8 = 0x00;
const TAG_STDOUT: u8 = 0x01;
const TAG_STDERR: u8 = 0x02;
const TAG_EXIT: u8 = 0x03;
const TAG_SIGNAL: u8 = 0x04;
const TAG_STARTUP_ERROR: u8 = 0x05;
const TAG_CLEANUP_ERROR: u8 = 0x06;

const CMD_STDIN: u8 = 0x01;
const CMD_EOF: u8 = 0x02;
const CMD_KILL: u8 = 0x03;
const CMD_KILL_GROUP: u8 = 0x04;
const CMD_KILL_TREE: u8 = 0x05;

fn send_packet(writer: &io::Stdout, tag: u8, data: &[u8]) {
    let mut writer = writer.lock();
    let length = (1 + data.len()) as u32;
    let _ = writer.write_all(&length.to_be_bytes());
    let _ = writer.write_all(&[tag]);
    let _ = writer.write_all(data);
    let _ = writer.flush();
}

fn read_packet(reader: &mut impl Read) -> io::Result<Vec<u8>> {
    let mut length = [0; 4];
    reader.read_exact(&mut length)?;
    let mut packet = vec![0; u32::from_be_bytes(length) as usize];
    reader.read_exact(&mut packet)?;
    Ok(packet)
}

fn main() {
    let writer = Arc::new(io::stdout());
    let args: Vec<String> = env::args().skip(1).collect();
    #[cfg(target_os = "linux")]
    let result = linux::run(&args, &writer);
    #[cfg(not(target_os = "linux"))]
    let result: Result<(), String> =
        Err("rexec requires Linux 5.3+, /proc, subreapers, and pidfds".into());

    if let Err(error) = result {
        send_packet(&writer, TAG_STARTUP_ERROR, error.as_bytes());
        std::process::exit(1);
    }
}

#[cfg(target_os = "linux")]
mod linux {
    use super::*;
    use std::fs;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::process::CommandExt;
    use std::process::{Child, Command, Stdio};
    use std::sync::mpsc::{self, RecvTimeoutError};
    use std::thread;
    use std::time::{Duration, Instant};

    use nix::libc;
    use nix::sys::signal::Signal;

    const CLEANUP_DEADLINE: Duration = Duration::from_secs(5);
    const INTERVAL: Duration = Duration::from_millis(10);

    fn pidfd_open(pid: i32) -> io::Result<OwnedFd> {
        let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
        if fd < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(unsafe { OwnedFd::from_raw_fd(fd as i32) })
        }
    }

    fn pidfd_signal(fd: &OwnedFd, signal: i32) -> io::Result<()> {
        let result = unsafe {
            libc::syscall(
                libc::SYS_pidfd_send_signal,
                fd.as_raw_fd(),
                signal,
                std::ptr::null::<libc::siginfo_t>(),
                0,
            )
        };
        if result < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    }

    fn exited(fd: &OwnedFd) -> io::Result<bool> {
        let mut descriptor = libc::pollfd {
            fd: fd.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        let result = unsafe { libc::poll(&mut descriptor, 1, 0) };
        if result < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(descriptor.revents & libc::POLLIN != 0)
        }
    }

    fn children(pid: i32) -> io::Result<Vec<i32>> {
        let mut children = Vec::new();
        // A fork from a nonleader thread appears only in that task's children file.
        for task in fs::read_dir(format!("/proc/{pid}/task"))? {
            let task = match task {
                Ok(task) => task,
                Err(error) if vanished(&error) => continue,
                Err(error) => return Err(error),
            };
            let pids = match fs::read_to_string(task.path().join("children")) {
                Ok(pids) => pids,
                Err(error) if vanished(&error) => continue,
                Err(error) => return Err(error),
            };
            for pid in pids.split_whitespace() {
                children.push(
                    pid.parse()
                        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?,
                );
            }
        }
        children.sort_unstable();
        children.dedup();
        Ok(children)
    }

    fn parent(pid: i32) -> io::Result<i32> {
        let stat = fs::read_to_string(format!("/proc/{pid}/stat"))?;
        stat.rsplit_once(')')
            .and_then(|(_, fields)| fields.split_whitespace().nth(1))
            .and_then(|field| field.parse().ok())
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing process parent"))
    }

    fn vanished(error: &io::Error) -> bool {
        matches!(error.raw_os_error(), Some(libc::ENOENT | libc::ESRCH))
    }

    fn owned_tree(owner: i32) -> (Vec<(i32, OwnedFd)>, Option<io::Error>) {
        let mut tree = Vec::new();
        let mut failure = None;
        match children(owner) {
            Ok(pids) => {
                for pid in pids {
                    match pidfd_open(pid) {
                        Ok(fd) => tree.push((pid, fd)),
                        Err(error) => failure = Some(error),
                    }
                }
            }
            Err(error) => failure = Some(error),
        }

        let mut index = 0;
        while index < tree.len() {
            let (pid, fd) = &tree[index];
            let descendants = (|| {
                if exited(fd)? {
                    return Ok(Vec::new());
                }
                let mut descendants = Vec::new();
                for child in children(*pid)? {
                    let candidate = (|| {
                        let child_fd = pidfd_open(child)?;
                        // Both identities must still be live after the PPid check.
                        // Otherwise /proc could have described a recycled numeric PID.
                        if parent(child)? == *pid && !exited(fd)? && !exited(&child_fd)? {
                            Ok(Some((child, child_fd)))
                        } else {
                            Ok(None)
                        }
                    })();
                    match candidate {
                        Ok(Some(child)) => descendants.push(child),
                        Ok(None) => {}
                        Err(error) if vanished(&error) => {}
                        Err(error) => failure = Some(error),
                    }
                }
                Ok::<_, io::Error>(descendants)
            })();
            match descendants {
                Ok(descendants) => tree.extend(descendants),
                Err(error) if vanished(&error) => {}
                Err(error) => failure = Some(error),
            }
            index += 1;
        }
        (tree, failure)
    }

    fn signal_tree(owner: i32, signal: i32) -> io::Result<()> {
        let (tree, mut failure) = owned_tree(owner);
        // Discover before signalling: killing a parent first can hide its live children.
        for (_, fd) in tree.iter().rev() {
            if let Err(error) = pidfd_signal(fd, signal) {
                if !vanished(&error) {
                    failure = Some(error);
                }
            }
        }
        match failure {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }

    fn kill_owned_children(owner: i32) -> io::Result<()> {
        let mut failure = None;
        // Only this thread reaps them, so every enumerated direct-child PID is pinned.
        // Killing adopted parents iteratively reaches descendants in any session.
        for pid in children(owner)? {
            if unsafe { libc::kill(pid, libc::SIGKILL) } < 0 {
                let error = io::Error::last_os_error();
                if !vanished(&error) {
                    failure = Some(error);
                }
            }
        }
        match failure {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }

    fn outcome(pid: i32) -> io::Result<Option<(u8, i32)>> {
        let mut status: libc::siginfo_t = unsafe { std::mem::zeroed() };
        let result = unsafe {
            libc::waitid(
                libc::P_PID,
                pid as u32,
                &mut status,
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        };
        if result < 0 {
            return Err(io::Error::last_os_error());
        }
        if unsafe { status.si_pid() } == 0 {
            return Ok(None);
        }
        let tag = match status.si_code {
            libc::CLD_EXITED => TAG_EXIT,
            libc::CLD_KILLED | libc::CLD_DUMPED => TAG_SIGNAL,
            _ => return Err(io::Error::other("unexpected direct-child wait outcome")),
        };
        Ok(Some((tag, unsafe { status.si_status() })))
    }

    fn reap_descendants(owner: i32, leader: i32) -> io::Result<bool> {
        for pid in children(owner)? {
            if pid != leader {
                let result = unsafe { libc::waitpid(pid, std::ptr::null_mut(), libc::WNOHANG) };
                if result < 0 {
                    return Err(io::Error::last_os_error());
                }
            }
        }
        Ok(children(owner)?.into_iter().all(|pid| pid == leader))
    }

    fn cleanup_error(writer: &io::Stdout, error: Option<&io::Error>) {
        let detail = error
            .map(ToString::to_string)
            .unwrap_or_else(|| "processes remain alive or unreaped".into());
        let message = format!(
            "cleanup incomplete after 5 seconds: {detail}; the runner is still attempting cleanup"
        );
        send_packet(writer, TAG_CLEANUP_ERROR, message.as_bytes());
    }

    fn startup_cleanup(child: &mut Child, owner: i32, writer: &io::Stdout) {
        let leader = child.id() as i32;
        let started = Instant::now();
        let mut reported = false;
        loop {
            // Our unreaped direct children cannot reuse their numeric PIDs.
            if let Ok(pids) = children(owner) {
                for pid in pids {
                    unsafe {
                        libc::kill(pid, libc::SIGKILL);
                    }
                }
            }
            unsafe {
                libc::kill(-leader, libc::SIGKILL);
            }
            if matches!(outcome(leader), Ok(Some(_)))
                && matches!(reap_descendants(owner, leader), Ok(true))
            {
                let _ = child.wait();
                return;
            }
            if !reported && started.elapsed() >= CLEANUP_DEADLINE {
                cleanup_error(writer, None);
                reported = true;
            }
            thread::sleep(INTERVAL);
        }
    }

    fn worker(
        child: &mut Child,
        owner: i32,
        writer: &io::Stdout,
        work: impl FnOnce() + Send + 'static,
    ) -> Result<thread::JoinHandle<()>, String> {
        thread::Builder::new().spawn(work).map_err(|error| {
            startup_cleanup(child, owner, writer);
            format!("failed to start native I/O worker: {error}")
        })
    }

    pub fn run(args: &[String], writer: &Arc<io::Stdout>) -> Result<(), String> {
        let command = args
            .first()
            .ok_or_else(|| "usage: rexec_native <command> [args...]".to_owned())?;
        let owner = unsafe { libc::getpid() };
        let result = unsafe { libc::prctl(libc::PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) };
        if result < 0 {
            return Err(format!(
                "Linux child-subreaper prerequisite failed: {}",
                io::Error::last_os_error()
            ));
        }
        children(owner).map_err(|error| format!("Linux /proc prerequisite failed: {error}"))?;
        let reserve = pidfd_open(owner)
            .map_err(|error| format!("Linux 5.3+ pidfd_open prerequisite failed: {error}"))?;
        pidfd_signal(&reserve, 0)
            .map_err(|error| format!("Linux pidfd_send_signal prerequisite failed: {error}"))?;

        let mut child = Command::new(command)
            .args(&args[1..])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .process_group(0)
            .spawn()
            .map_err(|error| format!("failed to spawn {command:?}: {error}"))?;
        let leader = child.id() as i32;
        // Reserve a descriptor across spawn so pidfd acquisition cannot hit EMFILE.
        drop(reserve);
        let child_fd = match pidfd_open(leader) {
            Ok(fd) => fd,
            Err(error) => {
                startup_cleanup(&mut child, owner, writer);
                return Err(format!("failed to acquire child pidfd: {error}"));
            }
        };

        let child_stdout = child.stdout.take().unwrap();
        let child_stderr = child.stderr.take().unwrap();
        let mut child_stdin = child.stdin.take().unwrap();
        let stdout_writer = Arc::clone(writer);
        let (stdout_start, stdout_ready) = mpsc::sync_channel::<()>(0);
        let stdout_thread = worker(&mut child, owner, writer, move || {
            if stdout_ready.recv().is_err() {
                return;
            }
            let mut reader = child_stdout;
            let mut buffer = [0; 65536];
            while let Ok(length) = reader.read(&mut buffer) {
                if length == 0 {
                    break;
                }
                send_packet(&stdout_writer, TAG_STDOUT, &buffer[..length]);
            }
        })?;
        let stderr_writer = Arc::clone(writer);
        let (stderr_start, stderr_ready) = mpsc::sync_channel::<()>(0);
        let stderr_thread = worker(&mut child, owner, writer, move || {
            if stderr_ready.recv().is_err() {
                return;
            }
            let mut reader = child_stderr;
            let mut buffer = [0; 65536];
            while let Ok(length) = reader.read(&mut buffer) {
                if length == 0 {
                    break;
                }
                send_packet(&stderr_writer, TAG_STDERR, &buffer[..length]);
            }
        })?;

        let (stdin_sender, stdin_receiver) = mpsc::channel::<Vec<u8>>();
        let stdin_thread = worker(&mut child, owner, writer, move || {
            while let Ok(packet) = stdin_receiver.recv() {
                if packet[0] == CMD_EOF || child_stdin.write_all(&packet[1..]).is_err() {
                    break;
                }
            }
        })?;
        let (control_sender, control_receiver) = mpsc::channel();
        worker(&mut child, owner, writer, move || {
            let mut reader = io::stdin();
            while let Ok(packet) = read_packet(&mut reader) {
                if packet.is_empty() || control_sender.send(packet).is_err() {
                    break;
                }
            }
        })?;
        send_packet(writer, TAG_PID, &(leader as u32).to_be_bytes());
        let _ = stdout_start.send(());
        let _ = stderr_start.send(());

        let mut direct_outcome = None;
        let mut cleaning = None;
        let mut failure = None;
        let mut reported = false;
        let mut control_open = true;
        loop {
            if direct_outcome.is_none() {
                match outcome(leader) {
                    Ok(Some(status)) => {
                        direct_outcome = Some(status);
                        cleaning.get_or_insert_with(Instant::now);
                    }
                    Ok(None) => {}
                    Err(error) => {
                        failure = Some(error);
                        cleaning.get_or_insert_with(Instant::now);
                    }
                }
            }

            if let Some(started) = cleaning {
                if let Err(error) = pidfd_signal(&child_fd, libc::SIGKILL) {
                    if !vanished(&error) {
                        failure = Some(error);
                    }
                }
                if let Err(error) = kill_owned_children(owner) {
                    failure = Some(error);
                }
                match reap_descendants(owner, leader) {
                    Ok(true) if direct_outcome.is_some() => break,
                    Ok(_) => {}
                    Err(error) => failure = Some(error),
                }
                if !reported && started.elapsed() >= CLEANUP_DEADLINE {
                    cleanup_error(writer, failure.as_ref());
                    reported = true;
                }
            }

            if !control_open {
                thread::sleep(INTERVAL);
                continue;
            }
            match control_receiver.recv_timeout(INTERVAL) {
                Ok(packet) => match packet[0] {
                    CMD_STDIN | CMD_EOF => {
                        let _ = stdin_sender.send(packet);
                    }
                    CMD_KILL | CMD_KILL_GROUP | CMD_KILL_TREE if packet.len() >= 5 => {
                        let signal = i32::from_be_bytes(packet[1..5].try_into().unwrap());
                        if Signal::try_from(signal).is_ok() {
                            match packet[0] {
                                CMD_KILL => {
                                    let _ = pidfd_signal(&child_fd, signal);
                                }
                                CMD_KILL_GROUP => unsafe {
                                    libc::kill(-leader, signal);
                                },
                                CMD_KILL_TREE if signal == libc::SIGKILL => {
                                    let _ = pidfd_signal(&child_fd, signal);
                                    cleaning.get_or_insert_with(Instant::now);
                                }
                                CMD_KILL_TREE => {
                                    let _ = signal_tree(owner, signal);
                                }
                                _ => unreachable!(),
                            }
                        }
                    }
                    _ => {}
                },
                Err(RecvTimeoutError::Disconnected) => {
                    control_open = false;
                    cleaning.get_or_insert_with(Instant::now);
                }
                Err(RecvTimeoutError::Timeout) => {}
            }
        }

        // Keep the group leader unreaped until group signals can no longer occur.
        let _ = child.wait();
        drop(stdin_sender);
        let _ = stdin_thread.join();
        let _ = stdout_thread.join();
        let _ = stderr_thread.join();
        let (tag, status) = direct_outcome.unwrap();
        if tag == TAG_SIGNAL {
            send_packet(writer, tag, &[status as u8]);
        } else {
            send_packet(writer, tag, &status.to_be_bytes());
        }
        Ok(())
    }
}
