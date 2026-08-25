//
//  NewPostView.swift
//  Social
//
//  Compositor de publicaciones — no existía en ninguna plataforma (ver
//  NewPostViewModel para el hallazgo completo). Solo texto: sin foto/vídeo
//  porque no hay Supabase Storage real, pero `media_url` es opcional en el
//  esquema, así que esto es una publicación de verdad, no una simulación.
//  Equivalente de NewPostSheet.kt.
//

import SwiftUI
import PhotosUI

struct NewPostView: View {
    @StateObject private var viewModel = NewPostViewModel()
    @State private var caption = ""
    @State private var isSocialOnly = false
    // Comparado con Instagram/Facebook: varias fotos por publicación
    // (0055_post_media.sql) -- antes solo se podía elegir una.
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var imageDataList: [Data] = []
    // Hallazgo real, comparado con SOCIAL_APP.html ("Pubs de socials",
    // etiqueta "con Marta"): no había forma de decir con quién se hizo
    // una publicación -- 0051_post_social_tags.sql. Reutiliza la misma
    // lista de socials aceptados que ya construye SocialsListViewModel.
    @StateObject private var socialsViewModel = SocialsListViewModel()
    @State private var taggedProfileID: UUID?
    let onDismiss: () -> Void
    let onPosted: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nueva publicación").font(.title2.bold())

            TextField("¿Qué quieres contar?", text: $caption, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
            // Hallazgo real: el límite de 2200 caracteres es real
            // (posts_caption_length, 0023_text_length_limits.sql) y ya se
            // valida antes de publicar (NewPostViewModel.swift), pero
            // nada avisaba mientras se escribe — comparado con Instagram/
            // Twitter, que siempre muestran el contador restante. Mismo
            // fix ya construido en la versión Kotlin equivalente.
            Text("\(caption.count)/2200")
                .font(.caption2)
                .foregroundStyle(caption.count > 2200 ? .red : .secondary)

            if !imageDataList.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(imageDataList.enumerated()), id: \.offset) { _, data in
                            if let uiImage = UIImage(data: data) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 140, height: 180)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                }
            }
            PhotosPicker(selection: $selectedPhotos, matching: .images) {
                Text(imageDataList.isEmpty ? "Añadir fotos" : "Cambiar fotos (\(imageDataList.count))")
            }
            .buttonStyle(.bordered)
            .onChange(of: selectedPhotos) { newValue in
                Task {
                    var loaded: [Data] = []
                    for item in newValue {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            loaded.append(data)
                        }
                    }
                    imageDataList = loaded
                }
            }

            Toggle("Solo visible para tus socials aceptados", isOn: $isSocialOnly)

            if !socialsViewModel.socials.isEmpty {
                Text("¿Con quién? (opcional)").font(.subheadline.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(socialsViewModel.socials) { entry in
                            let selected = taggedProfileID == entry.id
                            Text(entry.displayName)
                                .font(.subheadline)
                                .foregroundStyle(selected ? .white : .secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(selected ? Color.blue : Color(.systemGray5))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .onTapGesture { taggedProfileID = selected ? nil : entry.id }
                        }
                    }
                }
            }

            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }

            Button {
                Task {
                    if await viewModel.post(caption: caption, isSocialOnly: isSocialOnly, imageDataList: imageDataList, taggedProfileID: taggedProfileID) {
                        onPosted()
                        onDismiss()
                    }
                }
            } label: {
                if viewModel.isPosting {
                    ProgressView()
                } else {
                    Text("Publicar").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isPosting)

            Spacer()
        }
        .padding()
        .task { await socialsViewModel.load() }
    }
}
