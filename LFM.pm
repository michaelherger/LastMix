package Plugins::LastMix::LFM;

use strict;
use JSON::XS::VersionOneAndTwo;
use Digest::MD5 qw(md5_hex);
use URI::Escape qw(uri_escape_utf8);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use constant BASE_URL => 'http://ws.audioscrobbler.com/2.0/';
use constant CACHE_TTL => 30*60;
use constant LASTFM_MAX_ITEMS => 149;

my $cache = Slim::Utils::Cache->new;
my $log = logger('plugin.lastmix');
my $lfmPrefs = preferences('plugin.audioscrobbler');
my $aid;

sub init {
	shift->aid(shift->_pluginDataFor('id2'));
}

sub getUsername {
	my ( $class, $client ) = @_;

	my $username = $lfmPrefs->client($client->master)->get('account') if $client;

	if (!$username) {
		my $accounts = $lfmPrefs->get('accounts');
		if ($accounts && ref $accounts && scalar @$accounts) {
			my $account = $accounts->[ $lfmPrefs->get('account') || 0 ];
			if ($account) {
				$username = $account->{username};
			}
		}
	}

	return $username;
}

sub getPasswordHash {
	my ( $class, $username ) = @_;
	my $accounts = $lfmPrefs->get('accounts') || [];

	my ($password) = map {
		$_->{password}
	} grep {
		$_->{username} eq $username
	} @$accounts;

	return $password;
}

# get a session using a username and authToken
sub getMobileSession {
	my ( $class, $cb, $username ) = @_;

	my $result = _call( {
		method => 'auth.getMobileSession',
		_verb   => 'POST',
		username  => $username,
		authToken => md5_hex($username . $class->getPasswordHash($username)),
		_signed   => 1,
		_nocache  => 1,
	}, sub {
		my $result = shift;

		my $sessionKey;
		eval {
			$sessionKey = $result->{session}->{key};
		};

		$@ && $log->error("failed to get session key:" . $@);

		$cb->($sessionKey);
	} );
}

sub loveTrack {
	my ( $class, $cb, $username, $artist, $title ) = @_;

	$class->getMobileSession(sub {
		my $sessionKey = shift;

		if ($sessionKey) {
			_call( {
				method => 'track.love',
				_verb   => 'POST',
				_nocache => 1,
				track   => $title,
				artist  => $artist,
				sk      => $sessionKey,
				_signed => 1,
			}, $cb );

			return;
		}

		$cb->();
	}, 'mherger');
}

sub getSimilarTracks {
	my ( $class, $cb, $args ) = @_;

	if ($args->{mbid}) {
		_call({
			method => 'track.getSimilar',
			mbid => $args->{mbid},
		}, sub {
			my $results = shift;

			if ( $results && ref $results && $results->{similartracks} && ref $results->{similartracks} ) {
				$cb->($results);
			}
			else {
				$class->getSimilarTracksByName($cb, $args);
			}
		});
	}
	else {
		$class->getSimilarTracksByName($cb, $args);
	}
}

=pod
sub getLovedTracks {
	my ( $class, $cb, $args ) = @_;

	if ( my $username = $class->getUsername ) {
		_call({
			method => 'user.getLovedTracks',
			user => $username,
		}, sub {
			my $results = shift;

#warn Data::Dump::dump($results);
			if ( $results && ref $results && $results->{similartracks} && ref $results->{similartracks} ) {
#				$cb->($results);
			}
			else {
#				$class->getSimilarTracksByName($cb, $args);
			}
		});
	}
	else {
		$class->getSimilarTracksByName($cb, $args);
	}
}
=cut

sub getSimilarTracksByName {
	my ( $class, $cb, $args ) = @_;

	_call({
		method => 'track.getSimilar',
		artist => $args->{artist},
		track  => $args->{title},
		autocorrect => 1,
	}, sub {
		$cb->(shift);
	});
}

=pod
sub getTrackTags {
	my ( $class, $cb, $args ) = @_;

	_call({
		method => 'track.getTopTags',
		artist => $args->{artist},
		track  => $args->{title},
		autocorrect => 1,
	}, sub {
		$cb->(shift);
	});
}
=cut

sub getSimilarArtists {
	my ( $class, $cb, $args ) = @_;

	if ($args->{mbid}) {
		_call({
			method => 'artist.getSimilar',
			mbid => $args->{mbid},
			limit => 25,
		}, sub {
			my $results = shift;

			if ( $results && ref $results && $results->{similarartists} && ref $results->{similarartists} ) {
				$cb->($results);
			}
			else {
				$class->getSimilarArtistsByName($cb, $args);
			}
		});
	}
	else {
		$class->getSimilarArtistsByName($cb, $args);
	}
}

sub getSimilarArtistsByName {
	my ( $class, $cb, $args ) = @_;

	_call({
		method => 'artist.getSimilar',
		artist => $args->{artist},
		autocorrect => 1,
		limit => 25,
	}, sub {
		$cb->(shift);
	});
}

sub getFavouriteArtists {
	my ( $class, $cb, $args ) = @_;

	_call({
		method => 'user.getTopArtists',
		username => $args->{username} || $class->getUsername(),
		limit => 50,
	}, sub {
		$cb->(shift);
	});
}

