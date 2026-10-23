package app.strongroom.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.strongroom.android.StrongroomApp
import app.strongroom.android.core.Clock
import app.strongroom.android.core.Session
import app.strongroom.android.core.userMessage
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import uniffi.strongroom.CustomField
import uniffi.strongroom.Item
import uniffi.strongroom.ItemInput
import uniffi.strongroom.ItemKind
import uniffi.strongroom.ItemSummary
import uniffi.strongroom.PasswordPolicy
import uniffi.strongroom.TotpCode
import uniffi.strongroom.generatePassword

fun ItemKind.label(): String = when (this) {
    ItemKind.LOGIN -> "Login"
    ItemKind.SECURE_NOTE -> "Secure note"
    ItemKind.CARD -> "Card"
    ItemKind.IDENTITY -> "Identity"
    ItemKind.API_KEY -> "API key"
    ItemKind.SSH_KEY -> "SSH key"
}

/** Label for the generic `password` slot per kind. */
fun ItemKind.secretLabel(): String = when (this) {
    ItemKind.API_KEY -> "API key / token"
    ItemKind.SSH_KEY -> "Private key"
    ItemKind.CARD -> "PIN"
    else -> "Password"
}

/** Suggested custom fields for kinds whose data does not fit the generic slots. */
fun ItemKind.templateFields(): List<CustomField> = when (this) {
    ItemKind.CARD -> listOf(
        CustomField("Cardholder", "", false),
        CustomField("Number", "", true),
        CustomField("Expiry (MM/YY)", "", false),
        CustomField("Security code", "", true),
    )
    ItemKind.IDENTITY -> listOf(
        CustomField("Full name", "", false),
        CustomField("Email", "", false),
        CustomField("Phone", "", false),
        CustomField("Address", "", false),
    )
    ItemKind.SSH_KEY -> listOf(CustomField("Public key", "", false))
    else -> emptyList()
}

