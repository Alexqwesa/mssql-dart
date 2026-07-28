import 'package:mssql/src/tds/buf.dart';

void main() {
  final sizes = <int>[];
  for (var s = 30; s < 400; s++) {
    try {
      TdsBuffer.buildTlsAlignNopPacket(totalSize: s);
      sizes.add(s);
    } catch (_) {}
  }
  print('buildable sizes (${sizes.length}):');
  print(sizes.take(80).toList());
  print('...');
  print('119 in set: ${sizes.contains(119)}');
  print('odd buildable: ${sizes.where((s) => s.isOdd).take(40).toList()}');
}
