import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:url_launcher/url_launcher.dart';
import '../data/apple_subscription_service.dart';
import '../data/subscription_service.dart';
import '../models/subscription.dart';
import '../theme/app_theme.dart';
import '../widgets/community_safety_dialog.dart';

const String _privacyPolicyUrl =
    String.fromEnvironment('MLIVECAST_PRIVACY_POLICY_URL');

class SubscriptionUpgradeScreen extends StatefulWidget {
  const SubscriptionUpgradeScreen({super.key});

  @override
  State<SubscriptionUpgradeScreen> createState() => _SubscriptionUpgradeScreenState();
}

class _SubscriptionUpgradeScreenState extends State<SubscriptionUpgradeScreen> {
  final SubscriptionService _subscriptionService = SubscriptionService();
  final InAppPurchase _store = InAppPurchase.instance;
  final AppleSubscriptionService _appleSubscriptions = AppleSubscriptionService();
  StreamSubscription<List<PurchaseDetails>>? _purchaseUpdates;
  final Set<String> _purchaseNotificationsShown = {};
  final Set<String> _handledPurchaseUpdates = {};
  final Set<String> _requestedProductIds = {};
  final Map<String, String> _requestedAttemptIds = {};
  String? _activeAppleAttemptId;
  Timer? _restoreRequestWindow;
  Timer? _purchaseTimeout;
  bool _isRestoringPurchases = false;
  bool _isDrainingApplePurchaseQueue = false;
  String? _processingPlanId;

  String _cleanPrice(String rawPrice) {
    return rawPrice.replaceAllMapped(
      RegExp(r'([,\.])(\d+)(?=[^\d\.,]|$)(.*)'),
      (match) {
        final sep = match.group(1)!;
        final decimals = match.group(2)!;
        final rest = match.group(3)!;
        if (RegExp(r'^0+$').hasMatch(decimals)) {
          return rest;
        }
        final stripped = decimals.replaceAll(RegExp(r'0+$'), '');
        return '$sep$stripped$rest';
      },
    );
  }

  List<SubscriptionPlan> _plans = [];
  UserSubscription? _currentSubscription;
  // Canonical subscription level from the users doc — used as fallback when
  // user_subscriptions record is missing, stale, or has an expired endDate.
  String? _canonicalLevel;
  bool _isLoading = true;
  bool _isProcessing = false;
  bool _storeAvailable = false;
  String? _storeError;
  Map<String, ProductDetails> _storeProducts = {};

  bool get _usesAppleIap =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  void _iapLog(String attemptId, String message) {
    // Temporary purchase diagnostics were removed after investigation.
  }

  String _purchaseIdSuffix(String? value) {
    if (value == null || value.isEmpty) return 'none';
    return value.substring(value.length > 6 ? value.length - 6 : 0);
  }

  @override
  void initState() {
    super.initState();
    if (_usesAppleIap) {
      _purchaseUpdates = _store.purchaseStream.listen(
        _onPurchaseUpdates,
        onError: (Object error) {
          _iapLog(_activeAppleAttemptId ?? 'background', 'purchaseStream error=$error');
          if (mounted) {
            setState(() => _storeError = 'The App Store purchase service is unavailable.');
          }
        },
      );
      _loadAppleProducts();
      // Flush any orphaned StoreKit transactions left from previous sessions.
      // The existing listener will silently complete them (restored events are
      // ignored when _isRestoringPurchases == false). This clears the queue
      // so the payment sheet can appear on the next purchase attempt.
      _iapLog('startup', 'restorePurchases begin');
      _store.restorePurchases().then((_) {
        _iapLog('startup', 'restorePurchases future returned');
      }).catchError((Object error) {
        _iapLog('startup', 'restorePurchases future failed error=$error');
      });
    }
    _loadData();
  }

  @override
  void dispose() {
    _purchaseUpdates?.cancel();
    _restoreRequestWindow?.cancel();
    _purchaseTimeout?.cancel();
    super.dispose();
  }

