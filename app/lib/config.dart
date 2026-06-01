/// App-wide build flags.
library;

/// Whether ads are shown (and the ads SDK initialized). Off for now — the app
/// ships ad-free. The AdMob banner + the one-time "remove ads" IAP code is kept
/// behind this flag so it can be switched back on later without re-plumbing.
const bool kAdsEnabled = false;
