package Plugins::LastMix::DontStopTheMusic;

use strict;
use Scalar::Util qw(blessed);
use Storable;

use Slim::Plugin::DontStopTheMusic::Plugin;
use Slim::Utils::Log;

use Plugins::LastMix::Plugin;
use Plugins::LastMix::LFM;
use Plugins::LastMix::Services;

use constant BASE_URL => 'http://ws.audioscrobbler.com/2.0/';
use constant SEED_TRACKS => 5;

my $log = logger('plugin.lastmix');

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

sub init {
	Plugins::LastMix::LFM->init($_[1]);
	Plugins::LastMix::Services->init();
}

sub please {
	my ($client, $cb, $seedTracks, $myMusicOnly, $libraryViewOnly) = @_;

	$client = $client->master;
	# can't have libraryViewOnly without myMusicOnly, as it only applies to the latter anyway
	$client->pluginData( myMusicOnly => ($libraryViewOnly || $myMusicOnly || 0) );
	$client->pluginData( libraryViewOnly => ($libraryViewOnly || 0) );
	Plugins::LastMix::Plugin::initClientPluginData($client);

	trackMix(@_);
}

sub myMusicOnlyPlease {
	my ($client, $cb, $seedTracks) = @_;
	please($client, $cb, $seedTracks, 1);
}

sub currentLibraryViewOnlyPlease {
	my ($client, $cb, $seedTracks) = @_;
	please($client, $cb, $seedTracks, 1, 1);
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

			if ( $results && ref $results ) {
				_parseTracks($client, $results, 'similartracks');
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
				Plugins::LastMix::Plugin::checkTracks($client, sub {
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

			if ( $results && ref $results ) {
				_parseTracks($client, $results, 'tracks');
			}
			else {
				warn Data::Dump::dump($results);
			}

			if ( @$tags ) {
				getTaggedTracks($client, $cb, $tags);
			}
			else {
				Plugins::LastMix::Plugin::checkTracks($client, $cb);
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

		$seedTrack->{mbid} = delete $seedTrack->{artist_mbid};

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

	Plugins::LastMix::Plugin::initClientPluginData($client);

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

			if ( $results && ref $results ) {
				_parseTracks($client, $results, 'toptracks', 'track');
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
				Plugins::LastMix::Plugin::checkTracks($client, sub {
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

sub _parseTracks {
	my ($client, $results, $tag) = @_;

	if ( $results && ref $results && $results->{$tag} && ref $results->{$tag} && (my $candidates = $results->{$tag}->{track}) ) {
		# store the tracks if we got some
		if ( $candidates && ref $candidates && scalar @$candidates ) {
			$candidates = [ map {
				{
					title  => $_->{name},
					mbid   => $_->{mbid},
					artist => $_->{artist}->{name},
					artist_mbid => $_->{artist}->{mbid},
				}
			} grep {
				$_->{artist} && $_->{artist}->{name}
			} @$candidates ];

			push @$candidates, @{ $client->pluginData('candidates') };
			$client->pluginData( shuffled => 0 );
			$client->pluginData( candidates => $candidates );
		}
	}
}

1;
