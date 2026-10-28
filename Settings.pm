package Plugins::LastMix::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.lastmix');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_LASTMIX_NAME');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/LastMix/settings/basic.html');
}

sub prefs {
	return ($prefs, qw(useCustomApiKey apiKey apiSecret));
}

sub handler {
	my ($class, $client, $paramRef) = @_;

	if ($paramRef->{saveSettings}) {
		# keys are often copied from the Last.fm page with surrounding whitespace
		foreach (qw(pref_apiKey pref_apiSecret)) {
			$paramRef->{$_} =~ s/^\s+|\s+$//g if defined $paramRef->{$_};
		}
	}

	return $class->SUPER::handler($client, $paramRef);
}

1;
