package com.social.app.avatar

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path

/**
 * Misma geometría EXACTA que CartoonAvatar.kt (Compose Canvas), pero
 * dibujada con `android.graphics.Canvas` nativo en vez de un `DrawScope`
 * -- necesaria porque osmdroid (mapa real de Find, ver FindMapScreen.kt)
 * pinta sus marcadores con `Drawable`/`Bitmap`, no con Composables. Sin
 * esto, cada chincheta del mapa era el pin rojo genérico de OSM sin
 * relación con quién es esa persona -- comparado con el boceto
 * SOCIAL_APP.html (`.pinav` -- el busto ilustrado, no un pin suelto).
 */
fun renderAvatarBitmap(skin: Int, hair: Int, top: Int, sizePx: Int): Bitmap {
    val bitmap = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    val sx = sizePx / 104f
    val sy = sizePx / 104f
    val ox = 8f
    val oy = 2f
    fun nx(v: Float) = (v - ox) * sx
    fun ny(v: Float) = (v - oy) * sy

    val clip = Path().apply { addCircle(sizePx / 2f, sizePx / 2f, sizePx / 2f, Path.Direction.CW) }
    canvas.clipPath(clip)

    val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    paint.color = Color.parseColor("#DFE6EE")
    canvas.drawRect(0f, 0f, sizePx.toFloat(), sizePx.toFloat(), paint)

    // Cuerpo/hombros
    val body = Path().apply {
        moveTo(nx(18f), ny(120f))
        quadTo(nx(18f), ny(86f), nx(60f), ny(86f))
        quadTo(nx(102f), ny(86f), nx(102f), ny(120f))
        close()
    }
    paint.color = top
    canvas.drawPath(body, paint)

    // Cuello
    paint.color = skin
    canvas.drawRoundRect(nx(50f), ny(72f), nx(70f), ny(90f), 6f * sx, 6f * sy, paint)

    // Cara
    canvas.drawOval(nx(60f) - 30f * sx, ny(52f) - 33f * sy, nx(60f) + 30f * sx, ny(52f) + 33f * sy, paint)

    // Orejas
    canvas.drawCircle(nx(30f), ny(54f), 6f * sx, paint)
    canvas.drawCircle(nx(90f), ny(54f), 6f * sx, paint)

    // Pelo
    val hairPath = Path().apply {
        moveTo(nx(28f), ny(46f))
        quadTo(nx(28f), ny(14f), nx(60f), ny(14f))
        quadTo(nx(92f), ny(14f), nx(92f), ny(46f))
        quadTo(nx(88f), ny(30f), nx(60f), ny(30f))
        quadTo(nx(32f), ny(30f), nx(28f), ny(46f))
        close()
    }
    paint.color = hair
    canvas.drawPath(hairPath, paint)

    // Cejas
    paint.color = Color.parseColor("#4A2E1A")
    canvas.drawRoundRect(nx(43f), ny(46f), nx(55f), ny(49f), 1.5f * sx, 1.5f * sy, paint)
    canvas.drawRoundRect(nx(65f), ny(46f), nx(77f), ny(49f), 1.5f * sx, 1.5f * sy, paint)

    // Ojos
    paint.color = Color.parseColor("#33312F")
    canvas.drawCircle(nx(49f), ny(54f), 3.4f * sx, paint)
    canvas.drawCircle(nx(71f), ny(54f), 3.4f * sx, paint)

    // Boca
    val mouth = Path().apply {
        moveTo(nx(52f), ny(70f))
        quadTo(nx(60f), ny(77f), nx(68f), ny(70f))
    }
    val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        color = Color.parseColor("#B5533F")
        strokeWidth = 2.4f * sx
        strokeCap = Paint.Cap.ROUND
    }
    canvas.drawPath(mouth, strokePaint)

    return bitmap
}

/** Deriva un color Android (`Int`) de un hex `"#RRGGBB"`, con el mismo
 * fallback (piel del primer look de AvatarLook) que AvatarView.kt. */
fun avatarColorInt(hex: String?, fallback: String): Int = try {
    Color.parseColor(hex ?: fallback)
} catch (e: IllegalArgumentException) {
    Color.parseColor(fallback)
}
