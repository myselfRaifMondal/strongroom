package app.strongroom.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import app.strongroom.android.core.Session

sealed interface Route {
    val needsVault: Boolean get() = false

    data object Vaults : Route
    data object CreateVault : Route
    data class ShowSecretKey(val vaultName: String, val secretKey: String) : Route
    data class Unlock(val vaultName: String) : Route
    data object Items : Route { override val needsVault = true }
    data class Detail(val id: String) : Route { override val needsVault = true }
    data class Edit(val id: String?) : Route { override val needsVault = true }
    data class History(val id: String) : Route { override val needsVault = true }

    /** [forEditor]: opened from the item editor; offers "Use this password". */
    data class Generator(val forEditor: Boolean = false) : Route
    data object Export : Route { override val needsVault = true }
    data object Import : Route { override val needsVault = true }
    data object ImportCsv : Route { override val needsVault = true }
    data object Trash : Route { override val needsVault = true }
    data object Settings : Route { override val needsVault = true }
}

/**
 * One back-stack entry. [state] keeps a screen's in-memory UI state (drafts,
 * search text, ...) while other screens are pushed on top of it, so going to
 * the generator and back does not wipe a half-edited item. It lives only in
 * memory (never in a saved-instance Bundle) and is dropped with the entry,
 * e.g. when the vault locks.
 */
class Entry(val route: Route) {
    val state = HashMap<String, Any?>()
}

class Nav {
    val stack = mutableStateListOf(Entry(Route.Vaults))
    val top: Route get() = stack.last().route
    val topEntry: Entry get() = stack.last()

    /** Password chosen with "Use" in the generator, picked up by the editor. */
    var generatedForEditor by mutableStateOf<String?>(null)

    fun push(r: Route) { stack.add(Entry(r)) }
    fun pop() { if (stack.size > 1) stack.removeAt(stack.lastIndex) }
    fun reset(vararg routes: Route) {
        stack.clear()
        stack.addAll(routes.map { Entry(it) })
        generatedForEditor = null
    }
}

val LocalEntry = staticCompositionLocalOf<Entry?> { null }

/**
 * Like `remember`, but the value survives while the current back-stack entry
 * is covered by another screen. Outside a [Nav] entry it is plain `remember`.
 */
@Composable
fun <T> retain(key: String, init: () -> T): T {
    val entry = LocalEntry.current ?: return remember { init() }
    @Suppress("UNCHECKED_CAST")
    return entry.state.getOrPut(key) { init() } as T
}

@Composable
fun StrongroomTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme(),
        content = content,
    )
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun StrongroomUi() {
    val nav = remember { Nav() }
    val unlocked by Session.unlockedName.collectAsState()

    // Auto-lock (or explicit lock) while on a vault screen: back to unlock.
    LaunchedEffect(unlocked, nav.top) {
        if (unlocked == null && nav.top.needsVault) {
            val last = Session.lastVaultName
            if (last != null) nav.reset(Route.Vaults, Route.Unlock(last)) else nav.reset(Route.Vaults)
        }
    }

    BackHandler(enabled = nav.stack.size > 1) { nav.pop() }

    StrongroomTheme {
        // Exposes testTags as resource-ids so adb/uiautomator can drive the UI.
        Box(Modifier.semantics { testTagsAsResourceId = true }) {
            val entry = nav.topEntry
            key(entry) {
                CompositionLocalProvider(LocalEntry provides entry) {
                    when (val r = entry.route) {
                        Route.Vaults -> VaultPickerScreen(nav)
                        Route.CreateVault -> CreateVaultScreen(nav)
                        is Route.ShowSecretKey -> SecretKeyScreen(nav, r)
                        is Route.Unlock -> UnlockScreen(nav, r.vaultName)
                        Route.Items -> if (unlocked != null) ItemListScreen(nav)
                        is Route.Detail -> if (unlocked != null) ItemDetailScreen(nav, r.id)
                        is Route.Edit -> if (unlocked != null) ItemEditScreen(nav, r.id)
                        is Route.History -> if (unlocked != null) HistoryScreen(nav, r.id)
                        is Route.Generator -> GeneratorScreen(nav, r.forEditor)
                        Route.Export -> if (unlocked != null) ExportScreen(nav)
                        Route.Import -> if (unlocked != null) ImportScreen(nav)
                        Route.ImportCsv -> if (unlocked != null) ImportCsvScreen(nav)
                        Route.Trash -> if (unlocked != null) TrashScreen(nav)
                        Route.Settings -> if (unlocked != null) SettingsScreen(nav)
                    }
                }
            }
        }
    }
}
