/** Shared renderer delivery/recovery bounds.
 *
 * // ponytail: coordinate these limits with the protocol/native-helper wire
 * // limits and Swift PendingEchoStore. Change the policy and its byte-boundary
 * // and eviction tests together before raising any bound.
 */
export const CHAT_DELIVERY_MAX_RECORDS_PER_SCOPE = 256;
export const CHAT_DELIVERY_MAX_SCOPES = 32;
export const CHAT_DELIVERY_MAX_SNAPSHOT_BYTES = 128 * 1024 * 1024;
export const CHAT_DELIVERY_MAX_SEEN_CANONICAL_IDS = 512;
export const CHAT_DELIVERY_MAX_RECOVERY_ERROR_BYTES = 4096;
export const CHAT_DELIVERY_MAX_RETRY_IDENTITIES = 512;
