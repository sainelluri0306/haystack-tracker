import 'package:flutter/material.dart';
import 'package:macless_haystack/item_management/new_item_action.dart';

class NoAccessoriesPlaceholder extends StatelessWidget {
  /// Displays a message that no accessories are present.
  ///
  /// Allows the user to quickly add a new accessory.
  const NoAccessoriesPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'There\'s Nothing Here Yet\nOn your phone, wait for the home laptop to publish a location.\nYou do not need to import the JSON file here.',
            style: TextStyle(
              fontSize: 20,
              color: Colors.grey,
            ),
            textAlign: TextAlign.center,
          ),
          NewKeyAction(mini: true),
        ],
      ),
    );
  }
}
