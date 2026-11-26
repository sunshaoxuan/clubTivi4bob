"""Small rotating native-cast log with an explicit non-secret field allowlist."""
import json
import os
from pathlib import Path
import time
import re
import sys
import contextvars
import errno
import socket
import ipaddress
import subprocess
import traceback

request_id = contextvars.ContextVar('diagnostic_request_id', default=None)

FIELDS = {'stage', 'count', 'audioPackets', 'status', 'errorType', 'reason',
          'requests', 'elapsedMs', 'lagMs', 'provided', 'bytes', 'mode',
          'sourceEnded', 'decoderExit', 'hlsLiveEdge', 'errorCode', 'osErrorCode',
          'nativeStackFrames', 'helperMaxRssBytes', 'helperCpuUserMs', 'helperCpuSystemMs',
          'requestId', 'localAddress', 'receiverAddress', 'prefixLength', 'sameSubnet',
          'networkProbe', 'localAddressSource', 'routeAvailable', 'interfaceName',
          'gatewayAddress', 'vpnInterface', 'receiverPort', 'ffmpegAvailable',
          'pythonVersion', 'pyatvVersion', 'ffmpegVersion',
          'receiverModel', 'receiverFeatures', 'passwordRequired', 'savedCredentialsAvailable'}
FIELDS.add('interfaceIndex')
FIELDS |= {'authMode', 'authPhase', 'authEndpoint', 'authResult', 'authReason',
           'authTlvError', 'retryAfterSeconds', 'httpStatus', 'causeType'}


def failure_details(error):
    kind = type(error).__name__
    number = getattr(error, 'errno', None)
    code = 'other'
    if isinstance(error, FileNotFoundError): code = 'missing_dependency'
    elif isinstance(error, MemoryError): code = 'out_of_memory'
    elif isinstance(error, TimeoutError): code = 'timeout'
    elif isinstance(error, PermissionError): code = 'permission_denied'
    elif number in {errno.ENETUNREACH, errno.EHOSTUNREACH}: code = 'no_route'
    elif number == errno.ECONNREFUSED: code = 'connection_refused'
    elif isinstance(error, OSError): code = 'socket'
    elif any(x in kind for x in ('Authentication', 'Credentials', 'Pairing')): code = 'authentication'
    elif 'NotSupported' in kind: code = 'not_supported'
    frames = []
    for frame, line in traceback.walk_tb(error.__traceback__):
        module = frame.f_globals.get('__name__', '')
        function = frame.f_code.co_name
        if re.fullmatch(r'[A-Za-z_][A-Za-z0-9_.]*', module) and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', function):
            frames.append(f'{module}:{function}:{line}')
    result = {'errorType': kind, 'errorCode': code}
    reason = getattr(error, 'reason', None)
    if isinstance(reason, str) and re.fullmatch(r'[A-Za-z0-9_-]{1,80}', reason):
        result['authReason'] = reason
        result['authResult'] = ('backoff' if reason in {'receiver-error-3', 'receiver-error-5', 'receiver-error-7', 'backoff-active'} else
            'transport_error' if reason == 'timeout' else
            'protocol_error' if any(x in reason for x in ('invalid', 'mismatch', 'truncated', 'unexpected')) else 'rejected')
        if reason == 'timeout': result['errorCode'] = 'timeout'
        if result['authResult'] == 'backoff': result['errorCode'] = 'server_busy'
    for attribute, key in [('stage', 'authPhase'), ('auth_mode', 'authMode'),
                           ('http_status', 'httpStatus'), ('tlv_error', 'authTlvError'),
                           ('retry_after', 'retryAfterSeconds')]:
        value = getattr(error, attribute, None)
        if value is not None: result[key] = value
    if frames: result['nativeStackFrames'] = '\n'.join(frames[-12:])
    if isinstance(number, int): result['osErrorCode'] = number
    try:
        import resource
        usage = resource.getrusage(resource.RUSAGE_SELF)
        result.update(helperMaxRssBytes=int(usage.ru_maxrss * (1 if sys.platform == 'darwin' else 1024)),
                      helperCpuUserMs=int(usage.ru_utime * 1000),
                      helperCpuSystemMs=int(usage.ru_stime * 1000))
    except (ImportError, OSError): pass
    return result


