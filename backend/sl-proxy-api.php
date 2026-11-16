<?php
/**
 * Plugin Name: SL Proxy API
 * Description: REST API for the SL_Proxy iOS app: login (revocable Bearer tokens), wallet balance, live proxy list (masked), wallet purchase with live check, and 24h purchase history.
 * Version:     1.0.0
 * Author:      Sailorsloot
 *
 * HOW TO INSTALL
 *  A) As a plugin: upload this file to wp-content/plugins/sl-proxy-api/sl-proxy-api.php and activate it.
 *  B) With Code Snippets: delete the "<?php" line and the plugin header comment, paste the rest, run everywhere.
 *
 * ENDPOINTS (namespace sl-proxy/v1, HTTPS only)
 *  POST /auth/login          {login, password, device?}      -> token, username, balance
 *  POST /auth/logout         (Bearer)                         -> revokes the presented token
 *  GET  /user/balance        (Bearer)                         -> balance + account summary
 *  GET  /proxies             (Bearer)  country,state,city,zip,isp,q,page,per_page   -> MASKED rows only
 *  GET  /proxies/filters     (Bearer)                         -> distinct values for the filter sheet
 *  POST /proxies/purchase    (Bearer)  {proxy_id}             -> real SOCKS5 credentials (after live check + debit)
 *  GET  /proxies/history     (Bearer)                         -> purchases of the last 24h, still active
 *
 * PLACEHOLDER HOOKS (search for "PLUG IN HERE"): wallet balance, wallet debit/credit, live IP check.
 * The defaults below call the same functions your existing snippets use (TeraWallet and the 9Proxy
 * relay verifier). Override any of them with add_filter() or by editing the hook function.
 *
 * SECRETS: nothing secret lives in this file or in the app. The 9Proxy base username/password and the
 * relay secret stay in your existing snippet constants (SL_9PROXY_*, SL_RELAY_*) and are only ever
 * returned to the user who just paid for that session.
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

if ( ! defined( 'SL_PROXY_API_NS' ) )            define( 'SL_PROXY_API_NS', 'sl-proxy/v1' );
if ( ! defined( 'SL_PROXY_TOKEN_TTL' ) )         define( 'SL_PROXY_TOKEN_TTL', 30 * DAY_IN_SECONDS );
if ( ! defined( 'SL_PROXY_MAX_TOKENS' ) )        define( 'SL_PROXY_MAX_TOKENS', 5 );          // devices per user
if ( ! defined( 'SL_PROXY_DEFAULT_MINUTES' ) )   define( 'SL_PROXY_DEFAULT_MINUTES', 1440 );  // 24h
if ( ! defined( 'SL_PROXY_LIVE_CATEGORY' ) )     define( 'SL_PROXY_LIVE_CATEGORY', 'live-proxy' );
if ( ! defined( 'SL_PROXY_TOKEN_META' ) )        define( 'SL_PROXY_TOKEN_META', '_sl_proxy_api_tokens' );

/* =============================================================================
 * 1. ROUTES
 * ========================================================================== */
add_action( 'rest_api_init', 'sl_proxy_api_register_routes' );

function sl_proxy_api_register_routes() {
	register_rest_route( SL_PROXY_API_NS, '/auth/login', array(
		'methods'             => 'POST',
		'callback'            => 'sl_proxy_api_login',
		'permission_callback' => 'sl_proxy_api_require_https',
	) );
	register_rest_route( SL_PROXY_API_NS, '/auth/logout', array(
		'methods'             => 'POST',
		'callback'            => 'sl_proxy_api_logout',
		'permission_callback' => 'sl_proxy_api_authenticate',
	) );
	register_rest_route( SL_PROXY_API_NS, '/user/balance', array(
		'methods'             => 'GET',
		'callback'            => 'sl_proxy_api_balance',
		'permission_callback' => 'sl_proxy_api_authenticate',
	) );
	register_rest_route( SL_PROXY_API_NS, '/proxies', array(
		'methods'             => 'GET',
		'callback'            => 'sl_proxy_api_list',
		'permission_callback' => 'sl_proxy_api_authenticate',
		'args'                => array(
			'country'  => array( 'sanitize_callback' => 'sanitize_text_field' ),
			'state'    => array( 'sanitize_callback' => 'sanitize_text_field' ),
			'city'     => array( 'sanitize_callback' => 'sanitize_text_field' ),
			'zip'      => array( 'sanitize_callback' => 'sanitize_text_field' ),
			'isp'      => array( 'sanitize_callback' => 'sanitize_text_field' ),
			'q'        => array( 'sanitize_callback' => 'sanitize_text_field' ),
			'page'     => array( 'sanitize_callback' => 'absint', 'default' => 1 ),
			'per_page' => array( 'sanitize_callback' => 'absint', 'default' => 20 ),
		),
	) );
	register_rest_route( SL_PROXY_API_NS, '/proxies/filters', array(
		'methods'             => 'GET',
		'callback'            => 'sl_proxy_api_filters',
		'permission_callback' => 'sl_proxy_api_authenticate',
	) );
	register_rest_route( SL_PROXY_API_NS, '/proxies/purchase', array(
		'methods'             => 'POST',
		'callback'            => 'sl_proxy_api_purchase',
		'permission_callback' => 'sl_proxy_api_authenticate',
		'args'                => array(
			'proxy_id' => array( 'required' => true, 'sanitize_callback' => 'absint' ),
		),
	) );
	register_rest_route( SL_PROXY_API_NS, '/proxies/history', array(
		'methods'             => 'GET',
		'callback'            => 'sl_proxy_api_history',
		'permission_callback' => 'sl_proxy_api_authenticate',
	) );
}

