"""Rewrite common, clear DASH MPDs without leaving remote URL indirections."""
import copy
import re
import xml.etree.ElementTree as ET
from urllib.parse import urljoin

VARIABLE = re.compile(r'\$(RepresentationID|Bandwidth|Number|Time)(?:%0([1-9][0-9]?)d)?\$')
PARAMETERS = {'RepresentationID': 'r', 'Bandwidth': 'b', 'Number': 'n', 'Time': 't'}


def template_url(url, signer):
    variables = list(VARIABLE.finditer(url))
    remainder = VARIABLE.sub('', url.replace('$$', ''))
    if '$' in remainder: raise ValueError('Unknown DASH template variable')
    if not variables: return signer(url, None)
    tokens = {match.group(1): match.group(0) for match in variables}
    signed = signer(url, list(tokens))
    return signed + ''.join('&' + PARAMETERS[key] + '=' + value for key, value in tokens.items())


def expand_template(url, variables, values):
    if not isinstance(variables, list) or not variables or not set(variables) <= PARAMETERS.keys():
        raise ValueError('Invalid DASH variables')
    replacements = {}
    for name in variables:
        value = values.get(PARAMETERS[name], '')
        if name == 'RepresentationID':
            if not re.fullmatch(r'[A-Za-z0-9_.-]{1,100}', value) or value in ('.', '..'): raise ValueError('Invalid representation')
        elif not re.fullmatch(r'[0-9]{1,19}', value) or int(value) >= 2**63:
            raise ValueError('Invalid DASH number')
        replacements[name] = value
    def replace(match):
        value = replacements[match.group(1)]
        width = match.group(2)
        return value.zfill(int(width)) if width else value
    return VARIABLE.sub(replace, url).replace('$$', '$')


def rewrite_mpd(payload, base, signer):
    if b'<!DOCTYPE' in payload.upper() or b'<!ENTITY' in payload.upper():
        raise ValueError('XML entities forbidden')
    try: document = ET.fromstring(payload)
    except ET.ParseError: raise ValueError('Invalid DASH XML') from None
    if document.tag.rsplit('}', 1)[-1] != 'MPD': raise ValueError('Invalid MPD')
    namespace = document.tag.split('}')[0] + '}' if '}' in document.tag else ''
    count = 0
    def tag(node): return node.tag.rsplit('}', 1)[-1]
    for node in document.iter():
        if tag(node) in ('ContentProtection', 'ContentSteering', 'PatchLocation') or any(key.endswith('}href') for key in node.attrib):
            raise ValueError('Unsupported DASH indirection')
    def rewrite_url(value, current):
        return template_url(urljoin(current, value), signer)
    def walk(node, parent_base, inherited):
        nonlocal count
        if tag(node) in ('ContentProtection', 'ContentSteering', 'PatchLocation'):
            raise ValueError('Unsupported DASH indirection')
        if any(key.endswith('}href') for key in node.attrib): raise ValueError('DASH XLink forbidden')
        bases = [child for child in node if tag(child) == 'BaseURL']
        current = urljoin(parent_base, (bases[0].text or '').strip()) if bases else parent_base
        for child in bases: node.remove(child)
        modes = {'SegmentTemplate', 'SegmentList', 'SegmentBase'}
        own = next((child for child in node if tag(child) in modes), None)
        selected = own if own is not None else inherited
        if tag(node) == 'Representation':
            count += 1
            if selected is not None:
                if own is None:
                    own = copy.deepcopy(selected)
                    node.append(own)
                for element in own.iter():
                    for key in ('media', 'initialization', 'index', 'sourceURL'):
                        if element.get(key): element.set(key, rewrite_url(element.get(key), current))
                if tag(own) == 'SegmentBase':
                    element = ET.SubElement(node, namespace + 'BaseURL')
                    element.text = signer(current, None)
            else:
                element = ET.SubElement(node, namespace + 'BaseURL')
                element.text = signer(current, None)
        if tag(node) == 'Location' and node.text: node.text = rewrite_url(node.text.strip(), current)
        if tag(node) == 'UTCTiming' and ':http-' in node.get('schemeIdUri', ''):
            node.set('value', rewrite_url(node.get('value', ''), current))
        for child in list(node):
            if tag(child) not in modes and tag(child) != 'BaseURL': walk(child, current, selected)
        if tag(node) != 'Representation' and own is not None: node.remove(own)
    walk(document, base, None)
    if not count or count > 200: raise ValueError('Invalid representation count')
    return ET.tostring(document, encoding='utf-8', xml_declaration=True)
