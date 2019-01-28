package Plugins::LastMix::Plugin;

use strict;
use Tie::Cache::LRU;

use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;

# XXX - make this user-adjustable? Large number risks to create undesired mix if seed was
# too narrow (eg. accidentally all tracks of the same album). Small number will require more
# lookups.
use constant MAX_TRACKS => 5;

use constant NOMYSB => Slim::Utils::Versions->compareVersions($::VERSION, '7.9') >= 0 && main::NOMYSB() ? 1 : 0;

# we're going to cache some information about our artists during the resolving process
tie my %unknownArtists, 'Tie::Cache::LRU', 128;
tie my %knownArtists, 'Tie::Cache::LRU', 128;

my $deDupeClass = 'Slim::Plugin::DontStopTheMusic::Plugin';

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.lastmix',
	'defaultLevel' => 'WARN',
	'description'  => 'PLUGIN_LASTMIX_NAME',
});

# Only load the large parts of the code once we know Don't Stop The Music has been initialized
sub postinitPlugin {
	my $class = shift;

	# if the user has the Don't Stop The Music plugin enabled, register ourselves
	if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin') ) {
		if ( !$deDupeClass->can('deDupe') ) {
			$log->error('Your Logitech Media Server is OUTDATED. Please update!');
			require Plugins::LastMix::DeDupe;
			$deDupeClass = 'Plugins::LastMix::DeDupe';
		}

		require Slim::Plugin::DontStopTheMusic::Plugin;
		require Plugins::LastMix::LFM;
		require Plugins::LastMix::CLI;
		require Plugins::LastMix::DontStopTheMusic;
		require Plugins::LastMix::ProtocolHandler;

		Plugins::LastMix::CLI->init();
		Plugins::LastMix::DontStopTheMusic->init($class);
		Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_LASTMIX_DSTM_ITEM', \&Plugins::LastMix::DontStopTheMusic::please);
		Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_LASTMIX_DSTM_LOCAL_ONLY', \&Plugins::LastMix::DontStopTheMusic::myMusicOnlyPlease);

		if ( Plugins::LastMix::LFM->getUsername() ) {
			Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_LASTMIX_DSTM_YOUR_FAVORITE_ARTISTS', \&Plugins::LastMix::DontStopTheMusic::favouriteArtistMix);
		}

		Slim::Player::ProtocolHandlers->registerHandler(
			lastmix => 'Plugins::LastMix::ProtocolHandler'
		);
	}
	else {
		Slim::Utils::Log::logError("The LastMix plugin requires the Don't Stop The Music plugin to be enabled - which is not the case.");
	}
}

sub checkTracks {
	my ($client, $cb) = @_;

	my $candidates = $client->pluginData('candidates');

	my $tracks = $client->pluginData('tracks');
	if ( $tracks && ref $tracks ) {

		# stop after some matches
		if ( scalar @$tracks >= MAX_TRACKS ) {
			# we don't want duplicates in the playlist
			$tracks = $deDupeClass->deDupe($tracks);

			if ( scalar @$tracks >= MAX_TRACKS ) {
				$tracks = $deDupeClass->deDupePlaylist($client, $tracks);

				# if we're done, delete the remaining list of candidates
				if ( scalar @$tracks >= MAX_TRACKS ) {
					$candidates = undef;
				}
			}
		}
	}

	# process next candidate if possible
	if ( $candidates && ref $candidates && scalar @$candidates ) {
		# shuffle the playlist, trying to prevent repeated plays
		Slim::Player::Playlist::fischer_yates_shuffle($candidates);

		_checkTrack($client, $cb, shift @$candidates);
		return;
	}

	$tracks = $deDupeClass->deDupePlaylist($client, $tracks);

	if ( $tracks && ref $tracks && scalar @$tracks ) {
		# we're done mixing - clean up our data
		initClientPluginData($client);

		Slim::Player::Playlist::fischer_yates_shuffle($tracks);

		$cb->($client, $tracks);
		return;
	}

	$cb->($client);
}

