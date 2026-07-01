class Ioscpy < Formula
  desc "Mirror and control a jailbroken iPhone from macOS over USB"
  homepage "https://lautarovculic.com"
  url "https://github.com/lautarovculic/ioscpy/archive/refs/tags/v0.1.5.tar.gz"
  # TODO(v0.1.5): set to the sha256 of the v0.1.5 tarball, printed by
  #   curl -fsSL <url above> | shasum -a 256
  sha256 "PENDING_v0.1.5_TARBALL_SHA256"
  license "MIT"
  head "https://github.com/lautarovculic/ioscpy.git", branch: "main"

  # Builds with the Rust toolchain; the libimobiledevice tools (iproxy,
  # idevice_id, ideviceinfo) are needed at runtime for the USB transport.
  depends_on "rust" => :build
  depends_on "libimobiledevice"
  depends_on :macos

  def install
    # The host crate lives in host/; everything else in the repo is the device
    # package and docs.
    cd "host" do
      system "cargo", "install", *std_cargo_args(path: ".")
    end
  end

  test do
    assert_match "ioscpy", shell_output("#{bin}/ioscpy --version")
  end
end
