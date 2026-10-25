package app.strongroom.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.strongroom.android.StrongroomApp
import app.strongroom.android.core.Clock
import app.strongroom.android.core.FolderPath
import app.strongroom.android.core.Importance
import app.strongroom.android.core.RankedItem
import app.strongroom.android.core.RankingResult
import app.strongroom.android.core.RiskPriority
import app.strongroom.android.core.RotationInterval
import app.strongroom.android.core.RotationReminder
import app.strongroom.android.core.RotationSettings
import app.strongroom.android.core.Session
import app.strongroom.android.core.VaultAnalysis
import uniffi.strongroom.HealthReport
import uniffi.strongroom.ItemSummary

fun RiskPriority.color(): Color = when (this) {
    RiskPriority.CRITICAL -> Color(0xFFD32F2F)
    RiskPriority.HIGH -> Color(0xFFF57C00)
    RiskPriority.MEDIUM -> Color(0xFFFBC02D)
    RiskPriority.LOW -> Color(0xFF388E3C)
}

private fun scoreColor(score: Int): Color = when {
    score >= 80 -> Color(0xFF388E3C)
    score >= 50 -> Color(0xFFF57C00)
    else -> Color(0xFFD32F2F)
}

/** "fair · used on 2 other accounts · 400 d old · no one-time code · due · Social › X" */
fun rankingReasons(r: RankedItem, folder: String?): String {
    val x = r.inputs
    val parts = ArrayList<String>()
    parts.add(listOf("very weak", "weak", "fair", "good", "strong")[x.strength.coerceIn(0, 4)])
    if (x.reusedWith > 0) parts.add("used on ${x.reusedWith} other account${if (x.reusedWith == 1) "" else "s"}")
    parts.add(if (x.ageDays >= 365) "${x.ageDays / 365} yr old" else "${x.ageDays} d old")
    if (!x.hasTotp) parts.add("no one-time code")
    if (r.due) parts.add("due")
    val f = FolderPath.components(folder).joinToString(" › ")
    if (f.isNotEmpty()) parts.add(f)
    return parts.joinToString(" · ")
}

/**
 * Shown on the item list when passwords are due for a change. The text is
 * only a count. "Later" hides it for a week.
 */
@Composable
fun RotationBanner(count: Int, onReview: () -> Unit, onSnooze: () -> Unit) {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.tertiaryContainer),
        modifier = Modifier.fillMaxWidth().testTag("rotationBanner"),
    ) {
        Column(Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
            Text(
                RotationReminder.bannerText(count),
                color = MaterialTheme.colorScheme.onTertiaryContainer,
                style = MaterialTheme.typography.titleSmall,
                modifier = Modifier.testTag("rotationBannerText"),
            )
            Row {
                TextButton(onClick = onReview, modifier = Modifier.testTag("rotationReview")) { Text("Review") }
                TextButton(onClick = onSnooze, modifier = Modifier.testTag("rotationSnooze")) { Text("Remind me in a week") }
            }
        }
    }
}

