package com.social.app.duels

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface

/**
 * "Compartir el resultado de un duelo como Historia" real, comparado con
 * Wordle/Kahoot (compartir el resultado de un reto) -- hallazgo real,
 * confirmado con `grep` de "compartir"/"share" sin resultados en
 * DuelResultScreen.kt: el resultado de un duelo se quedaba encerrado en
 * la propia pantalla, sin ninguna forma de compartirlo. Mismo mecanismo
 * de `stories` ya usado y probado por "compartir post a Historia"
 * (0129_story_shared_post.sql) -- aquí no hay un post que reutilizar
 * como imagen, así que se genera una tarjeta real en memoria con
 * `android.graphics.Canvas` nativo, mismo patrón exacto ya usado en
 * `renderAvatarBitmap` (AvatarBitmap.kt) para los marcadores del mapa de
 * Find.
 */
fun renderDuelResultCard(opponentName: String, delta: Int, widthPx: Int = 800, heightPx: Int = 1000): Bitmap {
    val bitmap = Bitmap.createBitmap(widthPx, heightPx, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)

    val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    bgPaint.shader = android.graphics.LinearGradient(
        0f, 0f, 0f, heightPx.toFloat(),
        Color.parseColor("#4DABF7"), Color.parseColor("#A55EEA"),
        android.graphics.Shader.TileMode.CLAMP
    )
    canvas.drawRect(0f, 0f, widthPx.toFloat(), heightPx.toFloat(), bgPaint)

    val titlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = widthPx * 0.07f
        textAlign = Paint.Align.CENTER
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }
    canvas.drawText("Duelo contra $opponentName", widthPx / 2f, heightPx * 0.25f, titlePaint)

    val deltaPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = widthPx * 0.16f
        textAlign = Paint.Align.CENTER
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }
    val deltaText = "${if (delta >= 0) "+" else ""}$delta"
    canvas.drawText(deltaText, widthPx / 2f, heightPx * 0.45f, deltaPaint)

    val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = widthPx * 0.05f
        textAlign = Paint.Align.CENTER
    }
    canvas.drawText("de compatibilidad", widthPx / 2f, heightPx * 0.52f, labelPaint)

    val footerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = widthPx * 0.045f
        textAlign = Paint.Align.CENTER
    }
    canvas.drawText("SOCIAL", widthPx / 2f, heightPx * 0.92f, footerPaint)

    return bitmap
}
