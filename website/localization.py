"""Server-rendered page languages, with geolocation restricted to trusted edges."""

import ipaddress
import json
from pathlib import Path

from fastapi import Request
from fastapi.responses import HTMLResponse
from jinja2 import Environment, FileSystemLoader, StrictUndefined, select_autoescape

BASE = Path(__file__).resolve().parent
LANGUAGES = {"zh-CN": "简体中文", "en": "English", "ja": "日本語", "zh-TW": "繁體中文"}
COUNTRY_LANGUAGES = {"CN": "zh-CN", "JP": "ja", "TW": "zh-TW", "HK": "zh-TW", "MO": "zh-TW"}
CF_RANGES = tuple(ipaddress.ip_network(value) for value in json.loads(
    (BASE / "cloudflare_ranges.json").read_text(encoding="utf-8"))["ranges"])
COPY = {locale: json.loads((BASE / "locales" / f"{locale}.json").read_text(encoding="utf-8"))
        for locale in LANGUAGES}
TEMPLATES = Environment(loader=FileSystemLoader(BASE / "templates"),
                        autoescape=select_autoescape(["html"]), undefined=StrictUndefined)


def language(request: Request) -> str:
    explicit = request.query_params.get("lang")
    if explicit in LANGUAGES:
        return explicit
    remembered = request.cookies.get("bobtv_language")
    if remembered in LANGUAGES:
        return remembered
    try:
        peer = ipaddress.ip_address(request.client.host if request.client else "")
    except ValueError:
        return "en"
    if any(peer in network for network in CF_RANGES):
        return COUNTRY_LANGUAGES.get(request.headers.get("cf-ipcountry", ""), "en")
    return "en"


def page(request: Request, name: str) -> HTMLResponse:
    locale = language(request)
    response = HTMLResponse(TEMPLATES.get_template(f"{name}.html").render(
        locale=locale, t=COPY[locale], languages=LANGUAGES, page=name,
        path=request.url.path), headers={"Content-Language": locale,
        "Cache-Control": "private, no-store", "Vary": "Cookie, CF-IPCountry"})
    if request.query_params.get("lang") in LANGUAGES:
        response.set_cookie("bobtv_language", locale, max_age=31536000,
                            httponly=True, secure=request.url.scheme == "https", samesite="lax")
    return response
