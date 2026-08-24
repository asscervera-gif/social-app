//
//  AvatarProvider.swift
//  Social
//
//  Capa de abstracción para el motor de avatares 3D. El prompt maestro exige
//  no dibujar avatares a mano: la calidad debe venir de un motor especializado
//  (Avaturn como prioridad, MetaPerson como alternativa). Esta interfaz permite
//  cambiar de motor sin tocar el resto de la app.
//
//  IMPORTANTE (transparencia técnica): no conozco con certeza la firma exacta
//  del SDK de Avaturn ni de MetaPerson a fecha de hoy — sus APIs cambian y no
//  tengo acceso a su documentación en vivo desde este entorno. NO he inventado
//  llamadas a esos SDKs. Lo que sigue es la interfaz que el resto de la app
//  usará, más una implementación de marcador (placeholder) claramente aislada.
//  Antes de activar Avaturn/MetaPerson en producción, hay que:
//    1. Crear cuenta de desarrollador en avaturn.me (o Avatar SDK de Itseez3D
//       para MetaPerson) y leer su documentación de integración iOS actual.
//    2. Implementar AvaturnAvatarProvider / MetaPersonAvatarProvider conforme
//       a esa documentación real, sin adivinar nombres de métodos.
//

import Foundation
import SwiftUI

/// Resultado de generar un avatar a partir de un selfie.
struct AvatarGenerationResult {
    /// URL remota del modelo 3D generado (glb/usdz según el motor).
    let avatarURL: URL
    /// Configuración serializable del avatar (para guardar en profiles.avatar_config).
    let config: [String: String]
}

/// Errores comunes de generación de avatar, independientes del motor concreto.
enum AvatarProviderError: Error, LocalizedError {
    case noFaceDetected
    case networkFailure
    case providerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noFaceDetected:
            return "No se detectó una cara clara en la foto. Inténtalo con más luz y mirando de frente."
        case .networkFailure:
            return "No se pudo conectar con el servicio de avatares. Revisa tu conexión."
        case .providerUnavailable(let name):
            return "\(name) no está disponible ahora mismo."
        }
    }
}

/// Contrato que debe cumplir cualquier motor de avatares 3D usado por SOCIAL.
protocol AvatarProvider {
    /// Genera un avatar 3D realista a partir de una selfie. La imagen facial
    /// original NUNCA se almacena (requisito de la Fase 3): solo se envía al
    /// motor para procesarla y se descarta tras recibir el resultado.
    func generateAvatar(fromSelfie image: UIImage) async throws -> AvatarGenerationResult

    /// Devuelve una vista SwiftUI que renderiza el avatar en el tamaño dado.
    /// Se usa en los tres contextos: marcador flotante, cabecera de perfil, miniatura.
    func avatarView(config: [String: String], size: CGFloat) -> AnyView
}

/// Motor activo, inyectado en el resto de la app. Cambiar aquí basta para
/// sustituir el proveedor sin tocar ninguna pantalla.
enum ActiveAvatarProvider {
    static let shared: AvatarProvider = PlaceholderAvatarProvider()
}
