//
//  PeerMarkerView.swift
//  Social
//
//  Marcador flotante que representa a un peer cercano sobre la vista de cámara.
//  En Fase 1 usa un círculo con inicial como placeholder: el avatar 3D real
//  (Avaturn/MetaPerson) se integra en la Fase 3 a través de AvatarProvider,
//  sin tocar la lógica de posicionamiento de aquí.
//

import SwiftUI

/// Posición en pantalla calculada a partir del ángulo UWB y el tamaño de la vista.
struct MarkerPosition {
    let x: CGFloat
    let y: CGFloat
    let scale: CGFloat
}

extension PeerProximity {

    /// Convierte ángulo horizontal + distancia en una posición sobre la vista de cámara.
    /// El campo de visión horizontal asumido es ~65° (cámara gran angular del iPhone),
    /// suficiente para una aproximación visual en Fase 1.
    func markerPosition(in size: CGSize) -> MarkerPosition? {
        guard let angle = horizontalAngle, let distance = distance, isInFrame else { return nil }

        let horizontalFOV: Float = 65 * .pi / 180
        let normalizedX = angle / (horizontalFOV / 2) // -1 (izquierda) ... 1 (derecha)
        let clampedX = max(-1, min(1, normalizedX))

        let x = size.width / 2 + CGFloat(clampedX) * (size.width / 2)
        let y = size.height * 0.42 // altura aproximada de una persona en el encuadre

        // Marcador más grande cuanto más cerca; rango pensado para 0.5m - 8m.
        let clampedDistance = max(0.5, min(distance, 8))
        let scale = CGFloat(1.6 - (clampedDistance / 8) * 1.1)

        return MarkerPosition(x: x, y: y, scale: max(0.5, scale))
    }
}

struct PeerMarkerView: View {

    let proximity: PeerProximity

    var body: some View {
        VStack(spacing: 6) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.pink, .purple, .orange],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 64, height: 64)
                .overlay(
                    Text("👤") // placeholder: sustituido por avatar 3D en Fase 3
                        .font(.system(size: 28))
                )
                .shadow(radius: 6)

            if let distance = proximity.distance {
                Text(String(format: "%.1f m", distance))
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.6))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
    }
}
