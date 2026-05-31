import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Handles the one-time "Remove ads" purchase and exposes the Pro entitlement.
/// The entitlement is cached in prefs so paying users never see an ad flash,
/// and re-verified against the store on launch (restore).
class BillingService extends ChangeNotifier {
  static const removeAdsId = 'remove_ads';

  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  ProductDetails? _product;
  bool _available = false;
  bool _pro = false;

  bool get isPro => _pro;
  bool get storeAvailable => _available;
  String get price => _product?.price ?? r'$1.99';
  bool get canBuy => _available && _product != null && !_pro;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _pro = prefs.getBool('pro') ?? false;
    notifyListeners();

    _available = await _iap.isAvailable();
    if (!_available) return;

    _sub = _iap.purchaseStream.listen(_onPurchaseUpdates, onError: (_) {});

    final resp = await _iap.queryProductDetails({removeAdsId});
    if (resp.productDetails.isNotEmpty) {
      _product = resp.productDetails.first;
    }
    notifyListeners();

    await _iap.restorePurchases();
  }

  Future<void> buyRemoveAds() async {
    final p = _product;
    if (p == null) return;
    await _iap.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: p));
  }

  Future<void> restore() => _iap.restorePurchases();

  Future<void> _onPurchaseUpdates(List<PurchaseDetails> purchases) async {
    for (final pd in purchases) {
      if (pd.productID == removeAdsId &&
          (pd.status == PurchaseStatus.purchased ||
              pd.status == PurchaseStatus.restored)) {
        await _setPro(true);
      }
      if (pd.pendingCompletePurchase) {
        await _iap.completePurchase(pd);
      }
    }
  }

  Future<void> _setPro(bool value) async {
    if (_pro == value) return;
    _pro = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('pro', value);
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
