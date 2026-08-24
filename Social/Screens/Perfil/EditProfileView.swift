//
//  EditProfileView.swift
//  Social
//
//  Editar nombre/bio/color de avatar — no existía en ningún sitio (ver
//  PerfilViewModel.updateBasicInfo para el hallazgo completo). Sin
//  selector de foto real: la generación de avatar 3D sigue sin onboarding
//  construido, fingir un selector aquí sería peor que no tenerlo.
//  Equivalente de EditProfileSheet.kt.
//

import SwiftUI

private let colorSwatches = ["8B5CF6", "EF4444", "F59E0B", "10B981", "3B82F6", "EC4899"]

struct EditProfileView: View {
    @State private var name: String
    @State private var bio: String
    @State private var color: String
    let onSave: (String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    init(initialName: String, initialBio: String, initialColor: String, onSave: @escaping (String, String, String) -> Void) {
        _name = State(initialValue: initialName)
        _bio = State(initialValue: initialBio)
        _color = State(initialValue: initialColor)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Editar perfil").font(.title2.bold())

            TextField("Nombre", text: $name).textFieldStyle(.roundedBorder)
            // Hallazgo real, mismo criterio ya aplicado al caption de
            // posts: los límites de 50/300 caracteres son reales
            // (profiles_display_name_length/profiles_bio_length,
            // 0023_text_length_limits.sql) y ya se validan antes de
            // guardar (PerfilViewModel.swift), pero nada avisaba mientras
            // se escribe. Mismo fix ya construido en la versión Kotlin
            // equivalente.
            Text("\(name.count)/50")
                .font(.caption2)
                .foregroundStyle(name.count > 50 ? .red : .secondary)
            TextField("Bio", text: $bio, axis: .vertical).textFieldStyle(.roundedBorder)
            Text("\(bio.count)/300")
                .font(.caption2)
                .foregroundStyle(bio.count > 300 ? .red : .secondary)

            Text("Color de avatar").font(.subheadline.bold())
            HStack {
                ForEach(colorSwatches, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 36, height: 36)
                        .overlay(
                            Circle().stroke(.primary, lineWidth: color == hex ? 3 : 0)
                        )
                        .onTapGesture { color = hex }
                }
            }

            Button("Guardar") {
                onSave(name, bio, color)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)

            Spacer()
        }
        .padding()
    }
}

// `Color(hex:)` ya existe como `private extension` en
// PlaceholderAvatarProvider.swift (mismo formato de string que
// `colorSeed`) — las extensiones `private` son de ámbito de archivo en
// Swift, así que aquí hace falta la propia, no un duplicado real.
private extension Color {
    init(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
