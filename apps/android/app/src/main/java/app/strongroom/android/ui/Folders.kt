package app.strongroom.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.strongroom.android.core.FolderNode
import app.strongroom.android.core.FolderOps
import app.strongroom.android.core.FolderPath
import app.strongroom.android.core.FolderTree

/** "Social › Instagram"; "All items" for the root. */
fun folderLabel(path: List<String>): String = if (path.isEmpty()) "All items" else path.joinToString(" › ")

/**
 * The folder tree: top-level folders, and the sub-folders of each expanded
 * one. Tapping a row selects that folder (its whole subtree is shown).
 */
@Composable
fun FolderTreeList(
    tree: List<FolderNode>,
    selected: List<String>,
    expanded: Set<String>,
    onSelect: (List<String>) -> Unit,
    onToggle: (FolderNode) -> Unit,
) {
    Card(Modifier.fillMaxWidth().testTag("folderTree")) {
        Column(Modifier.padding(vertical = 4.dp)) {
            FolderRow("All items", depth = 0, count = null, selected = selected.isEmpty(), expander = null, tag = "folderRow_all") {
                onSelect(emptyList())
            }
            FolderTree.visibleRows(tree, expanded).forEach { (node, depth) ->
                val expander = if (node.children.isEmpty()) null else (node.id in expanded)
                FolderRow(
                    node.name, depth, node.totalCount, selected == node.path, expander, "folderRow_${node.id}",
                    onToggle = { onToggle(node) },
                ) { onSelect(node.path) }
            }
        }
    }
}

@Composable
private fun FolderRow(
    name: String,
    depth: Int,
    count: Int?,
    selected: Boolean,
    expander: Boolean?,
    tag: String,
    onToggle: () -> Unit = {},
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .testTag(tag)
            .padding(start = (8 + depth * 20).dp, end = 12.dp),
    ) {
        if (expander != null) {
            TextButton(onClick = onToggle, modifier = Modifier.width(44.dp).testTag("${tag}_toggle")) {
                Text(if (expander) "▾" else "▸")
            }
        } else {
            Text("", Modifier.width(44.dp))
        }
        Text(
            name,
            fontWeight = if (selected) FontWeight.Bold else null,
            color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.weight(1f).padding(vertical = 10.dp),
        )
        count?.let { Text("$it", style = MaterialTheme.typography.bodySmall) }
    }
}

/** The selected folder with its actions (shown above the item list). */
@Composable
fun FolderHeader(
    path: List<String>,
    onClear: () -> Unit,
    onNew: () -> Unit,
    onRename: () -> Unit,
    onMove: () -> Unit,
) {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer),
        modifier = Modifier.fillMaxWidth().testTag("folderHeader"),
    ) {
        Column(Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
            Text(
                "Folder: ${folderLabel(path)}",
                style = MaterialTheme.typography.titleSmall,
                modifier = Modifier.testTag("selectedFolder"),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(onClick = onNew, modifier = Modifier.testTag("newSubfolder")) { Text("New sub-folder") }
                TextButton(onClick = onRename, modifier = Modifier.testTag("renameFolder")) { Text("Rename") }
                TextButton(onClick = onMove, modifier = Modifier.testTag("moveFolder")) { Text("Move") }
                TextButton(onClick = onClear, modifier = Modifier.testTag("clearFolder")) { Text("Clear") }
            }
        }
    }
}

/**
 * Asks for a folder name. [title] says what it is for; [onDone] gets a valid
 * name (trimmed, no "/").
 */
@Composable
fun FolderNameDialog(title: String, initial: String, confirm: String, onDismiss: () -> Unit, onDone: (String) -> Unit) {
    var name by remember { mutableStateOf(initial) }
    val valid = FolderPath.validName(name)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                PlainField(name, { name = it }, "Folder name", "folderName", modifier = PopupTags)
                if (name.isNotBlank() && valid == null) {
                    Text("A folder name cannot contain \"/\".", color = MaterialTheme.colorScheme.error)
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = valid != null,
                modifier = PopupTags.testTag("confirmFolderName"),
                onClick = { valid?.let(onDone) },
            ) { Text(confirm) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** Picks the new parent of [path]: the top level or any folder it may move into. */
@Composable
fun MoveFolderDialog(path: List<String>, tree: List<FolderNode>, onDismiss: () -> Unit, onMove: (List<String>) -> Unit) {
    val targets = (listOf(emptyList<String>()) + FolderTree.allPaths(tree)).filter { FolderOps.canMove(path, it) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Move \"${path.lastOrNull().orEmpty()}\" to") },
        text = {
            Column(PopupTags.verticalScroll(rememberScrollState())) {
                if (targets.isEmpty()) Text("There is nowhere else to move this folder.")
                targets.forEach { p ->
                    Text(
                        if (p.isEmpty()) "Top level" else folderLabel(p),
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onMove(p) }
                            .testTag("moveTarget_${FolderPath.id(p).ifEmpty { "top" }}")
                            .padding(vertical = 10.dp),
                    )
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
