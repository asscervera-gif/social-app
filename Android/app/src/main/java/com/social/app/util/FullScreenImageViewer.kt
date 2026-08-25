package com.social.app.util

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import coil.compose.rememberAsyncImagePainter

/**
 * Hallazgo real, comparado con Instagram/Twitter/WhatsApp: en ningún sitio
 * de la app (feed, chat) se podía tocar una imagen para verla a tamaño
 * completo -- solo el recorte fijo (220dp en el feed, 200dp en el chat) de
 * la miniatura. Visor mínimo (sin zoom/pinch, alcance deliberadamente
 * acotado): fondo negro, imagen ajustada a la pantalla, tocar en cualquier
 * sitio para cerrar. Reutilizable desde HomeScreen.kt y ChatScreen.kt.
 */
@Composable
fun FullScreenImageViewer(url: String, onDismiss: () -> Unit) {
    // usePlatformDefaultWidth = false: por defecto Dialog limita el ancho
    // al contenido (pensado para diálogos pequeños), lo que dejaría la
    // imagen encajada en una franja estrecha en vez de ocupar la pantalla.
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black)
                .clickable(onClick = onDismiss),
            contentAlignment = Alignment.Center
        ) {
            Image(
                painter = rememberAsyncImagePainter(url),
                contentDescription = null,
                contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxSize()
            )
        }
    }
}