  Future<void> _loadAppleProducts() async {
    final stopwatch = Stopwatch()..start();
    try {
      _iapLog('catalog', 'product load started');
      final available = await _store.isAvailable();
      _iapLog('catalog', 'isAvailable=$available elapsedMs=${stopwatch.elapsedMilliseconds}');
      if (!available) {
        if (mounted) setState(() => _storeError = 'The App Store is not available right now.');
        return;
      }
      final response = await _store.queryProductDetails(
        AppleSubscriptionService.productToPlan.keys.toSet(),
      );
      _iapLog('catalog', 'requested=${AppleSubscriptionService.productToPlan.keys.toList()} '
          'returned=${response.productDetails.map((product) => product.id).toList()} '
          'notFound=${response.notFoundIDs} error=${response.error} '
          'elapsedMs=${stopwatch.elapsedMilliseconds}');
      if (mounted) {
        setState(() {
          _storeAvailable = true;
          _storeProducts = {for (final product in response.productDetails) product.id: product};
          _storeError = response.error?.message;
          if (response.productDetails.isEmpty && response.notFoundIDs.isNotEmpty && _storeError == null) {
            _storeError = 'Subscription products are not available in App Store Connect yet.';
          }
        });
      }
    } catch (error) {
      _iapLog('catalog', 'load failed elapsedMs=${stopwatch.elapsedMilliseconds} error=$error');
      if (mounted) setState(() => _storeError = 'Could not load App Store subscriptions.');
    }
  }

