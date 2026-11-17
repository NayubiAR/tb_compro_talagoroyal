import 'package:flutter/foundation.dart';

class PoDraftLine {
  PoDraftLine({this.sku = '', this.unitName, this.qty = 1});
  String sku;
  String? unitName;
  int qty;

  Map<String, dynamic> toJson() => {
        'sku': sku.trim(),
        if (unitName != null && unitName!.isNotEmpty) 'unitName': unitName,
        'qty': qty,
      };
}

/// Draf Purchase Order yang dibagi antara Katalog B2B, Quick PO, dan fitur "Pesan Ulang".
class PoDraft extends ChangeNotifier {
  final List<PoDraftLine> lines = [];

  void add(String sku, String unitName, int qty) {
    final existing = lines.where((l) => l.sku.toUpperCase() == sku.toUpperCase() && l.unitName == unitName);
    if (existing.isNotEmpty) {
      existing.first.qty += qty;
    } else {
      lines.add(PoDraftLine(sku: sku, unitName: unitName, qty: qty));
    }
    notifyListeners();
  }

  void replaceAll(Iterable<PoDraftLine> items) {
    lines
      ..clear()
      ..addAll(items);
    notifyListeners();
  }

  void clear() {
    lines.clear();
    notifyListeners();
  }

  void changed() => notifyListeners();

  int get count => lines.where((l) => l.sku.trim().isNotEmpty).length;
}
