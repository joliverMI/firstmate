"""Structural enforcement of the board's link policy.

The Admiral receives files for review as links he can open on his phone.
Two rules from standing order 17 and his own words are enforced here, not
just documented, so a card cannot silently carry a link that fails them:

  1. Never a GitHub or pull-request link.
  2. Never a link that cannot open on his phone (a bare path, or a host
     that only resolves on this machine).
"""

from __future__ import annotations

import ipaddress
from urllib.parse import urlparse

LOCAL_HOSTNAMES = {"localhost", "127.0.0.1", "0.0.0.0", "::1"}


class InvalidLinkError(ValueError):
    pass


def _is_private_literal(host: str) -> bool:
    try:
        return ipaddress.ip_address(host).is_private
    except ValueError:
        return False


def validate_review_link(url: str) -> None:
    """Raise InvalidLinkError if url cannot be sent to the Admiral as-is."""
    if not url or not url.strip():
        raise InvalidLinkError("a link needs a URL")
    parsed = urlparse(url.strip())
    if parsed.scheme not in ("http", "https"):
        raise InvalidLinkError(
            f"link must be a full http(s) URL that opens on his phone, got: {url!r}"
        )
    host = (parsed.hostname or "").lower()
    if not host:
        raise InvalidLinkError(f"link has no host: {url!r}")
    if "github" in host:
        raise InvalidLinkError(
            "never a GitHub or pull-request link to the Admiral (standing order 17) "
            f"- report the outcome in words instead: {url!r}"
        )
    if host in LOCAL_HOSTNAMES or _is_private_literal(host):
        raise InvalidLinkError(
            f"link host is local-only and will not open on his phone: {url!r}"
        )