// Never let a proxy/CDN cache our responses (they carry balances and credentials).
add_filter( 'rest_post_dispatch', function ( $response, $server, $request ) {
	if ( 0 === strpos( $request->get_route(), '/' . SL_PROXY_API_NS . '/' ) ) {
		$response->header( 'Cache-Control', 'no-store, no-cache, must-revalidate, private' );
		$response->header( 'Pragma', 'no-cache' );
	}
	return $response;
}, 10, 3 );

/* =============================================================================
 * 2. AUTH: Bearer tokens, hashed + revocable, stored in wp_usermeta
 *    Token format:  slp_<user_id>_<64 hex>   (the id lets us find the user without scanning)
 *    Stored value:  HMAC-SHA256(secret, wp_salt('auth')) + expiry. The raw token is never stored.
 * ========================================================================== */

function sl_proxy_api_is_https() {
	$ok = is_ssl()
		|| ( isset( $_SERVER['HTTP_X_FORWARDED_PROTO'] ) && 'https' === strtolower( $_SERVER['HTTP_X_FORWARDED_PROTO'] ) )
		|| ( isset( $_SERVER['HTTP_CF_VISITOR'] ) && false !== strpos( $_SERVER['HTTP_CF_VISITOR'], 'https' ) );
	return (bool) apply_filters( 'sl_proxy_api_is_https', $ok );
}

function sl_proxy_api_require_https() {
	if ( ! sl_proxy_api_is_https() ) {
		return new WP_Error( 'sl_https_required', 'HTTPS is required.', array( 'status' => 403 ) );
	}
	return true;
}

function sl_proxy_api_hash_secret( $secret ) {
	return hash_hmac( 'sha256', $secret, wp_salt( 'auth' ) );
}

function sl_proxy_api_issue_token( $user_id, $device = '' ) {
	$secret = bin2hex( random_bytes( 32 ) );
	$token  = 'slp_' . (int) $user_id . '_' . $secret;
	$now    = time();

	$tokens = get_user_meta( $user_id, SL_PROXY_TOKEN_META, true );
	$tokens = is_array( $tokens ) ? $tokens : array();
	// Drop expired entries, then keep only the newest (MAX-1) so adding one stays within the cap.
	$tokens = array_values( array_filter( $tokens, function ( $t ) use ( $now ) { return isset( $t['exp'] ) && $t['exp'] > $now; } ) );
	usort( $tokens, function ( $a, $b ) { return $b['created'] <=> $a['created']; } );
	$tokens = array_slice( $tokens, 0, max( 0, SL_PROXY_MAX_TOKENS - 1 ) );

	$exp      = $now + SL_PROXY_TOKEN_TTL;
	$tokens[] = array(
		'h'       => sl_proxy_api_hash_secret( $secret ),
		'exp'     => $exp,
		'created' => $now,
		'device'  => sanitize_text_field( mb_substr( (string) $device, 0, 60 ) ),
	);
	update_user_meta( $user_id, SL_PROXY_TOKEN_META, $tokens );

	return array( 'token' => $token, 'expires_at' => gmdate( 'Y-m-d\TH:i:s\Z', $exp ) );
}

function sl_proxy_api_read_bearer( WP_REST_Request $request ) {
	$header = $request->get_header( 'authorization' );
	if ( ! $header && ! empty( $_SERVER['HTTP_AUTHORIZATION'] ) )          $header = $_SERVER['HTTP_AUTHORIZATION'];
	if ( ! $header && ! empty( $_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ) ) $header = $_SERVER['REDIRECT_HTTP_AUTHORIZATION'];
	if ( ! $header ) $header = $request->get_header( 'x_sl_authorization' ); // fallback when a host strips Authorization
	if ( $header && preg_match( '/^\s*Bearer\s+(\S+)\s*$/i', $header, $m ) ) {
		return $m[1];
	}
	return '';
}

