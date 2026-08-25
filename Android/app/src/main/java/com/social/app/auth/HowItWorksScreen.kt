package com.social.app.auth

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

/**
 * Hallazgo real, directamente exigido por growth_strategy.md ("cero
 * fricción en el primer uso... el valor tiene que sentirse en los
 * primeros 30 segundos"): ninguna plataforma explicaba nunca qué es o
 * cómo funciona la detección UWB antes de soltar al usuario en la cámara
 * ("Buscando personas cerca de ti..."). Comparado con cualquier app
 * grande (Instagram/TikTok/Snapchat, que sí muestran un carrusel de
 * bienvenida antes de la función principal), un hueco real de
 * onboarding — UWB no es un mecanismo que nadie conozca de antemano, a
 * diferencia de "dar like". Equivalente de HowItWorksView.swift.
 *
 * Se muestra una sola vez por dispositivo (SharedPreferences local, no
 * una columna de servidor — es presentación pura, no hace falta
 * sincronizarla entre dispositivos).
 */
private const val PREFS_NAME = "social_prefs"
private const val KEY_SEEN = "has_seen_how_it_works"

fun hasSeenHowItWorks(context: android.content.Context): Boolean =
    context.getSharedPreferences(PREFS_NAME, android.content.Context.MODE_PRIVATE)
        .getBoolean(KEY_SEEN, false)

private fun markHowItWorksSeen(context: android.content.Context) {
    context.getSharedPreferences(PREFS_NAME, android.content.Context.MODE_PRIVATE)
        .edit().putBoolean(KEY_SEEN, true).apply()
}

private data class Slide(val emoji: String, val title: String, val body: String)

private val slides = listOf(
    Slide(
        "📡",
        "Descubre quién está cerca de verdad",
        "SOCIAL usa el chip UWB de tu teléfono para detectar con precisión real a las personas a tu alrededor — no es solo GPS, es distancia y dirección exactas."
    ),
    Slide(
        "📷",
        "Apunta con la cámara",
        "Verás el avatar de cada persona superpuesto justo en la dirección real donde está, como una brújula. Gira el teléfono para encontrarla."
    ),
    Slide(
        "💬",
        "Manda un social si te interesa",
        "Nadie ve tu ubicación exacta a menos que aceptéis conectar. El modo invisible te oculta por completo cuando quieras."
    )
)

@Composable
fun HowItWorksScreen(onFinished: () -> Unit) {
    val context = LocalContext.current
    val pagerState = rememberPagerState(pageCount = { slides.size })
    val scope = rememberCoroutineScope()

    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        HorizontalPager(
            state = pagerState,
            modifier = Modifier.fillMaxWidth().weight(1f)
        ) { page ->
            val slide = slides[page]
            Column(
                modifier = Modifier.fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                Text(slide.emoji, style = MaterialTheme.typography.displayLarge)
                Spacer(modifier = Modifier.height(20.dp))
                Text(
                    slide.title,
                    style = MaterialTheme.typography.headlineSmall,
                    textAlign = TextAlign.Center
                )
                Spacer(modifier = Modifier.height(12.dp))
                Text(
                    slide.body,
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(horizontal = 16.dp)
                )
            }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(vertical = 16.dp)) {
            repeat(slides.size) { index ->
                val active = index == pagerState.currentPage
                Box(
                    modifier = Modifier
                        .height(6.dp)
                        .width(if (active) 20.dp else 6.dp)
                        .clip(RoundedCornerShape(3.dp))
                        .background(if (active) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceVariant)
                )
            }
        }

        Button(
            onClick = {
                if (pagerState.currentPage < slides.size - 1) {
                    scope.launch { pagerState.animateScrollToPage(pagerState.currentPage + 1) }
                } else {
                    markHowItWorksSeen(context)
                    // Mismo criterio que el resto de la auditoría de
                    // AnalyticsManager de esta sesión: sin esto, el
                    // equipo no tendría forma de saber si alguien
                    // realmente lee el onboarding o lo salta.
                    com.social.app.backend.AnalyticsManager.track("how_it_works_completed")
                    onFinished()
                }
            },
            modifier = Modifier.fillMaxWidth()
        ) {
            Text(if (pagerState.currentPage < slides.size - 1) "Siguiente" else "Entendido")
        }
    }
}
