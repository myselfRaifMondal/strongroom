package app.strongroom.android.ui

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.fragment.app.FragmentActivity
import app.strongroom.android.StrongroomApp
import app.strongroom.android.core.Clock
import app.strongroom.android.core.Session
import app.strongroom.android.core.VaultFiles
import app.strongroom.android.core.VaultUnlocker
import app.strongroom.android.core.explanation
import app.strongroom.android.core.userMessage
import app.strongroom.android.security.BiometricResult
import app.strongroom.android.security.Biometrics
import app.strongroom.android.security.DeviceKeySupport
import kotlinx.coroutines.launch
import uniffi.strongroom.PasswordRequiredReason
import uniffi.strongroom.Vault
import uniffi.strongroom.estimateStrength
import uniffi.strongroom.generateSecretKey

const val NO_RECOVERY_WARNING =
    "Strongroom has no account and no recovery. If you lose your master password or your " +
        "Secret Key, everything in this vault is lost permanently. Nobody, including the " +
        "developers, can recover it."

@Composable
fun VaultPickerScreen(nav: Nav) {
    val context = LocalContext.current
    val files = remember { VaultFiles(context) }
    val names = remember(nav.stack.size) { files.list() }
    ScreenScaffold(title = "Strongroom", onBack = null) {
        Text("Vaults on this device", style = MaterialTheme.typography.titleMedium)
        if (names.isEmpty()) Text("No vaults yet.")
        names.forEach { name ->
            Card(
                onClick = { nav.push(Route.Unlock(name)) },
                modifier = Modifier.fillMaxWidth().testTag("vault_$name"),
            ) { Text(name, modifier = Modifier.padding16()) }
        }
        Button(onClick = { nav.push(Route.CreateVault) }, modifier = Modifier.testTag("createVault")) {
            Text("Create a new vault")
        }
        OutlinedButton(onClick = { nav.push(Route.Generator) }, modifier = Modifier.testTag("openGenerator")) {
            Text("Password generator")
        }
    }
}

@Composable
fun CreateVaultScreen(nav: Nav) {
    val context = LocalContext.current
    val files = remember { VaultFiles(context) }
    val scope = rememberCoroutineScope()
    val op = rememberOpState()
    var name by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf("") }
    val strength = remember(password) {
        if (password.isEmpty()) null else runCatching { estimateStrength(password) }.getOrNull()
    }

    ScreenScaffold(title = "Create vault", onBack = { nav.pop() }) {
        Warning(NO_RECOVERY_WARNING, tag = "noRecoveryWarning")
        PlainField(name, { name = it }, "Vault name", "vaultName")
        SecretField(password, { password = it }, "Master password", "masterPassword")
        strength?.let {
            LinearProgressIndicator(progress = { (it.score.toInt() + 1) / 5f }, modifier = Modifier.fillMaxWidth())
            Text("Strength ${it.score}/4, ~${it.entropyBits.toInt()} bits" +
                if (it.warnings.isNotEmpty()) " - " + it.warnings.joinToString("; ") else "")
        }
        SecretField(confirm, { confirm = it }, "Confirm master password", "confirmPassword")
        Button(
            enabled = !op.busy && name.isNotBlank() && password.isNotEmpty() && password == confirm,
            modifier = Modifier.testTag("createVaultSubmit"),
            onClick = {
                scope.launch {
                    op.run {
                        val n = name.trim()
                        require(VaultFiles.validName(n)) { "Use 1-40 letters, digits, spaces, '-' or '_' for the name." }
                        check(!files.exists(n)) { "A vault named \"$n\" already exists." }
                        val secretKey = generateSecretKey()
                        check(secretKey.isNotBlank()) { "The core returned no Secret Key (core not implemented yet)." }
                        val vault = core { Vault.create(files.vaultPath(n), password, secretKey, Clock.nowSeconds()) }
                        VaultUnlocker(context, n).recordPasswordUnlock()
                        Session.open(n, vault)
                        password = ""
                        confirm = ""
                        nav.reset(Route.Vaults, Route.ShowSecretKey(n, secretKey))
                    }
                }
            },
        ) { Text("Create vault") }
        if (password.isNotEmpty() && confirm.isNotEmpty() && password != confirm) {
            Text("Passwords do not match.", color = MaterialTheme.colorScheme.error)
        }
        OpStatus(op)
    }
}

