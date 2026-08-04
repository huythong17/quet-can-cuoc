import 'dart:typed_data';
void main() {
  var s = Uint8List(1);
  s[0] = 255;
  if (++s[0] != 0) {
    print('Not zero: ${s[0]}');
  } else {
    print('Zero: ${s[0]}');
  }
}
