<?php
/**
 * repo-auth-check.php (https://github.com/webmin/webmin-ci-cd)
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
 *   X-Client-IP: (client IP used for rate limiting)
 *   X-Cache-Status: cached|fresh|bypass
 *   X-Cache-TTL: (time remaining, e.g., 4m30s)
 *   X-Cache-Via: socket|tcp
 *   X-RateLimit-Status: blocked (only on 429)
 *   X-RateLimit-Retry: (time remaining)
 *   X-RateLimit-Via: socket|tcp
 *   X-Forbidden-Reason: ip-not-allowed|secret-mismatch (only on 403)
 *
 * Logging (when LOG_ENABLED = true):
 *   Writes to $HOME/logs/api-license-repo.log
 *   Format: [timestamp] code client_ip serial status [extra]
 *
 * Config:
 *   Loaded from $HOME/.config/repo-auth-check.conf or fails with 500 if missing
 */

declare(strict_types=1);

// Load config from ~/.config/repo-auth-check.conf
$home = $_SERVER['HOME'] ?? getenv('HOME');
$configFile = "{$home}/.config/repo-auth-check.conf";
if (!$home || !file_exists($configFile)) {
	http_response_code(500);
	exit;
}
require $configFile;

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
 * Write log entry if logging is enabled
 */
function writeLog(int $code, string $clientIp, string $status, string $extra = ''): void
{
	if (!LOG_ENABLED) {
		return;
	}

	$home = $_SERVER['HOME'] ?? getenv('HOME') ?: '/tmp';
	$logDir = "{$home}/logs";
	$logFile = "{$logDir}/api-license-repo.log";

	// Create log directory if needed
	if (!is_dir($logDir)) {
		@mkdir($logDir, 0750, true);
	}

	$timestamp = date('Y-m-d H:i:s');
	$serial = $_SERVER['PHP_AUTH_USER'] ?? '-';
	$extra = $extra !== '' ? " {$extra}" : '';
	
	$line = "[{$timestamp}] {$code} {$clientIp} {$serial} {$status}{$extra}\n";
	
	@file_put_contents($logFile, $line, FILE_APPEND | LOCK_EX);
}

/**
 * Deny access without prompting for credentials. Used for bad credentials, rate
 * limiting, or failed checks.
 */