@Composable
fun SecretKeyScreen(nav: Nav, route: Route.ShowSecretKey) {
    val app = LocalContext.current.applicationContext as StrongroomApp
    var acknowledged by remember { mutableStateOf(false) }
    ScreenScaffold(title = "Your Secret Key", onBack = null) {
        Text("This is shown only once. Write it down now and keep it somewhere safe and offline.")
        Card(modifier = Modifier.fillMaxWidth()) {
            Text(
                route.secretKey,
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Bold,
                fontSize = 20.sp,
                modifier = Modifier.padding16().testTag("secretKeyValue"),
            )
        }
        Warning(
            "You need BOTH your master password AND this Secret Key to open the vault on a new " +
                "device or to import an export. $NO_RECOVERY_WARNING",
            tag = "secretKeyWarning",
        )
        OutlinedButton(onClick = { app.clipboard.copy("Secret Key", route.secretKey) }) {
            Text("Copy (clears in 25 s)")
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(acknowledged, { acknowledged = it }, modifier = Modifier.testTag("ackSecretKey"))
            Text("I wrote down my Secret Key and understand it cannot be recovered.")
        }
        Button(
            enabled = acknowledged,
            modifier = Modifier.testTag("secretKeyDone"),
            onClick = {
                // Drop the Secret Key from the back stack.
                if (Session.vault != null) nav.reset(Route.Vaults, Route.Items) else nav.reset(Route.Vaults)
            },
        ) { Text("Continue") }
    }
}

@Composable
fun UnlockScreen(nav: Nav, vaultName: String) {
    UnlockContent(
        vaultName = vaultName,
        onBack = { nav.pop() },
        onUnlocked = { nav.reset(Route.Vaults, Route.Items) },
    )
}

@Composable
fun UnlockContent(vaultName: String, onBack: (() -> Unit)?, onUnlocked: () -> Unit) {
    val context = LocalContext.current
    val activity = context as FragmentActivity
    val unlocker = remember(vaultName) { VaultUnlocker(context, vaultName) }
    val scope = rememberCoroutineScope()
    val op = rememberOpState()
    var password by remember { mutableStateOf("") }
    var secretKey by remember { mutableStateOf("") }
    var reason by remember { mutableStateOf(PasswordRequiredReason.NO_BIOMETRIC_KEY) }
    val biometricHardware = remember { Biometrics.available(context) }
    var enableBiometric by remember { mutableStateOf(false) }

    LaunchedEffect(vaultName) {
        reason = core { unlocker.passwordRequiredReason() }
        enableBiometric = DeviceKeySupport.supported && biometricHardware && !unlocker.deviceUnlockEnabled()
    }

    fun finish(vault: Vault) {
        Session.open(vaultName, vault)
        onUnlocked()
    }

    ScreenScaffold(title = "Unlock \"$vaultName\"", onBack = onBack) {
        if (reason == PasswordRequiredReason.NOT_REQUIRED) {
            Button(
                enabled = !op.busy,
                modifier = Modifier.testTag("biometricUnlock"),
                onClick = {
                    scope.launch {
                        op.run {
                            val result = Biometrics.authenticate(
                                activity,
                                title = "Unlock $vaultName",
                                subtitle = "Confirm with your fingerprint or face",
                                onFailedAttempt = { unlocker.biometricFailure() },
                            )
                            if (result is BiometricResult.Error) {
                                reason = core { unlocker.passwordRequiredReason() }
                                throw IllegalStateException(result.message)
                            }
                            val vault = core { unlocker.unlockWithDevice() }
                            finish(vault)
                        }
                    }
                },
            ) { Text("Unlock with biometrics") }
            Text("or use your master password:")
        } else {
            Text(reason.explanation(), modifier = Modifier.testTag("passwordReason"))
        }
        if (!DeviceKeySupport.supported) {
            Text(
                "Biometric unlock: ${DeviceKeySupport.UNSUPPORTED_MESSAGE}",
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.testTag("api31Notice"),
            )
        }
        SecretField(password, { password = it }, "Master password", "unlockPassword")
        SecretKeyField(secretKey, { secretKey = it }, tag = "unlockSecretKey")
        if (DeviceKeySupport.supported && biometricHardware && !unlocker.deviceUnlockEnabled()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Checkbox(enableBiometric, { enableBiometric = it }, modifier = Modifier.testTag("enableBiometric"))
                Text("Turn on biometric unlock on this device")
            }
        } else if (DeviceKeySupport.supported && !biometricHardware) {
            Text(
                "Biometric unlock needs a strong (Class 3) fingerprint or face enrolled on this device.",
                style = MaterialTheme.typography.bodySmall,
            )
        }
        Button(
            enabled = !op.busy && password.isNotEmpty() && secretKey.isNotEmpty(),
            modifier = Modifier.testTag("unlockSubmit"),
            onClick = {
                scope.launch {
                    op.run {
                        val vault = core { unlocker.unlockWithPassword(password, secretKey) }
                        password = ""
                        secretKey = ""
                        if (enableBiometric) {
                            runCatching { core { unlocker.enableDeviceUnlock(vault) } }
                                .onFailure { op.info = "Biometric unlock not enabled: ${it.userMessage()}" }
                        }
                        finish(vault)
                    }
                }
            },
        ) { Text("Unlock") }
        OpStatus(op)
    }
}

internal fun Modifier.padding16() = this.padding(16.dp)
