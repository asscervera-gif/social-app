//
//  ProfileQrView.swift
//  Social
//
//  Código QR de perfil real, comparado con Snapchat (Snapcode)/Instagram
//  (Nametag)/WhatsApp -- hueco real, el botón de compartir de PerfilView
//  solo enviaba texto plano ("Añádeme en SOCIAL: @usuario"). Generado con
//  CoreImage.CIFilter.qrCodeGenerator(), nativo de iOS, sin ninguna
//  dependencia nueva (equivalente de renderProfileQr() en
//  PerfilScreen.kt, que sí necesitó añadir ZXing en Android por no tener
//  generador de QR nativo). Solo generación esta ronda, sin escáner
//  todavía -- hueco futuro documentado, no fingido aquí.
//

import SwiftUI
import CoreImage.CIFilterBuiltins

struct ProfileQrView: View {
    let profileID: UUID

    var body: some View {
        VStack(spacing: 16) {
            Text("Mi código QR")
                .font(.title2.bold())
            if let image = Self.renderQr(content: "social://user/\(profileID.uuidString)") {
                image
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(maxWidth: 280)
            } else {
                Text("No se pudo generar el código QR.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
    }

    private static func renderQr(content: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }
}
