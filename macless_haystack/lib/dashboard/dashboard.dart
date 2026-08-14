import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:macless_haystack/item_management/refresh_action.dart';
import 'package:provider/provider.dart';
import 'package:macless_haystack/accessory/accessory_registry.dart';
import 'package:macless_haystack/dashboard/accessory_map_list_vert.dart';
import 'package:macless_haystack/item_management/item_management.dart';
import 'package:macless_haystack/item_management/new_item_action.dart';
import 'package:macless_haystack/location/location_model.dart';
import 'package:macless_haystack/preferences/preferences_page.dart';
import 'package:macless_haystack/preferences/user_preferences_model.dart';

import '../accessory/accessory_model.dart';

class Dashboard extends StatefulWidget {
  /// Displays the layout for the mobile view of the app.
  ///
  /// The layout is optimized for a vertically aligned small screens.
  /// The functionality is structured in a bottom tab bar for easy access
  /// on mobile devices.
  const Dashboard({super.key});

  @override
  State<StatefulWidget> createState() {
    return _DashboardState();
  }
}

class _DashboardState extends State<Dashboard> {
  bool _lostMode = false;
  Timer? _lostTimer;

  /// A list of the tabs displayed in the bottom tab bar.
  late final List<Map<String, dynamic>> _tabs = [
    {
      'title': 'My Trackers',
      'body': (ctx) => AccessoryMapListVertical(
            loadLocationUpdates: loadLocationUpdates,
            saveOrderUpdatesCallback: saveAccessories,
          ),
      'icon': Icons.place,
      'label': 'Map',
      'actionButton': (ctx) => RefreshAction(
            callback: () async {
              await loadLocationUpdates(null);
            },
          ),
    },
    {
      'title': 'My Trackers',
      'body': (ctx) => const KeyManagement(),
      'icon': Icons.style,
      'label': 'Trackers',
      'actionButton': (ctx) => const NewKeyAction(),
    },
  ];

  @override
  void initState() {
    super.initState();

    // Initialize models and preferences
    var userPreferences = Provider.of<UserPreferences>(context, listen: false);
    var locationModel = Provider.of<LocationModel>(context, listen: false);
    var locationPreferenceKnown =
        userPreferences.locationPreferenceKnown ?? false;
    var locationAccessWanted = userPreferences.locationAccessWanted ?? false;
    if (!locationPreferenceKnown || locationAccessWanted) {
      locationModel.requestLocationUpdates();
    }
    // Always look for a published report when the site is opened or reloaded.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      loadLocationUpdates(null);
    });
  }

  @override
  void dispose() {
    _lostTimer?.cancel();
    super.dispose();
  }

  var logger = Logger(
    printer: PrettyPrinter(),
  );

  Future<void> _setLostMode(bool enabled) async {
    try {
      await http.post(
        Uri.parse('${Uri.base.origin}/api/lost'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'lost': enabled}),
      );
    } catch (e) {
      logger.i('Could not signal lost mode to the home laptop.', error: e);
    }
  }

  void _toggleLostMode() {
    setState(() {
      _lostMode = !_lostMode;
    });
    _lostTimer?.cancel();
    _setLostMode(_lostMode);
    if (_lostMode) {
      _lostTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        loadLocationUpdates(null, silent: true);
      });
      loadLocationUpdates(null);
    }
  }

  void _showPingPlaceholder() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Ping will control the ESP32 later. Nothing is sent from the browser yet.',
        ),
      ),
    );
  }

  Widget _trackerActionBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.tonalIcon(
            onPressed: () => loadLocationUpdates(null),
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh'),
          ),
          FilledButton.tonalIcon(
            onPressed: _toggleLostMode,
            icon:
                Icon(_lostMode ? Icons.my_location : Icons.location_searching),
            label: Text(_lostMode ? 'Lost: 1 min' : 'Lost'),
            style: _lostMode
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  )
                : null,
          ),
          FilledButton.tonalIcon(
            onPressed: _showPingPlaceholder,
            icon: const Icon(Icons.volume_up_outlined),
            label: const Text('Ping'),
          ),
        ],
      ),
    );
  }

  /// Fetch location updates for all accessories.
  Future<void> loadLocationUpdates(Accessory? accessory,
      {bool silent = false}) async {
    var accessoryRegistry =
        Provider.of<AccessoryRegistry>(context, listen: false);
    try {
      final publishedCount = await accessoryRegistry.loadPublishedLocations();
      if (mounted && !silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Theme.of(context).colorScheme.primary,
            content: Text(
              publishedCount > 0
                  ? 'Updated $publishedCount tracker location(s) from the home laptop.'
                  : 'No location report has been published yet.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimary,
              ),
            ),
          ),
        );
      }
      return;
    } catch (e) {
      logger.i('Published locations unavailable, using local key import.',
          error: e);
    }
    var inactive = 0;
    Iterable<Accessory> accessories;
    if (accessory == null) {
      accessories = accessoryRegistry.accessories;
      inactive = accessories.where((a) => !a.isActive).length;
    } else {
      accessories = [accessory];
    }
    try {
      var count = await accessoryRegistry
          .loadLocationReports(accessories.where((a) => a.isActive));
      if (mounted && accessories.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Theme.of(context).colorScheme.primary,
            content: Text(
              'Fetched $count location(s).${inactive > 0 ? '$inactive inactive accessories skipped' : ''}',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimary,
              ),
            ),
          ),
        );
      }
    } catch (e, stacktrace) {
      logger.e('Error on fetching', error: e, stackTrace: stacktrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Theme.of(context).colorScheme.error,
            content: Text(
              'Could not find location reports. Try again later. Error: ${e.toString()}',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onError,
              ),
            ),
          ),
        );
      }
    }
  }

  /// The selected tab index.
  int _selectedIndex = 0;

  /// Updates the currently displayed tab to [index].
  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          title: const Text('My Trackers'),
          actions: <Widget>[
            IconButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) => const PreferencesPage()),
                );
              },
              icon: const Icon(Icons.settings),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_selectedIndex == 0) _trackerActionBar(),
            Expanded(child: _tabs[_selectedIndex]['body'](context)),
          ],
        ),
        bottomNavigationBar: BottomNavigationBar(
          items: _tabs
              .map((tab) => BottomNavigationBarItem(
                    icon: Icon(tab['icon']),
                    label: tab['label'],
                  ))
              .toList(),
          currentIndex: _selectedIndex,
          unselectedItemColor: Theme.of(context).secondaryHeaderColor,
          onTap: _onItemTapped,
        ),
        floatingActionButton:
            _tabs[_selectedIndex]['actionButton']?.call(context),
        floatingActionButtonLocation: FloatingActionButtonLocation.endDocked);
  }

  Future<void> saveAccessories(List<Accessory> accessories) async {
    var accessoryRegistry =
        Provider.of<AccessoryRegistry>(context, listen: false);
    accessoryRegistry.saveOrderUpdates(accessories);
  }
}
