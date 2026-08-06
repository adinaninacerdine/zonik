import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/attendance/home_screen.dart';
import 'features/auth/auth_controller.dart';
import 'features/auth/login_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  runApp(const ProviderScope(child: ZonikApp()));
}

class ZonikApp extends StatelessWidget {
  const ZonikApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Zonik',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const _Root(),
    );
  }
}

class _Root extends ConsumerWidget {
  const _Root();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    return auth.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      // Erreur de lecture de session -> retour au login.
      error: (_, _) => const LoginScreen(),
      data: (session) =>
          session == null ? const LoginScreen() : const HomeScreen(),
    );
  }
}
