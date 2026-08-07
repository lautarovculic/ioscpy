//! ioscpy: mirror and control a jailbroken iPhone from macOS over USB.
//!
//! With no arguments it picks the single attached device, sets up the USB link,
//! handshakes with the daemon, and opens the session. Flags only pick a device
//! or turn on diagnostics.

mod cli;
mod clipboard;
mod config;
mod device;
mod h264;
mod health;
mod input;
mod installer;
mod keyboard;
mod logging;
mod mouse;
mod platform;
mod protocol;
mod sidebar;
mod update;
mod usbmux;
mod video;
#[cfg(all(unix, not(target_os = "macos")))]
mod wayland_compat;
mod window;

use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use serde::Serialize;

use crate::cli::{Cli, StreamProfile};
use crate::config::VideoSettings;

const HOST_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, Serialize)]
struct BenchReport {
    elapsed_seconds: f64,
    codec: String,
    width: u32,
    height: u32,
    received_frames: u64,
    decoded_frames: u64,
    unique_decoded_frames: u64,
    keyframes: u64,
    received_fps: f64,
    unique_fps: f64,
    bytes: u64,
    average_kilobytes_per_frame: f64,
    megabytes_per_second: f64,
    read_milliseconds_per_frame: f64,
    decode_milliseconds_per_frame: f64,
    stream_config: protocol::StreamConfig,
    device: Option<protocol::DeviceStreamStats>,
}

fn pair_token(cli: &Cli) -> Result<Option<String>> {
    let token = if let Some(path) = cli.pair_token_file.as_deref() {
        Some(
            std::fs::read_to_string(path)
                .with_context(|| format!("could not read LAN pairing token from {path}"))?,
        )
    } else {
        std::env::var("IOSCPY_PAIR_TOKEN").ok()
    };
    match token {
        Some(token) => {
            let token = token.trim().to_string();
            if token.len() < 16 {
                bail!("LAN pairing token must contain at least 16 characters");
            }
            Ok(Some(token))
        }
        None => Ok(None),
    }
}

fn stream_config(cli: &Cli, codec: u8) -> protocol::StreamConfig {
    use protocol::{LatencyMode, StreamConfig};

    let mut config = match cli.profile.unwrap_or(StreamProfile::Legacy) {
        StreamProfile::Legacy => StreamConfig::legacy(codec),
        StreamProfile::Quality => StreamConfig {
            codec,
            target_fps: 60,
            max_dimension: 2160,
            latency_mode: LatencyMode::Quality,
            bitrate_bps: 25_000_000,
            keyframe_interval_frames: 120,
        },
        StreamProfile::Balanced => StreamConfig {
            codec,
            target_fps: 60,
            max_dimension: 1800,
            latency_mode: LatencyMode::Balanced,
            bitrate_bps: 16_000_000,
            keyframe_interval_frames: 120,
        },
        StreamProfile::Latency => StreamConfig {
            codec,
            target_fps: 60,
            max_dimension: 1280,
            latency_mode: LatencyMode::LowLatency,
            bitrate_bps: 8_000_000,
            keyframe_interval_frames: 120,
        },
        StreamProfile::HighRefresh => StreamConfig {
            codec,
            target_fps: 90,
            max_dimension: 1600,
            latency_mode: LatencyMode::HighRefresh,
            bitrate_bps: 18_000_000,
            keyframe_interval_frames: 180,
        },
    };

    if let Some(fps) = cli.fps {
        config.target_fps = fps;
    }
    if config.target_fps >= 120 && cli.max_dimension.is_none() {
        // FPS and image quality are independent controls. Never silently reduce
        // resolution because the user selected 120 FPS; let device telemetry
        // expose the actual limit instead.
        config.max_dimension = config.max_dimension.max(2160);
        config.bitrate_bps = config.bitrate_bps.max(40_000_000);
        config.keyframe_interval_frames = 120;
        config.latency_mode = LatencyMode::Quality;
    }
    if let Some(max_dimension) = cli.max_dimension {
        config.max_dimension = max_dimension;
    }
    if let Some(mbps) = cli.bitrate_mbps {
        config.bitrate_bps = mbps.saturating_mul(1_000_000);
    }
    let keyframe_seconds = cli.keyframe_seconds.unwrap_or_else(|| {
        (u32::from(config.keyframe_interval_frames) / u32::from(config.target_fps.max(1))).max(1)
            as u16
    });
    config.keyframe_interval_frames = u32::from(config.target_fps)
        .saturating_mul(u32::from(keyframe_seconds))
        .min(u32::from(u16::MAX)) as u16;
    config
}

