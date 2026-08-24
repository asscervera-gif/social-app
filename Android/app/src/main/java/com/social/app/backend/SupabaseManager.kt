package com.social.app.backend

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.functions.Functions
import io.github.jan.supabase.gotrue.Auth
import io.github.jan.supabase.postgrest.Postgrest
import io.github.jan.supabase.realtime.Realtime
import io.github.jan.supabase.storage.Storage

/**
 * Punto único de acceso al backend en Android — equivalente exacto a
 * SupabaseManager.swift en iOS. Mismo proyecto Supabase, mismas migraciones
 * (../../../supabase/migrations), mismas Edge Functions.
 *
 * Las credenciales se leen de BuildConfig, generadas a partir de
 * local.properties (no versionado, igual que Config.plist en iOS):
 *
 *   # local.properties
 *   SUPABASE_URL=https://TU-PROYECTO.supabase.co
 *   SUPABASE_ANON_KEY=TU_ANON_KEY_AQUI
 *
 * y en app/build.gradle.kts, dentro de defaultConfig:
 *   buildConfigField("String", "SUPABASE_URL", "\"${project.findProperty("SUPABASE_URL")}\"")
 *   buildConfigField("String", "SUPABASE_ANON_KEY", "\"${project.findProperty("SUPABASE_ANON_KEY")}\"")
 * (con buildFeatures { buildConfig = true } activado)
 */
object SupabaseManager {

    lateinit var client: SupabaseClient
        private set

    private var initialized = false

    fun initialize(supabaseUrl: String, supabaseAnonKey: String) {
        if (initialized) return
        client = createSupabaseClient(
            supabaseUrl = supabaseUrl,
            supabaseKey = supabaseAnonKey
        ) {
            install(Postgrest)
            install(Realtime)
            install(Auth)
            install(Functions)
            install(Storage)
        }
        initialized = true
    }
}
