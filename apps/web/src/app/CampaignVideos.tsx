import type { ReactNode } from 'react'

type Episode = {
  number: '01' | '02' | '03'
  title: string
  description: string
  transcript: ReactNode
  featured?: boolean
}

const episodes: Episode[] = [
  {
    number: '01',
    title: '“per my last email” was not helping.',
    description: 'A synthetic work-message demonstration: same ask, less heat.',
    featured: true,
    transcript: (
      <>
        Draft: “Per my last email, this is the third time I’m asking.” Likely landing:
        frustrated or accusatory. Clearer rewrite: “Could you confirm whether Friday still works?
        If not, what timing should I plan around?” The user chooses what to copy and send.
      </>
    ),
  },
  {
    number: '02',
    title: 'the group chat draft.',
    description: 'A synthetic group-chat demonstration: still honest, easier to answer.',
    transcript: (
      <>
        Draft: “Wow. Thanks for letting me know.” Likely landing: passive-aggressive. Warmer
        rewrite: “I was looking forward to tonight. Thanks for telling me — can we pick another
        day?” The user chooses what to copy and send.
      </>
    ),
  },
  {
    number: '03',
    title: 'the 11:47pm text.',
    description: 'A synthetic late-night demonstration: keep the truth, lose the trap.',
    transcript: (
      <>
        Draft: “Do you even care? You haven’t answered all night.” Likely landing: accusatory.
        Safer rewrite: “I’m feeling shut out, and I don’t want to guess. Can we talk tomorrow when
        we’re both ready?” The user chooses what to copy and send.
      </>
    ),
  },
]

function EpisodeCard({ episode }: { episode: Episode }) {
  const transcriptId = `episode-${episode.number}-transcript`
  const mediaRoot = '/app/media/texts-i-almost-sent'

  return (
    <article
      className={`rounded-[22px] border border-tono-border bg-tono-bg-card overflow-hidden min-w-0 ${
        episode.featured ? 'md:row-span-2' : ''
      }`}
    >
      <div className="p-5 sm:p-7">
        <p className="text-[11px] uppercase tracking-[0.16em] font-bold text-tono-text-softer">
          episode {episode.number} · 20s product demonstration
        </p>
        <h3 className={`mt-3 font-bold tracking-[-0.035em] text-tono-text leading-[1.02] ${episode.featured ? 'text-[30px] sm:text-[36px]' : 'text-[24px]'}`}>
          {episode.title}
        </h3>
        <p className="mt-3 text-[13px] leading-relaxed text-tono-text-soft">{episode.description}</p>
      </div>
      <div className={`mx-auto w-full ${episode.featured ? 'max-w-[420px]' : 'max-w-[260px]'} px-4 pb-4`}>
        <video
          controls
          playsInline
          preload={episode.featured ? 'metadata' : 'none'}
          poster={`${mediaRoot}/episode-${episode.number}-poster.png`}
          width={1080}
          height={1920}
          aria-label={`${episode.title} — silent product demonstration with burned-in captions`}
          aria-describedby={transcriptId}
          className="block w-full h-auto aspect-[9/16] rounded-[16px] bg-black object-cover border border-tono-border"
        >
          <source src={`${mediaRoot}/episode-${episode.number}.mp4`} type="video/mp4" />
          <track
            default
            kind="captions"
            srcLang="en"
            label="English"
            src={`${mediaRoot}/episode-${episode.number}.vtt`}
          />
          Your browser cannot play this video. Read the full demonstration below.
        </video>
      </div>
      <details id={transcriptId} className="mx-5 sm:mx-7 mb-6 border-t border-tono-border pt-4 text-[13px] text-tono-text-soft">
        <summary className="cursor-pointer min-h-[44px] inline-flex items-center font-semibold text-tono-accent-light">
          read the demonstration
        </summary>
        <p className="pb-2 leading-relaxed">{episode.transcript}</p>
        <p className="pb-2 text-tono-text-softer">
          Synthetic editorial demo — not a testimonial. tono never sends a message for you.
        </p>
      </details>
    </article>
  )
}

export default function CampaignVideos() {
  return (
    <div className="grid grid-cols-1 md:grid-cols-[1.45fr_0.8fr] gap-5 items-start">
      {episodes.map((episode) => (
        <EpisodeCard key={episode.number} episode={episode} />
      ))}
    </div>
  )
}
