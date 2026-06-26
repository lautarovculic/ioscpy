//! ioscpy: mirror and control a jailbroken iPhone from macOS over USB.
//!
//! With no arguments it picks the single attached device, sets up the USB link,
//! handshakes with the daemon, and opens the session. Flags only pick a device
//! or turn on diagnostics.

mod cli;
mod clipboard;
mod codec;
mod config;
mod device;
mod h264;
mod health;
mod input;
mod installer;
mod keyboard;
mod logging;
mod mouse;
mod protocol;
mod update;
mod usbmux;
mod video;
mod window;

use std::net::TcpStream;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};

use crate::cli::Cli;

const HOST_VERSION: &str = env!("CARGO_PKG_VERSION");

fn main() {
    let cli = Cli::parse_args();
    logging::set_debug(cli.debug);

    if let Err(e) = run(&cli) {
        eprintln!("ioscpy: error: {e:#}");
        std::process::exit(1);
    }
}

fn run(cli: &Cli) -> Result<()> {
    if cli.list {
        return cmd_list();
    }
    cmd_connect(cli)
}

/// Print attached devices, one per line.
fn cmd_list() -> Result<()> {
    let devices = device::list_devices()?;
    if devices.is_empty() {
        println!("No devices attached.");
        return Ok(());
    }
    for d in &devices {
        println!("{}", d.summary());
    }
    Ok(())
}

/// Default flow: open the device window and keep it live. All the networking runs
/// on a background thread since the window has to own the main thread.
fn cmd_connect(cli: &Cli) -> Result<()> {
    // Show a one line notice if a newer release is out, then kick off the
    // background refresh for next time. Opt out with IOSCPY_NO_UPDATE_CHECK.
    if std::env::var_os("IOSCPY_NO_UPDATE_CHECK").is_none() {
        if let Some(notice) = update::pending_notice(HOST_VERSION) {
            println!("{notice}");
        }
        update::refresh_in_background();
    }

    let banner = format!("ioscpy v{HOST_VERSION} - lautarovculic.com");
    println!("{banner}");

    let port = cli.port.unwrap_or(protocol::DEFAULT_PORT);

    if cli.debug {
        print_debug_header(cli);
    }

    let stop = Arc::new(AtomicBool::new(false));
    {
        let stop = stop.clone();
        let _ = ctrlc::set_handler(move || stop.store(true, Ordering::Relaxed));
    }

    // Handshake-only diagnostic path, no window.
    if cli.handshake_only {
        return run_connection_loop(cli, port, &stop, None, None, None);
    }

    // Grab one frame for testing the stream path.
    if let Some(path) = cli.snapshot.clone() {
        return cmd_snapshot(cli, port, &path);
    }

    // Throughput measurement.
    if let Some(secs) = cli.bench {
        return cmd_bench(cli, port, secs);
    }

    // System-action test.
    if let Some(code) = cli.action {
        return cmd_action(cli, port, code);
    }

    // Run the real session loop headless for a while.
    if let Some(secs) = cli.soak {
        let stop = Arc::new(AtomicBool::new(false));
        {
            let stop = stop.clone();
            thread::spawn(move || {
                thread::sleep(Duration::from_secs(secs));
                stop.store(true, Ordering::Relaxed);
            });
        }
        println!("soak: running the streaming session for {secs}s, watching for reconnects…");
        let slot = window::new_frame_slot();
        return run_connection_loop(cli, port, &stop, Some(slot), None, None);
    }

    // Set the Dock icon on the main thread before the window opens, otherwise the
    // default executable icon flashes for a moment.
    window::set_app_icon();

    let slot = window::new_frame_slot();
    let (input_tx, input_rx) = mpsc::channel::<input::InputFrame>();
    // iPhone to Mac clipboard text goes from the net thread to the window thread,
    // which owns the pasteboard (and the main thread).
    let (clip_in_tx, clip_in_rx) = mpsc::channel::<String>();
    let net_slot = slot.clone();
    let net_stop = stop.clone();
    let net_cli = cli.clone();
    let net = thread::spawn(move || {
        if let Err(e) = run_connection_loop(
            &net_cli,
            port,
            &net_stop,
            Some(net_slot),
            Some(input_rx),
            Some(clip_in_tx),
        ) {
            eprintln!("ioscpy: error: {e:#}");
        }
        net_stop.store(true, Ordering::Relaxed);
    });

    let result = window::run_window(&banner, slot, stop.clone(), input_tx, clip_in_rx);
    stop.store(true, Ordering::Relaxed);
    let _ = net.join();
    result
}

