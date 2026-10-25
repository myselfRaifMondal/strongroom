package app.strongroom.android.core

import uniffi.strongroom.ItemKind

/*
 * Security Ranking (OQ-M9), a port of
 * apps/macos/Sources/StrongroomKit/SecurityRanking.swift. Keep the formula
 * identical on every platform.
 */

/** Tags with a meaning to the app (subset of the macOS `ReservedTags`). */
object ReservedTags {
    const val TEMPLATE_PREFIX = "template:"

    /** The first template id in the tags, lowercased. */
    fun templateId(tags: List<String>): String? {
        for (t in tags) {
            val low = t.trim().lowercase()
            if (!low.startsWith(TEMPLATE_PREFIX)) continue
            val id = low.removePrefix(TEMPLATE_PREFIX)
            if (id.isNotEmpty()) return id
        }
        return null
    }
}

/** How much an account matters, for ranking. */
enum class Importance(val label: String) {
    LOW("Low importance"),
    NORMAL("Normal"),
    CRITICAL("Critical account"),
    ;

    companion object {
        /** Tags that override the inferred importance. */
        const val CRITICAL_TAG = "priority:critical"
        const val LOW_TAG = "priority:low"

        private val criticalTemplates = setOf("email", "bank", "card", "server", "api-key", "crypto-wallet")

        /**
         * Order: the `priority:critical` / `priority:low` tag; then the
         * folder's category (first component); then the template; then the
         * kind (API and SSH keys); then the category of the first URL.
         * Critical categories: Email & Identity, Finance, Developer & Cloud.
         */
        fun infer(kind: ItemKind, tags: List<String>, folder: String?, urls: List<String>): Importance {
            val lowered = tags.map { it.trim().lowercase() }
            if (CRITICAL_TAG in lowered) return CRITICAL
            if (LOW_TAG in lowered) return LOW
            ServiceCategory.fromFolder(folder)?.let { return if (it.isCritical) CRITICAL else NORMAL }
            ReservedTags.templateId(tags)?.let { if (it in criticalTemplates) return CRITICAL }
            if (kind == ItemKind.API_KEY || kind == ItemKind.SSH_KEY) return CRITICAL
            for (u in urls) {
                ServiceCatalog.classify(u)?.let { return if (it.category.isCritical) CRITICAL else NORMAL }
            }
            return NORMAL
        }
    }
}

enum class RiskPriority(val label: String) {
    LOW("Low"),
    MEDIUM("Medium"),
    HIGH("High"),
    CRITICAL("Critical"),
}

/** Inputs of one item's risk score. No password, no hash. */
data class RiskInputs(
    /** `estimate_strength` score, 0 (very weak) ... 4 (very strong). */
    val strength: Int,
    /** How many *other* items use the same password. */
    val reusedWith: Int,
    /** Days since the password last changed. */
    val ageDays: Int,
    val hasTotp: Boolean,
    val importance: Importance,
)

/**
 * Risk score, 0 (fine) ... 100 (fix first).
 *
 *     base = strength + reuse + age + noTOTP                       (0 ... 95)
 *       strength  score 0: 40, 1: 30, 2: 18, 3: 8, 4: 0
 *       reuse     used by 0 others: 0, 1: 25, 2-3: 30, 4 or more: 35
 *       age       < 180 days: 0, 180-364: 5, 365-729: 10, 730+: 15
 *       noTOTP    no one-time code set: 5, else 0
 *     risk = min(100, round(base x weight))
 *       weight    critical account 1.5, normal 1.0, low importance 0.6
 *
 *     priority    risk >= 70 Critical, >= 45 High, >= 20 Medium, else Low
 */
object RiskScore {
    fun strengthPoints(s: Int): Int = when (s) {
        0 -> 40
        1 -> 30
        2 -> 18
        3 -> 8
        else -> 0
    }

    fun reusePoints(others: Int): Int = when {
        others < 1 -> 0
        others == 1 -> 25
        others <= 3 -> 30
        else -> 35
    }

    fun agePoints(days: Int): Int = when {
        days < 180 -> 0
        days < 365 -> 5
        days < 730 -> 10
        else -> 15
    }

    fun totpPoints(hasTotp: Boolean): Int = if (hasTotp) 0 else 5

    fun weight(i: Importance): Double = when (i) {
        Importance.CRITICAL -> 1.5
        Importance.NORMAL -> 1.0
        Importance.LOW -> 0.6
    }

    fun base(x: RiskInputs): Int =
        strengthPoints(x.strength) + reusePoints(x.reusedWith) + agePoints(x.ageDays) + totpPoints(x.hasTotp)

    /** Rounds half away from zero, like Swift's `rounded()`. */
    fun score(x: RiskInputs): Int = minOf(100, Math.round(base(x) * weight(x.importance)).toInt())

    fun priority(risk: Int): RiskPriority = when {
        risk >= 70 -> RiskPriority.CRITICAL
        risk >= 45 -> RiskPriority.HIGH
        risk >= 20 -> RiskPriority.MEDIUM
        else -> RiskPriority.LOW
    }
}

