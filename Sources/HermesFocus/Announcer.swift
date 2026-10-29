import AppKit
import AVFoundation

/// Soft chime + spoken "Break time".
final class Announcer {
    private let speech = AVSpeechSynthesizer()

    func breakTime() {
        if let chime = NSSound(named: "Glass") {
            chime.volume = 0.4
            chime.play()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [speech] in
            let u = AVSpeechUtterance(string: "Break time")
            u.volume = 0.8
            u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
            speech.speak(u)
        }
    }
}
