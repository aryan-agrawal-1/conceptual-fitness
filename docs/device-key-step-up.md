# Native device-key step-up

Export and account deletion use proof of possession of the app session's P-256 device key.
Google OAuth establishes identity for sign-in, legacy-session enrollment, and deletion recovery;
it is not treated as recent-authentication evidence and no `auth_time` or `max_age` claim is required.

## Key binding

- Capable devices create a Secure Enclave P-256 key before normal Google sign-in and send its
  standard-base64, 65-byte uncompressed X9.63 public key as `device_public_key`.
- OAuth state carries the normalized key into a one-use app authorization code. `/auth/exchange`
  verifies a standard-base64 DER ECDSA-SHA256 signature before atomically consuming that code and
  stores the immutable public key on the new app session.
- Simulators and devices without the required native capability may omit the public key and receive
  an unbound session for ordinary app use. Protected actions return
  `device_key_enrollment_required` for that session.
- A legacy unbound session can enroll only through same-account Google OAuth with purpose
  `enroll_device`. Successful signed exchange creates a bound session and revokes the source
  session; failed OAuth or proof leaves the source session active. There is no bearer-token key
  registration or replacement endpoint.

## Protected actions

`POST /auth/device/challenge` creates a random five-minute challenge bound to the user, app session,
stored public key, and requested purpose. `POST /auth/device/authorize` verifies the device signature
and marks that challenge authorized once. Export or deletion then consumes the same grant once and
requires the exact bound session and device. Both device-proof endpoints are rate limited.

All signed transcripts use UTF-8 fields, each prefixed by a four-byte unsigned big-endian length.
The first field is `conceptual-fitness/device-proof/v1`.

- App-code exchange: domain, `auth-code-exchange`, raw app code, device ID.
- Sensitive action: domain, `sensitive-action`, purpose, session ID, raw challenge.
- Recovery: domain, `account-recovery`, raw recovery grant, device ID.

## Deletion recovery

During the existing 14-day recovery window, same-account Google OAuth may start recovery on any
device and binds that device's new public key to the recovery grant. The recovery endpoint verifies
the new key's signature before atomically consuming the grant, restores the account, and issues a
new key-bound session. Previously revoked sessions remain revoked.

## Verification

Backend coverage includes key parsing, signed exchange without premature code consumption, typed
legacy enrollment, challenge replay and session binding, rejection of legacy unbound grants, signed
recovery, and an isolated upgrade/downgrade migration roundtrip.

Final checks: 168 backend tests, 24 focused account/auth/export tests, Ruff, isolated migration roundtrip, and iOS simulator build passed. The iOS/backend transcript bytes matched. Physical Face ID, passcode fallback, and Secure Enclave signing remain unverified because the user explicitly deferred hardware testing. The simulator has no software-key bypass. Physical-device checks are tracked in #57, the final milestone of delivery tracker #51.

Session creation for sign-in and recovery locks and refreshes the user row until the new session commits, using the same account lock as deletion. Regression tests reject issuance when another database session schedules deletion while the user is cached. Separate concurrency checks against an isolated PostgreSQL 16 cluster reproduced both original races and verified that deletion waits for issuance, revokes the resulting session, and leaves it revoked after recovery.
