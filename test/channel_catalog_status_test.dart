import 'package:clubtivi/features/channels/channel_catalog_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('category loading never displays global transfer counts', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChannelCatalogStatus(
      category: '台湾', loading: true, onRetry: () {}))));
    expect(find.text('正在载入台湾频道…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining('4327'), findsNothing);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChannelCatalogStatus(
      category: '台湾', loading: false, onRetry: () {}))));
    expect(find.text('台湾暂时没有可显示的频道'), findsOneWidget);
    expect(find.text('重新读取分类'), findsOneWidget);
  });
}
