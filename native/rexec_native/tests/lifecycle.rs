#![cfg(target_os = "linux")]

use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver};
use std::thread;
use std::time::{Duration, Instant};

use nix::libc;

const TIMEOUT: Duration = Duration::from_secs(3);
static NEXT_PATH: AtomicU64 = AtomicU64::new(0);

fn path() -> PathBuf {
    std::env::temp_dir().join(format!(
        "rexec-native-{}-{}",
        std::process::id(),
        NEXT_PATH.fetch_add(1, Ordering::Relaxed)
    ))
}

fn runner(args: &[&str]) -> (Child, Receiver<Vec<u8>>) {
    let binary = std::env::var_os("REXEC_NATIVE_TEST_BINARY")
        .unwrap_or_else(|| env!("CARGO_BIN_EXE_rexec_native").into());
    let mut child = Command::new(binary)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut stdout = child.stdout.take().unwrap();
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        loop {
            let mut length = [0; 4];
            if stdout.read_exact(&mut length).is_err() {
                break;
            }
            let mut packet = vec![0; u32::from_be_bytes(length) as usize];
            if stdout.read_exact(&mut packet).is_err() || sender.send(packet).is_err() {
                break;
            }
        }
    });
    (child, receiver)
}

fn send(child: &mut Child, tag: u8, data: &[u8]) {
    let input = child.stdin.as_mut().unwrap();
    input
        .write_all(&((data.len() + 1) as u32).to_be_bytes())
        .unwrap();
    input.write_all(&[tag]).unwrap();
    input.write_all(data).unwrap();
    input.flush().unwrap();
}

fn receive_until(
    receiver: &Receiver<Vec<u8>>,
    packets: &mut Vec<Vec<u8>>,
    predicate: impl Fn(&[Vec<u8>]) -> bool,
) -> bool {
    let deadline = Instant::now() + TIMEOUT;
    while !predicate(packets) {
        let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
            return false;
        };
        match receiver.recv_timeout(remaining) {
            Ok(packet) => packets.push(packet),
            Err(_) => return false,
        }
    }
    true
}

fn output(packets: &[Vec<u8>]) -> Vec<u8> {
    packets
        .iter()
        .filter(|packet| packet.first() == Some(&1))
        .flat_map(|packet| packet[1..].iter().copied())
        .collect()
}

fn terminal(packets: &[Vec<u8>]) -> bool {
    packets
        .iter()
        .any(|packet| matches!(packet.first(), Some(3 | 4 | 5 | 6)))
}

fn direct_pid(packets: &[Vec<u8>]) -> Option<i32> {
    packets.iter().find_map(|packet| {
        if packet.first() == Some(&0) && packet.len() == 5 {
            Some(u32::from_be_bytes(packet[1..5].try_into().unwrap()) as i32)
        } else {
            None
        }
    })
}

fn escaped_pid(packets: &[Vec<u8>]) -> Option<i32> {
    String::from_utf8_lossy(&output(packets))
        .lines()
        .find_map(|line| {
            line.strip_prefix("escaped:")
                .and_then(|pid| pid.parse().ok())
        })
}

fn exists(pid: i32) -> bool {
    std::path::Path::new(&format!("/proc/{pid}")).exists()
}

fn reap_runner(child: &mut Child) -> bool {
    let deadline = Instant::now() + TIMEOUT;
    while Instant::now() < deadline {
        if child.try_wait().unwrap().is_some() {
            return true;
        }
        thread::sleep(Duration::from_millis(5));
    }
    false
}

fn clean_failed_runner(child: &mut Child, packets: &[Vec<u8>], escaped: Option<i32>) {
    if child.try_wait().unwrap().is_some() {
        return;
    }
    for pid in escaped.into_iter().chain(direct_pid(packets)) {
        unsafe {
            libc::kill(pid, libc::SIGKILL);
        }
    }
    drop(child.stdin.take());
    if !reap_runner(child) {
        let _ = child.kill();
        let _ = child.wait();
    }
}

