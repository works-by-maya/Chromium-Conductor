# Chromium Conductor

Conductor is my custom Apple silicon-only build of [ungoogled-chromium-macos](https://github.com/ungoogled-software/ungoogled-chromium-macos).

The goal is straightforward: Build a lean, optimized Apple silicon web browser, and add CoreAudio routing features that are not available in Google Chrome, Chromium, or ungoogled-chromium-macos.

## Why?

Most of my listening happens via audio files, and physical media.

Every so often, I'll come across something on the web that deserves to be shot out to the stereo.

Conductor exists solely because I wanted the browser itself to have its own native, built-in audio routing, and not rely on third party software.

## Custom Changes

This build currently includes two local patches.

### mac-audio-output-device-uid-switch.patch

Adds support for selecting a specific CoreAudio output device.

This allows the browser to target a chosen audio device instead of relying entirely on the system default.

### mac-audio-output-device-tab-menu.patch

Adds a macOS-only **Send Audio To** submenu to the tab context menu.

Audio output can be assigned on a per-tab basis and switched between available output devices.

## Build Configuration

The custom build profile is defined in:

```text
flags.macos.gn
```

Current goals include:

- native ARM64 builds
- ThinLTO optimization
- stripped symbols
- full media codec support
- reduced build overhead

## Build System

Builds are managed by:

```text
conductor.sh
```

The script handles:

- source retrieval
- patch application
- build verification
- clean rebuilds
- update rebuilds
- safety checks

My goal is to make Chromium builds predictable, repeatable, and easy to recover if something goes wrong.

## Notable Files

```text
conductor.sh
```

This is the build and maintenance script.

```text
flags.macos.gn
```

Apple silicon build configuration.

```text
patches.local/
```

My local Chromium Conductor patches.

## Prerequisites

Conductor currently targets Apple silicon Macs.

If Xcode is not already installed, install it from the Mac App Store first.

After Xcode finishes installing, launch it at least once, and allow any additional components to install. Xcode may also ask you to accept Apple's license agreement.

Next, open Terminal, and install the Xcode Command Line Tools:

```bash
xcode-select --install
```

Install Homebrew:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Install GNU coreutils:

```bash
brew install coreutils
```

Verify everything is available:

```bash
xcode-select -p
brew --version
git --version
python3 --version
greadlink --version
```

You'll also need:

- free disk space
- patience

The build script handles the rest.

Please note the initial build can take several hours.

## Getting Started

Create a working directory wherever you generally keep development projects.

As an example:

```bash
mkdir -p ~/Projects/Chromium-Conductor
cd ~/Projects/Chromium-Conductor
```

Clone the repository:

```bash
git clone https://github.com/YOURNAME/Chromium-Conductor.git
cd Chromium-Conductor
```

## Building

The initial build downloads Chromium source, toolchains, build dependencies, applies patches, generates build files, and compiles the browser.

On my Apple silicon M4 Pro Mac mini with 64 GB of RAM, a clean build can take several hours. If this is your first build, plan accordingly.

Initially, you build from scratch:

```bash
./conductor.sh
```

Verify build state:

```bash
./conductor.sh --verify-only
```

Check the currently available upstream release from ungoogled-chromium-macos:

```bash
./conductor.sh --check
```

Clean generated source and build artifacts:

```bash
./conductor.sh --clean
```

Update source and rebuild:

```bash
./conductor.sh --update-build
```

## Status

Always under active development.

## Contributions

Chromium Conductor is a personal project built from a labor of love, and music.

Although I developed this solely for my own use, I am not accepting pull requests nor external contributions at this time.

However, if you'd like to experiment with the ideas here, please feel free to fork the project to build your own version.

## Privacy

Conductor inherits ungoogled-chromium's privacy posture, and adds nothing that undermines it:

- No telemetry, no usage reporting, no crash uploads.
- No Google account integration or background sign-in.
- The audio routing feature stores your per-tab choices locally and sends nothing anywhere.

If you find behavior that contradicts any of the above, please open an issue — that's a bug, not a feature.

---

## Relationship to Chromium and ungoogled-chromium

Chromium Conductor is downstream of these projects and owes them everything except the local patches in `patches.local/`:

- **[Chromium](https://www.chromium.org/)** — the open-source browser engine, licensed under BSD-3-Clause.
- **[ungoogled-chromium](https://github.com/ungoogled-software/ungoogled-chromium)** — Chromium with Google integration removed and privacy defaults tightened.
- **[ungoogled-chromium-macos](https://github.com/ungoogled-software/ungoogled-chromium-macos)** — the macOS build of the above, and the base `conductor.sh` clones and builds.

Conductor is not affiliated with nor endorsed by Google or the ungoogled-software project. Please don't report Conductor-specific issues to them, as they do not maintain this project's custom patches or build system.

---

## License

Chromium Conductor's own work — `conductor.sh`, `conductor.conf`, `flags.macos.gn`, and the patches in `patches.local/` — is licensed under the BSD-3-Clause license. See [`LICENSE`](LICENSE).

The Chromium source and the ungoogled-chromium modifications retain their existing licenses (Chromium is BSD-3-Clause; see the upstream `LICENSE` files).

---

## Acknowledgments

- The Chromium project and its contributors.
- The ungoogled-chromium maintainers, for the de-Googled base.
- The ungoogled-chromium-macos maintainers, for the Apple silicon build process `conductor.sh` stands on.