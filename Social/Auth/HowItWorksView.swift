//
//  HowItWorksView.swift
//  Social
//
//  Hallazgo real: ninguna plataforma explicaba nunca qué es o cómo
//  funciona la detección UWB antes de soltar al usuario directo en la
//  cámara ("Buscando personas cerca de ti..."). growth_strategy.md exige
//  explícitamente "cero fricción en el primer uso... el valor tiene que
//  sentirse en los primeros 30 segundos", y comparado con cualquier app
//  grande (Instagram/TikTok/Snapchat, que sí muestran un carrusel de
//  bienvenida antes de la función principal), SOCIAL no tenía ninguno —
//  un hueco real de onboarding, no cosmético: UWB es un mecanismo que
//  nadie conoce de antemano, a diferencia de "dar like a una foto".
//
//  Se muestra UNA sola vez por dispositivo (UserDefaults, no una columna
//  de servidor — es puramente presentación local, no hace falta
//  sincronizarlo entre dispositivos), justo después del primer login o
//  registro real.
//

import SwiftUI

enum HowItWorksSeen {
    private static let key = "has_seen_how_it_works"

    static var value: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

private struct Slide {
    let emoji: String
    let title: String
    let body: String
}

private let slides: [Slide] = [
    Slide(
        emoji: "📡",
        title: "Descubre quién está cerca de verdad",
        body: "SOCIAL usa el chip UWB de tu teléfono para detectar con precisión real a las personas a tu alrededor — no es solo GPS, es distancia y dirección exactas."
    ),
    Slide(
        emoji: "📷",
        title: "Apunta con la cámara",
        body: "Verás el avatar de cada persona superpuesto justo en la dirección real donde está, como una brújula. Gira el teléfono para encontrarla."
    ),
    Slide(
        emoji: "💬",
        title: "Manda un social si te interesa",
        body: "Nadie ve tu ubicación exacta a menos que aceptéis conectar. El modo invisible (arriba a la derecha) te oculta por completo cuando quieras."
    )
]

struct HowItWorksView: View {
    let onFinished: () -> Void
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                    VStack(spacing: 20) {
                        Spacer()
                        Text(slide.emoji).font(.system(size: 72))
                        Text(slide.title)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        Text(slide.body)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Spacer()
                        Spacer()
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < slides.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    HowItWorksSeen.value = true
                    // Mismo criterio que el resto de la auditoría de
                    // AnalyticsManager de esta sesión: sin esto, el
                    // equipo no tendría forma de saber si alguien
                    // realmente lee el onboarding o lo salta.
                    AnalyticsManager.track("how_it_works_completed")
                    onFinished()
                }
            } label: {
                Text(page < slides.count - 1 ? "Siguiente" : "Entendido").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
            .padding(.top, 12)
        }
    }
}
