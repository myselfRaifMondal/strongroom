package app.strongroom.android.ui

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.FilterChip
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import app.strongroom.android.StrongroomApp
import kotlinx.coroutines.launch
import uniffi.strongroom.PassphrasePolicy
import uniffi.strongroom.PasswordPolicy
import uniffi.strongroom.StrengthReport
import uniffi.strongroom.estimateStrength
import uniffi.strongroom.generatePassphrase
import uniffi.strongroom.generatePassword

@Composable
fun GeneratorScreen(nav: Nav) {
    val app = LocalContext.current.applicationContext as StrongroomApp
    val scope = rememberCoroutineScope()
    val op = rememberOpState()
    var passphrase by remember { mutableStateOf(false) }
    var length by remember { mutableFloatStateOf(20f) }
    var lower by remember { mutableStateOf(true) }
    var upper by remember { mutableStateOf(true) }
    var digits by remember { mutableStateOf(true) }
    var symbols by remember { mutableStateOf(true) }
    var avoidAmbiguous by remember { mutableStateOf(true) }
    var words by remember { mutableFloatStateOf(5f) }
    var separator by remember { mutableStateOf("-") }
    var capitalize by remember { mutableStateOf(true) }
    var includeNumber by remember { mutableStateOf(true) }
    var result by remember { mutableStateOf("") }
    var strength by remember { mutableStateOf<StrengthReport?>(null) }

    @Composable
    fun Toggle(label: String, value: Boolean, tag: String, onChange: (Boolean) -> Unit) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(value, onChange, modifier = Modifier.testTag(tag))
            Text(label)
        }
    }

    ScreenScaffold(title = "Generator", onBack = { nav.pop() }) {
        Row {
            FilterChip(selected = !passphrase, onClick = { passphrase = false }, label = { Text("Password") })
            FilterChip(selected = passphrase, onClick = { passphrase = true }, label = { Text("Passphrase") },
                modifier = Modifier.testTag("modePassphrase"))
        }
        if (!passphrase) {
            Text("Length: ${length.toInt()}")
            Slider(length, { length = it }, valueRange = 8f..64f, steps = 55)
            Toggle("Lowercase", lower, "genLower") { lower = it }
            Toggle("Uppercase", upper, "genUpper") { upper = it }
            Toggle("Digits", digits, "genDigits") { digits = it }
            Toggle("Symbols", symbols, "genSymbols") { symbols = it }
            Toggle("Avoid look-alike characters", avoidAmbiguous, "genAmbiguous") { avoidAmbiguous = it }
        } else {
            Text("Words: ${words.toInt()}")
            Slider(words, { words = it }, valueRange = 3f..12f, steps = 8)
            PlainField(separator, { separator = it.take(3) }, "Separator", "genSeparator")
            Toggle("Capitalize", capitalize, "genCapitalize") { capitalize = it }
            Toggle("Include a number", includeNumber, "genNumber") { includeNumber = it }
        }
        Button(
            modifier = Modifier.testTag("generate"),
            onClick = {
                scope.launch {
                    op.run {
                        result = core {
                            if (passphrase) generatePassphrase(
                                PassphrasePolicy(words.toInt().toUByte(), separator, capitalize, includeNumber),
                            ) else generatePassword(
                                PasswordPolicy(length.toInt().toUByte(), lower, upper, digits, symbols, avoidAmbiguous),
                            )
                        }
                        strength = core { estimateStrength(result) }
                    }
                }
            },
        ) { Text("Generate") }
        OpStatus(op)
        if (result.isNotEmpty()) {
            Card(Modifier.fillMaxWidth()) {
                Text(result, fontFamily = FontFamily.Monospace, modifier = Modifier.padding16().testTag("generated"))
            }
            strength?.let { Text("Strength ${it.score}/4, ~${it.entropyBits.toInt()} bits") }
            OutlinedButton(onClick = { app.clipboard.copy("generated password", result) }) { Text("Copy (clears in 25 s)") }
        }
    }
}
