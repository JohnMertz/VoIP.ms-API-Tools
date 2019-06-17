#!/usr/bin/perl
use warnings;
use strict;

use VoIPms;
use VoIPms::Errors;
use File::Which 'which';
use JSON::XS;
use Data::Dump;
use Email::Valid 'address';

my $settings;

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 
# Default settings, if not defined in config or cmdline
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 

our %defaults = (
    'config'    => "$ENV{HOME}/.config/VoIPms/VoIPms.json",
    'username'  => undef,
    'password'  => undef,
    'did'       => undef,
    'lockfile'  => "$ENV{HOME}/.config/VoIPms/latest",
    'inbound'   => 'echo',
    'outbound'  => 'echo',
    'new_only'  => 0,
    'print'     => 0,
    'latest'    => undef,
    'direction' => undef
);


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 
# Collect setting overrides from cmdline
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 

my %overrides = ();
foreach my $arg (@ARGV) {
    my $match = 0;
    if ($arg eq '--help') {
        help();
    }
    # Arguments with now associated value (ie. true/false)
    foreach my $attr ( qw | print new_only | ) {
        if ($arg =~ m/--$attr/) {
            $overrides{$attr} = 1;
            $match = 1;
            last;
        }
    }
    # Arguments with an associated value
    foreach my $attr ( qw| direction username password did config lockfile inbound outbound latest | ) {
        if ($arg =~ m/--$attr=.*/) {
            if (defined $overrides{$attr}) {
                die "Multiple \"$attr\" arguments were provided\n";
            } else {
                $overrides{$attr} = $arg;
                $overrides{$attr} =~ s/^--$attr=(.*)$/$1/;
            }
            $match = 1;
            last;
        }
    }
    if ($match) {
        next;
    } else {
        die "Invalid argument: \"$arg\"\n";
    }
}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 
# Organize highest priority settings
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 

# --print is incompatible with execution of external commands
if (defined $overrides{print} && (defined $overrides{inbound} || defined $overrides{outbound})) {
    die "\"--print\" conflicts with \"--outbound\" and \"--inbound\"\n";
}

# Perl isn't great about relative paths, so fix a manually defined config path
if (defined $overrides{config}) {
    if ($overrides{config} =~ m|^~/|) {
        $overrides{config} =~ s|^~([^~]*)$|$ENV{HOME}$1|;
    } 
    if ($overrides{config} =~ m|^\./|) {
        $overrides{config} =~ s|^\.(.*)$|$ENV{PWD}$1|;
    }
    if ($overrides{config} =~ m|^[^/]|) {
        $overrides{config} =~ s|^(.*)$|$ENV{PWD}/$1|;
    }
    $defaults{config} = $overrides{config};
}

# Initialize settings from config file
if (-r $defaults{config}) {
    my $json;
    open(my $fh, "<", $defaults{config}) or die "Could not open file \"$defaults{config}\"\n$!";
    while (<$fh>) {
        $json = $json . $_;
        chomp $json;
    }
    close $fh;
    $settings = decode_json($json);
} else {
    print "Cannot read config file \"$defaults{config}\". Attempting to complete with commandline arguments only.\n";
}

# Override config settings with @ARGV input
foreach my $key (keys %overrides) {
    $settings->{$key} = $overrides{$key};
}

# Fill in the blanks with %defaults
foreach my $key (keys %defaults) {
    if (!defined $settings->{$key}) {
        $settings->{$key} = $defaults{$key};
    }
}

# If any necessary setting is missing, bail
foreach my $key ( qw| did username password | ) {
    if (!defined $settings->{$key}) {
        die "Missing necessary setting: \"$key\"\n";
    }
}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 
# Validate settings
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 

# VoIP.ms usernames are valid email address, check that.
unless (Email::Valid->address($settings->{username})) {
    die "Invalid email address: \"$settings->{username}\"";
}

# TODO: Validate password according to VoIP.ms's acceptable characters

unless ($settings->{did} =~ m/^[0-9]{10}$/) {
    die "Invalid did: \"$settings->{did}\". Must be 10 numerals, no punctuation.\n";
}

# Fix relative path but not raw command
foreach my $key ( qw| lockfile inbound outbound | ) {
    if ($settings->{$key} =~ m|^~/|) {
        $settings->{$key} =~ s|^~([^~]*)$|$ENV{HOME}$1|;
    } 
    if ($settings->{$key} =~ m|^\./|) {
        $settings->{$key} =~ s|^\.(.*)$|$ENV{PWD}$1|;
    }
}

# Inbound and Outbound commands must be executable
unless ( -x $settings->{inbound} || which($settings->{inbound}) ) {
    die "Inbound command \"$settings->{inbound}\" either does not exist or is not executable.\n";
}
unless ( -x $settings->{outbound} || which($settings->{outbound}) ) {
    die "Outbound command \"$settings->{outbound}\" either does not exist or is not executable.\n";
}

# Lockfile DOES need to have full path added
if ($settings->{lockfile} =~ m|^[^/]|) {
    $settings->{lockfile} =~ s|^(.*)$|$ENV{PWD}/$1|;
}

