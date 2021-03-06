import 'package:app_settings/app_settings.dart';
import 'package:covidtrace/config.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:gact_plugin/gact_plugin.dart';
import 'package:url_launcher/url_launcher.dart';

import 'storage/user.dart';

class BlockButton extends StatelessWidget {
  final onPressed;
  final String label;

  BlockButton({this.onPressed, this.label});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
          child: RaisedButton(
              child: Text(label, style: TextStyle(fontSize: 20)),
              onPressed: onPressed,
              textColor: Colors.white,
              color: Theme.of(context).buttonTheme.colorScheme.primary,
              shape: StadiumBorder(),
              padding: EdgeInsets.all(15)))
    ]);
  }
}

class Onboarding extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => OnboardingState();
}

class OnboardingState extends State {
  var _pageController = PageController();
  var _requestExposure = false;
  var _requestNotification = false;
  var _linkToSettings = false;

  void nextPage() => _pageController.nextPage(
      duration: Duration(milliseconds: 250), curve: Curves.easeOut);

  void requestPermission(bool selected) async {
    if (_linkToSettings) {
      AppSettings.openAppSettings();
      return;
    }

    AuthorizationStatus status;
    try {
      status = await GactPlugin.authorizationStatus;
      print('enable exposure notification $status');

      if (status != AuthorizationStatus.Authorized) {
        status = await GactPlugin.enableExposureNotification();
      }

      if (status != AuthorizationStatus.Authorized) {
        setState(() => _linkToSettings = true);
      }
    } catch (err) {
      print(err);
      if (errorFromException(err) == ErrorCode.notAuthorized) {
        setState(() => _linkToSettings = true);
      }
    }

    setState(() => _requestExposure = status == AuthorizationStatus.Authorized);
  }

  void requestNotifications(bool selected) async {
    var plugin = FlutterLocalNotificationsPlugin();
    bool allowed = await plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        .requestPermissions(alert: true, sound: true);

    setState(() => _requestNotification = allowed);
    var user = await UserModel.find();
    await user.save();
  }

  void finish() async {
    var user = await UserModel.find();
    user.onboarding = false;
    await user.save();

    Navigator.of(context).pushReplacementNamed('/home');
  }

  @override
  Widget build(BuildContext context) {
    var config = Config.get()['onboarding'];
    var bodyText = Theme.of(context)
        .textTheme
        .bodyText2
        .merge(TextStyle(fontSize: 16, height: 1.4));

    var platform = Theme.of(context).platform;
    var brightness = MediaQuery.platformBrightnessOf(context);

    return AnnotatedRegion(
      value: brightness == Brightness.light
          ? SystemUiOverlayStyle.dark
          : SystemUiOverlayStyle.light,
      child: Container(
        color: Colors.white,
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.only(top: 30, left: 30, right: 30),
            child: PageView(
                controller: _pageController,
                physics: NeverScrollableScrollPhysics(),
                children: [
                  Center(
                      child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Row(children: [
                          Expanded(
                              child: Text(
                            config['intro']['title'],
                            style: Theme.of(context).textTheme.headline5,
                          )),
                          ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Container(
                                child: Image.asset(
                                  config['intro']['icon'],
                                  height: 40,
                                  fit: BoxFit.contain,
                                ),
                              )),
                        ]),
                        SizedBox(height: 10),
                        Text(
                          config['intro']['body'],
                          style: bodyText,
                        ),
                        SizedBox(height: 30),
                        BlockButton(
                            onPressed: nextPage, label: config['intro']['cta']),
                      ])),
                  Center(
                      child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Row(children: [
                          Expanded(
                              child: Text(
                                  config['exposure_notification']['title'],
                                  style:
                                      Theme.of(context).textTheme.headline5)),
                          Container(
                            child: Image.asset(
                                config['exposure_notification']['icon'],
                                color: Colors.black38,
                                height: 40,
                                fit: BoxFit.contain),
                          ),
                        ]),
                        SizedBox(height: 10),
                        RichText(
                          text: TextSpan(style: bodyText, children: [
                            TextSpan(
                              text: config['exposure_notification']['body'],
                            ),
                            TextSpan(
                                text: config['exposure_notification']
                                    ['link_title'],
                                style: TextStyle(
                                    decoration: TextDecoration.underline),
                                recognizer: TapGestureRecognizer()
                                  ..onTap = () {
                                    try {
                                      launch(config['exposure_notification']
                                          ['link']);
                                    } catch (err) {}
                                  })
                          ]),
                        ),
                        SizedBox(height: 30),
                        Center(
                            child: Transform.scale(
                                scale: 1.5,
                                child: Material(
                                    color: Colors.white,
                                    child: Switch.adaptive(
                                        value: _requestExposure,
                                        onChanged: requestPermission)))),
                        SizedBox(height: 30),
                        BlockButton(
                            label: config['exposure_notification']['cta'],
                            onPressed: _requestExposure ? nextPage : null)
                      ])),
                  Center(
                      child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(
                          config['notification_permission']['title'],
                          style: Theme.of(context).textTheme.headline5,
                        ),
                        SizedBox(height: 10),
                        Text(
                          config['notification_permission']['body'],
                          style: bodyText,
                        ),
                        SizedBox(height: 20),
                        Image.asset(platform == TargetPlatform.iOS
                            ? config['notification_permission']['preview_ios']
                            : config['notification_permission']
                                ['preview_android']),
                        SizedBox(height: 20),
                        platform == TargetPlatform.iOS
                            ? Material(
                                color: Colors.white,
                                child: InkWell(
                                    onTap: () =>
                                        requestNotifications(!_requestExposure),
                                    child: Row(children: [
                                      Expanded(
                                          child: Text('Enable notifications',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .headline6)),
                                      Switch.adaptive(
                                          value: _requestNotification,
                                          onChanged: requestNotifications),
                                    ])))
                            : Container(),
                        SizedBox(height: 30),
                        BlockButton(
                            onPressed: finish,
                            label: config['notification_permission']['cta']),
                      ])),
                ]),
          ),
        ),
      ),
    );
  }
}
