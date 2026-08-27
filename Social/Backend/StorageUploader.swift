//
//  StorageUploader.swift
//  Social
//
//  Hallazgo real, segundo hueco raíz más grave de toda la sesión: no había
//  ninguna integración de Storage en ningún sitio del proyecto — Historias,
//  chat multimedia, avatar 3D y fotos en publicaciones llevaban toda la
//  sesión documentados como "bloqueados por falta de Storage", asumiendo
//  (incorrectamente, confirmado ahora en Android vía compilador real) que
//  no había red en este entorno. Bucket "media" público, carpeta por
//  usuario (ver 0015_storage.sql). Equivalente de StorageUploader.kt.
//
//  Aviso de honestidad: `client.storage.from(_:).upload(path:data:)` es la
//  API documentada de supabase-swift 2.x, coherente con la misma llamada
//  ya compiler-verificada en Android (`storage.from("media").upload(...)`)
//  — sin verificación de compilador real aquí (límite de plataforma).
//

import Foundation
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

enum StorageUploader {
    static func uploadImage(data: Data, fileExtension: String, userID: UUID) async throws -> String {
        let path = "\(userID.uuidString)/\(UUID().uuidString).\(fileExtension)"
        try await SupabaseManager.shared.client.storage.from("media").upload(path, data: data)
        return try SupabaseManager.shared.client.storage.from("media").getPublicURL(path: path).absoluteString
    }

    /// Última pieza de "chat funcional con fotos, voz, reacciones, read
    /// receipts" — nota de voz grabada con `AVAudioRecorder` (ver
    /// VoiceRecorder.swift), mismo bucket/patrón que las fotos.
    /// `uploadImage` ya era genérico (Data + extensión), reutilizado tal
    /// cual con "m4a" en vez de duplicar la lógica de subida.
    static func uploadAudio(data: Data, userID: UUID) async throws -> String {
        try await uploadImage(data: data, fileExtension: "m4a", userID: userID)
    }

    /// Reels (0050_reels.sql) -- mismo criterio que `uploadAudio`:
    /// `uploadImage` ya es genérico de verdad (Data + extensión), llamarlo
    /// así para subir un vídeo confundiría a quien lea el sitio donde se
    /// usa. Equivalente de `uploadVideo` (Kotlin).
    static func uploadVideo(data: Data, fileExtension: String, userID: UUID) async throws -> String {
        try await uploadImage(data: data, fileExtension: fileExtension, userID: userID)
    }

    /// Miniatura real de un vídeo de Reels, comparado con TikTok/
    /// Instagram Reels/YouTube Shorts -- cierra el hueco deliberado
    /// documentado en ReelsViewModel.swift.upload(): `thumbnailURL` se
    /// dejaba siempre sin fijar. Decodifica un fotograma real del propio
    /// vídeo (`AVAssetImageGenerator`, API nativa de iOS, sin dependencia
    /// nueva) en vez de fingir con un color de relleno. `AVURLAsset`
    /// necesita una URL de archivo real -- `videoData` se escribe primero
    /// a un archivo temporal (mismo criterio ya usado para notas de voz
    /// grabadas, VoiceRecorder.swift). `nil` si el vídeo no tiene ningún
    /// fotograma decodificable -- el reel se sigue publicando igual, solo
    /// sin miniatura real.
    static func uploadVideoThumbnail(videoData: Data, fileExtension: String, userID: UUID) async -> String? {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        do {
            try videoData.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let asset = AVURLAsset(url: tempURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            // Fotograma a 1s real (no en 0, que en muchos vídeos reales
            // cae en un frame negro/de transición antes de que arranque
            // el contenido de verdad) -- mismo criterio visual que
            // TikTok/Instagram al elegir portada.
            let cgImage = try generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
            #if canImport(UIKit)
            guard let jpegData = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.8) else { return nil }
            return try? await uploadImage(data: jpegData, fileExtension: "jpg", userID: userID)
            #else
            return nil
            #endif
        } catch {
            return nil
        }
    }
}
