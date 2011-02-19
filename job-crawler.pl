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

# this hash holds the words we want to find in a job posting, and what we
# value them at. could be read in from a configuration file down the road...
# spaces should be escaped (put a '\' in front of any characters you think
# may cause problems. the search mechanism is pretty rudimentary, and searches
# for (word-boundary)exactmatch(word-boundary)... room for improvement...
my %TERMS = (
    'linux'                     =>  5,
    'windows'                   =>  -1,
    'mysql'                     =>  2,
    'perl'                      =>  6,
    'active\ directory'         =>  -2
);

# this array will allow you to step through older job postings.
# set to something like '@depth = qw( / );' to just do the first 100
# postings; otherwise this will analyze 600 postings (index100.html is
# job101-job200 and so on...)
my @DEEP = qw( / /index100.html /index200.html
                 /index300.html /index400.html /index500.html );

# get today's date in YYYY-MM-DD format (default) can be configured how you like
# `man strftime` for formatting help...
my $DATE = `/bin/date +%F`; chomp $DATE;

# configure the subject for sent emails.
# note: this is currently the only use of $DATE
my $SUBJECT = "Job Crawler $DATE";

# time in seconds to sleep between www queries
my $DELAY       = 2;

# should we send an email summary when done?
my $DO_EMAIL    = 0;

# a file to hold the jobs the script has scanned already, as well as a counter
# the counter is zero'd out each time the job is found. when a job reaches a
# count defined below, the job will be removed from the history file (so you
# don't end up with a huge file of stale job postings.
my $HISTORY     = "/tmp/job-crawler.history";

# list of all US locations available at: http://geo.craigslist.org/iso/us
# to add more locations add the prefix to the list below, 'BLAH.craigslist.org'
my @LOCALES     = qw( sfbay memphis );

# jobs are listed under a section, for example:
# http://sfbay.craigslist.org/sad/ for systems/networking jobs in sfbay...
# find the section in craig's list that posts jobs you want to search...
my $CL_SECTION  = 'sad';

# the email address you want to send your job summary to
my $EMAIL       = 'someemail@add.ress';

# freshness is how many days we want to save jobs that haven't been seen in our
# searching of craig's list. happens a lot in midwest areas with few postings...
# turn-over is fairly quick in the bay area...
my $FRESHNESS   = 4;

# sendmail command to use to send the mail
my $SENDMAIL    = '/usr/sbin/sendmail -t';

# global variable to hold potential job URLs
my @MATCHES     = ();  # array for desireable jobs

# threshold; if a job scores higher than this value, it will be included in the
# summary. you can set this higher or lower, depending on your level of success
# with the keywords and values you use and assign to them.
my $THRESHOLD   = 0;

# set to 1 to see more verbose, debugging output...
my $DEBUG       = 1;

################################################################################
####################### END USER CONFIGURABLE SETTINGS #########################
################################################################################

&main();

exit 0;

sub main {
    # scalar to hold any error messages we come across while scanning ads.
    # will be included as a footer of the email summary...
    my $errors = '';

    # array to hold summaries of potential job matches...
    my @potential = ();

    # read in previously searched job listing data...
    my $history = &read_history($HISTORY) if (-e $HISTORY);

    foreach my $locale (@LOCALES) {
        my $base = "http://$locale.craigslist.org/$CL_SECTION";
        foreach my $depth (@DEEP) {
            my $listing = get_page("$base$depth");
            if (!defined $listing) {
                my $error = "failed to get listings: $! ($base$depth)\n";
                print STDERR $error if ($DEBUG);
                $errors .= $error;
            } else {
                # skim the HTML listings for post URLs and descriptions
                my @posts = $listing =~ /^<p>.*(http.*font\ size.*)<\/p>$/gim;
                foreach my $post (@posts) {
                    my ($url,$title,$area) =
                                $post =~ /(.*.html).*>(.*?)<\/a>.*\(([^)]*)/i;
                    my $result = &examine_post($url,$title,$area,$history);
                    if ($result) {
                        push @potential, $result;
                    }
                    # (re)set 'seen' count to 1; a low value means it is still
                    # being listed on craig's list, and we still have to keep
                    # track of it, to avoid double-analyzing a job listing.
                    $$history{$url} = 1;
                }
                # write the history file
                &save_history($history);
            }
        }
    }
    &present_results($errors, @potential);
}

