package com.social.app.util

import androidx.compose.foundation.text.ClickableText
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.style.TextDecoration

/**
 * Texto con "#etiquetas" Y "@menciones" tocables, compartido entre
 * captions de posts/reels y comentarios de posts/reels -- antes cada
 * pantalla que quería hashtags tocables tenía su propia copia de
 * `buildAnnotatedStringWithHashtags`/`CaptionText` (HomeScreen.kt). A
 * diferencia de los sheets "Enviar a…" de esta sesión (duplicados a
 * propósito porque cada uno inserta contenido distinto en la base de
 * datos), aquí la lógica de renderizado es IDÉNTICA en las cuatro
 * superficies -- compartir es lo correcto, no duplicar.
 *
 * Nombre de usuario único real (@handle, 0073_profile_username.sql) +
 * notificación real de mención (0074_mentions.sql), comparado con
 * Instagram/Twitter/TikTok.
 */
private fun buildMentionHashtagAnnotatedString(text: String, linkColor: Color, baseColor: Color): AnnotatedString {
    return buildAnnotatedString {
        val words = text.split(" ")
        words.forEachIndexed { index, word ->
            when {
                word.startsWith("#") && word.length > 1 -> {
                    val tag = word.drop(1).trimEnd { !it.isLetterOrDigit() }
                    pushStringAnnotation(tag = "hashtag", annotation = tag)
                    withStyle(SpanStyle(color = linkColor, textDecoration = TextDecoration.Underline)) { append(word) }
                    pop()
                }
                word.startsWith("@") && word.length > 1 -> {
                    val handle = word.drop(1).trimEnd { !(it.isLetterOrDigit() || it == '_') }
                    if (handle.isNotEmpty()) {
                        pushStringAnnotation(tag = "mention", annotation = handle)
                        withStyle(SpanStyle(color = linkColor, textDecoration = TextDecoration.Underline)) { append(word) }
                        pop()
                    } else {
                        withStyle(SpanStyle(color = baseColor)) { append(word) }
                    }
                }
                else -> withStyle(SpanStyle(color = baseColor)) { append(word) }
            }
            if (index != words.lastIndex) append(" ")
        }
    }
}

@Composable
fun MentionHashtagText(
    text: String,
    modifier: Modifier = Modifier,
    style: TextStyle = LocalTextStyle.current,
    // Reels (ReelsScreen.kt) pinta este texto en blanco fijo sobre el
    // vídeo, no el LocalContentColor/primary normales del resto de la
    // app -- de ahí estos dos overrides opcionales, en vez de forzar un
    // único esquema de color para las cuatro superficies.
    baseColor: Color = LocalContentColor.current,
    linkColor: Color = MaterialTheme.colorScheme.primary,
    onOpenHashtag: (String) -> Unit = {},
    onOpenMention: (String) -> Unit = {}
) {
    val annotated = remember(text, baseColor, linkColor) { buildMentionHashtagAnnotatedString(text, linkColor, baseColor) }
    ClickableText(text = annotated, modifier = modifier, style = style) { offset ->
        val hashtag = annotated.getStringAnnotations(tag = "hashtag", start = offset, end = offset).firstOrNull()
        if (hashtag != null) {
            onOpenHashtag(hashtag.item)
            return@ClickableText
        }
        annotated.getStringAnnotations(tag = "mention", start = offset, end = offset).firstOrNull()
            ?.let { onOpenMention(it.item) }
    }
}