@Composable
fun ItemListScreen(nav: Nav) {
    val vault = Session.vault ?: return
    val op = rememberOpState()
    var query by remember { mutableStateOf("") }
    var items by remember { mutableStateOf<List<ItemSummary>>(emptyList()) }

    LaunchedEffect(query, nav.stack.size) {
        delay(150) // debounce typing
        op.run { items = core { vault.search(query, null, null) } }
    }

    ScreenScaffold(
        title = Session.unlockedName.value ?: "Vault",
        onBack = null,
        actions = {
            TextButton(onClick = { nav.push(Route.Generator) }, modifier = Modifier.testTag("openGenerator")) { Text("Gen") }
            TextButton(onClick = { nav.push(Route.Export) }, modifier = Modifier.testTag("openExport")) { Text("Export") }
            TextButton(onClick = { nav.push(Route.Import) }, modifier = Modifier.testTag("openImport")) { Text("Import") }
            TextButton(onClick = { Session.lock(); nav.reset(Route.Vaults) }, modifier = Modifier.testTag("lock")) { Text("Lock") }
        },
        floating = {
            FloatingActionButton(onClick = { nav.push(Route.Edit(null)) }, modifier = Modifier.testTag("addItem")) {
                Icon(Icons.Filled.Add, contentDescription = "Add item")
            }
        },
    ) {
        PlainField(query, { query = it }, "Search", "search")
        OpStatus(op)
        if (items.isEmpty() && !op.busy && op.error == null) {
            Text(if (query.isEmpty()) "No items yet." else "No matches.", modifier = Modifier.testTag("emptyList"))
        }
        items.forEach { s ->
            Card(
                onClick = { nav.push(Route.Detail(s.id)) },
                modifier = Modifier.fillMaxWidth().testTag("item_${s.title}"),
            ) {
                Column(Modifier.padding(12.dp)) {
                    Text(s.title, style = MaterialTheme.typography.titleMedium)
                    Text(
                        listOfNotNull(s.kind.label(), s.subtitle, if (s.hasTotp) "2FA" else null).joinToString(" - "),
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }
    }
}

@Composable
fun ItemDetailScreen(nav: Nav, id: String) {
    val vault = Session.vault ?: return
    val app = LocalContext.current.applicationContext as StrongroomApp
    val scope = rememberCoroutineScope()
    val op = rememberOpState()
    var item by remember { mutableStateOf<Item?>(null) }
    var totp by remember { mutableStateOf<TotpCode?>(null) }
    var totpError by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(id, nav.stack.size) { op.run { item = core { vault.getItem(id) } } }

    // Live TOTP: refresh every second while the screen is visible.
    LaunchedEffect(id, item?.data?.totp) {
        if (item?.data?.totp.isNullOrBlank()) return@LaunchedEffect
        while (true) {
            runCatching { core { vault.itemTotp(id, Clock.nowSeconds()) } }
                .onSuccess { totp = it; totpError = null }
                .onFailure { totpError = it.userMessage() }
            delay(1000)
        }
    }

    val data = item?.data
    ScreenScaffold(
        title = data?.title ?: "Item",
        onBack = { nav.pop() },
        actions = {
            TextButton(onClick = { nav.push(Route.Edit(id)) }, modifier = Modifier.testTag("editItem")) { Text("Edit") }
        },
    ) {
        OpStatus(op)
        if (data == null) return@ScreenScaffold
        Text(data.kind.label(), style = MaterialTheme.typography.labelLarge)
        data.username?.let { CopyRow("Username", it, concealed = false, app) }
        data.password?.let { CopyRow(data.kind.secretLabel(), it, concealed = true, app) }
        if (!data.totp.isNullOrBlank()) {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp)) {
                    Text("One-time code", style = MaterialTheme.typography.labelMedium)
                    totp?.let { t ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                t.code.chunked(3).joinToString(" "),
                                fontFamily = FontFamily.Monospace,
                                fontSize = 28.sp,
                                modifier = Modifier.testTag("totpCode"),
                            )
                            Text("  ${t.secondsRemaining}s", modifier = Modifier.testTag("totpRemaining"))
                            TextButton(onClick = { app.clipboard.copy("one-time code", t.code) }) { Text("Copy") }
                        }
                        LinearProgressIndicator(
                            progress = { t.secondsRemaining.toFloat() / t.period.toFloat().coerceAtLeast(1f) },
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                    totpError?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("totpError")) }
                }
            }
        }
        if (data.urls.isNotEmpty()) Text("Websites: " + data.urls.joinToString(", "))
        data.folder?.let { Text("Folder: $it") }
        if (data.tags.isNotEmpty()) Text("Tags: " + data.tags.joinToString(", "))
        data.fields.forEach { f -> CopyRow(f.name, f.value, f.concealed, app) }
        data.notes?.let {
            HorizontalDivider()
            Text("Notes", style = MaterialTheme.typography.labelMedium)
            Text(it)
        }
        if (data.travelSafe) Text("Travel-safe", style = MaterialTheme.typography.labelSmall)
        item?.let { Text("Modified ${java.util.Date(it.modifiedAt * 1000)}", style = MaterialTheme.typography.bodySmall) }
        OutlinedButton(
            modifier = Modifier.testTag("trashItem"),
            onClick = {
                scope.launch {
                    op.run {
                        core { vault.trashItem(id, Clock.nowSeconds()) }
                        nav.pop()
                    }
                }
            },
        ) { Text("Move to trash") }
    }
}

@Composable
private fun CopyRow(label: String, value: String, concealed: Boolean, app: StrongroomApp) {
    var shown by remember { mutableStateOf(!concealed) }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Column(Modifier.weight(1f)) {
            Text(label, style = MaterialTheme.typography.labelMedium)
            Text(if (shown) value else "•".repeat(10), fontFamily = if (concealed) FontFamily.Monospace else null)
        }
        if (concealed) TextButton(onClick = { shown = !shown }) { Text(if (shown) "Hide" else "Show") }
        TextButton(onClick = { app.clipboard.copy(label, value, sensitive = concealed || label == "Username") }) { Text("Copy") }
    }
}

private class FieldDraft(name: String, value: String, concealed: Boolean) {
    var name by mutableStateOf(name)
    var value by mutableStateOf(value)
    var concealed by mutableStateOf(concealed)
}

