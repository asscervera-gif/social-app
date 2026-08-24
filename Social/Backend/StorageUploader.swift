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
}