#[test]
fn control_eof_kills_child_even_when_child_stdin_is_blocked() {
    let (mut child, receiver) = runner(&["/bin/sh", "-c", "printf 'ready\\n'; exec sleep 60"]);
    let mut packets = Vec::new();
    let ready = receive_until(&receiver, &mut packets, |packets| {
        output(packets).ends_with(b"ready\n")
    });
    if ready {
        send(&mut child, 1, &vec![b'x'; 256 * 1024]);
        drop(child.stdin.take());
    }
    let finished = ready && receive_until(&receiver, &mut packets, terminal);
    let reaped = finished && reap_runner(&mut child);
    let gone = direct_pid(&packets).is_some_and(|pid| !exists(pid));
    clean_failed_runner(&mut child, &packets, None);
    assert!(ready, "child did not reach the stdin barrier: {packets:?}");
    assert!(
        finished && reaped && gone,
        "control EOF failed to clean the blocked child: {packets:?}"
    );
    assert_eq!(packets.last(), Some(&vec![4, libc::SIGKILL as u8]));
}

#[test]
fn direct_exit_reaps_escaped_descendant_before_draining_inherited_output() {
    let marker = path();
    let script = "setsid sh -c 'printf \"escaped:%s\\n\" \"$$\"; printf ready > \"$1\"; exec sleep 60' sh \"$1\" & while [ ! -s \"$1\" ]; do sleep 0.01; done; printf 'tail\\n'; exit 23";
    let (mut child, receiver) = runner(&["/bin/sh", "-c", script, "sh", marker.to_str().unwrap()]);
    let mut packets = Vec::new();
    let finished = receive_until(&receiver, &mut packets, terminal);
    let escaped = escaped_pid(&packets);
    let reaped = finished && reap_runner(&mut child);
    let gone = escaped.is_some_and(|pid| !exists(pid));
    clean_failed_runner(&mut child, &packets, escaped);
    let _ = std::fs::remove_file(marker);
    assert!(
        finished && reaped && gone,
        "escaped descendant retained output or survived cleanup: {packets:?}"
    );
    assert!(output(&packets).ends_with(b"tail\n"));
    let mut expected = vec![3];
    expected.extend_from_slice(&23i32.to_be_bytes());
    assert_eq!(packets.last(), Some(&expected));
}

#[test]
fn spawn_failure_is_a_structured_startup_error_without_a_child_pid() {
    let missing = path();
    let (mut child, receiver) = runner(&[missing.to_str().unwrap()]);
    let mut packets = Vec::new();
    let finished = receive_until(&receiver, &mut packets, terminal);
    let reaped = finished && reap_runner(&mut child);
    let failed_status = child
        .try_wait()
        .unwrap()
        .is_some_and(|status| !status.success());
    clean_failed_runner(&mut child, &packets, None);
    assert!(
        finished && reaped && failed_status,
        "spawn failure did not report and close cleanly: {packets:?}"
    );
    assert_eq!(packets.len(), 1);
    assert_eq!(packets[0][0], 5);
    assert!(std::str::from_utf8(&packets[0][1..]).is_ok());
    assert_eq!(direct_pid(&packets), None);
}

#[test]
fn kill_tree_signals_live_escaped_descendants_without_killing_the_ignoring_parent() {
    let marker = path();
    let script = r#"trap ':' USR1; setsid sh -c 'trap "echo tree-signalled; exit 41" USR1; echo "escaped:$$"; echo ready > "$1"; while :; do sleep 0.01; done' sh "$1" & while [ ! -s "$1" ]; do sleep 0.01; done; echo ready; while :; do sleep 0.01; done"#;
    let (mut child, receiver) = runner(&["/bin/sh", "-c", script, "sh", marker.to_str().unwrap()]);
    let mut packets = Vec::new();
    let ready = receive_until(&receiver, &mut packets, |packets| {
        output(packets).ends_with(b"ready\n")
    });
    if ready {
        send(&mut child, 5, &libc::SIGUSR1.to_be_bytes());
    }
    let signalled = ready
        && receive_until(&receiver, &mut packets, |packets| {
            output(packets)
                .windows(b"tree-signalled\n".len())
                .any(|window| window == b"tree-signalled\n")
        });
    let parent_survived =
        direct_pid(&packets).is_some_and(exists) && child.try_wait().unwrap().is_none();
    drop(child.stdin.take());
    let finished = receive_until(&receiver, &mut packets, terminal);
    let reaped = finished && reap_runner(&mut child);
    let escaped = escaped_pid(&packets);
    let gone = escaped.is_some_and(|pid| !exists(pid));
    clean_failed_runner(&mut child, &packets, escaped);
    let _ = std::fs::remove_file(marker);
    assert!(
        ready && signalled && parent_survived,
        "tree signal did not reach the live escaped descendant: {packets:?}"
    );
    assert!(
        finished && reaped && gone,
        "tree signal cleanup failed: {packets:?}"
    );
    assert_eq!(packets.last(), Some(&vec![4, libc::SIGKILL as u8]));
}
