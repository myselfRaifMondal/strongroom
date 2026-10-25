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
import android.service.autofill.SaveInfo
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
        walk(structure) { node, type ->
            node.webDomain?.let { if (webDomain == null) webDomain = it }
            when (type) {
                FieldType.USERNAME -> if (user == null) user = node.autofillId
                FieldType.PASSWORD -> if (pass == null) pass = node.autofillId
                FieldType.OTHER -> Unit
            }
        }
        return ParsedForm(structure.activityComponent?.packageName, webDomain, user, pass)
    }

    /**
     * The login typed into the screens of a save request (oldest first, so a
     * username page followed by a password page works). Null when no
     * password was typed.
     */
    fun capture(structures: List<AssistStructure>): CapturedLogin? {
        var webDomain: String? = null
        var username: String? = null
        val passwords = mutableListOf<String>()
        for (structure in structures) {
            walk(structure) { node, type ->
                node.webDomain?.let { webDomain = it }
                val text = node.autofillValue?.takeIf { it.isText }?.textValue?.toString()
                if (text.isNullOrEmpty()) return@walk
                when (type) {
                    FieldType.USERNAME -> username = text
                    FieldType.PASSWORD -> passwords += text
                    FieldType.OTHER -> Unit
                }
            }
        }
        val password = SaveText.choosePassword(passwords) ?: return null
        val pkg = structures.lastOrNull()?.activityComponent?.packageName
        return CapturedLogin(pkg, webDomain, username, password)
    }

    /** Calls [visit] for every node that has an autofill id, with its field type. */
    private fun walk(structure: AssistStructure, visit: (AssistStructure.ViewNode, FieldType) -> Unit) {
        fun go(node: AssistStructure.ViewNode) {
            if (node.autofillId != null) {
                val attrs = node.htmlInfo?.attributes.orEmpty().associate { it.first.lowercase() to it.second }
                visit(
                    node,
                    FieldClassifier.classify(
                        node.autofillHints?.toList().orEmpty(),
                        node.inputType,
                        node.idEntry,
                        node.hint,
                        attrs["type"],
                        attrs["name"],
                    ),
                )
            } else {
                node.webDomain?.let { visit(node, FieldType.OTHER) }
            }
            for (i in 0 until node.childCount) go(node.getChildAt(i))
        }
        for (i in 0 until structure.windowNodeCount) go(structure.getWindowNodeAt(i).rootViewNode)
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
        val save = saveInfo(form)
        if (save != null) builder.setSaveInfo(save)
        return if (count == 0 && save == null) null else builder.build()
    }

    /**
     * Asks the framework to offer "Save to Strongroom" when a password was
     * typed. Saving always goes through AutofillSaveActivity, which asks
     * the user first.
     */
    fun saveInfo(form: ParsedForm): SaveInfo? {
        val pass = form.passwordId ?: return null
        val builder = SaveInfo.Builder(SaveInfo.SAVE_DATA_TYPE_USERNAME or SaveInfo.SAVE_DATA_TYPE_PASSWORD, arrayOf(pass))
        form.usernameId?.let { builder.setOptionalIds(arrayOf(it)) }
        // Apps often hide the form instead of finishing the activity.
        builder.setFlags(SaveInfo.FLAG_SAVE_ON_ALL_VIEWS_INVISIBLE)
        return builder.build()
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
        AutofillDatasets.saveInfo(form)?.let { response.setSaveInfo(it) }
        callback.onSuccess(response.build())
    }

    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) {
        val captured = StructureParser.capture(request.fillContexts.map { it.structure })
        if (captured == null || captured.packageName == packageName) {
            callback.onFailure(getString(R.string.autofill_nothing_to_save))
            return
        }
        // Nothing is written here: the activity asks the user (unlocking
        // first if needed) and only then adds or updates the item.
        val intent = Intent(this, AutofillSaveActivity::class.java)
            .putExtra(AutofillSaveActivity.EXTRA_TOKEN, PendingSave.put(captured))
        // Started directly: a bound AutofillService may start an activity
        // from the background. onSuccess(IntentSender) was tried and the
        // framework's send is blocked as a background start on API 34.
        startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        callback.onSuccess()
    }

    companion object {
        private const val REQUEST_UNLOCK = 1
    }
}
