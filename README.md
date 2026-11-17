# PayNux Agent

**PayNux Agent** is an Android application that brings the Hermes Agent AI gateway to Android through a native Flutter interface and an Ubuntu environment powered by PRoot.

PayNux Agent maintains its own Android application, terminal interface, and integration layer while using [Hermes Agent](https://github.com/NousResearch/hermes-agent) as its underlying AI engine.

## Features

- **Guided setup** — Install and configure the Ubuntu environment and Hermes Agent.
- **Gateway management** — Start and stop the AI gateway and monitor its status.
- **Built-in terminal** — Access the Ubuntu environment through PayNux's integrated terminal.
- **Shared storage access** — Access Android shared storage through `/sdcard` when permission is granted.
- **Gateway logs** — Inspect gateway output and runtime activity.
- **Settings** — Manage application preferences and Android integration.
- **Configuration backup** — Export and restore Hermes configuration snapshots.

## Requirements

- Android 10 or later.
- ARM64 Android device (`arm64-v8a`).
- Internet connection for initial setup and AI provider access.
- Sufficient free storage for the Ubuntu environment and dependencies.

## Installation

1. Open [PayNux Agent Releases](https://github.com/pay/PayNux-Agent/releases).
2. Download the latest APK.
3. Install the APK on your Android device.
4. Open PayNux Agent and follow the setup instructions.

## Build from Source

### Requirements

- Flutter 3.27.4
- Dart 3.6.2
- Android SDK and build tools

### Build

```bash
git clone https://github.com/pay/PayNux-Agent.git
cd PayNux-Agent/flutter_app
flutter pub get
flutter build apk --release
```

APK output:

```text
build/app/outputs/flutter-apk/app-release.apk
```

## Architecture

- **Flutter / Dart** — PayNux Agent user interface and application logic.
- **Android / Kotlin** — Native Android integration, permissions, and background services.
- **PRoot** — Runs the Ubuntu environment without requiring Android root access.
- **Hermes Agent** — Underlying AI agent and gateway engine.

PayNux Agent owns its Android application and mobile interface independently of Hermes Agent Mobile. The Hermes engine remains an upstream component that can be updated separately.

## Privacy

See the [PayNux Agent Privacy Policy](docs/privacy-policy.html) for information about local configuration, network connections, permissions, and snapshot backups.

## Upstream Acknowledgements

PayNux Agent builds on work from:

- [Hermes Agent](https://github.com/NousResearch/hermes-agent) by Nous Research.
- [OpenClaw Termux](https://github.com/mithun50/openclaw-termux) by mithun50.

See [UPSTREAM_CHANGELOG.md](UPSTREAM_CHANGELOG.md) for inherited upstream history and [LICENSE](LICENSE) for license terms.

## License

This project is distributed under the MIT License. See [LICENSE](LICENSE).