/// Connect, handshake, run the session, and reconnect on drops until `stop` is set.
/// With a frame sink the session streams video; without one it just holds the
/// control channel. The `--handshake-only` path returns right after the handshake.
fn run_connection_loop(
    cli: &Cli,
    port: u16,
    stop: &Arc<AtomicBool>,
    frame_sink: Option<window::FrameSlot>,
    input_rx: Option<mpsc::Receiver<input::InputFrame>>,
    clip_in: Option<mpsc::Sender<String>>,
) -> Result<()> {
    let mut first = true;
    while !stop.load(Ordering::Relaxed) {
        // The forward has to outlive the session, so keep it in scope here.
        let mut forward: Option<usbmux::UsbForward> = None;

        let mut stream = match establish(cli, port, &mut forward) {
            Ok(s) => s,
            Err(e) => {
                if cli.addr.is_some() {
                    return Err(e);
                }
                warn!("{e:#}");
                if !reconnect_wait(stop) {
                    break;
                }
                continue;
            }
        };

        stream.set_nodelay(true).ok();
        // Time-bound the handshake so a daemon that accepts but never answers
        // errors out instead of hanging. The session loop drops the read timeout after.
        stream.set_read_timeout(Some(Duration::from_secs(8))).ok();
        stream.set_write_timeout(Some(Duration::from_secs(8))).ok();

        let ack = match protocol::handshake(&mut stream, HOST_VERSION) {
            Ok(ack) => ack,
            Err(e) => {
                if cli.addr.is_some() {
                    return Err(anyhow::Error::new(e).context("handshake with ioscpyd failed"));
                }
                warn!("handshake failed: {e}");
                if !reconnect_wait(stop) {
                    break;
                }
                continue;
            }
        };

        check_versions(&ack)?;
        if first {
            if let Some(notice) = update::phone_behind_notice(&ack.daemon_version, HOST_VERSION) {
                println!("{notice}");
            }
        }
        if first || cli.debug {
            health::print_capabilities(&ack);
        }
        if frame_sink.is_some() && ack.capabilities.stream_backends.is_empty() {
            warn!("the phone side isn't fully up yet, so the screen might not show. Respring the phone (or reinstall ioscpy from Sileo) and reconnect.");
        }
        first = false;

        if cli.handshake_only {
            return Ok(());
        }

        if frame_sink.is_some() {
            info!("session live. Close the window or press Ctrl-C to quit");
        } else {
            info!("session live. Press Ctrl-C to quit");
        }

        let codec_choice = choose_stream_codec(cli, &ack.capabilities);
        debug!(
            "requesting {} stream ({:?})",
            codec::codec_name(codec_choice.codec),
            codec_choice.reason
        );

        // Only hide the device keyboard if asked and the tweak can do it.
        let suppress_keyboard = cli.no_keyboard && ack.capabilities.keyboard;

        match health::run_session(
            stream,
            stop.clone(),
            frame_sink.clone(),
            input_rx.as_ref(),
            clip_in.as_ref(),
            codec_choice,
            suppress_keyboard,
        )? {
            health::SessionEnd::Quit => break,
            health::SessionEnd::Lost => {
                warn!("connection lost, reconnecting…");
                if !reconnect_wait(stop) {
                    break;
                }
            }
        }
    }

    Ok(())
}

