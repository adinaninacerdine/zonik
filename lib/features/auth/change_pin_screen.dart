import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';

/// Écran obligatoire à la première connexion : l'agent remplace le PIN
/// d'amorçage remis par son superviseur par un PIN qu'il est seul à connaître.
class ChangePinScreen extends ConsumerStatefulWidget {
  const ChangePinScreen({super.key});

  @override
  ConsumerState<ChangePinScreen> createState() => _ChangePinScreenState();
}

class _ChangePinScreenState extends ConsumerState<ChangePinScreen> {
  final _formKey = GlobalKey<FormState>();
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  String? _validatePin(String? v) {
    if (v == null || v.isEmpty) return 'Requis';
    if (!RegExp(r'^\d{4,6}$').hasMatch(v)) return '4 à 6 chiffres';
    return null;
  }

  Future<void> _submit() async {
    setState(() => _error = null);
    if (!_formKey.currentState!.validate()) return;
    if (_newController.text != _confirmController.text) {
      setState(() => _error = 'Les deux PIN ne correspondent pas.');
      return;
    }
    FocusScope.of(context).unfocus();
    await ref.read(authControllerProvider.notifier).changePin(
          currentPin: _currentController.text,
          newPin: _newController.text,
        );
    final auth = ref.read(authControllerProvider);
    if (auth.hasError && mounted) {
      setState(() => _error = auth.error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final session = auth.value;
    final isLoading = auth.isLoading;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Choisissez votre PIN'),
        actions: [
          IconButton(
            tooltip: 'Se déconnecter',
            icon: const Icon(Icons.logout),
            onPressed: () =>
                ref.read(authControllerProvider.notifier).logout(),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.lock_reset, size: 64, color: Colors.teal),
                const SizedBox(height: 12),
                Text(
                  session?.fullName.isNotEmpty == true
                      ? 'Bonjour ${session!.fullName}'
                      : 'Première connexion',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  'Le PIN que vous avez reçu sert uniquement à la première '
                  'connexion. Choisissez maintenant un PIN personnel : il '
                  'prouve que c\'est bien vous qui pointez.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 28),
                _PinField(
                  controller: _currentController,
                  label: 'PIN reçu',
                  validator: _validatePin,
                ),
                const SizedBox(height: 16),
                _PinField(
                  controller: _newController,
                  label: 'Nouveau PIN (4 à 6 chiffres)',
                  validator: _validatePin,
                ),
                const SizedBox(height: 16),
                _PinField(
                  controller: _confirmController,
                  label: 'Confirmez le nouveau PIN',
                  validator: _validatePin,
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 24),
                if (_error != null) ...[
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
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
                      : const Text('Enregistrer mon PIN'),
                ),
                const SizedBox(height: 12),
                Text(
                  'Évitez les suites simples (1234, 0000). Ne communiquez '
                  'votre PIN à personne, pas même à votre superviseur.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PinField extends StatefulWidget {
  const _PinField({
    required this.controller,
    required this.label,
    required this.validator,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final String? Function(String?) validator;
  final ValueChanged<String>? onSubmitted;

  @override
  State<_PinField> createState() => _PinFieldState();
}

class _PinFieldState extends State<_PinField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      decoration: InputDecoration(
        labelText: widget.label,
        prefixIcon: const Icon(Icons.pin),
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
          onPressed: () => setState(() => _obscure = !_obscure),
        ),
      ),
      obscureText: _obscure,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(6),
      ],
      textInputAction: widget.onSubmitted == null
          ? TextInputAction.next
          : TextInputAction.done,
      onFieldSubmitted: widget.onSubmitted,
      validator: widget.validator,
    );
  }
}
