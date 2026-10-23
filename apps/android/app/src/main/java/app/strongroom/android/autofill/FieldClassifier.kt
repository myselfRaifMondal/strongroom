package app.strongroom.android.autofill

import android.text.InputType

enum class FieldType { USERNAME, PASSWORD, OTHER }

/** Pure field heuristics (unit-tested); no framework objects. */
object FieldClassifier {
    private val USER_WORDS = listOf("user", "email", "e-mail", "login", "account", "identifier")
    private val PASS_WORDS = listOf("pass", "pwd", "pin")

    fun isPasswordInputType(inputType: Int): Boolean {
        val cls = inputType and InputType.TYPE_MASK_CLASS
        val variation = inputType and InputType.TYPE_MASK_VARIATION
        return (cls == InputType.TYPE_CLASS_TEXT && variation in setOf(
            InputType.TYPE_TEXT_VARIATION_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
        )) || (cls == InputType.TYPE_CLASS_NUMBER && variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD)
    }

    private fun isEmailInputType(inputType: Int): Boolean {
        val cls = inputType and InputType.TYPE_MASK_CLASS
        val variation = inputType and InputType.TYPE_MASK_VARIATION
        return cls == InputType.TYPE_CLASS_TEXT && (variation == InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS ||
            variation == InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS)
    }

    fun classify(
        autofillHints: List<String>,
        inputType: Int,
        idEntry: String?,
        hint: String?,
        htmlType: String?,
        htmlName: String?,
    ): FieldType {
        val hints = autofillHints.map { it.lowercase() }
        if (hints.any { it.contains("password") }) return FieldType.PASSWORD
        if (hints.any { it == "username" || it == "emailaddress" || it.contains("email") || it.contains("username") }) {
            return FieldType.USERNAME
        }
        if (htmlType.equals("password", ignoreCase = true) || isPasswordInputType(inputType)) return FieldType.PASSWORD
        if (htmlType.equals("email", ignoreCase = true) || isEmailInputType(inputType)) return FieldType.USERNAME
        val text = listOfNotNull(idEntry, hint, htmlName).joinToString(" ").lowercase()
        if (text.isEmpty()) return FieldType.OTHER
        if (PASS_WORDS.any { text.contains(it) }) return FieldType.PASSWORD
        if (USER_WORDS.any { text.contains(it) }) return FieldType.USERNAME
        return FieldType.OTHER
    }
}

/** What to ask Vault.match_domain for: the web domain, else the app package. */
object DomainQuery {
    fun of(webDomain: String?, packageName: String?): String? {
        val web = webDomain?.trim()?.lowercase()
        if (!web.isNullOrEmpty()) return web
        val pkg = packageName?.trim()
        return if (pkg.isNullOrEmpty()) null else pkg
    }
}
