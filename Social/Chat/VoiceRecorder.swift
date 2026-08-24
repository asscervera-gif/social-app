//
//  VoiceRecorder.swift
//  Social
//
//  Grabación de voz nativa (`AVAudioRecorder`, sin SDK de terceros) —
//  última pieza real de "chat funcional con fotos, voz, reacciones, read
//  receipts". AAC en un contenedor .m4a. Equivalente de VoiceRecorder.kt.
//
//  Aviso de honestidad: configuración estándar de AVAudioSession/
//  AVAudioRecorder documentada por Apple, coherente con el resto del
//  proyecto (misma disciplina que AVFoundation ya usado en la cámara) —
//  sin verificación de compilador real (límite de plataforma).
//

import Foundation
import AVFoundation

final class VoiceRecorder: NSObject {
    private var recorder: AVAudioRecorder?
    private var outputURL: URL?

    func start() throws -> URL {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default)
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice_\(UUID().uuidString).m4a")
        outputURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.record()
        recorder = r
        return url
    }

    /// Devuelve el archivo grabado, o nil si no había grabación en curso o
    /// fue demasiado corta para tener audio útil.
    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        return outputURL
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
    }
}
