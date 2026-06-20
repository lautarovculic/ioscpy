# Homebrew formula

This is the formula that installs the ioscpy Mac app. It builds the host binary
from source with the Rust toolchain and pulls in libimobiledevice, which the USB
transport needs at runtime.

## How users install it

Once the tap is published, installing is two lines:

```bash
brew tap lautarovculic/ioscpy
brew install ioscpy
```

Updates later are just `brew upgrade ioscpy`.

## Publishing a release

The formula points at a tagged source tarball and checks its hash, so a release
is: tag the code, then update `url` and `sha256` to match.

1. Tag and push the version in the main repo:

   ```bash
   git tag v0.1.0
   git push origin v0.1.0
   ```

2. Get the hash of the tarball GitHub builds for that tag:

   ```bash
   curl -fsSL https://github.com/lautarovculic/ioscpy/archive/refs/tags/v0.1.0.tar.gz \
     | shasum -a 256
   ```

3. Put the version and that hash into `ioscpy.rb`: set `url` to the same tag and
   replace the `sha256` value.

4. Copy the formula into your tap repository. The tap is a separate GitHub repo
   named `homebrew-ioscpy`, and the file lives at `Formula/ioscpy.rb`:

   ```bash
   cp packaging/homebrew/ioscpy.rb /path/to/homebrew-ioscpy/Formula/ioscpy.rb
   ```

   Commit and push that repo. The `lautarovculic/ioscpy` in `brew tap` maps to
   `github.com/lautarovculic/homebrew-ioscpy`.

## Testing before you publish

You can install straight from the local file to check it builds:

```bash
brew install --build-from-source ./packaging/homebrew/ioscpy.rb
ioscpy --version
```

Or track the latest commit without a tagged release:

```bash
brew install --HEAD lautarovculic/ioscpy/ioscpy
```
