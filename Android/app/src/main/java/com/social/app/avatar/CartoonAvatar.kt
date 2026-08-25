package com.social.app.avatar

import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke

/**
 * Avatar ilustrado tipo "busto de dibujo animado" -- misma geometría EXACTA
 * (mismos comandos de path, mismo viewBox="8 2 104 104") que `avatarSVG()`
 * en SOCIAL_APP.html, el boceto que el usuario pidió seguir "exactamente
 * igual". Reimplementado nativo en Compose Canvas (no un WebView) para que
 * encaje con el resto de la app y anime/recorte con normalidad.
 *
 * Sustituye al círculo con degradado + icono de persona que había antes --
 * sigue sin ser un motor de avatares 3D real (Avaturn/MetaPerson, ver
 * AvatarProvider), solo cambia el ESTILO del marcador de posición para que
 * coincida con el boceto en vez de un degradado genérico sin relación con
 * el diseño de producto real.
 */
@Composable
fun CartoonAvatar(skin: Color, hair: Color, top: Color, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier) {
        val sx = size.width / 104f
        val sy = size.height / 104f
        val ox = 8f
        val oy = 2f
        fun nx(v: Float) = (v - ox) * sx
        fun ny(v: Float) = (v - oy) * sy

        // Cuerpo/hombros — M18 120 Q18 86 60 86 Q102 86 102 120 Z
        val body = Path().apply {
            moveTo(nx(18f), ny(120f))
            quadraticTo(nx(18f), ny(86f), nx(60f), ny(86f))
            quadraticTo(nx(102f), ny(86f), nx(102f), ny(120f))
            close()
        }
        drawPath(body, color = top)

        // Cuello — rect x=50 y=72 w=20 h=18 rx=6
        drawRoundRect(
            color = skin,
            topLeft = Offset(nx(50f), ny(72f)),
            size = Size(20f * sx, 18f * sy),
            cornerRadius = CornerRadius(6f * sx, 6f * sy)
        )

        // Cara — ellipse cx=60 cy=52 rx=30 ry=33
        drawOval(
            color = skin,
            topLeft = Offset(nx(60f) - 30f * sx, ny(52f) - 33f * sy),
            size = Size(60f * sx, 66f * sy)
        )

        // Orejas — circle r=6 en (30,54) y (90,54)
        drawCircle(color = skin, radius = 6f * sx, center = Offset(nx(30f), ny(54f)))
        drawCircle(color = skin, radius = 6f * sx, center = Offset(nx(90f), ny(54f)))

        // Pelo — M28 46 Q28 14 60 14 Q92 14 92 46 Q88 30 60 30 Q32 30 28 46 Z
        val hairPath = Path().apply {
            moveTo(nx(28f), ny(46f))
            quadraticTo(nx(28f), ny(14f), nx(60f), ny(14f))
            quadraticTo(nx(92f), ny(14f), nx(92f), ny(46f))
            quadraticTo(nx(88f), ny(30f), nx(60f), ny(30f))
            quadraticTo(nx(32f), ny(30f), nx(28f), ny(46f))
            close()
        }
        drawPath(hairPath, color = hair)

        // Cejas — rect 12x3 rx=1.5 en (43,46) y (65,46)
        val browColor = Color(0xFF4A2E1A)
        drawRoundRect(
            color = browColor,
            topLeft = Offset(nx(43f), ny(46f)),
            size = Size(12f * sx, 3f * sy),
            cornerRadius = CornerRadius(1.5f * sx, 1.5f * sy)
        )
        drawRoundRect(
            color = browColor,
            topLeft = Offset(nx(65f), ny(46f)),
            size = Size(12f * sx, 3f * sy),
            cornerRadius = CornerRadius(1.5f * sx, 1.5f * sy)
        )

        // Ojos — circle r=3.4 en (49,54) y (71,54)
        val eyeColor = Color(0xFF33312F)
        drawCircle(color = eyeColor, radius = 3.4f * sx, center = Offset(nx(49f), ny(54f)))
        drawCircle(color = eyeColor, radius = 3.4f * sx, center = Offset(nx(71f), ny(54f)))

        // Boca — M52 70 Q60 77 68 70, stroke #b5533f width 2.4
        val mouth = Path().apply {
            moveTo(nx(52f), ny(70f))
            quadraticTo(nx(60f), ny(77f), nx(68f), ny(70f))
        }
        drawPath(
            mouth,
            color = Color(0xFFB5533F),
            style = Stroke(width = 2.4f * sx, cap = StrokeCap.Round)
        )
    }
}

/**
 * Paleta discreta de looks -- mismos valores hexadecimales exactos que
 * `LOOKS`/`me` en SOCIAL_APP.html, no colores inventados. `top` dobla como
 * "color de ropa"; usa el mismo conjunto de acentos de marca
 * (SocialColors) que el resto de la identidad visual de la app.
 */
object AvatarLook {
    val SKIN_TONES = listOf("#E0AC69", "#C68642", "#FFE0BD", "#8D5524", "#FCD7C2", "#F1C27D")
    val HAIR_TONES = listOf("#1A1A1A", "#111111", "#C9A227", "#B5B5B5", "#6B4226")
    val TOP_COLORS = listOf("#4DABF7", "#20BF6B", "#A55EEA", "#F76707", "#495057", "#E64980")

    fun random(): Triple<String, String, String> = Triple(
        SKIN_TONES.random(),
        HAIR_TONES.random(),
        TOP_COLORS.random()
    )
}
