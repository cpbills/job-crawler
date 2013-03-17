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
use POSIX qw(strftime);

my $VERBOSE = 0;

# Email subject; 'Job Crawler YYYY-MM-DD' by default.
my $subject = "Job Crawler " . strftime("%F",localtime);

# Default configuration locations; override with -c
my $config_name = 'job-crawler.conf';
my @config_path = ();
if ($^O =~ /mswin/i) {
    @config_path = ("./${config_name}");
} else {
    @config_path = ( "/etc/${config_name}",
                     "$ENV{HOME}/.${config_name}",
                     "$ENV{HOME}/.config/${config_name}",
                     "./${config_name}" );
}
my $config_file = '';
foreach my $config (@config_path) {
    $config_file = $config if (-e "$config" && -r "$config");
}

my %opts = ();
Getopt::Std::getopts('hvc:d:e:',\%opts);

if ($opts{h}) {
    usage();
    exit 0;
}

$config_file = $opts{c} if (defined $opts{c});

my $options = read_config($config_file);
$VERBOSE = 1 if ($$options{verbose} or $opts{v});
$$options{email} = $opts{e} if (defined $opts{e});
$$options{depth} = $opts{d} if (defined $opts{d});

if ($VERBOSE) {
    print "Using $config_file for configuration\n";
}

unless (verify_options($options)) {
    # exit if the options are broke
    err_msg('Required options not defined',1);
}


# Track errors encountered while processing job postings
my $errors = '';

my @matches = ();

# read in previously searched job listing data...
my $history = {};
if ($$options{history} && -e "$$options{history}") {
    $history = read_history($$options{history});
}

# Craig's List has 'static' URLs for 1-100 jobs, 101-200 and so on.
my @depths = qw( / /index100.html /index200.html
                   /index300.html /index400.html /index500.html );

