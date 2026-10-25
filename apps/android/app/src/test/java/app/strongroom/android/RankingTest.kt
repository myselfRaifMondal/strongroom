package app.strongroom.android

import app.strongroom.android.core.DomainName
import app.strongroom.android.core.DueReason
import app.strongroom.android.core.Importance
import app.strongroom.android.core.ReuseClusters
import app.strongroom.android.core.RiskInputs
import app.strongroom.android.core.RiskPriority
import app.strongroom.android.core.RiskScore
import app.strongroom.android.core.RotationInterval
import app.strongroom.android.core.RotationPolicy
import app.strongroom.android.core.RotationReminder
import app.strongroom.android.core.RotationSettings
import app.strongroom.android.core.SecurityRanking
import app.strongroom.android.core.ServiceCatalog
import app.strongroom.android.core.ServiceCategory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.strongroom.ItemKind

/** Same cases as apps/macos/Tests/StrongroomKitTests/RankingTests.swift. */
class RiskScoreTest {
    private fun x(s: Int, reused: Int = 0, age: Int = 0, totp: Boolean = false, i: Importance = Importance.NORMAL) =
        RiskInputs(s, reused, age, totp, i)

    @Test fun components() {
        assertEquals(listOf(40, 30, 18, 8, 0), (0..4).map { RiskScore.strengthPoints(it) })
        assertEquals(listOf(0, 25, 30, 30, 35, 35), listOf(0, 1, 2, 3, 4, 9).map { RiskScore.reusePoints(it) })
        assertEquals(
            listOf(0, 0, 5, 5, 10, 10, 15, 15),
            listOf(0, 179, 180, 364, 365, 729, 730, 5000).map { RiskScore.agePoints(it) },
        )
        assertEquals(0, RiskScore.totpPoints(true))
        assertEquals(5, RiskScore.totpPoints(false))
    }

    @Test fun fixedInputs() {
        assertEquals(0, RiskScore.score(x(4, totp = true, i = Importance.CRITICAL)))
        assertEquals(5, RiskScore.score(x(4)))
        assertEquals(8, RiskScore.score(x(4, i = Importance.CRITICAL))) // 5 x 1.5 = 7.5 -> 8
        assertEquals(45, RiskScore.score(x(4, reused = 1, i = Importance.CRITICAL)))
        assertEquals(RiskPriority.HIGH, RiskScore.priority(45))
        assertEquals(30, RiskScore.score(x(4, reused = 1)))
        assertEquals(18, RiskScore.score(x(4, reused = 1, i = Importance.LOW)))
        assertEquals(100, RiskScore.score(x(1, reused = 3, age = 400, i = Importance.CRITICAL))) // 112.5 -> 100
        assertEquals(45, RiskScore.score(x(0)))
        assertEquals(33, RiskScore.score(x(2, age = 800, totp = true)))
        assertEquals(95, RiskScore.score(x(0, reused = 9, age = 9999)))
    }

    @Test fun priorityBands() {
        assertEquals(RiskPriority.LOW, RiskScore.priority(0))
        assertEquals(RiskPriority.LOW, RiskScore.priority(19))
        assertEquals(RiskPriority.MEDIUM, RiskScore.priority(20))
        assertEquals(RiskPriority.MEDIUM, RiskScore.priority(44))
        assertEquals(RiskPriority.HIGH, RiskScore.priority(69))
        assertEquals(RiskPriority.CRITICAL, RiskScore.priority(70))
        assertEquals(RiskPriority.CRITICAL, RiskScore.priority(100))
    }
}

class ImportanceTest {
    private fun infer(tags: List<String> = emptyList(), folder: String? = null, urls: List<String> = emptyList(), kind: ItemKind = ItemKind.LOGIN) =
        Importance.infer(kind, tags, folder, urls)

    @Test fun tagsOverrideEverything() {
        assertEquals(Importance.CRITICAL, infer(tags = listOf("priority:critical"), folder = "Gaming"))
        assertEquals(Importance.LOW, infer(tags = listOf("Priority:Low"), folder = "Finance", urls = listOf("https://chase.com")))
    }

    @Test fun folderTemplateKindUrl() {
        assertEquals(Importance.CRITICAL, infer(folder = "Finance/Zerodha"))
        assertEquals(Importance.CRITICAL, infer(folder = "Banking"))
        assertEquals(Importance.CRITICAL, infer(folder = "Email & Identity"))
        // The user's folder wins over the URL.
        assertEquals(Importance.NORMAL, infer(folder = "Social", urls = listOf("https://github.com")))
        assertEquals(Importance.CRITICAL, infer(tags = listOf("template:bank")))
        assertEquals(Importance.CRITICAL, infer(kind = ItemKind.API_KEY))
        assertEquals(Importance.CRITICAL, infer(urls = listOf("https://accounts.google.com")))
        assertEquals(Importance.CRITICAL, infer(urls = listOf("https://classroom.google.com/u/0")))
        assertEquals(Importance.CRITICAL, infer(urls = listOf("https://signin.aws.amazon.com")))
        assertEquals(Importance.NORMAL, infer(urls = listOf("https://instagram.com")))
        assertEquals(Importance.NORMAL, infer())
    }
}

