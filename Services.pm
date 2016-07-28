package Plugins::LastMix::Services;

use strict;

use Slim::Utils::Log;

my $log = logger('plugin.lastmix');

my @serviceHandlers = qw(
	Plugins::LastMix::Services::Tidal
	Plugins::LastMix::Services::Spotify
	Plugins::LastMix::Services::Deezer
	Plugins::LastMix::Services::Napster
);

my $serviceHandler;

sub registerHandler {
	my ($class, $handlerClass) = @_;
	unshift @serviceHandlers, $handlerClass;
}

sub getServiceHandler {
	my ($class, $client) = @_;
	
	if ( ! defined $serviceHandler ) {
		foreach my $service ( @serviceHandlers ) {
			if ( $service->isEnabled($client) ) {
				$serviceHandler = $service->new($client);
				last;
			}
		}
		
		$serviceHandler ||= 0;
	}

	return $serviceHandler;
}

sub extractTrack {
	my ($class, $candidates, $args) = @_;

	my $artist = lc($args->{artist});
	my $title  = lc($args->{title});

	# XXX - apply some more smarts, like eg. "Tony Levin Band" vs. "Tony Levin", "Remaster" etc.
	# do some title/artist cleanup
	$candidates = [ grep {
		$_->{title} !~ /karaoke|sound.a.like|as.made.famous|original.*perfor.*by/i && $_->{artist} !~ /karaoke/
	} map {
		my $title = $class->cleanupTitle( lc($_->{title}) );
		my $artist = lc($_->{artist});
		
		# artist comes from a menu with "artist - album" in it
		$artist =~ s/ - .*//;

		{
			title  => lc($title),
			artist => lc($artist),
			url    => $_->{url},
		}
	} @$candidates ];
	
	if (main::INFOLOG && $log->is_info) {
		$log->info("Trying to match criteria: " . Data::Dump::dump($args));
		main::DEBUGLOG && $log->is_debug && $log->debug( Data::Dump::dump(
			map { "$_->{title} - $_->{artist}" } 
			grep { $_->{title} =~ /^\Q$title\E/ || $title =~ /^\Q$_->{title}\E/ }
			@$candidates)
		);
	} 
	
	# we don't care about tracks which don't even match the start of the title name
	my @candidates = grep { 
		$_->{title} =~ /^\Q$title\E/
	} @$candidates;

	# find match for "artist" - "title"
	my ($url) = map { $_->{url} } grep { $_->{title} eq $title && $_->{artist} eq $artist } @candidates;
	# "artist" - "title *"
	($url) = map { $_->{url} } grep { $_->{artist} eq $artist } @candidates unless $url;
	# "artist *" - "title"
	($url) = map { $_->{url} } grep { $_->{title} eq $title && $_->{artist} =~ /^\Q$artist\E/ } @candidates unless $url;
	# "artist *" - "title *"
	($url) = map { $_->{url} } grep { $_->{artist} =~ /^\Q$artist\E/ } @candidates unless $url;
	($url) = map { $_->{url} } grep { $artist =~ /^\Q$_->{artist}\E/ } @candidates unless $url;
	
	@candidates = grep { 
		$title =~ /^\Q$_->{title}\E/ 
	} @$candidates unless $url;
	
	# "title *" - "artist *"
	($url) = map { $_->{url} } grep { $title =~ /^\Q$_->{title}\E/ && $_->{artist} =~ /^\Q$artist\E/ } @candidates unless $url;

	if (main::INFOLOG && $log->is_info) {
		if ($url) {
			$log->info("Chose $url for " . Data::Dump::dump(grep {$_->{url} eq $url} @$candidates));
		}
		else {
			$log->info("No match!");
		}
	} 
	
	return $url;
}

sub cleanupTitle {
	my ($class, $title) = @_;

	# remove everything between () or []... But don't for PG's eponymous first four albums :-)
	$title =~ s/[\(\[].*?[\)\]]//g;
	
	# remove stuff like "2012", "live"
	$title =~ s/\d+\/\d+//ig;
	$title =~ s/- live\b//i;
	$title =~ s/- remaster.*//i;

	# remove trailing non-word characters
	$title =~ s/[\s\W]{2,}$//;
	$title =~ s/\s*$//;
	
	return $title;
}

1;

package Plugins::LastMix::Services::Base;

use base qw(Slim::Utils::Accessor);

{
	__PACKAGE__->mk_accessor('rw', qw(client cb args));
}

sub isEnabled {}

sub lookup {
	my ($class, $client, $cb, $args) = @_;
	
	$class->client($client) if $client;
	$class->cb($cb) if $cb;
	$class->args($args) if $args;
	
	Slim::Formats::XML->getFeedAsync(
		\&gotResults,
		\&gotError,
		{
			client => $client,
			url => Slim::Networking::SqueezeNetwork->url( $class->searchUrl ),
			class => $class,
		},
	);
}

