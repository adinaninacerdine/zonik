import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../providers.dart';
import 'auth_controller.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _tenantController = TextEditingController(text: 'demo');
  final _matriculeController = TextEditingController();
  final _pinController = TextEditingController();
  bool _obscurePin = true;

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  /// Dernier agent de ce téléphone (session expirée, déconnexion) :
  /// il n'a plus qu'à saisir son PIN.
  Future<void> _prefill() async {
    final ({String? tenantSlug, String? matricule}) last;
    try {
      last = await ref.read(authRepositoryProvider).lastIdentity();
    } catch (_) {
      return; // stockage indisponible (tests) : champs laissés tels quels
    }
    if (!mounted) return;
    if (last.tenantSlug != null && last.tenantSlug!.isNotEmpty) {
      _tenantController.text = last.tenantSlug!;
    }
    if (last.matricule != null &&
        last.matricule!.isNotEmpty &&
        _matriculeController.text.isEmpty) {
      _matriculeController.text = last.matricule!;
    }
  }

  @override
  void dispose() {
    _tenantController.dispose();
    _matriculeController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    await ref.read(authControllerProvider.notifier).login(
          tenantSlug: _tenantController.text,
          matricule: _matriculeController.text,
          pin: _pinController.text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final isLoading = auth.isLoading;
    final error = auth.hasError ? auth.error : null;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.fingerprint, size: 72, color: Colors.teal),
                  const SizedBox(height: 8),
                  Text(
                    'Zonik',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  Text(
                    'Pointage géolocalisé',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: _tenantController,
                    decoration: const InputDecoration(
                      labelText: 'Entreprise (slug)',
                      prefixIcon: Icon(Icons.business),
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.next,
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Requis' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _matriculeController,
                    decoration: const InputDecoration(
                      labelText: 'Matricule',
                      prefixIcon: Icon(Icons.badge),
                      border: OutlineInputBorder(),
                    ),
                    textCapitalization: TextCapitalization.characters,
                    textInputAction: TextInputAction.next,
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Requis' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _pinController,
                    decoration: InputDecoration(
                      labelText: 'Code PIN',
                      prefixIcon: const Icon(Icons.lock),
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(_obscurePin
                            ? Icons.visibility
                            : Icons.visibility_off),
                        onPressed: () =>
                            setState(() => _obscurePin = !_obscurePin),
                      ),
                    ),
                    obscureText: _obscurePin,
                    keyboardType: TextInputType.number,
                    onFieldSubmitted: (_) => _submit(),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Requis' : null,
                  ),
                  const SizedBox(height: 24),
                  if (error != null) ...[
                    Text(
                      error is ApiException && error.isNetwork
                          ? '${error.message}\nLa connexion demande du réseau '
                              'une fois ; ensuite le pointage marche sans.'
                          : error.toString(),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error),
                    ),
                    const SizedBox(height: 16),
                  ],
                  FilledButton(
                    onPressed: isLoading ? null : _submit,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: isLoading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Se connecter'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
