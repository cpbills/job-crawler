#!/usr/bin/perl
# job-crawler.pl - searches craig's list job postings and emails a summary
# Copyright (C) 2008 Christopher P. Bills (cpbills@fauxtographer.net)
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

use warnings;
use strict;

use LWP::UserAgent;
use Getopt::Std;

# get today's date in YYYY-MM-DD format (default) can be configured how you like
# `man strftime` for formatting help...
my $DATE = `/bin/date +%F`; chomp $DATE;

# configure the subject for sent emails.
# note: this is currently the only use of $DATE
my $SUBJECT = "Job Crawler $DATE";

# location of the configuration file... update as needed.
my $CONFIG = "$ENV{HOME}/.jc.conf";

################################################################################
####################### END USER CONFIGURABLE SETTINGS #########################
################################################################################

my $DEBUG = 0;

my %opts = ();
Getopt::Std::getopts('hdc:D:e:',\%opts);

if ($opts{h}) {
    usage();
    exit 0;
}

$CONFIG = $opts{c} if (defined $opts{c});

my $options = read_config();
my $terms   = $$options{terms};
my $locales = $$options{locales};

$DEBUG = 1 if ($$options{debug} or $opts{d});
$$options{email} = $opts{e} if ($opts{e});
$$options{depth} = $opts{D} if (defined $opts{D});

main();

exit 0;

sub usage {
    print qq{usage: $0 [option]...
searches craig's list postings for potential matches and can email
a summary to the user to ease job hunting process.

    -h              display this help message
    -d              enable debugging
    -c <file>       specify a configuration file
    -D [0-5]        specify the depth to search
    -e <email>      specify an email address to send a summary to

};
}

sub main {
    # scalar to hold any error messages we come across while scanning ads.
    # will be included as a footer of the email summary...
    my $errors = '';

    # array to hold summaries of potential job matches...
    my @potential = ();

    # read in previously searched job listing data...
    my $history = read_history($$options{history}) if (-e $$options{history});

    # this array will allow you to step through older job postings.
    # set to something like '@depth = qw( / );' to just do the first 100
    # postings; otherwise this will analyze 600 postings (index100.html is
    # job101-job200 and so on...)
    my @depths = qw( / /index100.html /index200.html
                       /index300.html /index400.html /index500.html );

    foreach my $locale (@$locales) {
        my $base = "http://$locale.craigslist.org/$$options{section}";
        for my $depth ( 0 .. $$options{depth} ) {
            my $url = "$base" . "$depths[$depth]";
            my $listing = get_page("$url");
            if (!defined $listing) {
                my $error = "failed to get listings: $! ($url)\n";
                print STDERR $error if ($DEBUG);
                $errors .= $error;
            } else {
                # skim the HTML listings for post URLs and descriptions
                my @posts = $listing =~ /^<p>.*(http.*font\ size.*)<\/p>$/gim;
                foreach my $post (@posts) {
                    my ($url,$title,$area) =
                                $post =~ /(.*.html).*>(.*?)<\/a>.*\(([^)]*)/i;
                    my $result = examine_post($url,$title,$area,$history);
                    if ($result) {
                        push @potential, $result;
                    }
                    # (re)set 'seen' count to 1; a low value means it is still
                    # being listed on craig's list, and we still have to keep
                    # track of it, to avoid double-analyzing a job listing.
                    $$history{$url} = 1;
                }
                # write the history file
                save_history($$options{history},$history,$$options{freshness});
            }
        }
    }
    present_results($errors, @potential);
}

