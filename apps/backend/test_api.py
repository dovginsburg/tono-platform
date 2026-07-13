"""Quick test: does the API key work from this environment?"""
import os, httpx, asyncio, json

async def test():
    key = os.environ.get("ANTHROPIC_API_KEY", "")
    print(f"Key length: {len(key)}")
    print(f"Key starts: {key[:15]}")
    
    body = {
        "model": "claude-haiku-4-5",
        "max_tokens": 50,
        "messages": [{"role": "user", "content": "Say hi"}],
    }
    async with httpx.AsyncClient(timeout=15) as c:
        r = await c.post(
            "https://api.anthropic.com/v1/messages",
            headers={"x-api-key": key, "anthropic-version": "2023-06-01"},
            json=body,
        )
        print(f"Status: {r.status_code}")
        print(f"Response: {r.text[:200]}")

asyncio.run(test())
