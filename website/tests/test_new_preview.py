import json
from html.parser import HTMLParser
from pathlib import Path

from test_bobtv_site import module
from fastapi.testclient import TestClient


class PageLinks(HTMLParser):
    def __init__(self):
        super().__init__()
        self.assets = []
        self.links = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag in {"script", "img"} and "src" in attrs:
            self.assets.append(attrs["src"])
        if tag == "link":
            self.assets.append(attrs["href"])
        if tag == "a":
            self.links.append(attrs["href"])


def test_preview_is_isolated_and_all_assets_are_local():
    client = TestClient(module.app)
    home_before = client.get("/").content
    response = client.get("/new/")
    assert response.status_code == 200
    assert "BoBTV" in response.text
    parser = PageLinks()
    parser.feed(response.text)
    for asset in parser.assets:
        assert asset.startswith("./"), asset
        assert client.get("/new/" + asset[2:]).status_code == 200, asset
    for link in parser.links:
        assert link.startswith(("#", "./", "/downloads", "/diagnostics"))
    assert client.get("/new").status_code == 200
    assert client.head("/new/").status_code == 200
    assert client.get("/").content == home_before
    assert client.get("/downloads").status_code == 200
    assert client.get("/diagnostics").status_code == 200
    assert client.get("/new/unknown.txt").status_code == 404
    assert client.get("/new/../app.py").status_code == 404


def test_import_map_and_three_dependencies_are_complete():
    root = Path(__file__).parents[1] / "new"
    html = (root / "index.html").read_text(encoding="utf-8")
    imports = json.loads(html.split('<script type="importmap">')[1].split('</script>')[0])["imports"]
    assert (root / imports["three"]).is_file()
    assert (root / "vendor/three.core.js").is_file()
    for addon in ["geometries/RoundedBoxGeometry.js", "environments/RoomEnvironment.js"]:
        assert (root / imports["three/addons/"] / addon).is_file()
    assert 'role="tablist"' in html and 'role="tabpanel"' in html
    assert 'aria-label="暂停动画"' in html
