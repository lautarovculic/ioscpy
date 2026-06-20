fn main() {
    // Embed an Info.plist so macOS treats the binary as a real app. Without it,
    // a terminal-launched binary can't become key window and the render window
    // never gets keyboard events, Cmd shortcuts especially.
    #[cfg(target_os = "macos")]
    {
        let dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
        println!("cargo:rustc-link-arg=-Wl,-sectcreate,__TEXT,__info_plist,{dir}/Info.plist");
        println!("cargo:rerun-if-changed=Info.plist");

        // build the VideoToolbox H.264 decode shim and link its frameworks. ARC
        // handles the ObjC bits, CoreFoundation memory is freed by hand.
        cc::Build::new()
            .file("src/h264_decoder.m")
            .flag("-fobjc-arc")
            .compile("ioscpy_h264_decoder");
        println!("cargo:rerun-if-changed=src/h264_decoder.m");
        println!("cargo:rustc-link-lib=framework=VideoToolbox");
        println!("cargo:rustc-link-lib=framework=CoreMedia");
        println!("cargo:rustc-link-lib=framework=CoreVideo");
        println!("cargo:rustc-link-lib=framework=CoreFoundation");
    }
}
