package app.strongroom.android.core

import uniffi.strongroom.Vault
import uniffi.strongroom.estimateStrength

/**
 * Reads an unlocked vault into the inputs of the ranking, and applies folder
 * renames and moves. Passwords are read with `get_item`/`item_history`,
 * compared and scored inside [ranking], and not kept: nothing here is stored
 * or logged.
 */
object VaultAnalysis {
    /**
     * Strength scores keyed by item id and the `modified_at` they were
     * computed for, so unchanged items are not re-estimated on every
     * reload. Holds no password. Cleared on lock ([Session]).
     */
    private var strengthCache: Map<String, Pair<Long, Int>> = emptyMap()
    private var generation = 0L

    @Synchronized
    fun clear() {
        strengthCache = emptyMap()
        generation++
    }

    private fun snapshot(): Pair<Map<String, Pair<Long, Int>>, Long> = synchronized(this) { strengthCache to generation }

    fun ranking(vault: Vault, policy: RotationSettings, now: Long): RankingResult {
        val (cache, gen) = snapshot()
        val scores = HashMap<String, Pair<Long, Int>>()
        val entries = ArrayList<SecurityRanking.Entry>()
        val pairs = ArrayList<Pair<String, String>>()
        for (s in vault.search("", null, null)) {
            val item = runCatching { vault.getItem(s.id) }.getOrNull() ?: continue
            val pw = item.data.password
            if (pw.isNullOrEmpty()) continue
            pairs.add(s.id to pw)
            val cached = cache[s.id]
            val score = if (cached != null && cached.first == item.modifiedAt) {
                cached.second
            } else {
                estimateStrength(pw).score.toInt()
            }
            scores[s.id] = item.modifiedAt to score
            val revisions = runCatching { vault.itemHistory(s.id) }.getOrDefault(emptyList())
                .map { it.modifiedAt to it.data.password }
            val changed = SecurityRanking.passwordChangedAt(pw, item.modifiedAt, item.createdAt, revisions)
            entries.add(
                SecurityRanking.Entry(
                    id = s.id,
                    strength = score,
                    passwordChangedAt = changed,
                    hasTotp = !item.data.totp.isNullOrBlank(),
                    importance = Importance.infer(item.data.kind, item.data.tags, item.data.folder, item.data.urls),
                ),
            )
        }
        val clusters = ReuseClusters.compute(pairs)
        pairs.clear()
        // Only items still present; and never refill the cache after a lock.
        synchronized(this) { if (generation == gen) strengthCache = scores }
        return SecurityRanking.build(entries, clusters, policy, now)
    }

    /**
     * Rewrites the folder of every live item in the subtree [from] so it
     * sits under [to] (rename or move). Each item keeps its old folder in
     * its history. Returns how many items changed.
     */
    fun relocateFolder(vault: Vault, from: List<String>, to: List<String>, now: Long): Int {
        val plan = FolderOps.plan(vault.search("", null, null).map { it.id to it.folder }, from, to)
        for (c in plan) {
            val item = vault.getItem(c.id)
            vault.updateItem(c.id, item.data.copy(folder = c.folder), now)
        }
        return plan.size
    }
}
