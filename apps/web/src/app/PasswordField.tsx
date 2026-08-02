'use client'

// A password input with an accessible show/hide (reveal) control.
//
// Every password field in the product must let a person verify what they typed
// without a second device or a screen reader guessing at masked dots. The
// toggle is a real <button> (keyboard-focusable, Enter/Space activatable),
// carries aria-pressed so assistive tech announces the current state, and
// aria-controls points at the input it governs. Revealing only flips the input
// type locally — the value never leaves the field, and autoComplete/minLength
// semantics are preserved so password managers still work.

import { useId, useState } from 'react'

type Props = {
  id?: string
  value: string
  onChange: (value: string) => void
  autoComplete?: string
  minLength?: number
  placeholder?: string
  required?: boolean
  name?: string
  inputClassName?: string
}

function EyeIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <path
        d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7Z"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <circle cx="12" cy="12" r="3" stroke="currentColor" strokeWidth="1.8" />
    </svg>
  )
}

function EyeOffIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <path
        d="M3 3l18 18M10.6 10.6A3 3 0 0 0 12 15a3 3 0 0 0 2.4-1.2M9.9 5.2A9.6 9.6 0 0 1 12 5c6.5 0 10 7 10 7a17.7 17.7 0 0 1-3.4 4.2M6.1 6.1A17.7 17.7 0 0 0 2 12s3.5 7 10 7a9.6 9.6 0 0 0 3-.5"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}

const DEFAULT_INPUT_CLASS =
  'w-full bg-tono-bg-elev text-tono-text border border-tono-border rounded-[12px] px-4 py-3 pr-12 text-[14px] outline-none focus:border-tono-border-strong min-h-[48px] placeholder:text-tono-muted'

export default function PasswordField({
  id,
  value,
  onChange,
  autoComplete,
  minLength,
  placeholder,
  required,
  name,
  inputClassName,
}: Props) {
  const [visible, setVisible] = useState(false)
  const reactId = useId()
  const fieldId = id ?? reactId

  return (
    <div className="relative">
      <input
        id={fieldId}
        name={name}
        type={visible ? 'text' : 'password'}
        required={required}
        minLength={minLength}
        placeholder={placeholder}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        autoComplete={autoComplete}
        className={inputClassName ?? DEFAULT_INPUT_CLASS}
      />
      <button
        type="button"
        onClick={() => setVisible((v) => !v)}
        aria-pressed={visible}
        aria-controls={fieldId}
        aria-label={visible ? 'Hide password' : 'Show password'}
        className="absolute inset-y-0 right-0 flex items-center px-3 text-tono-text-softer hover:text-tono-text focus:outline-none focus-visible:text-tono-text"
      >
        {visible ? <EyeOffIcon /> : <EyeIcon />}
      </button>
    </div>
  )
}
