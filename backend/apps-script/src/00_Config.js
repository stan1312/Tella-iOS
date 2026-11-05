/**
 * SPECTRE Capture — deposit-only backend (Google Apps Script).
 * Policy defaults. Owner-specific values (folder id, etc.) live in Script
 * Properties, never in source control.
 */
var SPECTRE_VERSION = '0.1.0';

var SPECTRE_POLICY = {
  maxFileBytes: 20 * 1024 * 1024 * 1024,          // 20 GiB per capture
  dailyBytesPerDevice: 60 * 1024 * 1024 * 1024,   // 60 GiB / device / UTC day
  dailyUploadsPerDevice: 300,
  maxOpenUploadsPerDevice: 25,
  requestsPerMinutePerDevice: 60,
  enrollRequestsPerMinute: 10,                    // global, anti brute-force
  clockSkewSec: 600,
  nonceTtlSec: 1800,
  inviteTtlHours: 48,
  deviceTtlDays: 180,
  sessionMaxAgeSec: 6 * 24 * 3600,                // Drive sessions last ~1 week
  pendingBeforeMd5Fallback: 3,                    // finalize calls without sha256 before md5+size is accepted
  pendingRetryAfterSec: 20,
  acceptMd5Fallback: true,
  purgeVerifiedAfterDays: 30,
  allowedMime: { 'video/quicktime': 'mov', 'video/mp4': 'mp4' }
};

var SPECTRE_DRIVE_FIELDS = 'id,name,size,md5Checksum,sha256Checksum,parents,appProperties,trashed,mimeType';
