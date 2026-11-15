/**
 * SL App Banners: lets the Sailorsloot admin edit the banner ads shown on the SL_Proxy Home screen.
 *
 * HOW TO INSTALL
 *  1. Code Snippets -> Add New -> paste this whole file (do NOT include a <?php tag).
 *  2. Set "Run snippet everywhere" and Save & Activate.
 *  3. WP Admin -> SL App Banners: edit the banners (up to 5), press "Choose image" to upload a logo
 *     from the media library, set the link the Get button opens, Save.
 *
 * The app reads:   GET https://sailorsloot.xyz/wp-json/slapp/v1/banners
 *   -> {"banners":[{"id","title","subtitle","logo","url","cta"}, ...]}   (only enabled banners)
 * The app refreshes it whenever Home opens, so a saved change shows up within seconds.
 */

define( 'SL_BANNER_SLOTS', 5 );
define( 'SL_BANNER_OPTION', 'sl_app_banners' );

function sl_banner_defaults() {
	return array(
		array(
			'on'       => 1,
			'title'    => 'SL_Spoof is out',
			'subtitle' => 'Move your iPhone anywhere from the Sailorsloot site. Tap Get to download it.',
			'logo'     => 'https://sailorsloot.xyz/wp-content/uploads/2026/11/IMG_7167.png',
			'url'      => 'https://sailorsloot.xyz/',
			'cta'      => 'Get',
		),
	);
}

function sl_banner_all() {
	$b = get_option( SL_BANNER_OPTION, null );
	return is_array( $b ) ? $b : sl_banner_defaults();
}

/* ---------------------------- public REST endpoint ---------------------------- */
add_action( 'rest_api_init', function () {
	register_rest_route( 'slapp/v1', '/banners', array(
		'methods'             => 'GET',
		'callback'            => 'sl_banner_rest',
		'permission_callback' => '__return_true',
	) );
} );

function sl_banner_rest() {
	$out = array();
	foreach ( sl_banner_all() as $i => $b ) {
		if ( empty( $b['on'] ) || '' === trim( (string) $b['title'] ) ) {
			continue;
		}
		$out[] = array(
			'id'       => substr( md5( $i . '|' . $b['title'] . '|' . $b['url'] . '|' . $b['logo'] ), 0, 12 ),
			'title'    => (string) $b['title'],
			'subtitle' => (string) $b['subtitle'],
			'logo'     => (string) $b['logo'],
			'url'      => (string) $b['url'],
			'cta'      => '' !== trim( (string) $b['cta'] ) ? (string) $b['cta'] : 'Get',
		);
	}
	$r = new WP_REST_Response( array( 'banners' => $out ), 200 );
	$r->header( 'Cache-Control', 'public, max-age=60' );
	return $r;
}

/* ------------------------------- admin screen -------------------------------- */
add_action( 'admin_menu', function () {
	add_menu_page( 'SL App Banners', 'SL App Banners', 'manage_options', 'sl-app-banners', 'sl_banner_admin_page', 'dashicons-megaphone', 59 );
} );

add_action( 'admin_enqueue_scripts', function ( $hook ) {
	if ( 'toplevel_page_sl-app-banners' === $hook ) {
		wp_enqueue_media();
	}
} );

