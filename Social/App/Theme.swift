//
//  Theme.swift
//  Social
//
//  Hallazgo real, comparado con cualquier app grande (Instagram/Duolingo):
//  Android ya tenía colores reales del logo metidos a mano en
//  MainActivity.kt, pero iOS no tenía NINGÚN color de marca -- usaba el
//  azul de sistema por defecto de SwiftUI en toda la app. Colores
//  extraídos de verdad del asset real (social_logo.png, muestreo de
//  píxeles por bucket de tono, no adivinados) -- equivalente exacto de
//  ui/theme/SocialTheme.kt (Android).
//

import SwiftUI

enum SocialColors {
    // Los siete acentos reales del arcoíris del wordmark "SOCIAL", uno por
    // letra aproximadamente. Coral es el que ya se usaba de forma suelta
    // en varios sitios (p. ej. el botón "Siguiente" del onboarding).
    static let coral = Color(hex: 0xFF5A76)
    static let orange = Color(hex: 0xFFA630)
    static let gold = Color(hex: 0xF2B705)
    static let green = Color(hex: 0x4CAF7D)
    static let turquoise = Color(hex: 0x29C7C2)
    static let purple = Color(hex: 0x9B6FE0)
    static let magenta = Color(hex: 0xF0459B)

    static let ink = Color(hex: 0x12121A)
    static let surfaceVariant = Color(hex: 0xF3F1F7)

    // `Identifiable` con `id = key`: mismo patrón ya usado en el resto de
    // listas `ForEach` de esta app -- una tupla con nombre no tiene
    // keypath garantizado (`\.key`) en todas las versiones de Swift, así
    // que se evita ese riesgo con un struct real.
    struct AccentOption: Identifiable {
        let key: String
        let color: Color
        var id: String { key }
    }

    static let accents: [AccentOption] = [
        AccentOption(key: "coral", color: coral),
        AccentOption(key: "orange", color: orange),
        AccentOption(key: "gold", color: gold),
        AccentOption(key: "green", color: green),
        AccentOption(key: "turquoise", color: turquoise),
        AccentOption(key: "purple", color: purple),
        AccentOption(key: "magenta", color: magenta)
    ]

    static func color(for key: String) -> Color {
        accents.first(where: { $0.key == key })?.color ?? coral
    }

    // Degradado EXACTO del wordmark "SOCIAL"/icono "S" en SOCIAL_APP.html
    // (el boceto que el usuario pidió seguir "exactamente igual"):
    // linear-gradient(90deg,#ff3b3b,#f7b731,#20bf6b,#4dabf7,#a55eea). Fijo
    // -- es identidad de marca, no un acento que el usuario elija en
    // Ajustes (eso sigue siendo `accents`, arriba). Equivalente exacto de
    // SocialColors.WordmarkGradient (Android).
    static let wordmarkGradient: [Color] = [
        Color(hex: 0xFF3B3B), Color(hex: 0xF7B731), Color(hex: 0x20BF6B), Color(hex: 0x4DABF7), Color(hex: 0xA55EEA)
    ]
}

private extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

/// Hallazgo real: no había ninguna forma de personalizar el color de
/// acento -- ver AjustesView.swift. `@AppStorage` (UserDefaults) en vez de
/// una dependencia nueva para un caso de uso tan pequeño -- equivalente
/// exacto de AccentPreference (Android, SharedPreferences).
final class AccentPreference: ObservableObject {
    static let shared = AccentPreference()

    @AppStorage("accent_color") var accentKey: String = "coral" {
        didSet { objectWillChange.send() }
    }

    var color: Color { SocialColors.color(for: accentKey) }
}
