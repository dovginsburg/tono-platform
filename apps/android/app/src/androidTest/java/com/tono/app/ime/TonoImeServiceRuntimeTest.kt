package com.tono.app.ime

import android.content.Intent
import android.view.inputmethod.InputMethodManager
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import com.tono.app.ImeRegressionHostActivity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Invokes the real manifest-declared InputMethodService through Android's IME
 * framework and waits for its Compose UI. Build 117 dies during that attach,
 * so "Coach" never appears and this test fails.
 */
@RunWith(AndroidJUnit4::class)
class TonoImeServiceRuntimeTest {
    @Test
    fun realImeInputViewAttachesRendersAndCommitsInput() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val device = UiDevice.getInstance(instrumentation)
        val component = "com.tono.myapp/com.tono.ime.TonoImeService"

        assertTrue(
            "Package manager must publish the real Tono IME before the test selects it",
            waitForShell(device, "ime list -a", component, 15_000),
        )
        shell(device, "ime enable $component")
        shell(device, "ime set $component")
        assertTrue(
            "Tono must become the system-selected IME",
            waitForShell(
                device,
                "settings get secure default_input_method",
                component,
                5_000,
            ),
        )

        val intent = Intent(
            instrumentation.targetContext,
            ImeRegressionHostActivity::class.java,
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        ActivityScenario.launch<ImeRegressionHostActivity>(intent).use { scenario ->
            scenario.onActivity { activity ->
                activity.editor.requestFocus()
                activity.getSystemService(InputMethodManager::class.java)
                    .showSoftInput(activity.editor, InputMethodManager.SHOW_IMPLICIT)
            }
            assertNotNull(
                "The real Tono keyboard must render; Build 117 crashes before this node exists",
                device.wait(Until.findObject(By.text("Coach")), 10_000),
            )

            val space = device.wait(Until.findObject(By.text("space")), 5_000)
            assertNotNull("Tono space key must be present", space)
            space.click()

            scenario.onActivity { activity ->
                assertEquals(
                    "Tapping a key on the real IME must commit through InputConnection",
                    " ",
                    activity.editor.text.toString(),
                )
            }
        }
    }

    private fun shell(device: UiDevice, command: String) {
        device.executeShellCommand(command)
    }

    private fun waitForShell(
        device: UiDevice,
        command: String,
        expected: String,
        timeoutMs: Long,
    ): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        do {
            if (device.executeShellCommand(command).contains(expected)) return true
            Thread.sleep(200)
        } while (System.currentTimeMillis() < deadline)
        return false
    }
}
