// Centralized customer-facing contact identity for tono.
//
// Every public web surface (about, contact, privacy, terms, pricing, the
// footer, the landing feedback CTA) links to one of the official inbound
// aliases below — never an internal operator mailbox. Routing all contact
// copy through this one module is deliberate: it is the single place a new
// alias is added, and the brand-contact-identity regression asserts that no
// surface reintroduces a personal/operator address by hand.
//
// Aliases are Cloudflare Email Routing addresses on tonoit.com that forward
// to Tono's verified destination. Pick the semantically correct channel per
// surface:
//
//   hello    — general, company, press, partnerships
//   support  — account help, product feedback, waitlist, customer support
//   privacy  — privacy questions and data-deletion requests
//   security — responsible disclosure
export const TONO_CONTACT = {
  hello: 'hello@tonoit.com',
  support: 'support@tonoit.com',
  privacy: 'privacy@tonoit.com',
  security: 'security@tonoit.com',
} as const

export type TonoContactChannel = keyof typeof TONO_CONTACT

/** The `mailto:` href for an official Tono contact channel. */
export function tonoMailto(channel: TonoContactChannel): string {
  return `mailto:${TONO_CONTACT[channel]}`
}