sub _checkTrack {
	my ($client, $cb, $candidate) = @_;

	# try to find the track in the local database before reaching out to some online music service
	my $dbh = Slim::Schema->dbh;

	# XXX - add library support

	my $tracks = $client->pluginData('tracks') || [];
	my $artist = Slim::Utils::Text::ignoreCase( $candidate->{artist}, 1 );

	if ( !$unknownArtists{$artist} ) {
		if ( $candidate->{mbid} ) {
			# try track search by musicbrainz ID first
			my $sth_get_track_by_mbid = $dbh->prepare_cached( qq{
				SELECT tracks.url
				FROM tracks
				WHERE musicbrainz_id = ?
				LIMIT 1
			} );

			$sth_get_track_by_mbid->execute($candidate->{mbid});

			if ( my $result = $sth_get_track_by_mbid->fetchall_arrayref({}) ) {
				my $url = $result->[0]->{url} if ref $result && scalar @$result;

				if ( $url ) {
					push @$tracks, $url;
					$client->pluginData( tracks => $tracks );

					checkTracks($client, $cb);
					return;
				}
			}
		}

		# look up artist first, blacklisting if not available to prevent further lookups of tracks of that artist
		my $artistId = $knownArtists{$artist};

		# try the musicbrainz ID first - if available
		if ( !$artistId && $candidate->{artist_mbid} ) {
			my $sth_get_artist_by_mbid = $dbh->prepare_cached( qq{
				SELECT id, name
				FROM contributors
				WHERE musicbrainz_id = ?
				LIMIT 1
			} );

			$sth_get_artist_by_mbid->execute($candidate->{artist_mbid});

			if ( my $result = $sth_get_artist_by_mbid->fetchall_arrayref({}) ) {
				if ( ref $result && scalar @$result ) {
					$knownArtists{$artist} = $artistId = $result->[0]->{id};
				}
			}
		}

		if ( !$artistId ) {
			my $sth_get_artist_by_name = $dbh->prepare_cached( qq{
				SELECT id, name
				FROM contributors
				WHERE namesearch LIKE ?
				LIMIT 1
			} );

			$sth_get_artist_by_name->execute("\%$artist\%");

			if ( my $result = $sth_get_artist_by_name->fetchall_arrayref({}) ) {
				if ( ref $result && scalar @$result ) {
					$knownArtists{$artist} = $artistId = $result->[0]->{id};
				}
			}
		}

		if ($artistId) {
			my $sth_get_track_by_name_and_artist = $dbh->prepare_cached( qq{
				SELECT tracks.url
				FROM tracks, contributor_track
				WHERE titlesearch LIKE ?
				AND contributor_track.track = tracks.id AND contributor_track.contributor = ?
				LIMIT 1
			} );

			$sth_get_track_by_name_and_artist->execute(
				Slim::Utils::Text::ignoreCase( $candidate->{title}, 1 ) . '%',
				$artistId
			);

			if ( my $result = $sth_get_track_by_name_and_artist->fetchall_arrayref({}) ) {
				my $url = $result->[0]->{url} if ref $result && scalar @$result;

				if ( $url ) {
					push @$tracks, $url;
					$client->pluginData( tracks => $tracks );

					checkTracks($client, $cb);
					return;
				}
			}
			else {
				$log->info("No local track found for: " . Data::Dump::dump($candidate));
			}
		}
		else {
			$unknownArtists{$artist}++;
			if ( main::INFOLOG && $log->is_info ) {
				$log->info(sprintf("No local track found for artist: %s (%s)", $candidate->{artist}, $artist));
			}
		}
	}

	if ( !$client->pluginData('localMusicOnly') && (my $serviceHandler = Plugins::LastMix::Services->getServiceHandler($client)) ) {
		$serviceHandler->lookup($client, sub {
			my ($url) = @_;

			if ( $url ) {
				push @$tracks, $url;
				$client->pluginData( tracks => $tracks );
			}

			checkTracks($client, $cb)
		}, $candidate);
	}
	else {
		checkTracks($client, $cb);
	}
}

sub initClientPluginData {
	my $client = shift || return;

	$client = $client->master;

	$client->pluginData( tracks => [] );
	$client->pluginData( artists => {} );
	$client->pluginData( tags => {} );
	$client->pluginData( candidates => [] );
	$client->pluginData( seed => [] );
}

1;