import Link from 'next/link'

type TonoBrandProps = {
  lockup?: boolean
  compact?: boolean
  className?: string
}

/**
 * Production use of Mark's recommended cursor-t direction.
 * The small asset intentionally drops the cursor at 32px for legibility.
 */
export default function TonoBrand({ lockup = false, compact = false, className = '' }: TonoBrandProps) {
  const size = compact ? 32 : 40

  return (
    <Link
      href="/"
      aria-label="tono — just tone it! — home"
      className={`inline-flex items-center gap-3 shrink-0 ${className}`}
    >
      <span aria-hidden="true">
        <img
          src={compact ? '/app/brand/tono-t-32.png' : '/app/brand/tono-cursor-t-64.png'}
          alt=""
          width={size}
          height={size}
          className="rounded-[9px]"
        />
      </span>
      <span className="flex flex-col leading-none">
        <span className="text-[22px] font-extrabold tracking-[-0.04em] text-tono-text">tono</span>
        {lockup ? (
          <span className="mt-1 text-[10px] font-semibold tracking-[0.02em] text-tono-accent-light">
            — just tone it!
          </span>
        ) : null}
      </span>
    </Link>
  )
}