@Composable
private fun StatTile(value: String, label: String, tint: Color, tag: String) {
    Card(Modifier.widthIn(min = 104.dp).testTag(tag)) {
        Column(Modifier.padding(12.dp)) {
            Text(value, style = MaterialTheme.typography.headlineSmall, color = tint, fontWeight = FontWeight.SemiBold)
            Text(label, style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
private fun RankingRow(nav: Nav, s: ItemSummary, r: RankedItem) {
    Card(onClick = { nav.push(Route.Detail(r.id)) }, modifier = Modifier.fillMaxWidth().testTag("rank_${s.title}")) {
        Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(
                Modifier.background(r.priority.color().copy(alpha = 0.22f), RoundedCornerShape(6.dp)).widthIn(min = 40.dp).padding(6.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text("${r.risk}", fontWeight = FontWeight.SemiBold, modifier = Modifier.testTag("risk_${s.title}"))
            }
            Column(Modifier.weight(1f)) {
                Text(
                    s.title + if (r.inputs.importance == Importance.CRITICAL) "  (critical account)" else "",
                    style = MaterialTheme.typography.titleSmall,
                )
                Text("${r.priority.label} priority", style = MaterialTheme.typography.labelMedium, color = r.priority.color())
                Text(rankingReasons(r, s.folder), style = MaterialTheme.typography.bodySmall)
            }
            TextButton(onClick = { nav.push(Route.Edit(r.id)) }, modifier = Modifier.testTag("change_${s.title}")) { Text("Change") }
        }
    }
}

@Composable
fun RankingScreen(nav: Nav) {
    val vault = Session.vault ?: return
    val app = LocalContext.current.applicationContext as StrongroomApp
    val op = rememberOpState()
    var ranking by remember { mutableStateOf(RankingResult.EMPTY) }
    var health by remember { mutableStateOf<HealthReport?>(null) }
    var summaries by remember { mutableStateOf<Map<String, ItemSummary>>(emptyMap()) }
    var groups by retain("groups") { mutableStateOf(false) }
    var dueOnly by retain("dueOnly") { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        op.run {
            val now = Clock.nowSeconds()
            summaries = core { vault.search("", null, null) }.associateBy { it.id }
            ranking = core { VaultAnalysis.ranking(vault, app.rotationSettings, now) }
            health = runCatching { core { vault.passwordHealth(now) } }.getOrNull()
        }
    }

    ScreenScaffold(title = "Security Ranking", onBack = { nav.pop() }) {
        Text(
            "Every password scored 0-100 from strength, reuse, age and a missing one-time code, weighted by " +
                "how important the account is. Fix the top of the list first.",
            style = MaterialTheme.typography.bodySmall,
        )
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            health?.let { StatTile("${it.securityScore}", "Security score", scoreColor(it.securityScore.toInt()), "tileScore") }
            StatTile("${ranking.dueCount}", "Due for a change", if (ranking.dueCount > 0) Color(0xFFF57C00) else Color(0xFF388E3C), "tileDue")
            StatTile("${ranking.sharedCount}", "Share a password", if (ranking.sharedCount > 0) Color(0xFFF57C00) else Color(0xFF388E3C), "tileShared")
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            RiskPriority.entries.reversed().forEach { p ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(9.dp).background(p.color(), CircleShape))
                    Text(" ${p.label} ${ranking.count(p)}", style = MaterialTheme.typography.bodySmall, modifier = Modifier.testTag("count_${p.name}"))
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            FilterChip(selected = !groups, onClick = { groups = false }, label = { Text("Ranking") }, modifier = Modifier.testTag("modeRanking"))
            FilterChip(selected = groups, onClick = { groups = true }, label = { Text("Same password") }, modifier = Modifier.testTag("modeGroups"))
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(dueOnly, { dueOnly = it }, modifier = Modifier.testTag("dueOnly"))
            Text("Only due for a change")
        }
        OpStatus(op)
        if (!op.busy && ranking.items.isEmpty()) {
            Text("No passwords to rank. Items with a password appear here, worst first.", modifier = Modifier.testTag("rankingEmpty"))
        }
        if (!groups) {
            val visible = ranking.items.filter { !dueOnly || it.due }
            if (visible.isEmpty() && ranking.items.isNotEmpty()) Text("Nothing is due for a change.", modifier = Modifier.testTag("nothingDue"))
            visible.forEach { r -> summaries[r.id]?.let { RankingRow(nav, it, r) } }
        } else {
            if (!op.busy && ranking.clusters.isEmpty()) {
                Text("No password is shared between accounts.", modifier = Modifier.testTag("noClusters"))
            }
            ranking.clusters.forEach { c ->
                val members = c.itemIds.mapNotNull { ranking.item(it) }.filter { !dueOnly || it.due }
                if (members.isNotEmpty()) {
                    Text(
                        "Same password on ${c.itemIds.size} accounts" +
                            if (c.maxImportance == Importance.CRITICAL) " (includes critical accounts)" else "",
                        style = MaterialTheme.typography.titleSmall,
                        modifier = Modifier.testTag("cluster_${c.id}"),
                    )
                    members.forEach { r -> summaries[r.id]?.let { RankingRow(nav, it, r) } }
                }
            }
        }
        HorizontalDivider()
        Text(
            "\"Change\" opens the item editor; use the generator there. Nothing is replaced until you save. " +
                "Tag an item ${Importance.CRITICAL_TAG} or ${Importance.LOW_TAG} to change its importance.",
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

@Composable
fun HealthScreen(nav: Nav) {
    val vault = Session.vault ?: return
    val op = rememberOpState()
    var health by remember { mutableStateOf<HealthReport?>(null) }
    var summaries by remember { mutableStateOf<Map<String, ItemSummary>>(emptyMap()) }

    LaunchedEffect(Unit) {
        op.run {
            summaries = core { vault.search("", null, null) }.associateBy { it.id }
            health = core { vault.passwordHealth(Clock.nowSeconds()) }
        }
    }

    ScreenScaffold(title = "Password Health", onBack = { nav.pop() }) {
        OpStatus(op)
        val h = health ?: return@ScreenScaffold
        val score = h.securityScore.toInt()
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(
                "$score",
                style = MaterialTheme.typography.displaySmall,
                color = scoreColor(score),
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.testTag("healthScore"),
            )
            Column {
                Text(
                    when {
                        score >= 80 -> "Looking good"
                        score >= 50 -> "Room to improve"
                        else -> "Needs attention"
                    },
                    style = MaterialTheme.typography.titleMedium,
                )
                Text("Security score: the share of passwords that are strong, unique and changed within a year.", style = MaterialTheme.typography.bodySmall)
            }
        }
        OutlinedButton(onClick = { nav.push(Route.Ranking) }, modifier = Modifier.testTag("openRankingFromHealth")) {
            Text("Open Security Ranking")
        }
        HealthGroup(nav, "Reused passwords", "Used by more than one item. Change each to a unique password.", h.reusedItemIds, summaries, "reused")
        HealthGroup(nav, "Weak passwords", "Easy to guess. Replace them with generated ones.", h.weakItemIds, summaries, "weak")
        HealthGroup(nav, "Old passwords", "Not changed for more than a year.", h.oldItemIds, summaries, "old")
    }
}

@Composable
private fun HealthGroup(nav: Nav, title: String, help: String, ids: List<String>, summaries: Map<String, ItemSummary>, tag: String) {
    HorizontalDivider()
    Text("$title (${ids.size})", style = MaterialTheme.typography.titleSmall, modifier = Modifier.testTag("health_$tag"))
    Text(help, style = MaterialTheme.typography.bodySmall)
    if (ids.isEmpty()) Text("None", color = Color(0xFF388E3C))
    ids.forEach { id ->
        val s = summaries[id] ?: return@forEach
        Card(onClick = { nav.push(Route.Detail(id)) }, modifier = Modifier.fillMaxWidth().testTag("health_${tag}_${s.title}")) {
            Column(Modifier.padding(12.dp)) {
                Text(s.title, style = MaterialTheme.typography.titleSmall)
                Text(
                    listOfNotNull(s.subtitle, FolderPath.components(s.folder).joinToString(" › ").ifEmpty { null }).joinToString(" - "),
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
    }
}

/** Rotation reminder intervals, for the Settings screen. */
@Composable
fun RotationSettingsSection(app: StrongroomApp) {
    var settings by remember { mutableStateOf(app.rotationSettings) }
    fun save(s: RotationSettings) { settings = s; app.rotationSettings = s }
    Text("Password rotation", style = MaterialTheme.typography.titleSmall)
    Text(
        "A password is due for a change when it is older than this, used on another account, or weak. " +
            "The item list shows how many are due after unlock.",
    )
    Text("Critical accounts (email, finance, developer)", style = MaterialTheme.typography.labelLarge)
    IntervalChips(settings.critical, "rotCritical") { save(settings.copy(critical = it)) }
    Text("Other accounts", style = MaterialTheme.typography.labelLarge)
    IntervalChips(settings.other, "rotOther") { save(settings.copy(other = it)) }
    if (settings.isSnoozed(Clock.nowSeconds())) {
        TextButton(onClick = { save(settings.copy(snoozedUntil = null)) }, modifier = Modifier.testTag("rotUnsnooze")) {
            Text("Show the reminder again now")
        }
    }
}

@Composable
private fun IntervalChips(value: RotationInterval, tag: String, onPick: (RotationInterval) -> Unit) {
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        RotationInterval.entries.forEach { i ->
            FilterChip(
                selected = value == i,
                onClick = { onPick(i) },
                label = { Text(i.label) },
                modifier = Modifier.testTag("${tag}_${i.days}"),
            )
        }
    }
}
