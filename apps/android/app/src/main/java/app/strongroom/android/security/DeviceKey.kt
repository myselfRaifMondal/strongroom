package app.strongroom.android.security

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.security.keystore.UserNotAuthenticatedException
import android.util.Log
import androidx.annotation.RequiresApi
import uniffi.strongroom.DeviceKeyAgreement
import uniffi.strongroom.StrongroomException
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import javax.crypto.KeyAgreement

/**
 * OQ-1: hardware ECDH (KeyProperties.PURPOSE_AGREE_KEY) exists from API 31.
 * Below that, device-bound export/import and biometric unlock are disabled.
 */
object DeviceKeySupport {
    const val MIN_API = Build.VERSION_CODES.S // 31

    val supported: Boolean get() = Build.VERSION.SDK_INT >= MIN_API

    const val UNSUPPORTED_MESSAGE =
        "Requires Android 12 (API 31) or newer: this Android version cannot perform the " +
            "key agreement inside secure hardware. Password unlock and password-protected " +
            "export/import still work."
}

enum class KeyState { VALID, MISSING, INVALIDATED }

/**
 * Non-exportable P-256 key in Android Keystore (StrongBox when present),
 * usable only for ECDH and only right after a strong biometric.
 *
 * Per-use (timeout 0) auth needs a BiometricPrompt.CryptoObject, and no public
 * API before 35 wraps a KeyAgreement in one. The key therefore uses a short
 * auth validity window ([AUTH_VALIDITY_SECONDS]) and the app shows a
 * BiometricPrompt immediately before every single use (see OQ-9).
 */
@RequiresApi(31)
class DeviceKey(private val context: Context, val alias: String) {

    private val keyStore: KeyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    fun exists(): Boolean = keyStore.containsAlias(alias)

    /** Creates the key if absent; returns its 65-byte SEC1 public key. */
    fun ensure(): ByteArray {
        if (!exists()) generate()
        return publicKey()
    }

    fun publicKey(): ByteArray {
        val pub = keyStore.getCertificate(alias)?.publicKey as? ECPublicKey
            ?: throw IllegalStateException("device key missing")
        return Sec1.encode(pub.w.affineX, pub.w.affineY)
    }

    fun delete() {
        if (exists()) keyStore.deleteEntry(alias)
    }

    /** "StrongBox", "TEE" or "software" (the latter must not happen on real devices). */
    fun securityLevel(): String = runCatching {
        val key = privateKey()
        val info = KeyFactory.getInstance(key.algorithm, ANDROID_KEYSTORE)
            .getKeySpec(key, KeyInfo::class.java)
        when (info.securityLevel) {
            KeyProperties.SECURITY_LEVEL_STRONGBOX -> "StrongBox"
            KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT -> "TEE"
            KeyProperties.SECURITY_LEVEL_SOFTWARE -> "software"
            else -> "unknown"
        }
    }.getOrDefault("unknown")

    /**
     * Detects biometric enrollment changes: Keystore throws
     * KeyPermanentlyInvalidatedException for a key created with
     * setInvalidatedByBiometricEnrollment(true) once the enrolled set changes.
     */
    fun state(): KeyState {
        if (!exists()) return KeyState.MISSING
        return try {
            KeyAgreement.getInstance("ECDH", ANDROID_KEYSTORE).init(privateKey())
            KeyState.VALID
        } catch (e: KeyPermanentlyInvalidatedException) {
            KeyState.INVALIDATED
        } catch (e: UserNotAuthenticatedException) {
            KeyState.VALID // valid key, just not authenticated right now
        } catch (e: Exception) {
            Log.w(TAG, "device key probe failed: ${e::class.java.simpleName}")
            KeyState.VALID
        }
    }

    /** Raw ECDH x-coordinate with [peer] (65-byte SEC1). Requires a fresh biometric. */
    fun agree(peer: ByteArray): ByteArray {
        val own = keyStore.getCertificate(alias).publicKey as ECPublicKey
        val (x, y) = Sec1.decode(peer)
        val peerKey = KeyFactory.getInstance("EC")
            .generatePublic(ECPublicKeySpec(ECPoint(x, y), own.params))
        val ka = KeyAgreement.getInstance("ECDH", ANDROID_KEYSTORE)
        ka.init(privateKey())
        ka.doPhase(peerKey, true)
        return ka.generateSecret()
    }

    private fun privateKey(): PrivateKey =
        keyStore.getKey(alias, null) as? PrivateKey ?: throw IllegalStateException("device key missing")

    private fun generate() {
        val strongBox = context.packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)
        if (strongBox) {
            try {
                generate(strongBox = true)
                return
            } catch (e: StrongBoxUnavailableException) {
                Log.i(TAG, "StrongBox unavailable for ECDH; falling back to TEE")
            } catch (e: java.security.ProviderException) {
                Log.i(TAG, "StrongBox rejected the key spec; falling back to TEE")
            }
        }
        generate(strongBox = false)
    }

    private fun generate(strongBox: Boolean) {
        val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_AGREE_KEY)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setUserAuthenticationRequired(true)
            .setUserAuthenticationParameters(AUTH_VALIDITY_SECONDS, KeyProperties.AUTH_BIOMETRIC_STRONG)
            .setInvalidatedByBiometricEnrollment(true)
            .setIsStrongBoxBacked(strongBox)
            .build()
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, ANDROID_KEYSTORE).run {
            initialize(spec)
            generateKeyPair()
        }
    }

    companion object {
        private const val TAG = "StrongroomDeviceKey"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"

        /** Seconds the key stays usable after one strong biometric. */
        const val AUTH_VALIDITY_SECONDS = 10
    }
}

/**
 * [DeviceKeyAgreement] callback handed to the Rust core. Any failure maps to
 * UnlockFailed so the core and UI never learn why the hardware refused.
 */
@RequiresApi(31)
class KeystoreDeviceKeyAgreement(private val key: DeviceKey) : DeviceKeyAgreement {
    override fun publicKey(): ByteArray = key.publicKey()

    override fun agree(peerPublicKey: ByteArray): ByteArray = try {
        key.agree(peerPublicKey)
    } catch (e: Exception) {
        Log.w("StrongroomDeviceKey", "agree failed: ${e::class.java.simpleName}")
        throw StrongroomException.UnlockFailed()
    }
}
