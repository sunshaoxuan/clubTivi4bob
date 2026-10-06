import json
from pathlib import Path

import pytest
from jinja2 import Environment, FileSystemLoader, StrictUndefined, select_autoescape

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize('locale', ['zh-CN', 'zh-TW', 'en', 'ja'])
def test_release_templates_preserve_languages_and_settings(locale):
    copy = json.loads((ROOT / 'locales' / f'{locale}.json').read_text())
    environment = Environment(loader=FileSystemLoader(ROOT / 'templates'),
                              undefined=StrictUndefined,
                              autoescape=select_autoescape(['html']))
    for page, path in [('index', '/'), ('downloads', '/downloads'),
                       ('diagnostics', '/diagnostics')]:
        rendered = environment.get_template(f'{page}.html').render(
            locale=locale, t=copy, languages={'zh-CN': '简体中文', 'zh-TW': '繁體中文',
                                            'en': 'English', 'ja': '日本語'},
            page=page, path=path, installed_devices=10)
        assert f'lang="{locale}"' in rendered
        assert 'installed-devices' in rendered
        if page == 'index':
            assert 'Mac 1.0.4 / Windows 1.0.4' in rendered
            assert 'settings-title' in rendered
            assert 'v1.0.4' in rendered
        elif page == 'downloads':
            assert 'id="release-list"' in rendered
            assert '1.0.4' in rendered
