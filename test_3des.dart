import 'dart:typed_data';
import 'package:pointycastle/export.dart';

void main() {
  var k16 = Uint8List.fromList(List.generate(16, (i) => i));
  var data = Uint8List.fromList(List.generate(8, (i) => i));
  
  // Method 1: DESedeEngine with 24-byte key
  var k24 = Uint8List(24);
  k24.setRange(0, 16, k16);
  k24.setRange(16, 24, k16.sublist(0, 8));
  var e1 = DESedeEngine();
  e1.init(true, KeyParameter(k24));
  var out1 = Uint8List(8);
  e1.processBlock(data, 0, out1, 0);
  
  // Method 2: Manual DES Encrypt(K1) -> Decrypt(K2) -> Encrypt(K1)
  var d1 = DESEngine(); d1.init(true, KeyParameter(k16.sublist(0, 8)));
  var d2 = DESEngine(); d2.init(false, KeyParameter(k16.sublist(8, 16)));
  var d3 = DESEngine(); d3.init(true, KeyParameter(k16.sublist(0, 8)));
  
  var t1 = Uint8List(8); d1.processBlock(data, 0, t1, 0);
  var t2 = Uint8List(8); d2.processBlock(t1, 0, t2, 0);
  var out2 = Uint8List(8); d3.processBlock(t2, 0, out2, 0);
  
  print('Out1: ${out1.map((e)=>e.toRadixString(16).padLeft(2,'0')).join()}');
  print('Out2: ${out2.map((e)=>e.toRadixString(16).padLeft(2,'0')).join()}');
}
