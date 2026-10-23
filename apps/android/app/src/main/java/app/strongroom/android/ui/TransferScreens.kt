package app.strongroom.android.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.fragment.app.FragmentActivity
import app.strongroom.android.StrongroomApp
import app.strongroom.android.core.Clock
import app.strongroom.android.core.Session
import app.strongroom.android.core.VaultUnlocker
import app.strongroom.android.security.BiometricResult
import app.strongroom.android.security.Biometrics
import app.strongroom.android.security.DeviceKeySupport
import app.strongroom.android.security.KeystoreDeviceKeyAgreement
import kotlinx.coroutines.launch
import uniffi.strongroom.ImportSummary
import uniffi.strongroom.PairedDevice
import uniffi.strongroom.VtfInfo
import uniffi.strongroom.pairingPayload
import uniffi.strongroom.parsePairingPayload
import uniffi.strongroom.vtfInspect
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun ExportScreen(nav: Nav) {
    val vault = Session.vault ?: return
    val vaultName = Session.unlockedName.value ?: return
    val context = LocalContext.current
    val app = context.applicationContext as StrongroomApp
    val scope = rememberCoroutineScope()
    val op = rememberOpState()
    var password by remember { mutableStateOf("") }
    var secretKey by remember { mutableStateOf("") }
    var recipientsText by remember { mutableStateOf("") }
    var recipients by remember { mutableStateOf<List<PairedDevice>>(emptyList()) }
    var myPairing by remember { mutableStateOf<String?>(null) }

    val createDoc = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/octet-stream"),
    ) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            op.run {
                val bytes = core {
                    vault.exportVtf(password, secretKey, recipients.map { it.publicKey }, Clock.nowSeconds())
                }
                core {
                    context.contentResolver.openOutputStream(uri, "wt")!!.use { it.write(bytes) }
                }
                op.info = "Exported ${bytes.size} bytes with ${recipients.size} device recipient(s)."
            }
        }
    }

    ScreenScaffold(title = "Export (VTF)", onBack = { nav.pop() }) {
        Text(
            "The export is encrypted with this vault's master password and Secret Key. " +
                "Anyone importing it needs both.",
        )
        SecretField(password, { password = it }, "Master password", "exportPassword")
        SecretKeyField(secretKey, { secretKey = it }, tag = "exportSecretKey")

        Text("Device recipients (optional)", style = MaterialTheme.typography.titleSmall)
        if (!DeviceKeySupport.supported) {
            Text(DeviceKeySupport.UNSUPPORTED_MESSAGE, modifier = Modifier.testTag("api31Notice"))
        } else {
            Text("Paste pairing codes of other devices, one per line. They can import with biometrics instead of the password.")
            PlainField(recipientsText, { recipientsText = it }, "Pairing codes", "pairingCodes", singleLine = false)
            OutlinedButton(onClick = {
                scope.launch {
                    op.run {
                        recipients = core {
                            recipientsText.lines().map { it.trim() }.filter { it.isNotEmpty() }.map { parsePairingPayload(it) }
                        }
                        op.info = "${recipients.size} recipient(s): " + recipients.joinToString { it.fingerprint }
                    }
                }
            }) { Text("Check pairing codes") }
            OutlinedButton(onClick = {
                scope.launch {
                    op.run {
                        val unlocker = VaultUnlocker(context, vaultName)
                        val key = unlocker.deviceKey ?: error(DeviceKeySupport.UNSUPPORTED_MESSAGE)
                        check(Biometrics.available(context)) { "Enroll a strong fingerprint or face first." }
                        myPairing = core { pairingPayload(key.ensure()) }
                    }
                }
            }) { Text("Show this device's pairing code") }
            myPairing?.let { code ->
                Card(Modifier.fillMaxWidth()) {
                    Text(code, fontFamily = FontFamily.Monospace, modifier = Modifier.padding16().testTag("myPairingCode"))
                }
                OutlinedButton(onClick = { app.clipboard.copy("pairing code", code, sensitive = false) }) { Text("Copy pairing code") }
            }
        }
        Button(
            enabled = !op.busy && password.isNotEmpty() && secretKey.isNotEmpty(),
            modifier = Modifier.testTag("exportChooseFile"),
            onClick = {
                val stamp = SimpleDateFormat("yyyyMMdd-HHmm", Locale.US).format(Date())
                createDoc.launch("strongroom-$vaultName-$stamp.vtf")
            },
        ) { Text("Choose file and export") }
        OpStatus(op)
    }
}