function sl_banner_admin_page() {
	if ( ! current_user_can( 'manage_options' ) ) {
		return;
	}
	$banners = sl_banner_all();
	echo '<div class="wrap"><h1>SL App Banners</h1>';
	if ( isset( $_GET['saved'] ) ) {
		echo '<div class="notice notice-success is-dismissible"><p>Saved. The app shows the new banners the next time Home opens.</p></div>';
	}
	echo '<p>Banners appear at the top of the SL_Proxy Home screen. Untick <em>Show</em> to hide one. With more than one active banner the app rotates them.</p>';
	echo '<form method="post" action="' . esc_url( admin_url( 'admin-post.php' ) ) . '">';
	wp_nonce_field( 'sl_banner_save' );
	echo '<input type="hidden" name="action" value="sl_banner_save">';

	for ( $i = 0; $i < SL_BANNER_SLOTS; $i++ ) {
		$b = isset( $banners[ $i ] ) ? $banners[ $i ] : array( 'on' => 0, 'title' => '', 'subtitle' => '', 'logo' => '', 'url' => '', 'cta' => 'Get' );
		echo '<div style="background:#fff;border:1px solid #c3c4c7;border-radius:8px;padding:14px 18px;margin:14px 0;max-width:760px">';
		echo '<h2 style="margin-top:0">Banner ' . ( $i + 1 ) . '</h2>';
		echo '<p><label><input type="checkbox" name="b[' . $i . '][on]" value="1" ' . checked( ! empty( $b['on'] ), true, false ) . '> Show this banner</label></p>';
		echo '<p><label>Title<br><input type="text" class="large-text" maxlength="60" name="b[' . $i . '][title]" value="' . esc_attr( $b['title'] ) . '"></label></p>';
		echo '<p><label>Text under the title<br><input type="text" class="large-text" maxlength="140" name="b[' . $i . '][subtitle]" value="' . esc_attr( $b['subtitle'] ) . '"></label></p>';
		echo '<p><label>Logo / image URL<br><input type="url" class="large-text sl-banner-logo" name="b[' . $i . '][logo]" value="' . esc_attr( $b['logo'] ) . '"></label> ';
		echo '<button type="button" class="button sl-banner-pick">Choose image</button>';
		if ( ! empty( $b['logo'] ) ) {
			echo '<br><img src="' . esc_url( $b['logo'] ) . '" alt="" style="max-height:56px;margin-top:8px;border-radius:8px;background:#fff">';
		}
		echo '</p>';
		echo '<p><label>Get link (opens when the user taps the button)<br><input type="url" class="large-text" name="b[' . $i . '][url]" value="' . esc_attr( $b['url'] ) . '"></label></p>';
		echo '<p><label>Button text<br><input type="text" maxlength="14" name="b[' . $i . '][cta]" value="' . esc_attr( $b['cta'] ) . '"></label></p>';
		echo '</div>';
	}
	echo '<p><button class="button button-primary">Save banners</button></p></form>';
	?>
	<script>
	jQuery(function ($) {
		$('.sl-banner-pick').on('click', function (e) {
			e.preventDefault();
			var field = $(this).siblings('label').find('.sl-banner-logo');
			var frame = wp.media({ title: 'Choose banner image', multiple: false, library: { type: 'image' } });
			frame.on('select', function () {
				field.val(frame.state().get('selection').first().toJSON().url);
			});
			frame.open();
		});
	});
	</script>
	<?php
	echo '</div>';
}

add_action( 'admin_post_sl_banner_save', function () {
	if ( ! current_user_can( 'manage_options' ) ) {
		wp_die( 'No access' );
	}
	check_admin_referer( 'sl_banner_save' );
	$in  = isset( $_POST['b'] ) && is_array( $_POST['b'] ) ? wp_unslash( $_POST['b'] ) : array();
	$out = array();
	for ( $i = 0; $i < SL_BANNER_SLOTS; $i++ ) {
		$r = isset( $in[ $i ] ) && is_array( $in[ $i ] ) ? $in[ $i ] : array();
		$out[] = array(
			'on'       => empty( $r['on'] ) ? 0 : 1,
			'title'    => mb_substr( sanitize_text_field( isset( $r['title'] ) ? $r['title'] : '' ), 0, 60 ),
			'subtitle' => mb_substr( sanitize_text_field( isset( $r['subtitle'] ) ? $r['subtitle'] : '' ), 0, 140 ),
			'logo'     => esc_url_raw( isset( $r['logo'] ) ? $r['logo'] : '', array( 'http', 'https' ) ),
			'url'      => esc_url_raw( isset( $r['url'] ) ? $r['url'] : '', array( 'http', 'https' ) ),
			'cta'      => mb_substr( sanitize_text_field( isset( $r['cta'] ) ? $r['cta'] : 'Get' ), 0, 14 ),
		);
	}
	update_option( SL_BANNER_OPTION, $out, false );
	wp_safe_redirect( admin_url( 'admin.php?page=sl-app-banners&saved=1' ) );
	exit;
} );
