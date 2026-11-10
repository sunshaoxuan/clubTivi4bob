"""Public page rendering and browser language negotiation."""

import json
import re
from functools import lru_cache, partial
from pathlib import Path

from fastapi import Request
from fastapi.responses import HTMLResponse
from jinja2 import Environment, FileSystemLoader, select_autoescape
from markupsafe import Markup, escape

BASE = Path(__file__).resolve().parent
MIRROR_ROOT = "https://cndrp.com/bobtv"
PAGES = {"/": "index", "/downloads": "downloads", "/diagnostics": "diagnostics",
         "/privacy": "privacy", "/code-signing": "code-signing"}
LANGUAGES = {"en": "English", "zh-CN": "简体中文", "zh-TW": "繁體中文",
             "ja": "日本語", "fr": "Français", "es": "Español", "ko": "한국어"}
COUNTRY_LANGUAGES = {"CN": "zh-CN", "HK": "zh-TW", "MO": "zh-TW",
                     "TW": "zh-TW", "JP": "ja", "KR": "ko", "FR": "fr",
                     "ES": "es", "MX": "es", "AR": "es"}
COOKIE = "bobtv_language"
ENV = Environment(loader=FileSystemLoader(BASE / "templates"),
                  autoescape=select_autoescape(["html"]))


def language_for(tag):
    parts = (tag or "").lower().split("-")
    if parts[0] == "zh":
        if "hant" in parts:
            return "zh-TW"
        if "hans" in parts:
            return "zh-CN"
        return "zh-TW" if {"tw", "hk", "mo"}.intersection(parts[1:]) else "zh-CN"
    return parts[0] if parts[0] in LANGUAGES else None


def preferred_language(header):
    choices = []
    for entry in header.split(","):
        tag, *parameters = entry.split(";")
        weight = 1.0
        for parameter in parameters:
            key, _, value = parameter.strip().partition("=")
            if key.lower() == "q":
                try:
                    weight = float(value)
                except ValueError:
                    weight = 0.0
        locale = language_for(tag.strip())
        if locale and 0 < weight <= 1:
            choices.append((weight, locale))
    return max(choices, key=lambda item: item[0])[1] if choices else None


@lru_cache(maxsize=len(LANGUAGES))
def messages(locale):
    return json.loads((BASE / "locales" / (locale + ".json")).read_text(encoding="utf-8"))


def policy_text(prefix, text, *links):
    parts = re.split(r"(\{link\d+\})", text)
    for i in range(1, len(parts), 2):
        href, label = links[int(parts[i][5:-1])]
        if href in PAGES:
            href = prefix + href
        parts[i] = Markup('<a href="{}">{}</a>').format(href, label)
    return Markup("").join(escape(part) for part in parts)


def render_page(request: Request):
    mirror = request.state.bobtv_mirror
    prefix = "/bobtv" if mirror else ""
    path = request.url.path
    explicit = request.query_params.get("lang")
    saved = request.cookies.get(COOKIE)
    locale = (explicit if explicit in LANGUAGES else saved if saved in LANGUAGES
              else preferred_language(request.headers.get("accept-language", "")) or COUNTRY_LANGUAGES.get(request.state.bobtv_country, "en"))
    page = PAGES[path]
    response = HTMLResponse(
        ENV.get_template(page + ".html").render(
            page=page, path=prefix + path, site_root=prefix, locale=locale,
            t=messages(locale), languages=LANGUAGES, installed_devices=None,
            policy_text=partial(policy_text, prefix),
        ),
        headers={"Content-Language": locale, "Cache-Control": "private, no-store",
                 "Vary": "Accept-Language, Cookie"},
    )
    if explicit in LANGUAGES and explicit != saved:
        response.set_cookie(COOKIE, explicit, max_age=365 * 86400, path=prefix + "/",
                            secure=True, httponly=True, samesite="lax")
    return response