  Future<void> _onPurchaseUpdates(List<PurchaseDetails> purchases) async {
    bool hasCompletedPurchases = false;

    for (final purchase in purchases) {
      final eventAttempt = _requestedAttemptIds[purchase.productID] ??
          _activeAppleAttemptId ?? 'background';
      _iapLog(eventAttempt, 'purchaseStream event productID=${purchase.productID} '
          'status=${purchase.status.name} '
          'transactionSuffix=${_purchaseIdSuffix(purchase.purchaseID)} '
          'transactionDate=${purchase.transactionDate ?? 'none'} '
          'pendingComplete=${purchase.pendingCompletePurchase} '
          'requested=${_requestedProductIds.contains(purchase.productID)} '
          'restoring=$_isRestoringPurchases processing=$_isProcessing '
          'error=${purchase.error?.code ?? 'none'}:${purchase.error?.message ?? 'none'}');

      // 1. Only process subscriptions configured for this screen
      if (!AppleSubscriptionService.productToPlan.containsKey(purchase.productID)) {
        continue;
      }

      final transactionKey = purchase.purchaseID ??
          '${purchase.productID}:${purchase.transactionDate ?? ''}:${purchase.status.name}';

      if (purchase.status == PurchaseStatus.pending) {
        _iapLog(eventAttempt, 'StoreKit explicitly reported PENDING');
        // Only show the spinner for a plan the user explicitly tapped.
        // Startup-replayed StoreKit queue items arrive as "pending" too;
        // setting _isProcessing for those blocks all subscription buttons.
        if (_requestedProductIds.contains(purchase.productID)) {
          if (mounted) setState(() => _isProcessing = true);
        }
        continue;
      }

      if (purchase.status == PurchaseStatus.canceled || purchase.status == PurchaseStatus.error) {
        final wasRequested = _requestedProductIds.remove(purchase.productID);
        _requestedAttemptIds.remove(purchase.productID);
        if (wasRequested || _isRestoringPurchases) {
          _purchaseTimeout?.cancel();
        }
        if (purchase.pendingCompletePurchase) {
          try {
            await _store.completePurchase(purchase);
          } catch (e) {
          }
        }
        if (mounted) {
          setState(() {
            _processingPlanId = null;
            _isProcessing = false;
          });
          if (wasRequested && purchase.status == PurchaseStatus.error) {
            _showMessage(purchase.error?.message ?? 'The App Store purchase could not be completed.');
          }
        }
        _iapLog(eventAttempt, 'terminal event handled wasRequested=$wasRequested '
            'completeCalled=${purchase.pendingCompletePurchase}');
        continue;
      }

      if (purchase.status == PurchaseStatus.purchased ||
          purchase.status == PurchaseStatus.restored) {
        if (purchase.status == PurchaseStatus.restored &&
            !_isRestoringPurchases &&
            _isDrainingApplePurchaseQueue) {
          if (purchase.pendingCompletePurchase) {
            try {
              await _store.completePurchase(purchase);
            } catch (_) {}
          }
          continue;
        }
        final wasRequested = _requestedProductIds.remove(purchase.productID);
        _requestedAttemptIds.remove(purchase.productID);
        final isRestore = _isRestoringPurchases;
        if (wasRequested || isRestore) {
          // Apple's transaction arrived. Do not let the purchase-start timer
          // expire while the backend verifies it.
          _purchaseTimeout?.cancel();
        }
        if (purchase.status == PurchaseStatus.restored &&
            !_isRestoringPurchases &&
            !wasRequested) {
          _iapLog(eventAttempt, 'restored transaction ignored outside explicit Restore flow');
          if (purchase.pendingCompletePurchase) {
            await _store.completePurchase(purchase);
          }
          continue;
        }

        if (!_handledPurchaseUpdates.add(transactionKey)) {
          _iapLog(eventAttempt, 'duplicate transaction update ignored key=$transactionKey');
          if (purchase.pendingCompletePurchase) {
            try {
              await _store.completePurchase(purchase);
            } catch (e) {
            }
          }
          continue;
        }

        var backendSuccess = false;
        Object? backendVerificationError;
        try {
          _iapLog(eventAttempt, 'backend verify begin transactionSuffix=${_purchaseIdSuffix(purchase.purchaseID)}');
          await _appleSubscriptions.verifyAndActivate(
            purchase.verificationData.serverVerificationData,
            clientAttemptId: eventAttempt,
          );
          backendSuccess = true;
          _iapLog(eventAttempt, 'backend verify succeeded');
        } catch (error) {
          _iapLog(eventAttempt, 'backend verify failed error=$error');
          backendVerificationError = error;
        }

        try {
          if (purchase.pendingCompletePurchase) {
            await _store.completePurchase(purchase);
            _iapLog(eventAttempt, 'completePurchase succeeded');
          }
          hasCompletedPurchases = true;
          if (mounted && (wasRequested || isRestore)) {
            final notificationKey = transactionKey;
            if (_purchaseNotificationsShown.add(notificationKey)) {
              _showMessage(backendSuccess
                  ? (isRestore
                      ? 'Your App Store subscription was restored.'
                      : 'Your App Store subscription is active.')
                  : 'Apple returned the purchase, but verification failed: ${backendVerificationError.toString().replaceFirst('Bad state: ', '').replaceFirst('Exception: ', '')}. Your plan has not changed yet.');
            }
          }
        } catch (e) {
          _iapLog(eventAttempt, 'completePurchase failed error=$e');
        } finally {
          _purchaseTimeout?.cancel();
          _restoreRequestWindow?.cancel();
          if (mounted) {
            setState(() {
              _processingPlanId = null;
              _isProcessing = false;
              _isRestoringPurchases = false;
            });
          }
        }
      }
    }

    // Refresh subscription status quietly without tearing down the UI
    if (hasCompletedPurchases) {
      await _loadData(silent: true);
    }
  }

