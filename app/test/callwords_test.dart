import 'package:flutter_test/flutter_test.dart';
import 'package:tilda_app/callwords.dart';
import 'package:tilda_app/personal_style.dart';

void main() {
  final s = PersonalStyle();

  test('call-words and Tilda are stripped from the start', () {
    expect(CallWords.strip('Ae Tilda, capture this', s), 'capture this');
    expect(CallWords.strip('hey tilda what is the weather', s), 'what is the weather');
    expect(CallWords.strip('Suno Telda I have a complaint', s), 'I have a complaint');
    expect(CallWords.strip('Oye टिल्डा कैमरा खोलो', s), 'कैमरा खोलो');
    expect(CallWords.strip('ए तिल्दा मौसम कैसा है', s), 'मौसम कैसा है');
    expect(CallWords.strip('Arre Tilde read this', s), 'read this');
  });

  test('ordinary sentences are left alone', () {
    expect(CallWords.strip('what time is it', s), 'what time is it');
    expect(CallWords.strip('Tilda', s), 'Tilda');
    expect(CallWords.called('okay now what', s), false);
    expect(CallWords.called('Hey Tilda', s), true);
  });

  test('practice learns how the engine wrote the call', () {
    final t = PersonalStyle();
    expect(CallWords.learn('Suno Telda.', t), true);
    expect(CallWords.learn('good morning everyone', t), false);
    expect(t.callHeard.contains('suno telda'), true);
    expect(CallWords.strip('Suno Telda open the camera', t), 'open the camera');
  });
}
