<?php
/**
 * license-check.php (https://github.com/webmin/webmin-ci-cd)
 * Copyright Ilia Ross <ilia@webmin.dev>
 * Licensed under the MIT License
 *
 * HTTP endpoint for license validation. Designed to be called by
 * mod_authnz_external via a bash script on the repo server.
 *
 * Accepts HTTP Basic Auth with serial_id as username and license_key as
 * password. Checks credentials against MariaDB and verifies the license
 * hasn't expired (with a configurable grace period).
 * 
 * Uses Valkey for caching valid/invalid auth results and rate limiting
 * per IP+serial to prevent brute force attacks. Falls back gracefully if
 * Valkey is unavailable.
 *
 * Response codes:
 *   200 - License valid
 *   401 - Invalid credentials or expired license
 *   403 - IP not in allowlist or secret mismatch
 *   429 - Rate limited (too many attempts)
 *   503 - Database unavailable or cannot be connected using provided DSN
 *
 * Response headers:
 *   X-License: valid|invalid|expired
 *   X-Cache-Status: cached|fresh|bypass
 *   X-Cache-TTL: (time remaining, e.g., 4m30s)
 *   X-Cache-Via: socket|tcp
 *   X-RateLimit-Status: blocked (only on 429)
 *   X-RateLimit-Retry: (time remaining)
 *   X-RateLimit-Via: socket|tcp
 *   X-Forbidden-Reason: ip-not-allowed|secret-mismatch (only on 403)
 */

declare(strict_types=1);

// Database
const DB_DSN    = 'mysql:host=127.0.0.1;dbname=database;';
const DB_USER   = 'user';
const DB_PASS   = 'password';
const DB_TABLE  = 'table';

// Valkey (tries unix socket first, falls back to TCP)
const VALKEY_SOCKET = '/run/valkey/valkey.sock';
const VALKEY_HOST   = '127.0.0.1';
const VALKEY_PORT   = 6379;

// Timing
const GRACE_DAYS        = 7;    // days after expiry to still allow access
const CACHE_OK_TTL      = 600;  // cache valid auth for 10 minutes
const CACHE_FAIL_TTL    = 45;   // cache invalid auth for 45 seconds
const RATE_LIMIT_WINDOW = 3;    // initial seconds between attempts per IP+serial
const RATE_LIMIT_MAX    = 90;   // max block time after repeated failures

// Repo server must send this secret (unless empty) to trust X-Auth-IP header
const AUTH_SECRET = 'SECRET';

// Only these IPs can use this endpoint (empty to allow all and rely on secret)
const ALLOWED_IPS = [
	'127.0.0.1',
	'::1',
];

/**
 * Format TTL for display
 */
function formatTtl(int $seconds): string
{
	if ($seconds >= 60) {
		$m = intdiv($seconds, 60);
		$s = $seconds % 60;
		return $s > 0 ? "{$m}m{$s}s" : "{$m}m";
	}
	return "{$seconds}s";
}

/**
 * Deny access without prompting for credentials. Used for bad credentials, rate
 * limiting, or failed checks.
 */
function deny(bool $cached, int $ttl, ?string $connType, string $reason = 'invalid'): never
{
	http_response_code(401);
	header('Cache-Control: no-store');
	header('X-License: ' . $reason);
	if ($connType === null) {
		header('X-Cache-Status: bypass');
	} else {
		header('X-Cache-Status: ' . ($cached ? 'cached' : 'fresh'));
		header('X-Cache-TTL: ' . formatTtl($ttl));
		header('X-Cache-Via: ' . $connType);
	}
	exit;
}

/**
 * Forbid access. Used when IP is not in allowlist or secret mismatch.
 */
function forbidden(string $reason = 'denied'): never
{
	http_response_code(403);
	header('Cache-Control: no-store');
	header('X-Forbidden-Reason: ' . $reason);
	exit;
}

/**
 * Too many requests. Used when rate limited.
 */
function tooManyRequests(int $retryAfter, string $connType): never
{
	http_response_code(429);
	header('Retry-After: ' . $retryAfter);
	header('Cache-Control: no-store');
	header('X-RateLimit-Status: blocked');
	header('X-RateLimit-Retry: ' . formatTtl($retryAfter));
	header('X-RateLimit-Via: ' . $connType);
	exit;
}

/**
 * Service unavailable. Used when DB is down.
 */
function serviceUnavailable(): never
{
	http_response_code(503);
	header('Retry-After: 5');
	header('Cache-Control: no-store');
	exit;
}

