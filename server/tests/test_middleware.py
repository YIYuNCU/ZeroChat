import logging
import unittest

from fastapi.responses import JSONResponse
from starlette.requests import Request

from core.middleware import ApiRateLimitMiddleware, PathWhitelistMiddleware


TOKEN = "test-auth-token-123456"


def make_request(path="/api/health", method="GET", headers=None, client_host="127.0.0.1"):
    scope = {
        "type": "http",
        "method": method,
        "path": path,
        "query_string": b"",
        "headers": [
            (str(key).lower().encode(), str(value).encode())
            for key, value in (headers or {}).items()
        ],
        "client": (client_host, 12345),
        "server": ("testserver", 80),
        "scheme": "http",
    }
    return Request(scope)


class ApiRateLimitMiddlewareTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.now = 100.0
        self.middleware = ApiRateLimitMiddleware(
            None,
            {"auth_token": TOKEN},
            logging.getLogger("test-rate-limit"),
            window_seconds=60,
            unauthenticated_limit=2,
            authenticated_limit=3,
            max_clients=2,
            clock=lambda: self.now,
        )

    async def call(self, request):
        async def next_handler(_):
            return JSONResponse({"ok": True})

        return await self.middleware.dispatch(
            request,
            next_handler,
        )

    async def test_invalid_requests_are_limited_and_include_retry_after(self):
        request = make_request(headers={"X-Forwarded-For": "198.51.100.10"})
        self.assertEqual((await self.call(request)).status_code, 200)
        self.assertEqual((await self.call(request)).status_code, 200)
        response = await self.call(request)
        self.assertEqual(response.status_code, 429)
        self.assertEqual(response.headers["retry-after"], "60")

    async def test_authenticated_bucket_has_higher_limit(self):
        request = make_request(
            headers={"X-Auth-Token": TOKEN},
            client_host="198.51.100.11",
        )
        for _ in range(3):
            self.assertEqual((await self.call(request)).status_code, 200)
        self.assertEqual((await self.call(request)).status_code, 429)

    async def test_x_forwarded_for_uses_last_valid_address_and_falls_back(self):
        request = make_request(
            headers={"X-Forwarded-For": "203.0.113.1, invalid, 2001:db8::2"},
            client_host="192.0.2.5",
        )
        self.assertEqual(self.middleware._client_ip(request), "2001:db8::2")

        malformed = make_request(
            headers={"X-Forwarded-For": "invalid, also-invalid"},
            client_host="192.0.2.5",
        )
        self.assertEqual(self.middleware._client_ip(malformed), "192.0.2.5")

    async def test_expired_window_is_pruned(self):
        request = make_request(client_host="198.51.100.12")
        await self.call(request)
        await self.call(request)
        self.assertEqual(len(self.middleware._buckets), 1)
        self.now = 161
        self.assertEqual((await self.call(request)).status_code, 200)
        self.assertEqual(len(self.middleware._buckets), 1)

    async def test_options_and_non_api_requests_bypass_limit(self):
        options = make_request(method="OPTIONS")
        for _ in range(4):
            self.assertEqual((await self.call(options)).status_code, 200)

        scanner = make_request(path="/wp-admin")
        for _ in range(4):
            self.assertEqual((await self.call(scanner)).status_code, 200)

    async def test_scanner_path_is_rejected_by_whitelist(self):
        whitelist = PathWhitelistMiddleware(None, logging.getLogger("test-whitelist"))
        response = await whitelist.dispatch(
            make_request(path="/.env"),
            lambda _: JSONResponse({"unexpected": True}),
        )
        self.assertEqual(response.status_code, 404)


if __name__ == "__main__":
    unittest.main()
