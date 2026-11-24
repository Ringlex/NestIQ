import 'package:flutter/material.dart';

import '../state/session_controller.dart';
import 'login_screen.dart';

/// Logowanie do bramki Mobilus jako osobny krok po wejściu w profil.
/// Zamyka się samo, gdy połączenie się uda.
class GatewayConnectScreen extends StatefulWidget {
  const GatewayConnectScreen({super.key, required this.session});

  final SessionController session;

  @override
  State<GatewayConnectScreen> createState() => _GatewayConnectScreenState();
}

class _GatewayConnectScreenState extends State<GatewayConnectScreen> {
  @override
  void initState() {
    super.initState();
    widget.session.addListener(_closeWhenConnected);
  }

  @override
  void dispose() {
    widget.session.removeListener(_closeWhenConnected);
    super.dispose();
  }

  void _closeWhenConnected() {
    if (widget.session.phase == SessionPhase.connected && mounted) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bramka Mobilus')),
      body: ListenableBuilder(
        listenable: widget.session,
        builder: (context, _) => LoginScreen(controller: widget.session),
      ),
    );
  }
}
