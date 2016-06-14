package Plugins::ShairTunes2::Plugin;

use strict;
use warnings;

use Plugins::ShairTunes2::AIRPLAY;
use Plugins::ShairTunes2::Utils;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Network;
use Slim::Networking::Async;
use Slim::Networking::Async::Socket;
use Slim::Networking::Async::Socket::HTTP;

use Config;
use Digest::MD5 qw(md5 md5_hex);
use MIME::Base64;
use File::Spec;
use File::Which;
use POSIX qw(:errno_h);
use Data::Dumper;

use IO::Socket::INET6;
use Crypt::OpenSSL::RSA;
use Net::SDP;
use IPC::Open3;
use IO::Handle;

use constant CAN_IMAGEPROXY => ( Slim::Utils::Versions->compareVersions( $::VERSION, '7.8.0' ) >= 0 );

# create log categogy before loading other modules
my $log = Slim::Utils::Log->addLogCategory(
    {
        'category'     => 'plugin.shairtunes',
        'defaultLevel' => 'INFO',
        'description'  => getDisplayName(),
    }
);

my $cover_cache = '';
my $cachedir    = preferences( 'server' )->get( 'cachedir' );
if ( !-d File::Spec->catdir( $cachedir, "shairtunes" ) ) {
    mkdir( File::Spec->catdir( $cachedir, "shairtunes" ) );
}

my $prefs         = preferences( 'plugin.shairtunes' );
my $hairtunes_cli = "";

my $airport_pem = _airport_pem();
my $rsa         = Crypt::OpenSSL::RSA->new_private_key( $airport_pem )
  || do { $log->error( "RSA private key import failed" ); return; };

my %clients     = ();
my %sockets     = ();
my %players     = ();
my %connections = ();

my $samplingRate     = 44100;
my $positionRealTime = 0;
my $durationRealTime = 0;

my $title   = "ShairTunes Title";
my $artist  = "ShairTunes Artist";
my $album   = "ShairTunes Album";
my $bitRate = $samplingRate . " Hz";
my $cover   = "";

my %airTunesMetaData = (
    artist   => $artist,
    title    => $title,
    album    => $album,
    bitrate  => $bitRate,
    cover    => $cover,
    duration => $durationRealTime,
    position => $positionRealTime,
);

sub getAirTunesMetaData {
    return %airTunesMetaData;
}

sub initPlugin {
    my $class = shift;

    $log->info( "Initialising " . $class->_pluginDataFor( 'version' ) . " on " . $Config{'archname'} );

    revoke_publishPlayer();

    # Subscribe to player connect/disconnect messages
    Slim::Control::Request::subscribe( \&playerSubscriptionChange,
        [ ['client'], [ 'new', 'reconnect', 'disconnect' ] ] );

    if ( CAN_IMAGEPROXY ) {
        require Slim::Web::ImageProxy;
        Slim::Web::ImageProxy->import();
        Slim::Web::ImageProxy->registerHandler(
            match => qr/shairtunes:image:/,
            func  => \&_getcover,
        );
    }
    else {
        $log->error( "Imageproxy not supported! Covers disabled!" );
    }

    return 1;
}

sub getDisplayName {
    return ( 'PLUGIN_SHAIRTUNES2' );
}

sub shutdownPlugin {
    revoke_publishPlayer();
    return;
}

sub _getcover {
    my ( $url, $spec, $cb ) = @_;

    # $url is aforementioned image URL
    # $spec we don't need (yet)
    # $cb is the callback to be called with the URL

    my ( $track_id ) = $url =~ m|shairtunes:image:(.*?)$|i;

    my $imagefilepath = File::Spec->catdir( $cachedir, 'shairtunes', $track_id . "_cover.jpg" );

    $log->debug( "_getcover called for $imagefilepath" );

    # now return the URLified file path
    return Slim::Utils::Misc::fileURLFromPath( $imagefilepath );
}