fn cli_has_video_overrides(cli: &Cli) -> bool {
    cli.profile.is_some()
        || cli.fps.is_some()
        || cli.max_dimension.is_some()
        || cli.bitrate_mbps.is_some()
        || cli.keyframe_seconds.is_some()
}

fn initial_video_settings(cli: &Cli) -> VideoSettings {
    if !cli_has_video_overrides(cli) {
        return VideoSettings::load();
    }
    let cfg = stream_config(cli, protocol::VIDEO_CODEC_H264);
    VideoSettings {
        target_fps: cfg.target_fps,
        max_dimension: cfg.max_dimension,
        bitrate_mbps: cfg.bitrate_bps / 1_000_000,
        keyframe_seconds: (cfg.keyframe_interval_frames / cfg.target_fps.max(1)).max(1),
        latency_mode: cfg.latency_mode,
    }
    .sanitized()
}

fn main() {
    let cli = Cli::parse_args();
    logging::set_debug(cli.debug);

    // Must run before any thread is spawned or window/clipboard is created:
    // it may unset WAYLAND_DISPLAY for this process (issue #4).
    #[cfg(all(unix, not(target_os = "macos")))]
    wayland_compat::apply_decoration_workaround(cli.wayland);

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
        return run_connection_loop(cli, port, &stop, None, None, None, None, None);
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
        return run_connection_loop(cli, port, &stop, Some(slot), None, None, None, None);
    }

    // Set the Dock icon on the main thread before the window opens, otherwise the
    // default executable icon flashes for a moment.
    window::set_app_icon();

    let slot = window::new_frame_slot();
    let (input_tx, input_rx) = mpsc::channel::<input::InputFrame>();
    let video_settings = Arc::new(Mutex::new(initial_video_settings(cli)));
    let active_codec = Arc::new(AtomicU8::new(protocol::VIDEO_CODEC_H264));
    // iPhone to Mac clipboard text goes from the net thread to the window thread,
    // which owns the pasteboard (and the main thread).
    let (clip_in_tx, clip_in_rx) = mpsc::channel::<String>();
    let net_slot = slot.clone();
    let net_stop = stop.clone();
    let net_cli = cli.clone();
    let net_settings = video_settings.clone();
    let net_codec = active_codec.clone();
    let net = thread::spawn(move || {
        if let Err(e) = run_connection_loop(
            &net_cli,
            port,
            &net_stop,
            Some(net_slot),
            Some(input_rx),
            Some(clip_in_tx),
            Some(&net_settings),
            Some(&net_codec),
        ) {
            eprintln!("ioscpy: error: {e:#}");
        }
        net_stop.store(true, Ordering::Relaxed);
    });

    let window_title = format!("ioscpy v{HOST_VERSION}");
    let result = window::run_window(
        &window_title,
        slot,
        stop.clone(),
        input_tx,
        clip_in_rx,
        video_settings,
        active_codec,
        cli.input_debug,
    );
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
    runtime_settings: Option<&Arc<Mutex<VideoSettings>>>,
    active_codec: Option<&Arc<AtomicU8>>,
) -> Result<()> {
    let pair_token = pair_token(cli)?;
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

        let ack = match protocol::handshake(&mut stream, HOST_VERSION, pair_token.as_deref()) {
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

        // Use H.264 when the device offers it and the user didn't force MJPEG.
        // The daemon also falls back to MJPEG if it can't honor the request.
        let codec = if !cli.mjpeg && ack.capabilities.stream_backends.iter().any(|b| b == "h264") {
            protocol::VIDEO_CODEC_H264
        } else {
            protocol::VIDEO_CODEC_MJPEG
        };
        if let Some(active_codec) = active_codec {
            active_codec.store(codec, Ordering::Relaxed);
        }
        let stream_config = runtime_settings
            .and_then(|settings| settings.lock().ok().map(|value| value.stream_config(codec)))
            .unwrap_or_else(|| stream_config(cli, codec));
        debug!(
            "stream config: codec={} fps={} max={} bitrate={} keyint={} mode={:?}",
            stream_config.codec,
            stream_config.target_fps,
            stream_config.max_dimension,
            stream_config.bitrate_bps,
            stream_config.keyframe_interval_frames,
            stream_config.latency_mode,
        );

        // Only hide the device keyboard if asked and the tweak can do it.
        let suppress_keyboard = cli.no_keyboard && ack.capabilities.keyboard;

        match health::run_session(
            stream,
            stop.clone(),
            frame_sink.clone(),
            input_rx.as_ref(),
            clip_in.as_ref(),
            stream_config,
            suppress_keyboard,
            cli.input_debug,
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

    let pair_token = pair_token(cli)?;
    let ack = protocol::handshake(&mut stream, HOST_VERSION, pair_token.as_deref())
        .context("handshake with ioscpyd failed")?;
    health::print_capabilities(&ack);
    if ack.capabilities.stream_backends.is_empty() {
        warn!("the phone side isn't fully up yet, so the screen might not show. Respring the phone (or reinstall ioscpy from Sileo) and reconnect.");
    }

    let snapshot_config = stream_config(cli, protocol::VIDEO_CODEC_MJPEG).encode();
    protocol::write_frame(
        &mut stream,
        protocol::MessageType::StartStream,
        protocol::CHANNEL_CONTROL,
        0,
        &snapshot_config,
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

    let pair_token = pair_token(cli)?;
    let ack = protocol::handshake(&mut stream, HOST_VERSION, pair_token.as_deref())
        .context("handshake with ioscpyd failed")?;
    if ack.capabilities.stream_backends.is_empty() {
        warn!("the phone side isn't fully up yet, so the screen might not show. Respring the phone (or reinstall ioscpy from Sileo) and reconnect.");
    }
    let codec = if !cli.mjpeg && ack.capabilities.stream_backends.iter().any(|b| b == "h264") {
        protocol::VIDEO_CODEC_H264
    } else {
        protocol::VIDEO_CODEC_MJPEG
    };
    let bench_config = stream_config(cli, codec);
    println!(
        "bench: requesting {} stream, {} fps, max {}, {:.1} Mbps, {:?}",
        if codec == protocol::VIDEO_CODEC_H264 {
            "h264"
        } else {
            "mjpeg"
        },
        bench_config.target_fps,
        bench_config.max_dimension,
        bench_config.bitrate_bps as f64 / 1_000_000.0,
        bench_config.latency_mode,
    );
    let start_payload = bench_config.encode();
    protocol::write_frame(
        &mut stream,
        protocol::MessageType::StartStream,
        protocol::CHANNEL_CONTROL,
        0,
        &start_payload,
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
    let (mut frames, mut bytes, mut decoded, mut unique_decoded, mut h264_frames, mut keyframes) =
        (0u64, 0u64, 0u64, 0u64, 0u64, 0u64);
    let mut decode_total = Duration::ZERO;
    let mut read_total = Duration::ZERO;
    let (mut w, mut h) = (0u32, 0u32);
    let mut h264_dec: Option<h264::H264Decoder> = None;
    let mut last_device_stats: Option<protocol::DeviceStreamStats> = None;
    let mut last_fingerprint: Option<u64> = None;

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
                            let fingerprint = video::frame_fingerprint(&f);
                            if last_fingerprint != Some(fingerprint) {
                                unique_decoded += 1;
                                last_fingerprint = Some(fingerprint);
                            }
                            (w, h) = (f.width as u32, f.height as u32);
                        }
                    }
                } else {
                    // MJPEG frame: decode to check it's valid and time it.
                    let t = Instant::now();
                    if let Some(f) = video::decode_jpeg(data) {
                        decode_total += t.elapsed();
                        decoded += 1;
                        let fingerprint = video::frame_fingerprint(&f);
                        if last_fingerprint != Some(fingerprint) {
                            unique_decoded += 1;
                            last_fingerprint = Some(fingerprint);
                        }
                    }
                }
            }
        } else if frame.message_type() == Some(protocol::MessageType::Stats) {
            if let Ok(stats) = serde_json::from_slice::<protocol::DeviceStreamStats>(&frame.payload)
            {
                last_device_stats = Some(stats);
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
    let report = BenchReport {
        elapsed_seconds: elapsed,
        codec: kind.to_string(),
        width: w,
        height: h,
        received_frames: frames,
        decoded_frames: decoded,
        unique_decoded_frames: unique_decoded,
        keyframes,
        received_fps: frames as f64 / elapsed.max(f64::EPSILON),
        unique_fps: unique_decoded as f64 / elapsed.max(f64::EPSILON),
        bytes,
        average_kilobytes_per_frame: bytes as f64 / n / 1024.0,
        megabytes_per_second: bytes as f64 / elapsed.max(f64::EPSILON) / 1024.0 / 1024.0,
        read_milliseconds_per_frame: read_total.as_secs_f64() * 1000.0 / n,
        decode_milliseconds_per_frame: if decoded > 0 {
            decode_total.as_secs_f64() * 1000.0 / decoded as f64
        } else {
            0.0
        },
        stream_config: bench_config,
        device: last_device_stats,
    };
    println!(
        "bench: {frames} {kind} frames in {elapsed:.1}s = {:.1} fps",
        frames as f64 / elapsed
    );
    println!(
        "  decoded {decoded}, unique {unique_decoded} = {:.1} unique fps",
        unique_decoded as f64 / elapsed.max(f64::EPSILON)
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
    if let Some(path) = cli.bench_json.as_deref() {
        let json = serde_json::to_string_pretty(&report)?;
        if path == "-" {
            println!("{json}");
        } else {
            std::fs::write(path, json)
                .with_context(|| format!("could not write benchmark JSON to {path}"))?;
            println!("  benchmark JSON: {path}");
        }
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

    let pair_token = pair_token(cli)?;
    let ack = protocol::handshake(&mut stream, HOST_VERSION, pair_token.as_deref())
        .context("handshake failed")?;
    println!("input backends: {:?}", ack.capabilities.input_backends);
    let action_config = stream_config(cli, protocol::VIDEO_CODEC_MJPEG).encode();
    protocol::write_frame(
        &mut stream,
        protocol::MessageType::StartStream,
        protocol::CHANNEL_CONTROL,
        0,
        &action_config,
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
    eprintln!("os     {}", platform::os_version());
    eprintln!(
        "target {}",
        cli.addr
            .clone()
            .or_else(|| cli.device.clone())
            .unwrap_or_else(|| "auto (single attached device)".to_string())
    );
}

#[cfg(test)]
mod stream_profile_tests {
    use super::*;
    use clap::Parser;

    fn parse(args: &[&str]) -> Cli {
        Cli::try_parse_from(args).expect("test CLI should parse")
    }

    #[test]
    fn balanced_profile_preserves_readable_resolution() {
        let cli = parse(&["ioscpy", "--profile", "balanced"]);
        let config = stream_config(&cli, protocol::VIDEO_CODEC_H264);
        assert_eq!(config.target_fps, 60);
        assert_eq!(config.max_dimension, 1800);
        assert_eq!(config.bitrate_bps, 16_000_000);
    }

    #[test]
    fn high_refresh_120_uses_new_quality_floor() {
        let cli = parse(&["ioscpy", "--profile", "high-refresh", "--fps", "120"]);
        let config = stream_config(&cli, protocol::VIDEO_CODEC_H264);
        assert_eq!(config.target_fps, 120);
        assert_eq!(config.max_dimension, 2160);
        assert_eq!(config.bitrate_bps, 40_000_000);
        assert_eq!(config.latency_mode, protocol::LatencyMode::Quality);
    }

    #[test]
    fn explicit_high_refresh_resolution_is_respected() {
        let cli = parse(&[
            "ioscpy",
            "--profile",
            "high-refresh",
            "--fps",
            "120",
            "--max-dimension",
            "1920",
            "--bitrate-mbps",
            "30",
        ]);
        let config = stream_config(&cli, protocol::VIDEO_CODEC_H264);
        assert_eq!(config.max_dimension, 1920);
        assert_eq!(config.bitrate_bps, 30_000_000);
    }
}
