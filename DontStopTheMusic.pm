package Plugins::LastMix::DontStopTheMusic;

use strict;
use Scalar::Util qw(blessed);
use Storable;
use Tie::Cache::LRU;

use Slim::Plugin::DontStopTheMusic::Plugin;
use Slim::Utils::Log;

use Plugins::LastMix::LFM;
use Plugins::LastMix::Services;

use constant BASE_URL => 'http://ws.audioscrobbler.com/2.0/';
use constant SEED_TRACKS => 5;

# XXX - make this user-adjustable? Large number risks to create undesired mix if seed was 
# too narrow (eg. accidentally all tracks of the same album). Small number will require more
# lookups.
use constant MAX_TRACKS => 5;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.lastmix',
	'defaultLevel' => main::INFOLOG ? 'INFO' : 'ERROR',
	'description'  => 'PLUGIN_LASTMIX_NAME',
});

# some tags we want to ignore, because they're too generic or cross genres
my $IGNORE_TAGS => {
	'seen live' => 1,
	'female vocalist' => 1,		# any female vocalist, whether jazz or electro
	'pop' => 1,
	rock => 1,
	dance => 1,					# could be any dance, from waltz to hip hop
	alternative => 1,
	indie => 1,
	experimental => 1,
	instrumental => 1,
	soundtrack => 1,
	british => 1,
	deutsch => 1,
	german => 1,
};

# we're going to cache some information about our artists during the resolving process
tie my %unknownArtists, 'Tie::Cache::LRU', 128;
tie my %knownArtists, 'Tie::Cache::LRU', 128;
my $aid;

my $deDupeClass = 'Slim::Plugin::DontStopTheMusic::Plugin';

sub init {
	if ( !$deDupeClass->can('deDupe') ) {
		$log->error('Your Logitech Media Server is OUTDATED. Please update!');
		require Plugins::LastMix::DeDupe;
		$deDupeClass = 'Plugins::LastMix::DeDupe';
	}
	
	Plugins::LastMix::LFM->init($_[1]);
}

sub _initPluginData {
	my $client = shift || return;
	
	$client = $client->master;
	
	$client->pluginData( tracks => [] );
	$client->pluginData( artists => {} );
	$client->pluginData( tags => {} );
	$client->pluginData( candidates => [] );
	$client->pluginData( seed => [] );
}

sub please {
	my ($client, $cb, $seedTracks, $localMusicOnly) = @_;
	
	$client = $client->master;
	$client->pluginData( localMusicOnly => ($localMusicOnly || 0) );
	_initPluginData($client);
	
	trackMix(@_);
}

sub myMusicOnlyPlease {
	my ($client, $cb, $seedTracks) = @_;
	please($client, $cb, $seedTracks, 1);
}

sub trackMix {
	my ($client, $cb, $seedTracks) = @_;
	
	$client = $client->master;

	if (!$seedTracks) {
		$seedTracks = Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client, SEED_TRACKS);
		main::INFOLOG && $log->is_info && $log->info("Seed Tracks: " . Data::Dump::dump($seedTracks));
		$client->pluginData( seed => Storable::dclone($seedTracks) );
	}

	if ($seedTracks && ref $seedTracks && scalar @$seedTracks) {
		Plugins::LastMix::LFM->getSimilarTracks(sub {
			my $results = shift;
			
			if ( $results && ref $results && $results->{similartracks} && ref $results->{similartracks} && (my $candidates = $results->{similartracks}->{track}) ) {
				# store the tracks if we got some
				if ( scalar @$candidates ) {
					$candidates = [ map {
						{
							title  => $_->{name},
							artist => $_->{artist}->{name}
						}
					} grep {
						$_->{artist} && $_->{artist}->{name}
					} @$candidates ];
					
					push @$candidates, @{ $client->pluginData('candidates') };
					$client->pluginData( candidates => $candidates );
				}
			}
			else {
				warn Data::Dump::dump($results);
			}

			if ( @$seedTracks ) {
				trackMix($client, $cb, $seedTracks);
			}
			# in case we didn't find any tracks, try an artist mix instead
			elsif ( !scalar @{ $client->pluginData('candidates') } ) {
				main::INFOLOG && $log->is_info && $log->info("Didn't find any similar tracks - trying artist mix instead.");
				artistMix($client, $cb, Storable::dclone($client->pluginData('seed')));
			}
			else {
				checkTracks($client, sub {
					my ($client, $tracks) = @_;

					if ($tracks) {
						$cb->(@_);
					}
					else {
						main::INFOLOG && $log->is_info && $log->info("Didn't find any similar tracks - trying artist mix instead.");
						artistMix($client, $cb, Storable::dclone($client->pluginData('seed')));
					}
				});
			}
			
		}, shift @$seedTracks );
		
		return;
	}
	
	$cb->($client);
}