/// Connect, stream, save the first frame's JPEG to `path`, then exit.
fn cmd_snapshot(cli: &Cli, port: u16, path: &str) -> Result<()> {
    let mut forward: Option<usbmux::UsbForward> = None;
    let mut stream = establish(cli, port, &mut forward)?;
    stream.set_nodelay(true).ok();
    stream.set_read_timeout(Some(Duration::from_secs(15))).ok();
    stream.set_write_timeout(Some(Duration::from_secs(8))).ok();

    let ack =
        protocol::handshake(&mut stream, HOST_VERSION).context("handshake with ioscpyd failed")?;
    health::print_capabilities(&ack);
    if ack.capabilities.stream_backends.is_empty() {
        warn!("the phone side isn't fully up yet, so the screen might not show. Respring the phone (or reinstall ioscpy from Sileo) and reconnect.");
    }

    protocol::write_frame(
        &mut stream,
        protocol::MessageType::StartStream,
        protocol::CHANNEL_CONTROL,
        0,
        &[],
    )?;

    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        if Instant::now() > deadline {
            bail!("no video frame within 15s (is the tweak streaming and the screen on?)");
        }
        let frame = protocol::read_frame(&mut stream)?;
        if frame.message_type() == Some(protocol::MessageType::VideoFrame) {
            if let Some((w, h, _, jpeg)) = protocol::parse_video_payload(&frame.payload) {
                std::fs::write(path, jpeg).with_context(|| format!("could not write {path}"))?;
                println!("saved {w}x{h} frame ({} bytes) to {path}", jpeg.len());
                let _ = protocol::write_frame(
                    &mut stream,
                    protocol::MessageType::StopStream,
                    protocol::CHANNEL_CONTROL,
                    0,
                    &[],
                );
                return Ok(());
            }
        }
    }
}