/** permission_callback for every authenticated route. Sets the current user on success. */
function sl_proxy_api_authenticate( WP_REST_Request $request ) {
	$https = sl_proxy_api_require_https();
	if ( is_wp_error( $https ) ) return $https;

	$unauth = new WP_Error( 'sl_unauthorized', 'Please sign in again.', array( 'status' => 401 ) );
	$raw    = sl_proxy_api_read_bearer( $request );
	if ( ! $raw || ! preg_match( '/^slp_(\d+)_([a-f0-9]{64})$/', $raw, $m ) ) return $unauth;

	$user_id = (int) $m[1];
	$hash    = sl_proxy_api_hash_secret( $m[2] );
	$tokens  = get_user_meta( $user_id, SL_PROXY_TOKEN_META, true );
	if ( ! is_array( $tokens ) ) return $unauth;

	$now = time();
	foreach ( $tokens as $t ) {
		if ( isset( $t['h'], $t['exp'] ) && $t['exp'] > $now && hash_equals( $t['h'], $hash ) ) {
			$user = get_userdata( $user_id );
			if ( ! $user ) return $unauth;
			wp_set_current_user( $user_id );
			$request->set_param( '_sl_token_hash', $hash );
			return true;
		}
	}
	return $unauth;
}

function sl_proxy_api_login( WP_REST_Request $request ) {
	$login    = trim( (string) $request->get_param( 'login' ) );
	$password = (string) $request->get_param( 'password' );
	$device   = (string) $request->get_param( 'device' );
	if ( '' === $login ) $login = trim( (string) $request->get_param( 'username' ) );

	if ( '' === $login || '' === $password ) {
		return new WP_Error( 'sl_bad_request', 'Enter your username or email and password.', array( 'status' => 400 ) );
	}

	// Throttle brute force: 8 failures per login+IP per 15 minutes.
	$ip       = isset( $_SERVER['REMOTE_ADDR'] ) ? $_SERVER['REMOTE_ADDR'] : '';
	$lock_key = 'sl_pa_fail_' . md5( strtolower( $login ) . '|' . $ip );
	$fails    = (int) get_transient( $lock_key );
	if ( $fails >= 8 ) {
		return new WP_Error( 'sl_too_many', 'Too many attempts. Try again in 15 minutes.', array( 'status' => 429 ) );
	}

	$user = wp_authenticate( $login, $password );
	if ( is_wp_error( $user ) || ! ( $user instanceof WP_User ) ) {
		set_transient( $lock_key, $fails + 1, 15 * MINUTE_IN_SECONDS );
		// One generic message: never reveal whether the account exists.
		return new WP_Error( 'sl_bad_credentials', 'Incorrect username or password.', array( 'status' => 401 ) );
	}
	delete_transient( $lock_key );

	$issued = sl_proxy_api_issue_token( $user->ID, $device );
	return rest_ensure_response( array(
		'token'           => $issued['token'],
		'expires_at'      => $issued['expires_at'],
		'username'        => $user->user_login,
		'display_name'    => $user->display_name,
		'balance'         => sl_proxy_hook_get_balance( $user->ID ),
		'currency'        => 'NGN',
		'currency_symbol' => '₦',
	) );
}

function sl_proxy_api_logout( WP_REST_Request $request ) {
	$user_id = get_current_user_id();
	$hash    = $request->get_param( '_sl_token_hash' );
	$tokens  = get_user_meta( $user_id, SL_PROXY_TOKEN_META, true );
	if ( is_array( $tokens ) && $hash ) {
		$tokens = array_values( array_filter( $tokens, function ( $t ) use ( $hash ) {
			return ! ( isset( $t['h'] ) && hash_equals( $t['h'], $hash ) );
		} ) );
		update_user_meta( $user_id, SL_PROXY_TOKEN_META, $tokens );
	}
	return rest_ensure_response( array( 'ok' => true ) );
}

/* =============================================================================
 * 3. PLACEHOLDER HOOKS: PLUG IN HERE
 *    Defaults mirror your existing 9Proxy / TeraWallet snippets.
 * ========================================================================== */

/** PLUG IN HERE: wallet balance getter. Return a float (Naira). */
function sl_proxy_hook_get_balance( $user_id ) {
	if ( function_exists( 'woo_wallet' ) && woo_wallet()->wallet ) {
		$balance = floatval( woo_wallet()->wallet->get_wallet_balance( $user_id, 'edit' ) );
	} else {
		$balance = floatval( get_user_meta( $user_id, '_current_woo_wallet_balance', true ) );
		if ( ! $balance ) $balance = floatval( get_user_meta( $user_id, '_wallet_balance', true ) );
	}
	return (float) apply_filters( 'sl_proxy_wallet_balance', $balance, $user_id );
}

