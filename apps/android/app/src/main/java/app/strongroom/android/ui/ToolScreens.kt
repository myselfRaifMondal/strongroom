package app.strongroom.android.ui

import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import app.strongroom.android.StrongroomApp
import app.strongroom.android.core.AutoLock
import app.strongroom.android.core.Clock
import app.strongroom.android.core.CsvSources
import app.strongroom.android.core.Session
import app.strongroom.android.core.VaultUnlocker
import app.strongroom.android.security.DeviceKeySupport
import kotlinx.coroutines.launch
import uniffi.strongroom.CsvSource
import uniffi.strongroom.ImportSummary
import uniffi.strongroom.TrashEntry

/** CSV import from another password manager (Vault.import_csv). */
@Composable
fun ImportCsvScreen(nav: Nav) {
    val vault = Session.vault ?: return
    val vaultName = Session.unlockedName.value ?: return
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val op = rememberOpState()
    var source by retain("source") { mutableStateOf(CsvSource.CHROME) }
    var csv by retain("csv") { mutableStateOf<String?>(null) }
    var fileName by retain("fileName") { mutableStateOf<String?>(null) }
    var summary by remember { mutableStateOf<ImportSummary?>(null) }

    val openDoc = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            op.run {
                summary = null
                val text = core {
                    context.contentResolver.openInputStream(uri)!!.use { it.readBytes() }.toString(Charsets.UTF_8)
                }
                csv = text
                fileName = core {
                    context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                        ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
                } ?: uri.lastPathSegment
                CsvSources.guess(text)?.let { source = it }
            }
        }
    }

    ScreenScaffold(title = "Import CSV", onBack = { nav.pop() }) {
        Text("Items from another password manager's CSV export are added to \"$vaultName\".")
        Warning(
            "A CSV export is NOT encrypted: anyone who can read the file sees every password. " +
                "Delete it (and empty the Downloads trash) right after importing.",
            tag = "csvWarning",
        )
        Button(onClick = { openDoc.launch(arrayOf("text/*", "application/csv", "application/vnd.ms-excel", "application/octet-stream")) },
            modifier = Modifier.testTag("csvChooseFile")) { Text("Choose .csv file") }
        csv?.let { Text("Selected: ${fileName ?: "file"} (${it.length} characters)", modifier = Modifier.testTag("csvSelected")) }
        Text("Exported from:", style = MaterialTheme.typography.titleSmall)
        CsvSources.ALL.forEach { (s, label) ->
            Row(
                Modifier.fillMaxWidth().selectable(selected = source == s, onClick = { source = s }).testTag("csvSource_${s.name}"),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RadioButton(selected = source == s, onClick = { source = s })
                Text(label)
            }
        }
        Button(
            enabled = !op.busy && csv != null,
            modifier = Modifier.testTag("csvImport"),
            onClick = {
                val text = csv ?: return@Button
                scope.launch {
                    op.run {
                        summary = core { vault.importCsv(source, text, Clock.nowSeconds()) }
                        csv = null // drop the plaintext from memory
                    }
                }
            },
        ) { Text("Import") }
        OpStatus(op)
        summary?.let {
            Text(
                "Imported: ${it.added} added, ${it.updated} updated, ${it.unchanged} unchanged, ${it.conflicts} conflicts",
                modifier = Modifier.testTag("csvSummary"),
            )
            Button(onClick = { nav.reset(Route.Vaults, Route.Items) }, modifier = Modifier.testTag("csvDone")) { Text("Done") }
        }
    }
}

/** Trashed items: restore, or delete the ones past their 180 days. */
@Composable
fun TrashScreen(nav: Nav) {
    val vault = Session.vault ?: return
    val scope = rememberCoroutineScope()
    val op = rememberOpState()
    var entries by remember { mutableStateOf<List<TrashEntry>>(emptyList()) }
    var loaded by remember { mutableStateOf(false) }

    suspend fun reload() {
        entries = core { vault.listTrash() }.sortedByDescending { it.deletedAt }
        loaded = true
    }
    LaunchedEffect(Unit) { op.run { reload() } }

    ScreenScaffold(title = "Trash", onBack = { nav.pop() }) {
        Text("Trashed items are kept for 180 days, then deleted for good.")
        OutlinedButton(
            modifier = Modifier.testTag("purgeExpired"),
            onClick = {
                scope.launch {
                    op.run {
                        val n = core { vault.purgeExpiredTrash(Clock.nowSeconds()) }
                        reload()
                        op.info = if (n == 0u) "Nothing in the trash is older than 180 days." else "$n expired item(s) deleted for good."
                    }
                }
            },
        ) { Text("Delete expired items now") }
        OpStatus(op)
        if (loaded && entries.isEmpty()) Text("The trash is empty.", modifier = Modifier.testTag("trashEmpty"))
        entries.forEach { e ->
            Card(Modifier.fillMaxWidth().testTag("trash_${e.item.title}")) {
                Column(Modifier.padding(12.dp)) {
                    Text(e.item.title, style = MaterialTheme.typography.titleMedium)
                    Text(
                        "${e.item.kind.label()} - trashed ${formatDate(e.deletedAt)} - deleted for good after ${formatDate(e.purgeAt)}",
                        style = MaterialTheme.typography.bodySmall,
                    )
                    TextButton(
                        modifier = Modifier.testTag("restore_${e.item.title}"),
                        onClick = {
                            scope.launch {
                                op.run {
                                    core { vault.restoreItem(e.item.id, Clock.nowSeconds()) }
                                    reload()
                                    op.info = "Restored \"${e.item.title}\"."
                                }
                            }
                        },
                    ) { Text("Restore") }
                }
            }
        }
    }
}

