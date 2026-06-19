import asyncio
import time


class RateLimiter:
    def __init__(self, interval_seconds: float) -> None:
        self.interval = interval_seconds
        self.next_allowed_at = 0.0
        self.lock = asyncio.Lock()

    async def wait(self) -> None:
        async with self.lock:
            now = time.monotonic()
            delay = max(0.0, self.next_allowed_at - now)
            self.next_allowed_at = max(now, self.next_allowed_at) + self.interval
        if delay > 0:
            await asyncio.sleep(delay)
