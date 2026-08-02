import 'package:flutter_test/flutter_test.dart';
import 'package:celeb_match/main.dart';

void main() {
  testWidgets('Smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const CelebMatchApp(cameras: []));
    
    // Verify that the app starts up and displays its loading text
    expect(find.text('CelebMatch AI'), findsOneWidget);
  });
}
