import json
import re

import pytest
from fastapi.testclient import TestClient

from test_bobtv_site import module


def client_for(peer, **kwargs):
    async def application(scope, receive, send):
        if scope["type"] == "http":
            scope["client"] = (peer, 1234)
        await module.app(scope, receive, send)
    return TestClient(application, **kwargs)


@pytest.mark.parametrize("peer", ["173.245.48.1", "2606:4700::1"])
@pytest.mark.parametrize("country,expected", [
    ("CN", "zh-CN"), ("JP", "ja"), ("TW", "zh-TW"), ("HK", "zh-TW"),
    ("MO", "zh-TW"), ("US", "en"), ("SG", "en"), ("XX", "en"),
    ("T1", "en"), ("", "en"), ("jp", "en"), (" JP", "en"),
])
def test_trusted_country_mapping(peer, country, expected):
    with client_for(peer) as client:
        response = client.get("/", headers={"CF-IPCountry": country})
    assert response.headers["content-language"] == expected
    assert f'<html lang="{expected}">' in response.text
    assert "set-cookie" not in response.headers


@pytest.mark.parametrize("peer", ["127.0.0.1", "192.0.2.1", "testclient", "::1"])
def test_direct_origin_cannot_spoof_country(peer):
    with client_for(peer) as client:
        response = client.get("/", headers={"CF-IPCountry": "CN", "X-Forwarded-For": "173.245.48.1"})
    assert response.headers["content-language"] == "en"


def test_language_priority_persistence_and_secure_cookie():
    with client_for("173.245.48.1", base_url="https://bobtv.test") as client:
        client.cookies.set("bobtv_language", "en")
        assert client.get("/", headers={"CF-IPCountry": "JP"}).headers["content-language"] == "en"
        response = client.get("/downloads?lang=zh-TW", headers={"CF-IPCountry": "JP"})
        assert response.headers["content-language"] == "zh-TW"
        cookie = response.headers["set-cookie"]
        for flag in ["HttpOnly", "Secure", "SameSite=lax", "Path=/", "Max-Age=31536000"]:
            assert flag in cookie
        client.cookies.clear()
        client.cookies.set("bobtv_language", "zh-TW")
        assert client.get("/diagnostics").headers["content-language"] == "zh-TW"
        assert client.get("/?lang=bad").headers["content-language"] == "zh-TW"
        client.cookies.clear()
        client.cookies.set("bobtv_language", "bad")
        assert client.get("/?lang=bad", headers={"CF-IPCountry": "JP"}).headers["content-language"] == "ja"


@pytest.mark.parametrize("locale", ["en", "ja", "zh-CN", "zh-TW"])
@pytest.mark.parametrize("path", ["/", "/downloads", "/diagnostics"])
def test_all_locales_render_and_head_matches(locale, path):
    with TestClient(module.app) as client:
        response = client.get(path, params={"lang": locale})
        head = client.head(path, params={"lang": locale})
    assert response.status_code == head.status_code == 200
    assert response.headers["content-language"] == locale
    assert response.headers["cache-control"] == "private, no-store"
    assert response.headers["vary"] == "Cookie, CF-IPCountry"
    assert head.content == b""
    assert head.headers["content-length"] == response.headers["content-length"]
    assert f'href="/downloads?lang={locale}"' in response.text
    assert 'name="lang"' in response.text
    language_form = re.search(r'<form class="language-form".*?</form>', response.text, re.S).group(0)
    assert '<button' not in language_form
    assert '/assets/language.js?v=1' in response.text
    embedded = re.search(r'<script id="site-messages" type="application/json">(.*?)</script>', response.text, re.S)
    assert json.loads(embedded.group(1))["invalid"]
    if locale == "en":
        # Native names in the language menu are intentionally untranslated.
        body = re.sub(r'<form class="language-form".*?</form>', "", response.text, flags=re.S)
        assert not re.search(r"[\u4e00-\u9fff]", body)


def test_dictionary_shape_and_placeholders_match():
    folder = module.BASE / "locales"
    dictionaries = [json.loads(path.read_text(encoding="utf-8")) for path in sorted(folder.glob("*.json"))]

    def shape(value):
        if isinstance(value, dict):
            return {key: shape(item) for key, item in value.items()}
        if isinstance(value, list):
            return [shape(item) for item in value]
        assert isinstance(value, str) and value.strip()
        return sorted(re.findall(r"\{\w+\}", value))

    assert len(dictionaries) == 4
    assert all(shape(item) == shape(dictionaries[0]) for item in dictionaries)


@pytest.mark.parametrize("locale", ["en", "ja", "zh-CN", "zh-TW"])
def test_language_does_not_change_download_bytes(tmp_path, monkeypatch, locale):
    monkeypatch.setattr(module, "DATA", tmp_path)
    (tmp_path / "releases").mkdir()
    (tmp_path / "releases" / "BobTV.zip").write_bytes(b"PK\x03\x04demo")
    (tmp_path / "releases.json").write_text(json.dumps({"releases": [{"filename": "BobTV.zip"}]}))
    with TestClient(module.app) as client:
        client.get("/", params={"lang": locale})
        response = client.get("/downloads/BobTV.zip", params={"lang": locale}, headers={"Range": "bytes=0-3"})
    assert response.status_code == 206 and response.content == b"PK\x03\x04"
    assert "location" not in response.headers
