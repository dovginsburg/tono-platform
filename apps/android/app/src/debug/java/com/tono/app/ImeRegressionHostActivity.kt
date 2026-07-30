package com.tono.app

import android.app.Activity
import android.os.Bundle
import android.view.inputmethod.InputMethodManager
import android.widget.EditText

/** Debug-only host used to invoke the installed IME in connected tests. */
class ImeRegressionHostActivity : Activity() {
    lateinit var editor: EditText
        private set

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        editor = EditText(this).apply {
            hint = "IME regression editor"
            setSingleLine()
        }
        setContentView(editor)
        editor.requestFocus()
        editor.post {
            getSystemService(InputMethodManager::class.java).showSoftInput(
                editor,
                InputMethodManager.SHOW_IMPLICIT,
            )
        }
    }
}
