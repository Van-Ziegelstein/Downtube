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


sub get_streams {

    my ($format_list) = shift =~ /adaptiveFormats\\":(\[.*?\])/;
    my $debug = shift;
    
    die "Couldn't locate the adaptive streams.\n" unless $format_list;

    # need to reduce the nesting of the backslash escapes
    $format_list =~ s/\\([^\\]{1})/$1/g;
    $format_list =~ s/\Q\\\E/\\/g;

    print "\nDEBUG ---> Parsed stream map:\n$format_list\n\n" if $debug;
    
    return decode_json($format_list)
}


sub select_stream {
    
    my $streams = shift;
    my $count = 0;
    my $selection = -1;


    foreach my $stream (@{$streams}) {

        $count++;
        print "\nStream $count:\n";

        foreach my $key (keys %{ $stream }) {
            print "$key: $stream->{$key}\n";
        }

        print "\n\n";
    }


    do {
        
        print "Select one of the available streams (1 - $count): ";
        chomp($selection = <STDIN>);

    } while ($selection < 1 || $selection > @{ $streams }); 


    return $streams->[$selection - 1];

}

sub html_parser {

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

    my $target_stream = select_stream(get_streams($op_data->{page_src}, $op_data->{debug}));


    if ($target_stream->{cipher} && $target_stream->{cipher} =~ /url=(.*)/) {

        print "\nVideo uses signature scrambling for copyright protection.\n", 
        "Attempting forged request...\n";

        $op_data->{target} = url_decode($1);
        print "\nDEBUG ---> Target entry:\n$op_data->{target}\n\n" 
        if $op_data->{debug};

        $op_data->{target} =~ /^(.+&|)s=([^&]+)/i
        or die "Couldn't extract the signature challenge from the url.";

        my $challenge = $2;

        $op_data->{target} =~ /^(.+&|)sp=([^&]+)/i
        or die "Couldn't extract the signature parameter name from the url.";

        my $sig_param = $2;

        print "\nDEBUG ---> Signature match:\n$challenge\n", 
        "\nDEBUG ---> Signature url parameter: $sig_param\n" 
        if $op_data->{debug}; 

        chomp (my $scrambled_signature = signature_scramble($op_data, $challenge));
        $op_data->{target} .= "\&$sig_param=" . "$scrambled_signature";

    }
    else { $op_data->{target} = url_decode($target_stream->{url}); }
  

    print "\nDEBUG ---> Final target url:\n$op_data->{target}\n" 
    if $op_data->{debug}; 

    print "\nDownloading: $op_data->{vid_title}\n\n";

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


sub download {

    my ($file_name, $curl, $src_url, $agent_cloak) = @_;

    system("$curl", "-L", "-C", "-", "-S", "--retry", "4", "-A", "$agent_cloak", "-o", "$file_name", "$src_url"); 

    if ($? != 0) {
      
        warn "\nWarning: Download attempt completed with errors!\n";
        return -1;

    }

    return 0;

}


sub mp3_conversion {

    my $op_data = shift;
    my $ffmpeg = find_prog("ffmpeg");

    (my $clip_fhandle, my $clip_fname) = tempfile("clipXXXXX", UNLINK => 1);

    my $status = download($clip_fname, $op_data->{curl}, $op_data->{target}, $op_data->{agent});
    die "Aborting mp3 conversion...\n" if $status == -1; 

    if (-s $clip_fhandle) { 

        print "\nConverting video to mp3 file...\n";

        system("$ffmpeg", "-loglevel", "quiet", "-i", "$clip_fname", "-qscale:a", "0", $op_data->{vid_title} . ".mp3");

        warn "Error: MP3 conversion attempt completed with errors!\n" if $? != 0;

    }

    close($clip_fhandle);
  
}


sub help_dialogue {

    print "\nRudimentary Perl script to download Youtube videos from the commandline.\n",
    "Can automatically convert them to mp3 files with ffmpeg.\n",
    "Videos with scrambled signatures can also be downloaded, provided nodejs is installed.\n\n",
    "Usage: $0 -help | -u <video_url> [-mp3] [-debug]\n\n";

}


if ( @ARGV != 0) {

    my $mp3_conv = 0;
    my %op_data = (

            url => undef,
            curl => find_prog("curl"),
            agent => "Mozilla/5.0 (Windows NT 6.1; rv:60.0) Gecko/20100101 Firefox/60.0",
            debug => 0,

    );

    until (@ARGV == 0) {

        if ($ARGV[0] =~ /-*help/i) { help_dialogue; exit 0; }

        elsif ($ARGV[0] =~ /-u/) { shift; chomp($op_data{url} = $ARGV[0]); }

        elsif ($ARGV[0] =~ /-mp3/i) { $mp3_conv = 1; }

        elsif ($ARGV[0] =~ /-debug/i) { $op_data{debug} = 1; }

        else { die "Unsupported option. Type -help for more info...\n";}

        shift;

    }        

    die "You must provide a Youtube url!\n" unless defined $op_data{url};     

    html_parser(\%op_data);  

    if ($mp3_conv) { mp3_conversion(\%op_data); }  

    else { download($op_data{vid_title} . ".mp4", $op_data{curl}, $op_data{target}, $op_data{agent}); }
 
}
else { help_dialogue; }
