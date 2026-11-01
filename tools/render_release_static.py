"""Refresh static fallbacks from the same locale and templates as the site."""
import json
from pathlib import Path
from jinja2 import Environment, FileSystemLoader, StrictUndefined, select_autoescape

root = Path(__file__).resolve().parents[1] / 'website'
copy = json.loads((root / 'locales/zh-CN.json').read_text())
environment = Environment(loader=FileSystemLoader(root / 'templates'),
                          undefined=StrictUndefined, autoescape=select_autoescape(['html']))
for page, path in [('index', '/'), ('downloads', '/downloads'), ('diagnostics', '/diagnostics')]:
    output = environment.get_template(page + '.html').render(
        locale='zh-CN', t=copy, languages={'zh-CN': '简体中文', 'zh-TW': '繁體中文',
                                        'en': 'English', 'ja': '日本語'},
        page=page, path=path, installed_devices=None)
    output = '\n'.join(line.rstrip() for line in output.splitlines())
    (root / (page + '.html')).write_text(output + '\n')
print('Rendered three static fallbacks from the current localized templates')
