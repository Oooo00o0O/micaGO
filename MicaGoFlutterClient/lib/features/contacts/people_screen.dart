import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'contacts_service.dart';
import '../../core/l10n/app_localizations.dart';

/// People tab: minimal control surface for read-only local contacts matching.
/// Not an address book — it manages the opt-in and shows matching status.
class PeopleScreen extends StatelessWidget {
  const PeopleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final contacts = context.watch<ContactsService>();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.contacts_outlined),
                    const SizedBox(width: 8),
                    Text(
                      MicaLocalizations.of(context).t('contacts.matching'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    _StatusChip(status: contacts.status),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  MicaLocalizations.of(context).t('contacts.matchingBody'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                _Action(contacts: contacts),
              ],
            ),
          ),
        ),
        if (contacts.status == ContactsStatus.ready) ...[
          const SizedBox(height: 12),
          Text(
            MicaLocalizations.of(context)
                .t('contacts.available')
                .replaceAll('{n}', '${contacts.contacts.length}'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (contacts.error != null) ...[
          const SizedBox(height: 12),
          Text(
            contacts.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }
}

class _Action extends StatelessWidget {
  final ContactsService contacts;
  const _Action({required this.contacts});

  @override
  Widget build(BuildContext context) {
    switch (contacts.status) {
      case ContactsStatus.requesting:
        return const Center(child: CircularProgressIndicator());
      case ContactsStatus.ready:
        return OutlinedButton.icon(
          onPressed: contacts.disable,
          icon: const Icon(Icons.link_off),
          label: Text(MicaLocalizations.of(context).t('contacts.turnOff')),
        );
      case ContactsStatus.denied:
        return Row(
          children: [
            FilledButton.icon(
              onPressed: contacts.enable,
              icon: const Icon(Icons.refresh),
              label: Text(MicaLocalizations.of(context).t('common.tryAgain')),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: contacts.openSettings,
              child: Text(
                MicaLocalizations.of(context).t('common.openSettings'),
              ),
            ),
          ],
        );
      case ContactsStatus.disabled:
        return FilledButton.icon(
          onPressed: contacts.enable,
          icon: const Icon(Icons.contacts),
          label: Text(MicaLocalizations.of(context).t('contacts.turnOn')),
        );
    }
  }
}

class _StatusChip extends StatelessWidget {
  final ContactsStatus status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final (String label, Color color) = switch (status) {
      ContactsStatus.ready => (
        MicaLocalizations.of(context).t('contacts.statusOn'),
        Colors.green,
      ),
      ContactsStatus.requesting => (
        MicaLocalizations.of(context).t('contacts.statusRequesting'),
        Theme.of(context).colorScheme.tertiary,
      ),
      ContactsStatus.denied => (
        MicaLocalizations.of(context).t('contacts.statusDenied'),
        Theme.of(context).colorScheme.error,
      ),
      ContactsStatus.disabled => (
        MicaLocalizations.of(context).t('contacts.statusOff'),
        Theme.of(context).colorScheme.outline,
      ),
    };
    return Chip(
      label: Text(label),
      visualDensity: VisualDensity.compact,
      side: BorderSide(color: color),
    );
  }
}
