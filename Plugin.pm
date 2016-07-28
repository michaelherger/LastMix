package Plugins::LastMix::Plugin;

use strict;
use base qw(Slim::Plugin::Base);

use constant NOMYSB => Slim::Utils::Versions->compareVersions($::VERSION, '7.9') >= 0 && main::NOMYSB() ? 1 : 0;

# Only load the large parts of the code once we know Don't Stop The Music has been initialized
sub postinitPlugin {
	my $class = shift;
	
	# if the user has the Don't Stop The Music plugin enabled, register ourselves
	if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin') ) {
		require Slim::Plugin::DontStopTheMusic::Plugin;
		require Plugins::LastMix::DontStopTheMusic;
		require Plugins::LastMix::LFM;

		Plugins::LastMix::DontStopTheMusic->init($class);
		Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_LASTMIX_DSTM_ITEM', \&Plugins::LastMix::DontStopTheMusic::please);
		Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_LASTMIX_DSTM_LOCAL_ONLY', \&Plugins::LastMix::DontStopTheMusic::myMusicOnlyPlease);
		
		if ( Plugins::LastMix::LFM->getUsername() ) {
			Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_LASTMIX_DSTM_YOUR_FAVORITE_ARTISTS', \&Plugins::LastMix::DontStopTheMusic::favouriteArtistMix);
		}
	}
	else {
		Slim::Utils::Log::logError("The LastMix plugin requires the Don't Stop The Music plugin to be enabled - which is not the case.");
	}
}

1;