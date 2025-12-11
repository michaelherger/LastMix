package Plugins::LastMix::CLI;

use strict;

use Slim::Control::Request;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::LastMix::Plugin;
use Plugins::LastMix::LFM;

use constant LASTFM_MAX_ITEMS => 149;

my $log = logger('plugin.lastmix');

sub init {
	Slim::Control::Request::addDispatch(['lastmix', 'play'], [1, 0, 1, \&_cliMix]);
	Slim::Control::Request::addDispatch(['lastmix', 'add'], [1, 0, 1, \&_cliMix]);
}

sub _cliMix {
	my $request = shift;

	my $client = $request->client();

	if (!$client) {
		$request->setStatusNeedsClient();
		return;
	}

	if ($request->isNotCommand([['lastmix'], ['play','add']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $tags = $request->getParam('tags');
	my $artist = $request->getParam('artist');

	if (!$tags && !$artist) {
		$request->setStatusBadParams();
		return;
	}

	Plugins::LastMix::Plugin::initClientPluginData($client);

	if ($artist) {
		Plugins::LastMix::DontStopTheMusic::getArtistTracks($client, sub {
			my $tracks = $_[1];
			_gotArtistTracks($client, $artist, $request, $tracks);
		}, [ split(',', $artist) ]);
	}
	else {
		my %tags = ( map { s/\+/ /g; URI::Escape::uri_unescape($_) => 1 } split(',', $tags) );

		$client->pluginData(tags => \%tags);

		foreach my $tag (keys %tags) {
			Plugins::LastMix::LFM->getTagTopTracks(sub {
				_gotTagTracks($client, $tag, $request, @_);
			}, {
				tag => $tag,
				limit => LASTFM_MAX_ITEMS
			});
		}
	}
}

sub _gotArtistTracks {
	my ($client, $artist, $request, $tracks) = @_;

	if ( !($tracks && scalar @$tracks) ) {
		main::INFOLOG && $log->is_info && $log->info("LastFM mix failed, try local files to get started");

		my $randomFunction = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->randomFunction();

		foreach my $artistName ( split(',', $artist) ) {
			my $artistRequest = Slim::Control::Request->new( undef, [ 'artists', 0, 1, 'search:' . URI::Escape::uri_unescape($artistName) ] );
			$artistRequest->execute();

			foreach my $artistId ( @{ $artistRequest->getResult('artists_loop') || [] } ) {
				my $tracksRequest = Slim::Control::Request->new( undef, [ 'titles', 0, Plugins::LastMix::Plugin::MAX_TRACKS, 'artist_id:' . $artistId->{id}, "sort:sql=$randomFunction", 'tags:u' ] );
				$tracksRequest->execute();
				push @$tracks, map { $_->{url} } @{ $tracksRequest->getResult('titles_loop') || [] };
			}

			main::idleStreams();
		}
	}

	my $cmd = $request->getRequest(1);
	$client->execute(['playlist', $cmd . 'tracks', 'listRef', $tracks]);

	if ( $request->getParam('dstm') && Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin') ) {
		preferences('plugin.dontstopthemusic')->client($client)->set('provider', 'PLUGIN_LASTMIX_DSTM_ITEM');
	}

	$request->setStatusDone();
}

sub _gotTagTracks {
	my ($client, $tag, $request, $results) = @_;

	if ( $results && ref $results && $results->{tracks} && ref $results->{tracks} && (my $candidates = $results->{tracks}->{track}) ) {
		# store the tracks if we got some
		if ( $candidates && ref $candidates && scalar @$candidates ) {
			$candidates = [ grep { $_ } map {
				{
					title  => $_->{name},
					mbid   => $_->{mbid},
					artist => $_->{artist}->{name},
					artist_mbid => $_->{artist}->{mbid},
				}
			} @$candidates ];

			my $tagTracks = $client->pluginData('candidates') || [];
			push @$tagTracks, grep { $_ } @$candidates;
			$client->pluginData(shuffled => 0);
			$client->pluginData(candidates => $tagTracks);
		}
	}

	my $tags = $client->pluginData('tags');
	delete $tags->{$tag};

	# when we've processed all tags, continue
	if (!keys %$tags) {
		Plugins::LastMix::Plugin::checkTracks($client, sub {
			my ($client, $tracks) = @_;

			if ( $tracks && scalar @$tracks ) {
				my $cmd = $request->getRequest(1);
				$client->execute(['playlist', $cmd . 'tracks', 'listRef', $tracks]);
			}

			$request->setStatusDone();
		});
	}
}

1;