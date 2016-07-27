package Plugins::LastMix::LFM;

use strict;
use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);

use Slim::Utils::Cache;
use Slim::Utils::Log;

use constant BASE_URL => 'http://ws.audioscrobbler.com/2.0/';
use constant CACHE_TTL => 60*60*24;

my $cache = Slim::Utils::Cache->new;
my $log = logger('plugin.lastmix');
my $aid;

sub init {
	shift->aid(shift->_pluginDataFor('id2'));
}

sub getSimilarTracks {
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
	
	_call({
		method => 'artist.getSimilar',
		artist => $args->{artist},
		autocorrect => 1,
		limit => 5,
	}, sub {
		$cb->(shift);
	});
}

sub getArtistTags {
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
		autocorrect => 1,
	}, sub {
		$cb->(shift);
	});
}



sub _call {
	my ($params, $cb) = @_;

	$params ||= {};
	my @query;
	
	while (my ($k, $v) = each %$params) {
		next if $k =~ /^_/;		# ignore keys starting with an underscore
		push @query, $k . '=' . uri_escape_utf8($v);
	}
	
	my $url = BASE_URL . '?' . join( '&', sort @query, 'api_key=' . aid(), 'format=json' );
	$url =~ s/\?$//;
	
	if ( my $cached = $cache->get($url) ) {
		$cb->($cached);
		return;
	}

	main::INFOLOG && $log->is_info && $log->info((main::SCANNER ? 'Sync' : 'Async') . ' API call: GET ' . _debug($url) );
	
	$params->{timeout} ||= 15;
	
	if ( !delete $params->{_nocache} ) {
		$params->{cache} = 1;
		$params->{expires} = CACHE_TTL;
	}
	
	my $cb2 = sub {
		my $response = shift;
		
		main::DEBUGLOG && $log->is_debug && $response->code !~ /2\d\d/ && $log->debug(_debug(Data::Dump::dump($response, @_)));
		my $result = eval { from_json( $response->content ) };
	
		$result ||= {};
		
		if ($@) {
			 $log->error($@);
			 $result->{error} = $@;
		}

		main::DEBUGLOG && $log->is_debug && warn Data::Dump::dump($result);
		
		$cache->set($url, $result, 30);
			
		$cb->($result);
	};
	
	Slim::Networking::SimpleAsyncHTTP->new( 
		$cb2,
		$cb2,
		$params
	)->get($url);
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