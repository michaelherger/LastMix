package Plugins::LastMix::ProtocolHandler;

use strict;

use Plugins::LastMix::LFM;

use constant ICON => 'plugins/DontStopTheMusic/html/images/icon.png';

sub overridePlayback {
	my ( $class, $client, $url ) = @_;

	return unless $client;

	if ( Slim::Player::Source::streamingSongIndex($client) ) {
		# don't start immediately if we're part of a playlist and previous track isn't done playing
		return if $client->controller()->playingSongDuration()
	}

	my ($tags) = $url =~ m|^lastmix://tags\?tags=(.*)|;

	return unless $tags;

	$client->execute(["lastmix", "tags:$tags"]);

	return 1;
}

sub canDirectStream { 0 }

sub contentType { 'lmx' }

sub isRemote { 0 }

sub getMetadataFor {
	my ( $class, $client, $url ) = @_;

	return unless $client && $url;

	# TODO - add genre as part of the title, custom icon etc.
	# my ($type) = $url =~ m{randomplay://(track|contributor|album|year)s?$};
	my $title = 'PLUGIN_LASTMIX_DSTM_ITEM';

	# if ($type) {
	# 	$title = 'PLUGIN_RANDOM_' . uc($type);
	# }

	return {
		title => $client->string($title),
		cover => $class->getIcon(),
	};
}

sub getIcon { ICON }

1;