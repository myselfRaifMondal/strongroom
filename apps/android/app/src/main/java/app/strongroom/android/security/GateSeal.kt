package app.strongroom.android.security

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey

/** HMAC over the gate state. `null` when no tag can be made. */
fun interface GateMac {
    fun tag(message: ByteArray): ByteArray?
}

/**
 * HMAC-SHA256 key in Android Keystore (TEE), non-exportable and usable
 * without user authentication: the gate is read before any prompt. A copy of
 * the app's files alone cannot forge a tag.
 */
object KeystoreGateMac : GateMac {
    private const val ALIAS = "strongroom.gate.seal"
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"

    @Synchronized
    private fun key(): SecretKey {
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_HMAC_SHA256, ANDROID_KEYSTORE).run {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN).build())
            generateKey()
        }
    }

    override fun tag(message: ByteArray): ByteArray? = runCatching {
        Mac.getInstance("HmacSHA256").run {
            init(key())
            doFinal(message)
        }
    }.getOrNull()
}

/**
 * Integrity seal for one UnlockGate state file (threat model residual risk 3),
 * kept in a sibling file. The core file format and the FFI are unchanged.
 *
 * A state file with a missing or wrong seal is treated as tampered and
 * deleted; the core reads a missing file as "never unlocked with the
 * password", so the master password is required (fail closed). After each
 * gate write the state is sealed again; if that fails the seal is removed,
 * which also fails closed.
 *
 * Not covered: replaying an older state file together with its seal.
 */
class GateSeal(private val stateFile: File, private val sealFile: File, private val mac: GateMac) {

    /** Domain tag, then the state file's name, then its exact bytes. */
    private fun message(state: ByteArray): ByteArray =
        DOMAIN + stateFile.name.toByteArray(Charsets.UTF_8) + byteArrayOf(0) + state

    /** True when the state file is absent or carries a valid seal. */
    fun stateIsIntact(): Boolean {
        if (!stateFile.exists()) return true
        val state = runCatching { stateFile.readBytes() }.getOrNull() ?: return false
        val seal = runCatching { sealFile.readBytes() }.getOrNull() ?: return false
        val expected = mac.tag(message(state)) ?: return false
        return MessageDigest.isEqual(expected, seal)
    }

    /** Call before every gate read. */
    fun dropTamperedState() {
        if (!stateIsIntact()) {
            stateFile.delete()
            sealFile.delete()
        }
    }

    /** Call after every gate write. */
    fun reseal() {
        val ok = runCatching {
            val tag = mac.tag(message(stateFile.readBytes())) ?: return@runCatching false
            val tmp = File(sealFile.path + ".tmp")
            tmp.writeBytes(tag)
            tmp.renameTo(sealFile)
        }.getOrDefault(false)
        if (!ok) sealFile.delete()
    }

    private companion object {
        val DOMAIN = "strongroom-gate-seal-v1\u0000".toByteArray(Charsets.UTF_8)
    }
}
