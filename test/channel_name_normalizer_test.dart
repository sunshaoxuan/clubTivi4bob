import 'package:clubtivi/data/services/channel_name_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChannelNameNormalizer', () {
    test('keeps Chinese channel names distinct', () {
      expect(ChannelNameNormalizer.normalize('湖南卫视'), '湖南卫视');
      expect(ChannelNameNormalizer.normalize('湖北卫视'), '湖北卫视');
    });

    test('removes quality and provider route labels', () {
      expect(ChannelNameNormalizer.normalize('电信线路1 湖南卫视 超高清 HEVC'), '湖南卫视');
      expect(ChannelNameNormalizer.normalize('湖南卫视 [IPv6] 备用源2'), '湖南卫视');
    });

    test('maps CCTV number and Chinese aliases', () {
      expect(ChannelNameNormalizer.normalize('CCTV-13 新闻 HD'), 'cctv13');
      expect(ChannelNameNormalizer.normalize('央视新闻 高清'), 'cctv13');
      expect(ChannelNameNormalizer.normalize('中央电视台十三套'), 'cctv13');
    });

    test('keeps CCTV5 Plus separate from CCTV5', () {
      expect(ChannelNameNormalizer.normalize('CCTV5 体育'), 'cctv5');
      expect(ChannelNameNormalizer.normalize('CCTV5+ 体育赛事'), 'cctv5plus');
    });

    test('keeps CCTV4 regional variants separate', () {
      expect(ChannelNameNormalizer.normalize('CCTV4 欧洲'), 'cctv4欧洲');
      expect(ChannelNameNormalizer.normalize('CCTV4 美洲'), 'cctv4美洲');
    });

    test('normalizes full width ASCII', () {
      expect(ChannelNameNormalizer.normalize('ＣＣＴＶ１ 综合'), 'cctv1');
    });

    test('preserves Chinese EPG channel names', () {
      expect(ChannelNameNormalizer.normalize('劲爆体育高清'), '劲爆体育');
      expect(ChannelNameNormalizer.normalize('魅力足球 HD'), '魅力足球');
      expect(ChannelNameNormalizer.normalize('咪咕赛事播01'), '咪咕赛事播01');
    });
  });
}
