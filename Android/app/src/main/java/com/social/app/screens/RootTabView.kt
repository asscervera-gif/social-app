package com.social.app.screens

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.social.app.ui.theme.SocialColors
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.social.app.backend.AnalyticsManager
import com.social.app.backend.SupabaseManager
import com.social.app.camera.SocialCameraScreen
import com.social.app.chat.ChatScreen
import com.social.app.duels.DuelEntryPoint
import com.social.app.duels.DuelHistoryScreen
import com.social.app.duels.DuelResultScreen
import com.social.app.proximity.SocialProximity
import com.social.app.screens.avisos.AvisosScreen
import com.social.app.screens.avisos.NotificationsBadgeViewModel
import com.social.app.screens.home.HomeScreen
import com.social.app.screens.match.MatchScreen
import com.social.app.screens.perfil.AjustesScreen
import com.social.app.screens.perfil.PerfilScreen
import com.social.app.screens.perfil.ProfileViewerScreen
import io.github.jan.supabase.gotrue.auth

private enum class Tab(val route: String, val label: String, val icon: ImageVector?) {
    HOME("home", "Home", Icons.Filled.Home),
    // Hallazgo real, comparado con Instagram/Duolingo: la pestaña Match no
    // tenía icono real, se veía un simple "•" -- ver
    // com.social.app.ui.theme.SocialColors.
    MATCH("match", "Match", Icons.Filled.Favorite),
    SOCIAL("social", "Social", null), // icono "S" con degradado real del logo
    AVISOS("avisos", "Avisos", Icons.Filled.Notifications),
    PERFIL("perfil", "Perfil", Icons.Filled.Person)
}

private const val CHAT_ROUTE = "chat/{chatId}"
private const val DUEL_ROUTE = "duel/{chatId}/{opponentId}"
private const val PROFILE_ROUTE = "profile/{profileId}"
private const val DUEL_RESULT_ROUTE = "duel_result/{duelId}"
private const val AJUSTES_ROUTE = "ajustes"
private const val MODERATION_ROUTE = "moderation"
private const val COMPAT_SHARES_ROUTE = "compat_shares"
private const val PRIVACY_POLICY_ROUTE = "privacy_policy"
private const val TERMS_ROUTE = "terms"
private const val BLOCKED_USERS_ROUTE = "blocked_users"
private const val HASHTAG_SEARCH_ROUTE = "search_hashtag/{tag}"
private const val DUEL_HISTORY_ROUTE = "duel_history"
private const val CHAT_LIST_ROUTE = "chat_list"
private const val MY_POSTS_ROUTE = "my_posts"
private const val SAVED_POSTS_ROUTE = "saved_posts"
private const val SOCIALS_LIST_ROUTE = "socials_list"
private const val FOLLOW_LIST_ROUTE = "follow_list/{tab}"
private const val SEARCH_ROUTE = "search"
private const val FIND_ROUTE = "find"

/**
 * Cinco pestañas + navegación real a chat/duelo — equivalente a
 * RootTabView.swift. "Social" (la cámara) es la pestaña por defecto, nunca
 * un feed. Antes, ChatScreen/DuelScreen eran componibles sueltos sin cablear
 * aquí; ahora sí forman parte del grafo de navegación de la app.
 */