# Check lockfile and get last message ID if not overriden
my $dir = $settings->{lockfile};
$dir =~ s|^(.*)/[^/]*$|$1|;
if ( -e $settings->{lockfile} ) {
    if ( -w $dir ) {
        if (!defined $settings->{latest}) {
            open(my $fh, '<', $settings->{lockfile});
            $settings->{latest} = <$fh>;
            chomp $settings->{latest}; 
        }
    } else {
        die "File \"$settings->{lockfile}\" cannot be written to in order to update latest fetched message.\n";
    }
# If the file doesn't exist, but we can write it, set latest to 0
} elsif ( -w $dir ) {
    $settings->{latest} = 0;
} else {
    die "\"$settings->{lockfile}\" is not in a writable directory. Must be able to store the most recent ID collected here.\n";
}

# Latest must be an int
if (!($settings->{latest} =~ m/^[0-9]*$/)) {
    die "Invalid value for latest: \"$settings->{latest}\". Must be a single interger.\nIf not defined as an argument, this value comes from \"$settings->{lockfile}\".\n";
}

# Only 2 valid options for direction are "in" and "out". Undefined is both.
if ( defined $settings->{direction} && !($settings->{direction} =~ m/(in|out)/) ) {
    die "Invalid direction setting: \"$settings->{direction}\". Must be \"in\" or \"out\". Leave undefined for both.\n";
}


# Fetch all messages and remove status
my $voipms = VoIPms->new('api_username' => $settings->{username}, 'api_password' => $settings->{password});
my $response = $voipms->response('method' => 'getSMS', 'did' => $settings->{did});
if ($response->{status} ne 'success') {
    print STDERR "Failed: " . decode_status($response->{status}) . "\n";
    exit;
}

my $hashref = @$response{sms};
my @messages = @$hashref;

my $print = "[";
my $new_latest = 0;
foreach (@messages) {
    my %message = %$_;
    if ($message{id} <= $settings->{latest} && $settings->{new_only}) {
        next;
    } elsif ($message{id} > $new_latest) {
        $new_latest = $message{id};
    }
    my $json = '{"id":"' . $message{id} . '",' .
            '"date":"' . $message{date} . '",' .
            '"message":"' . $message{message} . '",';
    if ( $message{type} eq '1' && (!defined $settings->{direction} || $settings->{direction} ne 'out') ) {
        $json = $json . '"type":"inbound",' .
                '"sender":"' . $message{contact} . '",' .
                '"recipient":"' . $message{did} . '"}';
        if ($settings->{print}) {
            $print = $print . $json . ',';
        } else {
            system $settings->{inbound}, $json;
        }
    } elsif ( $message{type} eq '0' && (!defined $settings->{direction} || $settings->{direction} ne 'in') ) {
        $json = $json . '"type":"outbound",' .
                '"sender":"' . $message{did} . '",' .
                '"recipient":"' . $message{contact} . '"}';
        if ($settings->{print}) {
            $print = $print . $json . ',';
        } else {
            system $settings->{outbound}, $json;
        }
    }
}
if ($settings->{print}) {
    $print =~ s/,$/]/;
    print $print . "\n";
}

# Store new value for latest
if ($new_latest) {
    open(my $fh, '>', $settings->{lockfile});
    print $fh $new_latest;
    close $fh;
}

sub help {
    print "\n";
    print "VoIP.ms SMS Fetch Script\n";
    print "\n";
    print "Unless overridden, settings are collected from $defaults{config}.\n";
    print "\n";
    print "Collected messages can be processed with a command or printed:\n";
    print "\n";
    print "--inbound=<command>   - Command to process each inbound messages.\n";
    print "             default: $defaults{inbound} \"<JSON string>\"\n";
    print "--outbound=<command>  - Command to process each outbound messages\n";
    print "             default: $defaults{outbound} \"<JSON string>\"\n";
    print "--print               - Print all messages to STDOUT as JSON array.\n";
    print "                        Makes intelligable by as single JSON string.\n";
    print "\n";
    print "The following settings can be defined in the JSON config file, or\n";
    print "overridden at the commandline as follows:\n";
    print "\n";
    print "--config=<path>       - Location of JSON config file. Settings\n";
    print "                        override those below, if present.\n";
    print "             default: $defaults{config}\n";
    print "--username=<username> - VoIP.ms API Username.\n";
    print "             default: None, program will fail unless defined.\n";
    print "--password=<password> - VoIP.ms API Password.\n";
    print "             default: None, program will fail unless defined.\n";
    print "--did=<did>           - DID number to fetch.\n";
    print "             default: None, program will fail unless defined.\n";
    print "--lockfile=<path>     - Tracks the most recent ID fetched.\n";
    print "                        Used by --new_only argument.\n";
    print "             default: $defaults{lockfile}\n";
    print "\n";
    print "The following additional options are available which are not\n";
    print "defined in the configuration file:\n";
    print "\n";
    print "--new_only            - Don't process old messages\n";
    print "--latest=<msg_id>     - Override the value currently in the lockfile\n";
    print "                        in order to define \"old messages\"\n";
    print "--direction={in|out}  - Restrict processing to only inbound or outbound.\n";
    print "\n";
    exit 1;
}