sub playerSubscriptionChange {
    my $request = shift;
    my $client  = $request->client;

    my $reqstr     = $request->getRequestString();
    my $clientname = $client->name();

    $log->debug( "request=$reqstr client=$clientname" );

    if ( ( $reqstr eq "client new" ) || ( $reqstr eq "client reconnect" ) ) {
        $sockets{$client} = createListenPort();
        $players{ $sockets{$client} } = $client;

        if ( $sockets{$client} ) {

            # Add us to the select loop so we get notified
            Slim::Networking::Select::addRead( $sockets{$client}, \&handleSocketConnect );

            $clients{$client} = publishPlayer( $clientname, "", $sockets{$client}->sockport() );
        }
        else {
            $log->error( "could not create ShairTunes socket for $clientname" );
            delete $sockets{$client};
        }
    }
    elsif ( $reqstr eq "client disconnect" ) {
        $log->debug( "publisher for $clientname PID $clients{$client} will be terminated." );
        kill 'TERM', $clients{$client};
        Slim::Networking::Select::removeRead( $sockets{$client} );
    }
}

sub createListenPort {
    my $listen;

    $listen = new IO::Socket::INET6(
        Listen    => 1,
        Domain    => AF_INET6,
        ReuseAddr => 1,
        Proto     => 'tcp',
    );

    $listen ||= new IO::Socket::INET(
        Listen    => 1,
        ReuseAddr => 1,
        Proto     => 'tcp',
    );

    if ( !$listen ) {
        $log->error( "Socket creation failed!: $!" );

    }

    return $listen;
}

sub revoke_publishPlayer {

    # pidof is OK here as it only works for the running user
    # and squeezeserver uses a dedicated one
    # so we can simply take care of all
    my @pids = split( /\s+/, `pidof avahi-publish-service dns-sd mDNSPublish 2>/dev/null` );

    if ( @pids ) {

        # use ->error as ->info does not always work while in plugin init
        $log->error( "Send TERM sig to old publish player services. pids: " . join( ", ", @pids ) );

        # -TERM is available since perl 5.18
        kill 'TERM', @pids;
    }
}