/**
 * Deny access and prompt for credentials.
 * Used when no credentials were provided.
 */
function denyNoCredentials(): never
{
	http_response_code(401);
	header('WWW-Authenticate: Basic realm="License Required"');
	header('Cache-Control: no-store');
	exit;
}

/**
 * Allow access. License is valid.
 */
function allow(bool $cached, int $ttl, ?string $connType): never
{
	http_response_code(200);
	header('Cache-Control: no-store');
	header('X-License: valid');
	if ($connType === null) {
		header('X-Cache-Status: bypass');
	} else {
		header('X-Cache-Status: ' . ($cached ? 'cached' : 'fresh'));
		header('X-Cache-TTL: ' . formatTtl($ttl));
		header('X-Cache-Via: ' . $connType);
	}
	exit;
}

/**
 * Main entry point. Validates the request and checks the license.
 * Checks IP allowlist, rate limits, caches, and finally the database.
 */
function main(): void
{
	// Check IP allowlist first
	if (ALLOWED_IPS !== []) {
		$remoteAddr = $_SERVER['REMOTE_ADDR'] ?? '';
		if (!in_array($remoteAddr, ALLOWED_IPS, true)) {
			forbidden('ip-not-allowed');
		}
	}

	// Check auth secret and reject wrong secret
	if (AUTH_SECRET !== '') {
		$providedSecret = $_SERVER['HTTP_X_AUTH_SECRET'] ?? '';
		if ($providedSecret !== AUTH_SECRET) {
			forbidden('secret-mismatch');
		}
	}

	// Get credentials from HTTP Basic Auth
	$serialId   = $_SERVER['PHP_AUTH_USER'] ?? '';
	$licenseKey = $_SERVER['PHP_AUTH_PW'] ?? '';

	if ($serialId === '' || $licenseKey === '') {
		denyNoCredentials();
	}

	// Reject oversized input
	if (strlen($serialId) > 16 || strlen($licenseKey) > 16) {
		deny(false, CACHE_FAIL_TTL, null, 'invalid');
	}

	// Figure out client IP but trust X-Auth-IP only if secret matches
	$clientIp = $_SERVER['REMOTE_ADDR'] ?? '0.0.0.0';
	if (AUTH_SECRET !== '' && ($_SERVER['HTTP_X_AUTH_SECRET'] ?? '') === AUTH_SECRET) {
		$headerIp = trim($_SERVER['HTTP_X_AUTH_IP'] ?? '');
		if ($headerIp !== '') {
			$firstIp = str_contains($headerIp, ',')
				? trim(explode(',', $headerIp)[0])
				: $headerIp;
			if (filter_var($firstIp, FILTER_VALIDATE_IP)) {
				$clientIp = $firstIp;
			}
		}
	}

	// Build cache keys
	$credHash     = hash('sha256', "{$serialId}\0{$licenseKey}");
	$cacheOkKey   = "license_auth:ok:{$credHash}";
	$cacheFailKey = "license_auth:fail:{$credHash}";
	$rateLimitKey = "license_auth:rl:" . hash('sha256', "{$clientIp}\0{$serialId}");

	// Connect to Valkey
	$connType = null;
	$valkey = connectValkey($connType);

	// Check OK cache first - valid licenses skip rate limiting
	if ($valkey !== null) {
		try {
			if ($valkey->exists($cacheOkKey)) {
				$ttl = $valkey->ttl($cacheOkKey);
				allow(true, $ttl > 0 ? $ttl : CACHE_OK_TTL, $connType);
			}
		} catch (Throwable) {}
	}

	// Rate limit check only applies to potentially invalid attempts
	if ($valkey !== null && RATE_LIMIT_WINDOW > 0) {
		try {
			$penaltyKey = "license_auth:pen:" . hash('sha256', "{$clientIp}\0{$serialId}");
			
			if ($valkey->set($rateLimitKey, '1', ['nx', 'ex' => RATE_LIMIT_WINDOW]) === false) {
				// Already rate limited, just bump penalty and extend block time
				$penalty = (int)$valkey->incr($penaltyKey);
				$valkey->expire($penaltyKey, RATE_LIMIT_MAX * 2);
				
				// Calculate new block time, like 3, 6, 9... capped at max
				$blockTime = min(RATE_LIMIT_WINDOW * $penalty, RATE_LIMIT_MAX);
				$valkey->expire($rateLimitKey, $blockTime);
				
				$ttl = $valkey->ttl($rateLimitKey);
				tooManyRequests($ttl > 0 ? $ttl : $blockTime, $connType);
			}
		} catch (Throwable) {}
	}

	// Check fail cache, after rate limit so repeated failures are throttled
	if ($valkey !== null) {
		try {
			$cachedReason = $valkey->get($cacheFailKey);
			if ($cachedReason !== false) {
				$ttl = $valkey->ttl($cacheFailKey);
				$reason = strtolower($cachedReason) ?: 'invalid';
				deny(true, $ttl > 0 ? $ttl : CACHE_FAIL_TTL, $connType, $reason);
			}
		} catch (Throwable) {}
	}

	// Check database
	$result = checkLicense($serialId, $licenseKey);

	// DB error
	if ($result === null) {
		serviceUnavailable();
	}

	// Cache the result
	if ($valkey !== null) {
		try {
			if ($result === 'valid') {
				if (CACHE_OK_TTL > 0) {
					$valkey->setex($cacheOkKey, CACHE_OK_TTL, '1');
				}
				// Reset penalty on success so future typos don't start from high penalty
				$penaltyKey = "license_auth:pen:" . hash('sha256', "{$clientIp}\0{$serialId}");
				$valkey->del($penaltyKey);
			} else {
				if (CACHE_FAIL_TTL > 0) {
					// Store reason in cache value
					$valkey->setex($cacheFailKey, CACHE_FAIL_TTL, $result);
				}
			}
		} catch (Throwable) {}
	}

	if ($result === 'valid') {
		allow(false, CACHE_OK_TTL, $connType);
	} else {
		deny(false, CACHE_FAIL_TTL, $connType, strtolower($result));
	}
}

