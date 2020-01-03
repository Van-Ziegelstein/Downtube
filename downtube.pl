#!/bin/perl

use strict;
use warnings;
use JSON::PP;
use File::Temp qw/ tempfile /;


sub find_prog {

    my $prog_name = shift;
    my $exe;

    foreach my $dir (split(":", $ENV{PATH})) {

        if (-e "$dir/$prog_name" && -x _) {
           
            $exe = "$dir/$prog_name";
            last;

        }
    }

    die "Couldn't locate $prog_name in your path.\n" unless $exe;
    return $exe;

}


sub url_decode {
    
    my $url = shift;

    $url =~ s/%([[:xdigit:]]{2})/chr(hex($1))/ieg;
    $url =~ s/\\u0026/&/g;

    return $url
}


sub pick_stream {

    my ($stream_list, $debug) = @_;
    my $count = 0;
    my $selection = 0;


    foreach my $stream (@{ $stream_list }) {

        $count++;
        print "\nStream $count:\n";

        foreach my $key (keys %{ $stream }) {
            
            if (!$debug && $key !~ /(itag|bitrate|qualityLabel|quality|averageBitrate|height|width|fps)/) {
                next;
            }

            print "$key: $stream->{$key}\n";
        }

        print "\n\n";
    }


    do {
        
        print "Your pick (1 - $count): ";
        chomp($selection = <STDIN>);

    } while ($selection < 1 || $selection > @{ $stream_list }); 


    return $stream_list->[$selection - 1];
}


sub get_mp4streams {

    my ($format_list) = shift =~ /adaptiveFormats\\":(\[.*?\])/;
    my ($debug, $audio_only) = @_;
    my %mp4_streams = (video => [], audio => []);
    my @target_streams;
    
    die "Couldn't locate the adaptive streams.\n" unless $format_list;

    # need to reduce the nesting of the backslash escapes
    $format_list =~ s/\\([^\\]{1})/$1/g;
    $format_list =~ s/\Q\\\E/\\/g;

    print "\nDEBUG ---> Parsed stream map:\n$format_list\n\n" if $debug;

    my $all_streams = decode_json($format_list);

    foreach my $stream (@{ $all_streams }) {
        
        if ($stream->{mimeType} =~ /(video|audio)\/mp4/) {
            push(@{ $mp4_streams{$1} }, $stream);
        }

    }
    

    print "\nChoose one of the available mp4 audio streams:\n\n";
    push(@target_streams, pick_stream($mp4_streams{audio}, $debug));

    unless ($audio_only) {

        print "\nChoose one of the available mp4 video streams:\n\n";
        push(@target_streams, pick_stream($mp4_streams{video}, $debug));
    }

    return @target_streams;
}


