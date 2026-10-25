package app.strongroom.android.autofill

import android.os.SystemClock
import uniffi.strongroom.Item
import uniffi.strongroom.ItemInput
import uniffi.strongroom.ItemKind
import uniffi.strongroom.Vault
import java.security.MessageDigest
import java.security.SecureRandom

/** A login the user just submitted, as captured from an autofill save request. */
class CapturedLogin(
    val packageName: String?,
    val webDomain: String?,
    val username: String?,
    val password: String,
)

/**
 * Holds at most one captured login in this process's memory while the save
 * activity asks the user. The password is never put in an Intent, Bundle,
 * log or file: the activity gets only a random token. Taking the login
 * removes it; it also expires after [TTL_MS].
 */
object PendingSave {
    private const val TTL_MS = 10 * 60 * 1000L
    private val random = SecureRandom()
    private var token: String? = null
    private var login: CapturedLogin? = null
    private var createdAt = 0L

    @Synchronized
    fun put(captured: CapturedLogin): String {
        val bytes = ByteArray(16).also { random.nextBytes(it) }
        val t = bytes.joinToString("") { "%02x".format(it) }
        token = t
        login = captured
        createdAt = SystemClock.elapsedRealtime()
        return t
    }

    /** The login for [t], once. Null when the token is wrong, used or expired. */
    @Synchronized
    fun take(t: String?): CapturedLogin? {
        val want = token
        val ok = t != null && want != null &&
            MessageDigest.isEqual(t.toByteArray(), want.toByteArray()) &&
            SystemClock.elapsedRealtime() - createdAt <= TTL_MS
        val out = if (ok) login else null
        if (ok) clear()
        return out
    }

    @Synchronized
    fun clear() {
        token = null
        login = null
    }
}

/** Pure helpers for the save flow (unit-tested). */
object SaveText {
    /** The URL stored on a new item: the site, else the app as androidapp://package. */
    fun urlFor(webDomain: String?, packageName: String?): String? {
        val web = webDomain?.trim()?.lowercase()
        if (!web.isNullOrEmpty()) return "https://$web"
        val pkg = packageName?.trim()
        return if (pkg.isNullOrEmpty()) null else "androidapp://$pkg"
    }

    /** Default title: the site without "www.", else the app's label, else the package. */
    fun suggestedTitle(webDomain: String?, appLabel: String?, packageName: String?): String {
        val web = webDomain?.trim()?.lowercase()?.removePrefix("www.")
        return when {
            !web.isNullOrEmpty() -> web
            !appLabel.isNullOrBlank() -> appLabel.trim()
            else -> packageName?.trim().orEmpty()
        }
    }

    /**
     * The password to save from the non-empty password fields of a form, in
     * screen order. On a change-password form (current, new, confirm) the
     * new one comes last, so the last value wins.
     */
    fun choosePassword(values: List<String>): String? = values.lastOrNull { it.isNotEmpty() }

    fun sameUsername(a: String?, b: String?): Boolean =
        a?.trim().orEmpty().equals(b?.trim().orEmpty(), ignoreCase = true)
}

/** What saving a captured login would do to the vault. */
sealed interface SaveTarget {
    /** No login for this site and username: add a new item. */
    data object New : SaveTarget

    /** A login exists with another password: update it (the core keeps the old one in history). */
    data class Update(val item: Item) : SaveTarget

    /** The same login is already saved. */
    data class Unchanged(val item: Item) : SaveTarget
}

object LoginSaver {
    /** Finds the existing login for [query] and [username], if any. */
    fun findTarget(vault: Vault, query: String?, username: String?, password: String): SaveTarget {
        if (query == null) return SaveTarget.New
        val logins = runCatching { vault.matchDomain(query) }.getOrNull().orEmpty()
            .filter { it.kind == ItemKind.LOGIN }
            .mapNotNull { runCatching { vault.getItem(it.id) }.getOrNull() }
        val same = logins.filter { SaveText.sameUsername(it.data.username, username) }
        val item = same.firstOrNull { it.data.password == password } ?: same.firstOrNull()
            ?: return SaveTarget.New
        return if (item.data.password == password) SaveTarget.Unchanged(item) else SaveTarget.Update(item)
    }

    fun addNew(vault: Vault, title: String, username: String?, password: String, url: String?, now: Long): String =
        vault.addItem(
            ItemInput(
                kind = ItemKind.LOGIN,
                title = title.trim(),
                username = username?.trim()?.ifEmpty { null },
                password = password,
                urls = listOfNotNull(url?.trim()?.ifEmpty { null }),
                notes = null,
                totp = null,
                folder = null,
                tags = emptyList(),
                fields = emptyList(),
                travelSafe = false,
            ),
            now,
        )

    /**
     * Sets the new password (and the confirmed title and username) on [item].
     * Vault.update_item moves the previous state, with the old password, to
     * the item's history. [url] is added when the item does not list it.
     */
    fun update(vault: Vault, item: Item, title: String, username: String?, password: String, url: String?, now: Long) {
        val u = url?.trim()?.ifEmpty { null }
        val urls = if (u == null || u in item.data.urls) item.data.urls else item.data.urls + u
        vault.updateItem(
            item.id,
            item.data.copy(
                title = title.trim().ifEmpty { item.data.title },
                username = username?.trim()?.ifEmpty { null },
                password = password,
                urls = urls,
            ),
            now,
        )
    }
}
