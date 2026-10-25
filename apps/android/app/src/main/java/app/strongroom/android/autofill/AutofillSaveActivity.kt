package app.strongroom.android.autofill

import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.fragment.app.FragmentActivity
import app.strongroom.android.core.Clock
import app.strongroom.android.core.Session
import app.strongroom.android.core.VaultFiles
import app.strongroom.android.ui.OpStatus
import app.strongroom.android.ui.ScreenScaffold
import app.strongroom.android.ui.SecretField
import app.strongroom.android.ui.StrongroomTheme
import app.strongroom.android.ui.UnlockContent
import app.strongroom.android.ui.core
import app.strongroom.android.ui.padding16
import app.strongroom.android.ui.rememberOpState
import kotlinx.coroutines.launch

/**
 * Save UI started by the autofill framework after the user accepts "Save to
 * Strongroom". Unlocks the vault if needed and shows the title, username and
 * URL to confirm. Nothing is written until the user taps Save or Update.
 */
class AutofillSaveActivity : FragmentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val login = PendingSave.take(intent.getStringExtra(EXTRA_TOKEN))
        val vaults = VaultFiles(this).list()
        if (login == null) {
            finish()
            return
        }
        val appLabel = login.packageName?.let { pkg ->
            runCatching { packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString() }
                .getOrNull()
        }
        setContent {
            StrongroomTheme {
                var unlocked by remember { mutableStateOf(Session.vault != null) }
                var chosen by remember {
                    mutableStateOf(Session.lastVaultName?.takeIf { it in vaults } ?: vaults.singleOrNull())
                }
                val name = chosen
                when {
                    vaults.isEmpty() -> ScreenScaffold(title = "Save to Strongroom", onBack = ::finish) {
                        Text("Create a vault in Strongroom first.")
                        Button(onClick = ::finish) { Text("Close") }
                    }
                    unlocked -> ConfirmContent(login, appLabel)
                    name == null -> ScreenScaffold(title = "Choose vault", onBack = ::finish) {
                        vaults.forEach { v ->
                            Card(onClick = { chosen = v }, modifier = Modifier.fillMaxWidth()) {
                                Text(v, modifier = Modifier.padding16())
                            }
                        }
                    }
                    else -> UnlockContent(vaultName = name, onBack = ::finish, onUnlocked = { unlocked = true })
                }
            }
        }
    }

    @Composable
    private fun ConfirmContent(login: CapturedLogin, appLabel: String?) {
        val scope = rememberCoroutineScope()
        val op = rememberOpState()
        val query = remember { DomainQuery.of(login.webDomain, login.packageName) }
        var target by remember { mutableStateOf<SaveTarget?>(null) }
        var title by remember { mutableStateOf(SaveText.suggestedTitle(login.webDomain, appLabel, login.packageName)) }
        var username by remember { mutableStateOf(login.username.orEmpty()) }
        var url by remember { mutableStateOf(SaveText.urlFor(login.webDomain, login.packageName).orEmpty()) }
        var password by remember { mutableStateOf(login.password) }

        LaunchedEffect(Unit) {
            op.run {
                val vault = Session.require()
                val t = core { LoginSaver.findTarget(vault, query, login.username, login.password) }
                if (t is SaveTarget.Update) title = t.item.data.title
                target = t
            }
        }

        fun save(asNew: Boolean) {
            scope.launch {
                op.run {
                    val vault = Session.require()
                    val now = Clock.nowSeconds()
                    val t = target
                    if (!asNew && t is SaveTarget.Update) {
                        core { LoginSaver.update(vault, t.item, title, username, password, url, now) }
                    } else {
                        core { LoginSaver.addNew(vault, title, username, password, url, now) }
                    }
                    finish()
                }
            }
        }

        val t = target
        ScreenScaffold(
            title = if (t is SaveTarget.Update) "Update password" else "Save to Strongroom",
            onBack = ::finish,
        ) {
            when (t) {
                null -> Unit
                is SaveTarget.Unchanged -> {
                    Text("This login is already saved as \"${t.item.data.title}\".", modifier = Modifier.testTag("alreadySaved"))
                    Button(onClick = ::finish, modifier = Modifier.testTag("close")) { Text("Close") }
                }
                else -> {
                    if (t is SaveTarget.Update) {
                        Text(
                            "\"${t.item.data.title}\" has a different password. Updating keeps the old " +
                                "password in the item's history.",
                        )
                    }
                    OutlinedTextField(
                        value = title, onValueChange = { title = it }, label = { Text("Title") }, singleLine = true,
                        modifier = Modifier.fillMaxWidth().testTag("saveTitle"),
                    )
                    OutlinedTextField(
                        value = username, onValueChange = { username = it }, label = { Text("Username") }, singleLine = true,
                        modifier = Modifier.fillMaxWidth().testTag("saveUsername"),
                    )
                    OutlinedTextField(
                        value = url, onValueChange = { url = it }, label = { Text("Website or app") }, singleLine = true,
                        modifier = Modifier.fillMaxWidth().testTag("saveUrl"),
                    )
                    SecretField(value = password, onValueChange = { password = it }, label = "Password", tag = "savePassword")
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(
                            enabled = !op.busy && title.isNotBlank() && password.isNotEmpty(),
                            onClick = { save(asNew = false) },
                            modifier = Modifier.testTag("saveConfirm"),
                        ) { Text(if (t is SaveTarget.Update) "Update" else "Save") }
                        if (t is SaveTarget.Update) {
                            OutlinedButton(
                                enabled = !op.busy && title.isNotBlank() && password.isNotEmpty(),
                                onClick = { save(asNew = true) },
                                modifier = Modifier.testTag("saveAsNew"),
                            ) { Text("Save as new") }
                        }
                        TextButton(onClick = ::finish, modifier = Modifier.testTag("saveCancel")) { Text("Not now") }
                    }
                }
            }
            OpStatus(op)
        }
    }

    companion object {
        /** Random token for PendingSave; the login itself never travels in the Intent. */
        const val EXTRA_TOKEN = "app.strongroom.android.autofill.SAVE_TOKEN"
    }
}
