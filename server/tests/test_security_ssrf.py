import ipaddress
import unittest

from core.utils import _is_disallowed_ip, is_safe_external_url


class SsrfIpFilterTests(unittest.TestCase):
    def test_disallows_sensitive_ranges(self):
        for addr in [
            "169.254.169.254",  # 云元数据
            "127.0.0.1",        # 环回
            "10.0.0.1",         # 私有 A
            "172.16.0.1",       # 私有 B
            "192.168.1.1",      # 私有 C
            "0.0.0.0",          # unspecified
            "::1",              # IPv6 环回
            "::ffff:169.254.169.254",  # IPv4-mapped 元数据
        ]:
            self.assertTrue(
                _is_disallowed_ip(ipaddress.ip_address(addr)),
                f"{addr} 应被拒绝",
            )

    def test_allows_public_ips(self):
        for addr in ["8.8.8.8", "1.1.1.1", "140.82.112.3"]:
            self.assertFalse(
                _is_disallowed_ip(ipaddress.ip_address(addr)),
                f"{addr} 应被放行",
            )


class SsrfUrlTests(unittest.TestCase):
    def test_rejects_bad_scheme_and_empty(self):
        self.assertFalse(is_safe_external_url(""))
        self.assertFalse(is_safe_external_url(None))
        self.assertFalse(is_safe_external_url("ftp://example.com/a"))
        self.assertFalse(is_safe_external_url("file:///etc/passwd"))

    def test_rejects_internal_hosts(self):
        # 这些主机名解析到本机/内网，或无法解析，均应拒绝
        for url in [
            "http://127.0.0.1:8000/x",
            "http://localhost/x",
        ]:
            self.assertFalse(is_safe_external_url(url), url)


if __name__ == "__main__":
    unittest.main()
