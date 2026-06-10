import 'package:core/core.dart';
import 'dart:developer' as developer;

void main() {
  var awesome = Awesome();
  developer.log('awesome: ${awesome.isAwesome}', name: 'my.app.category');
}