/** PLUG IN HERE: wallet deduction. Return true on success, WP_Error on failure. */
function sl_proxy_hook_debit( $user_id, $amount, $note ) {
	$custom = apply_filters( 'sl_proxy_wallet_debit', null, $user_id, $amount, $note );
	if ( null !== $custom ) return $custom;

	if ( function_exists( 'woo_wallet' ) && woo_wallet()->wallet ) {
		$tx = woo_wallet()->wallet->debit( $user_id, $amount, $note, 'debit' );
		return $tx ? true : new WP_Error( 'sl_debit_failed', 'Wallet debit failed.', array( 'status' => 500 ) );
	}
	// Fallback used by your snippets when TeraWallet is not active.
	$new = sl_proxy_hook_get_balance( $user_id ) - $amount;
	if ( $new < 0 ) return new WP_Error( 'sl_insufficient', 'Insufficient wallet balance.', array( 'status' => 402 ) );
	update_user_meta( $user_id, '_current_woo_wallet_balance', $new );
	update_user_meta( $user_id, '_wallet_balance', $new );
	return true;
}

/** PLUG IN HERE: refund, used only if logging the purchase fails after the debit. */
function sl_proxy_hook_credit( $user_id, $amount, $note ) {
	$custom = apply_filters( 'sl_proxy_wallet_credit', null, $user_id, $amount, $note );
	if ( null !== $custom ) return $custom;

	if ( function_exists( 'woo_wallet' ) && woo_wallet()->wallet ) {
		return (bool) woo_wallet()->wallet->credit( $user_id, $amount, $note );
	}
	$new = sl_proxy_hook_get_balance( $user_id ) + $amount;
	update_user_meta( $user_id, '_current_woo_wallet_balance', $new );
	update_user_meta( $user_id, '_wallet_balance', $new );
	return true;
}

/**
 * PLUG IN HERE: live IP check + credential allocation. Runs BEFORE the user is charged.
 *
 * Must return array( 'success' => bool, 'error' => string,
 *   'host','port','username','password',            // the real SOCKS5 credentials
 *   'ip','city','country','isp' )                    // what the live check resolved
 *
 * Default: your existing engine. Per-product targeting from the product's custom attributes
 * (_sl_proxy_country/_state/_city/_isp), a fresh 9Proxy session, then the relay live test with
 * the SAME session retried (so one purchase never mints several 9Proxy IPs).
 * If those functions are not loaded it FAILS CLOSED (no charge, no credentials).
 */
function sl_proxy_hook_allocate_and_verify( $product_id, $user_id ) {
	$custom = apply_filters( 'sl_proxy_live_check', null, $product_id, $user_id );
	if ( is_array( $custom ) ) return $custom;

	$needed = array( 'sailorsloot_build_9proxy_username', 'sailorsloot_verify_9proxy_connection', 'sailorsloot_get_custom_attribute' );
	foreach ( $needed as $fn ) {
		if ( ! function_exists( $fn ) ) {
			return array( 'success' => false, 'error' => 'Live check is not connected yet.' );
		}
	}
	if ( ! defined( 'SL_9PROXY_BASE_USERNAME' ) || ! defined( 'SL_9PROXY_PASSWORD' ) || ! defined( 'SL_9PROXY_HOST' ) || ! defined( 'SL_9PROXY_PORT' ) ) {
		return array( 'success' => false, 'error' => 'Live check is not configured.' );
	}

	$filters = array(
		'country' => sailorsloot_get_custom_attribute( $product_id, '_sl_proxy_country' ),
		'state'   => sailorsloot_get_custom_attribute( $product_id, '_sl_proxy_state' ),
		'city'    => sailorsloot_get_custom_attribute( $product_id, '_sl_proxy_city' ),
		'isp'     => sailorsloot_get_custom_attribute( $product_id, '_sl_proxy_isp' ),
	);
	$username     = sailorsloot_build_9proxy_username( SL_9PROXY_BASE_USERNAME, $filters );
	$verification = array( 'success' => false, 'error' => 'Not attempted' );
	$delays       = array( 1, 2, 3 );

	for ( $attempt = 0; $attempt < 4; $attempt++ ) {
		if ( $attempt > 0 ) sleep( $delays[ $attempt - 1 ] );
		$verification = sailorsloot_verify_9proxy_connection( $username, SL_9PROXY_PASSWORD );
		if ( ! empty( $verification['success'] ) ) break;
	}
	if ( empty( $verification['success'] ) ) {
		return array( 'success' => false, 'error' => 'No live proxy is available for that selection right now. Please try again shortly or pick another one.' );
	}
	return array(
		'success'  => true,
		'host'     => SL_9PROXY_HOST,
		'port'     => (string) SL_9PROXY_PORT,
		'username' => $username,
		'password' => SL_9PROXY_PASSWORD,
		'ip'       => $verification['ip'],
		'city'     => $verification['city'],
		'country'  => $verification['country'],
		'isp'      => $verification['org'],
	);
}

/* =============================================================================
 * 4. HELPERS: table, title parsing, masking, formatting
 * ========================================================================== */

function sl_proxy_api_table() {
	global $wpdb;
	return $wpdb->prefix . 'sailorsloot_live_proxies'; // same table your 9Proxy engine writes to
}

