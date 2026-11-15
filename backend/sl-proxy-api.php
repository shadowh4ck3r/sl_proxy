<?php
/**
 * Plugin Name: SL Proxy API
 * Description: REST API for the SL_Proxy iOS app (namespace sl-proxy/v1): account login with revocable
 *              Bearer tokens, wallet balance, the live proxy list (masked IPs only), one-tap purchase
 *              and the 24 hour purchase history. Reuses the existing live-proxy engine and TeraWallet.
 * Version:     1.0.0
 * Author:      Sailorsloot
 *
 * INSTALL: upload as wp-content/plugins/sl-proxy-api/sl-proxy-api.php and activate. It needs the
 * "9Proxy Live Allocation Engine" and "live proxy table" snippets to stay active (it calls their
 * helper functions; see the PLUG-IN HOOKS below to replace them).
 *
 * ENDPOINTS (all JSON, HTTPS only in production)
 *   POST /wp-json/sl-proxy/v1/auth/login        {username, password, device?}   -> token + balance
 *   POST /wp-json/sl-proxy/v1/auth/logout       (Bearer)                         -> revokes this token
 *   GET  /wp-json/sl-proxy/v1/user/balance      (Bearer)
 *   GET  /wp-json/sl-proxy/v1/proxies           (Bearer)  q,country,state,city,zip,isp,page,per_page
 *   GET  /wp-json/sl-proxy/v1/proxies/filters   (Bearer)  country?,state?  -> values for the filter modal
 *   POST /wp-json/sl-proxy/v1/proxies/purchase  (Bearer)  {proxy_id}
 *   GET  /wp-json/sl-proxy/v1/proxies/history   (Bearer)
 *
 * PLUG-IN HOOKS (filters; return null to use the built-in TeraWallet / 9Proxy implementation)
 *   sl_proxy_api_wallet_balance ( null, $user_id )                       -> float
 *   sl_proxy_api_wallet_debit   ( null, $user_id, $amount, $note )       -> bool
 *   sl_proxy_api_wallet_credit  ( null, $user_id, $amount, $note )       -> bool  (refund)
 *   sl_proxy_api_allocate_live  ( null, $product_id )                    -> array(host, port, username,
 *                                  password, ip, country, city, isp) or WP_Error  (your live IP check)
 *
 * SECURITY NOTES
 *   - Tokens are random, shown once, stored only as SHA-256 hashes in usermeta with an expiry, and can
 *     be revoked (logout or deleting the usermeta row sl_proxy_api_tokens).
 *   - The list endpoint never returns the real IP, port, username or password.
 *   - Real credentials are only returned by purchase and history, to the buying user.
 *   - Do NOT put secrets in the app. Keep the 9Proxy and relay secrets in wp-config.php.
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

final class SL_Proxy_API {

	const NS          = 'sl-proxy/v1';
	const TOKEN_META  = 'sl_proxy_api_tokens';
	const TOKEN_TTL   = 2592000; // 30 days.
	const MAX_TOKENS  = 8;       // Devices per account; the oldest token is dropped beyond this.
	const CATEGORY    = 'live-proxy';
	const CACHE_KEY   = 'sl_proxy_api_listings_v1';
	const CACHE_TTL   = 30;      // Seconds the parsed list is cached.

	/** @var int Authenticated user for the current request. */
	private static $uid = 0;
	/** @var string Hash of the token used for the current request. */
	private static $token_hash = '';

	public static function init() {
		add_action( 'rest_api_init', array( __CLASS__, 'routes' ) );
	}

	/* ------------------------------------------------------------------ *
	 * Routes
	 * ------------------------------------------------------------------ */
	public static function routes() {
		$auth = array( __CLASS__, 'authenticate' );

		register_rest_route( self::NS, '/auth/login', array(
			'methods'             => 'POST',
			'callback'            => array( __CLASS__, 'login' ),
			'permission_callback' => '__return_true',
		) );
		register_rest_route( self::NS, '/auth/logout', array(
			'methods'             => 'POST',
			'callback'            => array( __CLASS__, 'logout' ),
			'permission_callback' => $auth,
		) );
		register_rest_route( self::NS, '/user/balance', array(
			'methods'             => 'GET',
			'callback'            => array( __CLASS__, 'balance' ),
			'permission_callback' => $auth,
		) );
		register_rest_route( self::NS, '/proxies', array(
			'methods'             => 'GET',
			'callback'            => array( __CLASS__, 'proxies' ),
			'permission_callback' => $auth,
		) );
		register_rest_route( self::NS, '/proxies/filters', array(
			'methods'             => 'GET',
			'callback'            => array( __CLASS__, 'filters' ),
			'permission_callback' => $auth,
		) );
		register_rest_route( self::NS, '/proxies/purchase', array(
			'methods'             => 'POST',
			'callback'            => array( __CLASS__, 'purchase' ),
			'permission_callback' => $auth,
			'args'                => array(
				'proxy_id' => array(
					'required'          => true,
					'sanitize_callback' => 'absint',
					'validate_callback' => function ( $v ) {
						return is_numeric( $v ) && (int) $v > 0;
					},
				),
			),
		) );
		register_rest_route( self::NS, '/proxies/history', array(
			'methods'             => 'GET',
			'callback'            => array( __CLASS__, 'history' ),
			'permission_callback' => $auth,
		) );
	}

	/* ------------------------------------------------------------------ *
	 * Responses and small helpers
	 * ------------------------------------------------------------------ */
	private static function ok( $data, $status = 200 ) {
		$r = new WP_REST_Response( $data, $status );
		$r->header( 'Cache-Control', 'no-store, max-age=0' );
		return $r;
	}

	private static function err( $code, $message, $status ) {
		return new WP_Error( $code, $message, array( 'status' => $status ) );
	}

	private static function client_ip() {
		$ip = ! empty( $_SERVER['HTTP_CF_CONNECTING_IP'] ) ? $_SERVER['HTTP_CF_CONNECTING_IP'] : ( isset( $_SERVER['REMOTE_ADDR'] ) ? $_SERVER['REMOTE_ADDR'] : '0' );
		return sanitize_text_field( wp_unslash( $ip ) );
	}

	private static function iso( $ts ) {
		return gmdate( 'c', (int) $ts );
	}

	/** MySQL datetime stored in the site's timezone -> unix timestamp. */
	private static function local_to_ts( $mysql ) {
		$dt = date_create( (string) $mysql, wp_timezone() );
		return $dt ? $dt->getTimestamp() : 0;
	}

	/* ------------------------------------------------------------------ *
	 * Tokens
	 * ------------------------------------------------------------------ */
	private static function bearer( WP_REST_Request $req ) {
		$h = $req->get_header( 'authorization' );
		if ( ! $h && isset( $_SERVER['HTTP_AUTHORIZATION'] ) ) {
			$h = $_SERVER['HTTP_AUTHORIZATION'];
		}
		if ( ! $h && isset( $_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ) ) {
			$h = $_SERVER['REDIRECT_HTTP_AUTHORIZATION'];
		}
		if ( $h && 0 === stripos( $h, 'bearer ' ) ) {
			return trim( substr( $h, 7 ) );
		}
		// Some hosts strip the Authorization header; the app also sends the token here.
		$alt = $req->get_header( 'x-sl-token' );
		return $alt ? trim( $alt ) : '';
	}

	/** permission_callback for every authenticated route. */
	public static function authenticate( WP_REST_Request $req ) {
		$token = self::bearer( $req );
		if ( '' === $token || false === strpos( $token, '.' ) ) {
			return self::err( 'sl_unauthorized', 'Please log in again.', 401 );
		}
		list( $uid_part ) = explode( '.', $token, 2 );
		$uid = (int) $uid_part;
		if ( $uid <= 0 || ! get_userdata( $uid ) ) {
			return self::err( 'sl_unauthorized', 'Please log in again.', 401 );
		}
		$hash   = hash( 'sha256', $token );
		$tokens = get_user_meta( $uid, self::TOKEN_META, true );
		if ( ! is_array( $tokens ) || ! isset( $tokens[ $hash ] ) || (int) $tokens[ $hash ]['exp'] < time() ) {
			return self::err( 'sl_unauthorized', 'Your session expired. Please log in again.', 401 );
		}
		// Record activity at most every 10 minutes (avoids a usermeta write per request).
		if ( time() - (int) $tokens[ $hash ]['last'] > 600 ) {
			$tokens[ $hash ]['last'] = time();
			update_user_meta( $uid, self::TOKEN_META, $tokens );
		}
		self::$uid        = $uid;
		self::$token_hash = $hash;
		return true;
	}

	private static function issue_token( $uid, $device ) {
		$token  = $uid . '.' . bin2hex( random_bytes( 32 ) );
		$hash   = hash( 'sha256', $token );
		$tokens = get_user_meta( $uid, self::TOKEN_META, true );
		$tokens = is_array( $tokens ) ? $tokens : array();
		foreach ( $tokens as $h => $t ) { // Prune expired tokens.
			if ( (int) $t['exp'] < time() ) {
				unset( $tokens[ $h ] );
			}
		}
		$exp            = time() + self::TOKEN_TTL;
		$tokens[ $hash ] = array(
			'exp'     => $exp,
			'created' => time(),
			'last'    => time(),
			'device'  => mb_substr( sanitize_text_field( (string) $device ), 0, 60 ),
		);
		if ( count( $tokens ) > self::MAX_TOKENS ) { // Drop the oldest devices.
			uasort( $tokens, function ( $a, $b ) {
				return $a['created'] <=> $b['created'];
			} );
			$tokens = array_slice( $tokens, -self::MAX_TOKENS, null, true );
		}
		update_user_meta( $uid, self::TOKEN_META, $tokens );
		return array( $token, $exp );
	}

	/* ------------------------------------------------------------------ *
	 * Wallet (PLUG-IN HOOKS: replace through the filters above)
	 * ------------------------------------------------------------------ */
	public static function wallet_balance( $uid ) {
		$custom = apply_filters( 'sl_proxy_api_wallet_balance', null, $uid );
		if ( null !== $custom ) {
			return (float) $custom;
		}
		if ( function_exists( 'woo_wallet' ) && woo_wallet()->wallet ) {
			return (float) woo_wallet()->wallet->get_wallet_balance( $uid, 'edit' );
		}
		$b = (float) get_user_meta( $uid, '_current_woo_wallet_balance', true );
		return $b ? $b : (float) get_user_meta( $uid, '_wallet_balance', true );
	}

	private static function wallet_debit( $uid, $amount, $note ) {
		$custom = apply_filters( 'sl_proxy_api_wallet_debit', null, $uid, $amount, $note );
		if ( null !== $custom ) {
			return (bool) $custom;
		}
		if ( function_exists( 'woo_wallet' ) && woo_wallet()->wallet ) {
			return (bool) woo_wallet()->wallet->debit( $uid, $amount, $note );
		}
		$new = self::wallet_balance( $uid ) - $amount; // Same non-atomic fallback as the web checkout.
		update_user_meta( $uid, '_current_woo_wallet_balance', $new );
		update_user_meta( $uid, '_wallet_balance', $new );
		return true;
	}

	private static function wallet_credit( $uid, $amount, $note ) {
		$custom = apply_filters( 'sl_proxy_api_wallet_credit', null, $uid, $amount, $note );
		if ( null !== $custom ) {
			return (bool) $custom;
		}
		if ( function_exists( 'woo_wallet' ) && woo_wallet()->wallet ) {
			return (bool) woo_wallet()->wallet->credit( $uid, $amount, $note );
		}
		$new = self::wallet_balance( $uid ) + $amount;
		update_user_meta( $uid, '_current_woo_wallet_balance', $new );
		update_user_meta( $uid, '_wallet_balance', $new );
		return true;
	}

	private static function money( $uid = 0 ) {
		return array( 'currency' => 'NGN', 'currency_symbol' => "\xE2\x82\xA6" );
	}

	/* ------------------------------------------------------------------ *
	 * Auth endpoints
	 * ------------------------------------------------------------------ */
	public static function login( WP_REST_Request $req ) {
		$fk = 'sl_proxy_login_' . md5( self::client_ip() );
		$n  = (int) get_transient( $fk );
		if ( $n >= 10 ) {
			return self::err( 'sl_rate', 'Too many attempts. Try again in 15 minutes.', 429 );
		}
		$id = sanitize_text_field( (string) $req->get_param( 'username' ) );
		$pw = (string) $req->get_param( 'password' ); // Never sanitized: it may contain any character.
		if ( '' === $id || '' === $pw ) {
			return self::err( 'sl_bad', 'Enter your username or email and your password.', 400 );
		}
		$user = wp_authenticate( $id, $pw ); // Accepts a username or an email address.
		if ( is_wp_error( $user ) ) {
			set_transient( $fk, $n + 1, 900 );
			return self::err( 'sl_invalid_login', 'Incorrect username/email or password.', 401 );
		}
		delete_transient( $fk );
		list( $token, $exp ) = self::issue_token( $user->ID, (string) $req->get_param( 'device' ) );
		return self::ok( array_merge( array(
			'token'        => $token,
			'token_type'   => 'Bearer',
			'expires_at'   => self::iso( $exp ),
			'username'     => $user->user_login,
			'display_name' => $user->display_name ? $user->display_name : $user->user_login,
			'balance'      => round( self::wallet_balance( $user->ID ), 2 ),
		), self::money() ) );
	}

	public static function logout() {
		$tokens = get_user_meta( self::$uid, self::TOKEN_META, true );
		if ( is_array( $tokens ) && isset( $tokens[ self::$token_hash ] ) ) {
			unset( $tokens[ self::$token_hash ] );
			update_user_meta( self::$uid, self::TOKEN_META, $tokens );
		}
		return self::ok( array( 'ok' => true ) );
	}

	public static function balance() {
		$u = get_userdata( self::$uid );
		return self::ok( array_merge( array(
			'balance'        => round( self::wallet_balance( self::$uid ), 2 ),
			'username'       => $u->user_login,
			'display_name'   => $u->display_name ? $u->display_name : $u->user_login,
			'email'          => $u->user_email,
			'active_proxies' => count( self::active_rows( self::$uid ) ),
		), self::money() ) );
	}

	/* ------------------------------------------------------------------ *
	 * Proxy list (parsed from the live-proxy WooCommerce products)
	 * Title format: IP|STATE|CITY|ZIP|DOMAIN|ISP|TYPE|SPEED|PING|ADDED|CC
	 * ------------------------------------------------------------------ */
	private static function flag( $cc ) {
		if ( function_exists( 'sailorsloot_country_code_to_flag' ) ) {
			return sailorsloot_country_code_to_flag( $cc );
		}
		$cc = strtoupper( $cc );
		if ( 2 !== strlen( $cc ) || ! ctype_alpha( $cc ) ) {
			return "\xF0\x9F\x8C\x90";
		}
		$out = '';
		foreach ( str_split( $cc ) as $ch ) {
			$out .= mb_chr( ord( $ch ) - 65 + 127462, 'UTF-8' );
		}
		return $out;
	}

	/** 75.138.12.9 -> 75.138.***.***   2001:db8:1:2::1 -> 2001:db8:****:**** */
	private static function mask_ip( $ip ) {
		if ( filter_var( $ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4 ) ) {
			$p = explode( '.', $ip );
			return $p[0] . '.' . $p[1] . '.***.***';
		}
		if ( filter_var( $ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6 ) ) {
			$p = explode( ':', $ip );
			return $p[0] . ':' . ( isset( $p[1] ) ? $p[1] : '' ) . ':****:****';
		}
		return '***.***.***.***'; // Anything else (a hostname, a malformed title) is hidden entirely.
	}

	private static function listings() {
		$cached = get_transient( self::CACHE_KEY );
		if ( is_array( $cached ) ) {
			return $cached;
		}
		$q = new WP_Query( array(
			'post_type'      => 'product',
			'post_status'    => 'publish',
			'posts_per_page' => -1,
			'orderby'        => 'date',
			'order'          => 'DESC',
			'no_found_rows'  => true,
			'tax_query'      => array(
				array(
					'taxonomy' => 'product_cat',
					'field'    => 'slug',
					'terms'    => array( self::CATEGORY ),
				),
			),
		) );
		$out = array();
		foreach ( $q->posts as $post ) {
			if ( 'outofstock' === get_post_meta( $post->ID, '_stock_status', true ) ) {
				continue;
			}
			$p  = array_map( 'trim', explode( '|', $post->post_title ) );
			$cc = isset( $p[10] ) ? strtoupper( $p[10] ) : 'US';
			if ( 2 !== strlen( $cc ) || ! ctype_alpha( $cc ) ) {
				$cc = 'US';
			}
			$ip   = isset( $p[0] ) ? $p[0] : '';
			$ping = ( isset( $p[8] ) && preg_match( '/(\d+)/', $p[8], $m ) ) ? (int) $m[1] : null;
			$out[] = array(
				'id'           => (int) $post->ID,
				'ip_masked'    => self::mask_ip( $ip ),
				'country_code' => $cc,
				'flag'         => self::flag( $cc ),
				'state'        => isset( $p[1] ) ? $p[1] : '',
				'city'         => isset( $p[2] ) ? $p[2] : '',
				'zip'          => isset( $p[3] ) ? $p[3] : '',
				'isp'          => isset( $p[5] ) ? $p[5] : '',
				'type'         => isset( $p[6] ) ? $p[6] : 'MIX',
				'speed'        => isset( $p[7] ) ? $p[7] : '',
				'ping_ms'      => $ping,
				'status'       => 'live',
				'price'        => round( (float) get_post_meta( $post->ID, '_price', true ), 2 ),
				'added_at'     => self::iso( get_post_time( 'U', true, $post ) ),
				// Search text includes the real IP prefix so "Search IP" works; it is never returned.
				'_search'      => strtolower( $ip . ' ' . implode( ' ', array_slice( $p, 1, 3 ) ) . ' ' . ( isset( $p[5] ) ? $p[5] : '' ) ),
			);
		}
		set_transient( self::CACHE_KEY, $out, self::CACHE_TTL );
		return $out;
	}

	private static function filtered( WP_REST_Request $req ) {
		$q       = strtolower( trim( (string) $req->get_param( 'q' ) ) );
		$country = strtoupper( trim( (string) $req->get_param( 'country' ) ) );
		$state   = strtolower( trim( (string) $req->get_param( 'state' ) ) );
		$city    = strtolower( trim( (string) $req->get_param( 'city' ) ) );
		$zip     = strtolower( trim( (string) $req->get_param( 'zip' ) ) );
		$isp     = strtolower( trim( (string) $req->get_param( 'isp' ) ) );
		$out     = array();
		foreach ( self::listings() as $row ) {
			if ( '' !== $q && false === strpos( $row['_search'], $q ) ) {
				continue;
			}
			if ( '' !== $country && $row['country_code'] !== $country ) {
				continue;
			}
			if ( '' !== $state && false === strpos( strtolower( $row['state'] ), $state ) ) {
				continue;
			}
			if ( '' !== $city && false === strpos( strtolower( $row['city'] ), $city ) ) {
				continue;
			}
			if ( '' !== $zip && 0 !== strpos( strtolower( $row['zip'] ), $zip ) ) {
				continue;
			}
			if ( '' !== $isp && false === strpos( strtolower( $row['isp'] ), $isp ) ) {
				continue;
			}
			$out[] = $row;
		}
		return $out;
	}

	public static function proxies( WP_REST_Request $req ) {
		$rows     = self::filtered( $req );
		$per_page = max( 1, min( 100, (int) ( $req->get_param( 'per_page' ) ? $req->get_param( 'per_page' ) : 20 ) ) );
		$total    = count( $rows );
		$pages    = max( 1, (int) ceil( $total / $per_page ) );
		$page     = max( 1, min( $pages, (int) ( $req->get_param( 'page' ) ? $req->get_param( 'page' ) : 1 ) ) );
		$slice    = array_slice( $rows, ( $page - 1 ) * $per_page, $per_page );
		foreach ( $slice as &$row ) {
			unset( $row['_search'] ); // Internal only.
		}
		unset( $row );
		return self::ok( array_merge( array(
			'items'       => $slice,
			'page'        => $page,
			'per_page'    => $per_page,
			'total'       => $total,
			'total_pages' => $pages,
		), self::money() ) );
	}

	public static function filters( WP_REST_Request $req ) {
		$country = strtoupper( trim( (string) $req->get_param( 'country' ) ) );
		$state   = strtolower( trim( (string) $req->get_param( 'state' ) ) );
		$countries = array();
		$states    = array();
		$cities    = array();
		$isps      = array();
		foreach ( self::listings() as $row ) {
			$countries[ $row['country_code'] ] = true;
			if ( '' !== $country && $row['country_code'] !== $country ) {
				continue;
			}
			if ( '' !== $row['state'] ) {
				$states[ $row['state'] ] = true;
			}
			if ( '' !== $state && strtolower( $row['state'] ) !== $state ) {
				continue;
			}
			if ( '' !== $row['city'] ) {
				$cities[ $row['city'] ] = true;
			}
			if ( '' !== $row['isp'] ) {
				$isps[ $row['isp'] ] = true;
			}
		}
		$keys = function ( $a ) {
			$k = array_map( 'strval', array_keys( $a ) );
			sort( $k, SORT_NATURAL | SORT_FLAG_CASE );
			return array_values( $k );
		};
		return self::ok( array(
			'countries' => $keys( $countries ),
			'states'    => $keys( $states ),
			'cities'    => $keys( $cities ),
			'isps'      => $keys( $isps ),
		) );
	}

	/* ------------------------------------------------------------------ *
	 * Purchases
	 * ------------------------------------------------------------------ */
	private static function table() {
		global $wpdb;
		$table = $wpdb->prefix . 'sailorsloot_live_proxies';
		// Same schema as the web checkout; no-op when it already exists.
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
		return $table;
	}

	/**
	 * PLUG-IN HOOK: the live IP check. Default = the existing 9Proxy engine (build a Proxy2Web
	 * session, verify it through the relay, retry the SAME session while it becomes routable).
	 * Return array(host, port, username, password, ip, country, city, isp) or a WP_Error.
	 */
	private static function allocate_live( $product_id ) {
		$custom = apply_filters( 'sl_proxy_api_allocate_live', null, $product_id );
		if ( null !== $custom ) {
			return $custom;
		}
		if ( ! function_exists( 'sailorsloot_build_9proxy_username' ) || ! function_exists( 'sailorsloot_verify_9proxy_connection' )
			|| ! defined( 'SL_9PROXY_BASE_USERNAME' ) || ! defined( 'SL_9PROXY_PASSWORD' ) ) {
			return self::err( 'sl_engine_missing', 'The live proxy engine is not available right now.', 503 );
		}
		$attr = function ( $name ) use ( $product_id ) {
			return function_exists( 'sailorsloot_get_custom_attribute' ) ? sailorsloot_get_custom_attribute( $product_id, $name ) : '';
		};
		$filters  = array(
			'country' => $attr( '_sl_proxy_country' ),
			'state'   => $attr( '_sl_proxy_state' ),
			'city'    => $attr( '_sl_proxy_city' ),
			'isp'     => $attr( '_sl_proxy_isp' ),
		);
		$username = sailorsloot_build_9proxy_username( SL_9PROXY_BASE_USERNAME, $filters );
		$verify   = array( 'success' => false );
		$delays   = array( 1, 2, 3 );
		for ( $i = 0; $i < 4; $i++ ) {
			if ( $i > 0 ) {
				sleep( $delays[ $i - 1 ] );
			}
			$verify = sailorsloot_verify_9proxy_connection( $username, SL_9PROXY_PASSWORD );
			if ( ! empty( $verify['success'] ) ) {
				break;
			}
		}
		if ( empty( $verify['success'] ) ) {
			return self::err( 'sl_not_live', 'No live proxy is available for that selection right now. You were not charged.', 409 );
		}
		return array(
			'host'     => defined( 'SL_9PROXY_HOST' ) ? SL_9PROXY_HOST : '',
			'port'     => defined( 'SL_9PROXY_PORT' ) ? SL_9PROXY_PORT : '',
			'username' => $username,
			'password' => SL_9PROXY_PASSWORD,
			'ip'       => isset( $verify['ip'] ) ? $verify['ip'] : '',
			'country'  => isset( $verify['country'] ) ? $verify['country'] : '',
			'city'     => isset( $verify['city'] ) ? $verify['city'] : '',
			'isp'      => isset( $verify['org'] ) ? $verify['org'] : '',
		);
	}

	private static function create_order( $uid, $product ) {
		if ( ! function_exists( 'wc_create_order' ) ) {
			return 0;
		}
		$order = wc_create_order();
		$order->add_product( $product, 1 );
		$order->set_customer_id( $uid );
		$order->set_payment_method( 'wallet' );
		$order->set_payment_method_title( 'TeraWallet Deduction (SL_Proxy app)' );
		$order->calculate_totals();
		$order->update_status( 'completed', 'Live proxy verified and delivered through the SL_Proxy app.' );
		$order->save();
		return (int) $order->get_id();
	}

	public static function purchase( WP_REST_Request $req ) {
		global $wpdb;
		$uid        = self::$uid;
		$product_id = (int) $req->get_param( 'proxy_id' );

		$rk = 'sl_proxy_buy_rate_' . $uid;
		if ( (int) get_transient( $rk ) >= 10 ) {
			return self::err( 'sl_rate', 'Too many purchase attempts. Wait a minute and try again.', 429 );
		}
		set_transient( $rk, (int) get_transient( $rk ) + 1, 60 );

		$product = function_exists( 'wc_get_product' ) ? wc_get_product( $product_id ) : null;
		if ( ! $product || 'publish' !== get_post_status( $product_id ) || ! has_term( self::CATEGORY, 'product_cat', $product_id ) ) {
			return self::err( 'sl_not_found', 'That proxy is no longer listed.', 404 );
		}
		$price = round( (float) $product->get_price(), 2 );
		if ( $price <= 0 ) {
			return self::err( 'sl_bad_price', 'This proxy has no valid price.', 409 );
		}

		// One purchase at a time per user (MySQL named lock): the balance check, the live check
		// and the debit below cannot interleave with a second request from the same account.
		$lock = 'sl_proxy_buy_' . $uid;
		$got  = (int) $wpdb->get_var( $wpdb->prepare( 'SELECT GET_LOCK(%s, 0)', $lock ) );
		if ( ! $got ) {
			return self::err( 'sl_busy', 'Another purchase is already in progress on your account.', 409 );
		}
		@set_time_limit( 150 ); // The live check can wait on 9Proxy for a while.

		try {
			// 1) Enough money?
			$balance = self::wallet_balance( $uid );
			if ( $balance < $price ) {
				return self::err( 'sl_insufficient', 'Insufficient wallet balance. Please top up.', 402 );
			}

			// 2) Live IP check BEFORE charging.
			$alloc = self::allocate_live( $product_id );
			if ( is_wp_error( $alloc ) ) {
				return $alloc;
			}

			// 3) Charge (the lock guarantees nobody else spent in between).
			if ( self::wallet_balance( $uid ) < $price ) {
				return self::err( 'sl_insufficient', 'Insufficient wallet balance. Please top up.', 402 );
			}
			if ( ! self::wallet_debit( $uid, $price, 'Live Proxy Purchase via SL_Proxy app (Product #' . $product_id . ')' ) ) {
				return self::err( 'sl_debit_failed', 'The wallet could not be charged. You were not charged.', 500 );
			}

			// 4) Record it with the expiry (the product's duration, 24 hours by default).
			$minutes = (int) get_post_meta( $product_id, '_sl_proxy_duration_minutes', true );
			if ( $minutes <= 0 ) {
				$minutes = defined( 'SL_9PROXY_DEFAULT_DURATION_MINUTES' ) ? (int) SL_9PROXY_DEFAULT_DURATION_MINUTES : 1440;
			}
			$expires_ts = time() + $minutes * 60;
			$expires_at = wp_date( 'Y-m-d H:i:s', $expires_ts );
			$order_id   = self::create_order( $uid, $product );
			$table      = self::table();
			$ok         = $wpdb->insert( $table, array(
				'user_id'          => $uid,
				'order_id'         => $order_id,
				'product_id'       => $product_id,
				'host'             => $alloc['host'],
				'port'             => (string) $alloc['port'],
				'username'         => $alloc['username'],
				'password'         => $alloc['password'],
				'resolved_ip'      => $alloc['ip'],
				'resolved_country' => $alloc['country'],
				'resolved_city'    => $alloc['city'],
				'resolved_isp'     => $alloc['isp'],
				'status'           => 'active',
				'expires_at'       => $expires_at,
				'created_at'       => current_time( 'mysql' ),
			) );
			if ( false === $ok ) {
				self::wallet_credit( $uid, $price, 'Refund: Live Proxy purchase could not be recorded (Product #' . $product_id . ')' );
				return self::err( 'sl_record_failed', 'The purchase could not be saved. You were refunded.', 500 );
			}

			return self::ok( array_merge( array(
				'proxy_id'          => $product_id,
				'order_id'          => $order_id,
				'host'              => $alloc['host'],
				'port'              => (int) $alloc['port'],
				'username'          => $alloc['username'],
				'password'          => $alloc['password'],
				'ip_masked'         => self::mask_ip( (string) $alloc['ip'] ),
				'country'           => $alloc['country'],
				'city'              => $alloc['city'],
				'isp'               => $alloc['isp'],
				'expires_at'        => self::iso( $expires_ts ),
				'remaining_seconds' => max( 0, $expires_ts - time() ),
				'price'             => $price,
				'balance'           => round( self::wallet_balance( $uid ), 2 ),
			), self::money() ) );
		} finally {
			$wpdb->query( $wpdb->prepare( 'SELECT RELEASE_LOCK(%s)', $lock ) );
		}
	}

	/* ------------------------------------------------------------------ *
	 * History (purchases that have not expired yet)
	 * ------------------------------------------------------------------ */
	private static function active_rows( $uid ) {
		global $wpdb;
		$table = self::table();
		return (array) $wpdb->get_results( $wpdb->prepare(
			"SELECT * FROM `$table` WHERE user_id = %d AND status = 'active' AND expires_at > %s ORDER BY created_at DESC LIMIT 100",
			$uid,
			current_time( 'mysql' )
		) );
	}

	public static function history() {
		$items = array();
		foreach ( self::active_rows( self::$uid ) as $r ) {
			$exp     = self::local_to_ts( $r->expires_at );
			$items[] = array(
				'id'                => (int) $r->id,
				'proxy_id'          => (int) $r->product_id,
				'host'              => $r->host,
				'port'              => (int) $r->port,
				'username'          => $r->username,
				'password'          => $r->password,
				'ip_masked'         => self::mask_ip( (string) $r->resolved_ip ),
				'country'           => (string) $r->resolved_country,
				'city'              => (string) $r->resolved_city,
				'isp'               => (string) $r->resolved_isp,
				'purchased_at'      => self::iso( self::local_to_ts( $r->created_at ) ),
				'expires_at'        => self::iso( $exp ),
				'remaining_seconds' => max( 0, $exp - time() ),
			);
		}
		return self::ok( array( 'items' => $items, 'now' => self::iso( time() ) ) );
	}
}

SL_Proxy_API::init();
