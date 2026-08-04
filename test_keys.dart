import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

int _adjParity(int b) {
  b &= 0xFE;
  int p = 0;
  for (int i = 0; i < 8; i++) { if ((b & (1 << i)) != 0) p++; }
  return (p % 2 == 0) ? b | 1 : b;
}
Uint8List _deriveKey(Uint8List seed, int c) {
  var inp = Uint8List(20);
  inp.setRange(0, 16, seed);
  inp[19] = c;
  var h = sha1.convert(inp).bytes;
  return Uint8List.fromList(h.sublist(0, 16).map(_adjParity).toList());
}
void main() {
  String mrzKey = '089086019586020642602062';
  var h = sha1.convert(utf8.encode(mrzKey)).bytes;
  Uint8List kseed = Uint8List.fromList(h.sublist(0, 16));
  Uint8List kenc = _deriveKey(kseed, 1);
  Uint8List kmac = _deriveKey(kseed, 2);
  
  print('MRZ: $mrzKey');
  print('SHA1: ${h.map((e)=>e.toRadixString(16).padLeft(2,'0')).join()}');
  print('Kseed: ${kseed.map((e)=>e.toRadixString(16).padLeft(2,'0')).join()}');
  print('Kenc: ${kenc.map((e)=>e.toRadixString(16).padLeft(2,'0')).join()}');
  print('Kmac: ${kmac.map((e)=>e.toRadixString(16).padLeft(2,'0')).join()}');
}
