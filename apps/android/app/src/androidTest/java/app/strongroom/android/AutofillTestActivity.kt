package app.strongroom.android

import android.app.Activity
import android.os.Bundle
import android.text.InputType
import android.view.View
import android.webkit.WebView
import android.widget.EditText
import android.widget.LinearLayout

/**
 * Test-APK-only login form for exercising the Strongroom autofill service on
 * an emulator without a network or a browser:
 *
 *   adb shell am start -n app.strongroom.android.test/app.strongroom.android.AutofillTestActivity
 *       native EditTexts (query = this package name)
 *   ... --ez web true
 *       a WebView form whose web domain is login.example.com (no network:
 *       loadDataWithBaseURL), the way a browser reports a site
 */
class AutofillTestActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent.getBooleanExtra("web", false)) {
            val web = WebView(this)
            web.settings.javaScriptEnabled = false
            web.loadDataWithBaseURL(
                "https://login.example.com/signin",
                """<html><body><form>
                  <label>Email <input id="user" name="username" type="email" autocomplete="username"></label><br>
                  <label>Password <input id="pass" name="password" type="password" autocomplete="current-password"></label>
                  </form></body></html>""",
                "text/html", "utf-8", null,
            )
            setContentView(web)
            return
        }
        val user = EditText(this).apply {
            hint = "username"
            tag = "testUser"
            setAutofillHints(View.AUTOFILL_HINT_USERNAME)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS
        }
        val pass = EditText(this).apply {
            hint = "password"
            setAutofillHints(View.AUTOFILL_HINT_PASSWORD)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        }
        user.id = View.generateViewId()
        pass.id = View.generateViewId()
        setContentView(
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(48, 200, 48, 48)
                addView(user)
                addView(pass)
            },
        )
    }
}