@Composable
fun ItemEditScreen(nav: Nav, id: String?) {
    val vault = Session.vault ?: return
    val scope = rememberCoroutineScope()
    val op = rememberOpState()
    var loaded by remember { mutableStateOf(id == null) }
    var kind by remember { mutableStateOf(ItemKind.LOGIN) }
    var title by remember { mutableStateOf("") }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var urls by remember { mutableStateOf("") }
    var notes by remember { mutableStateOf("") }
    var totp by remember { mutableStateOf("") }
    var folder by remember { mutableStateOf("") }
    var tags by remember { mutableStateOf("") }
    var travelSafe by remember { mutableStateOf(false) }
    val fields = remember { mutableStateListOf<FieldDraft>() }
    var kindMenu by remember { mutableStateOf(false) }

    LaunchedEffect(id) {
        if (id == null) return@LaunchedEffect
        op.run {
            val d = core { vault.getItem(id) }.data
            kind = d.kind; title = d.title; username = d.username.orEmpty(); password = d.password.orEmpty()
            urls = d.urls.joinToString("\n"); notes = d.notes.orEmpty(); totp = d.totp.orEmpty()
            folder = d.folder.orEmpty(); tags = d.tags.joinToString(", "); travelSafe = d.travelSafe
            fields.clear(); fields.addAll(d.fields.map { FieldDraft(it.name, it.value, it.concealed) })
            loaded = true
        }
    }

    ScreenScaffold(title = if (id == null) "New item" else "Edit item", onBack = { nav.pop() }) {
        OpStatus(op)
        if (!loaded) return@ScreenScaffold
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Type: ")
            OutlinedButton(onClick = { kindMenu = true }, modifier = Modifier.testTag("kindPicker")) { Text(kind.label()) }
            DropdownMenu(expanded = kindMenu, onDismissRequest = { kindMenu = false }) {
                ItemKind.entries.forEach { k ->
                    DropdownMenuItem(
                        text = { Text(k.label()) },
                        modifier = Modifier.testTag("kind_${k.name}"),
                        onClick = {
                            kind = k
                            kindMenu = false
                            if (id == null && fields.all { it.value.isEmpty() }) {
                                fields.clear()
                                fields.addAll(k.templateFields().map { FieldDraft(it.name, it.value, it.concealed) })
                            }
                        },
                    )
                }
            }
        }
        PlainField(title, { title = it }, "Title", "itemTitle")
        if (kind != ItemKind.SECURE_NOTE) {
            PlainField(username, { username = it }, if (kind == ItemKind.CARD) "Card name / bank" else "Username", "itemUsername")
            SecretField(password, { password = it }, kind.secretLabel(), "itemPassword")
            if (kind == ItemKind.LOGIN) {
                TextButton(
                    modifier = Modifier.testTag("generateInline"),
                    onClick = {
                        scope.launch {
                            op.run {
                                password = core {
                                    generatePassword(PasswordPolicy(20u, true, true, true, true, true))
                                }
                            }
                        }
                    },
                ) { Text("Generate password") }
            }
            PlainField(urls, { urls = it }, "Websites (one per line)", "itemUrls", singleLine = false)
            PlainField(totp, { totp = it.trim() }, "TOTP secret or otpauth:// URI", "itemTotp")
        }
        PlainField(notes, { notes = it }, "Notes", "itemNotes", singleLine = false)
        PlainField(folder, { folder = it }, "Folder", "itemFolder")
        PlainField(tags, { tags = it }, "Tags (comma separated)", "itemTags")

        Text("Custom fields", style = MaterialTheme.typography.titleSmall)
        fields.forEachIndexed { i, f ->
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(8.dp)) {
                    PlainField(f.name, { f.name = it }, "Field name", "fieldName_$i")
                    if (f.concealed) SecretField(f.value, { f.value = it }, "Value", "fieldValue_$i")
                    else PlainField(f.value, { f.value = it }, "Value", "fieldValue_$i")
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(f.concealed, { f.concealed = it })
                        Text("Concealed")
                        TextButton(onClick = { fields.removeAt(i) }) { Text("Remove") }
                    }
                }
            }
        }
        OutlinedButton(onClick = { fields.add(FieldDraft("", "", false)) }, modifier = Modifier.testTag("addField")) {
            Text("Add custom field")
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(travelSafe, { travelSafe = it }, modifier = Modifier.testTag("travelSafe"))
            Text("Travel-safe (kept on device in travel mode)")
        }
        Button(
            enabled = !op.busy && title.isNotBlank(),
            modifier = Modifier.testTag("saveItem"),
            onClick = {
                scope.launch {
                    op.run {
                        val input = ItemInput(
                            kind = kind,
                            title = title.trim(),
                            username = username.trim().ifEmpty { null },
                            password = password.ifEmpty { null },
                            urls = urls.lines().map { it.trim() }.filter { it.isNotEmpty() },
                            notes = notes.ifBlank { null },
                            totp = totp.ifBlank { null },
                            folder = folder.trim().ifEmpty { null },
                            tags = tags.split(',').map { it.trim() }.filter { it.isNotEmpty() },
                            fields = fields.filter { it.name.isNotBlank() }
                                .map { CustomField(it.name.trim(), it.value, it.concealed) },
                            travelSafe = travelSafe,
                        )
                        val now = Clock.nowSeconds()
                        if (id == null) {
                            val newId = core { vault.addItem(input, now) }
                            nav.pop()
                            nav.push(Route.Detail(newId))
                        } else {
                            core { vault.updateItem(id, input, now) }
                            nav.pop()
                        }
                    }
                }
            },
        ) { Text("Save") }
    }
}
