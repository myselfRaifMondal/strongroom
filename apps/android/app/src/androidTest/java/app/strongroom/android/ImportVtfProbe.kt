package app.strongroom.android

import android.app.Instrumentation
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.util.Base64
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.strongroom.Vault
import uniffi.strongroom.generateSecretKey
import uniffi.strongroom.vtfInspect
import java.io.File

/**
 * Cross-platform round-trip probe (Phase 3): imports a given .vtf into a fresh
 * throwaway vault on the device and prints the imported item titles.
 *
 * Driven by scripts/import-vtf.sh. Arguments (instrumentation -e):
 *   vtf          device path of the .vtf (read via the shell, e.g. /data/local/tmp/x.vtf)
 *   passwordB64  base64 (UTF-8) master password of the exporting vault
 *   secretKeyB64 base64 (UTF-8) Secret Key of the exporting vault
 *
 * Output lines (also in logcat, tag SR_IMPORT):
 *   SR_IMPORT_INFO version=.. password_slots=.. device_slots=.. chunks=..
 *   SR_IMPORT_SUMMARY added=.. updated=.. unchanged=.. conflicts=..
 *   SR_IMPORT_TITLE <title>
 *   SR_IMPORT_ERROR <ExceptionClass> <message>
 */
@RunWith(AndroidJUnit4::class)
class ImportVtfProbe {

    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    private fun emit(line: String) {
        Log.i("SR_IMPORT", line)
        val b = Bundle()
        b.putString(Instrumentation.REPORT_KEY_STREAMRESULT, line + "\n")
        instrumentation.sendStatus(0, b)
    }

    private fun arg(name: String): String? = InstrumentationRegistry.getArguments().getString(name)

    private fun b64(name: String): String =
        String(Base64.decode(arg(name) ?: error("missing -e $name"), Base64.DEFAULT), Charsets.UTF_8)

    /** Reads a file the app itself may not access (e.g. /data/local/tmp) as the shell user. */
    private fun readAsShell(path: String): ByteArray {
        val pfd: ParcelFileDescriptor = instrumentation.uiAutomation.executeShellCommand("cat $path")
        return ParcelFileDescriptor.AutoCloseInputStream(pfd).use { it.readBytes() }
    }

    @Test
    fun importAndListTitles() {
        val vtfPath = arg("vtf")
        assumeTrue("no -e vtf given; probe skipped", vtfPath != null)
        val context = instrumentation.targetContext
        val tmp = File(context.cacheDir, "probe-${System.currentTimeMillis()}.srvault")
        try {
            val bytes = readAsShell(vtfPath!!)
            check(bytes.isNotEmpty()) { "empty or unreadable file: $vtfPath" }
            val now = System.currentTimeMillis() / 1000
            runCatching { vtfInspect(bytes) }
                .onSuccess {
                    emit("SR_IMPORT_INFO version=${it.version} password_slots=${it.passwordSlots} " +
                        "device_slots=${it.deviceSlots} chunks=${it.chunkCount}")
                }
                .onFailure { emit("SR_IMPORT_INFO unavailable: ${it::class.java.simpleName} ${it.message}") }

            val probeSecret = generateSecretKey()
            check(probeSecret.isNotBlank()) { "core returned an empty Secret Key" }
            Vault.create(tmp.absolutePath, "probe-" + java.util.UUID.randomUUID(), probeSecret, now).use { vault ->
                val s = vault.importVtf(bytes, b64("passwordB64"), b64("secretKeyB64"), now)
                emit("SR_IMPORT_SUMMARY added=${s.added} updated=${s.updated} unchanged=${s.unchanged} conflicts=${s.conflicts}")
                vault.search("", null, null).map { it.title }.sorted().forEach { emit("SR_IMPORT_TITLE $it") }
                vault.lock()
            }
        } catch (e: Exception) {
            emit("SR_IMPORT_ERROR ${e::class.java.name} ${e.message}")
            throw e
        } finally {
            tmp.parentFile?.listFiles { f -> f.name.startsWith(tmp.name) }?.forEach { it.delete() }
        }
    }
}