function sl_proxy_api_ensure_table() {
	global $wpdb;
	$table = sl_proxy_api_table();
	// Identical schema to the one in your engine snippet, plus nothing the engine does not already create.
	$wpdb->query( "CREATE TABLE IF NOT EXISTS `$table` (
		id INT AUTO_INCREMENT PRIMARY KEY,
		user_id BIGINT NOT NULL,
		order_id BIGINT NOT NULL,
		product_id BIGINT NOT NULL,
		host VARCHAR(100) NOT NULL,
		port VARCHAR(10) NOT NULL,
		username VARCHAR(150) NOT NULL,
		password VARCHAR(100) NOT NULL,
		resolved_ip VARCHAR(50) DEFAULT NULL,
		resolved_country VARCHAR(100) DEFAULT NULL,
		resolved_city VARCHAR(100) DEFAULT NULL,
		resolved_isp VARCHAR(150) DEFAULT NULL,
		status VARCHAR(30) DEFAULT 'active',
		expires_at DATETIME NOT NULL,
		created_at DATETIME NOT NULL
	);" );
}

function sl_proxy_api_mask_ip( $ip ) {
	$ip = trim( (string) $ip );
	if ( filter_var( $ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4 ) ) {
		$o = explode( '.', $ip );
		return $o[0] . '.' . $o[1] . '.***.***';
	}
	if ( filter_var( $ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6 ) ) {
		$g = explode( ':', $ip );
		return ( isset( $g[0] ) ? $g[0] : '' ) . ':' . ( isset( $g[1] ) ? $g[1] : '' ) . ':****';
	}
	return '***.***.***.***'; // unknown format: reveal nothing
}

function sl_proxy_api_flag( $code ) {
	$code = strtoupper( trim( (string) $code ) );
	if ( 2 !== strlen( $code ) || ! ctype_alpha( $code ) ) return '🌐';
	$flag = '';
	foreach ( str_split( $code ) as $l ) $flag .= mb_chr( ord( $l ) - 65 + 127462, 'UTF-8' );
	return $flag;
}

function sl_proxy_api_country_name( $code ) {
	$code = strtoupper( (string) $code );
	if ( function_exists( 'WC' ) && WC() && isset( WC()->countries ) ) {
		$all = WC()->countries->get_countries();
		if ( isset( $all[ $code ] ) ) return html_entity_decode( $all[ $code ], ENT_QUOTES, 'UTF-8' );
	}
	return $code;
}

/** Parsed + cached (45 s) view of the live-proxy catalogue. Real IPs stay in this array only. */
function sl_proxy_api_catalogue() {
	$cached = get_transient( 'sl_proxy_api_catalogue' );
	if ( is_array( $cached ) ) return $cached;

	$q = new WP_Query( array(
		'post_type'      => 'product',
		'post_status'    => 'publish',
		'posts_per_page' => -1,
		'no_found_rows'  => true,
		'tax_query'      => array( array(
			'taxonomy' => 'product_cat',
			'field'    => 'slug',
			'terms'    => array( SL_PROXY_LIVE_CATEGORY ),
		) ),
	) );

	$rows = array();
	foreach ( $q->posts as $post ) {
		// Same layout as the web table: IP|STATE|CITY|ZIP|DOMAIN|ISP|TYPE|SPEED|PING|ADDED|CC
		$p       = array_map( 'trim', explode( '|', $post->post_title ) );
		$product = function_exists( 'wc_get_product' ) ? wc_get_product( $post->ID ) : null;
		if ( ! $product ) continue;
		$cc   = isset( $p[10] ) && '' !== $p[10] ? strtoupper( $p[10] ) : 'US';
		$ping = isset( $p[8] ) ? (int) preg_replace( '/\D+/', '', $p[8] ) : 0;
		$rows[] = array(
			'id'           => (int) $post->ID,
			'ip'           => isset( $p[0] ) ? $p[0] : '',
			'state'        => isset( $p[1] ) ? $p[1] : '',
			'city'         => isset( $p[2] ) ? $p[2] : '',
			'zip'          => isset( $p[3] ) ? $p[3] : '',
			'isp'          => isset( $p[5] ) ? $p[5] : '',
			'type'         => isset( $p[6] ) ? $p[6] : '',
			'ping_ms'      => $ping > 0 ? $ping : null,
			'country_code' => $cc,
			'price'        => (float) $product->get_price(),
			'added_ts'     => (int) get_post_time( 'U', true, $post->ID ),
		);
	}
	wp_reset_postdata();
	set_transient( 'sl_proxy_api_catalogue', $rows, 45 );
	return $rows;
}