/**
 * Groups of items sharing one password. Passwords are compared in memory
 * and dropped when this returns; only item ids come out.
 */
object ReuseClusters {
    /** Each group has two or more ids, in input order. Empty passwords are not grouped. */
    fun compute(pairs: List<Pair<String, String>>): List<List<String>> {
        val byPassword = LinkedHashMap<String, MutableList<String>>()
        for ((id, pw) in pairs) {
            if (pw.isEmpty()) continue
            byPassword.getOrPut(pw) { ArrayList() }.add(id)
        }
        val groups = byPassword.values.filter { it.size > 1 }.map { it.toList() }
        byPassword.clear()
        return groups
    }
}

/** One ranked item. */
data class RankedItem(
    val id: String,
    val inputs: RiskInputs,
    val risk: Int,
    val priority: RiskPriority,
    /** Index into [RankingResult.clusters] ids, when the password is shared. */
    val cluster: Int?,
    val due: Boolean,
    val dueReasons: List<DueReason>,
)

data class ReuseCluster(
    val id: Int,
    val itemIds: List<String>,
    val maxImportance: Importance,
    val maxRisk: Int,
)

data class RankingResult(
    /** Worst first. */
    val items: List<RankedItem>,
    /** Sorted by the highest importance in the cluster, then size, then risk. */
    val clusters: List<ReuseCluster>,
) {
    val dueCount: Int get() = items.count { it.due }

    /** Accounts whose password is used on at least one other account. */
    val sharedCount: Int get() = clusters.sumOf { it.itemIds.size }

    fun count(p: RiskPriority): Int = items.count { it.priority == p }

    fun item(id: String): RankedItem? = items.firstOrNull { it.id == id }

    companion object {
        val EMPTY = RankingResult(emptyList(), emptyList())
    }
}

/**
 * Builds the ranking. Inputs carry no secrets: reuse comes in as clusters
 * of ids (from [ReuseClusters]), strength as a score.
 */
object SecurityRanking {
    data class Entry(
        val id: String,
        val strength: Int,
        /** When the current password was set (Unix seconds). */
        val passwordChangedAt: Long,
        val hasTotp: Boolean,
        val importance: Importance,
    )

    fun ageDays(since: Long, now: Long): Int = maxOf(0L, (now - since) / 86_400).toInt()

    fun build(entries: List<Entry>, clusters: List<List<String>>, policy: RotationSettings, now: Long): RankingResult {
        val clusterOf = HashMap<String, Int>()
        clusters.forEachIndexed { i, ids -> ids.forEach { clusterOf[it] = i } }
        val ranked = entries.map { e ->
            val cl = clusterOf[e.id]
            val inputs = RiskInputs(
                strength = e.strength,
                reusedWith = cl?.let { clusters[it].size - 1 } ?: 0,
                ageDays = ageDays(e.passwordChangedAt, now),
                hasTotp = e.hasTotp,
                importance = e.importance,
            )
            val risk = RiskScore.score(inputs)
            val reasons = RotationPolicy.dueReasons(inputs, policy)
            RankedItem(e.id, inputs, risk, RiskScore.priority(risk), cl, reasons.isNotEmpty(), reasons)
        }
        val byId = ranked.associateBy { it.id }
        val outClusters = clusters.mapIndexed { i, ids ->
            val members = ids.mapNotNull { byId[it] }
            ReuseCluster(
                id = i,
                itemIds = members.sortedByDescending { it.risk }.map { it.id },
                maxImportance = members.maxOfOrNull { it.inputs.importance } ?: Importance.NORMAL,
                maxRisk = members.maxOfOrNull { it.risk } ?: 0,
            )
        }.sortedWith(
            compareByDescending<ReuseCluster> { it.maxImportance }
                .thenByDescending { it.itemIds.size }
                .thenByDescending { it.maxRisk },
        )
        val sorted = ranked.sortedWith(
            compareByDescending<RankedItem> { it.risk }
                .thenByDescending { it.inputs.importance }
                .thenBy { it.id },
        )
        return RankingResult(sorted, outClusters)
    }

    /**
     * When the current password was set: the oldest revision in the
     * unbroken run of revisions that already had this password, else the
     * item's creation. `modified_at` alone would reset whenever the folder
     * or title changes, so the history is used. [revisions] are
     * (modified_at, password) pairs of `item_history`.
     */
    fun passwordChangedAt(current: String?, modifiedAt: Long, createdAt: Long, revisions: List<Pair<Long, String?>>): Long {
        var changed = modifiedAt
        val older = revisions.filter { it.first <= modifiedAt }.sortedByDescending { it.first }
        var sawDifferent = false
        for ((at, pw) in older) {
            if (pw == current) changed = minOf(changed, at) else { sawDifferent = true; break }
        }
        if (!sawDifferent) changed = minOf(changed, createdAt)
        return changed
    }
}
