import AVFoundation

/// Native "Read to me": AVSpeechSynthesizer + voice catalog, with character
/// range callbacks so the UI can map spoken words to document words. Not
/// MainActor: AppKit delegate callbacks can arrive on a background thread, and
/// the model dispatches back itself.
final class SpeechController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    let synthesizer = AVSpeechSynthesizer()
    private var utteranceIDs: [ObjectIdentifier: String] = [:]
    private let utteranceLock = NSLock()

    var onStart: ((String) -> Void)?
    /// (utteranceID, characterRange.location, length)
    var onRange: ((String, Int, Int) -> Void)?
    var onEnd: ((String) -> Void)?
    var onCancel: ((String) -> Void)?
    var onError: ((String, String) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    struct Voice: Identifiable, Equatable {
        var id: String
        var name: String
        var language: String
    }

    func voices() -> [Voice] {
        let list = AVSpeechSynthesisVoice.speechVoices().sorted {
            if $0.language == $1.language { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return $0.language.localizedCaseInsensitiveCompare($1.language) == .orderedAscending
        }
        return list.map { Voice(id: $0.identifier, name: $0.name, language: $0.language) }
    }

    func defaultVoiceID() -> String {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        return AVSpeechSynthesisVoice.speechVoices()
            .first { $0.language == language }?.identifier ?? ""
    }

    func speak(id: String, text: String, voiceID: String, rate: Double) {
        synthesizer.stopSpeaking(at: .immediate)
        let voice: AVSpeechSynthesisVoice?
        if voiceID.isEmpty {
            voice = AVSpeechSynthesisVoice(language: "en-US") ?? AVSpeechSynthesisVoice.speechVoices().first
        } else {
            voice = AVSpeechSynthesisVoice(identifier: voiceID)
        }
        guard let voice else { onError?(id, "The selected voice is unavailable."); return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = Float(max(0.1, min(1.0, Double(AVSpeechUtteranceDefaultSpeechRate) * rate)))
        utteranceLock.withLock { utteranceIDs[ObjectIdentifier(utterance)] = id }
        synthesizer.speak(utterance)
    }

    func pause() { synthesizer.pauseSpeaking(at: .word) }
    func resume() { synthesizer.continueSpeaking() }
    func stop() { synthesizer.stopSpeaking(at: .immediate) }

    private func utteranceID(_ utterance: AVSpeechUtterance, removing: Bool = false) -> String? {
        utteranceLock.withLock {
            if removing { return utteranceIDs.removeValue(forKey: ObjectIdentifier(utterance)) }
            return utteranceIDs[ObjectIdentifier(utterance)]
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard let id = utteranceID(utterance) else { return }
        onStart?(id)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        guard let id = utteranceID(utterance) else { return }
        onRange?(id, characterRange.location, characterRange.length)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard let id = utteranceID(utterance, removing: true) else { return }
        onEnd?(id)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard let id = utteranceID(utterance, removing: true) else { return }
        onCancel?(id)
    }
}
