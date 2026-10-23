package app.strongroom.android.core

import android.content.Context
import java.io.File

/** On-device layout. Everything lives in app-private storage (no backup). */
class VaultFiles(context: Context) {
    private val root = context.filesDir
    private val vaultDir = File(root, "vaults").apply { mkdirs() }
    private val gateDir = File(root, "gate").apply { mkdirs() }
    private val deviceDir = File(root, "devicekeys").apply { mkdirs() }

    fun list(): List<String> =
        vaultDir.listFiles { f -> f.isFile && f.name.endsWith(EXT) }
            ?.map { it.name.removeSuffix(EXT) }
            ?.sorted()
            .orEmpty()

    fun vaultPath(name: String): String = File(vaultDir, name + EXT).absolutePath
    fun exists(name: String): Boolean = File(vaultPath(name)).exists()
    fun gateStatePath(name: String): String = File(gateDir, "$name.state").absolutePath

    /** HPKE-wrapped vault key for this device; safe at rest per the contract. */
    fun wrappedKeyFile(name: String): File = File(deviceDir, "$name.wrapped")

    companion object {
        const val EXT = ".srvault"
        private val NAME = Regex("^[A-Za-z0-9 _-]{1,40}$")

        fun validName(name: String): Boolean = NAME.matches(name) && name.isNotBlank()
        fun deviceKeyAlias(name: String): String = "strongroom.device.$name"
    }
}