  Future<void> _buyApplePlan(SubscriptionPlan plan) async {
    final attemptId = 'sub-${DateTime.now().microsecondsSinceEpoch}';
    _activeAppleAttemptId = attemptId;
    final attemptTimer = Stopwatch()..start();
    final productIds = AppleSubscriptionService.productToPlan.entries
        .where((entry) => entry.value == plan.id)
        .map((entry) => entry.key)
        .toList();
    final productId = productIds.isEmpty ? null : productIds.first;
    final product = productId == null ? null : _storeProducts[productId];

    _iapLog(attemptId, 'buy tap plan=${plan.id} productId=$productId '
        'storeAvailable=$_storeAvailable '
        'productFound=${product != null} '
        'storeError=$_storeError '
        'storeProductsCount=${_storeProducts.length}');

    if (!_storeAvailable || productId == null || product == null) {
      final reason = !_storeAvailable
          ? 'App Store not available'
          : productId == null
              ? 'No product ID mapped for plan ${plan.id}'
              : 'Product $productId not returned by App Store Connect';
      _showMessage('Cannot start purchase: $reason. '
          '(${_storeError ?? "no store error"})');
      return;
    }
    _requestedProductIds.add(productId);
    _requestedAttemptIds[productId] = attemptId;
    setState(() {
      _processingPlanId = plan.id;
      _isProcessing = true;
    });
    // Step 1: drain any stuck StoreKit transactions.
    // If there is an unfinished transaction for this product in the queue,
    // StoreKit queues the new payment but never shows the payment sheet.
    // restorePurchases() replays all queue entries → our existing listener
    // calls completePurchase on each one → queue is clean after the wait.
    _iapLog(attemptId, 'pre-purchase restorePurchases begin');
    _showMessage('Clearing Apple queue…');
    _isDrainingApplePurchaseQueue = true;
    try {
      await _store.restorePurchases();
      _iapLog(attemptId, 'restorePurchases future returned elapsedMs=${attemptTimer.elapsedMilliseconds}');
    } catch (error) {
      _iapLog(attemptId, 'restorePurchases future failed elapsedMs=${attemptTimer.elapsedMilliseconds} error=$error');
    }
    // Give StoreKit 3 s to deliver and complete all pending events.
    await Future<void>.delayed(const Duration(seconds: 3));
    _isDrainingApplePurchaseQueue = false;
    _iapLog(attemptId, 'queue-drain wait ended elapsedMs=${attemptTimer.elapsedMilliseconds}');
    if (!mounted) {
      _requestedProductIds.remove(productId);
      _requestedAttemptIds.remove(productId);
      return;
    }
    // Step 2: attempt the actual purchase on a clean queue.
    _showMessage('Contacting App Store for $productId…');
    _purchaseTimeout?.cancel();
    _purchaseTimeout = Timer(const Duration(seconds: 30), () {
      if (mounted && _isProcessing) {
        _iapLog(attemptId, '30s timeout fired elapsedMs=${attemptTimer.elapsedMilliseconds} '
            'requested=${_requestedProductIds.contains(productId)} '
            'activeAttempt=${_activeAppleAttemptId == attemptId}');
        setState(() {
          _processingPlanId = null;
          _isProcessing = false;
        });
        _showMessage(
          'Apple has not sent a purchase update yet for $productId. '
          'If Apple confirmed the purchase, tap Restore Purchases before trying again.',
        );
      }
    });
    try {
      _iapLog(attemptId, 'buyNonConsumable call begin product=$productId');
      final started = await _store.buyNonConsumable(
        purchaseParam: PurchaseParam(productDetails: product),
      );
      _iapLog(attemptId, 'buyNonConsumable future returned started=$started elapsedMs=${attemptTimer.elapsedMilliseconds}');
      if (!started) {
        _purchaseTimeout?.cancel();
        _requestedProductIds.remove(productId);
        _requestedAttemptIds.remove(productId);
        if (mounted) {
          setState(() {
            _processingPlanId = null;
            _isProcessing = false;
          });
          _showMessage('Apple returned false for $productId — '
              'possible Screen Time restriction or existing subscription. '
              'Check Settings → Screen Time → Content & Privacy Restrictions.');
        }
      }
    } catch (error) {
      _purchaseTimeout?.cancel();
      _requestedProductIds.remove(productId);
      _requestedAttemptIds.remove(productId);
      _iapLog(attemptId, 'buyNonConsumable future threw elapsedMs=${attemptTimer.elapsedMilliseconds} error=$error');
      if (mounted) {
        setState(() {
          _processingPlanId = null;
          _isProcessing = false;
        });
        _showMessage('Purchase error for $productId: '
            '${error.toString().replaceFirst('Bad state: ', '')}');
      }
    }
  }

