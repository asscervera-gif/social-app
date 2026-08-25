//
//  EventModeView.swift
//  Social
//
//  Banner de evento activo + ranking de socials del evento.
//

import SwiftUI

struct EventModeView: View {

    @ObservedObject var viewModel: EventModeViewModel
    // Hallazgo real, mismo hueco raíz ya cerrado en el feed/comentarios/
    // chats/duelos/avisos/socials: el ranking del evento tampoco mostraba
    // avatar ni dejaba tocar para ver el perfil. Sin NavigationStack
    // ambiente en esta pantalla (todo se presenta con .sheet, ver
    // SendSocialSheet más abajo), mismo patrón ya usado en FindMapView.swift.
    @State private var openedProfileID: UUID?

    var body: some View {
        if let event = viewModel.activeEvent {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "sparkles")
                    Text("Estás en: \(event.name)").font(.headline)
                }

                // Hallazgo real, alineado con growth_strategy.md sección
                // 6: la métrica que de verdad importa es la "densidad
                // efectiva" (cuánta gente hay AHORA en este evento
                // concreto), y el valor tiene que sentirse en los
                // primeros 30 segundos — antes de esta pasada,
                // `viewModel.ranking` ya se cargaba en cuanto se detectaba
                // el evento (incluso sin haberse unido), pero nada en la
                // UI mostraba ese número hasta después de unirse. Mismo
                // fix ya construido en la versión Kotlin equivalente.
                if !viewModel.ranking.isEmpty {
                    Text("👥 \(viewModel.ranking.count) \(viewModel.ranking.count == 1 ? "persona" : "personas") aquí ahora")
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                }

                if !viewModel.hasJoined {
                    // joinEvent() ya existía en el ViewModel pero no había
                    // ningún punto de entrada en la UI para llamarlo.
                    Button("Unirme al evento") {
                        Task {
                            guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
                            await viewModel.joinEvent(eventID: event.id, userID: userID)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("Ranking de socials del evento")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)

                    ForEach(Array(viewModel.ranking.enumerated()), id: \.element.id) { index, attendee in
                        Button {
                            openedProfileID = attendee.id
                        } label: {
                            HStack {
                                Text("\(index + 1)").font(.caption.bold()).frame(width: 24)
                                ActiveAvatarProvider.shared.avatarView(config: attendee.avatarConfig ?? [:], size: 28)
                                Text(attendee.displayName).foregroundStyle(.primary)
                                Spacer()
                                Text("\(attendee.socialCount) socials").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding()
            .sheet(isPresented: Binding(
                get: { openedProfileID != nil },
                set: { isPresented in if !isPresented { openedProfileID = nil } }
            )) {
                if let openedProfileID {
                    NavigationStack {
                        ProfileViewerView(profileID: openedProfileID)
                    }
                }
            }
        }
    }
}
