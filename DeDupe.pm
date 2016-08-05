package Plugins::LastMix::DeDupe;

# Fallback class to provide some helper methods provided by most recent LMS only

use strict;

use Slim::Player::Playlist;

sub deDupePlaylist {
	my ( $class, $client, $tracks ) = @_;

	if ( $tracks && ref $tracks && scalar @$tracks ) {
		$tracks = $class->deDupe($tracks, { map { $_ => 1 } @{Slim::Player::Playlist::playList($client)} } );
	}
	
	return $tracks;
}

sub deDupe {
	my ( $class, $tracks, $seen ) = @_;
			
	if ( $tracks && ref $tracks && scalar @$tracks ) {
		$seen ||= {};
		$tracks = [ grep {
			!$seen->{$_}++
		} @$tracks ];
	}
	
	return $tracks;
}

1;