sub publishPlayer {
    my ( $apname, $password, $port ) = @_;

    my $pw_clause = ( length $password ) ? "pw=true" : "pw=false";
    my @hw_addr = +( map( ord, split( //, md5( $apname ) ) ) )[ 0 .. 5 ];

    my $pid = fork();
    if ( $pid == 0 ) {
        no warnings;
        eval {
            if ( which('avahi-publish-service') ) {
                $log->info( "start avahi-publish-service \"$apname\"" );
                exec(
                    'avahi-publish-service', join( '', map { sprintf "%02X", $_ } @hw_addr ) . "\@$apname",
                    "_raop._tcp",            $port,
                    "tp=UDP",                "sm=false",
                    "sv=false",              "ek=1",
                    "et=0,1",                "md=0,1,2",
                    "cn=0,1",                "ch=2",
                    "ss=16",                 "sr=44100",
                    $pw_clause,              "vn=3",
                    "txtvers=1"
                );
                $log->error( "start avahi-publish-service failed" );
            }
            else {
                $log->info( "avahi-publish-player not in path" );
            }
        };
        eval {
            if ( which('dns-sd') ) {
                $log->info( "start dns-sd \"$apname\"" );
                exec(
                    'dns-sd', '-R',
                    join( '', map { sprintf "%02X", $_ } @hw_addr ) . "\@$apname", "_raop._tcp",
                    ".",        $port,
                    "tp=UDP",   "sm=false",
                    "sv=false", "ek=1",
                    "et=0,1",   "md=0,1,2",
                    "cn=0,1",   "ch=2",
                    "ss=16",    "sr=44100",
                    $pw_clause, "vn=3",
                    "txtvers=1"
                );
                $log->error( "start dns-sd failed" );
            }
            else {
                $log->info( "dns-sd not in path" );
            }
        };
        eval {
            if ( which('mDNSPublish') ) {
                $log->info( "start mDNSPublish \"$apname\"" );
                exec(
                    'mDNSPublish', join( '', map { sprintf "%02X", $_ } @hw_addr ) . "\@$apname",
                    "_raop._tcp",  $port,
                    "tp=UDP",      "sm=false",
                    "sv=false",    "ek=1",
                    "et=0,1",      "md=0,1,2",
                    "cn=0,1",      "ch=2",
                    "ss=16",       "sr=44100",
                    $pw_clause,    "vn=3",
                    "txtvers=1"
                );
                $log->error( "start mDNSPublish failed" );
            }
            else {
                $log->info( "mDNSPublish not in path" );
            }
        };
        $log->error( "could not run avahi-publish-service nor dns-sd nor mDNSPublish" );
    }

    return $pid;
}

sub handleSocketConnect {
    my $socket = shift;
    my $player = $players{$socket};

    my $new = $socket->accept;
    $log->info( "New connection from " . $new->peerhost );

    # set socket to unblocking mode => 0
    Slim::Utils::Network::blocking( $new, 0 );
    $connections{$new} = { socket => $socket, player => $player };

    # Add us to the select loop so we get notified
    Slim::Networking::Select::addRead( $new, \&handleSocketRead );
}

sub handleSocketRead {
    my $socket = shift;

    if ( eof( $socket ) ) {
        $log->debug( "Closed: " . $socket );

        Slim::Networking::Select::removeRead( $socket );

        close $socket;
        delete $connections{$socket};
    }
    else {
        conn_read_data( $socket );
    }
}

sub conn_read_data {
    my $socket = shift;

    my $conn = $connections{$socket};

    my $contentLength = 0;
    my $buffer        = "";

    my $bytesToRead = 4096;

    # read header
    while ( 1 ) {
        my $ret = read( $socket, my $incoming, $bytesToRead );
        next if !defined $ret && $! == EAGAIN;
        $log->error( "Reading socket failed!: $!" ) if !defined $ret;
        last if !$ret;    # ERROR or EOF

        $log->debug( "conn_read_data: read $ret bytes." );

        $buffer .= $incoming;

        last if ( $incoming =~ /\r\n\r\n/ );
    }
    my ( $header, $contentBody ) = split( /\r\n\r\n/, $buffer, 2 );

    # get body length
    if ( $header =~ /Content-Length:\s(\d+)/ ) {
        $contentLength = $1;
        $log->debug( "Content Length is: " . $contentLength );
    }

    $log->debug( "ContentBody length already received: " . length( $contentBody ) );

    $bytesToRead = $contentLength - length( $contentBody );
    while ( $bytesToRead > 0 ) {
        $log->debug( "Content not yet completely received. Waiting..." );
        ### In the next loop just read whats missing.
        my $ret = read( $socket, my $incoming, $bytesToRead );
        next if !defined $ret && $! == EAGAIN;
        $log->error( "Reading socket failed!: $!" ) if !defined $ret;
        last if !$ret;    # ERROR or EOF

        $contentBody .= $incoming;
        $bytesToRead = $contentLength - length( $contentBody );
    }

    $log->debug( "Handle request..." );
    ### START: Not yet updated.
    $conn->{req} = HTTP::Request->parse( $header );
    $conn->{req}->content( $contentBody );

    conn_handle_request( $socket, $conn );
    ### END: Not yet updated.
}

sub conn_handle_request {
    my ( $socket, $conn ) = @_;

    my $req  = $conn->{req};
    my $resp = HTTP::Response->new( 200 );

    $resp->request( $req );
    $resp->protocol( $req->protocol );

    $resp->header( 'CSeq',              $req->header( 'CSeq' ) );
    $resp->header( 'Audio-Jack-Status', 'connected; type=analog' );

    if ( my $chall = $req->header( 'Apple-Challenge' ) ) {
        my $data = decode_base64( $chall );
        my $ip   = $socket->sockhost;
        if ( $ip =~ /((\d+\.){3}\d+)$/ ) {    # IPv4
            $data .= join '', map { chr } split( /\./, $1 );
        }
        else {
            $data .= Plugins::ShairTunes2::Utils::ip6bin( $ip );
        }

        my @hw_addr = +( map( ord, split( //, md5( $conn->{player}->name() ) ) ) )[ 0 .. 5 ];

        $data .= join '', map { chr } @hw_addr;
        $data .= chr( 0 ) x ( 0x20 - length( $data ) );

        $rsa->use_pkcs1_padding;              # this isn't hashed before signing
        my $signature = encode_base64 $rsa->private_encrypt( $data ), '';
        $signature =~ s/=*$//;
        $resp->header( 'Apple-Response', $signature );
    }

    if ( defined $conn->{password} && length $conn->{password} ) {
        if ( !Plugins::ShairTunes2::Utils::digest_ok( $req, $conn ) ) {
            my $nonce = md5_hex( map { rand } 1 .. 20 );
            $conn->{nonce} = $nonce;
            my $apname = $conn->{player}->name();
            $resp->header( 'WWW-Authenticate', "Digest realm=\"$apname\", nonce=\"$nonce\"" );
            $resp->code( 401 );
            $req->method( 'DENIED' );
        }
    }

    for ( $req->method ) {
        $log->debug( "got command / method: $_" );

        /^OPTIONS$/ && do {
            $resp->header( 'Public',
                'ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER' );

            # OPTIONS is called every 2s so ideal to read all errors on a regular basis
            if ( my $derr = $conn->{decoder_fherr} ) {
                while ( <$derr> ) { $log->error( "Decoder error: " . $_ ); }
            }

            last;
        };

        /^ANNOUNCE$/ && do {
            my $sdp   = Net::SDP->new( $req->content );
            my $audio = $sdp->media_desc_of_type( 'audio' );

            do { $log->error( "no AESIV" ); return; } unless my $aesiv = decode_base64( $audio->attribute( 'aesiv' ) );
            do { $log->error( "no AESKEY" ); return; }
              unless my $rsaaeskey = decode_base64( $audio->attribute( 'rsaaeskey' ) );
            $rsa->use_pkcs1_oaep_padding;
            my $aeskey = $rsa->decrypt( $rsaaeskey ) || do { $log->error( "RSA decrypt failed" ); return; };

            $conn->{aesiv}  = $aesiv;
            $conn->{aeskey} = $aeskey;
            $conn->{fmtp}   = $audio->attribute( 'fmtp' );
            last;
        };

        /^SETUP$/ && do {
            my $transport = $req->header( 'Transport' );
            $transport =~ s/;control_port=(\d+)//;
            my $cport = $1;
            $transport =~ s/;timing_port=(\d+)//;
            my $tport = $1;
            $transport =~ s/;server_port=(\d+)//;
            my $dport = $1;
            $resp->header( 'Session', 'DEADBEEF' );

            my %dec_args = (
                iv    => unpack( 'H*', $conn->{aesiv} ),
                key   => unpack( 'H*', $conn->{aeskey} ),
                fmtp  => $conn->{fmtp},
                cport => $cport,
                tport => $tport,
                dport => $dport,
            );

            my $shairtunes_helper = Plugins::ShairTunes2::Utils::helperBinary();

            if ( !$shairtunes_helper || !-x $shairtunes_helper ) {
                $log->error( "I'm sorry your platform \""
                      . $Config{archname}
                      . "\" is unsupported or nobody has compiled a binary for it! Can't work." );
                last;
            }

            my $helper_cmd = '"'
              . $shairtunes_helper . '"'
              . join( ' ', '', map { sprintf "%s '%s'", $_, $dec_args{$_} } keys( %dec_args ) );
            $log->debug( "decode command: $helper_cmd" );

            my ( $helper_in, $helper_out, $helper_err ) = ( IO::Handle->new(), IO::Handle->new(), IO::Handle->new() );

            my $tied = tied *STDERR;
            untie *STDERR if $tied;
            my $helper_pid = open3( $helper_in, $helper_out, $helper_err, $shairtunes_helper, %dec_args );
            tie *STDERR, 'Tie::Restore', $tied if $tied;

            $helper_out->blocking( 0 );
            $helper_err->blocking( 0 );
            my $sel = IO::Select->new();
            $sel->add( $helper_out );
            $sel->add( $helper_err );

            $conn->{decoder_pid}   = $helper_pid;
            $conn->{decoder_fh}    = $helper_in;
            $conn->{decoder_fherr} = $helper_err;

            my %helper_ports = ( cport => '', hport => '', port => '' );
            my @ready;
            while ( @ready = $sel->can_read( 5 ) ) {
                foreach my $reader ( @ready ) {
                    while ( defined( my $line = $reader->getline ) ) {
                        $log->error( $line ) and next if ( $line =~ /^shairport_helper: / );
                        if ( $reader == $helper_err ) {
                            $log->error( "Helper error: " . $line );
                            next;
                        }
                        if ( $line =~ /^([ch]?port):\s*(\d+)/ ) {
                            $helper_ports{$1} = $2;
                            next;
                        }
                        $log->error( "Helper unknown output: " . $line );
                    }
                }
                last if ( !grep { !$helper_ports{$_} } keys %helper_ports );
            }
            $sel->remove( $helper_out );
            $sel->remove( $helper_err );

            $log->info(
                "launched decoder: $helper_pid on ports: $helper_ports{port}/$helper_ports{cport}/$helper_ports{hport}"
            );
            $resp->header( 'Transport', $req->header( 'Transport' ) . ";server_port=$helper_ports{port}" );

            my $host         = Slim::Utils::Network::serverAddr();
            my $url          = "airplay://$host:$helper_ports{hport}/stream.wav";
            my $client       = $conn->{player};
            my @otherclients = grep { $_->name ne $client->name and $_->power } $client->syncGroupActiveMembers();
            foreach my $otherclient ( @otherclients ) {
                $log->info( 'turning off: ' . $otherclient->name );
                $otherclient->display->showBriefly(
                    { line => [ 'AirPlay streaming to ' . $client->name . ':', 'Turning this player off' ] } );
                $otherclient->execute( [ 'power', 0 ] );
            }
            $conn->{poweredoff} = !$client->power;
            $conn->{player}->execute( [ 'playlist', 'play', $url ] );

            last;
        };

        /^RECORD$/ && do {

            Slim::Control::Request::notifyFromArray( $conn->{player}, ['newmetadata'] );
            $conn->{player}->execute( ['play'] );

            last;
        };
        /^FLUSH$/ && do {

            # this is pause at airplay - but only stop also flushed the buffer at the player
            # so if you press skip you won't hear the old song
            # also double FLUSH won't result in play again (like on skip)
            # 
            my $dfh = $conn->{decoder_fh};
            print $dfh "flush\n";

            $conn->{player}->execute( ['stop'] );
            $conn->{player}->execute( ['play'] );

            last;
        };
        /^TEARDOWN$/ && do {
            $resp->header( 'Connection', 'close' );
            close $conn->{decoder_fh};
            $conn->{player}->execute( ['stop'] );

            # read all left errors
            my $derr = $conn->{decoder_fherr};
            while ( <$derr> ) { $log->error( "Decoder error: " . $_ ); }

            close $conn->{decoder_fherr};

            if ( $conn->{poweredoff} ) {
                $conn->{player}->execute( [ 'power', 0 ] );
            }
            last;
        };
        /^SET_PARAMETER$/ && do {
            if ( $req->header( 'Content-Type' ) eq "text/parameters" ) {
                my @lines = split( /[\r\n]+/, $req->content );
                $log->debug( "SET_PARAMETER req: " . $req->content );
                my %content = map { /^(\S+): (.+)/; ( lc $1, $2 ) } @lines;
                my $cfh = $conn->{decoder_fh};
                if ( exists $content{volume} ) {
                    my $volume = $content{volume};
                    my $percent = 100 + ( $volume * 3.35 );

                    $conn->{player}->execute( [ 'mixer', 'volume', $percent ] );

                    $log->debug( "sending-> vol: " . $percent );
                }
                elsif ( exists $content{progress} ) {
                    my ( $start, $curr, $end ) = split( /\//, $content{progress} );

                    $positionRealTime = int ( ( $curr - $start ) / $samplingRate );
                    $durationRealTime = int ( ( $end - $start ) / $samplingRate );

                    $log->debug( "Duration: " . $durationRealTime . "; Position: " . $positionRealTime );

                    $airTunesMetaData{duration} = $durationRealTime;
                    $airTunesMetaData{position} = $positionRealTime;

                    my $client = $conn->{player};
                    Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );
                    $client->execute( ['play'] );
                }
                else {
                    $log->error( "unable to perform content for req SET_PARAMETER text/parameters: " . $req->content );
                }
            }
            elsif ( $req->header( 'Content-Type' ) eq "application/x-dmap-tagged" ) {

                my %dmapData = Plugins::ShairTunes2::Utils::getDmapData( $req->content );
                $airTunesMetaData{artist} = $dmapData{artist};
                $airTunesMetaData{album}  = $dmapData{album};
                $airTunesMetaData{title}  = $dmapData{title};

                $log->debug( "DMAP DATA found. Length: " . length( $req->content ) . " " . Dumper( \%dmapData ) );

                my $hashkey       = Plugins::ShairTunes2::Utils::imagekeyfrommeta( \%airTunesMetaData );
                my $imagefilepath = File::Spec->catdir( $cachedir, 'shairtunes', $hashkey . "_cover.jpg" );
                my $imageurl      = "/imageproxy/shairtunes:image:" . $hashkey . "/cover.jpg";
                if ( length $cover_cache ) {
                    open( my $imgFH, '>' . $imagefilepath );
                    binmode( $imgFH );
                    print $imgFH $cover_cache;
                    close( $imgFH );

                    $log->debug( "IMAGE DATA COVER_CACHE found. " . $imagefilepath . " " . $imageurl );

                    $airTunesMetaData{cover}        = $imageurl;
                    $cover_cache                    = '';
                    $airTunesMetaData{waitforcover} = 0;
                }
                elsif ( -e $imagefilepath ) {
                    $airTunesMetaData{cover}        = $imageurl;
                    $airTunesMetaData{waitforcover} = 0;
                }
                else {
                    $airTunesMetaData{waitforcover} = 1;
                    $airTunesMetaData{cover}        = '';
                }

                my $client = $conn->{player};
                Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );
            }
            elsif ( $req->header( 'Content-Type' ) eq "image/jpeg" ) {

                if ( $airTunesMetaData{waitforcover} && length $airTunesMetaData{title} ) {
                    $cover_cache = '';
                    $airTunesMetaData{waitforcover} = 0;

                    my $hashkey       = Plugins::ShairTunes2::Utils::imagekeyfrommeta( \%airTunesMetaData );
                    my $imagefilepath = File::Spec->catdir( $cachedir, 'shairtunes', $hashkey . "_cover.jpg" );
                    my $imageurl      = "/imageproxy/shairtunes:image:" . $hashkey . "/cover.jpg";

                    open( my $imgFH, '>' . $imagefilepath );
                    binmode( $imgFH );
                    print $imgFH $req->content;
                    close( $imgFH );

                    $log->debug( "IMAGE DATA found. " . $imagefilepath . " " . $imageurl );

                    $airTunesMetaData{cover} = $imageurl;

                    my $client = $conn->{player};
                    Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );
                }
                else {
                    $log->debug( "IMAGE DATA CACHED" );
                    $cover_cache = $req->content;
                }
            }
            else {
                $log->error( "Unknown content-type: \"" . $req->header( 'Content-Type' ) . "\"" );
            }
            last;
        };
        /^GET_PARAMETER$/ && do {
            my @lines = split /[\r\n]+/, $req->content;
            $log->debug( "GET_PARAMETER req: " . $req->content );

            my %content = map { /^(\S+): (.+)/; ( lc $1, $2 ) } @lines;

            last;

        };
        /^DENIED$/ && last;
        $log->error( "Got unknown method: $_" );
    }

    #$log->debug("\n\nPLAYER_MESSAGE_START: \n" .$resp->as_string("\r\n"). "\nPLAYER_MESSAGE_END\n\n");

    print $socket $resp->as_string( "\r\n" );
    $socket->flush;

}

sub _airport_pem {
    return q|-----BEGIN RSA PRIVATE KEY-----
MIIEpQIBAAKCAQEA59dE8qLieItsH1WgjrcFRKj6eUWqi+bGLOX1HL3U3GhC/j0Qg90u3sG/1CUt
wC5vOYvfDmFI6oSFXi5ELabWJmT2dKHzBJKa3k9ok+8t9ucRqMd6DZHJ2YCCLlDRKSKv6kDqnw4U
wPdpOMXziC/AMj3Z/lUVX1G7WSHCAWKf1zNS1eLvqr+boEjXuBOitnZ/bDzPHrTOZz0Dew0uowxf
/+sG+NCK3eQJVxqcaJ/vEHKIVd2M+5qL71yJQ+87X6oV3eaYvt3zWZYD6z5vYTcrtij2VZ9Zmni/
UAaHqn9JdsBWLUEpVviYnhimNVvYFZeCXg/IdTQ+x4IRdiXNv5hEewIDAQABAoIBAQDl8Axy9XfW
BLmkzkEiqoSwF0PsmVrPzH9KsnwLGH+QZlvjWd8SWYGN7u1507HvhF5N3drJoVU3O14nDY4TFQAa
LlJ9VM35AApXaLyY1ERrN7u9ALKd2LUwYhM7Km539O4yUFYikE2nIPscEsA5ltpxOgUGCY7b7ez5
NtD6nL1ZKauw7aNXmVAvmJTcuPxWmoktF3gDJKK2wxZuNGcJE0uFQEG4Z3BrWP7yoNuSK3dii2jm
lpPHr0O/KnPQtzI3eguhe0TwUem/eYSdyzMyVx/YpwkzwtYL3sR5k0o9rKQLtvLzfAqdBxBurciz
aaA/L0HIgAmOit1GJA2saMxTVPNhAoGBAPfgv1oeZxgxmotiCcMXFEQEWflzhWYTsXrhUIuz5jFu
a39GLS99ZEErhLdrwj8rDDViRVJ5skOp9zFvlYAHs0xh92ji1E7V/ysnKBfsMrPkk5KSKPrnjndM
oPdevWnVkgJ5jxFuNgxkOLMuG9i53B4yMvDTCRiIPMQ++N2iLDaRAoGBAO9v//mU8eVkQaoANf0Z
oMjW8CN4xwWA2cSEIHkd9AfFkftuv8oyLDCG3ZAf0vrhrrtkrfa7ef+AUb69DNggq4mHQAYBp7L+
k5DKzJrKuO0r+R0YbY9pZD1+/g9dVt91d6LQNepUE/yY2PP5CNoFmjedpLHMOPFdVgqDzDFxU8hL
AoGBANDrr7xAJbqBjHVwIzQ4To9pb4BNeqDndk5Qe7fT3+/H1njGaC0/rXE0Qb7q5ySgnsCb3DvA
cJyRM9SJ7OKlGt0FMSdJD5KG0XPIpAVNwgpXXH5MDJg09KHeh0kXo+QA6viFBi21y340NonnEfdf
54PX4ZGS/Xac1UK+pLkBB+zRAoGAf0AY3H3qKS2lMEI4bzEFoHeK3G895pDaK3TFBVmD7fV0Zhov
17fegFPMwOII8MisYm9ZfT2Z0s5Ro3s5rkt+nvLAdfC/PYPKzTLalpGSwomSNYJcB9HNMlmhkGzc
1JnLYT4iyUyx6pcZBmCd8bD0iwY/FzcgNDaUmbX9+XDvRA0CgYEAkE7pIPlE71qvfJQgoA9em0gI
LAuE4Pu13aKiJnfft7hIjbK+5kyb3TysZvoyDnb3HOKvInK7vXbKuU4ISgxB2bB3HcYzQMGsz1qJ
2gG0N5hvJpzwwhbhXqFKA4zaaSrw622wDniAK5MlIE0tIAKKP4yxNGjoD2QYjhBGuhvkWKY=
-----END RSA PRIVATE KEY-----|;
}

1;

package Tie::Restore;

our $VERSION = 0.11;

sub TIESCALAR { $_[1] }
sub TIEARRAY  { $_[1] }
sub TIEHASH   { $_[1] }
sub TIEHANDLE { $_[1] }

1;
