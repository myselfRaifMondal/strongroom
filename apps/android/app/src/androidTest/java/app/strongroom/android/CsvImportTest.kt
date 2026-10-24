package app.strongroom.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import app.strongroom.android.core.CsvSources
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.strongroom.CsvSource
import uniffi.strongroom.ItemKind
import uniffi.strongroom.Vault
import uniffi.strongroom.generateSecretKey
import java.io.File

/**
 * The CSV importer screen guesses the exporter from the header and hands the
 * text to Vault.import_csv. These fake exports (made-up data) must import
 * with their fields intact through the Android binding.
 */
@RunWith(AndroidJUnit4::class)
class CsvImportTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var dir: File
    private lateinit var vault: Vault

    @Before
    fun setUp() {
        dir = File(context.cacheDir, "csvtest-${System.nanoTime()}").apply { mkdirs() }
        vault = Vault.create(File(dir, "v.srvault").absolutePath, "csv-test-password-1", generateSecretKey(), 1_700_000_000)
    }

    @After
    fun tearDown() {
        runCatching { vault.lock(); vault.close() }
        dir.deleteRecursively()
    }

    private fun import(csv: String): CsvSource {
        val source = CsvSources.guess(csv) ?: error("header not recognised")
        val s = vault.importCsv(source, csv, 1_700_000_100)
        assertEquals(0u, s.conflicts)
        return source
    }

    private fun item(title: String) =
        vault.getItem(vault.search(title, null, null).single { it.title == title }.id).data

    @Test
    fun chrome() {
        assertEquals(CsvSource.CHROME, import("name,url,username,password,note\nexample.com,https://example.com/login,chrome.user,Chr0me-Test-pw!,chrome note\n"))
        val d = item("example.com")
        assertEquals("chrome.user", d.username)
        assertEquals("Chr0me-Test-pw!", d.password)
        assertEquals(listOf("https://example.com/login"), d.urls)
    }

    @Test
    fun bitwarden() {
        val csv = "folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n" +
            "Work,,login,BW Login,bw note,\"pin: 1234\",0,https://bitwarden.example,bw.user,Bw-Test-pw-1,JBSWY3DPEHPK3PXP\n" +
            ",,note,BW Note,dear diary,,0,,,,\n"
        assertEquals(CsvSource.BITWARDEN, import(csv))
        val d = item("BW Login")
        assertEquals("Work", d.folder)
        assertEquals("bw.user", d.username)
        assertEquals("JBSWY3DPEHPK3PXP", d.totp)
        assertEquals("pin", d.fields.single().name)
        assertEquals(ItemKind.SECURE_NOTE, item("BW Note").kind)
    }

    @Test
    fun lastPass() {
        assertEquals(CsvSource.LAST_PASS, import("url,username,password,totp,extra,name,grouping,fav\nhttps://lastpass.example,lp.user,Lp-Test-pw-1,,lp extra,LP Login,Personal,0\n"))
        val d = item("LP Login")
        assertEquals("Personal", d.folder)
        assertEquals("lp.user", d.username)
        assertEquals("lp extra", d.notes)
    }

    @Test
    fun onePassword() {
        assertEquals(CsvSource.ONE_PASSWORD, import("Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes\nOP Login,https://op.example,op.user,Op-Test-pw-1,,false,false,finance;money,op note\n"))
        val d = item("OP Login")
        assertEquals(listOf("finance", "money"), d.tags)
        assertEquals("Op-Test-pw-1", d.password)
    }
}
