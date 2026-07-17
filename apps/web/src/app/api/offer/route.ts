import { cookies } from 'next/headers'
import { NextResponse } from 'next/server'

export async function GET(request: Request) {
  const interval = new URL(request.url).searchParams.get('interval')
  if (interval !== 'month' && interval !== 'year') {
    return NextResponse.json({ error: 'interval must be "month" or "year"' }, { status: 400 })
  }

  const token = (await cookies()).get('tono_api_token')?.value
  if (!token) {
    return NextResponse.json({ error: 'sign in to view your offer' }, { status: 401 })
  }

  const backendUrl = process.env.TONO_BACKEND_URL || 'https://api.tonoit.com'
  try {
    const response = await fetch(
      `${backendUrl}/v1/offer?interval=${encodeURIComponent(interval)}`,
      {
        headers: { Authorization: `Bearer ${token}` },
        cache: 'no-store',
      }
    )
    const body = await response.json().catch(() => ({}))
    return NextResponse.json(body, { status: response.status })
  } catch {
    return NextResponse.json({ error: "couldn't load the current offer" }, { status: 502 })
  }
}
