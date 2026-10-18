
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:offline_vlm/main.dart';

void main() {
  testWidgets('VisionApp is a Flutter application', (tester) async {
    // Check that our application widget can be constructed.
    const app = VisionApp();

    expect(app, isA<StatelessWidget>());
  });
}