@Composable
fun ImportScreen(nav: Nav) {
    val vault = Session.vault ?: return
    val vaultName = Session.unlockedName.value ?: return
    val context = LocalContext.current
    val activity = context as FragmentActivity
    val scope = rememberCoroutineScope()
    val op = rememberOpState()
    var fileBytes by remember { mutableStateOf<ByteArray?>(null) }
    var fileName by remember { mutableStateOf<String?>(null) }
    var info by remember { mutableStateOf<VtfInfo?>(null) }
    var password by remember { mutableStateOf("") }
    var secretKey by remember { mutableStateOf("") }
    var summary by remember { mutableStateOf<ImportSummary?>(null) }

    val openDoc = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            op.run {
                summary = null
                info = null
                val bytes = core { context.contentResolver.openInputStream(uri)!!.use { it.readBytes() } }
                fileBytes = bytes
                fileName = uri.lastPathSegment
                info = core { vtfInspect(bytes) }
            }
        }
    }

    ScreenScaffold(title = "Import (VTF)", onBack = { nav.pop() }) {
        Text("Items are merged into \"$vaultName\".")
        Button(onClick = { openDoc.launch(arrayOf("*/*")) }, modifier = Modifier.testTag("importChooseFile")) {
            Text("Choose .vtf file")
        }
        fileBytes?.let { Text("Selected: ${fileName ?: "file"} (${it.size} bytes)", modifier = Modifier.testTag("importSelected")) }
        info?.let {
            Text(
                "VTF v${it.version}: ${it.passwordSlots} password slot(s), ${it.deviceSlots} device slot(s), ${it.chunkCount} chunk(s)",
                modifier = Modifier.testTag("vtfInfo"),
            )
        }
        Text("Master password and Secret Key of the vault that made the export:")
        SecretField(password, { password = it }, "Master password", "importPassword")
        SecretKeyField(secretKey, { secretKey = it }, tag = "importSecretKey")
        Button(
            enabled = !op.busy && fileBytes != null && password.isNotEmpty() && secretKey.isNotEmpty(),
            modifier = Modifier.testTag("importSubmit"),
            onClick = {
                val bytes = fileBytes ?: return@Button
                scope.launch {
                    op.run {
                        summary = core { vault.importVtf(bytes, password, secretKey, Clock.nowSeconds()) }
                    }
                }
            },
        ) { Text("Import with password") }

        if (!DeviceKeySupport.supported) {
            Text("Import with this device's key: " + DeviceKeySupport.UNSUPPORTED_MESSAGE, modifier = Modifier.testTag("api31Notice"))
        } else {
            OutlinedButton(
                enabled = !op.busy && fileBytes != null && (info?.deviceSlots?.toInt() ?: 0) > 0,
                modifier = Modifier.testTag("importWithDevice"),
                onClick = {
                    val bytes = fileBytes ?: return@OutlinedButton
                    scope.launch {
                        op.run {
                            val key = VaultUnlocker(context, vaultName).deviceKey
                                ?: error(DeviceKeySupport.UNSUPPORTED_MESSAGE)
                            check(key.exists()) { "This device has no pairing key yet." }
                            val r = Biometrics.authenticate(activity, "Import export", "Use this device's key")
                            if (r is BiometricResult.Error) error(r.message)
                            summary = core {
                                vault.importVtfWithDeviceKey(bytes, KeystoreDeviceKeyAgreement(key), Clock.nowSeconds())
                            }
                        }
                    }
                },
            ) { Text("Import with this device's key (biometric)") }
        }
        OpStatus(op)
        summary?.let {
            Text(
                "Imported: ${it.added} added, ${it.updated} updated, ${it.unchanged} unchanged, ${it.conflicts} conflicts",
                modifier = Modifier.testTag("importSummary"),
            )
            Button(onClick = { nav.reset(Route.Vaults, Route.Items) }, modifier = Modifier.testTag("importDone")) { Text("Done") }
        }
    }
}
