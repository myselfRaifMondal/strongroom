package app.strongroom.android.ui

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
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
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
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

/** Label for the generic `username` slot per kind. */
fun ItemKind.usernameLabel(): String = when (this) {
    ItemKind.CARD -> "Card name / bank"
    ItemKind.API_KEY -> "Account / key ID"
    else -> "Username"
}

private val DATE =java.text.SimpleDateFormat("yyyy-MM-dd HH:mm", java.util.Locale.US)
fun formatDate(seconds: Long): String = DATE.format(java.util.Date(seconds * 1000))

/** Popup menus are a separate window: expose their testTags to uiautomator too. */
@OptIn(ExperimentalComposeUiApi::class)
internal val PopupTags = Modifier.semantics { testTagsAsResourceId = true }

@Composable
fun ItemListScreen(nav: Nav) {
    val vault = Session.vault ?: return
    val op = rememberOpState()
    var query by retain("query") { mutableStateOf("") }
    var folder by retain("folder") { mutableStateOf<String?>(null) }
    var tag by retain("tag") { mutableStateOf<String?>(null) }
    var items by remember { mutableStateOf<List<ItemSummary>>(emptyList()) }
    var folders by remember { mutableStateOf<List<String>>(emptyList()) }
    var tags by remember { mutableStateOf<List<String>>(emptyList()) }
    var menu by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        runCatching {
            folders = core { vault.listFolders() }
            tags = core { vault.listTags() }
        }
        if (folder != null && folder !in folders) folder = null
        if (tag != null && tag !in tags) tag = null
    }
    LaunchedEffect(query, folder, tag) {
        delay(150) // debounce typing
        op.run { items = core { vault.search(query, folder, tag) } }
    }

    ScreenScaffold(
        title = Session.unlockedName.value ?: "Vault",
        onBack = null,
        actions = {
            TextButton(onClick = { menu = true }, modifier = Modifier.testTag("menu")) { Text("Menu") }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }, modifier = PopupTags) {
                fun go(r: Route) { menu = false; nav.push(r) }
                DropdownMenuItem({ Text("Password generator") }, { go(Route.Generator()) }, Modifier.testTag("openGenerator"))
                DropdownMenuItem({ Text("Export (VTF)") }, { go(Route.Export) }, Modifier.testTag("openExport"))
                DropdownMenuItem({ Text("Import (VTF)") }, { go(Route.Import) }, Modifier.testTag("openImport"))
                DropdownMenuItem({ Text("Import CSV") }, { go(Route.ImportCsv) }, Modifier.testTag("openImportCsv"))
                DropdownMenuItem({ Text("Trash") }, { go(Route.Trash) }, Modifier.testTag("openTrash"))
                DropdownMenuItem({ Text("Settings") }, { go(Route.Settings) }, Modifier.testTag("openSettings"))
            }
            TextButton(onClick = { Session.lock(); nav.reset(Route.Vaults) }, modifier = Modifier.testTag("lock")) { Text("Lock") }
        },
        floating = {
            FloatingActionButton(onClick = { nav.push(Route.Edit(null)) }, modifier = Modifier.testTag("addItem")) {
                Icon(Icons.Filled.Add, contentDescription = "Add item")
            }
        },
    ) {
        PlainField(query, { query = it }, "Search", "search")
        if (folders.isNotEmpty() || tags.isNotEmpty()) {
            Row(
                Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                folders.forEach { f ->
                    FilterChip(
                        selected = folder == f,
                        onClick = { folder = if (folder == f) null else f },
                        label = { Text("Folder: $f") },
                        modifier = Modifier.testTag("folder_$f"),
                    )
                }
                tags.forEach { t ->
                    FilterChip(
                        selected = tag == t,
                        onClick = { tag = if (tag == t) null else t },
                        label = { Text("#$t") },
                        modifier = Modifier.testTag("tag_$t"),
                    )
                }
            }
        }
        OpStatus(op)
        if (items.isEmpty() && !op.busy && op.error == null) {
            val filtered = query.isNotEmpty() || folder != null || tag != null
            Text(if (filtered) "No matches." else "No items yet.", modifier = Modifier.testTag("emptyList"))
        }
        items.forEach { s ->
            Card(
                onClick = { nav.push(Route.Detail(s.id)) },
                modifier = Modifier.fillMaxWidth().testTag("item_${s.title}"),
            ) {
                Column(Modifier.padding(12.dp)) {
                    Text(s.title, style = MaterialTheme.typography.titleMedium)
                    Text(
                        listOfNotNull(s.kind.label(), s.subtitle, s.folder, if (s.hasTotp) "2FA" else null).joinToString(" - "),
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
    var confirmTrash by remember { mutableStateOf(false) }

    LaunchedEffect(id) { op.run { item = core { vault.getItem(id) } } }

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

    if (confirmTrash) {
        AlertDialog(
            onDismissRequest = { confirmTrash = false },
            title = { Text("Move to trash?") },
            text = { Text("It stays in the trash for 180 days and can be restored from Menu > Trash until then.") },
            confirmButton = {
                TextButton(
                    modifier = PopupTags.testTag("confirmTrash"),
                    onClick = {
                        confirmTrash = false
                        scope.launch {
                            op.run {
                                core { vault.trashItem(id, Clock.nowSeconds()) }
                                nav.pop()
                            }
                        }
                    },
                ) { Text("Move to trash") }
            },
            dismissButton = { TextButton(onClick = { confirmTrash = false }) { Text("Cancel") } },
        )
    }

    val data = item?.data
    ScreenScaffold(
        title = data?.title ?: "Item",
        onBack = { nav.pop() },
        actions = {
            TextButton(onClick = { nav.push(Route.History(id)) }, modifier = Modifier.testTag("openHistory")) { Text("History") }
            TextButton(onClick = { nav.push(Route.Edit(id)) }, modifier = Modifier.testTag("editItem")) { Text("Edit") }
        },
    ) {
        OpStatus(op)
        if (data == null) return@ScreenScaffold
        Text(data.kind.label(), style = MaterialTheme.typography.labelLarge)
        data.username?.let { CopyRow(data.kind.usernameLabel(), it, concealed = false, app, "username") }
        data.password?.let { CopyRow(data.kind.secretLabel(), it, concealed = true, app, "password") }
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
                            TextButton(
                                onClick = { app.clipboard.copy("one-time code", t.code) },
                                modifier = Modifier.testTag("copy_totp"),
                            ) { Text("Copy") }
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
        data.fields.forEachIndexed { i, f -> CopyRow(f.name, f.value, f.concealed, app, "field_$i") }
        data.notes?.let {
            HorizontalDivider()
            Text("Notes", style = MaterialTheme.typography.labelMedium)
            Text(it, modifier = Modifier.testTag("notes"))
        }
        if (data.travelSafe) Text("Travel-safe", style = MaterialTheme.typography.labelSmall)
        item?.let { Text("Modified ${formatDate(it.modifiedAt)}", style = MaterialTheme.typography.bodySmall) }
        OutlinedButton(
            modifier = Modifier.testTag("trashItem"),
            onClick = { confirmTrash = true },
        ) { Text("Move to trash") }
    }
}

@Composable
private fun CopyRow(label: String, value: String, concealed: Boolean, app: StrongroomApp, tag: String) {
    var shown by remember { mutableStateOf(!concealed) }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Column(Modifier.weight(1f)) {
            Text(label, style = MaterialTheme.typography.labelMedium)
            Text(
                if (shown) value else "•".repeat(10),
                fontFamily = if (concealed) FontFamily.Monospace else null,
                modifier = Modifier.testTag("value_$tag"),
            )
        }
        if (concealed) {
            TextButton(onClick = { shown = !shown }, modifier = Modifier.testTag("reveal_$tag")) {
                Text(if (shown) "Hide" else "Show")
            }
        }
        TextButton(
            onClick = { app.clipboard.copy(label, value, sensitive = concealed || tag == "username") },
            modifier = Modifier.testTag("copy_$tag"),
        ) { Text("Copy") }
    }
}

private class FieldDraft(name: String, value: String, concealed: Boolean) {
    var name by mutableStateOf(name)
    var value by mutableStateOf(value)
    var concealed by mutableStateOf(concealed)
}

/** The editor's state; retained while the generator is on top of it. */
private class ItemDraft {
    var loaded by mutableStateOf(false)
    var kind by mutableStateOf(ItemKind.LOGIN)
    var title by mutableStateOf("")
    var username by mutableStateOf("")
    var password by mutableStateOf("")
    var urls by mutableStateOf("")
    var notes by mutableStateOf("")
    var totp by mutableStateOf("")
    var folder by mutableStateOf("")
    var tags by mutableStateOf("")
    var travelSafe by mutableStateOf(false)
    val fields = mutableStateListOf<FieldDraft>()

    /** [dropEmptyFields]: new items only; existing items keep every named field as it was. */
    fun toInput(dropEmptyFields: Boolean): ItemInput {
        // Fields hidden for this kind (e.g. a secure note's username) are kept
        // as they are, so editing never silently drops imported data.
        return ItemInput(
            kind = kind,
            title = title.trim(),
            username = username.trim().ifEmpty { null },
            password = password.ifEmpty { null },
            urls = urls.lines().map { it.trim() }.filter { it.isNotEmpty() },
            notes = notes.ifBlank { null },
            totp = totp.ifBlank { null },
            folder = folder.trim().ifEmpty { null },
            tags = tags.split(',').map { it.trim() }.filter { it.isNotEmpty() },
            // Template fields left empty on a new item are dropped instead of saved blank.
            fields = fields.filter { it.name.isNotBlank() && (!dropEmptyFields || it.value.isNotEmpty()) }
                .map { CustomField(it.name.trim(), it.value, it.concealed) },
            travelSafe = travelSafe,
        )
    }
}

@Composable
fun ItemEditScreen(nav: Nav, id: String?) {
    val vault = Session.vault ?: return
    val scope = rememberCoroutineScope()
    val op = rememberOpState()
    val d = retain("draft") { ItemDraft().apply { loaded = id == null } }
    var kindMenu by remember { mutableStateOf(false) }

    LaunchedEffect(id) {
        if (id == null || d.loaded) return@LaunchedEffect
        op.run {
            val src = core { vault.getItem(id) }.data
            d.kind = src.kind; d.title = src.title; d.username = src.username.orEmpty(); d.password = src.password.orEmpty()
            d.urls = src.urls.joinToString("\n"); d.notes = src.notes.orEmpty(); d.totp = src.totp.orEmpty()
            d.folder = src.folder.orEmpty(); d.tags = src.tags.joinToString(", "); d.travelSafe = src.travelSafe
            d.fields.clear(); d.fields.addAll(src.fields.map { FieldDraft(it.name, it.value, it.concealed) })
            d.loaded = true
        }
    }
    // Back from the generator with "Use this password".
    LaunchedEffect(Unit) {
        nav.generatedForEditor?.let {
            d.password = it
            nav.generatedForEditor = null
        }
    }

    ScreenScaffold(title = if (id == null) "New item" else "Edit item", onBack = { nav.pop() }) {
        OpStatus(op)
        if (!d.loaded) return@ScreenScaffold
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Type: ")
            OutlinedButton(onClick = { kindMenu = true }, modifier = Modifier.testTag("kindPicker")) { Text(d.kind.label()) }
            DropdownMenu(expanded = kindMenu, onDismissRequest = { kindMenu = false }, modifier = PopupTags) {
                ItemKind.entries.forEach { k ->
                    DropdownMenuItem(
                        text = { Text(k.label()) },
                        modifier = Modifier.testTag("kind_${k.name}"),
                        onClick = {
                            d.kind = k
                            kindMenu = false
                            if (id == null && d.fields.all { it.value.isEmpty() }) {
                                d.fields.clear()
                                d.fields.addAll(k.templateFields().map { FieldDraft(it.name, it.value, it.concealed) })
                            }
                        },
                    )
                }
            }
        }
        PlainField(d.title, { d.title = it }, "Title", "itemTitle")
        if (d.kind != ItemKind.SECURE_NOTE) {
            PlainField(d.username, { d.username = it }, d.kind.usernameLabel(), "itemUsername")
            // SSH private keys are multi-line PEM text.
            SecretField(d.password, { d.password = it }, d.kind.secretLabel(), "itemPassword", singleLine = d.kind != ItemKind.SSH_KEY)
            if (d.kind == ItemKind.LOGIN) {
                Row {
                    TextButton(
                        modifier = Modifier.testTag("generateInline"),
                        onClick = {
                            scope.launch {
                                op.run {
                                    d.password = core {
                                        generatePassword(PasswordPolicy(20u, true, true, true, true, true))
                                    }
                                }
                            }
                        },
                    ) { Text("Generate password") }
                    TextButton(
                        modifier = Modifier.testTag("openGeneratorForEditor"),
                        onClick = { nav.push(Route.Generator(forEditor = true)) },
                    ) { Text("Generator options...") }
                }
            }
            PlainField(d.urls, { d.urls = it }, "Websites (one per line)", "itemUrls", singleLine = false)
            PlainField(d.totp, { d.totp = it.trim() }, "TOTP secret or otpauth:// URI", "itemTotp")
        }
        PlainField(d.notes, { d.notes = it }, "Notes", "itemNotes", singleLine = false)
        PlainField(d.folder, { d.folder = it }, "Folder (use / for sub-folders)", "itemFolder")
        PlainField(d.tags, { d.tags = it }, "Tags (comma separated)", "itemTags")

        Text("Custom fields", style = MaterialTheme.typography.titleSmall)
        d.fields.forEachIndexed { i, f ->
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(8.dp)) {
                    PlainField(f.name, { f.name = it }, "Field name", "fieldName_$i")
                    if (f.concealed) SecretField(f.value, { f.value = it }, "Value", "fieldValue_$i")
                    else PlainField(f.value, { f.value = it }, "Value", "fieldValue_$i")
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(f.concealed, { f.concealed = it }, modifier = Modifier.testTag("fieldConcealed_$i"))
                        Text("Concealed")
                        TextButton(onClick = { d.fields.removeAt(i) }, modifier = Modifier.testTag("fieldRemove_$i")) { Text("Remove") }
                    }
                }
            }
        }
        OutlinedButton(onClick = { d.fields.add(FieldDraft("", "", false)) }, modifier = Modifier.testTag("addField")) {
            Text("Add custom field")
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(d.travelSafe, { d.travelSafe = it }, modifier = Modifier.testTag("travelSafe"))
            Text("Travel-safe (kept on device in travel mode)")
        }
        Button(
            enabled = !op.busy && d.title.isNotBlank(),
            modifier = Modifier.testTag("saveItem"),
            onClick = {
                scope.launch {
                    op.run {
                        val input = d.toInput(dropEmptyFields = id == null)
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

/** Earlier versions of an item; any of them can be made current again. */
@Composable
fun HistoryScreen(nav: Nav, id: String) {
    val vault = Session.vault ?: return
    val scope = rememberCoroutineScope()
    val op = rememberOpState()
    var revisions by remember { mutableStateOf<List<uniffi.strongroom.ItemRevision>>(emptyList()) }
    var loaded by remember { mutableStateOf(false) }

    LaunchedEffect(id) {
        op.run { revisions = core { vault.itemHistory(id) }.sortedByDescending { it.modifiedAt } }
        loaded = true
    }

    ScreenScaffold(title = "History", onBack = { nav.pop() }) {
        Text("Earlier versions of this item, newest first. Restoring one keeps the current version in the history.")
        OpStatus(op)
        if (loaded && revisions.isEmpty()) Text("No earlier versions.", modifier = Modifier.testTag("historyEmpty"))
        revisions.forEachIndexed { i, rev ->
            Card(Modifier.fillMaxWidth().testTag("revision_$i")) {
                Column(Modifier.padding(12.dp)) {
                    Text(formatDate(rev.modifiedAt), style = MaterialTheme.typography.labelMedium)
                    Text(rev.data.title, style = MaterialTheme.typography.titleSmall)
                    Text(
                        listOfNotNull(rev.data.username, rev.data.folder, "${rev.data.fields.size} field(s)").joinToString(" - "),
                        style = MaterialTheme.typography.bodySmall,
                    )
                    TextButton(
                        modifier = Modifier.testTag("restoreRevision_$i"),
                        onClick = {
                            scope.launch {
                                op.run {
                                    core { vault.updateItem(id, rev.data, Clock.nowSeconds()) }
                                    nav.pop()
                                }
                            }
                        },
                    ) { Text("Restore this version") }
                }
            }
        }
    }
}
