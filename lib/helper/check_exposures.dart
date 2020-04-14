import 'dart:async';
import 'package:covidtrace/config.dart';
import 'package:covidtrace/exposure/beacon.dart';
import 'package:covidtrace/exposure/location.dart';
import 'package:covidtrace/helper/cloud_storage.dart';
import 'package:covidtrace/storage/beacon.dart';
import 'package:covidtrace/storage/location.dart';
import 'package:covidtrace/storage/user.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tuple/tuple.dart';

Future<bool> checkExposures() async {
  print('Checking exposures...');
  var threeWeeksAgo = DateTime.now().subtract(Duration(days: 21));
  var whereArgs = [threeWeeksAgo.toIso8601String()];

  var results = await Future.wait([
    UserModel.find(),
    getConfig(),
    getApplicationSupportDirectory(),
    LocationModel.findAll(
        where: 'DATE(timestamp) >= DATE(?)', whereArgs: whereArgs),
    BeaconModel.findAll(where: 'DATE(start) >= DATE(?)', whereArgs: whereArgs),
  ]);

  var user = results[0];
  var config = results[1];
  var dir = results[2];
  var locations = results[3];
  var beacons = results[4];

  String publishedBucket = config['publishedBucket'];
  int compareLevel = config['compareS2Level'];
  List<dynamic> aggLevels = config['aggS2Levels'];

  // Structures for exposures
  Map<int, LocationModel> exposedLocations = {};
  var locationExposure = new LocationExposure(locations, compareLevel);

  Map<int, BeaconModel> exposedBeacons = {};
  var beaconExposure = new BeaconExposure(beacons, compareLevel);

  // Set of all top level geo prefixes to begin querying
  var geoPrefixes = Set<String>.from(locations.map(
      (location) => location.cellID.parent(aggLevels.first as int).toToken()));

  // Build a queue of geos to fetch
  List<Tuple2<String, int>> geoPrefixQueue =
      geoPrefixes.map((prefix) => Tuple2(prefix, 0)).toList();

  // BFS through published bucket using `geoPrefixQueue`
  var objects = [];
  while (geoPrefixQueue.length > 0) {
    var prefix = geoPrefixQueue.removeAt(0);
    var geo = prefix.item1;
    var level = prefix.item2;

    var hint = await objectExists(publishedBucket, '$geo/0_HINT');
    if (hint && level + 1 < aggLevels.length) {
      geoPrefixQueue.addAll(Set.from(locations
              .where((location) =>
                  location.cellID.parent(aggLevels[level]).toToken() == geo)
              .map((location) =>
                  location.cellID.parent(aggLevels[level + 1]).toToken()))
          .map((geo) => Tuple2(geo, level + 1)));
    } else {
      objects.addAll(await getPrefixMatches(publishedBucket, '$geo/'));
    }
  }

  // Filter objects for any that are lexically equal to or greater than
  // the CSVs we last downloaded. If we have never checked before, we
  // should fetch everything for the last three weeks
  var lastCheck; // user.lastCheck;
  if (lastCheck == null) {
    lastCheck = threeWeeksAgo;
  }
  var lastCsv = '${(lastCheck.millisecondsSinceEpoch / 1000).floor()}.csv';

  await Future.wait(objects.where((object) {
    // Strip off geo prefix for lexical comparison
    var objectName = object['name'] as String;
    var objectNameParts = objectName.split('/');
    if (objectNameParts.length != 2) {
      return false;
    }

    // Perform lexical comparison. Object names look like: '$UNIX_TS.$TYPE.csv'
    // where $TYPE is one of `points` or `tokens`. We want to compare
    // '$UNIX_TS.csv' to `lastCsv`
    var fileName = objectNameParts[1];
    var fileNameParts = fileName.split('.');
    if (fileNameParts.length < 1) {
      return false;
    }
    var unixTs = fileNameParts[0];

    //  Lexical comparison
    return '$unixTs.csv'.compareTo(lastCsv) >= 0;
  }).map((object) async {
    var objectName = object['name'] as String;
    print('processing $objectName');

    // Sync file to local storage
    var file = await syncObject(
        dir.path, publishedBucket, objectName, object['md5Hash'] as String);

    // Find exposures and update!
    if (objectName.contains(".tokens.csv")) {
      var exposed =
          await beaconExposure.getExposures(await file.readAsString());
      exposed.forEach((e) => exposedBeacons[e.id] = e);
    } else {
      var exposed =
          await locationExposure.getExposures(await file.readAsString());
      exposed.forEach((e) => exposedLocations[e.id] = e);
    }
  }));

  user.lastCheck = DateTime.now();
  await user.save();

  if (exposedBeacons.isNotEmpty) {
    print('Found new beacon exposures!');
    var locations = await matchBeaconsAndLocations(exposedBeacons.values);
    exposedLocations.addAll(locations);
  }

  // Save all exposed beacons and locations
  await Future.wait([
    ...exposedBeacons.values.map((e) {
      e.exposure = true;
      return e.save();
    }),
    ...exposedLocations.values.map((e) {
      e.exposure = true;
      return e.save();
    })
  ]);

  if (exposedLocations.isNotEmpty) {
    print('Found new location exposures!');
    showExposureNotification(exposedLocations.values.last);
  }

  print('Done checking exposures!');
  return exposedBeacons.isNotEmpty || exposedLocations.isNotEmpty;
}

