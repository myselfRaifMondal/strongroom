package app.strongroom.android.core

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import uniffi.strongroom.Vault

/**
 * The single unlocked vault of this process, if any. Shared by the UI and
 * the autofill service. Locking zeroizes keys in the core and drops the
 * native handle.
 */
object Session {
    @Volatile
    private var current: Vault? = null

    private val _unlockedName = MutableStateFlow<String?>(null)

    /** Name of the unlocked vault, or null when locked. */
    val unlockedName: StateFlow<String?> = _unlockedName

    /** Last vault the user unlocked in this process (for re-lock prompts). */
    @Volatile
    var lastVaultName: String? = null
        private set

    val vault: Vault? get() = current

    @Synchronized
    fun open(name: String, vault: Vault) {
        closeLocked()
        current = vault
        lastVaultName = name
        _unlockedName.value = name
    }

    @Synchronized
    fun lock() {
        closeLocked()
        _unlockedName.value = null
    }

    private fun closeLocked() {
        current?.let { v ->
            runCatching { v.lock() }
            runCatching { v.close() }
        }
        current = null
    }

    /** The unlocked vault or throws [IllegalStateException]. */
    fun require(): Vault = current ?: throw IllegalStateException("vault is locked")
}
