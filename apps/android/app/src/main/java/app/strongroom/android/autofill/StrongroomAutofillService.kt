package app.strongroom.android.autofill

import android.app.PendingIntent
import android.app.assist.AssistStructure
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.CancellationSignal
import android.service.autofill.AutofillService
import android.service.autofill.Dataset
import android.service.autofill.FillCallback
import android.service.autofill.FillRequest
import android.service.autofill.FillResponse
import android.service.autofill.SaveCallback
import android.service.autofill.SaveRequest
import android.util.Log
import android.view.autofill.AutofillId
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import app.strongroom.android.R
import app.strongroom.android.core.Session
import uniffi.strongroom.Vault

/** Parsed login form of the app/page being filled. */
data class ParsedForm(
    val packageName: String?,
    val webDomain: String?,
    val usernameId: AutofillId?,
    val passwordId: AutofillId?,
) {
    val ids: Array<AutofillId> get() = listOfNotNull(usernameId, passwordId).toTypedArray()
}

object StructureParser {
    fun parse(structure: AssistStructure): ParsedForm {
        var webDomain: String? = null
        var user: AutofillId? = null
        var pass: AutofillId? = null
        fun visit(node: AssistStructure.ViewNode) {
            node.webDomain?.let { if (webDomain == null) webDomain = it }
            val id = node.autofillId
            if (id != null) {
                val attrs = node.htmlInfo?.attributes.orEmpty().associate { it.first.lowercase() to it.second }
                when (FieldClassifier.classify(
                    node.autofillHints?.toList().orEmpty(),
                    node.inputType,
                    node.idEntry,
                    node.hint,
                    attrs["type"],
                    attrs["name"],
                )) {
                    FieldType.USERNAME -> if (user == null) user = id
                    FieldType.PASSWORD -> if (pass == null) pass = id
                    FieldType.OTHER -> Unit
                }
            }
            for (i in 0 until node.childCount) visit(node.getChildAt(i))
        }
        for (i in 0 until structure.windowNodeCount) visit(structure.getWindowNodeAt(i).rootViewNode)
        return ParsedForm(structure.activityComponent?.packageName, webDomain, user, pass)
    }
}

object AutofillDatasets {
    private const val MAX = 5

    /** Datasets for [query] from the unlocked [vault]; null when nothing matches. */
    @Suppress("DEPRECATION") // Dataset.Builder(RemoteViews)/setValue: replacements are API 33+.
    fun build(context: Context, vault: Vault, query: String, form: ParsedForm): FillResponse? {
        val matches = runCatching { vault.matchDomain(query) }
            .onFailure { Log.w(TAG, "matchDomain failed: ${it::class.java.simpleName}") }
            .getOrNull().orEmpty()
        val builder = FillResponse.Builder()
        var count = 0
        for (summary in matches.take(MAX)) {
            val item = runCatching { vault.getItem(summary.id) }.getOrNull() ?: continue
            val presentation = presentation(context, item.data.title + (item.data.username?.let { " ($it)" } ?: ""))
            val ds = Dataset.Builder(presentation)
            var any = false
            val u = item.data.username
            val p = item.data.password
            if (form.usernameId != null && u != null) { ds.setValue(form.usernameId, AutofillValue.forText(u)); any = true }
            if (form.passwordId != null && p != null) { ds.setValue(form.passwordId, AutofillValue.forText(p)); any = true }
            if (any) { builder.addDataset(ds.build()); count++ }
        }
        return if (count == 0) null else builder.build()
    }

    fun presentation(context: Context, text: String): RemoteViews =
        RemoteViews(context.packageName, android.R.layout.simple_list_item_1).apply {
            setTextViewText(android.R.id.text1, text)
        }

    private const val TAG = "StrongroomAutofill"
}

class StrongroomAutofillService : AutofillService() {

    @Suppress("DEPRECATION") // setAuthentication(ids, sender, RemoteViews): replacement is API 33+.
    override fun onFillRequest(request: FillRequest, cancellationSignal: CancellationSignal, callback: FillCallback) {
        val structure = request.fillContexts.lastOrNull()?.structure ?: return callback.onSuccess(null)
        val form = StructureParser.parse(structure)
        if (form.ids.isEmpty() || form.packageName == packageName) return callback.onSuccess(null)
        val query = DomainQuery.of(form.webDomain, form.packageName) ?: return callback.onSuccess(null)

        val vault = Session.vault
        if (vault != null) {
            callback.onSuccess(AutofillDatasets.build(this, vault, query, form))
            return
        }
        // Locked: offer one "Unlock Strongroom" entry that opens the unlock UI.
        val intent = Intent(this, AutofillUnlockActivity::class.java)
            .putExtra(AutofillUnlockActivity.EXTRA_QUERY, query)
            .putExtra(AutofillUnlockActivity.EXTRA_PACKAGE, form.packageName)
            .putExtra(AutofillUnlockActivity.EXTRA_WEB_DOMAIN, form.webDomain)
            .putExtra(AutofillUnlockActivity.EXTRA_USERNAME_ID, form.usernameId)
            .putExtra(AutofillUnlockActivity.EXTRA_PASSWORD_ID, form.passwordId)
        // The framework adds extras to this intent, so it must be mutable (explicit target).
        val flags = PendingIntent.FLAG_CANCEL_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
        val sender = PendingIntent.getActivity(this, REQUEST_UNLOCK, intent, flags).intentSender
        val response = FillResponse.Builder()
            .setAuthentication(form.ids, sender, AutofillDatasets.presentation(this, getString(R.string.autofill_unlock)))
            .build()
        callback.onSuccess(response)
    }

    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) {
        // No SaveInfo is ever requested, so this is not expected to be called.
        callback.onFailure("Strongroom does not save from autofill yet")
    }

    companion object {
        private const val REQUEST_UNLOCK = 1
    }
}
