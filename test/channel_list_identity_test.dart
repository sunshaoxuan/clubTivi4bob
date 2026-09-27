import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/features/channels/channel_list_identity.dart';

void main() {
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
