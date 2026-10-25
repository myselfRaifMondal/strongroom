package app.strongroom.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import app.strongroom.android.autofill.CapturedLogin
import app.strongroom.android.autofill.LoginSaver
import app.strongroom.android.autofill.PendingSave
import app.strongroom.android.autofill.SaveTarget
import app.strongroom.android.autofill.SaveText
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.strongroom.ItemKind
import uniffi.strongroom.Vault
import uniffi.strongroom.generateSecretKey
import java.io.File
import java.util.UUID

/**
 * The autofill save flow through the Android binding: a new login becomes a
 * vault item, and a changed password updates that item with the old one in
 * its history. Passwords are random per run (made-up data only).
 */
@RunWith(AndroidJUnit4::class)
class AutofillSaveTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var dir: File
    private lateinit var vault: Vault

    private val domain = "login.example.test"
    private val url = SaveText.urlFor(domain, "com.android.chrome")!!

    @Before
    fun setUp() {
        dir = File(context.cacheDir, "savetest-${System.nanoTime()}").apply { mkdirs() }
        vault = Vault.create(File(dir, "v.srvault").absolutePath, UUID.randomUUID().toString(), generateSecretKey(), 1_700_000_000)
    }

    @After
    fun tearDown() {
        runCatching { vault.lock(); vault.close() }
        dir.deleteRecursively()
        PendingSave.clear()
    }

    private fun randomPassword() = "pw-" + UUID.randomUUID()

    @Test
    fun newLoginIsAddedAsItem() {
        val password = randomPassword()
        assertEquals(SaveTarget.New, LoginSaver.findTarget(vault, domain, "alice@example.test", password))

        val title = SaveText.suggestedTitle(domain, null, "com.android.chrome")
        val id = LoginSaver.addNew(vault, title, "alice@example.test", password, url, 1_700_000_100)

        val match = vault.matchDomain(domain).single()
        assertEquals(id, match.id)
        val item = vault.getItem(id).data
        assertEquals(ItemKind.LOGIN, item.kind)
        assertEquals("login.example.test", item.title)
        assertEquals("alice@example.test", item.username)
        assertEquals(password, item.password)
        assertEquals(listOf("https://login.example.test"), item.urls)
        assertTrue(vault.itemHistory(id).isEmpty())

        // Saving the same login again changes nothing.
        val again = LoginSaver.findTarget(vault, domain, "Alice@Example.test", password)
        assertTrue(again is SaveTarget.Unchanged)
    }

    @Test
    fun changedPasswordUpdatesItemAndKeepsOldInHistory() {
        val oldPassword = randomPassword()
        val id = LoginSaver.addNew(vault, "Example", "bob@example.test", oldPassword, url, 1_700_000_100)
        // Another user on the same site must not be touched.
        val otherId = LoginSaver.addNew(vault, "Example (carol)", "carol@example.test", randomPassword(), url, 1_700_000_100)

        val newPassword = randomPassword()
        val target = LoginSaver.findTarget(vault, domain, "bob@example.test", newPassword)
        assertTrue("expected Update, got $target", target is SaveTarget.Update)
        val item = (target as SaveTarget.Update).item
        assertEquals(id, item.id)

        LoginSaver.update(vault, item, "Example", "bob@example.test", newPassword, url, 1_700_000_200)

        val updated = vault.getItem(id)
        assertEquals(newPassword, updated.data.password)
        assertEquals(listOf("https://login.example.test"), updated.data.urls)
        assertEquals(1, vault.matchDomain(domain).count { it.id == id })
        val history = vault.itemHistory(id)
        assertEquals(1, history.size)
        assertEquals(oldPassword, history.single().data.password)
        assertTrue(vault.itemHistory(otherId).isEmpty())
    }

    @Test
    fun pendingSaveIsTakenOnceWithTheRightToken() {
        val login = CapturedLogin("com.example.app", null, "dave@example.test", randomPassword())
        val token = PendingSave.put(login)
        assertNull(PendingSave.take("not-the-token"))
        assertSame(login, PendingSave.take(token))
        assertNull(PendingSave.take(token))
    }
}