def record_network(receiver, port):
    result = {'stage': 'network-environment', 'receiverAddress': str(receiver),
              'receiverPort': port, 'networkProbe': 'partial'}
    try:
        address = ipaddress.ip_address(str(receiver))
        with socket.socket(socket.AF_INET6 if address.version == 6 else socket.AF_INET,
                           socket.SOCK_DGRAM) as route:
            route.connect((str(receiver), port))  # Select route, send no packets.
            local = route.getsockname()[0]
        result.update(localAddress=local, localAddressSource='socket_route', routeAvailable=True)
        if sys.platform == 'darwin' and address.version == 4:
            route = subprocess.check_output(['/sbin/route', '-n', 'get', str(receiver)],
                stderr=subprocess.DEVNULL, timeout=2, text=True)
            interface = re.search(r'interface:\s*(\S+)', route).group(1)
            config = subprocess.check_output(['/sbin/ifconfig', interface],
                stderr=subprocess.DEVNULL, timeout=2, text=True)
            match = re.search(r'inet '+re.escape(local)+r' netmask 0x([0-9a-f]+)', config)
            result.update(interfaceName=interface, vpnInterface=interface.startswith(('utun', 'tun', 'tap', 'wg')))
            if match:
                mask = str(ipaddress.IPv4Address(int(match[1], 16)))
                network = ipaddress.ip_network(f'{local}/{mask}', strict=False)
                result.update(prefixLength=network.prefixlen, sameSubnet=address in network,
                              networkProbe='complete')
        elif sys.platform == 'win32':
            # Both interpolated values have already been parsed as IP addresses.
            command = (f"$a=Get-NetIPAddress -IPAddress '{local}' -ErrorAction Stop | Select-Object -First 1; "
                       f"$r=Find-NetRoute -RemoteIPAddress '{address}' -ErrorAction Stop | Where-Object {{$_.CimClass.CimClassName -eq 'MSFT_NetRoute'}} | Select-Object -First 1; "
                       "$n=Get-NetAdapter -InterfaceIndex $a.InterfaceIndex -ErrorAction SilentlyContinue; "
                       "@{prefixLength=[int]$a.PrefixLength;interfaceIndex=[int]$a.InterfaceIndex;"
                       "interfaceName=($a.InterfaceAlias -replace '[^A-Za-z0-9_.-]','_');"
                       "gatewayAddress=$r.NextHop;vpnInterface=[bool]($n.InterfaceDescription -match 'Tailscale|WireGuard|VPN|TAP|TUN')} | ConvertTo-Json -Compress")
            info = json.loads(subprocess.check_output(['powershell.exe', '-NoProfile', '-NonInteractive',
                '-Command', command], stderr=subprocess.DEVNULL, timeout=5, text=True))
            network = ipaddress.ip_network(f"{local}/{info['prefixLength']}", strict=False)
            result.update({k: v for k, v in info.items() if v is not None})
            result.update(sameSubnet=address in network, networkProbe='complete')
    except OSError as error:
        result.update(failure_details(error))
        if result['errorCode'] == 'no_route':
            result.update(networkProbe='no_route', routeAvailable=False)
    except (ValueError, AttributeError, subprocess.SubprocessError): pass
    record(result)


def record(item):
    try:
        item = dict(item)
        if request_id.get(): item.setdefault('requestId', request_id.get())
        if sys.platform == 'darwin' and 'LOCALAPPDATA' not in os.environ:
            folder = Path.home() / 'Library' / 'Application Support' / 'BobTV' / 'AirPlay'
        else:
            folder = Path(os.environ.get('LOCALAPPDATA', str(Path.home()))) / 'BobTV' / 'AirPlay'
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / 'native-cast.log'
        if path.exists() and path.stat().st_size > 256 * 1024:
            path.replace(folder / 'native-cast.previous.log')
        clean = {k: v for k, v in item.items() if k in FIELDS
                 and isinstance(v, (str, int, float, bool))
                 and (not isinstance(v, str) or
                      (k in {'localAddress', 'receiverAddress', 'gatewayAddress'} and _address(v)) or
                      (k == 'nativeStackFrames' and len(v) <= 2000 and re.fullmatch(r'[A-Za-z0-9_.:\n]{1,2000}', v)) or
                      (k in {'pythonVersion', 'pyatvVersion', 'ffmpegVersion'} and re.fullmatch(r'\d+(?:\.\d+){1,3}', v)) or
                      (k == 'receiverModel' and re.fullmatch(r'[A-Za-z0-9 ()@.+,_-]{1,160}', v)) or
                      (k == 'receiverFeatures' and re.fullmatch(r'[A-Fa-f0-9x,]{1,80}', v)) or
                      re.fullmatch(r'[A-Za-z0-9_-]{1,80}', v))}
        print(json.dumps({'event': 'diagnostic', **clean}), flush=True)
        # Values originate only from fixed stage/reason enums and numeric metrics.
        clean['time'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        with path.open('a', encoding='utf-8') as stream:
            stream.write(json.dumps(clean) + '\n')
    except OSError:
        pass


def _address(value):
    try: ipaddress.ip_address(value); return True
    except ValueError: return False
