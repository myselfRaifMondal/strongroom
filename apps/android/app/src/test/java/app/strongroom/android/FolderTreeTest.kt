package app.strongroom.android

import app.strongroom.android.core.FolderOps
import app.strongroom.android.core.FolderPath
import app.strongroom.android.core.FolderTree
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Same cases as apps/macos/Tests/StrongroomKitTests/HierarchyTests.swift. */
class FolderPathTest {
    @Test fun parsesBothSeparatorsAndSpaces() {
        assertEquals(listOf("Social", "Instagram"), FolderPath.components("Social/Instagram"))
        assertEquals(listOf("Social", "Instagram"), FolderPath.components("Social / Instagram"))
        assertEquals(listOf("Social", "Instagram"), FolderPath.components("  Social//Instagram/ "))
        assertEquals(listOf("Banking"), FolderPath.components("Banking"))
        assertEquals(emptyList<String>(), FolderPath.components(null))
        assertEquals(emptyList<String>(), FolderPath.components(""))
        assertEquals(emptyList<String>(), FolderPath.components(" / "))
        assertEquals("Social/Instagram", FolderPath.canonical("Social / Instagram "))
        assertNull(FolderPath.canonical("  "))
        assertNull(FolderPath.join(emptyList()))
    }

    @Test fun validNames() {
        assertEquals("Work", FolderPath.validName("  Work "))
        assertNull(FolderPath.validName("a/b"))
        assertNull(FolderPath.validName("   "))
    }

    @Test fun prefixFiltering() {
        assertTrue(FolderPath.isInSubtree("Social/Instagram", listOf("Social")))
        assertTrue(FolderPath.isInSubtree("Social / Instagram", listOf("Social", "Instagram")))
        assertTrue(FolderPath.isInSubtree("Social", listOf("Social")))
        assertTrue(FolderPath.isInSubtree(null, emptyList()))
        assertTrue(FolderPath.isInSubtree("Anything/Deep", emptyList()))
        assertFalse("prefix is per component", FolderPath.isInSubtree("Socialite", listOf("Social")))
        assertFalse(FolderPath.isInSubtree("Social", listOf("Social", "Instagram")))
        assertFalse(FolderPath.isInSubtree(null, listOf("Social")))
        assertFalse("components compare exactly", FolderPath.isInSubtree("social/instagram", listOf("Social")))
        assertTrue(FolderPath.isDirectlyIn("Social/Instagram", listOf("Social", "Instagram")))
        assertFalse(FolderPath.isDirectlyIn("Social/Instagram", listOf("Social")))
    }
}

class FolderTreeTest {
    private val folders = listOf(
        "Social/Instagram", "Social / Instagram", "Social/Twitter", "Social",
        "Banking", null, "", "Work/Servers/Prod", "Work/Servers/Prod",
    )

    @Test fun buildsTreeWithCounts() {
        val tree = FolderTree.build(folders)
        assertEquals(listOf("Banking", "Social", "Work"), tree.map { it.name })
        val social = FolderTree.find(listOf("Social"), tree)!!
        assertEquals(1, social.directCount)
        assertEquals(4, social.totalCount)
        assertEquals(listOf("Instagram", "Twitter"), social.children.map { it.name })
        val ig = FolderTree.find(listOf("Social", "Instagram"), tree)!!
        assertEquals(2, ig.totalCount)
        assertEquals(2, ig.directCount)
        assertTrue(ig.children.isEmpty())
        assertEquals("Social/Instagram", ig.id)
        val work = FolderTree.find(listOf("Work"), tree)!!
        assertEquals(0, work.directCount)
        assertEquals(2, work.totalCount)
        assertEquals(2, FolderTree.find(listOf("Work", "Servers", "Prod"), tree)?.totalCount)
        assertNull(FolderTree.find(listOf("Nope"), tree))
        assertEquals(7, FolderTree.allPaths(tree).size)
    }

