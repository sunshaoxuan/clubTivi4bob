#!/usr/bin/env python3
"""Exercise the production radio filter through the shipped macOS libmpv ABI.

First export the Dart filter with BOBTV_RADIO_NATIVE_FILTER_PATH=<path> flutter
 test test/radio_audio_spectrum_test.dart, then pass --filter-file and the built
 app's Contents/Frameworks. Audio is sent to a null sink or a temporary PCM file.
"""
import argparse
import ctypes as c
import json
import math
import re
from pathlib import Path
import struct
import tempfile
import time
import wave


def load(frameworks):
    pending = list(frameworks.glob('*.framework'))
    for _ in range(len(pending)):
        for framework in pending[:]:
            try:
                c.CDLL(str(framework / framework.stem))
                pending.remove(framework)
            except OSError:
                pass
    lib = c.CDLL(str(frameworks / 'Mpv.framework/Mpv'))
    lib.mpv_create.restype = c.c_void_p
    lib.mpv_initialize.argtypes = [c.c_void_p]
    lib.mpv_set_option_string.argtypes = [c.c_void_p, c.c_char_p, c.c_char_p]
    lib.mpv_command.argtypes = [c.c_void_p, c.POINTER(c.c_char_p)]
    lib.mpv_get_property_string.argtypes = [c.c_void_p, c.c_char_p]
    lib.mpv_get_property_string.restype = c.c_void_p
    lib.mpv_free.argtypes = [c.c_void_p]
    lib.mpv_terminate_destroy.argtypes = [c.c_void_p]
    return lib


class Probe:
    def __init__(self, lib, graph, output=None):
        self.lib = lib
        self.handle = lib.mpv_create()
        options = {'vo': 'null', 'ao': 'pcm' if output else 'null', 'msg-level': 'all=no',
                   'audio-format': 's16', 'volume': '100', 'af': graph}
        if output:
            options.update({'ao-pcm-file': str(output), 'ao-pcm-waveheader': 'no', 'untimed': 'yes'})
        for key, value in options.items():
            assert lib.mpv_set_option_string(self.handle, key.encode(), value.encode()) >= 0, key
        assert lib.mpv_initialize(self.handle) >= 0

    def command(self, *args):
        assert self.lib.mpv_command(self.handle, (c.c_char_p * (len(args) + 1))(
            *[a.encode() for a in args], None)) >= 0, args

    def get(self, name):
        pointer = self.lib.mpv_get_property_string(self.handle, name.encode())
        if not pointer:
            return ''
        value = c.string_at(pointer).decode()
        self.lib.mpv_free(pointer)
        return value

    def close(self):
        self.lib.mpv_terminate_destroy(self.handle)


def tone(path, frequency, amplitude=16000, opposite=False, rate=48000):
    samples = bytearray()
    for i in range(rate):
        value = int(amplitude * math.sin(2 * math.pi * frequency * i / rate))
        samples += struct.pack('<hh', value, -value if opposite else value)
    with wave.open(str(path), 'wb') as audio:
        audio.setparams((2, 2, rate, 0, 'NONE', 'not compressed'))
        audio.writeframes(samples)
    return bytes(samples)