function deny(bool $cached, int $ttl, ?string $connType, string $clientIp, string $reason = 'invalid'): never
{
	$cacheInfo = $connType === null
		? 'bypass'
		: ($cached
			? 'cached'
			: 'fresh') . ' ' . formatTtl($ttl) . ' [' . $connType . ']';
	writeLog(401, $clientIp, $reason, $cacheInfo);
	
	http_response_code(401);
	header('Cache-Control: no-store');
	header('X-License: ' . $reason);
	header('X-Client-IP: ' . $clientIp);
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
function forbidden(string $reason, string $clientIp): never
{
	writeLog(403, $clientIp, $reason);
	
	http_response_code(403);
	header('Cache-Control: no-store');
	header('X-Forbidden-Reason: ' . $reason);
	header('X-Client-IP: ' . $clientIp);
	exit;
}

/**
 * Too many requests. Used when rate limited.
 */
function tooManyRequests(int $retryAfter, string $connType, string $clientIp): never
{
	writeLog(429, $clientIp, 'rate-limited',
	         formatTtl($retryAfter) . ' [' . $connType . ']');
	
	http_response_code(429);
	header('Retry-After: ' . $retryAfter);
	header('Cache-Control: no-store');
	header('X-RateLimit-Status: blocked');
	header('X-RateLimit-Retry: ' . formatTtl($retryAfter));
	header('X-RateLimit-Via: ' . $connType);
	header('X-Client-IP: ' . $clientIp);
	exit;
}

/**
 * Service unavailable. Used when DB is down.
 */
function serviceUnavailable(string $clientIp): never
{
	writeLog(503, $clientIp, 'db-unavailable');
	
	http_response_code(503);
	header('Retry-After: 5');
	header('Cache-Control: no-store');
	exit;
}

/**
 * Deny access and prompt for credentials.
 * Used when no credentials were provided.
 */
function denyNoCredentials(string $clientIp): never
{
	writeLog(401, $clientIp, 'no-credentials');
	
	http_response_code(401);
	header('WWW-Authenticate: Basic realm="License Required"');
	header('Cache-Control: no-store');
	exit;
}

/**
 * Allow access. License is valid.
 */
function allow(bool $cached, int $ttl, ?string $connType, string $clientIp): never
{
	$cacheInfo = $connType === null
		? 'bypass'
		: ($cached
			? 'cached'
			: 'fresh') . ' ' . formatTtl($ttl) . ' [' . $connType . ']';
	writeLog(200, $clientIp, 'valid', $cacheInfo);
	
	http_response_code(200);
	header('Cache-Control: no-store');
	header('X-License: valid');
	header('X-Client-IP: ' . $clientIp);
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
	// Remove identifying headers
	header_remove('X-Powered-By');

	// Set initial client IP from remote addr
	$clientIp = $_SERVER['REMOTE_ADDR'] ?? '0.0.0.0';

	// Check IP allowlist first
	if (ALLOWED_IPS !== []) {
		if (!in_array($clientIp, ALLOWED_IPS, true)) {
			forbidden('ip-not-allowed', $clientIp);
		}
	}

	// Check auth secret and reject wrong secret
	if (AUTH_SECRET !== '') {
		$providedSecret = $_SERVER['HTTP_X_AUTH_SECRET'] ?? '';
		if ($providedSecret !== AUTH_SECRET) {
			forbidden('secret-mismatch', $clientIp);
		}
	}

	// Get credentials from HTTP Basic Auth
	$serialId   = $_SERVER['PHP_AUTH_USER'] ?? '';
	$licenseKey = $_SERVER['PHP_AUTH_PW'] ?? '';

	if ($serialId === '' || $licenseKey === '') {
		denyNoCredentials($clientIp);
	}

	// Reject oversized input
	if (strlen($serialId) > 16 || strlen($licenseKey) > 16) {
		deny(false, CACHE_FAIL_TTL, null, $clientIp, 'invalid');
	}

	// Trust X-Auth-IP only if secret matches
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
	$cacheOkKey   = "repo_auth:ok:{$credHash}";
	$cacheFailKey = "repo_auth:fail:{$credHash}";
	$rateLimitKey = "repo_auth:rl:" . hash('sha256', "{$clientIp}\0{$serialId}");

	// Connect to Valkey
	$connType = null;
	$valkey = connectValkey($connType);

	// Check OK cache first - valid licenses skip rate limiting
	if ($valkey !== null) {
		try {
			if ($valkey->exists($cacheOkKey)) {
				$ttl = $valkey->ttl($cacheOkKey);
				allow(true, $ttl > 0 ? $ttl : CACHE_OK_TTL, $connType, $clientIp);
			}
		} catch (Throwable) {}
	}

	// Rate limit check only applies to potentially invalid attempts
	if ($valkey !== null && RATE_LIMIT_WINDOW > 0) {
		try {
			$penaltyKey = "repo_auth:pen:" . hash('sha256', "{$clientIp}\0{$serialId}");
			
			if ($valkey->set($rateLimitKey, '1', ['nx', 'ex' => RATE_LIMIT_WINDOW]) === false) {
				// Already rate limited, just bump penalty and extend block time
				$penalty = (int)$valkey->incr($penaltyKey);
				$valkey->expire($penaltyKey, RATE_LIMIT_MAX * 2);
				
				// Calculate new block time, like 3, 6, 9... capped at max
				$blockTime = min(RATE_LIMIT_WINDOW * $penalty, RATE_LIMIT_MAX);
				$valkey->expire($rateLimitKey, $blockTime);
				
				$ttl = $valkey->ttl($rateLimitKey);
				tooManyRequests($ttl > 0 ? $ttl : $blockTime, $connType, $clientIp);
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
				deny(true, $ttl > 0 ? $ttl : CACHE_FAIL_TTL, $connType, $clientIp, $reason);
			}
		} catch (Throwable) {}
	}

	// Check database
	$result = checkLicense($serialId, $licenseKey);

	// DB error
	if ($result === null) {
		serviceUnavailable($clientIp);
	}

	// Cache the result
	if ($valkey !== null) {
		try {
			if ($result === 'valid') {
				if (CACHE_OK_TTL > 0) {
					$valkey->setex($cacheOkKey, CACHE_OK_TTL, '1');
				}
				// Reset penalty on success so future typos don't start from high penalty
				$penaltyKey = "repo_auth:pen:" . hash('sha256', "{$clientIp}\0{$serialId}");
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
		allow(false, CACHE_OK_TTL, $connType, $clientIp);
	} else {
		deny(false, CACHE_FAIL_TTL, $connType, $clientIp, strtolower($result));
	}
}

/**
 * Connect to Valkey. Prefers unix socket if available.
 * Returns null if connection fails (script continues without caching).
 * Sets $connType to 'socket', 'tcp', or leaves as null on failure.
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
