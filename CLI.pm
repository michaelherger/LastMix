package Plugins::LastMix::CLI;

use strict;

use Slim::Control::Request;
use Slim::Utils::Log;

use Plugins::LastMix::Plugin;
use Plugins::LastMix::LFM;

my $log = logger('plugin.lastmix');

sub init {
	# TODO - add support for play/add
	Slim::Control::Request::addDispatch(['lastmix'], [1, 0, 1, \&_cliMix]);
}

sub _cliMix {
	my $request = shift;

	my $client = $request->client();

	if (!$client) {
		$request->setStatusNeedsClient();
		return;
	}

	# get the tags
	my $tags = $request->getParam('tags');

	if (!$tags) {
		$request->setStatusBadParams();
		return;
	}

	Plugins::LastMix::Plugin::initClientPluginData($client);

	my %tags = ( map { s/\+/ /g; URI::Escape::uri_unescape($_) => 1 } split(',', $tags) );
	$client->pluginData(tags => \%tags);

	foreach my $tag (keys %tags) {
		Plugins::LastMix::LFM->getTagTopTracks(sub {
			_gotTagTracks($client, $tag, $request, @_);
		}, {
			tag => $tag,
			limit => 500
		});
	}
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

			Slim::Player::Playlist::fischer_yates_shuffle($candidates);

			my $tagTracks = $client->pluginData('candidates') || [];
			push @$tagTracks, grep { $_ } @$candidates;
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
				$client->execute(['playlist', 'playtracks', 'listRef', $tracks]);
			}

			$request->setStatusDone();
		});
	}
}

1;