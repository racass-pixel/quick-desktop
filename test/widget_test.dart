// Basic smoke test — mounts the root with a ProviderScope and asserts it builds.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quick_desktop/main.dart';

void main() {
  testWidgets('Root builds', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: QuickApp()));
    // Pump a frame so async bootstrap can fire (though it will likely fail
    // outside of a desktop binding — that's fine for this smoke check).
    await tester.pump();
    expect(find.byType(MaterialApp), findsWidgets);
  });
}