class ServiceCatalogTest {
    @Test fun hostsAndRegistrableDomains() {
        assertEquals("mail.example.com", DomainName.host("https://user@Mail.Example.com:8443/"))
        assertEquals("instagram.com", DomainName.host("instagram.com/x"))
        assertEquals("example.test", DomainName.host("https://example.test./login?x=1#y"))
        assertNull(DomainName.host("ftp://example.test"))
        assertNull(DomainName.host("  "))
        assertNull(DomainName.host("not a url"))
        assertEquals("hostinger.com", DomainName.registrable("mail.hostinger.com"))
        assertEquals("bbc.co.uk", DomainName.registrable("www.bbc.co.uk"))
        assertEquals("10.0.0.1", DomainName.registrable("10.0.0.1"))
        assertEquals("examplebank.bank.in", DomainName.registrableOfUrl("https://netbanking.examplebank.bank.in"))
    }

    @Test fun classifies() {
        assertEquals("Instagram", ServiceCatalog.classify("https://www.instagram.com/")?.service)
        assertEquals("Google", ServiceCatalog.classify("https://classroom.google.com/u/0")?.service)
        assertEquals("Lloyds Bank", ServiceCatalog.classify("https://online.lloydsbank.co.uk/personal/logon")?.service)
        assertEquals("State Bank of India", ServiceCatalog.classify("https://retail.sbi.bank.in")?.service)
        assertEquals("Skyscanner", ServiceCatalog.classify("https://www.skyscanner.co.in")?.service)
        assertEquals(ServiceCategory.DEVELOPER_CLOUD, ServiceCatalog.classify("https://appstoreconnect.apple.com")?.category)
        assertEquals("acme", ServiceCatalog.classify("https://acme.zendesk.com/agent")?.tenant)
        val unknown = ServiceCatalog.classify("https://shop.example.test/login")
        assertEquals(false, unknown?.known)
        assertEquals(ServiceCategory.OTHER, unknown?.category)
        assertEquals("example.test", unknown?.service)
        assertNull(ServiceCatalog.classify(""))
    }

    @Test fun categoryFromFolder() {
        assertEquals(ServiceCategory.FINANCE, ServiceCategory.fromFolder("banking / HDFC"))
        assertEquals(ServiceCategory.SOCIAL, ServiceCategory.fromFolder("Social"))
        assertNull(ServiceCategory.fromFolder("Personal"))
        assertNull(ServiceCategory.fromFolder(null))
    }
}

class ReuseAndRankingTest {
    @Test fun groupsOnlySharedPasswords() {
        val pairs = listOf("a" to "same", "b" to "unique", "c" to "same", "d" to "", "e" to "", "f" to "x", "g" to "x", "h" to "same")
        assertEquals(listOf(listOf("a", "c", "h"), listOf("f", "g")), ReuseClusters.compute(pairs))
        assertEquals(emptyList<List<String>>(), ReuseClusters.compute(emptyList()))
    }

    @Test fun rankingAndClusterOrder() {
        val now = 1_800_000_000L
        val day = 86_400L
        fun e(id: String, s: Int, at: Long, totp: Boolean, i: Importance) = SecurityRanking.Entry(id, s, at, totp, i)
        val entries = listOf(
            e("game1", 4, now, true, Importance.NORMAL),
            e("game2", 4, now, true, Importance.NORMAL),
            e("game3", 4, now, true, Importance.NORMAL),
            e("bank", 4, now - 10 * day, false, Importance.CRITICAL),
            e("mail", 4, now, true, Importance.CRITICAL),
            e("fine", 4, now, true, Importance.NORMAL),
            e("weak", 1, now, true, Importance.NORMAL),
        )
        val r = SecurityRanking.build(entries, listOf(listOf("game1", "game2", "game3"), listOf("bank", "mail")), RotationSettings(), now)
        assertEquals("bank", r.items.first().id) // worst first
        assertEquals("fine", r.items.last().id)
        assertEquals(2, r.item("game1")?.inputs?.reusedWith)
        assertEquals(45, r.item("bank")?.risk)
        assertEquals(RiskPriority.HIGH, r.item("bank")?.priority)
        // The bank/mail cluster is smaller but holds critical accounts: first.
        assertEquals(listOf(2, 3), r.clusters.map { it.itemIds.size })
        assertEquals(Importance.CRITICAL, r.clusters.first().maxImportance)
        assertEquals(5, r.sharedCount)
        assertEquals(6, r.dueCount) // five reused + one weak
        assertEquals(false, r.item("fine")?.due)
        assertEquals(1, r.count(RiskPriority.HIGH))
    }

