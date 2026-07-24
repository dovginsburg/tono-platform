const assert = require('node:assert/strict')
const { readFileSync, readdirSync, statSync } = require('node:fs')
const { join } = require('node:path')
const test = require('node:test')

const webRoot = join(__dirname, '..')
const read = (path) => readFileSync(join(webRoot, path), 'utf8')

const landing = read('src/app/page.tsx')
const pricing = read('src/app/pricing/page.tsx')
const footer = read('src/app/TonoFooter.tsx')
const videos = read('src/app/CampaignVideos.tsx')
const brand = read('src/app/TonoBrand.tsx')

function sourceFiles(path) {
  return readdirSync(path, { withFileTypes: true }).flatMap((entry) => {
    const fullPath = join(path, entry.name)
    if (entry.isDirectory()) return sourceFiles(fullPath)
    return /\.(?:ts|tsx)$/.test(entry.name) ? [fullPath] : []
  })
}

const publicAppSource = sourceFiles(join(webRoot, 'src/app'))
  .map((path) => readFileSync(path, 'utf8'))
  .join('\n')

test('landing implements the approved Mark lockup and proof surfaces', () => {
  assert.match(landing, /tono — just tone it!/)
  assert.match(landing, /product proof, not promises/)
  assert.match(landing, /texts i almost sent\./)
  assert.match(landing, /<del className=/)
  assert.match(landing, /tono never sends a message for you/)
  assert.match(brand, /tono-cursor-t-64\.png/)
})

test('commercial copy has one lifetime trial, two paid prices, unlimited, and no free tier', () => {
  for (const source of [landing, pricing, footer]) {
    assert.match(source, /lifetime 14-day trial/i)
    assert.match(source, /\$3\.99\/month/)
    assert.match(source, /\$39\.99\/year/)
    assert.match(source, /unlimited/i)
    assert.match(source, /no free tier/i)
  }
  assert.doesNotMatch(landing + pricing + footer, /priority on the rewrite queue|in 8 seconds/i)
  assert.doesNotMatch(publicAppSource, /web now|ios (?:is )?coming soon|public beta opens|install the tono ios keyboard today|free beta slots|App Store \/ Google Play/i)
})

test('public routes do not expose source-hosting or repository links', () => {
  assert.doesNotMatch(publicAppSource, /github|gitlab\.com|bitbucket\.org|codeberg\.org|sourcehut|sr\.ht/i)
  assert.doesNotMatch(publicAppSource, />\s*[^<]*\b(?:repo(?:sitor(?:y|ies))?|source\s+code)\b[^<]*</i)
})

test('all three campaign videos use native accessible controls and disciplined loading', () => {
  assert.match(videos, /<video/)
  assert.match(videos, /controls/)
  assert.match(videos, /playsInline/)
  assert.match(videos, /preload=\{episode\.featured \? 'metadata' : 'none'\}/)
  assert.match(videos, /poster=/)
  assert.match(videos, /kind="captions"/)
  assert.match(videos, /read the demonstration/)
  assert.doesNotMatch(videos, /autoPlay|autoplay/)

  for (const number of ['01', '02', '03']) {
    const media = join(webRoot, `public/media/texts-i-almost-sent/episode-${number}.mp4`)
    const poster = join(webRoot, `public/media/texts-i-almost-sent/episode-${number}-poster.png`)
    const captions = join(webRoot, `public/media/texts-i-almost-sent/episode-${number}.vtt`)
    assert.ok(statSync(media).size > 1_000_000)
    assert.ok(statSync(poster).size > 40_000)
    assert.match(readFileSync(captions, 'utf8'), /^WEBVTT/)
    assert.equal(readFileSync(media).subarray(4, 8).toString('ascii'), 'ftyp')
  }
})

test('media and brand paths honor the production /app base path', () => {
  assert.match(videos, /'\/app\/media\/texts-i-almost-sent'/)
  assert.match(brand, /compact \? '\/app\/brand\/tono-t-32\.png' : '\/app\/brand\/tono-cursor-t-64\.png'/)
})