foreach my $locale (split(/\s+/,$$options{locale})) {
    my $base = "http://$locale.craigslist.org/$$options{section}";
    for my $depth ( 0 .. $$options{depth} ) {
        my $url = "$base" . "$depths[$depth]";
        my $postings = get_page("$url");
        if ($postings) {
            # Scrape HTML for post URLs and descriptions
            my @posting_urls = ($postings =~ /(http.*[0-9]+\.html)"/gim);
            foreach my $url (@posting_urls) {
                unless ($$history{$url}) {
                    my $result = examine_posting($url,$$options{terms});
                    if ($result) {
                        push @matches, $result;
                    }
                }
                # Set the 'age' to 1
                $$history{$url} = 1;
            }
            if ($$options{history}) {
                # save URL history
                save_history($$options{history},$history,$$options{freshness});
            }
        } else {
            my $error = "failed to get listings: $! ($url)";
            if ($VERBOSE) {
                err_msg($error,0);
            }
            $errors .= "$error\n";
        }
    }
}
my $results = create_results($errors,@matches);

if ($$options{send_email}) {
    send_email($$options{email},$subject,$results,$$options{sendmail});
}

exit 0;

sub usage {
    print qq{usage: $0 [option]...
searches craig's list postings for potential matches and can email
a summary to the user to ease job hunting process.

    -h              display this help message
    -v              verbose output
    -c <file>       specify a configuration file
    -d [0-5]        specify the depth to search
    -e <email>      specify an email address to send a summary to

};
}

sub read_config {
    # Attempts to open and read a configuration file.
    # Returns a hash-reference containing configuration details
    my $conf_file   = shift;

    my %options = ();

    if (open CONFIG,'<',"$conf_file") {
        # hash for the score of each search term
        my %terms   = ();

        while (<CONFIG>) {
            my $line = $_;

            # remove pesking whitespace
            $line =~ s/^\s+//;
            $line =~ s/\s+$//;

            # skip comments and empty lines
            next if ($line =~ /^#/);
            next if ($line =~ /^$/);

            # squish whitespace
            $line =~ s/\s+/\ /g;

            my ($option,$value) = split(/\ /,$line,2);
            if ($options{$option}) {
                # check for 'overloadable' options
                if ($option eq 'locale') {
                    $options{$option} = join(' ',$options{$option},$value);
                } elsif ($option eq 'term') {
                    # Special handing for 'terms' data
                    # grab the score from the end of $line and leave 'term'
                    $value =~ s/\ ([-0-9]+)$//;
                    $terms{"$value"} = $1;
                } else {
                    err_msg("Option $option previously defined",0);
                }
            } else {
                $options{$option} = $value;
            }
        }
        close CONFIG;

        # Special handling for the 'terms' data
        if (scalar(keys %terms)) {
            $options{terms} = \%terms;
        } else {
            $options{terms} = 0;
        }
    } else {
        err_msg("Unable to open $conf_file: $!",1);
    }

    $options{depth} = 0 unless (defined $options{depth});
    $options{delay} = 5 unless (defined $options{delay});
    $options{threshold} = 5 unless (defined $options{threshold});

    return \%options;
}

sub err_msg {
    # Function to 'standardize' error output
    my $message = shift;
    # 0 is non-fatal, non-zero exits with that value
    my $err_lvl = shift;

    print STDERR "$message\n";
    if ($err_lvl) {
        usage();
        exit $err_lvl;
    }
}

sub verify_options {
    # Check that required options are set, as expected.
    my $options = shift;

    my $success = 1;

    if ($$options{terms} == 0) {
        $success = 0;
        err_msg('No search terms have been defined.',0);
    }

    if (scalar(split(/\s+/,$$options{locale})) == 0) {
        $success = 0;
        err_msg('No search locales have been defined.',0);
    }

    unless ($$options{section}) {
        $success = 0;
        err_msg('No section to search defined.',0);
    }

    if ($$options{send_email}) {
        unless ($$options{email}) {
            $$options{send_email} = 0;
            err_msg('No email address defined, not sending mail.',0);
        }
        if ($$options{sendmail}) {
            my ($bin) = split(/\s*/,$$options{sendmail});
            unless (-e "$bin" && -x "$bin") {
                $$options{send_email} = 0;
                err_msg("Sendmail binary ($bin) not found, not sending mail",0);
            }
        } else {
            $$options{send_email} = 0;
            err_msg('Path to sendmail not defined, not sending mail.',0);
        }
    }

    unless ($$options{history}) {
        $$options{history} = 0;
        err_msg('No history file defined, not using URL history.',0);
    }

    return $success;
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
        err_msg("Failed to open $hist_file; $!",0);
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

    print $email_content if ($VERBOSE);

    if (open EMAIL,'|-',"$sendmail") {
        print EMAIL $email_content;
        close EMAIL;
    } else {
        err_msg("Cannot open $sendmail: $!",0);
    }
}

sub create_results {
    my $errors      = shift;
    my @matches     = @_;

    # Return if there are no matches
    return undef unless (scalar(@matches) > 0);

    # Sort matches by score
    my @sorted = sort {
        # Items in @matches are formatted as:
        # DATE: [SCORE] (AREA) <a href='URL'>TITLE</a>\n
        my ($date_a,$score_a) = $a =~ /([0-9-]*):.*\[\s+([0-9]+)/;
        my ($date_b,$score_b) = $b =~ /([0-9-]*):.*\[\s+([0-9]+)/;
        return -1 if ($score_a > $score_b);
        return  1 if ($score_b > $score_a);
        return 0;
    } @matches;

    my $results = '';
    foreach my $posting (@sorted) {
        $results .= $posting;
    }

    $results = "$results\n$errors\n";
    print "$results" if ($VERBOSE);

    return $results;
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
    if ($VERBOSE) {
        err_msg("problem fetching $url ($!)",0);
    }
    return undef;
}

sub examine_posting {
    # Scan a Craig's List posting for configured search terms
    # Returns text if the posting meets a threshold requirement, else undef
    my $url     = shift;
    my $terms   = shift;

    my $score   = 0;

    # Terms found in job posting
    my @found = ();

    my $title   = '';
    my $area    = '???';
    my $date    = '????-??-??';
    my $body    = get_page($url);
    return undef unless (defined $body);

    ($date) = $body =~ /Posted:\s+\<date\>([0-9]{4}-[0-9]{2}-[0-9]{2})/gi;
    ($title) = $body =~ /postingTitle = "([^"]*)/gi;

    if ($title =~ /\(([^)]+)\)$/) {
        $area = $1;
        $title =~ s/\s+\($area\)//;
    }

    $body =~ s/^.*\<section id=\"postingbody\"\>//gis;
    $body =~ s/\<\/section\>.*//gis;

    foreach my $term (keys %$terms) {
        my @count = $body =~ /\b$term\b/igs;
        if (scalar(@count) > 0) {
            my $term_count = $term . '[' . scalar(@count) . ']';
            push @found, $term_count;
            $score += scalar(@count)*$$terms{$term};
        }
        # Bonus score if the term is found in the job title
        $score += $$terms{$term} if ($title =~ /$term/i);
    }

    print "examined: $url score: $score\n" if ($VERBOSE);

    my $fscore = sprintf("% 3i",$score);
    # Create a summary of the job posting;
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
        err_msg("unable to open $hist_file for writing; $!",0);
    }
}
