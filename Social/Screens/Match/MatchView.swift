//
//  MatchView.swift
//  Social
//
//  Redisenio fiel a match_boceto.html (título con lupa, buscador, chips de
//  filtro, tarjetas 2 columnas con degradado y nombre/compatibilidad
//  superpuestos) — equivalente SwiftUI de MatchScreen.kt (ya compilado y
//  verificado en el emulador Android; este archivo NO tiene verificación
//  de compilador real, no hay Mac disponible en este entorno).
//
//  Compatibilidad visible si el dueño la tiene pública; si no, "?%" y botón
//  para solicitarla (ver compat_requests, Fase 2 RLS regla 4).
//
//  Los 4 chips del boceto eran solo decorativos en la maqueta — aquí
//  filtran/ordenan de verdad sobre datos reales: "Compatibles" por %
//  descendente, "Tus gustos" por solapamiento real de intereses, "Nuevos"
//  por profiles.created_at, y "Cerca" por distancia real a partir de
//  last_lat/last_lng (ver el hallazgo gemelo en
//  PrivacySettingsViewModel.swift.publishCurrentLocation — antes esa
//  columna nunca se escribía, así que "Cerca" no podía haber funcionado
//  nunca).
//

import SwiftUI
import CoreLocation

private enum MatchFilter: String, CaseIterable {
    case cerca = "Cerca", compatibles = "Compatibles", nuevos = "Nuevos", gustos = "Tus gustos"
}

/// Paleta de degradados del boceto (match_boceto.html .card) — se asigna
/// por posición en la lista, no por identidad de usuario, igual que el
/// mockup y que cardGradients en MatchScreen.kt.
private let cardGradients: [[Color]] = [
    [Color(red: 1.0, green: 0.847, blue: 0.659), Color(red: 1.0, green: 0.659, blue: 0.659)],
    [Color(red: 0.647, green: 0.847, blue: 1.0), Color(red: 0.816, green: 0.749, blue: 1.0)],
    [Color(red: 0.698, green: 0.949, blue: 0.733), Color(red: 0.588, green: 0.949, blue: 0.843)],
    [Color(red: 1.0, green: 0.788, blue: 0.871), Color(red: 0.933, green: 0.745, blue: 0.980)]
]

struct MatchView: View {

    @StateObject private var viewModel = MatchViewModel()
    @State private var searchQuery = ""
    @State private var selectedFilter: MatchFilter = .cerca

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    private func distance(from here: CLLocation, to profile: Profile) -> CLLocationDistance? {
        guard let lat = profile.lastLat, let lng = profile.lastLng else { return nil }
        return here.distance(from: CLLocation(latitude: lat, longitude: lng))
    }

