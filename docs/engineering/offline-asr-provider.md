# Offline ASR provider integration

Build scripts select pinned multilingual weights, optional macOS and Windows
helpers use installed system models, and the server advertises language-aware
alignment. Android uses local Whisper only. This code does not change installed
apps, released packages, or deployed subtitle services.

The shared policy accepts the decoded PCM window and its audio-track locale.
It treats a confirmed silent window as valid and discards late results after
the playback window is invalidated. A provider may signal unavailability only
after ceasing to read the window. The native Whisper worker accepts a language
code or detects it when a multilingual tiny/base model is supplied. English
models keep the existing default and reject non-English requests.
Japanese, Chinese, and Korean Whisper output uses token timestamps rather than
requiring word spaces. A language or audio-track change invalidates the old
alignment before new observations can lock a reference.

Provider and compatibility notes:

- macOS: the optional macOS 26 helper checks installed locales and takes only
  decoder PCM. It never installs an asset. The system-recognition success path
  and playback cost still need a test on accessible Apple Silicon hardware
  with an installed language.
- Windows: the in-process SAPI helper only uses a matching installed Microsoft
  recognizer and a bounded decoder PCM stream. Windows x64 was verified on
  hardware via a silent file-input test; ARM64 was cross-compiled and packaged.
- Android: no system recognizer or microphone input is enabled. Android
  documents that a provider may ignore EXTRA_AUDIO_SOURCE and open the
  microphone. Whisper reads only the bounded player PCM file.
- The client sends non-English observations only when the server advertises
  audioLanguageV1. The server uses a same-language reference from the existing
  validated subtitle edition. Sources without an English-backed cue grid
  remain unsupported by the existing cache contract. Verify real speech and
  advert/reconnect behavior across locales before rollout.

QA artifacts include Android ARM, ARM64 and x64 debug APKs with verified
multilingual model hashes, Windows x64 and ARM64 native dependency archives,
and a macOS Intel QA app with native helpers. The packaged Intel Whisper helper
emitted distinct timed fragments for English and Japanese PCM. The system
helper returned no transcript on the Intel test host. A Windows x64 silent
test produced timed Chinese words using Microsoft SAPI, returned no text for
an unavailable Japanese system model, and produced timed Chinese fragments
using the packaged multilingual Whisper fallback. These checks did not
exercise the Windows playback UI or Android hardware.

Reference APIs: [Apple SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer),
[Windows SAPI WAV input](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/ms717071%28v%3Dvs.85%29),
[Android audio injection](https://developer.android.com/reference/android/speech/RecognizerIntent#EXTRA_AUDIO_SOURCE).