sub read_config {
    # Attempts to open and read a configuration file.
    # Returns a hash-reference containing configuration details
    my $conf_file   = shift;

    my %options = ();

    if (open CONFIG,'<',$conf_file) {
        my @locales = ();
        my %terms   = ();
        while (<CONFIG>) {
            my $line = $_;
            next if ($line =~ /^#/);
            next if ($line =~ /^$/);

            $line =~ s/\s+/\ /g;

            my ($option,@settings) = split(/\ /,$line);
            if ($option eq 'locale') {
                push @locales, @settings;
            } elsif ($option eq 'term') {
                my $score = $settings[$#settings];
                my $term  = join(' ',@settings[0 .. $#settings-1]);
                $terms{"$term"} = $score;
            } else {
                $options{$option} = join(' ',@settings);
            }
        }

        if (scalar(keys %terms) == 0) {
            print STDERR "No Terms: Please define search terms to use\n";
            usage();
            exit 1;
        }
        if (scalar(@locales) == 0) {
            print STDERR "No Locales: Please select a locale to search\n";
            usage();
            exit 1;
        }

        $options{terms}     = \%terms;
        $options{locales}   = \@locales;
        close CONFIG;
    } else {
        print STDERR "Unable to open $conf_file: $!\n";
        usage();
        exit 1;
    }

    unless ($options{section}) {
        print STDERR "you need to define a section of craig's list to search\n";
        usage();
        exit 1;
    }

    unless ($options{email} and $options{sendmail}) {
        if ($options{send_email}) {
            print STDERR "no email address to send to or no sendmail defined\n";
            print STDERR "disabling sending of mail. please fix to correct\n";
            $options{send_email} = 0;
        }
    }
    unless (defined $options{history}) {
        print STDERR "no history file defined, using /dev/null\n";
        $options{history} = '/dev/null';
    }

    $options{depth} = 0 unless (defined $options{depth});
    $options{delay} = 5 unless (defined $options{delay});
    $options{threshold} = 5 unless (defined $options{threshold});

    return \%options;
}

sub read_history {
    my $hist_file = shift;

    my %history = ();
    if (open HISTORY,'<',$hist_file) {
        while (<HISTORY>) {
            my $line = $_;
            chomp $line;
            my ($url,$age) = split(/::/,$line);
            # Increase the posting age to track which postings are gone
            $history{$url} = ++$age;
        }
        close HISTORY;
    } else {
        print STDERR "Failed to open $hist_file; $!\n";
    }

    # return a hash reference (for easier passing between functions...)
    return \%history;
}

sub send_email {
    my $email_addr  = shift;
    my $subject     = shift;
    my $results     = shift;
    my $sendmail    = shift;

    $results =~ s/\n/<br\/>\n/g;

    print "sending an email to $$options{email}\n" if ($VERBOSE);

    my $email_content = qq{Subject: $subject
X-Oddity: The ducks in the bathroom are not mine
Content-Type: multipart/alternative; boundary="_424242_"
To: $email_addr
From: $email_addr

--_424242_
Content-Type: text/plain; charset="iso-8859-1"
$results
--_424242_
Content-Type: text/html; charset="iso-8859-1"
<html>
    <body style="font-family:'Courier New',monospace;">
    <p style="font-family:'Courier New',Courier,monospace;">
$results
    </p>
    </body>
</html>

--_424242_--
};

    print $email if ($DEBUG);

    if (open EMAIL,"|$$options{sendmail}") {
        print EMAIL $email;
        close EMAIL;
    } else {
        print STDERR "cannot open $$options{sendmail}: $!";
    }
}

sub present_results {
    my $errors      = shift;
    my @potential   = @_;

    return unless (scalar(@potential) > 0);

    my @sorted = sort {
        # originally set to sort by date, then score, that ended up
        # more frustrating than not.
        my ($da,$sa) = $a =~ /([0-9-]*):.*\[\s+([0-9]+)/;
        my ($db,$sb) = $b =~ /([0-9-]*):.*\[\s+([0-9]+)/;
        #return -1 if ($da gt $db);
        #return  1 if ($db gt $da);
        #if ($da eq $db) {
            return -1 if ($sa > $sb);
            return  1 if ($sb > $sa);
        #}
        return 0;
    } @potential;

    my $jobs = '';
    foreach my $joblisting (@sorted) {
        $jobs .= $joblisting;
    }

    print "$jobs\n$errors\n" if ($DEBUG);

    send_email(@sorted) if ($$options{send_email});
}

sub get_page {
    my $url = shift;

    my $browser = LWP::UserAgent->new;
    $browser->agent('Mozilla/5.0 (X11; U; Linux i686)');

    my $req = HTTP::Request->new(GET => $url);
    my $res = $browser->request($req);
    if ($res->is_success) {
        sleep $$options{delay};
        return $res->content;
    }
    print STDERR "problem fetching $url ($!)\n" if ($DEBUG);
    return undef;
}

sub examine_post {
    my $url     = shift;
    my $title   = shift;
    my $area    = shift;
    my $history = shift;

    return undef if ($$history{$url});

    my $score   = 0;

    # initialize array to hold terms found in job posting...
    my @found = ();

    my $body = get_page($url);
    return undef unless (defined $body);

    foreach my $term (keys %$terms) {
        my @count = $body =~ /\b$term\b/igs;
        if (scalar(@count) > 0) {
            my $find = $term . '[' . scalar(@count) . ']';
            push @found, $find;
            $score += scalar(@count)*$$terms{$term};
        }
        # additionally increase score if the term is found in the job title
        $score += $$terms{$term} if ($title =~ /$term/i);
    }

    print "examined: $url score: $score\n" if ($DEBUG);

    my $date  = '';
      ($date) = $body =~ /Date:\s+([0-9]{4}-[0-9]{2}-[0-9]{2})/is;
    my $fscore = sprintf("% 3i",$score);
    # create a summary of the job posting;
    my $summary  = "$date: [$fscore] ($area) <a href='$url'>$title</a>\n";
       $summary .= join(', ',@found) . "\n\n";

    if ($score >= $$options{threshold}) {
        return $summary;
    } else {
        return undef;
    }
}

sub save_history {
    # Keep track of 'fresh' jobs that have been scanned already.
    # If a posting hasn't been seen in a set number of program runs,
    # it is no longer tracked. This keeps the history file from growing
    # too large and tracking irellevant data.
    my $hist_file   = shift;
    my $postings    = shift;
    my $freshness   = shift;

    if (open HISTORY,'>',"$hist_file") {
        foreach my $url (keys %$postings) {
            if ($freshness > $$postings{$url}) {
                print HISTORY join('::',$url,$$postings{$url}),"\n";
            }
        }
        close HISTORY;
    } else {
        # Be noisy about our inability to track things.
        print STDERR "unable to open $hist_file for writing; $!\n";
    }
}