  Future<void> _restoreApplePurchases() async {
    setState(() {
      _isRestoringPurchases = true;
      _isProcessing = true;
    });
    try {
      _handledPurchaseUpdates.clear();
      _restoreRequestWindow?.cancel();
      _restoreRequestWindow = Timer(const Duration(seconds: 15), () {
        if (mounted && _isRestoringPurchases) {
          setState(() {
            _isRestoringPurchases = false;
            _isProcessing = false;
          });
          _showMessage('Restore process finished.');
        }
      });
      await _store.restorePurchases();
    } catch (error) {
      _restoreRequestWindow?.cancel();
      if (mounted) {
        setState(() {
          _isRestoringPurchases = false;
          _isProcessing = false;
        });
        _showMessage('Could not restore purchases. Please try again.');
      }
    }
  }

  Future<void> _manageAppleSubscriptions() async {
    final uri = Uri.parse('https://apps.apple.com/account/subscriptions');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && mounted) {
      _showMessage('Could not open Apple subscription settings.');
    }
  }

  Future<void> _openPrivacyPolicy() async {
    final uri = Uri.tryParse(_privacyPolicyUrl);
    if (uri == null || !uri.hasScheme || !await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    )) {
      if (mounted) _showMessage('Could not open the Privacy Policy.');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _loadData({bool silent = false}) async {
    if (!silent && _plans.isEmpty && mounted) {
      setState(() => _isLoading = true);
    }
    
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final plans = await _subscriptionService.getPlans();
      final subscription = await _subscriptionService.getUserSubscription(user.uid);
      // Also read the canonical subscriptionLevel from the users collection.
      // This is the source of truth for feature gating. The user_subscriptions
      // record may have an expired endDate (e.g. from a previous Sandbox test)
      // while users.subscriptionLevel still correctly reflects their entitlement.
      String? canonicalLevel;
      try {
        final userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();
        canonicalLevel = userDoc.data()?['subscriptionLevel'] as String?;
      } catch (e) {
      }
      
      if (mounted) {
        setState(() {
          _plans = plans;
          _currentSubscription = subscription;
          _canonicalLevel = canonicalLevel;
          _isLoading = false;
        });
      }
    } else if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF09090B),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0C),
        title: const Text(
          'Upgrade Subscription',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.primary))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildCurrentPlanInfo(),
                  const SizedBox(height: 32),
                  const Text(
                    'Choose Your Plan',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 24),
                  ..._plans.map((plan) => _buildPlanCard(plan)),
                  if (_usesAppleIap) ...[
                    if (_storeError != null) ...[
                      const SizedBox(height: 12),
                      Text(_storeError!, style: const TextStyle(color: Colors.orangeAccent)),
                    ],
                    const SizedBox(height: 16),
                    Center(
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 16,
                        runSpacing: 4,
                        children: [
                          TextButton(
                            onPressed: _isProcessing ? null : _restoreApplePurchases,
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white70,
                              disabledForegroundColor: Colors.white30,
                            ),
                            child: _isRestoringPurchases
                                ? const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(
                                        width: 12,
                                        height: 12,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 1.5,
                                          color: Colors.white70,
                                        ),
                                      ),
                                      SizedBox(width: 8),
                                      Text('Restoring…', style: TextStyle(color: Colors.white70, fontSize: 13)),
                                    ],
                                  )
                                : const Text('Restore Purchases', style: TextStyle(fontSize: 13)),
                          ),
                          TextButton(
                            onPressed: _isProcessing ? null : _manageAppleSubscriptions,
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white70,
                              disabledForegroundColor: Colors.white30,
                            ),
                            child: const Text('Manage Subscription', style: TextStyle(fontSize: 13)),
                          ),
                          TextButton(
                            onPressed: () => CommunitySafetyHelper.showEula(context),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white70,
                              disabledForegroundColor: Colors.white30,
                            ),
                            child: const Text('Terms of Use', style: TextStyle(fontSize: 13)),
                          ),
                          if (_privacyPolicyUrl.isNotEmpty)
                            TextButton(
                              onPressed: _openPrivacyPolicy,
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white70,
                                disabledForegroundColor: Colors.white30,
                              ),
                              child: const Text('Privacy Policy', style: TextStyle(fontSize: 13)),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Payment will be charged to your Apple Account at confirmation. Subscriptions renew automatically unless canceled at least 24 hours before the current period ends. Your account will be charged for renewal within 24 hours before the period ends. Manage or cancel in Apple Account settings.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildCurrentPlanInfo() {
    final hasActiveSub = _currentSubscription != null &&
        _currentSubscription!.isActive &&
        !_currentSubscription!.isExpired;
    // If the subscription record is missing/expired but users.subscriptionLevel
    // says premium, still show the premium banner (the data just needs a refresh).
    final canonicalIsPremium = _canonicalLevel != null &&
        _canonicalLevel != 'free' &&
        _canonicalLevel!.isNotEmpty;

    if (!hasActiveSub && !canonicalIsPremium) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
        ),
        child: Row(
          children: [
            const Icon(LucideIcons.info, color: Colors.white54, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'You are currently on the Free plan. Upgrade to unlock premium features!',
                style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 14),
              ),
            ),
          ],
        ),
      );
    }

    final currentPlan = hasActiveSub
        ? _plans.firstWhere(
            (p) => p.id == _currentSubscription!.planId,
            orElse: () => _plans.firstWhere((p) => p.id == 'premium', orElse: () => _plans[0]),
          )
        : _plans.firstWhere(
            (p) => p.id == (_canonicalLevel ?? 'premium'),
            orElse: () => _plans.firstWhere((p) => p.id == 'premium', orElse: () => _plans[0]),
          );

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.primary.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.primary.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(LucideIcons.crown, color: AppTheme.primary, size: 20),
              const SizedBox(width: 12),
              Text(
                'Current Plan: ${currentPlan.name}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (hasActiveSub && _currentSubscription!.endDate != null)
            Text(
              '${_currentSubscription!.autoRenew ? 'Renews on' : 'Access ends'}: ${_currentSubscription!.endDate.toString().split('.')[0]}',
              style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 12),
            )
          else if (!hasActiveSub && canonicalIsPremium)
            const Text(
              'Your subscription is active. Tap "Subscribe with Apple" to renew or confirm.',
              style: TextStyle(color: Colors.white60, fontSize: 12),
            ),
          if (hasActiveSub && _currentSubscription!.status == 'canceled')
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'Canceled - Will expire at end of billing period',
                style: TextStyle(color: Colors.orange, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPlanCard(SubscriptionPlan plan) {
    // hasActiveSub: subscription record exists, is active, and not expired.
    final hasActiveSub = _currentSubscription != null &&
        _currentSubscription!.isActive &&
        !_currentSubscription!.isExpired;
    // canonicalIsPremium: users.subscriptionLevel says premium even if the
    // user_subscriptions record is missing or its endDate has expired.
    // This covers the case where profile shows "Premium" but sub page shows "Free".
    final canonicalIsPremium = _canonicalLevel != null &&
        _canonicalLevel != 'free' &&
        _canonicalLevel!.isNotEmpty;
    final effectiveHasActive = hasActiveSub || canonicalIsPremium;
    final activePlanId = hasActiveSub
        ? _currentSubscription!.planId
        : (canonicalIsPremium ? (_canonicalLevel ?? 'free') : 'free');
    final isCurrentPlan = activePlanId == plan.id ||
        (canonicalIsPremium && plan.id == 'premium' && activePlanId.startsWith('premium'));
    final currentPlanPrice = _plans.firstWhere(
      (p) => p.id == activePlanId,
      orElse: () => _plans[0],
    ).price;
    final isUpgrade = plan.price > currentPlanPrice;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: isCurrentPlan 
            ? AppTheme.primary.withOpacity(0.15)
            : const Color(0xFF141416),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isCurrentPlan 
              ? AppTheme.primary 
              : Colors.white.withOpacity(0.08),
          width: isCurrentPlan ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                plan.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (isCurrentPlan)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppTheme.primary,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'Current',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            plan.description,
            style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 14),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _usesAppleIap
                    ? (plan.id == 'free'
                        ? 'Free'
                        : _cleanPrice(_storeProducts[_appleProductIdForPlan(plan.id)]?.price ?? '—'))
                    : '\$${plan.price.toStringAsFixed(2)}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '/${plan.interval}',
                  style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 14),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: plan.features.map((feature) => _buildFeatureChip(feature)).toList(),
          ),
          const SizedBox(height: 24),
          if (isCurrentPlan || (_usesAppleIap && plan.id == 'free' && !effectiveHasActive))
            _buildCurrentPlanButton()
          else if (isCurrentPlan)
            _buildCurrentPlanButton()
          else
            _buildUpgradeButton(plan, isUpgrade),
        ],
      ),
    );
  }

  Widget _buildFeatureChip(String feature) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(LucideIcons.check, size: 14, color: Colors.green),
          const SizedBox(width: 8),
          Text(
            feature,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentPlanButton() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Center(
        child: Text(
          'Current Plan',
          style: TextStyle(
            color: Colors.white54,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildUpgradeButton(SubscriptionPlan plan, bool isUpgrade) {
    final label = isUpgrade ? 'Upgrade' : 'Switch Plan';
    final color = isUpgrade ? AppTheme.primary : Colors.blue;
    final appleProductReady = !_usesAppleIap ||
        (_storeAvailable && _storeProducts.containsKey(_appleProductIdForPlan(plan.id)));
    final isThisPlanProcessing = _isProcessing && _processingPlanId == plan.id;

    return InkWell(
      onTap: _isProcessing || !appleProductReady
          ? null
          : () => _usesAppleIap ? _buyApplePlan(plan) : _showPaymentDialog(plan),
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: !appleProductReady
              ? Colors.white.withOpacity(0.08)
              : isThisPlanProcessing
                  ? color.withOpacity(0.7)
                  : (_isProcessing ? color.withOpacity(0.4) : color),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: isThisPlanProcessing
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  ),
                )
              : Text(
                  _usesAppleIap && !appleProductReady
                      ? (_storeError != null || _storeAvailable
                          ? 'Not available'
                          : 'Loading App Store…')
                      : _usesAppleIap ? 'Subscribe with Apple' : label,
                  style: TextStyle(
                    color: !appleProductReady ? Colors.white38 : Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
        ),
      ),
    );
  }

  String? _appleProductIdForPlan(String planId) {
    for (final entry in AppleSubscriptionService.productToPlan.entries) {
      if (entry.value == planId) return entry.key;
    }
    return null;
  }

  void _showPaymentDialog(SubscriptionPlan plan) {
    final cardNumberController = TextEditingController();
    final expiryController = TextEditingController();
    final cvcController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF151515),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withOpacity(0.1)),
        ),
        title: Text(
          'Upgrade to ${plan.name}',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Total: \$${plan.price.toStringAsFixed(2)}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Payment Details',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              _buildPaymentField(cardNumberController, 'Card Number', '4242 4242 4242 4242'),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _buildPaymentField(expiryController, 'MM/YY', '12/25'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildPaymentField(cvcController, 'CVC', '123'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(LucideIcons.shield, size: 16, color: Colors.white38),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This is a demo. No actual payment will be processed.',
                        style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              setState(() => _isProcessing = true);
              Navigator.pop(context);

              // Simulate payment processing
              await Future.delayed(const Duration(seconds: 2));

              final user = FirebaseAuth.instance.currentUser;
              if (user != null) {
                // Create subscription (placeholder)
                await _subscriptionService.createSubscription(
                  userId: user.uid,
                  planId: plan.id,
                  stripeSubscriptionId: 'sub_demo_${DateTime.now().millisecondsSinceEpoch}',
                  stripeCustomerId: 'cus_demo_${DateTime.now().millisecondsSinceEpoch}',
                );

                if (mounted) {
                  setState(() => _isProcessing = false);
                  _loadData(silent: true);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Successfully upgraded to ${plan.name}!'),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              }
            },
            child: const Text('Pay Now'),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentField(TextEditingController controller, String label, String placeholder) {
    return TextField(
      controller: controller,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
        hintText: placeholder,
        hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppTheme.primary),
        ),
      ),
    );
  }
}
