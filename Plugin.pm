package Plugins::LastMix::Plugin;

use base qw(Slim::Plugin::Base);

use constant NOMYSB => Slim::Utils::Versions->compareVersions($::VERSION, '7.9') >= 0 && main::NOMYSB() ? 1 : 0;

# Only load the large parts of the code once we know Don't Stop The Music has been initialized
sub postinitPlugin {
	my $class = shift;
	
	# if the user has the Don't Stop The Music plugin enabled, register ourselves
	if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin') ) {
		require Slim::Plugin::DontStopTheMusic::Plugin;
		require Plugins::LastMix::DontStopTheMusic;

		Plugins::LastMix::DontStopTheMusic->init($class);
		Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_LASTMIX_DSTM_ITEM', \&Plugins::LastMix::DontStopTheMusic::please);
		Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_LASTMIX_DSTM_LOCAL_ONLY', \&Plugins::LastMix::DontStopTheMusic::myMusicOnlyPlease);
	}
	else {
		$log->warn("The LastMix plugin requires the Don't Stop The Music to be running - which is not the case.");
	}
}

1;