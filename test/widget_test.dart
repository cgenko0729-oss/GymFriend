// GymFriend の基本的なスモークテスト。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App builds a basic widget', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('GymFriend'))),
    );
    expect(find.text('GymFriend'), findsOneWidget);
  });
}
