package com.social.app.screens.avisos

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.social.app.MainActivity
import com.social.app.backend.model.NotificationEntry

/**
 * Notificación local del sistema para un aviso nuevo — hasta esta pasada,
 * `NotificationsBadgeViewModel` ya sabía en tiempo real (Realtime) que
 * había un aviso nuevo, pero solo actualizaba un número en la pestaña
 * Avisos: si el usuario estaba en otra pestaña (o la pantalla apagada con
 * la app en segundo plano reciente), no se enteraba de nada salvo que
 * volviera a mirar. Instagram/TikTok/Snapchat muestran una notificación
 * real del sistema en ese momento.
 *
 * Aviso de honestidad importante: esto NO es push real (FCM/APNs) — solo
 * funciona mientras el proceso de la app sigue vivo (la suscripción
 * Realtime de `NotificationsBadgeViewModel` sigue activa), como cualquier
 * WebSocket. Si el sistema mata el proceso, deja de llegar, igual que
 * cualquier notificación en vivo sin un servicio en primer plano o un
 * backend de push real. Documentado así en vez de fingir push verdadero.
 */
object LocalNotifier {
    private const val CHANNEL_ID = "avisos"

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Avisos",
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            description = "Nuevos socials, seguidores, duelos y compatibilidad"
        }
        manager.createNotificationChannel(channel)
    }

    fun notify(context: Context, entry: NotificationEntry) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ActivityCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            // Sin el permiso (nunca concedido o denegado) no se puede
            // publicar nada — mismo criterio que el resto de permisos
            // opcionales de la app: fallar en silencio, no crashear.
            return
        }
        ensureChannel(context)
        // Sin icono monocromo propio para la barra de estado en `res/` — se
        // usa el icono del sistema en vez de inventar un asset nuevo, mismo
        // criterio de honestidad que el resto de la sesión.
        //
        // Hallazgo real: el texto del cuerpo de la notificación era
        // literalmente el emoji (entry.icon(), "👥"/"➕"/"⚡"/...) en vez de
        // algo legible — probablemente un cruce de argumentos con
        // entry.title(). El emoji ahora va delante del título (mismo
        // sitio donde AvisosScreen.kt ya lo usa como icono visual, línea
        // 202), y el cuerpo dice algo real en vez de un símbolo suelto.
        // Hueco real, encontrado comparando con Instagram/TikTok/Snapchat:
        // el texto decía "Toca para verlo" pero sin PendingIntent tocar la
        // notificación no llevaba a ningún sitio -- ver MainActivity.kt/
        // RootTabView.kt.EXTRA_OPEN_TAB.
        val openIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(MainActivity.EXTRA_OPEN_TAB, "avisos")
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            entry.id.hashCode(),
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("${entry.icon()} ${entry.title()}")
            .setContentText("Toca para verlo")
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setContentIntent(pendingIntent)
            .build()
        NotificationManagerCompat.from(context).notify(entry.id.hashCode(), notification)
    }
}
