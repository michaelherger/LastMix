package Plugins::LastMix::Plugin;

use strict;
use Tie::Cache::LRU;

use base qw(Slim::Plugin::OPMLBased);
use URI::Escape qw(uri_unescape);

use Slim::Menu::ArtistInfo;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

# XXX - make this user-adjustable? Large number risks to create undesired mix if seed was
# too narrow (eg. accidentally all tracks of the same album). Small number will require more
# lookups.
use constant MAX_TRACKS => 5;

use constant CAN_BALANCED_SHUFFLE => UNIVERSAL::can('Slim::Player::Playlist', 'balancedShuffle') ? 1 : 0;

# we're going to cache some information about our artists during the resolving process
tie my %unknownArtists, 'Tie::Cache::LRU', 128;
tie my %knownArtists, 'Tie::Cache::LRU', 128;

my $deDupeClass = 'Slim::Plugin::DontStopTheMusic::Plugin';

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.lastmix',
	'defaultLevel' => 'WARN',
	'description'  => 'PLUGIN_LASTMIX_NAME',
});
my $lfmPrefs = preferences('plugin.audioscrobbler');

# Only load the large parts of the code once we know Don't Stop The Music has been initialized
sub postinitPlugin {
	my $class = shift;

	Slim::Menu::ArtistInfo->registerInfoProvider( lastMixArtistMix => (
		after => 'top',
		func  => \&artistInfoMenu,
	) );

	if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::AudioScrobbler::Plugin') ) {
		Slim::Plugin::AudioScrobbler::Plugin::registerLoveHandler(sub {
			my ( $client, $item ) = @_;

			my $username = $lfmPrefs->client($client)->get('account');

			Plugins::LastMix::LFM->loveTrack(sub {
				my $result = shift;
				$log->error("Failed to love track") if !$result || keys %$result;
			}, $username, uri_unescape($item->{a}), uri_unescape($item->{t}));
		});
	}

	# if the user has the Don't Stop The Music plugin enabled, register ourselves
	if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin') ) {
		if ( !$deDupeClass->can('deDupe') ) {
			$log->error('Your Lyrion Music Server is OUTDATED. Please update!');
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
		Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_LASTMIX_DSTM_MYMUSIC_ONLY', \&Plugins::LastMix::DontStopTheMusic::myMusicOnlyPlease);
		Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_LASTMIX_DSTM_CURRENT_LIBRARYVIEW_ONLY', \&Plugins::LastMix::DontStopTheMusic::currentLibraryViewOnlyPlease);

		if ( Plugins::LastMix::LFM->getUsername() ) {
			Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_LASTMIX_DSTM_YOUR_FAVORITE_ARTISTS', \&Plugins::LastMix::DontStopTheMusic::favouriteArtistMix);
		}

		Slim::Player::ProtocolHandlers->registerHandler(
			lastmix => 'Plugins::LastMix::ProtocolHandler'
		);

		$class->SUPER::initPlugin(
			feed   => \&handleFeed,
			tag    => 'lastmix',
			menu   => 'radios',
			is_app => 1,
			weight => 5,
		);
	}
	else {
		Slim::Utils::Log::logError("The LastMix plugin requires the Don't Stop The Music plugin to be enabled - which is not the case.");
	}
}

sub handleFeed {
	my ($client, $cb, $args) = @_;

	$cb->({
		items => [{
			name => cstring($client, 'PLUGIN_LASTMIX_TOP_TAGS_ALPAHBETICALLY'),
			url => \&topTagsFeed,
			passthrough => [{
				sort => 'alpha'
			}]
		},{
			name => cstring($client, 'PLUGIN_LASTMIX_TOP_TAGS_BY_COUNT'),
			url => \&topTagsFeed,
		}]
	});
}

sub artistInfoMenu {
	my ( $client, $url, $artist, $remoteMeta ) = @_;

	my $artistName = ($artist && $artist->name) || (ref $remoteMeta && $remoteMeta->{artist}) || return;

	return [
		{
			name => cstring($client, 'PLUGIN_LASTMIX_ARTISTMIX'),
			url  => 'lastmix://play?artist=' . URI::Escape::uri_escape($artistName),
			type => 'audio',
		}
	];
}

sub topTagsFeed {
	my ($client, $cb, $args, $pt) = @_;

	$pt ||= {};

	Plugins::LastMix::LFM->getTopTags( sub {
		my $tagData = shift;

		# Build main menu structure
		my $items = [];

		my $topTags;

		eval {
			$topTags = $tagData->{toptags}->{tag};
		};

		$log->error($@) if $@;

		if ($topTags && ref $topTags) {
			if ($pt->{sort} && $pt->{sort} eq 'alpha') {
				$topTags = [ sort { lc($a->{name}) cmp lc($b->{name}) } @$topTags ];
			}

			foreach my $tag (@$topTags) {
				push @$items, {
					type => 'audio',
					name => ucfirst($tag->{name}),
					url => 'lastmix://play?tags=' . $tag->{name},
				}
			}
		}

		$cb->({
			items => $items,
		});
	} );
}

sub getDisplayName { 'PLUGIN_LASTMIX_NAME' }
sub playerMenu {}

sub checkTracks {
	my ($client, $cb) = @_;

	my $candidates = $client->pluginData('candidates');

	# shuffle the playlist, trying to prevent repeated plays
	if (!$client->pluginData('shuffled')) {
		$client->pluginData(shuffled => 1);

		if (CAN_BALANCED_SHUFFLE) {
			my $mbidToTrackinfoMap = {};
			foreach (@$candidates) {
				$mbidToTrackinfoMap->{$_->{mbid} || $_->{title} . $_->{artist}} = $_;
			}

			my $shuffledIds = Slim::Player::Playlist::balancedShuffle([
				map {
					[$_, $mbidToTrackinfoMap->{$_}->{artist_mbid} || $mbidToTrackinfoMap->{$_}->{artist}]
				} keys %$mbidToTrackinfoMap
			]);

			$candidates = [ map {
				$mbidToTrackinfoMap->{$_}
			} @$shuffledIds ];
		}
		else {
			Slim::Player::Playlist::fischer_yates_shuffle($candidates);
		}

		$client->pluginData(candidates => $candidates);
	}

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
		_checkTrack($client, $cb, shift @$candidates);
		return;
	}

	$tracks = $deDupeClass->deDupePlaylist($client, $tracks);

	if ( $tracks && ref $tracks && scalar @$tracks ) {
		# we're done mixing - clean up our data
		initClientPluginData($client);

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
	my $library_id = $client->pluginData('libraryViewOnly') ? Slim::Music::VirtualLibraries->getLibraryIdForClient($client) : undef;

	if ( !$unknownArtists{$artist} ) {
		if ( $candidate->{mbid} ) {
			# try track search by musicbrainz ID first
			my $sth_get_track_by_mbid = $dbh->prepare_cached( qq{
				SELECT tracks.url
				FROM tracks } . ($library_id ? qq{
					JOIN library_track ON library_track.library = '$library_id' AND tracks.id = library_track.track
				} : '') . qq{
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
				} . ($library_id ? qq{
					JOIN library_track ON library_track.library = '$library_id' AND tracks.id = library_track.track
				} : '') . qq{
				WHERE titlesearch LIKE ?
					AND contributor_track.track = tracks.id
					AND contributor_track.contributor = ?
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

	if ( !$client->pluginData('myMusicOnly') && (my $serviceHandler = Plugins::LastMix::Services->getServiceHandler($client)) ) {
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
	$client->pluginData( shuffled => 0 );
	$client->pluginData( candidates => [] );
	$client->pluginData( seed => [] );
}

1;