@Composable
fun RootTabView(proximity: SocialProximity, startTab: String? = null) {
    val navController = rememberNavController()
    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = backStackEntry?.destination?.route
    val showBottomBar = Tab.values().any { it.route == currentRoute }

    // Hueco real, encontrado comparando con Instagram/TikTok/Snapchat:
    // tocar una notificación local (LocalNotifier.kt, "Toca para verlo")
    // no llevaba a ningún sitio -- sin PendingIntent, solo abría (o
    // traía a primer plano) la app en la pestaña por defecto. MainActivity
    // pasa aquí la pestaña pedida por el extra del Intent de la
    // notificación; se navega una sola vez por cada valor nuevo.
    LaunchedEffect(startTab) {
        if (startTab != null && Tab.values().any { it.route == startTab }) {
            navController.navigate(startTab) {
                popUpTo(navController.graph.findStartDestination().id) { saveState = true }
                launchSingleTop = true
                restoreState = true
            }
        }
    }

    // Badge de no leídas en la pestaña Avisos — antes no existía ninguna
    // señal de "hay algo nuevo" sin entrar a mirar (ver
    // NotificationsBadgeViewModel para el hallazgo completo).
    val badgeVm = remember { NotificationsBadgeViewModel() }
    val unreadCount by badgeVm.unreadCount.collectAsState()
    val appContext = LocalContext.current.applicationContext
    DisposableEffect(Unit) {
        badgeVm.start(appContext)
        onDispose { badgeVm.stop() }
    }

    // Sin este permiso explícito (obligatorio desde Android 13, API 33),
    // LocalNotifier.notify() falla en silencio para siempre — se pide una
    // sola vez al entrar a la app, mismo patrón ya usado para el micrófono
    // en ChatScreen.kt (ActivityResultContracts.RequestPermission).
    val notificationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
    DisposableEffect(Unit) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        onDispose {}
    }

    Scaffold(
        bottomBar = {
            if (showBottomBar) {
                // Hallazgo real, comparado con Instagram/Duolingo: la barra
                // inferior era un `NavigationBar` totalmente por defecto --
                // icono "S" como texto plano, "•" para Match, sin ningún
                // color de marca real. El icono "S" ahora usa el degradado
                // real de social_logo.png (mismo Brush multicolor ya usado
                // en el icono de pestaña de iOS, SocialTabIcon).
                NavigationBar(containerColor = SocialColors.Background) {
                    Tab.values().forEach { tab ->
                        val selected = currentRoute == tab.route
                        NavigationBarItem(
                            selected = selected,
                            onClick = {
                                AnalyticsManager.track("tab_view")
                                navController.navigate(tab.route) {
                                    popUpTo(navController.graph.findStartDestination().id) { saveState = true }
                                    launchSingleTop = true
                                    restoreState = true
                                }
                            },
                            icon = {
                                val iconContent: @Composable () -> Unit = {
                                    when {
                                        tab.icon != null -> Icon(tab.icon, contentDescription = tab.label)
                                        tab == Tab.SOCIAL -> Text(
                                            "S",
                                            style = TextStyle(
                                                // Mismo degradado EXACTO que SOCIAL_APP.html
                                                // (el boceto pedido "exactamente igual"),
                                                // no el arcoíris de 7 colores muestreado del
                                                // logo -- ver SocialColors.WordmarkGradient.
                                                brush = Brush.linearGradient(SocialColors.WordmarkGradient),
                                                fontWeight = FontWeight.Light,
                                                fontSize = 22.sp
                                            )
                                        )
                                        else -> Text("•")
                                    }
                                }
                                if (tab == Tab.AVISOS && unreadCount > 0) {
                                    BadgedBox(badge = { Badge { Text(unreadCount.coerceAtMost(99).toString()) } }) {
                                        iconContent()
                                    }
                                } else {
                                    iconContent()
                                }
                            },
                            label = { Text(tab.label) },
                            colors = NavigationBarItemDefaults.colors(
                                indicatorColor = SocialColors.SurfaceVariant
                            )
                        )
                    }
                }
            }
        }
    ) { padding ->
        Box(modifier = Modifier.padding(padding)) {
            NavHost(navController = navController, startDestination = Tab.SOCIAL.route) {
                composable(Tab.HOME.route) {
                    HomeScreen(
                        onOpenSearch = { navController.navigate(SEARCH_ROUTE) },
                        onOpenFind = { navController.navigate(FIND_ROUTE) },
                        onOpenHashtag = { tag ->
                            navController.navigate("search_hashtag/${java.net.URLEncoder.encode(tag, "UTF-8")}")
                        },
                        onOpenProfile = { profileId -> navController.navigate("profile/$profileId") }
                    )
                }
                composable(SEARCH_ROUTE) {
                    com.social.app.ui.theme.BackScaffold(title = "Buscar", onBack = { navController.popBackStack() }) {
                        com.social.app.screens.search.SearchScreen(
                            onOpenProfile = { profileId -> navController.navigate("profile/$profileId") }
                        )
                    }
                }
                composable(HASHTAG_SEARCH_ROUTE) { routeEntry ->
                    val tag = routeEntry.arguments?.getString("tag").orEmpty()
                    com.social.app.ui.theme.BackScaffold(title = "Buscar", onBack = { navController.popBackStack() }) {
                        com.social.app.screens.search.SearchScreen(
                            onOpenProfile = { profileId -> navController.navigate("profile/$profileId") },
                            initialHashtag = java.net.URLDecoder.decode(tag, "UTF-8")
                        )
                    }
                }
                composable(FIND_ROUTE) {
                    com.social.app.ui.theme.BackScaffold(title = "Find", onBack = { navController.popBackStack() }) {
                        com.social.app.screens.home.FindMapScreen(
                            onOpenProfile = { profileId -> navController.navigate("profile/$profileId") }
                        )
                    }
                }
                composable(Tab.MATCH.route) {
                    MatchScreen(onOpenProfile = { profileId -> navController.navigate("profile/$profileId") })
                }
                composable(Tab.SOCIAL.route) {
                    SocialCameraScreen(
                        proximity,
                        onOpenProfile = { profileId -> navController.navigate("profile/$profileId") }
                    )
                }
                composable(Tab.AVISOS.route) {
                    AvisosScreen(
                        onOpenChat = { chatId -> navController.navigate("chat/$chatId") },
                        onOpenProfile = { profileId -> navController.navigate("profile/$profileId") },
                        onOpenDuelResult = { duelId -> navController.navigate("duel_result/$duelId") }
                    )
                }
                composable(Tab.PERFIL.route) {
                    PerfilScreen(
                        onOpenAjustes = { navController.navigate(AJUSTES_ROUTE) },
                        onOpenDuelHistory = { navController.navigate(DUEL_HISTORY_ROUTE) },
                        onOpenChatList = { navController.navigate(CHAT_LIST_ROUTE) },
                        onOpenMyPosts = { navController.navigate(MY_POSTS_ROUTE) },
                        onOpenSocials = { navController.navigate(SOCIALS_LIST_ROUTE) },
                        onOpenSavedPosts = { navController.navigate(SAVED_POSTS_ROUTE) },
                        onOpenFollowing = { navController.navigate("follow_list/following") },
                        onOpenFollowers = { navController.navigate("follow_list/followers") }
                    )
                }
                // Hallazgo real, comparado con Instagram/Twitter/TikTok:
                // los contadores "Sigo"/"Seguid." de la cabecera del perfil
                // ya eran reales, pero tocarlos no hacía nada -- no existía
                // ninguna pantalla para ver QUIÉN sigue a quién.
                composable(FOLLOW_LIST_ROUTE) { routeEntry ->
                    val tabArg = routeEntry.arguments?.getString("tab")
                    val initialTab = if (tabArg == "followers") {
                        com.social.app.screens.perfil.FollowTab.FOLLOWERS
                    } else {
                        com.social.app.screens.perfil.FollowTab.FOLLOWING
                    }
                    com.social.app.ui.theme.BackScaffold(title = "Siguiendo y seguidores", onBack = { navController.popBackStack() }) {
                        com.social.app.screens.perfil.FollowListScreen(
                            initialTab = initialTab,
                            onOpenProfile = { profileId -> navController.navigate("profile/$profileId") }
                        )
                    }
                }
                // Hallazgo real, sistémico, encontrado por el usuario
                // probando la app de verdad ("no se puede volver atrás"):
                // NINGUNA pantalla empujada por navegación tenía un botón
                // de volver real -- dependían solo del gesto de sistema,
                // casi imposible de repetir con ratón en el emulador (y un
                // antipatrón de Material Design incluso en un dispositivo
                // real). `BackScaffold` centraliza la barra superior real
                // (título + flecha), envolviendo cada pantalla aquí mismo
                // sin tocar su disposición interna.
                composable(MY_POSTS_ROUTE) {
                    com.social.app.ui.theme.BackScaffold(title = "Tus publicaciones", onBack = { navController.popBackStack() }) {
                        com.social.app.screens.perfil.MyPostsScreen()
                    }
                }
                composable(SAVED_POSTS_ROUTE) {
                    com.social.app.ui.theme.BackScaffold(title = "Guardados", onBack = { navController.popBackStack() }) {
                        com.social.app.screens.perfil.SavedPostsScreen(
                            onOpenProfile = { profileId -> navController.navigate("profile/$profileId") }
                        )
                    }
                }
                composable(SOCIALS_LIST_ROUTE) {
                    com.social.app.ui.theme.BackScaffold(title = "Tus socials", onBack = { navController.popBackStack() }) {
                        com.social.app.screens.perfil.SocialsListScreen(
                            onOpenProfile = { profileId -> navController.navigate("profile/$profileId") }
                        )
                    }
                }
                composable(DUEL_HISTORY_ROUTE) {
                    com.social.app.ui.theme.BackScaffold(title = "Duelos", onBack = { navController.popBackStack() }) {
                        DuelHistoryScreen(onOpenDuel = { duelId -> navController.navigate("duel_result/$duelId") })
                    }
                }
                composable(CHAT_LIST_ROUTE) {
                    com.social.app.ui.theme.BackScaffold(title = "Tus chats", onBack = { navController.popBackStack() }) {
                        com.social.app.chat.ChatListScreen(onOpenChat = { chatId -> navController.navigate("chat/$chatId") })
                    }
                }
                composable(AJUSTES_ROUTE) {
                    com.social.app.ui.theme.BackScaffold(title = "Ajustes", onBack = { navController.popBackStack() }) {
                        AjustesScreen(
                            onAccountDeleted = {
                                // AccountManager.deleteAccount() ya llama a
                                // auth.signOut() — AppRoot.kt reacciona a
                                // sessionStatus y desmonta este NavHost entero
                                // en favor de AuthScreen automáticamente. Ya no
                                // hace falta navegar a mano (antes no existía
                                // ninguna pantalla de login a la que volver).
                            },
                            onOpenBlockedUsers = { navController.navigate(BLOCKED_USERS_ROUTE) },
                            onOpenCompatShares = { navController.navigate(COMPAT_SHARES_ROUTE) },
                            onOpenPrivacyPolicy = { navController.navigate(PRIVACY_POLICY_ROUTE) },
                            onOpenModeration = { navController.navigate(MODERATION_ROUTE) }
                        )
                    }
                }
                composable(MODERATION_ROUTE) {
                    com.social.app.ui.theme.BackScaffold(title = "Moderación", onBack = { navController.popBackStack() }) {
                        com.social.app.screens.perfil.ModerationScreen()
                    }
                }
                composable(COMPAT_SHARES_ROUTE) {
                    com.social.app.ui.theme.BackScaffold(title = "Quién ve tu compatibilidad", onBack = { navController.popBackStack() }) {
                        com.social.app.screens.perfil.CompatSharesScreen(
                            onOpenProfile = { profileId -> navController.navigate("profile/$profileId") }
                        )
                    }
                }
                composable(PRIVACY_POLICY_ROUTE) {
                    com.social.app.ui.theme.BackScaffold(title = "Política de privacidad", onBack = { navController.popBackStack() }) {
                        com.social.app.screens.perfil.PrivacyPolicyScreen()
                    }
                }
                composable(TERMS_ROUTE) {
                    com.social.app.ui.theme.BackScaffold(title = "Términos del servicio", onBack = { navController.popBackStack() }) {
                        com.social.app.screens.perfil.TermsOfServiceScreen()
                    }
                }
                composable(BLOCKED_USERS_ROUTE) {
                    com.social.app.ui.theme.BackScaffold(title = "Usuarios bloqueados", onBack = { navController.popBackStack() }) {
                        com.social.app.screens.perfil.BlockedUsersScreen()
                    }
                }

                composable(CHAT_ROUTE) { routeEntry ->
                    val chatId = routeEntry.arguments?.getString("chatId") ?: return@composable
                    val currentUserId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@composable
                    com.social.app.ui.theme.BackScaffold(title = "Chat", onBack = { navController.popBackStack() }) {
                        ChatScreen(
                            chatId = chatId,
                            currentUserId = currentUserId,
                            onStartDuel = { opponentId -> navController.navigate("duel/$chatId/$opponentId") }
                        )
                    }
                }
                composable(DUEL_ROUTE) { routeEntry ->
                    val chatId = routeEntry.arguments?.getString("chatId") ?: return@composable
                    val opponentId = routeEntry.arguments?.getString("opponentId") ?: return@composable
                    com.social.app.ui.theme.BackScaffold(title = "Duelo", onBack = { navController.popBackStack() }) {
                        DuelEntryPoint(chatId = chatId, opponentId = opponentId)
                    }
                }
                composable(PROFILE_ROUTE) { routeEntry ->
                    val profileId = routeEntry.arguments?.getString("profileId") ?: return@composable
                    com.social.app.ui.theme.BackScaffold(title = "Perfil", onBack = { navController.popBackStack() }) {
                        ProfileViewerScreen(profileId = profileId)
                    }
                }
                composable(DUEL_RESULT_ROUTE) { routeEntry ->
                    val duelId = routeEntry.arguments?.getString("duelId") ?: return@composable
                    com.social.app.ui.theme.BackScaffold(title = "Resultado del duelo", onBack = { navController.popBackStack() }) {
                        DuelResultScreen(duelId = duelId)
                    }
                }
            }

            // Hallazgo real, reportado directamente por el usuario
            // probando la app de verdad: "hay un icono de denunciar/
            // bloquear que no sé en qué momento está ahí" -- el overlay
            // global `SafetyToolbar` ya solo abría un aviso de "denúncialo
            // desde su perfil/chat/post/comentario" (desde que se cerró
            // el bug de autodenuncia), porque cada pantalla real ya tiene
            // su propio botón con el target correcto. Un icono flotante
            // que solo explica dónde ir ya no aporta nada, solo confunde
            // -- quitado del todo, no sustituido por nada (SafetyManager/
            // ReportSheet no dependen de este overlay para funcionar).
        }
    }
}
