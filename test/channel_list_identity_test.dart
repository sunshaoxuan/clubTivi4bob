import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/features/channels/channel_list_identity.dart';

void main() {
  test('fullscreen guide follows the playing ID after list insertion', () {
    final snapshot = ChannelListIdentity.includingCurrent(
      ['CCTV-1', 'CCTV-3', 'CCTV-6'], 'CCTV-6', (id) => id,
    );
    final index = ChannelListIdentity.indexOf(snapshot, 'CCTV-6', (id) => id);
    expect(index, 2);
    expect(snapshot[index], 'CCTV-6');
  });

  test('fullscreen retains a playing channel excluded by the category', () {
    final channels = ['CCTV-1', 'CCTV-2'];
    final snapshot = ChannelListIdentity.includingCurrent(
      channels, 'CCTV-6', (id) => id,
    );
    expect(snapshot, ['CCTV-6', 'CCTV-1', 'CCTV-2']);
    expect(channels, ['CCTV-1', 'CCTV-2']);
    expect(ChannelListIdentity.indexOf(snapshot, 'CCTV-6', (id) => id), 0);
  });
  test('a newly discovered channel does not move the preview', () {
    final initial = ['CCTV-1', 'CCTV-5'];
    const selectedId = 'CCTV-5';
    expect(ChannelListIdentity.indexOf(initial, selectedId, (id) => id), 1);

    final rescanned = ['CCTV-1', 'CCTV-3', 'CCTV-5'];
    final previewIndex = ChannelListIdentity.indexOf(
      rescanned, selectedId, (id) => id,
    );
    expect(previewIndex, 2);
    expect(
      ChannelListIdentity.matches(selectedId, rescanned[previewIndex]),
      isTrue,
    );
    expect(ChannelListIdentity.matches(selectedId, rescanned[1]), isFalse);
  });

  test('a removed channel has no visible card to attach preview to', () {
    expect(
      ChannelListIdentity.indexOf(['CCTV-1'], 'CCTV-5', (id) => id),
      -1,
    );
    expect(ChannelListIdentity.indexOf(['CCTV-1'], null, (id) => id), -1);
  });
}