sub read_history {
    my $HISTORY = shift;
    
    my %history = ();
    if (open HISTORY,'<',$HISTORY ) {
        while (<HISTORY>) {
            my $line = $_;
            chomp $line;
            my ($url,$stale) = split(/::/,$line); 
            # increase the staleness; this allows us to keep job posting history
            # fresh and not retain job postings that are no longer around but at
            # the same time allows us to keep from searching the same postings
            $history{$url} = ++$stale;
        }
        close HISTORY;
    } else {
        print STDERR "failed to open $HISTORY; $!\n" if ($DEBUG);
    }

    # return a hash reference (for easier passing between functions...)
    return \%history;
}

sub send_email {
    my $errors      = shift;
    my $job_summary = shift;

    $job_summary =~ s/\n/<br\/>\n/g;

    print "sending an email to $EMAIL\n" if ($DEBUG);

    my $email = qq{Subject: $SUBJECT
X-Oddity: The ducks in the bathroom are not mine
Content-Type: multipart/alternative; boundary="_424242_"
To: $EMAIL
From: $EMAIL

--_424242_
Content-Type: text/plain; charset="iso-8859-1"
$job_summary
$errors
--_424242_
Content-Type: text/html; charset="iso-8859-1"
<html>
    <body style="font-family:'Courier New',monospace;">
    <p style="font-family:'Courier New',Courier,monospace;">
$job_summary
$errors
    </p>
    </body>
</html>

--_424242_--
};

    print $email if ($DEBUG);

    if (open EMAIL,"|$SENDMAIL") {
        print EMAIL $email;
        close EMAIL;
    } else {
        print STDERR "cannot open $SENDMAIL: $!";
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

    &send_email(@sorted) if ($DO_EMAIL);
}

sub get_page {
    my $url = shift;

    sleep $DELAY;
    my $browser = LWP::UserAgent->new;
    $browser->agent('Mozilla/5.0 (X11; U; Linux i686)');
    
    my $req = HTTP::Request->new(GET => $url);
    my $res = $browser->request($req);
    if ($res->is_success) {
        sleep $DELAY;
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

    foreach my $term (keys %TERMS) {
        my @count = $body =~ /\b$term\b/igs;
        if (scalar(@count) > 0) {
            my $find = $term . '[' . scalar(@count) . ']';
            push @found, $find;
            $score += scalar(@count)*$TERMS{$term};
        }
        # additionally increase score if the term is found in the job title
        $score += $TERMS{$term} if ($title =~ /$term/i);
    }

    print "examined: $url score: $score\n" if ($DEBUG);

    my $date  = '';
      ($date) = $body =~ /Date:\s+([0-9]{4}-[0-9]{2}-[0-9]{2})/is;
    my $fscore = sprintf("% 3i",$score);
    # create a summary of the job posting;
    my $summary  = "$date: [$fscore] ($area) <a href='$url'>$title</a>\n";
       $summary .= join(', ',@found) . "\n\n";

    if ($score >= $THRESHOLD) {
        return $summary;
    } else {
        return undef;
    }
}

sub save_history {
    # write posting information we have already seen out to a file.
    # skip writing the post details if it isn't 'fresh'. by setting the check
    # for staleness a little higher than 1 or 2, we allow for a failure when
    # running the script, since the staleness is incremented each time the
    # script runs and the posting isn't seen.
    my $history = shift;    

    if (open HISTORY,'>',"$HISTORY") {
        foreach my $url (keys %$history) {
            print HISTORY join('::',$url,$$history{$url}),"\n"
                                    unless ($$history{$url} > $FRESHNESS);
        }
        close HISTORY;
    } else {
        print STDERR "unable to open $HISTORY for writing; $!\n" if ($DEBUG);
    }
}
