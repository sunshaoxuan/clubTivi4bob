"""Minimal MLHLS manifest response for a single explicitly selected HLS URL.

Wire field names follow the documented UxPlay HLS/FCUP interoperability flow.
This handler never fetches receiver-supplied URLs, follows redirects, or reads
local files. Only the synthetic master playlist is provided over FCUP.
"""
MASTER_URL = 'mlhls://localhost/master.m3u8'


def master_playlist(media_url):
    from urllib.parse import urlsplit
    parsed = urlsplit(media_url)
    if parsed.scheme not in ('http', 'https') or not parsed.hostname or any(
            character in media_url for character in '\r\n'):
        raise ValueError('Invalid selected HLS URL')
    return ('#EXTM3U\n#EXT-X-VERSION:3\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=4000000\n' + media_url + '\n').encode()


def fcup_response(event, media_url):
    if not isinstance(event, dict) or event.get('type') != 'unhandledURLRequest':
        return None
    request = event.get('request')
    if not isinstance(request, dict):
        raise ValueError('Invalid FCUP request')
    params = {}
    for key in ('FCUP_Response_RequestID', 'FCUP_Response_ClientInfo',
                'FCUP_Response_ClientRef', 'sessionID'):
        value = request.get(key)
        if value is not None:
            if type(value) is not int or not 0 <= value < 2**64:
                raise ValueError('Invalid FCUP identifier')
            params[key] = value
    url = request.get('FCUP_Response_URL')
    if not isinstance(url, str) or len(url) > 4096:
        raise ValueError('Invalid FCUP URL')
    allowed = url == MASTER_URL
    params.update({'FCUP_Response_URL': url,
                   'FCUP_Response_StatusCode': 200 if allowed else 404,
                   'FCUP_Response_Headers': {'Content-Type': 'application/vnd.apple.mpegurl'},
                   'FCUP_Response_Data': master_playlist(media_url) if allowed else b''})
    return {'type': 'unhandledURLResponse', 'params': params}
