"""Regenerate the Dart country map from the shared Unicode CLDR mapping."""
import json
from pathlib import Path
root = Path(__file__).resolve().parents[2]
obj = json.loads((root / "website/country_names.json").read_text())
names = obj["names"]
out="// Generated from website/country_names.json by tools/catalog/generate_country_names.py.\nclass CountryNames {\n  CountryNames._();\n\n  static String normalize(String value) {\n    final cleaned = value.trim().replaceAll(RegExp(r'\\s+'), ' ');\n    return aliases[cleaned.toLowerCase()] ?? cleaned;\n  }\n\n  static const byCode = <String, String>{\n"
for k,v in sorted(names.items()):
 if k!='cn':out+=f'    {json.dumps(k,ensure_ascii=False)}: {json.dumps(v,ensure_ascii=False)},\n'
out+='  };\n\n  static const aliases = <String, String>{\n'
for k,v in obj['aliases'].items():out+=f'    {json.dumps(k,ensure_ascii=False)}: {json.dumps(v,ensure_ascii=False)},\n'
out+='  };\n}\n';(root/'lib/data/services/country_names.dart').write_text(out)
