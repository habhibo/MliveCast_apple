"use strict";

const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");
const crypto = require("crypto");
const sponsorship = require("./sponsorship");
const {
  Environment,
  SignedDataVerifier,
} = require("@apple/app-store-server-library");

const BUNDLE_ID = "com.contestlive.contestLive";
const PRODUCT_PLANS = {
  "com.mlivecast.premium.monthly": "premium",
  "com.mlivecast.premium.yearly": "premium_yearly",
};
const ROOT_CERT_SECRET = "APPLE_ROOT_CA_G3_BASE64";

if (!admin.apps.length) admin.initializeApp();
const db = admin.firestore();

function diagnosticTag(value) {
  return crypto.createHash("sha256").update(String(value || ""))
      .digest("hex").slice(0, 10);
}

function diagnosticSuffix(value) {
  const text = String(value || "");
  return text ? text.slice(-6) : "none";
}

/**
 * Decode a JWS payload for routing only; this does not verify its signature.
 * @param {string} jws Signed JWS value.
 * @return {Object} Decoded payload.
 */
function decodeUntrustedJwsPayload(jws) {
  if (typeof jws !== "string") throw new Error("Missing signed data");
  const parts = jws.split(".");
  if (parts.length !== 3) throw new Error("Malformed signed data");
  return JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
}

/**
 * Read the claimed Apple environment from a signed transaction payload.
 * @param {string} jws Signed transaction JWS.
 * @return {string} Apple sandbox or production environment.
 */
function getEnvironment(jws) {
  const payload = decodeUntrustedJwsPayload(jws);
  if (payload.environment === "Sandbox") return Environment.SANDBOX;
  if (payload.environment === "Production") return Environment.PRODUCTION;
  throw new Error("Unknown App Store environment");
}

/**
 * Verify an App Store notification and identify its environment.
 * @param {string} signedPayload Signed notification payload.
 * @return {Promise<Object>} Verified notification and matching verifier.
 */
async function verifyNotificationPayload(signedPayload) {
  const payload = decodeUntrustedJwsPayload(signedPayload);
  const environmentName = payload.data && payload.data.environment;
  if (environmentName === "Sandbox" || environmentName === "Production") {
    const environment = environmentName === "Sandbox" ?
      Environment.SANDBOX : Environment.PRODUCTION;
    const verifier = createVerifier(environment);
    return {environment, verifier,
      notification: await verifier.verifyAndDecodeNotification(signedPayload)};
  }

  // Apple's TEST notification can omit the data object that normally carries
  // the environment. Verify it against the supported environments in turn.
  for (const environment of [Environment.SANDBOX, Environment.PRODUCTION]) {
    try {
      const verifier = createVerifier(environment);
      const notification = await verifier.verifyAndDecodeNotification(
          signedPayload);
      return {environment, verifier, notification};
    } catch (_) {
      // Try the other environment; only a successfully verified JWS is used.
    }
  }
  throw new Error("App Store notification signature could not be verified");
}

/**
 * Create Apple's signed-data verifier for the selected environment.
 * @param {string} environment Apple sandbox or production environment.
 * @return {SignedDataVerifier} Configured verifier.
 */
function createVerifier(environment) {
  const encoded = process.env[ROOT_CERT_SECRET];
  if (!encoded) throw new Error(`${ROOT_CERT_SECRET} is not configured`);
  const appAppleId = environment === Environment.PRODUCTION ?
    Number(process.env.APPLE_APP_ID) : undefined;
  if (environment === Environment.PRODUCTION &&
      (!Number.isSafeInteger(appAppleId) || appAppleId <= 0)) {
    throw new Error(
        "APPLE_APP_ID is not configured for production verification");
  }
  return new SignedDataVerifier(
      [Buffer.from(encoded, "base64")], true, environment, BUNDLE_ID,
      appAppleId,
  );
}

/**
 * Verify and decode an App Store transaction JWS.
 * @param {string} signedTransaction Signed transaction payload.
 * @return {Promise<Object>} Verified transaction and its verifier.
 */
