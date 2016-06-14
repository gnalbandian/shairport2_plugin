package Plugins::ShairTunes2::AIRPLAY;

use strict;
use warnings;
use base qw(Slim::Player::Pipeline);
use Slim::Utils::Strings qw(string);
use Slim::Utils::Misc;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

Slim::Player::ProtocolHandlers->registerHandler( 'airplay', __PACKAGE__ );

my $log   = logger( 'plugin.airplay' );
my $prefs = preferences( 'plugin.airplay' );

sub isRemote { 1 }

sub bufferThreshold { 20 }

sub new { undef }

sub canDoAction {
    my ( $class, $client, $url, $action ) = @_;
    $log->info( "Action=$action" );

    #if (($action eq 'pause') && $prefs->get('pausestop') ) {
    #	$log->info("Stopping track because pref is set yo stop");
    #	return 0;
    #}

    return 1;
}

sub canHandleTranscode {
    my ( $self, $song ) = @_;

    return 1;
}

sub getStreamBitrate {
    my ( $self, $maxRate ) = @_;

    return Slim::Player::Song::guessBitrateFromFormat( ${*$self}{'contentType'}, $maxRate );
}

sub isAudioURL { 1 }

# XXX - I think that we scan the track twice, once from the playlist and then again when playing
sub scanUrl {
    my ( $class, $url, $args ) = @_;

    Slim::Utils::Scanner::Remote->scanURL( $url, $args );
}

sub canDirectStream {
    my ( $class, $client, $url ) = @_;

    $log->info( "canDirectStream $url" );

    $url =~ s{^airplay://}{http://};

    return $url;
}

sub contentType {
    my $self = shift;

    return ${*$self}{'contentType'};
}

sub getMetadataFor {
    my ( $class, $client, $url, $forceCurrent ) = @_;

    my %metaData     = Plugins::ShairTunes2::Plugin->getAirTunesMetaData();
    my $metaArtist   = $metaData{artist};
    my $metaTitle    = $metaData{title};
    my $metaAlbum    = $metaData{album};
    my $metaBitRate  = $metaData{bitrate};
    my $metaCover    = $metaData{cover};
    my $metaDuration = $metaData{duration};
    my $metaPosition = $metaData{position};

    # $client->streamingSong->duration( $metaDuration );
    # $client->playingSong()->startOffset( $metaPosition );

    return {
        artist  => $metaArtist,
        title   => $metaTitle,
        album   => $metaAlbum,
        bitrate => $metaBitRate,
        cover   => $metaCover,
        icon    => $metaCover,
        type    => 'ShairTunes Stream',
      }

}

1;

# Local Variables:
# tab-width:4
# indent-tabs-mode:t
# End:
