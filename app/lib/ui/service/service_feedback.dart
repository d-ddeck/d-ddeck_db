import 'package:flutter/material.dart';

import '../common/feedback.dart';

/// Compatibility wrapper: loads rethrow so AsyncView can offer retry.
Future<T> serviceLoad<T>(BuildContext context, Future<T> Function() load) =>
    guardedLoad(context, load);
