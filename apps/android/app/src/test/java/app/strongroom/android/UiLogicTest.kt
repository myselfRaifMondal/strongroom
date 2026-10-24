package app.strongroom.android

import app.strongroom.android.core.AutoLock
import app.strongroom.android.core.CsvSources
import app.strongroom.android.core.MasterPasswordRules
import app.strongroom.android.ui.Nav
import app.strongroom.android.ui.Route
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.strongroom.CsvSource

class MasterPasswordRulesTest {
    @Test fun rejectsShortPasswords() {
        // Regression: "abc" used to create a vault.
        assertNotNull(MasterPasswordRules.problem("abc", "abc"))
        assertNotNull(MasterPasswordRules.problem("123456789", "123456789"))
        assertEquals("Use at least 10 characters.", MasterPasswordRules.problem("short", ""))
    }

    @Test fun rejectsMismatchAndMissingConfirmation() {
        assertEquals("Passwords do not match.", MasterPasswordRules.problem("correct horse battery", "correct horse"))
        assertEquals("Confirm the master password.", MasterPasswordRules.problem("correct horse battery", ""))
        assertNotNull(MasterPasswordRules.problem("          ", "          "))
    }

    @Test fun acceptsLongMatchingPassword() {
        assertNull(MasterPasswordRules.problem("0123456789", "0123456789"))
        assertNull(MasterPasswordRules.problem("correct horse battery", "correct horse battery"))
    }
}

class AutoLockTest {
    @Test fun sanitizesUnknownValues() {
        assertEquals(3, AutoLock.sanitize(0))
        assertEquals(3, AutoLock.sanitize(7))
        assertEquals(15, AutoLock.sanitize(15))
        assertEquals("1 hour", AutoLock.label(60))
        assertEquals("5 min", AutoLock.label(5))
    }
}

class CsvSourcesTest {
    @Test fun guessesExporterFromHeader() {
        assertEquals(CsvSource.CHROME, CsvSources.guess("name,url,username,password,note\nx,https://a.example,u,p,\n"))
        assertEquals(
            CsvSource.BITWARDEN,
            CsvSources.guess("folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n"),
        )
        assertEquals(CsvSource.LAST_PASS, CsvSources.guess("url,username,password,totp,extra,name,grouping,fav\n"))
        assertEquals(CsvSource.ONE_PASSWORD, CsvSources.guess("﻿Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes\n"))
        assertEquals(CsvSource.ONE_PASSWORD, CsvSources.guess("Title,URL,Username,Password,Notes,OTPAuth\n")) // Apple Passwords
        assertNull(CsvSources.guess("foo,bar\n1,2\n"))
        assertNull(CsvSources.guess(""))
    }

    @Test fun everySourceHasALabel() {
        CsvSource.entries.forEach { assertTrue(CsvSources.label(it).isNotBlank()) }
    }
}

class NavTest {
    @Test fun coveredEntryKeepsItsState() {
        // Regression: opening the generator from the editor wiped the draft.
        val nav = Nav()
        nav.push(Route.Items)
        nav.push(Route.Edit(null))
        val editor = nav.topEntry
        editor.state["draft"] = "half-typed item"
        nav.push(Route.Generator(forEditor = true))
        assertEquals(Route.Generator(true), nav.top)
        nav.generatedForEditor = "Gen3rated!"
        nav.pop()
        assertSame(editor, nav.topEntry)
        assertEquals("half-typed item", nav.topEntry.state["draft"])
        assertEquals("Gen3rated!", nav.generatedForEditor)
    }

    @Test fun resetDropsAllStateIncludingGeneratedPassword() {
        val nav = Nav()
        nav.push(Route.Edit(null))
        nav.topEntry.state["draft"] = "secret"
        nav.generatedForEditor = "secret"
        nav.reset(Route.Vaults, Route.Unlock("v"))
        assertEquals(2, nav.stack.size)
        assertTrue(nav.stack.all { it.state.isEmpty() })
        assertNull(nav.generatedForEditor)
    }

    @Test fun popNeverEmptiesTheStack() {
        val nav = Nav()
        nav.pop()
        assertEquals(Route.Vaults, nav.top)
    }
}
