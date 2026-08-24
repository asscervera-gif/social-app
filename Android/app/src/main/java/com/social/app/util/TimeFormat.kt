package com.social.app.util

/** Hora relativa ("hace 2h", "3d") — extraída de HomeScreen.kt para
 * reutilizarla también en Avisos, que tenía el mismo hueco (createdAt
 * nunca se mostraba). `created_at` de Postgres llega en ISO 8601. */
fun relativeTime(isoTimestamp: String): String {
    return try {
        val then = java.time.Instant.parse(isoTimestamp)
        val seconds = java.time.Duration.between(then, java.time.Instant.now()).seconds
        when {
            seconds < 60 -> "ahora"
            seconds < 3600 -> "hace ${seconds / 60}min"
            seconds < 86400 -> "hace ${seconds / 3600}h"
            seconds < 604800 -> "hace ${seconds / 86400}d"
            else -> "hace ${seconds / 604800}sem"
        }
    } catch (e: Exception) {
        ""
    }
}
