import 'package:flutter_test/flutter_test.dart';
import 'package:celeb_match/main.dart';

void main() {
  testWidgets('Smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const CelebMatchApp(cameras: []));

    // Verify that the app starts up and displays its loading text
    expect(find.text('CelebMatch AI'), findsOneWidget);
  });

  testWidgets('Can switch to photo upload mode', (WidgetTester tester) async {
    await tester.pumpWidget(const CelebMatchApp(cameras: []));
    await tester.tap(find.text('Upload Photo'));
    await tester.pump();

    expect(find.text('Choose a photo to scan'), findsOneWidget);
    expect(find.text('Run Scan'), findsOneWidget);
  });
}
