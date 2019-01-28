package Plugins::LastMix::ProtocolHandler;

use strict;

use Plugins::LastMix::LFM;

# TODO - custom icon
use constant ICON => 'plugins/DontStopTheMusic/html/images/icon.png';

sub overridePlayback {
	my ( $class, $client, $url ) = @_;

	return unless $client;

	if ( Slim::Player::Source::streamingSongIndex($client) ) {
		# don't start immediately if we're part of a playlist and previous track isn't done playing
		return if $client->controller()->playingSongDuration()
	}

	my ($command, $tags) = $url =~ m{^lastmix://(play|add)\?tags=(.*)};

	return unless $tags;

	$client->execute(["lastmix", $command, "tags:$tags"]);

	return 1;
}

sub canDirectStream { 0 }

sub contentType { 'lmx' }

sub isRemote { 0 }

sub getMetadataFor {
	my ( $class, $client, $url ) = @_;

	return unless $client && $url;

	my $title = $client->string('PLUGIN_LASTMIX_DSTM_ITEM');

	if ( my ($genres) = $url =~ m{lastmix://(?:play|add|tags)\?tags=(.*)} ) {
		$title .= ' (' . join(', ', map { s/^\s+|\s+$//g; ucfirst($_) } split(',', $genres)) . ')';
	}

	return {
		title => $title,
		cover => $class->getIcon(),
	};
}

sub getIcon { ICON }

1;