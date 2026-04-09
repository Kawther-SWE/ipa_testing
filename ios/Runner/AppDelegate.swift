import AVFoundation
import Flutter
import Speech
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let iosSpeechBridge = IosSpeechBridge()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    if let controller = window?.rootViewController as? FlutterViewController {
      iosSpeechBridge.register(with: controller.binaryMessenger)
    }
    return launched
  }
}

private final class IosSpeechBridge: NSObject, FlutterStreamHandler {
  private enum ChannelName {
    static let method = "my_project/ios_speech"
    static let events = "my_project/ios_speech_events"
  }

  private let audioEngine = AVAudioEngine()
  private let audioSession = AVAudioSession.sharedInstance()

  private var methodChannel: FlutterMethodChannel?
  private var eventChannel: FlutterEventChannel?
  private var eventSink: FlutterEventSink?
  private var recognizer: SFSpeechRecognizer?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var restartTimer: Timer?

  private var isRunning = false
  private var tapInstalled = false
  private var requiresOnDeviceRecognition = true
  private var usingOnDeviceRecognition = false
  private var restartInterval: TimeInterval = 50
  private var activeLocaleIdentifier = "en-US"
  private var taskToken = 0

  private var sessionCommittedText = ""
  private var taskCommittedText = ""
  private var currentPartialText = ""

  func register(with messenger: FlutterBinaryMessenger) {
    guard methodChannel == nil, eventChannel == nil else { return }

    let methodChannel = FlutterMethodChannel(
      name: ChannelName.method,
      binaryMessenger: messenger
    )
    let eventChannel = FlutterEventChannel(
      name: ChannelName.events,
      binaryMessenger: messenger
    )

    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    eventChannel.setStreamHandler(self)

    self.methodChannel = methodChannel
    self.eventChannel = eventChannel
  }

  func onListen(arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      handleStart(call: call, result: result)
    case "stop":
      stop()
      result(true)
    case "clear":
      clearTranscript()
      result(true)
    case "isRunning":
      result(isRunning)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleStart(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any] else {
      result(
        FlutterError(
          code: "INVALID_ARGUMENTS",
          message: "Expected iOS speech start arguments.",
          details: nil
        )
      )
      return
    }

    if isRunning {
      result(true)
      return
    }

    let primaryLocale = arguments["primaryLocale"] as? String ?? "en-US"
    let alternateLocales = arguments["alternateLocales"] as? [String] ?? []
    let initialTranscript = normalize(arguments["initialTranscript"] as? String ?? "")
    requiresOnDeviceRecognition = arguments["requiresOnDevice"] as? Bool ?? true
    restartInterval = arguments["restartIntervalSeconds"] as? Double ?? 50

    sessionCommittedText = initialTranscript
    taskCommittedText = ""
    currentPartialText = ""

    requestPermissions { [weak self] granted, message in
      guard let self else { return }
      DispatchQueue.main.async {
        guard granted else {
          let failureMessage = message ?? "Speech recognition permission denied."
          self.emitError(failureMessage)
          result(
            FlutterError(
              code: "PERMISSION_DENIED",
              message: failureMessage,
              details: nil
            )
          )
          return
        }

        do {
          try self.startRecognition(
            primaryLocale: primaryLocale,
            alternateLocales: alternateLocales
          )
          result(true)
        } catch {
          self.stop(silently: true)
          self.emitError(error.localizedDescription)
          result(
            FlutterError(
              code: "START_FAILED",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      }
    }
  }

  private func requestPermissions(
    completion: @escaping (_ granted: Bool, _ message: String?) -> Void
  ) {
    let group = DispatchGroup()
    var speechGranted = false
    var microphoneGranted = false
    var failureMessage: String?

    group.enter()
    SFSpeechRecognizer.requestAuthorization { status in
      switch status {
      case .authorized:
        speechGranted = true
      case .denied:
        failureMessage = "Speech recognition permission denied."
      case .restricted:
        failureMessage = "Speech recognition is restricted on this device."
      case .notDetermined:
        failureMessage = "Speech recognition permission was not granted."
      @unknown default:
        failureMessage = "Speech recognition permission failed."
      }
      group.leave()
    }

    group.enter()
    audioSession.requestRecordPermission { granted in
      microphoneGranted = granted
      if !granted && failureMessage == nil {
        failureMessage = "Microphone permission denied."
      }
      group.leave()
    }

    group.notify(queue: .main) {
      completion(speechGranted && microphoneGranted, failureMessage)
    }
  }

  private func startRecognition(
    primaryLocale: String,
    alternateLocales: [String]
  ) throws {
    guard let recognizer = resolveRecognizer(
      primaryLocale: primaryLocale,
      alternateLocales: alternateLocales
    ) else {
      throw NSError(
        domain: "IosSpeechBridge",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "No supported speech locale was available."]
      )
    }

    self.recognizer = recognizer
    activeLocaleIdentifier = recognizer.locale.identifier
    isRunning = true

    try configureAudioSession()
    try installTapIfNeeded()

    if !audioEngine.isRunning {
      audioEngine.prepare()
      try audioEngine.start()
    }

    try startRecognitionTask()
    scheduleRestartTimer()
    emitStatus(listeningStatusMessage())
    emitTranscript()
  }

  private func resolveRecognizer(
    primaryLocale: String,
    alternateLocales: [String]
  ) -> SFSpeechRecognizer? {
    for identifier in [primaryLocale] + alternateLocales {
      let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: trimmed)) {
        return recognizer
      }
    }
    return SFSpeechRecognizer(locale: Locale.current)
  }

