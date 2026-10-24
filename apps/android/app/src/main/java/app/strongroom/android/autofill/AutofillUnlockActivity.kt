package app.strongroom.android.autofill

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.view.autofill.AutofillId
import android.view.autofill.AutofillManager
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Card
import app.strongroom.android.ui.StrongroomTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.core.content.IntentCompat
import androidx.fragment.app.FragmentActivity
import app.strongroom.android.core.Session
import app.strongroom.android.core.VaultFiles
import app.strongroom.android.ui.ScreenScaffold
import app.strongroom.android.ui.UnlockContent
import app.strongroom.android.ui.padding16

/** Unlock UI shown by the autofill framework when the vault is locked. */
class AutofillUnlockActivity : FragmentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val query = intent.getStringExtra(EXTRA_QUERY)
        val form = ParsedForm(
            packageName = intent.getStringExtra(EXTRA_PACKAGE),
            webDomain = intent.getStringExtra(EXTRA_WEB_DOMAIN),
            usernameId = IntentCompat.getParcelableExtra(intent, EXTRA_USERNAME_ID, AutofillId::class.java),
            passwordId = IntentCompat.getParcelableExtra(intent, EXTRA_PASSWORD_ID, AutofillId::class.java),
        )
        val vaults = VaultFiles(this).list()
        if (query == null || vaults.isEmpty()) {
            setResult(Activity.RESULT_CANCELED)
            finish()
            return
        }
        setContent {
            StrongroomTheme {
                var chosen by remember {
                    mutableStateOf(Session.lastVaultName?.takeIf { it in vaults } ?: vaults.singleOrNull())
                }
                val name = chosen
                if (name == null) {
                    ScreenScaffold(title = "Choose vault", onBack = null) {
                        vaults.forEach { v ->
                            Card(onClick = { chosen = v }, modifier = Modifier.fillMaxWidth()) {
                                Text(v, modifier = Modifier.padding16())
                            }
                        }
                    }
                } else {
                    UnlockContent(vaultName = name, onBack = null, onUnlocked = { deliver(query, form) })
                }
            }
        }
    }

    private fun deliver(query: String, form: ParsedForm) {
        val vault = Session.vault
        val response = vault?.let { AutofillDatasets.build(this, it, query, form) }
        if (response == null) {
            setResult(Activity.RESULT_CANCELED)
        } else {
            setResult(Activity.RESULT_OK, Intent().putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, response))
        }
        finish()
    }

    companion object {
        const val EXTRA_QUERY = "app.strongroom.android.autofill.QUERY"
        const val EXTRA_PACKAGE = "app.strongroom.android.autofill.PACKAGE"
        const val EXTRA_WEB_DOMAIN = "app.strongroom.android.autofill.WEB_DOMAIN"
        const val EXTRA_USERNAME_ID = "app.strongroom.android.autofill.USERNAME_ID"
        const val EXTRA_PASSWORD_ID = "app.strongroom.android.autofill.PASSWORD_ID"
    }
}
