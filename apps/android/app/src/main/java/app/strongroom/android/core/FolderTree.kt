package app.strongroom.android.core

/*
 * Folder hierarchy on top of the existing `folder` string (no format or FFI
 * change; OQ-M6). A port of apps/macos/Sources/StrongroomKit/FolderTree.swift.
 */

/**
 * A folder is a path whose components are separated by "/", with optional
 * spaces around the separator: "Social/Instagram", "Social / Instagram" and
 * " Social//Instagram/ " all mean ["Social", "Instagram"]. The app writes
 * the canonical form "Social/Instagram". Components are compared exactly
 * (after trimming), so "Social" and "social" are two different folders.
 */
object FolderPath {
    const val SEPARATOR = '/'

    fun components(folder: String?): List<String> =
        folder?.split(SEPARATOR)?.map { it.trim() }?.filter { it.isNotEmpty() } ?: emptyList()

    /** null for the root (no folder). */
    fun join(components: List<String>): String? =
        if (components.isEmpty()) null else components.joinToString(SEPARATOR.toString())

    fun canonical(folder: String?): String? = join(components(folder))

    /** Stable identifier of a path (used for selection and test tags). */
    fun id(components: List<String>): String = components.joinToString(SEPARATOR.toString())

    fun isPrefix(prefix: List<String>, path: List<String>): Boolean =
        prefix.size <= path.size && path.subList(0, prefix.size) == prefix

    /**
     * True when [folder] is [prefix] or inside it. An empty prefix (the root)
     * contains everything. `search` in the core only matches an exact
     * folder, so subtree filtering happens here, client-side.
     */
    fun isInSubtree(folder: String?, prefix: List<String>): Boolean = isPrefix(prefix, components(folder))

    /** True when the item sits directly in [path] (not in a sub-folder). */
    fun isDirectlyIn(folder: String?, path: List<String>): Boolean = components(folder) == path

    /** A valid new folder name: trimmed, non-empty, without "/". */
    fun validName(raw: String): String? {
        val name = raw.trim()
        return if (name.isEmpty() || name.contains(SEPARATOR)) null else name
    }
}

/** One node of the folder tree. */
data class FolderNode(
    val name: String,
    val path: List<String>,
    /** Items whose folder is exactly this path. */
    val directCount: Int,
    /** Items in this folder and every sub-folder. */
    val totalCount: Int,
    val children: List<FolderNode>,
) {
    val id: String get() = FolderPath.id(path)

    /** Depth-first list of this node and its descendants. */
    val flattened: List<FolderNode> get() = listOf(this) + children.flatMap { it.flattened }
}

object FolderTree {
    /**
     * Natural order like Finder's: case-insensitive, with digit runs compared
     * as numbers ("a2" before "a10"). Exact spelling breaks ties.
     */
    val naturalOrder: Comparator<String> = Comparator { a, b ->
        val chunk = Regex("\\d+|\\D+")
        val ca = chunk.findAll(a).map { it.value }.toList()
        val cb = chunk.findAll(b).map { it.value }.toList()
        for (i in 0 until minOf(ca.size, cb.size)) {
            val x = ca[i]
            val y = cb[i]
            val c = if (x[0].isDigit() && y[0].isDigit()) {
                val nx = x.trimStart('0')
                val ny = y.trimStart('0')
                if (nx.length != ny.length) nx.length - ny.length else nx.compareTo(ny)
            } else {
                x.compareTo(y, ignoreCase = true)
            }
            if (c != 0) return@Comparator c
        }
        if (ca.size != cb.size) ca.size - cb.size else a.compareTo(b)
    }

    private class Builder {
        var direct = 0
        val children = HashMap<String, Builder>()

        fun node(name: String, path: List<String>): FolderNode {
            val kids = children.keys.sortedWith(naturalOrder).map { children.getValue(it).node(it, path + it) }
            val total = direct + kids.sumOf { it.totalCount }
            return FolderNode(name, path, direct, total, kids)
        }
    }