sub signature_scramble {

    my $script;
    my @helper_objects;
    my $op_data = shift;
    my %player_resources = (crypt_signature => shift);
    my $nodejs = find_prog("node");


    $player_resources{player_url} = $op_data->{url_root} . $1 if $op_data->{page_src} =~ /src="\/(.+\/jsbin[^"]*\/base\.js)/;
    die "Couldn't extract the player url!\n" unless $player_resources{player_url};

    $player_resources{player_js} = qx($op_data->{curl} -sSL --compressed -A \Q$op_data->{agent}\E $player_resources{player_url}) 
    or die "Couldn't download the player script!\n";


    #Locate the scrambling routine.
    ($player_resources{crypt_func}) = $player_resources{player_js} =~ /((\w+?)\s*=\s*function\((.*?)\)\s*\{\s*\g3\s*=\s*\g3\.split\(\"\"\).*?\};)/;  
    $player_resources{crypt_func_call} = $2 . "(\"" . "$player_resources{crypt_signature}" . "\");"; 


    #Locate auxilary variables and functions used by the scrambling routine.
    OBJ_CHECK: while ($player_resources{crypt_func} =~ /;([^\s]+?)\./g) {

        foreach my $entry (@helper_objects) { next OBJ_CHECK if $entry =~ /^var\s\Q$1\E/; }

        ($helper_objects[++$#helper_objects]) = $player_resources{player_js} =~ /(var\s\Q$1\E=.+?\};)/s;

    }
   
   
    #Piece everything together.
    foreach my $entry (@helper_objects) { $script .= "$entry\n"; }     
    $script .= "$player_resources{crypt_func}\n" . "$player_resources{crypt_func_call}\n";  

    die "Couldn't parse player code\n" unless $script;

    print "\nDEBUG ---> Reconstructed javascript code:\n$script\n" 
    if $op_data->{debug};      

    return qx($nodejs -p \Q$script\E);

}


sub video_metadigger {

    my $op_data = shift;

    die "Not a Youtube url!\n" 
    unless $op_data->{url} =~ /^(http.?\:\/\/www\.youtube\.\w{2,3}\/)watch\?\w*v=\w*/;

    $op_data->{url_root} = $1;

    $op_data->{page_src} = qx($op_data->{curl} -sSL --compressed -A \Q$op_data->{agent}\E \Q$op_data->{url}\E)
    or die "Couldn't download the page source!\n";

    ($op_data->{vid_title}) = $op_data->{page_src} =~ /"title":"(.+?)",/si 
    or die "Couldn't locate the title JSON object\n";

    $op_data->{vid_title} =~ s/\\u0026/&/g;
    $op_data->{vid_title} =~ s/[\\\$\/{}:]//g;

    my @target_streams = get_mp4streams($op_data->{page_src}, $op_data->{debug}, $op_data->{audio_only});


    foreach my $stream (@target_streams) {


        my $true_url;
        my ($type) = $stream->{mimeType} =~ /(audio|video)/;
        print "\nChecking source url of $type stream...\n";

        if ($stream->{cipher}) {

            print "\nStream uses signature scrambling for copyright protection.\n", 
            "Forging token...\n";

            my $url_soup = url_decode($stream->{cipher});
            ($true_url) = $url_soup =~ /url=(.*)/;
            print "\nDEBUG ---> Decoded target url string:\n$url_soup\n\n" 
            if $op_data->{debug};

            $url_soup =~ /^(.+&|)s=([^&]+)/i
            or die "Couldn't extract the signature challenge from the url.";

            my $challenge = $2;

            $url_soup =~ /^(.+&|)sp=([^&]+)/i
            or die "Couldn't extract the signature parameter name from the url.";

            my $sig_param = $2;

            print "\nDEBUG ---> Signature match:\n$challenge\n", 
            "\nDEBUG ---> Signature url parameter: $sig_param\n" 
            if $op_data->{debug}; 

            chomp (my $scrambled_signature = signature_scramble($op_data, $challenge));
            $true_url .= "\&$sig_param=" . "$scrambled_signature";

        }
        else { $true_url = url_decode($stream->{url}); }

        print "\nDEBUG ---> Final target url:\n$true_url\n" 
        if $op_data->{debug}; 

        $op_data->{$type . "_target"} = { src => $true_url }; 

    }

}


sub download {

    my ($file_name, $curl, $src_url, $agent_cloak) = @_;

    system("$curl", "-L", "-C", "-", "-S", "--retry", "4", "-A", "$agent_cloak", "-o", "$file_name", "$src_url"); 

    if ($? != 0) {
      
        warn "\nWarning: Download attempt completed with errors!\n";
        return -1;

    }

    return 0;

}


sub assemble {

    my $op_data = shift;
    my $ffmpeg = find_prog("ffmpeg");

    print "\nDownloading all streams...\n\n";

    foreach my $target ($op_data->{audio_target}, $op_data->{video_target}) {

        next unless $target;

        ($target->{fhandle}, $target->{fname}) = tempfile("clipXXXXX", UNLINK => 1);

        my $status = download($target->{fname}, $op_data->{curl}, $target->{src}, $op_data->{agent});
        die "Aborting download...\n" if $status == -1; 

    }

    
    if ($op_data->{audio_only}) {

        print "\nConverting audio data to mp3 file...\n";

        system($ffmpeg, "-loglevel", "quiet", "-i", 
        $op_data->{audio_target}->{fname}, "-qscale:a", "0", $op_data->{vid_title} . ".mp3");

        warn "Error: something went wrong during mp3 conversion.\n" if $? != 0;
        
    }
    else {
        
        print "Combining audio and video streams...\n";

        system($ffmpeg, "-loglevel", "quiet", "-i", $op_data->{video_target}->{fname}, 
        "-i", $op_data->{audio_target}->{fname}, "-c", "copy", $op_data->{vid_title} . ".mp4");

        warn "Error: something went wrong during the final assembly.\n" if $? != 0;
    }

    foreach my $target ($op_data->{audio_target}, $op_data->{video_target}) {
        close($target->{fhandle}) if $target;
    }

}


sub help_dialogue {

    print "\nRudimentary Perl script to download Youtube videos from the commandline.\n",
    "Can automatically convert them to mp3 files with ffmpeg.\n",
    "Videos with scrambled signatures can also be downloaded, provided nodejs is installed.\n\n",
    "Usage: $0 -help | -u <video_url> [-mp3] [-debug]\n\n";

}


if ( @ARGV != 0) {

    my %op_data = (

            url => undef,
            curl => find_prog("curl"),
            agent => "Mozilla/5.0 (Windows NT 6.1; rv:60.0) Gecko/20100101 Firefox/60.0",
            audio_only => 0,
            audio_target => undef,
            video_target => undef,
            debug => 0

    );

    until (@ARGV == 0) {

        if ($ARGV[0] =~ /-*help/i) { help_dialogue; exit 0; }

        elsif ($ARGV[0] =~ /-u/) { shift; chomp($op_data{url} = $ARGV[0]); }

        elsif ($ARGV[0] =~ /-mp3/i) { $op_data{audio_only} = 1; }

        elsif ($ARGV[0] =~ /-debug/i) { $op_data{debug} = 1; }

        else { die "Unsupported option. Type -help for more info...\n";}

        shift;

    }        

    die "You must provide a Youtube url!\n" unless defined $op_data{url};     

    video_metadigger(\%op_data);  
    assemble(\%op_data);
 
}
else { help_dialogue; }