sub tagMix {
	my ($client, $cb, $seedTracks) = @_;

	$client = $client->master;

	if (!$seedTracks) {
		$seedTracks = Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client, SEED_TRACKS);
		main::DEBUGLOG && $log->is_debug && $log->debug("Seed Tracks: " . Data::Dump::dump($seedTracks));
	}
	
	# get a list of (related) artists
	if ($seedTracks && ref $seedTracks && scalar @$seedTracks) {
		Plugins::LastMix::LFM->getArtistTags(sub {
			my $results = shift;
			
			if ( $results && ref $results && $results->{toptags} && ref $results->{toptags} && (my $candidates = $results->{toptags}->{tag}) ) {
				# store the tags if we got some
				foreach (splice @$candidates, 0, 5) {
					my $tags = $client->pluginData('tags');
					$tags->{$_->{name}} += $_->{count};
					$client->pluginData( tags => $tags );
				}
			}
			else {
				warn Data::Dump::dump($results);
			}

			if ( @$seedTracks ) {
				tagMix($client, $cb, $seedTracks);
			}
			else {
				my $tags = $client->pluginData('tags');
				$tags = [ sort {
					$tags->{$b} <=> $tags->{$a}
				} grep {
					!$IGNORE_TAGS->{lc($_)}
				} keys %$tags ];
				
				main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump('Getting tags:', $tags));
				
				getTaggedTracks($client, $cb, $tags);
			}
		}, shift @$seedTracks );
		
		return;
	}
	
	$cb->($client);
}

sub getTaggedTracks {
	my ($client, $cb, $tags) = @_;

	$client = $client->master;

	# get the tag's top tracks
	if ($tags && ref $tags && scalar @$tags) {
		if ( scalar @$tags > 5 ) {
			$tags = [ splice(@$tags, 0, 5) ];
		}
		
		Plugins::LastMix::LFM->getTagTopTracks(sub {
			my $results = shift;
			
			if ( $results && ref $results && $results->{tracks} && ref $results->{tracks} && (my $candidates = $results->{tracks}->{track}) ) {
				# store the tracks if we got some
				if ( scalar @$candidates ) {
					$candidates = [ map {
						{
							title  => $_->{name},
							artist => $_->{artist}->{name}
						}
					} grep {
						$_->{artist} && $_->{artist}->{name}
					} @$candidates ];
					
					push @$candidates, @{ $client->pluginData('candidates') };
					$client->pluginData( candidates => $candidates );
				}
			}
			else {
				warn Data::Dump::dump($results);
			}

			if ( @$tags ) {
				getTaggedTracks($client, $cb, $tags);
			}
			else {
				checkTracks($client, $cb);
			}
		}, {
			tag => shift @$tags
		} );
		
		return;
	}
	
	$cb->($client);
}

sub artistMix {
	my ($client, $cb, $seedTracks) = @_;

	$client = $client->master;

	if (!$seedTracks) {
		$seedTracks = Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client, SEED_TRACKS);
		main::DEBUGLOG && $log->is_debug && $log->debug("Seed Tracks: " . Data::Dump::dump($seedTracks));
		$client->pluginData( seed => Storable::dclone($seedTracks) );
	}
	
	# get a list of (related) artists
	if ($seedTracks && ref $seedTracks && scalar @$seedTracks) {
		my $seedTrack = shift @$seedTracks;
		
		_addArtist($client, $seedTrack->{artist});
		
		Plugins::LastMix::LFM->getSimilarArtists(sub {
			my $results = shift;
			
			if ( $results && ref $results && $results->{similarartists} && ref $results->{similarartists} && (my $candidates = $results->{similarartists}->{artist}) ) {
				# store the artist if we got some
				foreach (@$candidates) {
					_addArtist($client, $_->{name});
				}
			}
			else {
				warn Data::Dump::dump($results);
			}

			if ( @$seedTracks ) {
				artistMix($client, $cb, $seedTracks);
			}
			else {
				getArtistTracks($client, $cb, [ keys %{ $client->pluginData('artists') } ]);
			}
		}, $seedTrack );
		
		return;
	}
	
	$cb->($client);
}