/// Stream for `secs` seconds with no window and print the numbers.
fn cmd_bench(cli: &Cli, port: u16, secs: u64) -> Result<()> {
    let mut forward: Option<usbmux::UsbForward> = None;
    let mut stream = establish(cli, port, &mut forward)?;
    stream.set_nodelay(true).ok();
    stream.set_read_timeout(Some(Duration::from_secs(5))).ok();
    stream.set_write_timeout(Some(Duration::from_secs(5))).ok();

    let ack =
        protocol::handshake(&mut stream, HOST_VERSION).context("handshake with ioscpyd failed")?;
    if ack.capabilities.stream_backends.is_empty() {
        warn!("the phone side isn't fully up yet, so the screen might not show. Respring the phone (or reinstall ioscpy from Sileo) and reconnect.");
    }
    let codec_choice = choose_stream_codec(cli, &ack.capabilities);
    println!(
        "bench: requesting {} stream",
        codec::codec_name(codec_choice.codec)
    );
    protocol::write_frame(
        &mut stream,
        protocol::MessageType::StartStream,
        protocol::CHANNEL_CONTROL,
        0,
        &codec::start_stream_payload(codec_choice),
    )?;
    // Ask for a keyframe so H.264 decodes from the first frame.
    let _ = protocol::write_frame(
        &mut stream,
        protocol::MessageType::RequestKeyframe,
        protocol::CHANNEL_CONTROL,
        0,
        &[],
    );

    let start = Instant::now();
    let window = Duration::from_secs(secs);
    let (mut frames, mut bytes, mut decoded, mut h264_frames, mut keyframes) =
        (0u64, 0u64, 0u64, 0u64, 0u64);
    let mut decode_total = Duration::ZERO;
    let mut read_total = Duration::ZERO;
    let (mut w, mut h) = (0u32, 0u32);
    let mut h264_dec: Option<h264::H264Decoder> = None;

    while start.elapsed() < window {
        let rt = Instant::now();
        let frame = protocol::read_frame(&mut stream)?;
        read_total += rt.elapsed();
        if frame.message_type() == Some(protocol::MessageType::VideoFrame) {
            if let Some((fw, fh, flags, data)) = protocol::parse_video_payload(&frame.payload) {
                frames += 1;
                bytes += data.len() as u64;
                (w, h) = (fw, fh);
                if flags & protocol::VIDEO_FLAG_H264 != 0 {
                    h264_frames += 1;
                    if flags & protocol::VIDEO_FLAG_KEYFRAME != 0 {
                        keyframes += 1;
                    }
                    // Run the real VideoToolbox decode so we exercise the whole
                    // pipeline, and time it.
                    if h264_dec.is_none() {
                        h264_dec = h264::H264Decoder::new();
                    }
                    if let Some(d) = h264_dec.as_mut() {
                        let t = Instant::now();
                        if let h264::Decoded::Frame(f) = d.decode(data) {
                            decode_total += t.elapsed();
                            decoded += 1;
                            (w, h) = (f.width as u32, f.height as u32);
                        }
                    }
                } else {
                    // MJPEG frame: decode to check it's valid and time it.
                    let t = Instant::now();
                    if video::decode_jpeg(data).is_some() {
                        decode_total += t.elapsed();
                        decoded += 1;
                    }
                }
            }
        }
    }
    let _ = protocol::write_frame(
        &mut stream,
        protocol::MessageType::StopStream,
        protocol::CHANNEL_CONTROL,
        0,
        &[],
    );

    let elapsed = start.elapsed().as_secs_f64();
    let n = frames.max(1) as f64;
    let kind = if h264_frames > 0 { "h264" } else { "mjpeg" };
    println!(
        "bench: {frames} {kind} frames in {elapsed:.1}s = {:.1} fps",
        frames as f64 / elapsed
    );
    println!(
        "  {w}x{h}, avg {:.1} KB/frame, ~{:.2} MB/s over the wire",
        bytes as f64 / n / 1024.0,
        bytes as f64 / elapsed / 1024.0 / 1024.0
    );
    if h264_frames > 0 {
        println!("  h264: {h264_frames} frames, {keyframes} keyframes");
    }
    if decoded > 0 {
        println!(
            "  read {:.1} ms/frame, host decode {:.1} ms/frame",
            read_total.as_secs_f64() * 1000.0 / n,
            decode_total.as_secs_f64() * 1000.0 / decoded as f64
        );
    }
    Ok(())
}

/// Send one system action and report whether the stream survives it.
fn cmd_action(cli: &Cli, port: u16, code: u16) -> Result<()> {
    let mut forward: Option<usbmux::UsbForward> = None;
    let mut stream = establish(cli, port, &mut forward)?;
    stream.set_nodelay(true).ok();
    stream.set_read_timeout(Some(Duration::from_secs(6))).ok();
    stream.set_write_timeout(Some(Duration::from_secs(6))).ok();

    let ack = protocol::handshake(&mut stream, HOST_VERSION).context("handshake failed")?;
    println!("input backends: {:?}", ack.capabilities.input_backends);
    protocol::write_frame(
        &mut stream,
        protocol::MessageType::StartStream,
        protocol::CHANNEL_CONTROL,
        0,
        &[],
    )?;

    // Warm up: count frames for about 2s.
    let mut before = 0u32;
    let t0 = Instant::now();
    while t0.elapsed() < Duration::from_secs(2) {
        let f = protocol::read_frame(&mut stream)?;
        if f.message_type() == Some(protocol::MessageType::VideoFrame) {
            before += 1;
        }
    }
    println!("frames in 2s before action: {before}");

    println!("sending SYSTEM_ACTION {code}");
    protocol::write_frame(
        &mut stream,
        protocol::MessageType::SystemAction,
        protocol::CHANNEL_CONTROL,
        1,
        &code.to_be_bytes(),
    )?;

    // Watch for about 6s: does the stream keep flowing or drop?
    let mut after = 0u32;
    let t1 = Instant::now();
    while t1.elapsed() < Duration::from_secs(6) {
        match protocol::read_frame(&mut stream) {
            Ok(f) => {
                if f.message_type() == Some(protocol::MessageType::VideoFrame) {
                    after += 1;
                }
            }
            Err(e) => {
                println!(
                    "!! connection DROPPED {:.1}s after action: {e}",
                    t1.elapsed().as_secs_f32()
                );
                return Ok(());
            }
        }
    }
    println!("connection survived; frames in 6s after action: {after}");
    Ok(())
}

