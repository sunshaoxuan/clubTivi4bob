import json
from pathlib import Path

import pytest
from jinja2 import Environment, FileSystemLoader, StrictUndefined, select_autoescape

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize('locale', ['zh-CN', 'zh-TW', 'en', 'ja', 'fr', 'es', 'ko'])
def test_release_templates_preserve_languages_and_settings(locale):
    copy = json.loads((ROOT / 'locales' / f'{locale}.json').read_text())
    environment = Environment(loader=FileSystemLoader(ROOT / 'templates'),
                              undefined=StrictUndefined,
                              autoescape=select_autoescape(['html']))
    for page, path in [('index', '/'), ('downloads', '/downloads'),
                       ('diagnostics', '/diagnostics'), ('release-notes', '/release-notes')]:
        rendered = environment.get_template(f'{page}.html').render(
            locale=locale, t=copy, languages={'zh-CN': '简体中文', 'zh-TW': '繁體中文',
                                            'en': 'English', 'ja': '日本語'},
            page=page, path=path, installed_devices=10)
        assert f'lang="{locale}"' in rendered
        assert 'installed-devices' in rendered
        if page == 'index':
            assert copy['showcase']['hero'][0] in rendered
            assert 'class="back-top"' in rendered
            assert 'class="history-band"' not in rendered
            assert 'signals-title' in rendered
            assert 'devices-title' in rendered
            assert 'player-title' in rendered
        elif page == 'release-notes':
            assert f'<a href="/release-notes" aria-current="page">{copy["home"]["history_label"]}</a>' in rendered
            assert 'v1.1.19 · ' in rendered
            assert 'v1.1.10 · ' in rendered
            assert 'v1.0.6' in rendered
        elif page == 'downloads':
            assert 'class="download-signing-note"' not in rendered
            assert 'id="install-title"' in rendered
            assert 'id="release-list"' in rendered
            assert copy['showcase']['download'][0] in rendered
            assert '1.1.10+103' not in copy['downloads']['intro']
            assert '1.1.19+114' in copy['downloads']['intro']
            assert '1.1.10+103' not in copy['downloads']['intro']
            assert '30' in copy['downloads']['intro']
            assert 'ad-hoc' in rendered


@pytest.mark.parametrize('page', ['release-notes', 'downloads'])
def test_static_release_copies_preserve_android_and_diagnostic_notice(page):
    rendered = (ROOT / f'{page}.html').read_text()
    if page == 'release-notes':
        assert 'v1.1.18 · ' in rendered
    else:
        assert 'id="release-list"' in rendered
    assert '1.1.10+103' not in json.loads((ROOT / 'locales' / 'zh-CN.json').read_text())['downloads']['intro']
    assert '30 天' in rendered
    assert '同意' in rendered
    assert '关闭' in rendered
