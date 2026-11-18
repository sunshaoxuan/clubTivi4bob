import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clubtivi/features/player/live_subtitle_timeline.dart';
import 'package:clubtivi/features/player/subtitle_variants.dart';

String id(String character) => List.filled(64, character).join();

Map<String, String> candidate(String hex, String language) => {
  'id': id(hex),
  'language': language,
  'provider': 'Example subtitle provider',
  'label': 'Release $hex',
};

Map<String, Object?> status({
  List<Object?>? variants,
  String? selected,
  String? active,
}) => {
  'variantCandidates': variants ?? [candidate('a', 'en'), candidate('b', 'en')],
  'selectedVariantId': selected,
  'activeVariantId': active,
};

void main() {
  test('only three distinct valid candidates per supported language', () {
    final parsed = SubtitleVariantCandidate.parse([
      candidate('a', 'zh-Hans'),
      candidate('a', 'zh-CN'),
      candidate('b', 'zh-CN'),
      candidate('c', 'zh-CN'),
      candidate('d', 'zh-CN'),
      candidate('e', 'en'),
      candidate('f', 'de'),
      candidate('G', 'ja'),
      {...candidate('0', 'ko'), 'label': ' '},
    ]);
    expect(parsed.map((v) => v.id), [id('a'), id('b'), id('c'), id('e')]);
    expect(parsed.first.language, 'zh-CN');
    expect(
      SubtitleVariantOptions(candidates: parsed).forLanguage('es').single.id,
      id('e'),
    );
  });

  test('an offered language can be pinned without changing the preference', () {
    final options = ValueNotifier(const SubtitleVariantOptions());
    addTearDown(options.dispose);
    final selection = SubtitleVariantSelection(options, 'zh-CN');
    final variants = [candidate('a', 'en'), candidate('b', 'fr')];
    selection.accept(
      'film',
      status(variants: variants),
      acknowledgesRequest: true,
    );
    expect(selection.select(id('c'), options.value.scope), isFalse);
    expect(selection.select(id('b'), options.value.scope), isTrue);
    expect(selection.request.query, {'language': 'zh-CN', 'variant': id('b')});
    expect(
      selection
          .accept(
            'film',
            status(variants: variants, selected: id('b'), active: id('b')),
            acknowledgesRequest: true,
          )
          .render,
      isTrue,
    );
  });

  test('pinned English fallback retains the requested language', () {
    final options = ValueNotifier(const SubtitleVariantOptions());
    addTearDown(options.dispose);
    final selection = SubtitleVariantSelection(options, 'zh-CN');
    selection.accept(
      'first',
      status(active: id('a')),
      acknowledgesRequest: true,
    );
    final autoRequest = selection.request;
    expect(autoRequest.query, {'language': 'zh-CN'});
    expect(selection.select(id('b'), options.value.scope), isTrue);
    expect(selection.isCurrent(autoRequest), isFalse);
    expect(selection.request.query, {'language': 'zh-CN', 'variant': id('b')});
    expect(options.value.activeId, isNull);
    expect(selection.pending, isTrue);

    final stale = selection.accept(
      'first',
      status(selected: id('b'), active: id('a')),
      acknowledgesRequest: true,
    );
    expect(stale.render, isFalse);
    expect(options.value.selectedId, id('b'));
    expect(options.value.activeId, isNull);

    final aligned = selection.accept(
      'first',
      status(selected: id('b'), active: id('b')),
      acknowledgesRequest: false,
    );
    expect(aligned.render, isTrue);
    expect(options.value.activeId, id('b'));
    expect(selection.pending, isFalse);

    selection.select(null, options.value.scope);
    expect(selection.request.query, {'language': 'zh-CN'});
    expect(
      selection
          .accept('first', status(active: id('a')), acknowledgesRequest: false)
          .render,
      isFalse,
    );
    expect(
      selection
          .accept('first', status(active: id('a')), acknowledgesRequest: true)
          .render,
      isTrue,
    );
  });

  test(
    'programme and language changes discard pins and stale menu actions',
    () {
      final options = ValueNotifier(const SubtitleVariantOptions());
      addTearDown(options.dispose);
      final selection = SubtitleVariantSelection(options, 'en');
      selection.accept('first', status(), acknowledgesRequest: true);
      final oldScope = options.value.scope;
      selection.select(id('b'), oldScope);
      final pinned = selection.request;

      selection.accept('second', status(), acknowledgesRequest: true);
      expect(options.value.selectedId, isNull);
      expect(selection.isCurrent(pinned), isFalse);
      expect(selection.select(id('b'), oldScope), isFalse);
      expect(selection.request.query, {'language': 'en'});

      selection.select(id('b'), options.value.scope);
      expect(selection.setLanguage('fr'), isTrue);
      expect(options.value.selectedId, isNull);
      expect(selection.request.query, {'language': 'fr'});
    },
  );

  test(
    'same-programme session replacement waits for its resource catalogue',
    () {
      final options = ValueNotifier(const SubtitleVariantOptions());
      addTearDown(options.dispose);
      final selection = SubtitleVariantSelection(options, 'en');
      selection.accept('first', status(), acknowledgesRequest: true);
      selection.select(id('b'), options.value.scope);
      selection.renewSession();
      final waiting = selection.accept('first', {
        'variantCandidates': [],
        'phase': 'searching',
      }, acknowledgesRequest: true);
      expect(waiting.render, isFalse);
      expect(selection.request.query, {'language': 'en', 'variant': id('b')});
      final withdrawn = selection.accept(
        'first',
        status(variants: [candidate('a', 'en')], active: id('a')),
        acknowledgesRequest: true,
      );
      expect(withdrawn.render, isTrue);
      expect(selection.request.query, {'language': 'en'});
    },
  );

  test('same-language stale tracks cannot replace the requested version', () {
    final timeline = LiveSubtitleTimeline('session', 'route', [
      {
        'start': 0,
        'end': 30,
        'state': 'LOCKED',
        'program': 'film',
        'asset': 'edition',
        'tracks': [
          {
            'language': 'en',
            'variantId': id('a'),
            'verified': true,
            'cues': [
              {'start': 0, 'end': 10, 'text': 'First version'},
            ],
          },
          {
            'language': 'en',
            'variantId': id('b'),
            'verified': true,
            'cues': [
              {'start': 0, 'end': 10, 'text': 'Pinned version'},
            ],
          },
        ],
      },
    ]);
    expect(timeline.textAt(1, 'zh-CN'), 'First version');
    expect(timeline.textAt(1, 'zh-CN', variantId: id('b')), 'Pinned version');
    expect(timeline.textAt(1, 'zh-CN', variantId: id('c')), isEmpty);
    expect(timeline.variantLanguageAt(1, id('b')), 'en');
    expect(timeline.variantLanguageAt(1, id('c')), isNull);
  });
}
