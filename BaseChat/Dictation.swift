import AVFoundation
import Foundation
import Observation
import Speech

/// Live speech-to-text for the composer.
///
/// `AVAudioEngine` taps the microphone, every buffer is converted to the format
/// `SpeechAnalyzer` asked for and pushed into an `AsyncStream`, and a
/// `SpeechTranscriber` module reports results back — volatile ones while the
/// phrase is still forming, final ones once it settles. Everything lands on
/// `@Observable` properties so the composer redraws without a view rebuild.
@Observable
@MainActor
final class Dictation {

    enum Phase: Equatable {
        case idle
        case preparing
        /// Fraction complete while the on-device model downloads.
        case installing(Double)
        case listening
        case failed(String)

        var isActive: Bool {
            switch self {
            case .preparing, .installing, .listening: return true
            case .idle, .failed: return false
            }
        }

    }

    private(set) var phase: Phase = .idle
    /// Phrases the transcriber has committed to.
    private(set) var finalized = ""
    /// The tail it is still revising.
    private(set) var volatile = ""

    /// Everything heard this session.
    var transcript: String {
        let tail = volatile.trimmingCharacters(in: .whitespaces)
        if finalized.isEmpty { return tail }
        return tail.isEmpty ? finalized : finalized + " " + tail
    }

    /// The new Speech stack ships with macOS 26; there is no fallback path.
    static var isSupported: Bool { SpeechTranscriber.isAvailable }

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var stream: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var installProgress: Task<Void, Never>?
    private var converter: ConverterBox?
    private var tapped = false

    // MARK: - Control

    func toggle() {
        if phase.isActive {
            Task { await stop() }
        } else {
            Task { await start() }
        }
    }

    func start() async {
        guard !phase.isActive else { return }
        finalized = ""
        volatile = ""
        phase = .preparing

        guard Self.isSupported else {
            phase = .failed("Speech recognition is not available on this Mac.")
            return
        }
        guard await Self.authorize() else {
            phase = .failed("BaseChat needs microphone and speech recognition access. Grant it in System Settings › Privacy & Security.")
            return
        }

        do {
            let locale = await Self.bestLocale()
            let module = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: []
            )
            transcriber = module

            try await install(module)
            guard phase.isActive else { return }

            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
            let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            stream = continuation

            let session = SpeechAnalyzer(modules: [module])
            analyzer = session
            try await session.prepareToAnalyze(in: format)
            try await session.start(inputSequence: input)

            results = Task { [weak self] in
                do {
                    for try await result in module.results {
                        self?.absorb(String(result.text.characters), final: result.isFinal)
                    }
                } catch {
                    self?.fail(error.localizedDescription)
                }
            }

            try startEngine(target: format)
            phase = .listening
        } catch {
            await teardown()
            phase = .failed(error.localizedDescription)
        }
    }

    /// Stops the tap, drains what is left through the analyzer, returns the text.
    @discardableResult
    func stop() async -> String {
        guard phase.isActive else { return transcript }
        stopEngine()
        stream?.finish()
        stream = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        results?.cancel()
        results = nil
        analyzer = nil
        transcriber = nil
        converter = nil
        installProgress?.cancel()
        installProgress = nil
        phase = .idle
        let text = transcript
        volatile = ""
        return text
    }

    func clear() {
        finalized = ""
        volatile = ""
        if case .failed = phase { phase = .idle }
    }

    // MARK: - Audio

    private func startEngine(target: AVAudioFormat?) throws {
        let node = engine.inputNode
        let source = node.outputFormat(forBus: 0)
        guard source.sampleRate > 0 else {
            throw Failure("No microphone input is available.")
        }
        let box = target.flatMap { ConverterBox(from: source, to: $0) }
        converter = box
        let sink = stream

        node.installTap(onBus: 0, bufferSize: 4096, format: source) { buffer, _ in
            guard let sink else { return }
            if let box {
                if let converted = box.convert(buffer) {
                    sink.yield(AnalyzerInput(buffer: converted))
                }
            } else {
                sink.yield(AnalyzerInput(buffer: buffer))
            }
        }
        tapped = true
        engine.prepare()
        try engine.start()
    }

    private func stopEngine() {
        if tapped {
            engine.inputNode.removeTap(onBus: 0)
            tapped = false
        }
        if engine.isRunning { engine.stop() }
    }

    private func teardown() async {
        stopEngine()
        stream?.finish()
        stream = nil
        results?.cancel()
        results = nil
        installProgress?.cancel()
        installProgress = nil
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        transcriber = nil
        converter = nil
    }

    // MARK: - Model assets

    private func install(_ module: SpeechTranscriber) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        phase = .installing(0)
        let progress = request.progress
        installProgress = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                let fraction = progress.fractionCompleted
                await MainActor.run {
                    guard case .installing = self?.phase else { return }
                    self?.phase = .installing(fraction)
                }
            }
        }
        defer {
            installProgress?.cancel()
            installProgress = nil
        }
        try await request.downloadAndInstall()
    }

    private static func bestLocale() async -> Locale {
        let current = Locale.current
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: current) { return match }
        let installed = await SpeechTranscriber.installedLocales
        return installed.first ?? Locale(identifier: "en-US")
    }

    private static func authorize() async -> Bool {
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        guard microphone else { return false }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return speech == .authorized
    }

    // MARK: - Results

    private func absorb(_ text: String, final: Bool) {
        guard phase.isActive else { return }
        if final {
            let piece = text.trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty {
                finalized = finalized.isEmpty ? piece : finalized + " " + piece
            }
            volatile = ""
        } else {
            volatile = text
        }
    }

    private func fail(_ message: String) {
        guard phase.isActive else { return }
        Task { await teardown() }
        phase = .failed(message)
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

/// Resamples microphone buffers into the format the analyzer asked for.
/// Lives outside the actor because the tap runs on a realtime audio thread.
private final class ConverterBox: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let ratio: Double

    init?(from source: AVAudioFormat, to target: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
        converter.primeMethod = .none
        self.converter = converter
        self.target = target
        self.ratio = target.sampleRate / source.sampleRate
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
