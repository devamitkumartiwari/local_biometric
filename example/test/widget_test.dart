import 'package:flutter_test/flutter_test.dart';

import 'package:local_biometric_example/main.dart';

void main() {
  testWidgets('Home page shows the three demo sections', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const LocalBiometricExampleApp());

    expect(find.text('Local Biometric'), findsOneWidget);
    expect(find.text('Simple Authentication'), findsOneWidget);
    expect(find.text('Encrypted Authentication'), findsOneWidget);
    expect(find.text('Management'), findsOneWidget);
  });
}