@Composable
fun SettingsScreen(nav: Nav) {
    val vault = Session.vault ?: return
    val vaultName = Session.unlockedName.value ?: return
    val context = LocalContext.current
    val app = context.applicationContext as StrongroomApp
    val scope = rememberCoroutineScope()
    val op = rememberOpState()
    val unlocker = remember(vaultName) { VaultUnlocker(context, vaultName) }
    var autoLock by remember { mutableIntStateOf(app.autoLockMinutes) }
    var biometricOn by remember { mutableStateOf(unlocker.deviceUnlockEnabled()) }
    var travel by remember { mutableStateOf(false) }
    var confirmTravel by remember { mutableStateOf<Boolean?>(null) }
    var notTravelSafe by remember { mutableIntStateOf(0) }

    LaunchedEffect(Unit) {
        op.run {
            travel = core { vault.travelMode() }
            notTravelSafe = core {
                vault.search("", null, null).count { s -> runCatching { !vault.getItem(s.id).data.travelSafe }.getOrDefault(true) }
            }
        }
    }

    confirmTravel?.let { on ->
        AlertDialog(
            onDismissRequest = { confirmTravel = null },
            title = { Text(if (on) "Turn on travel mode?" else "Turn off travel mode?") },
            text = {
                Text(
                    if (on) "$notTravelSafe item(s) not marked travel-safe will be REMOVED from this device. " +
                        "Make sure you have an export (VTF) that contains them; import it after your trip to get them back."
                    else "Travel mode will be turned off. Removed items come back only by importing an export that contains them.",
                )
            },
            confirmButton = {
                TextButton(
                    modifier = PopupTags.testTag("confirmTravel"),
                    onClick = {
                        confirmTravel = null
                        scope.launch {
                            op.run {
                                core { vault.setTravelMode(on, Clock.nowSeconds()) }
                                travel = core { vault.travelMode() }
                                op.info = if (travel) "Travel mode is on." else "Travel mode is off."
                            }
                        }
                    },
                ) { Text(if (on) "Remove and turn on" else "Turn off") }
            },
            dismissButton = { TextButton(onClick = { confirmTravel = null }) { Text("Cancel") } },
        )
    }

    ScreenScaffold(title = "Settings", onBack = { nav.pop() }) {
        Text("Auto-lock", style = MaterialTheme.typography.titleSmall)
        Text("Lock the vault this long after Strongroom leaves the screen.")
        Row(horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp)) {
            AutoLock.CHOICES_MINUTES.forEach { m ->
                FilterChip(
                    selected = autoLock == m,
                    onClick = { autoLock = m; app.autoLockMinutes = m },
                    label = { Text(AutoLock.label(m)) },
                    modifier = Modifier.testTag("autoLock_$m"),
                )
            }
        }
        HorizontalDivider()
        Text("Biometric unlock", style = MaterialTheme.typography.titleSmall)
        if (!DeviceKeySupport.supported) {
            Text(DeviceKeySupport.UNSUPPORTED_MESSAGE)
        } else if (biometricOn) {
            Text("On for \"$vaultName\" on this device.", modifier = Modifier.testTag("biometricState"))
            OutlinedButton(
                modifier = Modifier.testTag("biometricOff"),
                onClick = {
                    unlocker.disableDeviceUnlock()
                    biometricOn = unlocker.deviceUnlockEnabled()
                    op.info = "Biometric unlock turned off."
                },
            ) { Text("Turn off biometric unlock") }
        } else {
            Text(
                "Off. To turn it on, lock the vault and tick \"Turn on biometric unlock\" when you unlock with your master password.",
                modifier = Modifier.testTag("biometricState"),
            )
        }
        HorizontalDivider()
        Text("Travel mode", style = MaterialTheme.typography.titleSmall)
        Text("When on, only items marked travel-safe stay on this device.")
        Row(verticalAlignment = Alignment.CenterVertically) {
            Switch(checked = travel, onCheckedChange = { confirmTravel = it }, modifier = Modifier.testTag("travelMode"))
            Text(if (travel) "  On" else "  Off ($notTravelSafe item(s) would be removed)")
        }
        OpStatus(op)
    }
}