/// Open the transport for one connection attempt. Stashes the USB forward (if any)
/// in `forward_slot` so the caller can keep it alive for the session.
fn establish(
    cli: &Cli,
    port: u16,
    forward_slot: &mut Option<usbmux::UsbForward>,
) -> Result<TcpStream> {
    if let Some(addr) = &cli.addr {
        info!("connecting directly to {addr}");
        return TcpStream::connect(addr).with_context(|| format!("could not connect to {addr}"));
    }

    let devices = device::list_devices()?;
    let dev = device::select_device(devices, cli.device.as_deref())?;
    info!(
        "device {}, {} (iOS {})",
        dev.udid, dev.product_type, dev.ios_version
    );
    let forward = usbmux::UsbForward::start(&dev.udid, port)
        .context("couldn't set up the USB link to the iPhone")?;
    debug!(
        "usbmux 127.0.0.1:{} -> device :{}",
        forward.local_port, forward.device_port
    );
    let stream = forward.connect()?;
    *forward_slot = Some(forward);
    Ok(stream)
}

/// Map CLI codec flags to the shared host-side codec policy.
fn choose_stream_codec(cli: &Cli, caps: &protocol::Capabilities) -> codec::CodecChoice {
    let preference = if cli.mjpeg {
        codec::CodecPreference::Mjpeg
    } else if cli.h264 {
        codec::CodecPreference::H264
    } else {
        codec::CodecPreference::Auto
    };
    codec::choose_stream_codec(caps, preference)
}

/// The protocol version must match. A different build version is just noted under
/// `--debug`.
fn check_versions(ack: &protocol::HelloAck) -> Result<()> {
    if ack.protocol_version != protocol::PROTOCOL_VERSION {
        bail!(
            "the Mac and the phone are running different ioscpy versions (Mac speaks v{}, phone speaks v{}). \
             Update both: run `brew upgrade ioscpy` here, and update ioscpy from your Sileo or Zebra repo on the phone.",
            protocol::PROTOCOL_VERSION,
            ack.protocol_version
        );
    }
    if ack.daemon_version != HOST_VERSION {
        debug!(
            "version note: host {HOST_VERSION}, daemon {}",
            ack.daemon_version
        );
    }
    Ok(())
}

/// Short pause between reconnect attempts, interruptible with Ctrl-C. Returns false
/// if the user asked to quit during the wait.
fn reconnect_wait(stop: &Arc<AtomicBool>) -> bool {
    for _ in 0..15 {
        if stop.load(Ordering::Relaxed) {
            return false;
        }
        thread::sleep(Duration::from_millis(100));
    }
    !stop.load(Ordering::Relaxed)
}

/// Diagnostics header for `--debug`.
fn print_debug_header(cli: &Cli) {
    eprintln!("ioscpy {HOST_VERSION}");
    eprintln!("macOS  {}", macos_version());
    eprintln!(
        "target {}",
        cli.addr
            .clone()
            .or_else(|| cli.device.clone())
            .unwrap_or_else(|| "auto (single attached device)".to_string())
    );
}

fn macos_version() -> String {
    Command::new("sw_vers")
        .arg("-productVersion")
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|| "unknown".to_string())
}
