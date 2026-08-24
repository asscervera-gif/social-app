package com.social.app.camera

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.social.app.proximity.PeerProximity
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.min

/**
 * Posición en pantalla a partir de ángulo + distancia UWB — equivalente
 * Android de `markerPosition(in:)` en PeerMarkerView.swift. Mismo campo de
 * visión horizontal asumido (~65°, gran angular típico de móvil) y el mismo
 * rango de escalado por distancia (0.5m–8m).
 */
fun PeerProximity.markerOffset(widthPx: Float, heightPx: Float): Offset? {
    val angle = horizontalAngleRad ?: return null
    if (distanceMeters == null) return null
    if (!isInFrame) return null

    val horizontalFovRad = 65f * (PI.toFloat() / 180f)
    val normalizedX = angle / (horizontalFovRad / 2f)
    val clampedX = max(-1f, min(1f, normalizedX))

    val x = widthPx / 2f + clampedX * (widthPx / 2f)
    val y = heightPx * 0.42f
    return Offset(x, y)
}

fun PeerProximity.markerScale(): Float {
    val distance = distanceMeters ?: return 1f
    val clamped = max(0.5f, min(distance, 8f))
    return max(0.5f, 1.6f - (clamped / 8f) * 1.1f)
}

/** Marcador flotante — placeholder de degradado, igual que en iOS hasta que
 * se integre un motor de avatares 3D real (ver AvatarProvider.swift). */
@Composable
fun PeerMarker(distanceMeters: Float?, sizeDp: Dp = 56.dp) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            modifier = Modifier
                .size(sizeDp)
                .background(
                    Brush.linearGradient(listOf(Color(0xFFFF5C8A), Color(0xFF8B5CF6), Color(0xFFFF9D4D))),
                    shape = CircleShape
                )
        )
        distanceMeters?.let {
            Text(
                text = "%.1f m".format(it),
                color = Color.White,
                style = MaterialTheme.typography.labelSmall,
                modifier = Modifier
                    .background(Color.Black.copy(alpha = 0.6f), RoundedCornerShape(50))
                    .padding(horizontal = 8.dp, vertical = 2.dp)
            )
        }
    }
}
