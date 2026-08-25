//
//  PlaceholderAvatarProvider.swift
//  Social
//
//  Implementación temporal de AvatarProvider, aislada a propósito. NO produce
//  avatares 3D reales: dibuja el busto ilustrado de CartoonAvatarView (mismo
//  estilo exacto que SOCIAL_APP.html), con la única finalidad de que el resto
//  de la app (marcador, cabecera, miniaturas) funcione mientras se integra
//  Avaturn o MetaPerson según la documentación oficial.
//  Sustituir por AvaturnAvatarProvider/MetaPersonAvatarProvider cuando se
//  confirme la integración real — no requiere cambios en el resto de la app.
//
//  Hallazgo real de la pasada de fidelidad visual con SOCIAL_APP.html
//  ("lo quiero exactamente igual"): antes dibujaba un círculo con degradado
//  + icono de persona, sin relación con el diseño de producto real. Ahora
//  usa exactamente el mismo busto ilustrado de tres colores (piel/pelo/
//  ropa) que el boceto, elegidos de una paleta cerrada (AvatarLook) en vez
//  de un colorSeed continuo.
//

import SwiftUI

final class PlaceholderAvatarProvider: AvatarProvider {

    func generateAvatar(fromSelfie image: UIImage) async throws -> AvatarGenerationResult {
        // Simulación local: no sube nada a ningún servidor de terceros ni
        // analiza la foto de verdad. El "avatar" es un look elegido de una
        // paleta cerrada (AvatarLook), para poder probar el flujo de
        // onboarding end-to-end sin motor externo.
        let look = AvatarLook.random()
        return AvatarGenerationResult(
            avatarURL: URL(string: "placeholder://avatar/\(look.skin.dropFirst())\(look.hair.dropFirst())\(look.top.dropFirst())")!,
            config: ["type": "cartoon", "skin": look.skin, "hair": look.hair, "top": look.top]
        )
    }

    func avatarView(config: [String: String], size: CGFloat) -> AnyView {
        let skin = Color(hex: config["skin"] ?? AvatarLook.skinTones[0])
        let hair = Color(hex: config["hair"] ?? AvatarLook.hairTones[0])
        let top = Color(hex: config["top"] ?? AvatarLook.topColors[0])
        return AnyView(
            CartoonAvatarView(skin: skin, hair: hair, top: top)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .background(Circle().fill(Color(hex: "DFE6EE")))
        )
    }
}

private extension Color {
    init(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.removeAll { $0 == "#" }
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