    /**
     * Builds the tree from every item's `folder` string. Items without a
     * folder are not part of the tree. [extraPaths] adds folders that have
     * no items yet (created in this session; a folder only persists once an
     * item is in it).
     */
    fun build(folders: List<String?>, extraPaths: List<List<String>> = emptyList()): List<FolderNode> {
        val root = Builder()
        fun insert(path: List<String>, countItem: Boolean) {
            if (path.isEmpty()) return
            var node = root
            for (c in path) node = node.children.getOrPut(c) { Builder() }
            if (countItem) node.direct++
        }
        folders.forEach { insert(FolderPath.components(it), countItem = true) }
        extraPaths.forEach { insert(it, countItem = false) }
        return root.node("", emptyList()).children
    }

    fun find(path: List<String>, nodes: List<FolderNode>): FolderNode? {
        val first = path.firstOrNull() ?: return null
        val node = nodes.firstOrNull { it.name == first } ?: return null
        return if (path.size == 1) node else find(path.drop(1), node.children)
    }

    fun allPaths(nodes: List<FolderNode>): List<List<String>> = nodes.flatMap { it.flattened }.map { it.path }

    /**
     * The rows to show: every top-level folder, plus the children of each
     * expanded folder, depth-first. Paired with each row's depth.
     */
    fun visibleRows(nodes: List<FolderNode>, expanded: Set<String>): List<Pair<FolderNode, Int>> {
        val out = ArrayList<Pair<FolderNode, Int>>()
        fun walk(list: List<FolderNode>, depth: Int) {
            for (n in list) {
                out.add(n to depth)
                if (n.id in expanded) walk(n.children, depth + 1)
            }
        }
        walk(nodes, 0)
        return out
    }
}

/**
 * Rename and move: both rewrite the folder of every item in the subtree with
 * `update_item`. Nothing about folders is stored apart from the items.
 */
object FolderOps {
    /** The path after renaming its last component. */
    fun renamed(path: List<String>, newName: String): List<String>? {
        val name = FolderPath.validName(newName) ?: return null
        if (path.isEmpty()) return null
        return path.dropLast(1) + name
    }

    /** The path after moving it (with its subtree) under [parent] (empty = top level). */
    fun moved(path: List<String>, parent: List<String>): List<String>? {
        if (!canMove(path, parent)) return null
        return parent + path.last()
    }

    /** Not into itself or one of its descendants, and not where it already is. */
    fun canMove(path: List<String>, parent: List<String>): Boolean {
        if (path.isEmpty()) return false
        if (FolderPath.isPrefix(path, parent)) return false
        return path.dropLast(1) != parent
    }

    /**
     * The new folder string for an item at [folder] when the subtree [from]
     * becomes [to]; null when the item is outside the subtree.
     */
    fun relocated(folder: String?, from: List<String>, to: List<String>): String? {
        val comps = FolderPath.components(folder)
        if (from.isEmpty() || !FolderPath.isPrefix(from, comps)) return null
        return FolderPath.join(to + comps.drop(from.size)) ?: ""
    }

    data class Change(val id: String, val folder: String)

    /**
     * Every item to update, with its new folder. Items whose folder string
     * would not change are skipped.
     */
    fun plan(items: List<Pair<String, String?>>, from: List<String>, to: List<String>): List<Change> {
        if (from == to) return emptyList()
        return items.mapNotNull { (id, folder) ->
            val new = relocated(folder, from, to) ?: return@mapNotNull null
            if (new == folder) null else Change(id, new)
        }
    }

    /** Rewrites session-only (empty) folders after a rename/move. */
    fun relocatePaths(paths: List<List<String>>, from: List<String>, to: List<String>): List<List<String>> =
        paths.map { p -> if (FolderPath.isPrefix(from, p)) to + p.drop(from.size) else p }
}
