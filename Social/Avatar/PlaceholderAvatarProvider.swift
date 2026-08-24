//
//  PlaceholderAvatarProvider.swift
//  Social
//
//  Implementación temporal de AvatarProvider, aislada a propósito. NO produce
//  avatares 3D reales: dibuja un círculo con degradado e inicial, con la única
//  finalidad de que el resto de la app (marcador, cabecera, miniaturas) funcione
//  mientras se integra Avaturn o MetaPerson según la documentación oficial.
//  Sustituir por AvaturnAvatarProvider/MetaPersonAvatarProvider cuando se
//  confirme la integración real — no requiere cambios en el resto de la app.
//

import SwiftUI

final class PlaceholderAvatarProvider: AvatarProvider {

    func generateAvatar(fromSelfie image: UIImage) async throws -> AvatarGenerationResult {
        // Simulación local: no sube nada a ningún servidor de terceros.
        // El "avatar" es solo un color derivado de la imagen, para poder
        // probar el flujo de onboarding end-to-end sin motor externo.
        let seed = String(format: "%02X%02X%02X", Int.random(in: 0...255), Int.random(in: 0...255), Int.random(in: 0...255))
        return AvatarGenerationResult(
            avatarURL: URL(string: "placeholder://avatar/\(seed)")!,
            config: ["type": "placeholder", "colorSeed": seed]
        )
    }

    func avatarView(config: [String: String], size: CGFloat) -> AnyView {
        let seed = config["colorSeed"] ?? "8B5CF6"
        let color = Color(hex: seed)
        return AnyView(
            Circle()
                .fill(
                    LinearGradient(
                        colors: [color, color.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "person.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: size * 0.45, height: size * 0.45)
                        .foregroundStyle(.white.opacity(0.85))
                )
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