    private var visibleEntries: [MatchViewModel.Entry] {
        var list = viewModel.entries
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { entry in
                entry.profile.displayName.lowercased().contains(q) ||
                    entry.profile.interests.contains { $0.lowercased().contains(q) }
            }
        }
        switch selectedFilter {
        case .cerca:
            guard let here = viewModel.myLocation else { return list }
            return list.sorted {
                (distance(from: here, to: $0.profile) ?? .greatestFiniteMagnitude)
                    < (distance(from: here, to: $1.profile) ?? .greatestFiniteMagnitude)
            }
        case .compatibles:
            return list.sorted { ($0.compatibility ?? -1) > ($1.compatibility ?? -1) }
        case .nuevos:
            return list.sorted { ($0.profile.createdAt ?? "") > ($1.profile.createdAt ?? "") }
        case .gustos:
            return list.filter { entry in
                entry.profile.interests.contains { viewModel.myInterests.contains($0) }
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("🔍 Match")
                        .font(.title2.bold())
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 10)

                    HStack(spacing: 6) {
                        Text("🔍")
                        TextField("Buscar por intereses, ciudad, gustos...", text: $searchQuery)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(red: 0.945, green: 0.953, blue: 0.961))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(MatchFilter.allCases, id: \.self) { filter in
                                let active = filter == selectedFilter
                                Text(filter.rawValue)
                                    .font(.caption.bold())
                                    .foregroundStyle(active ? .white : .secondary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(active ? Color.black : Color(red: 0.945, green: 0.953, blue: 0.961))
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                    .onTapGesture { selectedFilter = filter }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 14)

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }

                    LazyVGrid(columns: columns, spacing: 10) {
                        // Hallazgo real (ya corregido antes de este
                        // redisenio): no había ninguna forma de abrir el
                        // perfil completo de un candidato desde esta
                        // cuadrícula — la tarjeta no llevaba a ningún sitio
                        // salvo el botón de pedir compatibilidad.
                        ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, entry in
                            NavigationLink {
                                ProfileViewerView(profileID: entry.profile.id)
                            } label: {
                                MatchCard(
                                    entry: entry,
                                    gradient: cardGradients[index % cardGradients.count],
                                    onRequestCompat: {
                                        Task { await viewModel.requestCompatibility(for: entry) }
                                    },
                                    onRequestHighlighted: {
                                        Task { await viewModel.requestCompatibility(for: entry, highlighted: true) }
                                    }
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await viewModel.load()
                await viewModel.fetchMyLocation()
            }
            // Hallazgo real: comparado con Instagram/Twitter/Facebook,
            // ninguna pantalla de la app tenía pull-to-refresh.
            .refreshable { await viewModel.load() }
            .overlay {
                if viewModel.isLoading { ProgressView() }
            }
        }
    }
}

private struct MatchCard: View {
    let entry: MatchViewModel.Entry
    let gradient: [Color]
    let onRequestCompat: () -> Void
    // "Interés destacado" real, comparado con Tinder/Bumble (Super Like)
    // -- ver MatchViewModel.requestCompatibility(highlighted:),
    // 0136_compat_request_highlight.sql.
    var onRequestHighlighted: () -> Void = {}

    var body: some View {
        ZStack {
            LinearGradient(colors: gradient, startPoint: .top, endPoint: .bottom)

            VStack {
                HStack(alignment: .top) {
                    ActiveAvatarProvider.shared.avatarView(config: entry.profile.avatarConfig ?? [:], size: 32)
                        .clipShape(Circle())
                        .background(Circle().fill(.white))

                    Spacer()

                    CompatBadge(entry: entry, onRequestCompat: onRequestCompat)
                }
                Spacer()
                HStack {
                    Text(entry.profile.displayName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 4)
                        .lineLimit(1)
                    Spacer()
                    // "Interés destacado" real, comparado con Tinder/
                    // Bumble (Super Like) -- solo tiene sentido mientras
                    // la compatibilidad real todavía no se sabe ni ya se
                    // pidió, mismo criterio que el badge "?% · Pedir".
                    if entry.compatibility == nil && !entry.requestSent {
                        Button(action: onRequestHighlighted) {
                            Text("⭐")
                                .padding(6)
                                .background(Circle().fill(.white))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(10)
        }
        .aspectRatio(0.8, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// Hallazgo real: la maqueta pinta "?%" como texto fijo, pero la app real
/// ya distingue "compatibilidad pública" de "compatibilidad solicitada"
/// (ver MatchViewModel.requestCompatibility) — el badge aquí conserva los
/// 3 estados reales en vez de perder el de "Solicitado" solo por igualar
/// el mockup al pixel. Estado "?% · Pedir" es un Button real (no
/// Text+onTapGesture) porque el patrón "Button dentro de un NavigationLink"
/// ya se usaba, sin cambios, en la versión anterior de esta pantalla.
private struct CompatBadge: View {
    let entry: MatchViewModel.Entry
    let onRequestCompat: () -> Void

    var body: some View {
        if let compat = entry.compatibility {
            pill(text: "\(compat)%", bg: Color(red: 0.125, green: 0.749, blue: 0.420), fg: .white)
        } else if entry.requestSent {
            pill(text: "Solicitado", bg: Color.white.opacity(0.7), fg: Color(white: 0.53))
        } else {
            Button(action: onRequestCompat) {
                pill(text: "?% · Pedir", bg: Color.white.opacity(0.7), fg: Color(white: 0.53))
            }
            .buttonStyle(.plain)
        }
    }

    private func pill(text: String, bg: Color, fg: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}
