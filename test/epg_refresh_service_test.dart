import 'package:clubtivi/data/services/epg_refresh_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hotel TV Chinese EPG source is stable and compressed', () {
    expect(EpgRefreshService.chinaSourceId, 'hotel-cn-epg');
    expect(EpgRefreshService.chinaSourceName, '中国电视节目表');
    expect(EpgRefreshService.chinaSourceUrl, startsWith('https://'));
    expect(EpgRefreshService.chinaSourceUrl, endsWith('.xml.gz'));
    expect(EpgRefreshService.extendedChinaSourceId, 'hotel-cn-epg-extended');
    expect(EpgRefreshService.extendedChinaSourceName, '中国扩展节目表');
    expect(EpgRefreshService.extendedChinaSourceUrl, startsWith('https://'));
    expect(EpgRefreshService.extendedChinaSourceUrl, endsWith('.xml'));
  });
}
