package com.tono.app.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable

private val TonoDarkColors = darkColorScheme(
    primary = TonoAccent,
    onPrimary = TonoAccentContrast,
    secondary = TonoAccentSoftTextDark,
    background = TonoBackgroundDark,
    onBackground = TonoTextPrimaryDark,
    surface = TonoSurfaceDark,
    onSurface = TonoTextPrimaryDark,
    surfaceVariant = TonoSurfaceRaisedDark,
    outline = TonoBorderDark,
    error = RiskHigh,
)

private val TonoLightColors = lightColorScheme(
    primary = TonoAccentLight,
    onPrimary = TonoAccentContrast,
    secondary = TonoAccentSoftTextLight,
    background = TonoBackgroundLight,
    onBackground = TonoTextPrimaryLight,
    surface = TonoSurfaceLight,
    onSurface = TonoTextPrimaryLight,
    surfaceVariant = TonoSurfaceRaisedLight,
    outline = TonoBorderLight,
    error = RiskHigh,
)

/**
 * Wraps the app in Tono's brand ColorScheme — dark by default (matching
 * tonoit.com), light as the supported-but-secondary variant, same split as
 * apps/web/app/globals.css and apps/desktop/renderer/index.html.
 */
@Composable
fun TonoTheme(darkTheme: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (darkTheme) TonoDarkColors else TonoLightColors,
        typography = TonoTypography,
        content = content,
    )
}
