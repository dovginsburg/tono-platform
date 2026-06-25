package com.tono.app.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val Purple = Color(0xFF9B59B6)
private val PurpleContainer = Color(0xFF7D3C98)
private val Background = Color(0xFF000000)
private val Surface = Color(0xFF1C1C1E)

private val TonoColorScheme = darkColorScheme(
    primary          = Purple,
    onPrimary        = Color.White,
    primaryContainer = PurpleContainer,
    background       = Background,
    surface          = Surface,
    onBackground     = Color.White,
    onSurface        = Color.White,
)

@Composable
fun TonoTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = TonoColorScheme,
        content     = content,
    )
}