sub getArtistTags {
	my ( $class, $cb, $args ) = @_;

	if ($args->{mbid}) {
		_call({
			method => 'artist.getTopTags',
			mbid => $args->{mbid},
		}, sub {
			my $results = shift;

			if ( $results && ref $results && $results->{toptags} && ref $results->{toptags} ) {
				$cb->($results);
			}
			else {
				$class->getArtistTagsByArtistName($cb, $args);
			}
		});
	}
	else {
		$class->getArtistTagsByArtistName($cb, $args);
	}
}

sub getArtistTagsByArtistName {
	my ( $class, $cb, $args ) = @_;

	_call({
		method => 'artist.getTopTags',
		artist => $args->{artist},
		autocorrect => 1,
	}, sub {
		$cb->(shift);
	});
}

sub getArtistTopTracks {
	my ( $class, $cb, $args ) = @_;

	if ($args->{mbid}) {
		_call({
			method => 'artist.getTopTracks',
			mbid => $args->{mbid},
		}, sub {
			my $results = shift;

			if ( $results && ref $results && $results->{toptracks} && ref $results->{toptracks} ) {
				$cb->($results);
			}
			else {
				$class->getArtistTopTracksByArtistName($cb, $args);
			}
		});
	}
	else {
		$class->getArtistTopTracksByArtistName($cb, $args);
	}
}

sub getArtistTopTracksByArtistName {
	my ( $class, $cb, $args ) = @_;

	_call({
		method => 'artist.getTopTracks',
		artist => $args->{artist},
		autocorrect => 1,
	}, sub {
		$cb->(shift);
	});
}

sub getTagTopTracks {
	my ( $class, $cb, $args ) = @_;

	_call({
		method => 'tag.getTopTracks',
		tag => $args->{tag},
		limit => $args->{limit} || 50,
		autocorrect => 1,
	}, sub {
		$cb->(shift);
	});
}

sub getTopTags {
	my ( $class, $cb, $args ) = @_;

	_call({
		method => 'tag.getTopTags',
		num_res => $args->{limit} || LASTFM_MAX_ITEMS
	}, sub {
		$cb->(shift);
	});
}


sub _call {
	my ($params, $cb) = @_;

	$params ||= {};
	my $verb = delete $params->{_verb} || 'GET';

	my @query = ('api_key=' . aid());

	while (my ($k, $v) = each %$params) {
		next if $k =~ /^_/;		# ignore keys starting with an underscore
		push @query, $k . '=' . uri_escape_utf8($v);
	}

	my $url = BASE_URL;

	# sign request if needed
	if ( delete $params->{_signed} ) {
		my %p = %{{ %$params, api_key => aid() }};

		my $sig = join('', map {
			$_ . $p{$_}
		} grep {
			$_ !~ /^_/
		} sort keys %p );

		push @query, 'api_sig=' . md5_hex($sig . (Plugins::LastMix::Plugin->_pluginDataFor('id3') =~ s/-//rg));
		$url =~ s/^http:/https:/;
	}

	push @query, 'format=json';
	my $query = join('&', sort @query);
	$url .= "?$query" if $verb eq 'GET';
	$url =~ s/\?$//;

	if ( !$params->{_nocache} && (my $cached = $cache->get($query)) ) {
		main::INFOLOG && $log->is_info && $log->info("Returning cached result for: " . _debug($url) );
		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($cached));
		$cb->($cached);
		return;
	}

	main::INFOLOG && $log->is_info && $log->info("API call: $verb " . _debug($url) );

	$params->{timeout} ||= 15;

	if ( !$params->{_nocache} ) {
		$params->{cache} = 1;
		$params->{expires} = CACHE_TTL;
	}

	my $cb2 = sub {
		my $response = shift;

		if ($response->code >= 400) {
			$log->error(sprintf("LastMix API HTTP error %s: %s", $response->code, $response->message));
			main::INFOLOG && $log->is_info && $log->info(_debug(Data::Dump::dump($response, @_)));
		}
		elsif (main::DEBUGLOG && $log->is_debug && $response->code !~ /2\d\d/) {
			$log->debug(_debug(Data::Dump::dump($response, @_)));
		}

		my $result = eval { from_json( $response->content ) };

		$result ||= {};

		if ($@) {
			 $log->error($@);
			 $result->{error} = $@;
		}

		if ($result->{error}) {
			if (main::INFOLOG) {
				$log->error(Data::Dump::dump($result));
			}
			else {
				$log->error("LastMix API error " . $result->{error} . ": " . $result->{message});
			}
		}
		elsif (main::DEBUGLOG && $log->is_debug) {
			$log->debug(Data::Dump::dump($result));
		}

		$cache->set($query, $result, CACHE_TTL) if !$params->{_nocache} && !$result->{error};

		$cb->($result);
	};

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		$cb2,
		$cb2,
		$params
	);

	if ($verb eq 'POST') {
		$http->post($url, 'Content-Type' => 'application/x-www-form-urlencoded', $query);
	}
	else {
		$http->get($url);
	}
}

sub aid {
	if ( $_[1] ) {
		$aid = $_[1];
		$aid =~ s/-//g;
		$cache->set('lfm_aid', $aid, 'never');
	}

	$aid ||= $cache->get('lfm_aid');

	return $aid;
}

sub _debug {
	my $msg = shift;
	$msg =~ s/api_key=.*?(&|$)//gi;
	return $msg;
}

1;