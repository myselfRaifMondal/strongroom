package app.strongroom.android

import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.fragment.app.FragmentActivity
import app.strongroom.android.ui.StrongroomUi

/** FragmentActivity (not ComponentActivity) because BiometricPrompt needs one. */
class MainActivity : FragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { StrongroomUi() }
    }
}