    @Test fun sortsNaturally() {
        assertEquals(listOf("A", "a2", "a10", "b"), FolderTree.build(listOf("b", "A", "a10", "a2")).map { it.name })
    }

    @Test fun emptySessionFolders() {
        val tree = FolderTree.build(listOf("Social"), listOf(listOf("Social", "New"), listOf("Empty")))
        assertEquals(0, FolderTree.find(listOf("Social", "New"), tree)?.totalCount)
        assertEquals(1, FolderTree.find(listOf("Social"), tree)?.totalCount)
        assertEquals(0, FolderTree.find(listOf("Empty"), tree)?.totalCount)
    }

    @Test fun visibleRowsFollowExpansion() {
        val tree = FolderTree.build(folders)
        assertEquals(listOf("Banking", "Social", "Work"), FolderTree.visibleRows(tree, emptySet()).map { it.first.name })
        val rows = FolderTree.visibleRows(tree, setOf("Social", "Work"))
        assertEquals(listOf("Banking" to 0, "Social" to 0, "Instagram" to 1, "Twitter" to 1, "Work" to 0, "Servers" to 1), rows.map { it.first.name to it.second })
        assertNotNull(rows.firstOrNull { it.first.id == "Work/Servers" })
    }
}

class FolderOpsTest {
    @Test fun renameAndMovePaths() {
        assertEquals(listOf("Social", "Instagram"), FolderOps.renamed(listOf("Social", "Insta"), " Instagram "))
        assertNull(FolderOps.renamed(listOf("Social"), "a/b"))
        assertNull(FolderOps.renamed(emptyList(), "x"))
        assertEquals(listOf("Instagram"), FolderOps.moved(listOf("Social", "Instagram"), emptyList()))
        assertEquals(listOf("Social", "Instagram"), FolderOps.moved(listOf("Instagram"), listOf("Social")))
        assertNull("not into a descendant", FolderOps.moved(listOf("Social"), listOf("Social", "Instagram")))
        assertNull("not into itself", FolderOps.moved(listOf("Social"), listOf("Social")))
        assertNull("already there", FolderOps.moved(listOf("Social", "Instagram"), listOf("Social")))
        assertTrue(FolderOps.canMove(listOf("Socialite"), listOf("Social")))
    }

    @Test fun relocatesOnlyTheSubtree() {
        assertEquals("Personal/Social/Instagram", FolderOps.relocated("Social/Instagram", listOf("Social"), listOf("Personal", "Social")))
        assertEquals("Friends", FolderOps.relocated("Social", listOf("Social"), listOf("Friends")))
        assertNull(FolderOps.relocated("Socialite", listOf("Social"), listOf("Friends")))
        assertNull(FolderOps.relocated(null, listOf("Social"), listOf("Friends")))
        assertEquals("IG", FolderOps.relocated("Social / Instagram", listOf("Social", "Instagram"), listOf("IG")))
    }

    @Test fun planSkipsUnaffectedAndUnchanged() {
        val items = listOf("1" to "Social/Instagram", "2" to "Social", "3" to "Banking", "4" to null, "5" to "Social/Twitter/Old")
        assertEquals(
            listOf(
                FolderOps.Change("1", "Online/Social/Instagram"),
                FolderOps.Change("2", "Online/Social"),
                FolderOps.Change("5", "Online/Social/Twitter/Old"),
            ),
            FolderOps.plan(items, listOf("Social"), listOf("Online", "Social")),
        )
        assertTrue(FolderOps.plan(items, listOf("Social"), listOf("Social")).isEmpty())
        // A non-canonical spelling is rewritten even when the path is equal.
        assertEquals(listOf(FolderOps.Change("9", "A2/B")), FolderOps.plan(listOf("9" to "A / B"), listOf("A"), listOf("A2")))
        assertEquals(
            listOf(listOf("S", "New"), listOf("Other")),
            FolderOps.relocatePaths(listOf(listOf("Social", "New"), listOf("Other")), listOf("Social"), listOf("S")),
        )
    }
}