/**
 * Connect to Valkey. Prefers unix socket if available.
 * Returns null if connection fails (script continues without caching).
 * Sets $connType to 'SOCK', 'TCP', or leaves as null on failure.
 */
function connectValkey(?string &$connType): ?Redis
{
	$connType = null;

	if (!class_exists('Redis')) {
		return null;
	}

	try {
		$redis = new Redis();

		if (VALKEY_SOCKET !== '' && file_exists(VALKEY_SOCKET)) {
			if (!@$redis->connect(VALKEY_SOCKET, 0, 0.2)) {
				return null;
			}
			$connType = 'socket';
		} else {
			if (!@$redis->connect(VALKEY_HOST, VALKEY_PORT, 0.2)) {
				return null;
			}
			$connType = 'tcp';
		}

		$redis->setOption(Redis::OPT_READ_TIMEOUT, 0.2);
		
		// Test connection with ping
		$ping = $redis->ping();
		if ($ping !== true && $ping !== '+PONG' && $ping !== 'PONG') {
			$connType = null;
			return null;
		}

		return $redis;
	} catch (Throwable) {
		$connType = null;
		return null;
	}
}

/**
 * Check if the license is valid in the database.
 * Returns 'valid' if license exists and not expired.
 * Returns 'invalid' if serial_id + license_key not found.
 * Returns 'expired' if found but past end_date + grace period.
 * Returns null on DB error.
 */
function checkLicense(string $serialId, string $licenseKey): ?string
{
	try {
		$pdo = new PDO(DB_DSN, DB_USER, DB_PASS, [
			PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
			PDO::ATTR_EMULATE_PREPARES   => false,
			PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
			PDO::ATTR_TIMEOUT            => 3,
		]);

		$sql = 'SELECT end_date FROM `' . DB_TABLE . '`
				WHERE serial_id = :serial_id AND license_key = :license_key
				LIMIT 1';

		$stmt = $pdo->prepare($sql);
		$stmt->execute([
			':serial_id'   => $serialId,
			':license_key' => $licenseKey,
		]);

		$row = $stmt->fetch();
		if ($row === false) {
			return 'invalid';
		}

		$endDate = $row['end_date'] ?? null;

		// Null or zero date means lifetime license
		if (
			$endDate === null ||
			$endDate === '' ||
			$endDate === '0000-00-00' ||
			$endDate === '0000-00-00 00:00:00'
		) {
			return 'valid';
		}

		// Check if: end_date + grace period >= now
		$endTs = strtotime($endDate);
		if ($endTs === false) {
			return 'invalid';
		}

		if (time() <= ($endTs + (GRACE_DAYS * 86400))) {
			return 'valid';
		}

		return 'expired';

	} catch (Throwable) {
		return null;
	}
}

main();
