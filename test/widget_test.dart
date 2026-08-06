import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zonik/features/auth/auth_controller.dart';
import 'package:zonik/features/auth/auth_repository.dart';
import 'package:zonik/features/auth/login_screen.dart';

/// Auth factice : pas de session, sans toucher au secure storage natif.
class _FakeAuthController extends AuthController {
  @override
  Future<Session?> build() async => null;
}

void main() {
  testWidgets('l\'écran de connexion affiche les champs attendus',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith(_FakeAuthController.new),
        ],
        child: const MaterialApp(home: LoginScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('Entreprise (slug)'), findsOneWidget);
    expect(find.text('Matricule'), findsOneWidget);
    expect(find.text('Code PIN'), findsOneWidget);
    expect(find.text('Se connecter'), findsOneWidget);
  });
}