    @Test fun scoreUpdatesWhenThePasswordChanges() {
        val now = 1_800_000_000L
        val before = SecurityRanking.build(
            listOf(
                SecurityRanking.Entry("a", 1, now - 400 * 86_400, false, Importance.CRITICAL),
                SecurityRanking.Entry("b", 1, now, false, Importance.NORMAL),
            ),
            listOf(listOf("a", "b")), RotationSettings(), now,
        )
        val after = SecurityRanking.build(
            listOf(
                SecurityRanking.Entry("a", 4, now, false, Importance.CRITICAL),
                SecurityRanking.Entry("b", 1, now, false, Importance.NORMAL),
            ),
            emptyList(), RotationSettings(), now,
        )
        assertTrue(before.item("a")!!.risk > after.item("a")!!.risk)
        assertFalse(after.item("a")!!.due)
        assertEquals(0, after.sharedCount)
    }

    @Test fun passwordAgeComesFromHistory() {
        // Created day 0 with P1, changed to P2 on day 100, moved on day 300:
        // the password is 200 days old on day 300, not 0.
        val d = 86_400L
        val revs = listOf(0L to "P1", 100 * d to "P2")
        assertEquals(100 * d, SecurityRanking.passwordChangedAt("P2", 300 * d, 0, revs))
        assertEquals(0L, SecurityRanking.passwordChangedAt("P1", 300 * d, 0, listOf(0L to "P1")))
        assertEquals(300 * d, SecurityRanking.passwordChangedAt("P3", 300 * d, 0, revs))
        assertEquals(0L, SecurityRanking.passwordChangedAt("P1", 50 * d, 0, emptyList()))
    }
}

class RotationTest {
    private fun x(s: Int, reused: Int = 0, age: Int, i: Importance) = RiskInputs(s, reused, age, true, i)

    @Test fun dueRules() {
        val p = RotationSettings()
        assertEquals(RotationInterval.DAYS_90, p.critical)
        assertEquals(RotationInterval.DAYS_365, p.other)
        assertFalse(RotationPolicy.isDue(x(4, age = 89, i = Importance.CRITICAL), p))
        assertEquals(listOf(DueReason.OLD), RotationPolicy.dueReasons(x(4, age = 90, i = Importance.CRITICAL), p))
        assertFalse(RotationPolicy.isDue(x(4, age = 364, i = Importance.NORMAL), p))
        assertTrue(RotationPolicy.isDue(x(4, age = 365, i = Importance.LOW), p))
        assertEquals(listOf(DueReason.REUSED, DueReason.WEAK), RotationPolicy.dueReasons(x(1, reused = 2, age = 0, i = Importance.NORMAL), p))
        assertFalse("score 2 is not weak", RotationPolicy.isDue(x(2, age = 0, i = Importance.NORMAL), p))
        val never = p.copy(critical = RotationInterval.NEVER, other = RotationInterval.NEVER)
        assertFalse(RotationPolicy.isDue(x(4, age = 10_000, i = Importance.CRITICAL), never))
        assertTrue(RotationPolicy.isDue(x(0, age = 0, i = Importance.CRITICAL), never))
    }

    @Test fun settingsRoundTrip() {
        assertEquals(RotationSettings(), RotationSettings.fromMap(emptyMap<String, Any?>()))
        val s = RotationSettings(RotationInterval.DAYS_30, RotationInterval.NEVER, 1_900_000_000L)
        assertEquals(s, RotationSettings.fromMap(s.toMap()))
        assertTrue(s.isSnoozed(1_899_999_999))
        assertFalse(s.isSnoozed(1_900_000_000))
        // Unknown stored values fall back to the defaults.
        assertEquals(RotationSettings(), RotationSettings.fromMap(mapOf(RotationSettings.KEY_CRITICAL to 7L, RotationSettings.KEY_OTHER to "x")))
    }

    @Test fun bannerHasOnlyACount() {
        for (n in listOf(0, 1, 2, 12, 220)) {
            val text = RotationReminder.bannerText(n)
            assertEquals(n.toString(), text.filter { it.isDigit() })
            assertFalse(text.contains("@") || text.contains("/") || text.contains(".com"))
        }
        assertEquals("1 password should be changed", RotationReminder.bannerText(1))
        assertEquals("12 passwords should be changed", RotationReminder.bannerText(12))
    }
}