/** The ONLY shape the list endpoint ever returns: masked IP, no port, no credentials. */
function sl_proxy_api_public_row( $r ) {
	return array(
		'id'           => $r['id'],
		'country_code' => $r['country_code'],
		'country'      => sl_proxy_api_country_name( $r['country_code'] ),
		'flag'         => sl_proxy_api_flag( $r['country_code'] ),
		'ip_masked'    => sl_proxy_api_mask_ip( $r['ip'] ),
		'state'        => $r['state'],
		'city'         => $r['city'],
		'zip'          => $r['zip'],
		'isp'          => $r['isp'],
		'type'         => $r['type'],
		'ping_ms'      => $r['ping_ms'],
		'status'       => 'live',
		'price'        => $r['price'],
		'currency'     => 'NGN',
		'added_at'     => gmdate( 'Y-m-d\TH:i:s\Z', $r['added_ts'] ),
	);
}

function sl_proxy_api_local_to_iso( $mysql_local ) {
	try {
		$d = new DateTimeImmutable( $mysql_local, wp_timezone() );
		return $d->setTimezone( new DateTimeZone( 'UTC' ) )->format( 'Y-m-d\TH:i:s\Z' );
	} catch ( Exception $e ) {
		return null;
	}
}

function sl_proxy_api_remaining( $mysql_local ) {
	try {
		$d = new DateTimeImmutable( $mysql_local, wp_timezone() );
		return max( 0, $d->getTimestamp() - time() );
	} catch ( Exception $e ) {
		return 0;
	}
}

function sl_proxy_api_purchase_payload( $row, $balance = null ) {
	$out = array(
		'purchase_id'       => (int) $row->id,
		'proxy_id'          => (int) $row->product_id,
		'type'              => 'socks5',
		'host'              => $row->host,
		'port'              => (int) $row->port,
		'username'          => $row->username,
		'password'          => $row->password,
		'ip'                => $row->resolved_ip,
		'city'              => $row->resolved_city,
		'country'           => $row->resolved_country,
		'isp'               => $row->resolved_isp,
		'expires_at'        => sl_proxy_api_local_to_iso( $row->expires_at ),
		'remaining_seconds' => sl_proxy_api_remaining( $row->expires_at ),
	);
	if ( null !== $balance ) $out['balance'] = (float) $balance;
	return $out;
}

/* =============================================================================
 * 5. ENDPOINT CALLBACKS
 * ========================================================================== */

function sl_proxy_api_balance( WP_REST_Request $request ) {
	global $wpdb;
	sl_proxy_api_ensure_table();
	$user = wp_get_current_user();
	$table = sl_proxy_api_table();
	$active = (int) $wpdb->get_var( $wpdb->prepare(
		"SELECT COUNT(*) FROM `$table` WHERE user_id = %d AND status = 'active' AND expires_at > %s",
		$user->ID, current_time( 'mysql' )
	) );
	return rest_ensure_response( array(
		'balance'         => sl_proxy_hook_get_balance( $user->ID ),
		'currency'        => 'NGN',
		'currency_symbol' => '₦',
		'account'         => array(
			'username'        => $user->user_login,
			'display_name'    => $user->display_name,
			'member_since'    => gmdate( 'Y-m-d', strtotime( $user->user_registered ) ),
			'active_proxies'  => $active,
		),
	) );
}

function sl_proxy_api_contains( $haystack, $needle ) {
	return '' === $needle || false !== mb_stripos( (string) $haystack, $needle );
}

function sl_proxy_api_list( WP_REST_Request $request ) {
	$country = strtoupper( trim( (string) $request->get_param( 'country' ) ) );
	$state   = trim( (string) $request->get_param( 'state' ) );
	$city    = trim( (string) $request->get_param( 'city' ) );
	$zip     = trim( (string) $request->get_param( 'zip' ) );
	$isp     = trim( (string) $request->get_param( 'isp' ) );
	$q       = trim( (string) $request->get_param( 'q' ) );
	$page    = max( 1, (int) $request->get_param( 'page' ) );
	$per     = min( 50, max( 1, (int) $request->get_param( 'per_page' ) ) );

	$rows = array_filter( sl_proxy_api_catalogue(), function ( $r ) use ( $country, $state, $city, $zip, $isp, $q ) {
		if ( '' !== $country && $r['country_code'] !== $country ) return false;
		if ( ! sl_proxy_api_contains( $r['state'], $state ) ) return false;
		if ( ! sl_proxy_api_contains( $r['city'], $city ) ) return false;
		if ( ! sl_proxy_api_contains( $r['zip'], $zip ) ) return false;
		if ( ! sl_proxy_api_contains( $r['isp'], $isp ) ) return false;
		if ( '' !== $q ) {
			// Free search matches the masked IP prefix the user can see, city, zip, isp, state.
			$blob = implode( ' ', array( sl_proxy_api_mask_ip( $r['ip'] ), $r['city'], $r['zip'], $r['isp'], $r['state'] ) );
			if ( ! sl_proxy_api_contains( $blob, $q ) ) return false;
		}
		return true;
	} );

	// Newest first, so fresh IPs lead the list.
	usort( $rows, function ( $a, $b ) { return $b['added_ts'] <=> $a['added_ts']; } );

	$total = count( $rows );
	$slice = array_slice( $rows, ( $page - 1 ) * $per, $per );
	return rest_ensure_response( array(
		'items'       => array_map( 'sl_proxy_api_public_row', $slice ),
		'page'        => $page,
		'per_page'    => $per,
		'total'       => $total,
		'total_pages' => (int) max( 1, ceil( $total / $per ) ),
	) );
}

