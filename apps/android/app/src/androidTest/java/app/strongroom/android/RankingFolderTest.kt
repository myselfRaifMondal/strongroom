package app.strongroom.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import app.strongroom.android.core.DueReason
import app.strongroom.android.core.FolderTree
import app.strongroom.android.core.Importance
import app.strongroom.android.core.RotationSettings
import app.strongroom.android.core.VaultAnalysis
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.strongroom.ItemInput
import uniffi.strongroom.ItemKind
import uniffi.strongroom.Vault
import uniffi.strongroom.generateSecretKey
import java.io.File

/**
 * Security Ranking and folder rename/move through the real core (made-up
 * data). Checks that reuse, strength and importance reach the ranking, and
 * that moving a folder rewrites only its subtree without resetting the
 * password age.
 */
@RunWith(AndroidJUnit4::class)
class RankingFolderTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var dir: File
    private lateinit var vault: Vault
    private val t0 = 1_700_000_000L
    private val day = 86_400L

    @Before
    fun setUp() {
        dir = File(context.cacheDir, "ranktest-${System.nanoTime()}").apply { mkdirs() }
        vault = Vault.create(File(dir, "v.srvault").absolutePath, "rank-test-password-1", generateSecretKey(), t0)
    }

    @After
    fun tearDown() {
        runCatching { vault.lock(); vault.close() }
        VaultAnalysis.clear()
        dir.deleteRecursively()
    }

    private fun add(title: String, folder: String?, password: String?, url: String? = null, totp: String? = null, kind: ItemKind = ItemKind.LOGIN) =
        vault.addItem(
            ItemInput(kind, title, "user@example.test", password, listOfNotNull(url), null, totp, folder, emptyList(), emptyList(), false),
            t0,
        )

    @Test
    fun rankingAndFolderMove() {
        val mail = add("Example Mail", "Email & Identity", "Shared-Pass-1", "https://mail.example.test")
        val game = add("Example Game", "Gaming", "Shared-Pass-1")
        val weak = add("Weak One", "Social / Friends", "abc")
        val strong = add("Strong One", "Social/Friends/Close", "q8#Vt2!pLm9@Zx4&Rw7^kD3", totp = "JBSWY3DPEHPK3PXP")
        add("A note", "Social", null, kind = ItemKind.SECURE_NOTE)

        val r = VaultAnalysis.ranking(vault, RotationSettings(), t0)
        assertEquals("items with a password only", 4, r.items.size)
        assertEquals(listOf(setOf(mail, game)), r.clusters.map { it.itemIds.toSet() })
        assertEquals(Importance.CRITICAL, r.item(mail)?.inputs?.importance)
        assertEquals(Importance.CRITICAL, r.clusters.single().maxImportance)
        assertTrue(r.item(weak)!!.dueReasons.contains(DueReason.WEAK))
        assertFalse(r.item(strong)!!.due)
        assertEquals(mail, r.items.first().id)

        // Move "Social" under "Personal" 400 days later.
        val later = t0 + 400 * day
        assertEquals(3, VaultAnalysis.relocateFolder(vault, listOf("Social"), listOf("Personal", "Social"), later))
        assertEquals("Personal/Social/Friends", vault.getItem(weak).data.folder)
        assertEquals("Personal/Social/Friends/Close", vault.getItem(strong).data.folder)
        assertEquals("Gaming", vault.getItem(game).data.folder)
        assertEquals("Social / Friends", vault.itemHistory(weak).maxByOrNull { it.modifiedAt }?.data?.folder)
        val tree = FolderTree.build(vault.search("", null, null).map { it.folder })
        assertEquals(3, FolderTree.find(listOf("Personal", "Social"), tree)?.totalCount)

        // The move changed modified_at, not the password: the age is 400 days.
        val after = VaultAnalysis.ranking(vault, RotationSettings(), later)
        assertEquals(400, after.item(weak)?.inputs?.ageDays)
        assertTrue(after.item(mail)!!.dueReasons.contains(DueReason.OLD)) // critical: 90-day policy
    }
}
