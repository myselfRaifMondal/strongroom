package app.strongroom.android

import app.strongroom.android.security.GateMac
import app.strongroom.android.security.GateSeal
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Threat model residual risk 3: tampered gate state is deleted, which the
 * core reads as "password required". A software HMAC key stands in for the
 * Keystore key (no Keystore on the JVM).
 */
class GateSealTest {
    private val dir: File = Files.createTempDirectory("strongroom-seal").toFile()
    private val state = File(dir, "v.state")
    private val sealFile = File(dir, "v.seal")

    private fun softwareMac(keyByte: Int) = GateMac { msg ->
        Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(ByteArray(32) { keyByte.toByte() }, "HmacSHA256"))
            doFinal(msg)
        }
    }

    private val seal = GateSeal(state, sealFile, softwareMac(7))

    @After fun cleanUp() {
        dir.deleteRecursively()
    }

    @Test fun missingStateIsIntact() {
        assertTrue(seal.stateIsIntact())
    }

    @Test fun sealedStateIsKept() {
        state.writeText("SRGATE1\n1750000000\n0\n")
        seal.reseal()
        assertTrue(seal.stateIsIntact())
        seal.dropTamperedState()
        assertTrue(state.exists())
    }

    @Test fun resetCounterIsDropped() {
        state.writeText("SRGATE1\n1750000000\n5\n")
        seal.reseal()
        state.writeText("SRGATE1\n1750000000\n0\n")
        assertFalse(seal.stateIsIntact())
        seal.dropTamperedState()
        assertFalse(state.exists())
        assertFalse(sealFile.exists())
    }

    @Test fun unsealedOrForgedStateIsDropped() {
        state.writeText("SRGATE1\n1750000000\n0\n")
        assertFalse(seal.stateIsIntact())

        // Tag made with another key.
        GateSeal(state, sealFile, softwareMac(9)).reseal()
        assertFalse(seal.stateIsIntact())

        sealFile.writeBytes(ByteArray(32))
        assertFalse(seal.stateIsIntact())
    }

    @Test fun sealIsBoundToItsFile() {
        state.writeText("SRGATE1\n1750000000\n0\n")
        seal.reseal()
        val other = File(dir, "w.state").apply { writeBytes(state.readBytes()) }
        val otherSeal = File(dir, "w.seal").apply { writeBytes(sealFile.readBytes()) }
        assertFalse(GateSeal(other, otherSeal, softwareMac(7)).stateIsIntact())
    }

    @Test fun noKeyFailsClosed() {
        val noKey = GateSeal(state, sealFile, GateMac { null })
        state.writeText("SRGATE1\n1750000000\n0\n")
        noKey.reseal()
        assertFalse(sealFile.exists())
        assertFalse(noKey.stateIsIntact())
    }
}
