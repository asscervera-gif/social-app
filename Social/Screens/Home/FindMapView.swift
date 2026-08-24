//
//  FindMapView.swift
//  Social
//
//  "Find" — mapa de ubicaciones públicas real, hallazgo real: era un
//  texto de relleno desde el principio de esta sesión (ver
//  FindLocationsViewModel.swift para el detalle completo). MapKit nativo
//  de Apple (framework del sistema, no un SDK de terceros de pago —
//  distinto de Google Maps, que sí exige API key facturable).
//
//  Aviso de honestidad: `Map(coordinateRegion:annotationItems:)` es la
//  forma de SwiftUI Map compatible con el deployment target real de este
//  proyecto (iOS 16, ver project.yml) — la API `Map(position:)` con
//  `Marker`/`Annotation` es exclusiva de iOS 17+ y no compilaría aquí,
//  mismo límite ya documentado para onChange(of:) en otros archivos. Sin
//  verificación de compilador real (límite de plataforma).
//

import SwiftUI
import MapKit

struct FindMapView: View {
    @StateObject private var viewModel = FindLocationsViewModel()
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.4168, longitude: -3.7038), // Madrid, centro por defecto sin ubicación propia real.
        span: MKCoordinateSpan(latitudeDelta: 20, longitudeDelta: 20)
    )

    var body: some View {
        ZStack(alignment: .top) {
            Map(coordinateRegion: $region, annotationItems: viewModel.locations) { location in
                MapAnnotation(coordinate: location.coordinate) {
                    VStack(spacing: 2) {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(.red)
                            .font(.title2)
                        Text(location.displayName)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .background(.thinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            .ignoresSafeArea(edges: .bottom)

            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red).padding()
            } else if viewModel.locations.isEmpty {
                Text("Nadie ha compartido su ubicación pública todavía.")
                    .font(.footnote)
                    .padding(8)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding()
            }
        }
        .task { await viewModel.load() }
    }
}