sub favouriteArtistMix {
	my ($client, $cb) = @_;

	$client = $client->master;
	
	_initPluginData($client);
	
	my $username = Plugins::LastMix::LFM->getUsername($client);
	
	# get the list of this user's favourite artists
	if ($username) {
		Plugins::LastMix::LFM->getFavouriteArtists(sub {
			my $results = shift;
			
			if ( $results && ref $results && $results->{topartists} && ref $results->{topartists} && (my $candidates = $results->{topartists}->{artist}) ) {
				Slim::Player::Playlist::fischer_yates_shuffle($candidates);

				# store the artist if we got some
				foreach (splice @$candidates, 0, 10) {
					_addArtist($client, $_->{name});
				}
			}
			else {
				warn Data::Dump::dump($results);
			}

			getArtistTracks($client, $cb, [ keys %{ $client->pluginData('artists') } ]);
		}, {
			username => $username
		} );
		
		return;
	}
	
	# fall back to artist mix
	artistMix($client, $cb);
}

sub _addArtist {
	my ($client, $artist) = @_;
	my $artists = $client->pluginData('artists');
	$artists->{$artist}++;
	$client->pluginData( artists => $artists );
}

sub getArtistTracks {
	my ($client, $cb, $artists) = @_;
	
	# get the artist's top tracks
	if ($artists && ref $artists && scalar @$artists) {
		if (scalar @$artists > 5) {
			Slim::Player::Playlist::fischer_yates_shuffle($artists);
			$artists = [ splice @$artists, 0, 5 ];
		}
		
		Plugins::LastMix::LFM->getArtistTopTracks(sub {
			my $results = shift;
			
			if ( $results && ref $results && $results->{toptracks} && ref $results->{toptracks} && (my $candidates = $results->{toptracks}->{track}) ) {
				# store the tracks if we got some
				if ( scalar @$candidates ) {
					$candidates = [ map {
						{
							title  => $_->{name},
							artist => $_->{artist}->{name}
						}
					} grep {
						$_->{artist} && $_->{artist}->{name}
					} @$candidates ];
					
					push @$candidates, @{ $client->pluginData('candidates') };
					$client->pluginData( candidates => $candidates );
				}
			}
			else {
				warn Data::Dump::dump($results);
			}

			if ( @$artists ) {
				getArtistTracks($client, $cb, $artists);
			}
			# in case we didn't find any tracks, try an artist mix instead
			elsif ( !scalar @{ $client->pluginData('candidates') } ) {
				main::INFOLOG && $log->is_info && $log->info("Didn't find any similar artist tracks - trying tag mix instead. Surprises ahead!");
				tagMix($client, $cb, Storable::dclone($client->pluginData('seed')));
			}
			else {
				checkTracks($client, sub {
					my ($client, $tracks) = @_;
					
					if ($tracks) {
						$cb->(@_);
					}
					else {
						main::INFOLOG && $log->is_info && $log->info("Didn't find any similar artist tracks - trying tag mix instead. Surprises ahead!");
						tagMix($client, $cb, Storable::dclone($client->pluginData('seed')));
					}
				});
			}
		}, {
			artist => shift @$artists
		} );
		
		return;
	}
	
	$cb->($client);
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
		_initPluginData($client);

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
	my $sth_get_track_by_name_and_artist = $dbh->prepare_cached( qq{
		SELECT tracks.url
		FROM tracks, contributor_track
		WHERE titlesearch LIKE ?
		AND contributor_track.track = tracks.id AND contributor_track.contributor = ?
		LIMIT 1
	} );

	my $sth_get_artist_by_name = $dbh->prepare_cached( qq{
		SELECT id, name
		FROM contributors
		WHERE namesearch LIKE ?
		LIMIT 1
	} );
	
	my $tracks = $client->pluginData('tracks') || [];
	my $artist = Slim::Utils::Text::ignoreCase( $candidate->{artist}, 1 );
	
	if ( !$unknownArtists{$artist} ) {
		# look up artist first, blacklisting if not available to prevent further lookups of tracks of that artist
		my $artistId = $knownArtists{$artist};
		
		if ( !$artistId ) {
			$sth_get_artist_by_name->execute("\%$artist\%");
		
			if ( my $result = $sth_get_artist_by_name->fetchall_arrayref({}) ) {
				if ( ref $result && scalar @$result ) {
					$knownArtists{$artist} = $artistId = $result->[0]->{id};
				}
			}
		}
	
		if ($artistId) {
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

1;
