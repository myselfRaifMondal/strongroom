package app.strongroom.android

import android.app.Instrumentation
import android.os.Bundle
import android.util.Base64
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.strongroom.CustomField
import uniffi.strongroom.ItemInput
import uniffi.strongroom.ItemKind
import uniffi.strongroom.Vault
import uniffi.strongroom.generateSecretKey
import java.io.File

/**
 * Cross-platform round-trip probe (Phase 3): creates a throwaway vault on the
 * device, adds a fixed set of items, exports a VTF with the given password and
 * a freshly generated Secret Key, and streams the result back.
 *
 * Driven by scripts/export-vtf.sh. Arguments (instrumentation -e):
 *   passwordB64  base64 (UTF-8) master password for the throwaway vault
 *
 * Output lines:
 *   SR_EXPORT_SECRET_KEY <display form>
 *   SR_EXPORT_TITLE <title>        one per item, sorted
 *   SR_EXPORT_B64 <base64 chunk>   the .vtf, in order
 *   SR_EXPORT_DONE bytes=<n>
 *   SR_EXPORT_ERROR <ExceptionClass> <message>
 */
@RunWith(AndroidJUnit4::class)
class ExportVtfProbe {

    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    private fun emit(line: String) {
        val b = Bundle()
        b.putString(Instrumentation.REPORT_KEY_STREAMRESULT, line + "\n")
        instrumentation.sendStatus(0, b)
    }

    private fun arg(name: String): String? = InstrumentationRegistry.getArguments().getString(name)

    private fun item(title: String, kind: ItemKind = ItemKind.LOGIN, username: String? = null,
                     totp: String? = null, fields: List<CustomField> = emptyList()) = ItemInput(
        kind = kind,
        title = title,
        username = username,
        password = if (kind == ItemKind.LOGIN) "android-probe-item-password" else null,
        urls = if (kind == ItemKind.LOGIN) listOf("https://example.com/") else emptyList(),
        notes = if (kind == ItemKind.SECURE_NOTE) "exported on Android" else null,
        totp = totp,
        folder = "Round-trip",
        tags = listOf("android"),
        fields = fields,
        travelSafe = false,
    )

    @Test
    fun exportFixedItems() {
        val pwB64 = arg("passwordB64")
        assumeTrue("no -e passwordB64 given; probe skipped", pwB64 != null)
        val password = String(Base64.decode(pwB64, Base64.DEFAULT), Charsets.UTF_8)
        val context = instrumentation.targetContext
        val tmp = File(context.cacheDir, "export-probe-${System.currentTimeMillis()}.srvault")
        try {
            val now = System.currentTimeMillis() / 1000
            val secretKey = generateSecretKey()
            check(secretKey.isNotBlank()) { "core returned an empty Secret Key" }
            Vault.create(tmp.absolutePath, password, secretKey, now).use { vault ->
                val items = listOf(
                    item("Android: Example Login", username = "alice@example.com", totp = "JBSWY3DPEHPK3PXP"),
                    item("Android: Ünïcödé ✓ note", kind = ItemKind.SECURE_NOTE),
                    item("Android: API key", kind = ItemKind.API_KEY,
                        fields = listOf(CustomField("token", "tok_probe_0000", true))),
                )
                items.forEach { vault.addItem(it, now) }
                val bytes = vault.exportVtf(password, secretKey, emptyList(), now)
                emit("SR_EXPORT_SECRET_KEY $secretKey")
                vault.search("", null, null).map { it.title }.sorted().forEach { emit("SR_EXPORT_TITLE $it") }
                Base64.encodeToString(bytes, Base64.NO_WRAP).chunked(3000).forEach { emit("SR_EXPORT_B64 $it") }
                emit("SR_EXPORT_DONE bytes=${bytes.size}")
                vault.lock()
            }
        } catch (e: Exception) {
            Log.e("SR_EXPORT", "export probe failed", e)
            emit("SR_EXPORT_ERROR ${e::class.java.name} ${e.message}")
            throw e
        } finally {
            tmp.parentFile?.listFiles { f -> f.name.startsWith(tmp.name) }?.forEach { it.delete() }
        }
    }
}
