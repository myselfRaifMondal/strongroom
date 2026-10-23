package app.strongroom.android

import android.text.InputType
import app.strongroom.android.autofill.DomainQuery
import app.strongroom.android.autofill.FieldClassifier
import app.strongroom.android.autofill.FieldType
import app.strongroom.android.core.VaultFiles
import app.strongroom.android.security.BootIdentity
import app.strongroom.android.security.Sec1
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.math.BigInteger

class Sec1Test {
    // P-256 generator point.
    private val gx = BigInteger("6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296", 16)
    private val gy = BigInteger("4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5", 16)

    @Test fun roundTrip() {
        val enc = Sec1.encode(gx, gy)
        assertEquals(65, enc.size)
        assertEquals(0x04.toByte(), enc[0])
        val (x, y) = Sec1.decode(enc)
        assertEquals(gx, x)
        assertEquals(gy, y)
    }

    @Test fun padsShortCoordinates() {
        val enc = Sec1.encode(BigInteger.ONE, BigInteger.TWO)
        val expected = ByteArray(65).also { it[0] = 4; it[32] = 1; it[64] = 2 }
        assertArrayEquals(expected, enc)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsCompressed() {
        Sec1.decode(ByteArray(33).also { it[0] = 2 })
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsWrongPrefix() {
        Sec1.decode(ByteArray(65).also { it[0] = 5 })
    }
}

class BootIdentityTest {
    @Test fun usesBootCountWhenAvailable() {
        assertEquals("count:7", BootIdentity.of(7, 1_000_000, 5_000))
    }

    @Test fun fallsBackToBootTimeInMinutes() {
        val a = BootIdentity.of(-1, 10 * 60_000L + 1_000, 1_000)
        val b = BootIdentity.of(-1, 10 * 60_000L + 30_000, 30_000) // same boot, later
        assertEquals(a, b)
    }

    @Test fun rebootDetection() {
        assertTrue(BootIdentity.rebooted(null, "count:3"))
        assertTrue(BootIdentity.rebooted("count:2", "count:3"))
        assertFalse(BootIdentity.rebooted("count:3", "count:3"))
    }
}

class FieldClassifierTest {
    private val textPassword = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
    private val textEmail = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS
    private val plainText = InputType.TYPE_CLASS_TEXT

    @Test fun hintsWin() {
        assertEquals(FieldType.PASSWORD, FieldClassifier.classify(listOf("password"), plainText, null, null, null, null))
        assertEquals(FieldType.USERNAME, FieldClassifier.classify(listOf("username"), plainText, null, null, null, null))
        assertEquals(FieldType.USERNAME, FieldClassifier.classify(listOf("emailAddress"), plainText, null, null, null, null))
    }

    @Test fun inputTypes() {
        assertEquals(FieldType.PASSWORD, FieldClassifier.classify(emptyList(), textPassword, null, null, null, null))
        assertEquals(FieldType.USERNAME, FieldClassifier.classify(emptyList(), textEmail, null, null, null, null))
        assertTrue(FieldClassifier.isPasswordInputType(InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD))
        assertFalse(FieldClassifier.isPasswordInputType(plainText))
    }

    @Test fun htmlAndIds() {
        assertEquals(FieldType.PASSWORD, FieldClassifier.classify(emptyList(), 0, null, null, "password", "pw"))
        assertEquals(FieldType.USERNAME, FieldClassifier.classify(emptyList(), 0, null, null, "text", "login"))
        assertEquals(FieldType.USERNAME, FieldClassifier.classify(emptyList(), plainText, "et_username", null, null, null))
        assertEquals(FieldType.PASSWORD, FieldClassifier.classify(emptyList(), plainText, null, "Your passcode", null, null))
        assertEquals(FieldType.OTHER, FieldClassifier.classify(emptyList(), plainText, "search_box", "Search", null, null))
    }
}

class DomainQueryTest {
    @Test fun prefersWebDomain() {
        assertEquals("example.com", DomainQuery.of(" Example.com ", "com.android.chrome"))
        assertEquals("com.example.app", DomainQuery.of(null, "com.example.app"))
        assertEquals("com.example.app", DomainQuery.of("", "com.example.app"))
        assertNull(DomainQuery.of(null, null))
    }
}

class VaultNameTest {
    @Test fun names() {
        assertTrue(VaultFiles.validName("Personal"))
        assertTrue(VaultFiles.validName("work-2_b"))
        assertFalse(VaultFiles.validName("../evil"))
        assertFalse(VaultFiles.validName(""))
        assertFalse(VaultFiles.validName("a".repeat(41)))
    }
}
