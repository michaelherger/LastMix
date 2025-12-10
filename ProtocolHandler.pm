package Plugins::LastMix::ProtocolHandler;

use strict;

use Plugins::LastMix::LFM;

sub overridePlayback {
	my ( $class, $client, $url ) = @_;

	return unless $client;

	if ( Slim::Player::Source::streamingSongIndex($client) ) {
		# don't start immediately if we're part of a playlist and previous track isn't done playing
		return if $client->controller()->playingSongDuration()
	}

	my ($command, $tag, $tags) = $url =~ m{^lastmix://(play|add)\?(tags|artist)=(.*)};

	return unless $tags;

	$client->execute(["lastmix", $command, "$tag:$tags"]);

	return 1;
}

sub canDirectStream { 0 }

sub contentType { 'lmx' }

sub isRemote { 0 }

sub getMetadataFor {
	my ( $class, $client, $url ) = @_;

	return unless $client && $url;

	my $title = $client->string('PLUGIN_LASTMIX_NAME');

	if ( my ($arguments) = $url =~ m{lastmix://(?:play|add|tags)\?(?:tags|artist)=(.*)} ) {
		$title .= ' (' . join(', ', map {
			s/^\s+|\s+$//g;
			ucfirst(URI::Escape::uri_unescape($_))
		} split(',', $arguments)) . ')';
	}

	return {
		title => $title,
		cover => $class->getIcon(),
	};
}

sub getIcon {
	return Plugins::LastMix::Plugin->_pluginDataFor('icon');
}

1;