  private func configureAudioSession() throws {
    try audioSession.setCategory(
      .record,
      mode: .measurement,
      options: [.allowBluetooth, .duckOthers]
    )
    try audioSession.setActive(true)
  }

  private func installTapIfNeeded() throws {
    let inputNode = audioEngine.inputNode
    if tapInstalled {
      inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }

    let format = inputNode.outputFormat(forBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) {
      [weak self] buffer, _ in
      self?.recognitionRequest?.append(buffer)
    }
    tapInstalled = true
  }

  private func startRecognitionTask() throws {
    guard let recognizer else {
      throw NSError(
        domain: "IosSpeechBridge",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Speech recognizer was not configured."]
      )
    }

    invalidateRecognitionTask()

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true

    usingOnDeviceRecognition = false
    if #available(iOS 13.0, *), requiresOnDeviceRecognition,
      recognizer.supportsOnDeviceRecognition
    {
      request.requiresOnDeviceRecognition = true
      usingOnDeviceRecognition = true
    }
    if #available(iOS 16.0, *) {
      request.addsPunctuation = true
    }

    recognitionRequest = request
    taskCommittedText = ""
    currentPartialText = ""
    emitTranscript()

    taskToken += 1
    let activeToken = taskToken

    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self else { return }
      guard self.isRunning, activeToken == self.taskToken else { return }

      if let error {
        self.handleRecognitionError(error)
        return
      }

      guard let result else { return }
      self.handleRecognitionResult(result)
    }
  }

  private func handleRecognitionResult(_ result: SFSpeechRecognitionResult) {
    let fullText = normalize(result.bestTranscription.formattedString)
    guard !fullText.isEmpty else { return }

    if result.isFinal {
      let segment = incrementalText(from: fullText, after: taskCommittedText)
      taskCommittedText = fullText
      currentPartialText = ""
      if !segment.isEmpty {
        sessionCommittedText = mergeTranscript(base: sessionCommittedText, addition: segment)
      }
    } else {
      currentPartialText = incrementalText(from: fullText, after: taskCommittedText)
    }

    emitTranscript()
  }

  private func handleRecognitionError(_ error: Error) {
    stop(silently: true)
    emitError(error.localizedDescription)
  }

  private func scheduleRestartTimer() {
    restartTimer?.invalidate()
    let timer = Timer.scheduledTimer(withTimeInterval: restartInterval, repeats: true) {
      [weak self] _ in
      guard let self, self.isRunning else { return }
      do {
        try self.startRecognitionTask()
        self.emitStatus(self.listeningStatusMessage())
      } catch {
        self.handleRecognitionError(error)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    restartTimer = timer
  }

  private func stop(silently: Bool = false) {
    isRunning = false
    restartTimer?.invalidate()
    restartTimer = nil
    invalidateRecognitionTask()

    if tapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    audioEngine.stop()
    try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)

    currentPartialText = ""
    if !silently {
      emitStatus("Stopped")
      emitTranscript()
    }
  }

  private func clearTranscript() {
    sessionCommittedText = ""
    taskCommittedText = ""
    currentPartialText = ""
    emitTranscript()

    guard isRunning else { return }
    do {
      try startRecognitionTask()
      emitStatus(listeningStatusMessage())
    } catch {
      handleRecognitionError(error)
    }
  }

  private func invalidateRecognitionTask() {
    taskToken += 1
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionRequest?.endAudio()
    recognitionRequest = nil
  }

  private func listeningStatusMessage() -> String {
    let mode = usingOnDeviceRecognition ? "on-device" : "system"
    return "Listening... (\(activeLocaleIdentifier), \(mode))"
  }

  private func incrementalText(from fullText: String, after prefix: String) -> String {
    guard !prefix.isEmpty else { return normalize(fullText) }
    guard fullText.hasPrefix(prefix) else { return normalize(fullText) }
    return normalize(String(fullText.dropFirst(prefix.count)))
  }

  private func mergeTranscript(base: String, addition: String) -> String {
    let normalizedAddition = normalize(addition)
    guard !normalizedAddition.isEmpty else { return base }
    guard !base.isEmpty else { return normalizedAddition }

    let punctuation = CharacterSet(charactersIn: ",.;:!?)]}")
    if let firstScalar = normalizedAddition.unicodeScalars.first,
      punctuation.contains(firstScalar)
    {
      return base + normalizedAddition
    }
    return base + " " + normalizedAddition
  }

  private func normalize(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func emitTranscript() {
    emit(
      [
        "type": "transcript",
        "finalText": sessionCommittedText,
        "partialText": currentPartialText,
        "locale": activeLocaleIdentifier,
      ]
    )
  }

  private func emitStatus(_ value: String) {
    emit(["type": "status", "value": value])
  }

  private func emitError(_ message: String) {
    emit(["type": "error", "message": message])
  }

  private func emit(_ payload: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(payload)
    }
  }
}

