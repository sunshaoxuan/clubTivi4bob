import AVKit
import Flutter
import Speech
import UIKit

// One native media owner. PCM and remux stay inside the application sandbox.
final class BobTVNativeMedia: NSObject, FlutterPlugin, AVPlayerViewControllerDelegate {
  private weak var host: UIViewController?
  private var controller: BobTVSystemPlayer?
  private var sessionPlayer: AVPlayer?
  private var closingSnapshot: [String: Any]?
  private var mediaResult: FlutterResult?
  private var observation: NSKeyValueObservation?
  private var deadline: DispatchWorkItem?
  private var pipActive = false
  private var remuxes: [String: OpaquePointer] = [:]
  private let remuxQueue = DispatchQueue(label: "bobtv.native.remux")
  private let speechQueue = DispatchQueue(label: "bobtv.native.speech", qos: .utility)
  private var offlineSupport: Bool?
  private var probingSpeech = false
  private var capabilityWaiters: [FlutterResult] = []
  private var speech: SFSpeechRecognitionTask?
  private var speechRecognizer: SFSpeechRecognizer?
  private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
  private var speechResult: FlutterResult?
  private var speechDeadline: DispatchWorkItem?
  private var presentationHost: UIViewController? {
    host ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }.first(where: { $0.isKeyWindow })?.rootViewController
  }
  deinit {
    deadline?.cancel(); speechDeadline?.cancel(); speech?.cancel()
    for pointer in remuxes.values { bobtv_remux_destroy(pointer) }
  }
  private var speechID: String?
  private var activeSpeechRequest: String?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = BobTVNativeMedia()
    instance.host = registrar.viewController
    registrar.addMethodCallDelegate(instance, channel: FlutterMethodChannel(name: "bobtv/native_media", binaryMessenger: registrar.messenger()))
  }

  private func capabilities() -> [String: Any] {
    let key = "bobtv.speech.support.\(ProcessInfo.processInfo.operatingSystemVersionString).\(Locale.current.identifier)"
    if offlineSupport == nil && UserDefaults.standard.bool(forKey: key) { offlineSupport = true }
    return ["pip": AVPictureInPictureController.isPictureInPictureSupported(),
      "speechAuthorization": SFSpeechRecognizer.authorizationStatus().rawValue,
      "offlineSpeech": offlineSupport == true, "speechChecking": probingSpeech,
      "pcmFilter": bobtv_has_pcm_filter() != 0, "nativeRemux": true,
      "locale": Locale.current.identifier]
  }

  private func probeSpeechSupport(waiter: FlutterResult? = nil) {
    guard SFSpeechRecognizer.authorizationStatus() == .authorized else { waiter?(capabilities()); return }
    if offlineSupport != nil { waiter?(capabilities()); return }
    if let waiter = waiter { capabilityWaiters.append(waiter) }
    if probingSpeech { return }
    probingSpeech = true
    let locale = Locale.current
    let key = "bobtv.speech.support.\(ProcessInfo.processInfo.operatingSystemVersionString).\(locale.identifier)"
    speechQueue.async { [weak self] in
      let supported = SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.offlineSupport = supported; self.probingSpeech = false
        if supported { UserDefaults.standard.set(true, forKey: key) }
        let callbacks = self.capabilityWaiters; self.capabilityWaiters.removeAll()
        let state = self.capabilities(); callbacks.forEach { $0(state) }
      }
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "capabilities": result(capabilities()); probeSpeechSupport()
    case "authorizeSpeech":
      SFSpeechRecognizer.requestAuthorization { _ in DispatchQueue.main.async {
        self.offlineSupport = nil; self.probeSpeechSupport(waiter: result)
      } }
    case "recognize": recognize(args, result: result)
    case "cancelRecognition":
      if args["id"] as? String == speechID { endSpeech(error: "cancelled") }; result(nil)
    case "startRemux":
      guard let source = args["source"] as? String else { result(FlutterError(code: "source", message: "Missing local input", details: nil)); return }
      let id = UUID().uuidString
      remuxQueue.async {
        let pointer = bobtv_remux_start(source, id)
        if let pointer = pointer { self.remuxes[id] = pointer }
        let port = pointer.map { bobtv_remux_port($0) } ?? 0
        DispatchQueue.main.async {
          if port > 0 { result(["id": id, "url": "http://127.0.0.1:\(port)/\(id)/playback.ts"]) }
          else { result(FlutterError(code: "remux", message: "Unable to open local timestamp pipe", details: nil)) }
        }
      }
    case "remuxState", "stopRemux":
      let id = args["id"] as? String ?? ""
      remuxQueue.async {
        guard let pointer = self.remuxes[id] else { DispatchQueue.main.async { result(["running": false, "events": []]) }; return }
        if call.method == "stopRemux" {
          self.remuxes.removeValue(forKey: id); bobtv_remux_destroy(pointer)
          DispatchQueue.main.async { result(nil) }
        } else {
          let raw = bobtv_remux_events(pointer)
          let data = raw.map { Data(String(cString: $0).utf8) } ?? Data("[]".utf8)
          bobtv_remux_free_string(raw)
          let events = (try? JSONSerialization.jsonObject(with: data)) ?? []
          let running = bobtv_remux_running(pointer) != 0
          DispatchQueue.main.async { result(["running": running, "events": events]) }
        }
      }
    case "presentPlayer": presentPlayer(args, result: result)
    case "closePlayer": finishPlayer(); result(nil)
    case "playerState": result(playerState())
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func recognize(_ args: [String: Any], result: @escaping FlutterResult) {
    guard speechResult == nil else { result(FlutterError(code: "busy", message: "Recognition already active", details: nil)); return }
    guard SFSpeechRecognizer.authorizationStatus() == .authorized else { result(FlutterError(code: "permission", message: "Speech permission required", details: nil)); return }
    let locale = (args["locale"] as? String)?.replacingOccurrences(of: "_", with: "-") ?? Locale.current.identifier
    guard let path = args["path"] as? String,
      URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path + "/"),
      let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe), !data.isEmpty, data.count <= 1280000, data.count % 2 == 0,
      let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / 2)) else {
      result(FlutterError(code: "pcm", message: "Invalid sandbox PCM window", details: nil)); return
    }
    buffer.frameLength = buffer.frameCapacity
    data.withUnsafeBytes { raw in if let base = raw.baseAddress { memcpy(buffer.int16ChannelData![0], base, data.count) } }
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = false
    request.taskHint = .dictation
    speechRequest = request
    speechResult = result; speechID = args["id"] as? String
    let requestID = UUID().uuidString
    activeSpeechRequest = requestID
    let started = Date()
    speechQueue.async { [weak self] in
      let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
      let supported = recognizer?.supportsOnDeviceRecognition == true && recognizer?.isAvailable == true
      DispatchQueue.main.async {
        guard let self = self, self.activeSpeechRequest == requestID else { return }
        guard supported, let recognizer = recognizer else { self.endSpeech(error: "offline_model"); return }
        self.speechRecognizer = recognizer
        self.speech = recognizer.recognitionTask(with: request) { [weak self] response, error in
      DispatchQueue.main.async {
        guard let self = self, self.speechResult != nil, self.activeSpeechRequest == requestID else { return }
        if let response = response, response.isFinal {
          let words = response.bestTranscription.segments.map { ["word": $0.substring, "start": $0.timestamp, "end": $0.timestamp + $0.duration, "probability": $0.confidence] as [String: Any] }
          let callback = self.speechResult
          self.speechResult = nil; self.activeSpeechRequest = nil; self.speech = nil; self.speechRecognizer = nil; self.speechRequest = nil; self.speechID = nil; self.speechDeadline?.cancel()
          callback?(["words": words, "audioLanguage": locale, "processSeconds": Date().timeIntervalSince(started)])
        } else if let error = error as NSError? {
          self.endSpeech(error: "recognition_failed", details: ["domain": error.domain, "code": error.code])
        }
      }
    }
        request.append(buffer); request.endAudio()
      }
    }
    let timeout = DispatchWorkItem { [weak self] in self?.endSpeech(error: "timeout") }
    speechDeadline = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 40, execute: timeout)
  }
  private func endSpeech(error: String, details: [String: Any]? = nil) {
    let callback = speechResult; speechResult = nil; speechID = nil; activeSpeechRequest = nil
    speechDeadline?.cancel(); speech?.cancel(); speech = nil; speechRecognizer = nil; speechRequest = nil
    callback?(FlutterError(code: error, message: "On-device recognition stopped", details: details))
  }
  private func playerState() -> [String: Any] {
    guard let player = sessionPlayer else { return ["active": false] }
    let seconds = player.currentTime().seconds
    return ["active": true, "playing": player.rate > 0, "position": seconds.isFinite ? seconds : 0,
      "pipActive": pipActive, "externalPlayback": player.isExternalPlaybackActive, "muted": player.isMuted,
      "ready": player.currentItem?.status == .readyToPlay]
  }
  private func presentPlayer(_ args: [String: Any], result: @escaping FlutterResult) {
    guard controller == nil, let value = args["url"] as? String, let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
      result(FlutterError(code: "native_player", message: "Native player busy or unsupported URL", details: nil)); return
    }
    guard var presenter = presentationHost else { result(FlutterError(code: "presentation", message: "Player view unavailable", details: nil)); return }
    while let presented = presenter.presentedViewController { presenter = presented }
    do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback); try AVAudioSession.sharedInstance().setActive(true) }
    catch { result(FlutterError(code: "audio_session", message: "Unable to activate playback", details: nil)); return }
    let vc = BobTVSystemPlayer()
    vc.modalPresentationStyle = .fullScreen
    vc.delegate = self; vc.allowsPictureInPicturePlayback = true
    if #available(iOS 14.2, *) { vc.canStartPictureInPictureAutomaticallyFromInline = true }
    let player = AVPlayer(url: url); player.allowsExternalPlayback = true
    player.isMuted = args["muted"] as? Bool ?? false
    #if DEBUG
    if args["qaSilent"] as? Bool == true { player.isMuted = true; player.volume = 0 }
    #endif
    vc.player = player; sessionPlayer = player; controller = vc; mediaResult = result; closingSnapshot = nil
    vc.closed = { [weak self] in if self?.pipActive == false { self?.finishPlayer(dismiss: false) } }
    observation = player.currentItem?.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
      DispatchQueue.main.async {
        guard let self = self, self.controller === vc else { return }
        if item.status == .failed { self.finishPlayer(error: "此线路无法由 Apple 系统播放器播放") }
        if item.status == .readyToPlay {
          self.deadline?.cancel()
          if args["live"] as? Bool != true, let position = args["position"] as? Double, position > 0 {
            player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
              DispatchQueue.main.async {
                guard let self = self, self.controller === vc else { return }
                if finished { player.play() } else { self.finishPlayer(error: "此线路无法由 Apple 系统播放器播放") }
              }
            }
          } else { player.play() }
        }
      }
    }
    let timeout = DispatchWorkItem { [weak self] in self?.finishPlayer(error: "系统播放器连接超时") }
    deadline = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
    presenter.present(vc, animated: true)
  }
  private func finishPlayer(error: String? = nil, dismiss: Bool = true) {
    guard let vc = controller else { return }
    var state = dismiss ? playerState() : (closingSnapshot ?? playerState()); if let error = error { state["error"] = error }
    let callback = mediaResult; mediaResult = nil; controller = nil; pipActive = false
    observation = nil; deadline?.cancel(); vc.closed = nil; sessionPlayer?.pause(); sessionPlayer = nil; vc.player = nil; closingSnapshot = nil
    if dismiss && vc.presentingViewController != nil && !vc.isBeingDismissed {
      vc.dismiss(animated: true) { callback?(state) }
    } else {
      // AVKit is already dismissing after its own Close button. A second
      // dismiss here can detach Flutter's view and leave a black window.
      DispatchQueue.main.async { callback?(state) }
    }
  }
  func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
    pipActive = true; closingSnapshot = nil
  }
  func playerViewController(_ playerViewController: AVPlayerViewController, willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
    if !pipActive { closingSnapshot = playerState() }
    coordinator.animate(alongsideTransition: nil) { [weak self] transition in
      guard let self = self, !transition.isCancelled, !self.pipActive, self.controller === playerViewController else { return }
      self.finishPlayer(dismiss: false)
    }
  }
  func playerViewController(_ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError error: Error) {
    pipActive = false
    if playerViewController.presentingViewController == nil { finishPlayer() }
  }
  func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
    pipActive = false
    if playerViewController.presentingViewController == nil { finishPlayer() }
  }
  func playerViewController(_ playerViewController: AVPlayerViewController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    closingSnapshot = nil
    guard let host = presentationHost else { completionHandler(false); return }
    if playerViewController.presentingViewController != nil { completionHandler(true) }
    else {
      var presenter = host
      while let presented = presenter.presentedViewController { presenter = presented }
      presenter.present(playerViewController, animated: true) { completionHandler(true) }
    }
  }
}

private final class BobTVSystemPlayer: AVPlayerViewController {
  var closed: (() -> Void)?
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || presentingViewController == nil { closed?() }
  }
}
