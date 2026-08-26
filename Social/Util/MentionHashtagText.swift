//
//  MentionHashtagText.swift
//  Social
//
//  Texto con "#etiquetas" Y "@menciones" tocables, compartido entre
//  captions de posts/reels y comentarios de posts/reels -- antes cada
//  pantalla que quería hashtags tocables tenía su propia copia de
//  `hashtagAttributedString`/`OpenURLAction` (HomeView.swift). A
//  diferencia de los sheets "Enviar a…" de esta sesión (duplicados a
//  propósito porque cada uno inserta contenido distinto en la base de
//  datos), aquí la lógica de renderizado es IDÉNTICA en las cuatro
//  superficies -- compartir es lo correcto, no duplicar. Equivalente de
//  MentionHashtagText.kt.
//
//  Nombre de usuario único real (@handle, 0073_profile_username.sql) +
//  notificación real de mención (0074_mentions.sql), comparado con
//  Instagram/Twitter/TikTok.
//

import SwiftUI

/// Construida FUERA de `body` a propósito, mismo criterio que
/// `hashtagAttributedString` (HomeView.swift): `body` está sujeto a
/// `@ViewBuilder` (requisito del protocolo `View`), que no admite un `for`
/// con efectos secundarios sin producir una `View` en cada iteración -- una
/// función normal fuera de cualquier result builder no tiene esa
/// restricción.
private func mentionHashtagAttributedString(_ text: String, baseColor: Color?, linkColor: Color) -> AttributedString {
    var result = AttributedString("")
    let words = text.split(separator: " ", omittingEmptySubsequences: false)
    for (index, word) in words.enumerated() {
        var piece = AttributedString(word)
        var isLink = false
        if word.hasPrefix("#"), word.count > 1 {
            let tag = word.dropFirst().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            if !tag.isEmpty, let url = URL(string: "socialhashtag://\(tag)") {
                piece.link = url
                piece.foregroundColor = linkColor
                piece.underlineStyle = .single
                isLink = true
            }
        } else if word.hasPrefix("@"), word.count > 1 {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
            let handle = word.dropFirst().trimmingCharacters(in: allowed.inverted)
            if !handle.isEmpty, let url = URL(string: "socialmention://\(handle)") {
                piece.link = url
                piece.foregroundColor = linkColor
                piece.underlineStyle = .single
                isLink = true
            }
        }
        if !isLink, let baseColor {
            piece.foregroundColor = baseColor
        }
        result += piece
        if index != words.count - 1 { result += AttributedString(" ") }
    }
    return result
}

struct MentionHashtagText: View {
    let text: String
    var font: Font = .subheadline
    // Reels (ReelsView.swift) pinta este texto en blanco fijo sobre el
    // vídeo, no el color normal del resto de la app -- de ahí este
    // override opcional, en vez de forzar un único esquema de color para
    // las cuatro superficies. `nil` deja el texto normal heredar el color
    // ambiente, igual que antes de esta ronda.
    var color: Color? = nil
    var linkColor: Color = .accentColor
    var onOpenHashtag: (String) -> Void = { _ in }
    var onOpenMention: (String) -> Void = { _ in }

    var body: some View {
        Text(mentionHashtagAttributedString(text, baseColor: color, linkColor: linkColor))
            .font(font)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "socialhashtag", let tag = url.host {
                    onOpenHashtag(tag)
                    return .handled
                }
                if url.scheme == "socialmention", let handle = url.host {
                    onOpenMention(handle)
                    return .handled
                }
                return .systemAction
            })
    }
}
