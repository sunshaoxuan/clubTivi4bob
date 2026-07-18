# Hotel TV for Windows

Hotel TV is a Windows focused IPTV player built from the open source [clubTivi](https://github.com/clubanderson/clubTivi) project. This fork turns a Windows 11 computer connected to a television into a remote friendly live TV appliance with a Chinese interface, automatic stream selection, silent failover, programme guide support, and native borderless fullscreen output.

The application is built with Flutter and uses `media_kit`, libmpv, FFmpeg, Riverpod, Drift, and SQLite.

<p align="center">
  <img src="docs/images/clubtivi-screenshot.png" alt="Hotel TV channel guide and player" width="900">
</p>

## Highlights

### One channel, multiple hidden routes

Equivalent channel entries from different M3U providers are normalized and shown as one channel. Quality labels, common route labels, full width characters, and Chinese CCTV aliases are handled by a CJK safe name normalizer.

The route list remains hidden from the normal channel browser. Users select a channel, while the player manages its available streams in the background.

### Fast route selection

Before playback, the player can test up to eight equivalent HTTP or HTTPS streams in parallel. Selection uses:

* Time to first byte
* Short transfer throughput
* Persisted stream health history
* Previous buffering and stall observations

The probe has a bounded timeout. If probing cannot produce a usable result, playback falls back to the original route.

### Silent automatic failover

The player monitors the libmpv demuxer cache during playback. When the active route remains unhealthy, it prepares another route and switches automatically. Manual buffering confirmation dialogs have been removed. A short Chinese notification is shown after a successful switch.

### Chinese programme guide

The fork includes bootstrap configuration for Chinese XMLTV sources and supports:

* CCTV and CCTV Plus schedules
* Chinese satellite and regional channels
* Fixed sports channels available in the configured XMLTV data
* CJK channel name matching
* `tvg-id`, explicit mapping, normalized name, and call sign matching
* Per channel EPG time shift

Generic event slots such as numbered temporary sports feeds need a reliable external mapping before they can receive accurate event names.

### Windows television mode

The Windows runner uses a native Win32 borderless display mode that covers the current monitor. The title bar, resizable frame, and work area margins are removed at the native window layer.

Additional Windows behavior includes:

* Double click a channel to open the player
* Double click video or press `F11` to toggle the player fullscreen state
* Accidental window close prevention
* Scheduled task friendly startup
* Crash dump support when configured during deployment
* Chinese application title without encoding corruption

### Stability and memory controls

This fork includes several changes for long running playback:

* Bounded media buffers for the main and warm players
* Serialized player and warm player lifecycle operations
* Generation guards for rapid channel changes
* Serialized channel database reloads
* Cached channel normalization and route indexes
* Bounded parallel network probes
* Persisted health scores with time decay

## Included source bootstrap

The application can bootstrap several public M3U playlists and Chinese XMLTV endpoints on first launch. These endpoints are stored in the source code so they can be reviewed, changed, disabled, or removed.

Public stream availability changes frequently and may depend on network location, IPv4 or IPv6 access, provider policy, and regional restrictions. The player does not operate or control any external playlist, stream, or EPG service.

## Main technologies

| Area | Technology |
| --- | --- |
| User interface | Flutter and Dart |
| State management | Riverpod |
| Playback | media_kit, libmpv, and FFmpeg |
| Database | Drift and SQLite |
| Playlist parsing | M3U, M3U Plus, and Xtream Codes |
| Programme guide | XMLTV |
| Windows integration | Win32 Runner and window_manager |

## Requirements

For the Windows build:

* Windows 11
* Flutter SDK with Windows desktop support
* Visual Studio 2022 with the Desktop development with C++ workload
* Git

This fork has been built and tested with Flutter 3.44.6.

## Build on Windows

```powershell
git clone https://github.com/sunshaoxuan/clubTivi4bob.git
cd clubTivi4bob
flutter pub get
flutter test
flutter build windows --release
```

The release directory is:

```text
build\windows\x64\runner\Release
```

Copy the complete `Release` directory when installing the application. The executable requires the DLLs and data files generated beside it.

## Run during development

```powershell
flutter run -d windows
```

Other Flutter targets remain in the repository, although this fork is maintained primarily for the Windows 11 television host.

## Basic controls

| Input | Action |
| --- | --- |
| Single click a channel | Select and preview |
| Double click a channel | Open the full player |
| Double click video | Toggle player fullscreen state |
| `F11` or `F` | Toggle player fullscreen state |
| `Escape` | Close an overlay or leave the player |
| Arrow keys | Navigate channels or adjust volume according to the active view |
| Channel Up or Channel Down | Change channel in the player |
| `D` | Open channel diagnostics from the channel view |

## Project layout

```text
lib/
  app/                       Application shell, routing, and theme
  data/datasources/         Drift database, M3U, and XMLTV parsing
  data/services/            EPG refresh, name normalization, and health data
  features/channels/        Channel browser, search, guide, and aggregation
  features/player/          Playback, probing, buffering, and failover
  features/providers/       Provider bootstrap and management
  features/settings/        Application and EPG settings
windows/runner/             Native Windows title and borderless TV window
test/                       Parser, mapping, bootstrap, and widget tests
```

## Validation

Run the automated test suite with:

```powershell
flutter test
```

Run static analysis with:

```powershell
flutter analyze
```

Windows release builds should also be tested on the target display because GPU drivers, codecs, monitor topology, and stream reachability vary by host.

## Privacy and updates

This fork does not perform the original application update check and does not display upstream release notifications. Playlist and EPG refreshes remain available because they are part of live TV data maintenance.

Stream health metrics and application configuration are stored locally by the application. Review the configured provider URLs before distributing a customized build.

## Legal notice

Hotel TV is a media player. It does not host, retransmit, sell, or guarantee access to television content. Repository maintainers do not control third party playlists, streams, logos, metadata, or programme guides.

Users and deployers are responsible for verifying that they have permission to access and display every configured source and for complying with applicable copyright, contract, network, and broadcasting rules.

## Upstream and license

This project is derived from [clubTivi](https://github.com/clubanderson/clubTivi). Upstream authors and contributors retain credit for their work.

The repository is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for the complete license text.

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the upstream contribution guidelines.
