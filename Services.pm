package Plugins::LastMix::Services;

use strict;

use Slim::Utils::Log;

my $log = logger('plugin.lastmix');

my @serviceHandlers;

my $serviceHandler;

sub registerHandler {
	my ($class, $handlerClass, $lossless) = @_;

	main::INFOLOG && $log->is_info && $log->info("Registering $handlerClass: " . ($lossless ? 'lossless' : 'lossy'));

	# if a plugin claims to be lossless streaming, put it at the top, otherwise below the top
	splice @serviceHandlers, ($lossless ? 0 : 1), 0, $handlerClass;
}

sub getServiceHandler {
	my ($class, $client) = @_;

	if ( ! defined $serviceHandler ) {
		foreach my $service ( @serviceHandlers ) {
			if ( $service->isEnabled($client) ) {
				$serviceHandler = $service->new($client);
				main::DEBUGLOG && $log->is_debug && $log->debug("Using $serviceHandler");
				last;
			}
		}

		$serviceHandler ||= 0;
	}

	return $serviceHandler;
}

sub init {
	foreach my $service ( @serviceHandlers ) {
		if ($service->can('init')) {
			$service->init();
		}
	}
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

	$log->error("No LastMix lookup() method defined for $class!");

	$cb->();
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
