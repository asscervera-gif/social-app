//
//  PeerToken.swift
//  Social
//
//  Modelo que se intercambia por MultipeerConnectivity antes de poder
//  arrancar una sesión NearbyInteraction. Apple exige este paso previo:
//  UWB no puede descubrir peers por sí solo, necesita un canal "de arranque"
//  (aquí Multipeer/BLE) para pasar el token de descubrimiento.
//

import Foundation
import NearbyInteraction

/// Identificador estable de un peer social, independiente de su sesión UWB.
struct SocialPeerID: Hashable, Codable {
    let id: UUID
}

/// Mensaje que viaja por MultipeerConnectivity para intercambiar el token
/// de NearbyInteraction necesario para arrancar la medición UWB.
struct DiscoveryTokenMessage: Codable {
    let peerID: SocialPeerID
    let tokenData: Data
    /// profile_id REAL de Supabase del remitente (autenticado en su sesión),
    /// no solo el peerID efímero de esta sesión de proximidad. Sin esto no
    /// hay forma de saber a qué perfil real enviar un social al tocar un
    /// marcador — antes de este cambio, ni Android ni iOS lo intercambiaban.
    ///
    /// Aviso de seguridad: el servidor sigue validando `requester_id =
    /// auth.uid()` en la tabla `socials` (RLS), así que nadie puede enviar
    /// un social en nombre de otro. El único riesgo real es que un cliente
    /// modificado mienta sobre SU PROPIO profileID, lo que dirigiría un
    /// social hacia la persona equivocada (no un fallo de account-takeover)
    /// — mismo nivel de confianza que el resto del intercambio Multipeer
    /// (el token de descubrimiento tampoco se firma).
    let profileID: String?

    init(peerID: SocialPeerID, token: NIDiscoveryToken, profileID: String?) throws {
        self.peerID = peerID
        self.tokenData = try NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: true
        )
        self.profileID = profileID
    }

    /// Reconstruye el NIDiscoveryToken recibido del peer remoto.
    func decodedToken() throws -> NIDiscoveryToken {
        guard let token = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: NIDiscoveryToken.self,
            from: tokenData
        ) else {
            throw PeerTokenError.decodeFailed
        }
        return token
    }
}

enum PeerTokenError: Error {
    case decodeFailed
}

/// Estado de proximidad publicado para un peer concreto.
/// `SocialProximity` mantiene un diccionario [SocialPeerID: PeerProximity].
struct PeerProximity: Identifiable {
    var id: SocialPeerID { peerID }

    let peerID: SocialPeerID

    /// Distancia en metros. nil si aún no hay medición UWB válida.
    var distance: Float?

    /// Ángulo horizontal en radianes respecto al eje de la cámara del dispositivo.
    /// nil si el dispositivo no soporta ángulo horizontal (algunos iPhone solo dan distancia).
    var horizontalAngle: Float?

    /// true si NearbyInteraction reporta que el peer está dentro del campo de visión de la cámara.
    var isInFrame: Bool

    /// Rumbo de brújula (grados, 0-360) del propio dispositivo en el momento de la última medición.
    /// Se usa para estabilizar el marcador cuando el usuario gira el cuerpo.
    var deviceHeading: Double?

    /// true mientras la sesión NI está activa y recibiendo actualizaciones para este peer.
    var isActive: Bool

    /// profile_id real de Supabase del peer (ver DiscoveryTokenMessage.profileID).
    /// nil hasta que llega, o si el peer no está autenticado.
    var profileID: String?
}
