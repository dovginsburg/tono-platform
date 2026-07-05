"use client";

import { useTranslation } from "react-i18next";
import { RTL_LOCALES, SUPPORTED_LOCALES } from "@tono/shared";

export function LanguageSwitcher() {
  const { i18n } = useTranslation();

  function onChange(code: string) {
    i18n.changeLanguage(code);
    if (typeof document !== "undefined") {
      document.documentElement.dir = RTL_LOCALES.has(code) ? "rtl" : "ltr";
      document.documentElement.lang = code;
    }
  }

  return (
    <select
      aria-label="Language"
      value={i18n.language}
      onChange={(e) => onChange(e.target.value)}
    >
      {SUPPORTED_LOCALES.map((loc) => (
        <option key={loc.code} value={loc.code}>
          {loc.name}
        </option>
      ))}
    </select>
  );
}
