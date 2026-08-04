import 'dart:typed_data';
import 'package:pointycastle/export.dart';
void main() {
  var engine = CBCBlockCipher(DESedeEngine());
  var key = KeyParameter(Uint8List(24));
  engine.init(true, ParametersWithIV(key, Uint8List(8)));
  var data = Uint8List(16);
  for(int i=0; i<16; i++) data[i] = i;
  var out1 = Uint8List(16);
  for (int i = 0; i < data.length; i += 8) {
    int processed = engine.processBlock(data, i, out1, i);
    print('processed: $processed');
  }
  print(out1);
}