async function verifyTransaction(signedTransaction) {
  const environment = getEnvironment(signedTransaction);
  const verifier = createVerifier(environment);
  const transaction = await verifier.verifyAndDecodeTransaction(
      signedTransaction);
  if (transaction.bundleId !== BUNDLE_ID) {
    throw new Error("Transaction bundle does not match this app");
  }
  if (!PRODUCT_PLANS[transaction.productId]) {
    throw new Error("Unrecognized subscription product");
  }
  if (!transaction.transactionId || !transaction.originalTransactionId ||
      !transaction.purchaseDate || !transaction.expiresDate) {
    throw new Error("Incomplete App Store transaction");
  }
  return {environment, verifier, transaction};
}

/**
 * Verify and decode a signed App Store transaction for a sponsorship.
 * @param {string} signedTransaction Signed transaction payload.
 * @return {Promise<Object>} Verified one-time transaction.
 */
async function verifyOneTimeTransaction(signedTransaction) {
  const environment = getEnvironment(signedTransaction);
  const verifier = createVerifier(environment);
  const transaction = await verifier.verifyAndDecodeTransaction(
      signedTransaction);
  if (transaction.bundleId !== BUNDLE_ID) {
    throw new Error("Transaction bundle does not match this app");
  }
  if (!transaction.productId || !transaction.transactionId ||
      !transaction.purchaseDate) {
    throw new Error("Incomplete App Store transaction");
  }
  return transaction;
}

/**
 * Convert an Apple transaction timestamp to an ISO date string.
 * @param {number|string} milliseconds Timestamp in milliseconds.
 * @return {string} ISO date string.
 */
function asIsoDate(milliseconds) {
  const date = new Date(Number(milliseconds));
  if (!Number.isFinite(date.getTime())) {
    throw new Error("Invalid App Store transaction date");
  }
  return date.toISOString();
}

/**
 * Persist a verified Apple transaction and update the user's entitlement.
 * @param {Object} options Verified transaction and entitlement status fields.
 * @return {Promise<Object>} Transfer result after the Firestore transaction commits.
 */
