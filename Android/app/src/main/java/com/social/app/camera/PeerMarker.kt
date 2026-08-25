package com.social.app.camera

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
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

/**
 * Marcador flotante -- comparado con el boceto real del producto
 * (`social_boceto.html`, en la raíz del repositorio: `.avatar-marker` con
 * `.am-tag` -- nombre + distancia en una píldora ENCIMA del círculo -- y
 * `.am-circle` con el color/avatar real de la persona, más una colita de
 * bocadillo apuntando hacia abajo).
 *
 * Hallazgo real, reportado directamente por el usuario probando la app de
 * verdad: "el muñeco que sale en social al entrar no significa nada" --
 * cierto, era un círculo con un degradado ALEATORIO sin relación alguna
 * con la persona detectada, igual para todo el mundo. Ahora usa el avatar
 * real de esa persona (`AvatarView`, el mismo componente ya usado en
 * chat/posts/avisos) en cuanto se resuelve su perfil, con una etiqueta de
 * nombre real encima -- mientras el perfil todavía no se conoce (UWB
 * detecta antes de identificar), se muestra un estado "Alguien cerca"
 * honesto en vez de fingir un dato que no existe todavía.
 */
@Composable
fun PeerMarker(distanceMeters: Float?, displayName: String? = null, avatarConfig: Map<String, String>? = null, sizeDp: Dp = 56.dp) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        // Etiqueta de nombre real -- antes no existía ningún texto
        // identificando a la persona, solo la distancia debajo del círculo.
        Text(
            text = buildString {
                append(displayName ?: "Alguien cerca")
                distanceMeters?.let { append(" · %.0f m".format(it)) }
            },
            color = Color.White,
            style = MaterialTheme.typography.labelSmall,
            modifier = Modifier
                .background(Color.Black.copy(alpha = 0.55f), RoundedCornerShape(50))
                .padding(horizontal = 8.dp, vertical = 3.dp)
        )
        Spacer(modifier = Modifier.height(4.dp))
        Box(
            modifier = Modifier
                .size(sizeDp)
                .background(Color.White, shape = CircleShape)
                .padding(2.5.dp),
            contentAlignment = Alignment.Center
        ) {
            if (avatarConfig != null) {
                com.social.app.avatar.AvatarView(config = avatarConfig, size = sizeDp - 5.dp)
            } else {
                // Todavía sin perfil resuelto (UWB detecta antes de
                // identificar) -- degradado neutro honesto, no un
                // "muñeco" con apariencia definitiva pero sin sentido.
                Box(
                    modifier = Modifier
                        .size(sizeDp - 5.dp)
                        .background(
                            Brush.linearGradient(listOf(Color(0xFFBDBDBD), Color(0xFF9E9E9E))),
                            shape = CircleShape
                        )
                )
            }
        }
    }
}

/**
 * Radar de fondo -- comparado con el boceto real (`social_boceto.html`,
 * `.radar`/`.sweep`): tres anillos concéntricos + un barrido giratorio,
 * reforzando visualmente el concepto de "escaneando alrededor tuyo" en
 * vez de dejar los marcadores flotando sobre la cámara sin ningún
 * elemento que comunique que SOCIAL está buscando activamente. Hallazgo
 * real, pedido directamente por el usuario: "tiene que haber una brújula
 * que encuentre a las personas... mayoritariamente" -- el radar es esa
 * brújula visual (dirección real ya viene del ángulo UWB en
 * `markerOffset`, esto es la representación, no un dato inventado).
 */
@Composable
fun RadarBackground(modifier: Modifier = Modifier, sizeDp: Dp = 260.dp) {
    val transition = rememberInfiniteTransition(label = "radar-sweep")
    val angle by transition.animateFloat(
        initialValue = 0f,
        targetValue = 360f,
        animationSpec = infiniteRepeatable(tween(3000, easing = LinearEasing), RepeatMode.Restart),
        label = "radar-angle"
    )
    Box(modifier = modifier.size(sizeDp), contentAlignment = Alignment.Center) {
        Canvas(modifier = Modifier.size(sizeDp)) {
            val ringColor = Color(0xFF4DABF7).copy(alpha = 0.35f)
            listOf(1f, 0.65f, 0.3f).forEach { fraction ->
                drawCircle(color = ringColor, radius = (size.minDimension / 2f) * fraction, style = Stroke(width = 1.5.dp.toPx()))
            }
            rotate(degrees = angle) {
                drawArc(
                    brush = Brush.sweepGradient(listOf(Color.Transparent, Color(0xFF4DABF7).copy(alpha = 0.5f), Color.Transparent)),
                    startAngle = 0f,
                    sweepAngle = 100f,
                    useCenter = true
                )
            }
        }
    }
}
