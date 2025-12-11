package Plugins::LastMix::ProtocolHandler;

use strict;

use URI;
use URI::QueryParam;

use Plugins::LastMix::LFM;

sub overridePlayback {
	my ( $class, $client, $url ) = @_;

	return unless $client;

	if ( Slim::Player::Source::streamingSongIndex($client) ) {
		# don't start immediately if we're part of a playlist and previous track isn't done playing
		return if $client->controller()->playingSongDuration()
	}

	my ($command) = $url =~ m{^lastmix://(play|add)\?};

	return unless $command;

	my $uri = URI->new($url);
	my $params = $uri->query_form_hash;

	my $cmd = ['lastmix', $command];
	push @$cmd, 'dstm:1' if $params->{dstm};

	if (my $artist = $params->{artist}) {
		push @$cmd, "artist:$artist";
	}
	elsif (my $tags = $params->{tags}) {
		push @$cmd, "tags:$tags";
	}
	else {
		return;
	}

	$client->execute($cmd);

	return 1;
}

sub canDirectStream { 0 }

sub contentType { 'lmx' }

sub isRemote { 0 }

sub getMetadataFor {
	my ( $class, $client, $url ) = @_;

	return unless $client && $url;

	my $title = $client->string('PLUGIN_LASTMIX_NAME');

	if ( my ($arguments) = $url =~ m{lastmix://(?:play|add|tags)\?.*(?:tags|artist)=(.*)} ) {
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