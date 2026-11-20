"""Android installation order, independent of BobTV's visible build counter."""
import re


def base_install_code(version):
    match = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)\+(\d+)', version)
    if not match:
        raise ValueError('Invalid BobTV version')
    major, minor, patch, counter = map(int, match.groups())
    if (major, minor) < (1, 3):
        return counter
    if not (0 <= major <= 20 and 0 <= minor <= 99 and 0 <= patch <= 99 and 0 <= counter <= 999):
        raise ValueError('Android installation code components exceed their ranges')
    return ((major * 100 + minor) * 100 + patch) * 10000 + counter


def split_install_code(version, platform):
    return base_install_code(version) + {'android-arm': 1000, 'android-arm64': 2000, 'android-x64': 4000}[platform]
