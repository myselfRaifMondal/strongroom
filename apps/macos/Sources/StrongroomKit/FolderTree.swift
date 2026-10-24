import Foundation

/// Folder hierarchy on top of the existing `folder` string (no format or FFI
/// change). A folder is a path whose components are separated by "/", with
/// optional spaces around the separator: "Social/Instagram",
/// "Social / Instagram" and " Social//Instagram/ " all mean
/// ["Social", "Instagram"]. The app writes the canonical form "Social/Instagram".
/// Components are compared exactly (after trimming), so "Social" and "social"
/// are two different folders.
public enum FolderPath {
    public static let separator: Character = "/"

    public static func components(_ folder: String?) -> [String] {
        guard let folder else { return [] }
        return folder.split(separator: separator, omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// nil for the root (no folder).
    public static func join(_ components: [String]) -> String? {
        components.isEmpty ? nil : components.joined(separator: String(separator))
    }

    public static func canonical(_ folder: String?) -> String? { join(components(folder)) }

    /// Stable identifier of a path (used for sidebar selection).
    public static func id(_ components: [String]) -> String { components.joined(separator: String(separator)) }

    public static func isPrefix(_ prefix: [String], of path: [String]) -> Bool {
        prefix.count <= path.count && Array(path.prefix(prefix.count)) == prefix
    }

    /// True when `folder` is `prefix` or inside it. An empty prefix (the root)
    /// contains everything. `search` in the core only matches an exact
    /// folder, so subtree filtering happens here, client-side.
    public static func isInSubtree(_ folder: String?, of prefix: [String]) -> Bool {
        isPrefix(prefix, of: components(folder))
    }

    /// True when the item sits directly in `path` (not in a sub-folder).
    public static func isDirectlyIn(_ folder: String?, _ path: [String]) -> Bool {
        components(folder) == path
    }

    /// A valid new folder name: trimmed, non-empty, without "/".
    public static func validName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains(separator) else { return nil }
        return name
    }
}

/// One node of the sidebar tree.
public struct FolderNode: Identifiable, Hashable, Sendable {
    public var id: String { FolderPath.id(path) }
    public let name: String
    public let path: [String]
    /// Items whose folder is exactly this path.
    public let directCount: Int
    /// Items in this folder and every sub-folder.
    public let totalCount: Int
    /// nil for a leaf, so `OutlineGroup` shows no disclosure triangle.
    public let children: [FolderNode]?

    public init(name: String, path: [String], directCount: Int, totalCount: Int, children: [FolderNode]?) {
        self.name = name
        self.path = path
        self.directCount = directCount
        self.totalCount = totalCount
        self.children = children
    }

    /// Depth-first list of this node and its descendants.
    public var flattened: [FolderNode] { [self] + (children ?? []).flatMap(\.flattened) }
}

public enum FolderTree {
    private final class Builder {
        var direct = 0
        var children: [String: Builder] = [:]
        func node(name: String, path: [String]) -> FolderNode {
            let kids = children.keys
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { children[$0]!.node(name: $0, path: path + [$0]) }
            let total = direct + kids.reduce(0) { $0 + $1.totalCount }
            return FolderNode(name: name, path: path, directCount: direct, totalCount: total,
                              children: kids.isEmpty ? nil : kids)
        }
    }

    /// Builds the tree from every item's `folder` string. Items without a
    /// folder are not part of the tree (they show under "All Items").
    /// `extraPaths` adds folders that have no items yet (created in this
    /// session; a folder only persists once an item is in it).
    public static func build(folders: [String?], extraPaths: [[String]] = []) -> [FolderNode] {
        let root = Builder()
        func insert(_ path: [String], countItem: Bool) {
            guard !path.isEmpty else { return }
            var node = root
            for c in path {
                if let next = node.children[c] { node = next } else {
                    let next = Builder()
                    node.children[c] = next
                    node = next
                }
            }
            if countItem { node.direct += 1 }
        }
        for f in folders { insert(FolderPath.components(f), countItem: true) }
        for p in extraPaths { insert(p, countItem: false) }
        return root.node(name: "", path: []).children ?? []
    }

    public static func find(_ path: [String], in nodes: [FolderNode]) -> FolderNode? {
        guard let first = path.first, let node = nodes.first(where: { $0.name == first }) else { return nil }
        if path.count == 1 { return node }
        return find(Array(path.dropFirst()), in: node.children ?? [])
    }

    public static func allPaths(_ nodes: [FolderNode]) -> [[String]] {
        nodes.flatMap(\.flattened).map(\.path)
    }
}

/// Rename and move: both rewrite the folder of every item in the subtree with
/// `update_item`. Nothing about folders is stored apart from the items.
public enum FolderOps {
    /// The path after renaming its last component.
    public static func renamed(_ path: [String], to newName: String) -> [String]? {
        guard !path.isEmpty, let name = FolderPath.validName(newName) else { return nil }
        return Array(path.dropLast()) + [name]
    }

    /// The path after moving it (with its subtree) under `parent` ([] = top level).
    public static func moved(_ path: [String], toParent parent: [String]) -> [String]? {
        guard canMove(path, toParent: parent), let last = path.last else { return nil }
        return parent + [last]
    }

    /// Not into itself or one of its descendants, and not where it already is.
    public static func canMove(_ path: [String], toParent parent: [String]) -> Bool {
        guard !path.isEmpty else { return false }
        if FolderPath.isPrefix(path, of: parent) { return false }
        return Array(path.dropLast()) != parent
    }

    /// The new folder string for an item at `folder` when the subtree `from`
    /// becomes `to`; nil when the item is outside the subtree.
    public static func relocated(_ folder: String?, from: [String], to: [String]) -> String? {
        let comps = FolderPath.components(folder)
        guard !from.isEmpty, FolderPath.isPrefix(from, of: comps) else { return nil }
        return FolderPath.join(to + comps.dropFirst(from.count)) ?? ""
    }

    public struct Change: Equatable, Sendable {
        public let id: String
        public let folder: String
    }

    /// Every item to update, with its new folder. Items whose folder string
    /// would not change are skipped (an unchanged update is a no-op anyway).
    public static func plan(items: [(id: String, folder: String?)], from: [String], to: [String]) -> [Change] {
        guard from != to else { return [] }
        return items.compactMap { item in
            guard let new = relocated(item.folder, from: from, to: to), new != item.folder else { return nil }
            return Change(id: item.id, folder: new)
        }
    }

    /// Rewrites session-only (empty) folders after a rename/move.
    public static func relocatePaths(_ paths: [[String]], from: [String], to: [String]) -> [[String]] {
        paths.map { p in FolderPath.isPrefix(from, of: p) ? to + p.dropFirst(from.count) : p }
    }
}
