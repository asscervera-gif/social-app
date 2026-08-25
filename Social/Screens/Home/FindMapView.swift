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
    // Hallazgo real, comparado con Snapchat Map/BeReal: el marcador solo
    // mostraba el nombre, sin ninguna forma de tocar para ver el perfil
    // completo de esa persona. Equivalente de FindMapScreen.kt
    // (marker.setOnMarkerClickListener).
    @State private var openedProfileID: UUID?

    var body: some View {
        ZStack(alignment: .top) {
            Map(coordinateRegion: $region, annotationItems: viewModel.locations) { location in
                MapAnnotation(coordinate: location.coordinate) {
                    Button {
                        openedProfileID = location.id
                    } label: {
                        VStack(spacing: 2) {
                            // Hallazgo real, comparado con SOCIAL_APP.html
                            // (mapa "Find", `.pinav` -- el busto ilustrado,
                            // no un pin suelto): el marcador era un icono
                            // de sistema genérico sin relación con quién es
                            // esa persona. Equivalente de FindMapScreen.kt
                            // (renderAvatarBitmap) -- aquí no hace falta
                            // dibujar a mano en un Canvas nativo, MapKit
                            // acepta una View real como contenido del pin.
                            ActiveAvatarProvider.shared.avatarView(config: location.avatarConfig ?? [:], size: 40)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                                .shadow(radius: 2)
                            Text(location.displayName)
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .background(.thinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .ignoresSafeArea(edges: .bottom)
            // Mismo patrón ya usado en HomeView.swift para un `UUID?`/
            // `String?` no Identifiable: `.sheet(item:)` exige
            // `Identifiable`, así que se ata a un Binding derivado en vez
            // de forzar la conformidad solo para esto.
            .sheet(isPresented: Binding(
                get: { openedProfileID != nil },
                set: { isPresented in if !isPresented { openedProfileID = nil } }
            )) {
                if let profileID = openedProfileID {
                    NavigationStack {
                        ProfileViewerView(profileID: profileID)
                    }
                }
            }

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
