package com.tono.app.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

// Mirrors the type scale in /DESIGN.md. System font (no FontFamily override)
// so Android renders its native Roboto, same "OS-native feel" reasoning as
// the system font stack on web/desktop.
val TonoTypography = Typography(
    headlineMedium = TextStyle( // "display" — app name / page title
        fontSize = 28.sp,
        fontWeight = FontWeight.ExtraBold,
        lineHeight = 32.sp,
    ),
    titleMedium = TextStyle( // "heading" — section headers
        fontSize = 18.sp,
        fontWeight = FontWeight.SemiBold,
        lineHeight = 23.sp,
    ),
    bodyLarge = TextStyle( // "body" — draft text, results
        fontSize = 16.sp,
        fontWeight = FontWeight.Normal,
        lineHeight = 24.sp,
    ),
    bodyMedium = TextStyle( // "body-sm" — tagline, rationale, subtext
        fontSize = 14.sp,
        fontWeight = FontWeight.Normal,
        lineHeight = 20.sp,
    ),
    bodySmall = TextStyle( // "body-sm" variant used for secondary result text
        fontSize = 14.sp,
        fontWeight = FontWeight.Normal,
        lineHeight = 20.sp,
    ),
    labelMedium = TextStyle( // "caption" — risk/axis badge labels
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        lineHeight = 16.sp,
        letterSpacing = 0.3.sp,
    ),
)
