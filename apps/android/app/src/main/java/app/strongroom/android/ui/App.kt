package app.strongroom.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.foundation.layout.Box
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
    data object Generator : Route
    data object Export : Route { override val needsVault = true }
    data object Import : Route { override val needsVault = true }
}

class Nav {
    val stack = mutableStateListOf<Route>(Route.Vaults)
    val top: Route get() = stack.last()
    fun push(r: Route) { stack.add(r) }
    fun pop() { if (stack.size > 1) stack.removeAt(stack.lastIndex) }
    fun reset(vararg routes: Route) {
        stack.clear()
        stack.addAll(routes)
    }
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

    MaterialTheme {
        // Exposes testTags as resource-ids so adb/uiautomator can drive the UI.
        Box(Modifier.semantics { testTagsAsResourceId = true }) {
            when (val r = nav.top) {
                Route.Vaults -> VaultPickerScreen(nav)
                Route.CreateVault -> CreateVaultScreen(nav)
                is Route.ShowSecretKey -> SecretKeyScreen(nav, r)
                is Route.Unlock -> UnlockScreen(nav, r.vaultName)
                Route.Items -> if (unlocked != null) ItemListScreen(nav)
                is Route.Detail -> if (unlocked != null) ItemDetailScreen(nav, r.id)
                is Route.Edit -> if (unlocked != null) ItemEditScreen(nav, r.id)
                Route.Generator -> GeneratorScreen(nav)
                Route.Export -> if (unlocked != null) ExportScreen(nav)
                Route.Import -> if (unlocked != null) ImportScreen(nav)
            }
        }
    }
}