/// Takes a list of beacons and attempts to match them with a recored location within
/// the provided duration window. This method sets the `location` property on each
/// `BeaconModel` when a match is found. Additionally it returns the set of locations
/// that matched against any of the provided beacons.
///
/// The default `window` Duration is 10 minutes.
Future<Map<int, LocationModel>> matchBeaconsAndLocations(
    Iterable<BeaconModel> beacons,
    {Duration window}) async {
  window ??= Duration(minutes: 10);
  var start = beacons.first.start.subtract(window).toIso8601String();
  var end = beacons.last.end.add(window).toIso8601String();

  List<LocationModel> locations = await LocationModel.findAll(
      orderBy: 'id ASC',
      where:
          'DATETIME(timestamp) >= DATETIME(?) AND DATETIME(timestamp) <= DATETIME(?)',
      whereArgs: [start, end]);
  Map<int, LocationModel> locationMatches = {};

  /// For each Beacon do the following:
  /// - Find all the locations that fall within the duration window if the Beacon time range.
  /// - Associate the location closest to the midpoint of the Beacon time range to the Beacon.
  /// - Mark any matching locations as exposures.
  beacons.forEach((b) {
    var start = b.start.subtract(window);
    var end = b.end.add(window);
    var midpoint = b.start
        .add(Duration(milliseconds: end.difference(start).inMilliseconds ~/ 2));

    var matches = locations
        .where((l) => l.timestamp.isAfter(start) && l.timestamp.isBefore(end))
        .toList();

    matches.sort((a, b) {
      var aDiff = midpoint.difference(a.timestamp);
      var bDiff = midpoint.difference(b.timestamp);

      return aDiff.compareTo(bDiff);
    });

    if (matches.isNotEmpty) {
      b.location = matches.first;
      matches.forEach((l) => locationMatches[l.id] = l);
    }
  });

  return locationMatches;
}

void showExposureNotification(LocationModel location) async {
  var start = location.timestamp.toLocal();
  var end = start.add(Duration(hours: 1));

  var notificationPlugin = FlutterLocalNotificationsPlugin();
  var androidSpec = AndroidNotificationDetails(
      '1', 'COVID Trace', 'Exposure notifications',
      importance: Importance.Max, priority: Priority.High, ticker: 'ticker');
  var iosSpecs = IOSNotificationDetails();
  await notificationPlugin.show(
      0,
      'COVID-19 Exposure Alert',
      'Your location history matched with a reported infection on ${DateFormat.Md().format(start)} ${DateFormat('ha').format(start).toLowerCase()} - ${DateFormat('ha').format(end).toLowerCase()}',
      NotificationDetails(androidSpec, iosSpecs),
      payload: 'Default_Sound');
}
