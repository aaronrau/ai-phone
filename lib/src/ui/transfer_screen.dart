import 'dart:async';

import 'package:flutter/material.dart';

import '../runtime.dart';
import 'common.dart';

/// Warm transfer: a known contact is on the line with the assistant and is
/// waiting for the owner. Shows who it is and what they want, with a countdown.
class TransferScreen extends StatefulWidget {
  const TransferScreen({super.key, required this.runtime, required this.request});
  final ReceptionistRuntime runtime;
  final TransferRequest request;

  @override
  State<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends State<TransferScreen> {
  late final Timer _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final request = widget.request;
    final left = request.waitSeconds - DateTime.now().difference(request.started).inSeconds;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              Text(displayName(request.name), style: text.headlineMedium),
              const SizedBox(height: 4),
              Muted(request.topic == null
                  ? 'is on the line with your assistant and asked for you'
                  : 'is on the line with your assistant · About: ${request.topic}'),
              const SizedBox(height: 16),
              if (request.said.isNotEmpty) Text('"${request.said}"', style: text.titleMedium),
              const Spacer(),
              Muted(left > 0 ? 'The assistant will take a message in $left s' : 'Taking a message…'),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                      onPressed: widget.runtime.declineTransfer,
                      child: const Text('Not now'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                      onPressed: widget.runtime.acceptTransfer,
                      icon: const Icon(Icons.call),
                      label: const Text('Pick up'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