function sl_proxy_api_filters( WP_REST_Request $request ) {
	$countries = $states = $cities = $isps = array();
	foreach ( sl_proxy_api_catalogue() as $r ) {
		$countries[ $r['country_code'] ] = sl_proxy_api_country_name( $r['country_code'] );
		if ( '' !== $r['state'] && '-' !== $r['state'] ) $states[ $r['state'] ] = true;
		if ( '' !== $r['city'] && '-' !== $r['city'] )   $cities[ $r['city'] ] = true;
		if ( '' !== $r['isp'] && '-' !== $r['isp'] )     $isps[ $r['isp'] ] = true;
	}
	asort( $countries );
	$keys = function ( $a ) { $k = array_keys( $a ); sort( $k, SORT_NATURAL | SORT_FLAG_CASE ); return $k; };
	$country_list = array();
	foreach ( $countries as $code => $name ) $country_list[] = array( 'code' => $code, 'name' => $name, 'flag' => sl_proxy_api_flag( $code ) );
	return rest_ensure_response( array(
		'countries' => $country_list,
		'states'    => $keys( $states ),
		'cities'    => $keys( $cities ),
		'isps'      => $keys( $isps ),
	) );
}

function sl_proxy_api_purchase( WP_REST_Request $request ) {
	global $wpdb;
	sl_proxy_api_ensure_table();

	$user_id    = get_current_user_id();
	$product_id = (int) $request->get_param( 'proxy_id' );
	$product    = $product_id ? wc_get_product( $product_id ) : null;

	$in_catalogue = $product && 'publish' === get_post_status( $product_id )
		&& has_term( SL_PROXY_LIVE_CATEGORY, 'product_cat', $product_id );
	if ( ! $in_catalogue ) {
		return new WP_Error( 'sl_not_found', 'This proxy is no longer available.', array( 'status' => 404 ) );
	}

	// One purchase per user at a time: a double tap or a retry can never double charge.
	$lock = 'sl_proxy_buy_' . $user_id;
	$got  = (int) $wpdb->get_var( $wpdb->prepare( 'SELECT GET_LOCK(%s, 3)', $lock ) );
	if ( 1 !== $got ) {
		return new WP_Error( 'sl_busy', 'A purchase is already in progress.', array( 'status' => 409 ) );
	}

	try {
		$table = sl_proxy_api_table();
		$now   = current_time( 'mysql' );

		// Already owns an active session for this listing? Return it, charge nothing.
		$existing = $wpdb->get_row( $wpdb->prepare(
			"SELECT * FROM `$table` WHERE user_id = %d AND product_id = %d AND status = 'active' AND expires_at > %s ORDER BY id DESC LIMIT 1",
			$user_id, $product_id, $now
		) );
		if ( $existing ) {
			$payload = sl_proxy_api_purchase_payload( $existing, sl_proxy_hook_get_balance( $user_id ) );
			$payload['already_owned'] = true;
			return rest_ensure_response( $payload );
		}

		$price = (float) $product->get_price();

		// STEP 1: wallet balance (re-read inside the lock).
		if ( sl_proxy_hook_get_balance( $user_id ) < $price ) {
			return new WP_Error( 'sl_insufficient', 'Insufficient wallet balance. Please top up.', array( 'status' => 402 ) );
		}

		// STEP 2: live check BEFORE charging.
		$live = sl_proxy_hook_allocate_and_verify( $product_id, $user_id );
		if ( empty( $live['success'] ) ) {
			$msg = ! empty( $live['error'] ) ? $live['error'] : 'No live proxy is available right now.';
			return new WP_Error( 'sl_not_live', $msg, array( 'status' => 503 ) );
		}

		// STEP 3: debit, then log. If the log fails the user is refunded.
		$note  = 'Live Proxy Purchase (Product #' . $product_id . ') via app';
		$debit = sl_proxy_hook_debit( $user_id, $price, $note );
		if ( true !== $debit ) {
			return is_wp_error( $debit ) ? $debit : new WP_Error( 'sl_debit_failed', 'Wallet debit failed.', array( 'status' => 500 ) );
		}

		$minutes = (int) get_post_meta( $product_id, '_sl_proxy_duration_minutes', true );
		if ( $minutes <= 0 ) $minutes = (int) apply_filters( 'sl_proxy_duration_minutes', SL_PROXY_DEFAULT_MINUTES, $product_id );
		$expires_local = wp_date( 'Y-m-d H:i:s', time() + $minutes * MINUTE_IN_SECONDS );

		$order_id = 0;
		if ( apply_filters( 'sl_proxy_create_wc_order', true ) ) {
			try {
				$order = wc_create_order();
				$order->add_product( $product, 1 );
				$order->set_customer_id( $user_id );
				$order->set_payment_method( 'wallet' );
				$order->set_payment_method_title( 'TeraWallet Deduction (app)' );
				$order->calculate_totals();
				$order->update_status( 'completed', 'Live proxy generated, verified and delivered via the SL_Proxy app.' );
				$order->save();
				$order_id = $order->get_id();
			} catch ( Exception $e ) {
				$order_id = 0; // the order record is a convenience; the purchase row is what matters
			}
		}

		$ok = $wpdb->insert( $table, array(
			'user_id'          => $user_id,
			'order_id'         => $order_id,
			'product_id'       => $product_id,
			'host'             => $live['host'],
			'port'             => (string) $live['port'],
			'username'         => $live['username'],
			'password'         => $live['password'],
			'resolved_ip'      => isset( $live['ip'] ) ? $live['ip'] : null,
			'resolved_country' => isset( $live['country'] ) ? $live['country'] : null,
			'resolved_city'    => isset( $live['city'] ) ? $live['city'] : null,
			'resolved_isp'     => isset( $live['isp'] ) ? $live['isp'] : null,
			'status'           => 'active',
			'expires_at'       => $expires_local,
			'created_at'       => $now,
		) );
		if ( ! $ok ) {
			sl_proxy_hook_credit( $user_id, $price, 'Refund: purchase could not be recorded (Product #' . $product_id . ')' );
			return new WP_Error( 'sl_log_failed', 'Could not complete the purchase. You were not charged.', array( 'status' => 500 ) );
		}

		$row = $wpdb->get_row( $wpdb->prepare( "SELECT * FROM `$table` WHERE id = %d", $wpdb->insert_id ) );
		do_action( 'sl_proxy_api_purchased', $user_id, $product_id, $row, $price );

		// STEP 4: real credentials + fresh balance.
		return rest_ensure_response( sl_proxy_api_purchase_payload( $row, sl_proxy_hook_get_balance( $user_id ) ) );
	} finally {
		$wpdb->query( $wpdb->prepare( 'SELECT RELEASE_LOCK(%s)', $lock ) );
	}
}