def main(frameworks, filter_file):
    lib = load(frameworks)
    graph = filter_file.read_text().strip()
    labels = re.findall(r'@([^:]+):lavfi=', graph)
    assert len(labels) == 1, labels
    results = []
    with tempfile.TemporaryDirectory(prefix='bobtv-spectrum-') as directory:
        directory = Path(directory)
        def measure(frequency, muted=False, **kwargs):
            path = directory / 'input.wav'
            tone(path, frequency, **kwargs)
            probe = Probe(lib, graph)
            try:
                if muted:
                    probe.command('set', 'mute', 'yes')
                    probe.command('set', 'volume', '0')
                probe.command('loadfile', str(path))
                deadline = time.monotonic() + 3
                levels = []
                while time.monotonic() < deadline:
                    time.sleep(.05)
                    if float(probe.get('time-pos') or '0') < .3:
                        continue
                    levels = []
                    for label in labels:
                        raw = probe.get(f'af-metadata/{label}')
                        if not raw:
                            break
                        metadata = json.loads(raw)
                        if metadata.get('lavfi.bobtv_spectrum.ready') != '1':
                            continue
                        assert len(metadata) == 129, metadata
                        levels.extend(float(metadata[f'lavfi.bobtv_spectrum.{i}']) for i in range(128))
                    if len(levels) == 128:
                        break
                assert len(levels) == 128, f'No live band data: {levels}'
                probe.command('set', 'pause', 'yes')
                time.sleep(.08)
                position = probe.get('time-pos')
                time.sleep(.12)
                assert probe.get('time-pos') == position, 'Pause advanced audio'
                return levels
            finally:
                probe.close()

        for band in (20, 70, 110):
            frequency = 40 * 400 ** (band / 127)
            levels = measure(frequency)
            peak = max(range(128), key=levels.__getitem__)
            assert abs(peak - band) <= 1, (frequency, peak, levels)
            assert levels[peak] - levels[(peak + 64) % 128] > 15
            results.append({'frequency_hz': round(frequency, 2), 'peak_band': peak})
        # Match the app's runtime attach/remove path and retain existing filters.
        path = directory / 'input.wav'
        tone(path, 1000)
        live = Probe(lib, 'equalizer=f=1000:t=q:w=1:g=0')
        try:
            live.command('loadfile', str(path))
            time.sleep(.15)
            previous = live.get('af')
            live.command('af', 'add', graph)
            time.sleep(.15)
            for label in labels:
                assert live.get(f'af-metadata/{label}'), 'Runtime attachment produced no metadata'
            for label in labels:
                live.command('af', 'remove', '@' + label)
            assert live.get('af') == previous, 'Existing audio filters were changed'
        finally:
            live.close()
        results.append({'live_attach_detach': 'passed', 'existing_audio_filters': 'preserved'})
        reference = measure(1000)
        muted = measure(1000, muted=True)
        assert max(abs(10 ** (a / 20) - 10 ** (b / 20)) for a, b in zip(reference, muted)) < .001, 'Muted preview lost its input signal'
        opposite = measure(1000, opposite=True)
        assert max(abs(10 ** (a / 20) - 10 ** (b / 20)) for a, b in zip(reference, opposite)) < .001, 'Stereo cancellation'
        quiet = measure(1000, amplitude=8000)
        assert 5.9 < max(reference) - max(quiet) < 6.1, 'Amplitude not reflected in bands'
        silence = measure(1000, amplitude=0)
        assert all(value == -math.inf for value in silence), silence
        low_rate = measure(1000, rate=16000)
        assert max(low_rate) > -20, 'Low-sample-rate station lost analysis'
        path = directory / 'input.wav'
        original = tone(path, 1000, opposite=True)
        output = directory / 'output.pcm'
        probe = Probe(lib, graph, output)
        try:
            probe.command('loadfile', str(path))
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                time.sleep(.05)
                if output.exists() and output.stat().st_size >= len(original):
                    break
        finally:
            probe.close()
        rendered = output.read_bytes()
        assert rendered == original, f'Analysis changed output PCM: {len(rendered)} vs {len(original)}'
        results.append({'silence': 'zero', 'stereo_opposite_phase': 'preserved',
                        'amplitude_half': 'minus 6.02 dB', 'paused_audio': 'stopped',
                        'low_sample_rate': 'passed', 'output_pcm': 'byte-identical', 'muted_preview_input': 'preserved'})
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--frameworks', type=Path, required=True)
    parser.add_argument('--filter-file', type=Path, required=True)
    arguments = parser.parse_args()
    main(arguments.frameworks.resolve(), arguments.filter_file.resolve())
