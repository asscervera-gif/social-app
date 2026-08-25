//
//  EditProfileView.swift
//  Social
//
//  Editar nombre/bio/look de avatar — no existía en ningún sitio (ver
//  PerfilViewModel.updateBasicInfo para el hallazgo completo). Sin
//  selector de foto real: la generación de avatar 3D sigue sin un motor
//  real (ver AvatarProvider), fingir un selector aquí sería peor que no
//  tenerlo. Equivalente de EditProfileSheet.kt.
//
//  Hallazgo real de esta pasada ("lo quiero exactamente igual" al boceto
//  SOCIAL_APP.html): un único "color de avatar" dejó de tener sentido en
//  cuanto el avatar pasó a ser el busto ilustrado de tres colores
//  (piel/pelo/ropa, CartoonAvatarView/AvatarLook) — ahora se eligen los
//  tres por separado, con vista previa en vivo.
//

import SwiftUI

struct EditProfileView: View {
    @State private var name: String
    @State private var bio: String
    @State private var skin: String
    @State private var hair: String
    @State private var top: String
    let onSave: (String, String, String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    init(initialName: String, initialBio: String, initialSkin: String, initialHair: String, initialTop: String, onSave: @escaping (String, String, String, String, String) -> Void) {
        _name = State(initialValue: initialName)
        _bio = State(initialValue: initialBio)
        _skin = State(initialValue: initialSkin)
        _hair = State(initialValue: initialHair)
        _top = State(initialValue: initialTop)
        self.onSave = onSave
    }

    var body: some View {
        ScrollView {
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

                HStack(spacing: 12) {
                    CartoonAvatarView(skin: Color(hex: skin), hair: Color(hex: hair), top: Color(hex: top))
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                        .background(Circle().fill(Color(hex: "DFE6EE")))
                    Text("Tu look").font(.title3.bold())
                }
                .padding(.top, 4)

                swatchRow("Piel", options: AvatarLook.skinTones, selected: $skin)
                swatchRow("Pelo", options: AvatarLook.hairTones, selected: $hair)
                swatchRow("Ropa", options: AvatarLook.topColors, selected: $top)

                Button("Guardar") {
                    onSave(name, bio, skin, hair, top)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer(minLength: 8)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func swatchRow(_ label: String, options: [String], selected: Binding<String>) -> some View {
        Text(label).font(.subheadline.bold()).padding(.top, 6)
        HStack {
            ForEach(options, id: \.self) { hex in
                Circle()
                    .fill(Color(hex: hex))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Circle().stroke(.primary, lineWidth: selected.wrappedValue.caseInsensitiveCompare(hex) == .orderedSame ? 3 : 0)
                    )
                    .onTapGesture { selected.wrappedValue = hex }
            }
        }
    }
}

// `Color(hex:)` ya existe como `private extension` en
// PlaceholderAvatarProvider.swift (mismo formato de string que
// skin/hair/top) — las extensiones `private` son de ámbito de archivo en
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