sub gotResults {
	my ($feed, $params) = @_;

	my $class = $params->{class};
	my $candidates;
		
	# extract all potential streams
	if ($feed && $feed->{items}) {
		my $protocol = $params->{class}->protocol;
		
		push @$candidates, map {
			# some service handlers return one single line rather than two with title and artist
			if ( !($_->{line1} && $_->{line2}) ) {
				my ($title, $artist) = split(/ by /i, $_->{name});
				$_->{line1} ||= $title;
				$_->{line2} ||= $artist;
			}
			
			{
				title  => $_->{line1} || $_->{name},
				artist => $_->{line2},
				url    => $_->{play},
			}
		} grep { 
			$_->{play} && $_->{play} =~ /^\Q$protocol\E:/
		} @{$feed->{items}};
	}

	$class->cb->( $class->extractTrack($candidates) );
}

sub extractTrack {
	my ($class, $candidates) = @_;
	return Plugins::LastMix::Services->extractTrack($candidates, $class->args);
}

sub gotError {
	my ($error, $params) = @_;
	$log->error('LastMix Service lookup failed: ' . $error);
	$params->{class}->cb->();
}

sub protocol {}
sub searchUrl {}

1;


package Plugins::LastMix::Services::Tidal;

use base qw(Plugins::LastMix::Services::Base);

sub isEnabled {
	my ($class, $client) = @_;

	return if $Plugins::LastMix::Plugin::NOMYSB;
	
	return unless $client;
	return unless Slim::Utils::PluginManager->isEnabled('Slim::Plugin::WiMP::Plugin');

	return ( $client->isAppEnabled('WiMP') || $client->isAppEnabled('WiMPDK') ) ? 'wimp' : undef;
} 

sub protocol { 'wimp' }

sub searchUrl {
	my ($class) = @_;
	sprintf('/api/wimp/v1/opml/search?q=%s', URI::Escape::uri_escape_utf8($class->args->{title}));
}

1;


package Plugins::LastMix::Services::Deezer;

use base qw(Plugins::LastMix::Services::Base);

sub isEnabled {
	my ($class, $client) = @_;

	return if $Plugins::LastMix::Plugin::NOMYSB;
	
	return unless $client;
	return unless Slim::Utils::PluginManager->isEnabled('Slim::Plugin::Deezer::Plugin');

	return $client->isAppEnabled('Deezer') ? 'deezer' : undef;
} 

sub protocol { 'deezer' }

sub searchUrl {
	my ($class) = @_;
	sprintf('/api/deezer/v1/opml/search_tracks?q=%s', URI::Escape::uri_escape_utf8($class->args->{title}));
}

1;


package Plugins::LastMix::Services::Spotify;

use base qw(Plugins::LastMix::Services::Base);

my $use3rdPartySpotify;

sub isEnabled {
	my ($class, $client) = @_;

	return unless $client;
	
	if (!defined $use3rdPartySpotify) {
		$use3rdPartySpotify = (Slim::Utils::PluginManager->isEnabled('Plugins::Spotify::Plugin') || Slim::Utils::PluginManager->isEnabled('Plugins::SpotifyProtocolHandler::Plugin')) ? 1 : 0;
	}
	
	return if $Plugins::LastMix::Plugin::NOMYSB && !$use3rdPartySpotify; 

	return unless $use3rdPartySpotify || Slim::Utils::PluginManager->isEnabled('Slim::Plugin::SpotifyLogi::Plugin');
	
	return unless $use3rdPartySpotify || $client->isAppEnabled('Spotify');
	
	# spotify on ip3k only with Triode's plugin
	return unless $use3rdPartySpotify || ($client->isa('Slim::Player::SqueezePlay') && $client->model ne 'squeezeplay');

	return 'spotify';
} 

sub protocol { 'spotify' }

sub searchUrl {
	my ($class) = @_;
	sprintf('/api/spotify/v1/opml/search?type=track&q=track:%s%%20artist:%s', URI::Escape::uri_escape_utf8($class->args->{title}), URI::Escape::uri_escape_utf8($class->args->{artist}));
}


package Plugins::LastMix::Services::Napster;

use base qw(Plugins::LastMix::Services::Base);

sub isEnabled {
	my ($class, $client) = @_;
	
	return if $Plugins::LastMix::Plugin::NOMYSB;
	
	return if !$client;
	
	return if !$client->isa('Slim::Player::Squeezebox2') || $client->model eq 'squeezeplay';

	return unless Slim::Utils::PluginManager->isEnabled('Slim::Plugin::RhapsodyDirect::Plugin');
	
	return if !($client->isAppEnabled('RhapsodyDirect') || $client->isAppEnabled('RhapsodyEU')); 
	
	return 'napster';
} 

sub protocol { 'rhapd' }

sub searchUrl {
	my ($class) = @_;
	sprintf('/api/rhapsody/v1/opml/search/fastFindTracks?q=%s', URI::Escape::uri_escape_utf8($class->args->{title}));
}

1;

1;