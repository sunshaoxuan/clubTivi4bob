"""Summarize native playback evidence; ASR onsets are estimates, not human truth."""
import argparse
import json
import statistics
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--observations', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    fixture = json.loads(args.fixture.read_text())
    observations = [json.loads(line) for line in args.observations.read_text().splitlines()]
    ad_start, returned = fixture['adStart'], fixture['movieReturn']
    ads = [o for o in observations if ad_start <= o['position'] < returned]
    post = [o for o in observations if o['position'] >= returned]
    first_caption = next((o for o in post if o['text']), None)
    firsts = {}
    origin = fixture['origin']
    for observation in post:
        position = observation['position']
        if not observation['text']:
            continue
        for window in fixture['manifest']['windows']:
            if not window['start'] <= position < window['end']:
                continue
            for track in window['tracks']:
                for cue in track['cues']:
                    if cue['start'] <= position < cue['end'] and cue['text'] == observation['text']:
                        firsts.setdefault(cue['cue'], position + origin)
    errors = []
    for anchor in fixture['originalHoldout']['anchors']:
        if anchor['cue'] in firsts:
            errors.append(dict(cue=anchor['cue'], asrOnset=anchor['timeline'],
                               nativeCaptionOnset=firsts[anchor['cue']],
                               errorSeconds=firsts[anchor['cue']] - anchor['timeline']))
    absolute = [abs(error['errorSeconds']) for error in errors]
    stalled = [o for o in observations if o['elapsed'] > 10 and o['buffering']]
    result = dict(scope='Native client replay of previously captured real movie/ad/movie cycle; '
                        'not a new live ad or ASR reacquisition test',
                  duration=fixture['duration'], adDuration=returned-ad_start,
                  adSamples=len(ads), adSamplesWithFilmCaption=sum(bool(o['text']) for o in ads),
                  nativeCaptionResumeSeconds=None if first_caption is None else first_caption['position']-returned,
                  sampledLayouts=sorted(set(o['layout'] for o in observations)),
                  bufferingSamplesAfterStartup=len(stalled),
                  cueCount=len(errors), medianAbsoluteError=None if not absolute else statistics.median(absolute),
                  maximumAbsoluteError=None if not absolute else max(absolute),
                  errors=errors, errorReference='Previously recorded local ASR word onsets, '
                  'including any remux timestamp shift; sampled native caption state, not screen OCR')
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps({key: value for key, value in result.items() if key != 'errors'}, ensure_ascii=False))


if __name__ == '__main__':
    main()