async function writeAppleEntitlement({
  uid,
  transaction,
  autoRenew,
  pendingPlanId,
  pendingAppleProductId,
  statusOverride,
  entitlementEndMs,
  allowAccountTransfer = false,
}) {
  const planId = PRODUCT_PLANS[transaction.productId];
  const expiresAt = Number(entitlementEndMs || transaction.expiresDate);
  const revoked = Boolean(transaction.revocationDate);
  const active = !revoked && expiresAt > Date.now();
  const status = statusOverride ||
    (active ? "active" : revoked ? "revoked" : "expired");
  const ownerRef = db.collection("apple_subscription_owners")
      .doc(transaction.originalTransactionId);
  const transactionRef = db.collection("apple_iap_transactions")
      .doc(transaction.transactionId);
  const subscriptionRef = db.collection("user_subscriptions").doc(uid);
  const userRef = db.collection("users").doc(uid);
  let transferredFromUids = [];

  await db.runTransaction(async (firestoreTransaction) => {
    const owner = await firestoreTransaction.get(ownerRef);
    const existingSubscription = await firestoreTransaction.get(
        subscriptionRef);
    const prior = await firestoreTransaction.get(transactionRef);
    const ownerUid = owner.exists ? owner.get("userId") : null;
    const priorUid = prior.exists ? prior.get("userId") : null;
    const ownerBelongsToAnotherUser = Boolean(ownerUid && ownerUid !== uid);
    // The original-transaction owner is authoritative after a transfer. Old
    // per-transaction rows from that same chain can be reassigned on restore.
    // If no chain owner exists, a conflicting transaction row still requires
    // an explicit user restore before it can be claimed.
    const orphanedTransactionBelongsToAnotherUser = !owner.exists &&
      Boolean(priorUid && priorUid !== uid);
    if ((ownerBelongsToAnotherUser || orphanedTransactionBelongsToAnotherUser) &&
        !allowAccountTransfer) {
      throw new Error(
          "This Apple subscription is linked to another Mlivecast account. " +
          "Tap Restore Purchases to move it to this account.");
    }

    transferredFromUids = allowAccountTransfer ?
      [...new Set([
        ...(ownerBelongsToAnotherUser ? [ownerUid] : []),
        ...(orphanedTransactionBelongsToAnotherUser ? [priorUid] : []),
      ])] : [];
    const previousAccounts = [];
    for (const previousUid of transferredFromUids) {
      const previousSubscriptionRef = db.collection("user_subscriptions")
          .doc(previousUid);
      const previousUserRef = db.collection("users").doc(previousUid);
      const [previousSubscription, previousUser] = await Promise.all([
        firestoreTransaction.get(previousSubscriptionRef),
        firestoreTransaction.get(previousUserRef),
      ]);
      previousAccounts.push({
        uid: previousUid,
        subscriptionRef: previousSubscriptionRef,
        subscription: previousSubscription,
        userRef: previousUserRef,
        user: previousUser,
      });
    }

    const sameAppleSubscription = existingSubscription.exists &&
      existingSubscription.get("appleOriginalTransactionId") ===
        transaction.originalTransactionId;
    const effectiveAutoRenew = autoRenew == null ?
      (sameAppleSubscription ?
        existingSubscription.get("autoRenew") !== false : true) : autoRenew;
    const pendingPlanFields = {};
    if (pendingPlanId !== undefined) {
      pendingPlanFields.pendingPlanId = pendingPlanId;
      pendingPlanFields.pendingAppleProductId = pendingAppleProductId || null;
    } else if (existingSubscription.exists &&
        existingSubscription.get("pendingAppleProductId") ===
          transaction.productId) {
      pendingPlanFields.pendingPlanId = null;
      pendingPlanFields.pendingAppleProductId = null;
    }

    // A transfer is a move, not a second entitlement. Revoke the Apple
    // subscription from each prior Mlivecast account in this verified chain.
    for (const previous of previousAccounts) {
      const previousData = previous.subscription.exists ?
        previous.subscription.data() : null;
      if (previousData &&
          previousData.paymentProvider === "apple" &&
          previousData.appleOriginalTransactionId ===
            transaction.originalTransactionId) {
        firestoreTransaction.set(previous.subscriptionRef, {
          status: "transferred",
          autoRenew: false,
          transferredToUserId: uid,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, {merge: true});
        if (previous.user.exists &&
            previous.user.get("subscriptionLevel") === "premium") {
          firestoreTransaction.set(previous.userRef,
              {subscriptionLevel: "free"}, {merge: true});
        }
      }
    }

    firestoreTransaction.set(ownerRef, {
      userId: uid,
      originalTransactionId: transaction.originalTransactionId,
      productId: transaction.productId,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
    firestoreTransaction.set(transactionRef, {
      userId: uid,
      productId: transaction.productId,
      transactionId: transaction.transactionId,
      originalTransactionId: transaction.originalTransactionId,
      environment: transaction.environment || null,
      purchaseDate: asIsoDate(transaction.purchaseDate),
      expiresDate: asIsoDate(transaction.expiresDate),
      revocationDate: transaction.revocationDate ?
        asIsoDate(transaction.revocationDate) : null,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});

    const existingEndDate = existingSubscription.exists ?
      Date.parse(existingSubscription.get("endDate") || "") : 0;
    // A delayed event must not overwrite a newer entitlement already applied
    // for the same account.
    if (Number.isFinite(existingEndDate) && existingEndDate > expiresAt) {
      if (Object.keys(pendingPlanFields).length > 0) {
        firestoreTransaction.set(subscriptionRef, {
          ...pendingPlanFields,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, {merge: true});
      }
      if (status === "active") {
        firestoreTransaction.set(
            userRef, {subscriptionLevel: "premium"}, {merge: true});
      }
      return;
    }

    if (status === "active") {
      firestoreTransaction.set(subscriptionRef, {
        userId: uid,
        planId,
        status,
        startDate: asIsoDate(transaction.purchaseDate),
        endDate: asIsoDate(expiresAt),
        autoRenew: effectiveAutoRenew,
        paymentProvider: "apple",
        appleProductId: transaction.productId,
        appleTransactionId: transaction.transactionId,
        appleOriginalTransactionId: transaction.originalTransactionId,
        appleEnvironment: transaction.environment || null,
        ...pendingPlanFields,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
      // Existing feature gates check the canonical "premium" level. The plan
      // ID can differ (for example, premium_yearly).
      firestoreTransaction.set(
          userRef, {subscriptionLevel: "premium"}, {merge: true});
    } else {
      firestoreTransaction.set(subscriptionRef, {
        userId: uid,
        planId,
        status,
        startDate: asIsoDate(transaction.purchaseDate),
        endDate: asIsoDate(expiresAt),
        autoRenew: false,
        paymentProvider: "apple",
        appleProductId: transaction.productId,
        appleTransactionId: transaction.transactionId,
        appleOriginalTransactionId: transaction.originalTransactionId,
        appleEnvironment: transaction.environment || null,
        ...pendingPlanFields,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
      firestoreTransaction.set(
          userRef, {subscriptionLevel: "free"}, {merge: true});
    }
  });
  return {
    transferred: transferredFromUids.length > 0,
    transferredFromUids,
  };
}

exports.verifyAppleSubscription = functions
    .region("us-central1")
    .runWith({secrets: [ROOT_CERT_SECRET]})
    .https.onRequest(async (req, res) => {
      res.set("Cache-Control", "no-store");
      if (req.method !== "POST") {
        return res.status(405).json({error: "POST required"});
      }
      const requestStartedAt = Date.now();
      try {
        const authorization = req.get("authorization") || "";
        const match = authorization.match(/^Bearer\s+(.+)$/i);
        if (!match) return res.status(401).json({error: "Sign in is required"});
        const decoded = await admin.auth().verifyIdToken(match[1]);
        const clientAttemptId = typeof (req.body && req.body.clientAttemptId) === "string" ?
          req.body.clientAttemptId.slice(0, 80) : null;
        const userInitiatedSync = clientAttemptId === "restore" ||
          Boolean(clientAttemptId && clientAttemptId.startsWith("sub-"));
        console.info("[IAP-Subscription] verification request", JSON.stringify({
          userTag: diagnosticTag(decoded.uid),
          clientAttemptId,
        }));
        const signedTransaction = req.body && req.body.signedTransaction;
        console.info("[IAP-Subscription] request authenticated", JSON.stringify({
          userTag: diagnosticTag(decoded.uid),
          clientAttemptId,
          signedDataPresent: typeof signedTransaction === "string" &&
            signedTransaction.length > 0,
          signedDataLength: typeof signedTransaction === "string" ?
            signedTransaction.length : 0,
        }));
        const {transaction} = await verifyTransaction(signedTransaction);
        console.info("[IAP-Subscription] transaction verified", JSON.stringify({
          userTag: diagnosticTag(decoded.uid),
          clientAttemptId,
          productId: transaction.productId,
          transactionTag: diagnosticTag(transaction.transactionId),
          transactionSuffix: diagnosticSuffix(transaction.transactionId),
          originalTransactionTag: diagnosticTag(
              transaction.originalTransactionId),
          purchaseDate: transaction.purchaseDate,
          expiresDate: transaction.expiresDate,
          revoked: Boolean(transaction.revocationDate),
          environment: transaction.environment || null,
        }));
        // Apple's verified signed transaction is the source of truth. Do not
        // compare its purchaseDate with the device clock: clock skew and
        // StoreKit replay/restore can make a valid active entitlement appear
        // older than the client request. Expiration, revocation, and original
        // transaction ownership are checked below and in writeAppleEntitlement.
        if (transaction.revocationDate ||
            Number(transaction.expiresDate) <= Date.now()) {
          console.warn("[IAP-Subscription] inactive transaction rejected", JSON.stringify({
            userTag: diagnosticTag(decoded.uid),
            clientAttemptId,
            productId: transaction.productId,
            transactionTag: diagnosticTag(transaction.transactionId),
            transactionSuffix: diagnosticSuffix(transaction.transactionId),
            expiresDate: transaction.expiresDate,
            revoked: Boolean(transaction.revocationDate),
          }));
          return res.status(402).json({
            error: "This App Store subscription is no longer active",
          });
        }
        const entitlementResult = await writeAppleEntitlement({
          uid: decoded.uid,
          transaction,
          allowAccountTransfer: userInitiatedSync,
        });
        if (entitlementResult.transferred) {
          console.info("[IAP-Subscription] ownership transferred", JSON.stringify({
            fromUserTags: entitlementResult.transferredFromUids.map(
                (previousUid) => diagnosticTag(previousUid)),
            toUserTag: diagnosticTag(decoded.uid),
            productId: transaction.productId,
            originalTransactionTag: diagnosticTag(
                transaction.originalTransactionId),
          }));
        }
        console.info("[IAP-Subscription] entitlement activated", JSON.stringify({
          userTag: diagnosticTag(decoded.uid),
          clientAttemptId,
          productId: transaction.productId,
          transactionTag: diagnosticTag(transaction.transactionId),
          transactionSuffix: diagnosticSuffix(transaction.transactionId),
        }));
        return res.status(200).json({
          ok: true,
          transferred: entitlementResult.transferred,
        });
      } catch (error) {
        console.error("[verifyAppleSubscription]", JSON.stringify({
          clientAttemptId: req.body && req.body.clientAttemptId || null,
          elapsedMs: Date.now() - requestStartedAt,
          errorCode: error.code || null,
          error: error.message,
        }));
        const status = error.code === "auth/argument-error" ||
          error.code === "auth/id-token-expired" ? 401 : 400;
        return res.status(status).json({
          error: error.message || "Purchase verification failed",
        });
      }
    });

exports.verifyAppleSponsorship = functions
    .region("us-central1")
    .runWith({secrets: [ROOT_CERT_SECRET]})
    .https.onRequest(async (req, res) => {
      res.set("Cache-Control", "no-store");
      if (req.method !== "POST") {
        return res.status(405).json({error: "POST required"});
      }
      const requestStartedAt = Date.now();
      try {
        const authorization = req.get("authorization") || "";
        const match = authorization.match(/^Bearer\s+(.+)$/i);
        if (!match) {
          return res.status(401).json({error: "Sign in is required"});
        }
        const decoded = await admin.auth().verifyIdToken(match[1]);
        const clientAttemptId = typeof (req.body && req.body.clientAttemptId) === "string" ?
          req.body.clientAttemptId.slice(0, 80) : null;
        const signedTransaction = req.body && req.body.signedTransaction;
        console.info("[IAP-Sponsor] request authenticated", JSON.stringify({
          userTag: diagnosticTag(decoded.uid),
          clientAttemptId,
          signedDataPresent: typeof signedTransaction === "string" &&
            signedTransaction.length > 0,
          signedDataLength: typeof signedTransaction === "string" ?
            signedTransaction.length : 0,
        }));
        const transaction = await verifyOneTimeTransaction(
            signedTransaction);
        console.info("[IAP-Sponsor] transaction verified", JSON.stringify({
          userTag: diagnosticTag(decoded.uid),
          clientAttemptId,
          productId: transaction.productId,
          transactionTag: diagnosticTag(transaction.transactionId),
          transactionSuffix: diagnosticSuffix(transaction.transactionId),
          purchaseDate: transaction.purchaseDate,
          environment: transaction.environment || null,
          revoked: Boolean(transaction.revocationDate),
        }));
        if (transaction.revocationDate) {
          console.warn("[IAP-Sponsor] refunded transaction rejected", JSON.stringify({
            userTag: diagnosticTag(decoded.uid),
            clientAttemptId,
            productId: transaction.productId,
            transactionTag: diagnosticTag(transaction.transactionId),
            transactionSuffix: diagnosticSuffix(transaction.transactionId),
          }));
          return res.status(402).json({error: "This purchase was refunded"});
        }
        await sponsorship.activateAppleSponsorship(decoded.uid, transaction);
        console.info("[IAP-Sponsor] transaction applied", JSON.stringify({
          userTag: diagnosticTag(decoded.uid),
          clientAttemptId,
          productId: transaction.productId,
          transactionTag: diagnosticTag(transaction.transactionId),
          transactionSuffix: diagnosticSuffix(transaction.transactionId),
        }));
        return res.status(200).json({ok: true});
      } catch (error) {
        console.error("[verifyAppleSponsorship]", JSON.stringify({
          clientAttemptId: req.body && req.body.clientAttemptId || null,
          elapsedMs: Date.now() - requestStartedAt,
          errorCode: error.code || null,
          error: error.message,
        }));
        const status = error.code === "auth/argument-error" ||
          error.code === "auth/id-token-expired" ? 401 :
          error.code === "APPLE_TRANSACTION_REPLAY" ? 409 : 400;
        return res.status(status).json({
          error: error.message || "Sponsorship purchase verification failed",
        });
      }
    });

exports.appleSubscriptionNotifications = functions
    .region("us-central1")
    .runWith({secrets: [ROOT_CERT_SECRET]})
    .https.onRequest(async (req, res) => {
      if (req.method !== "POST") {
        return res.status(405).send("POST required");
      }
      let applePayloadVerified = false;
      try {
        const signedPayload = req.body && req.body.signedPayload;
        const {verifier, notification} =
          await verifyNotificationPayload(signedPayload);
        applePayloadVerified = true;
        const uuid = notification.notificationUUID;
        if (!uuid) throw new Error("App Store notification has no UUID");
        const eventRef = db.collection("apple_iap_notifications").doc(uuid);
        const eventSnapshot = await eventRef.get();
        if (eventSnapshot.exists &&
            eventSnapshot.get("status") === "PROCESSED") {
          return res.status(200).send("Already processed");
        }
        const data = notification.data;
        if (!data || !data.signedTransactionInfo) {
          await eventRef.set({
            status: "PROCESSED",
            notificationType: notification.notificationType || null,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          });
          return res.status(200).send("No transaction data");
        }
        const transaction = await verifier.verifyAndDecodeTransaction(
            data.signedTransactionInfo);
        applePayloadVerified = true;
        const sponsorProduct = await db.collection("apple_sponsorship_products")
            .doc(transaction.productId).get();
        if (sponsorProduct.exists) {
          if (["REFUND", "REVOKE"].includes(
              notification.notificationType)) {
            await sponsorship.refundAppleSponsorship(transaction);
          }
          await eventRef.set({
            status: "PROCESSED",
            notificationType: notification.notificationType || null,
            productId: transaction.productId,
            transactionId: transaction.transactionId || null,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          });
          return res.status(200).send("Processed sponsorship notification");
        }
        const ownerSnapshot = await db.collection("apple_subscription_owners")
            .doc(transaction.originalTransactionId).get();
        if (!ownerSnapshot.exists) {
          // First purchase sync may still be arriving from the app. Retry lets
          // Apple redeliver instead of permanently dropping the renewal event.
          return res.status(500).send(
              "Subscription owner is not registered yet");
        }
        const uid = ownerSnapshot.get("userId");
        let autoRenew;
        let pendingPlanId;
        let pendingAppleProductId;
        let entitlementEndMs = Number(transaction.expiresDate);
        if (data.signedRenewalInfo) {
          const renewal = await verifier.verifyAndDecodeRenewalInfo(
              data.signedRenewalInfo);
          autoRenew = Number(renewal.autoRenewStatus) === 1;
          if (Number(renewal.autoRenewStatus) !== 1) {
            pendingPlanId = null;
            pendingAppleProductId = null;
          } else if (typeof renewal.autoRenewProductId === "string" &&
              PRODUCT_PLANS[renewal.autoRenewProductId]) {
            const renewalPlanId = PRODUCT_PLANS[renewal.autoRenewProductId];
            const currentPlanId = PRODUCT_PLANS[transaction.productId];
            if (renewalPlanId === currentPlanId) {
              pendingPlanId = null;
              pendingAppleProductId = null;
            } else {
              pendingPlanId = renewalPlanId;
              pendingAppleProductId = renewal.autoRenewProductId;
            }
          }
          const gracePeriodEnd = Number(renewal.gracePeriodExpiresDate);
          if (Number.isFinite(gracePeriodEnd) &&
              gracePeriodEnd > entitlementEndMs) {
            entitlementEndMs = gracePeriodEnd;
          }
        }
        const type = notification.notificationType;
        const statusOverride = ["REFUND", "REVOKE"].includes(type) ? "revoked" :
          ["EXPIRED", "GRACE_PERIOD_EXPIRED"].includes(type) ?
            "expired" : undefined;
        await writeAppleEntitlement({
          uid,
          transaction,
          autoRenew,
          pendingPlanId,
          pendingAppleProductId,
          statusOverride,
          entitlementEndMs,
        });
        await eventRef.set({
          status: "PROCESSED",
          notificationType: type || null,
          originalTransactionId: transaction.originalTransactionId,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        return res.status(200).send("Processed");
      } catch (error) {
        console.error("[appleSubscriptionNotifications]", error.message);
        const status = applePayloadVerified ? 500 : 400;
        const message = applePayloadVerified ?
          "Temporary notification processing failure" :
          "Invalid App Store notification";
        return res.status(status).send(message);
      }
    });
