"use client";

import i18next from "i18next";
import { initReactI18next } from "react-i18next";
import { baseI18nOptions, DEFAULT_LOCALE } from "@tono/shared";

if (!i18next.isInitialized) {
  i18next.use(initReactI18next).init(
    baseI18nOptions({
      lng: DEFAULT_LOCALE,
      detection: undefined,
    })
  );
}

export default i18next;