function sl_proxy_api_history( WP_REST_Request $request ) {
	global $wpdb;
	sl_proxy_api_ensure_table();
	$table = sl_proxy_api_table();
	$user_id = get_current_user_id();
	$since = wp_date( 'Y-m-d H:i:s', time() - DAY_IN_SECONDS );

	$rows = $wpdb->get_results( $wpdb->prepare(
		"SELECT * FROM `$table` WHERE user_id = %d AND status = 'active' AND expires_at > %s AND created_at >= %s ORDER BY expires_at DESC LIMIT 100",
		$user_id, current_time( 'mysql' ), $since
	) );

	$items = array();
	foreach ( (array) $rows as $row ) {
		$item          = sl_proxy_api_purchase_payload( $row );
		$item['label'] = trim( ( $row->resolved_city ? $row->resolved_city . ', ' : '' ) . ( $row->resolved_country ? $row->resolved_country : '' ), ' ,' );
		$item['purchased_at'] = sl_proxy_api_local_to_iso( $row->created_at );
		$items[] = $item;
	}
	return rest_ensure_response( array( 'items' => $items, 'balance' => sl_proxy_hook_get_balance( $user_id ) ) );
}

/* =============================================================================
 * 6. MAINTENANCE: forget expired tokens once a day
 * ========================================================================== */
add_action( 'sl_proxy_api_gc', function () {
	global $wpdb;
	$ids = $wpdb->get_col( $wpdb->prepare( "SELECT DISTINCT user_id FROM {$wpdb->usermeta} WHERE meta_key = %s", SL_PROXY_TOKEN_META ) );
	$now = time();
	foreach ( (array) $ids as $uid ) {
		$t = get_user_meta( $uid, SL_PROXY_TOKEN_META, true );
		if ( ! is_array( $t ) ) continue;
		$t = array_values( array_filter( $t, function ( $x ) use ( $now ) { return isset( $x['exp'] ) && $x['exp'] > $now; } ) );
		if ( $t ) update_user_meta( $uid, SL_PROXY_TOKEN_META, $t ); else delete_user_meta( $uid, SL_PROXY_TOKEN_META );
	}
} );
add_action( 'init', function () {
	if ( ! wp_next_scheduled( 'sl_proxy_api_gc' ) ) wp_schedule_event( time() + HOUR_IN_SECONDS, 'daily', 'sl_proxy_api_gc' );
} );
